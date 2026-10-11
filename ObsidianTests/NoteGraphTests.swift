import Foundation
import XCTest

@testable import Obsidian

final class NoteGraphTests: XCTestCase {
    func testMarkdownNoteLinkExtractorIgnoresEmbedsAndCode() {
        let markdown = """
        [[Alpha]]
        [Beta](Beta.md)
        ![[hero.png]]
        ![Image](hero.png)
        `[[Inline]]`

        ```md
        [[Fenced]]
        [Also fenced](Gamma.md)
        ```
        """

        let references = MarkdownNoteLinkExtractor.references(in: markdown).map(\.destination)

        XCTAssertEqual(references, ["Alpha", "Beta.md"])
    }

    func testCodeMaskingKeepsUTF16LengthAndMasksCRLFFences() {
        // Emoji and combining sequences are one Character but several UTF-16
        // code units; the masked copy must keep every NSRange aligned.
        let samples = [
            "`👍` [[Old]]",
            "Intro `e\u{301} 🇺🇸` [[Old]]\n```\n🙂 [[Fenced]]\n```\n[x](Old.md)",
            "```\r\n[[Fenced]] 👍\r\n```\r\nSee [[Real]].",
            "Intro\r\n~~~\r\n[[Fenced]]\r\n~~~\r\n[[Real]]\r\n",
            "`unterminated 🙂 [[Inline]]\nnext [[Real]]"
        ]
        for sample in samples {
            let masked = MarkdownNoteLinkExtractor.maskingCodeRegions(sample)
            XCTAssertEqual((masked as NSString).length, (sample as NSString).length, sample.debugDescription)
        }

        let body = "`👍` [[Old]]"
        let maskedBody = MarkdownNoteLinkExtractor.maskingCodeRegions(body)
        XCTAssertEqual(
            (maskedBody as NSString).range(of: "[[Old]]"),
            (body as NSString).range(of: "[[Old]]")
        )

        // "\r\n" is a single Character, so CRLF notes used to be one "line":
        // an opening fence masked the whole note and `~~~` fences masked nothing.
        XCTAssertEqual(
            MarkdownNoteLinkExtractor.maskingCodeRegions("```\r\n[[Fenced]]\r\n```\r\nSee [[Real]]."),
            "   \r\n          \r\n   \r\nSee [[Real]]."
        )
        XCTAssertEqual(
            MarkdownNoteLinkExtractor.references(in: "```\r\n[[Fenced]]\r\n```\r\nSee [[Real]].").map(\.destination),
            ["Real"]
        )
        XCTAssertEqual(
            MarkdownNoteLinkExtractor.references(in: "Intro\r\n~~~\r\n[[Fenced]]\r\n~~~\r\n[[Real]]\r\n").map(\.destination),
            ["Real"]
        )
    }

    func testNoteGraphBuilderResolvesWikiLinksAndRelativeMarkdownLinks() throws {
        let vaultURL = try makeVault()
        let journalDirectoryURL = vaultURL.appendingPathComponent("Daily", isDirectory: true)
        let projectsDirectoryURL = vaultURL.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectsDirectoryURL, withIntermediateDirectories: true)

        let homeURL = vaultURL.appendingPathComponent("Home.md")
        let journalURL = journalDirectoryURL.appendingPathComponent("Journal.md")
        let activeURL = projectsDirectoryURL.appendingPathComponent("Active.md")

        try Data(
            """
            # Home

            [[Daily/Journal]]
            [Project](Projects/Active.md)
            [[Missing]]
            """.utf8
        ).write(to: homeURL, options: .atomic)
        try Data("# Journal\n\n[[Home]]".utf8).write(to: journalURL, options: .atomic)
        try Data("# Active".utf8).write(to: activeURL, options: .atomic)

        let files = [homeURL, journalURL, activeURL].map(makeFileItem)
        let metadata = Dictionary(uniqueKeysWithValues: try [homeURL, journalURL, activeURL].map { url in
            let content = try String(contentsOf: url, encoding: .utf8)
            let normalizedURL = url.standardizedFileURL
            return (
                normalizedURL.path,
                CachedMarkdownMetadata(
                    modificationDate: Date(),
                    noteTitle: Workspace.extractTitle(from: content),
                    noteLinks: MarkdownNoteLinkExtractor.references(in: content),
                    noteBodyStorage: SearchableNoteBody(content)
                )
            )
        })

        let snapshot = NoteGraphBuilder.makeSnapshot(
            files: files,
            metadataByPath: metadata,
            vaultURL: vaultURL,
            selectedFileURL: homeURL,
            liveSelectedMarkdown: nil
        )

        XCTAssertEqual(snapshot.nodes.count, 3)
        XCTAssertEqual(snapshot.edges.count, 3)
        XCTAssertEqual(snapshot.selectedNodeID?.standardizedFileURL, homeURL.standardizedFileURL)
        XCTAssertEqual(snapshot.connectedNodeIDs, Set([journalURL.standardizedFileURL, activeURL.standardizedFileURL]))

        let homeNode = try XCTUnwrap(snapshot.nodes.first(where: { $0.id == homeURL.standardizedFileURL }))
        let journalNode = try XCTUnwrap(snapshot.nodes.first(where: { $0.id == journalURL.standardizedFileURL }))
        let activeNode = try XCTUnwrap(snapshot.nodes.first(where: { $0.id == activeURL.standardizedFileURL }))

        XCTAssertEqual(homeNode.incomingCount, 1)
        XCTAssertEqual(homeNode.outgoingCount, 2)
        XCTAssertEqual(journalNode.incomingCount, 1)
        XCTAssertEqual(journalNode.outgoingCount, 1)
        XCTAssertEqual(activeNode.incomingCount, 1)
        XCTAssertEqual(activeNode.outgoingCount, 0)
    }

    func testGraphLayoutAnimationFramesShowDeterministicSettlingMotion() throws {
        let nodeURLs = ["A.md", "B.md", "C.md"].map {
            URL(fileURLWithPath: "/tmp/\($0)").standardizedFileURL
        }
        let nodes = [
            NoteGraphNode(
                id: nodeURLs[0],
                url: nodeURLs[0],
                title: "A",
                relativePath: "A.md",
                incomingCount: 0,
                outgoingCount: 1
            ),
            NoteGraphNode(
                id: nodeURLs[1],
                url: nodeURLs[1],
                title: "B",
                relativePath: "B.md",
                incomingCount: 1,
                outgoingCount: 1
            ),
            NoteGraphNode(
                id: nodeURLs[2],
                url: nodeURLs[2],
                title: "C",
                relativePath: "C.md",
                incomingCount: 1,
                outgoingCount: 0
            )
        ]
        let snapshot = NoteGraphSnapshot(
            nodes: nodes,
            edges: [
                NoteGraphEdge(source: nodeURLs[0], target: nodeURLs[1]),
                NoteGraphEdge(source: nodeURLs[1], target: nodeURLs[2])
            ],
            selectedNodeID: nodeURLs[0],
            connectedNodeIDs: [nodeURLs[1]]
        )

        let frames = NoteGraphLayoutEngine.animationFrames(for: snapshot, relayoutSeed: 3)
        let repeatedFrames = NoteGraphLayoutEngine.animationFrames(for: snapshot, relayoutSeed: 3)
        let finalLayout = NoteGraphLayoutEngine.generate(for: snapshot, relayoutSeed: 3)

        XCTAssertGreaterThan(frames.count, 2)
        XCTAssertEqual(frames, repeatedFrames)
        XCTAssertEqual(frames.last, finalLayout)
        XCTAssertEqual(Set(frames[0].positions.keys), Set(nodeURLs))

        let selectedPosition = try XCTUnwrap(frames[0].positions[nodeURLs[0]])
        XCTAssertEqual(selectedPosition.x, 0, accuracy: 0.0001)
        XCTAssertEqual(selectedPosition.y, 0, accuracy: 0.0001)

        let firstMovingPosition = try XCTUnwrap(frames.first?.positions[nodeURLs[2]])
        let lastMovingPosition = try XCTUnwrap(frames.last?.positions[nodeURLs[2]])
        XCTAssertGreaterThan(
            hypot(
                lastMovingPosition.x - firstMovingPosition.x,
                lastMovingPosition.y - firstMovingPosition.y
            ),
            0.01
        )
    }

    func testRepulsionStrategyIsExactForSmallGraphsAndBarnesHutForLargeOnes() {
        let threshold = NoteGraphLayoutEngine.barnesHutNodeThreshold

        XCTAssertEqual(NoteGraphLayoutEngine.repulsionStrategy(forNodeCount: 50), .exact)
        XCTAssertEqual(NoteGraphLayoutEngine.repulsionStrategy(forNodeCount: threshold), .exact)
        XCTAssertEqual(NoteGraphLayoutEngine.repulsionStrategy(forNodeCount: threshold + 1), .barnesHut)
        XCTAssertEqual(NoteGraphLayoutEngine.repulsionStrategy(forNodeCount: 400), .barnesHut)
    }

    func testBarnesHutLayoutIsFiniteDeterministicAndCoversEveryNode() throws {
        let snapshot = makeSyntheticSnapshot(nodeCount: 400, isolatedNodeCount: 20)
        XCTAssertEqual(NoteGraphLayoutEngine.repulsionStrategy(forNodeCount: snapshot.nodes.count), .barnesHut)

        let layout = NoteGraphLayoutEngine.generate(for: snapshot, relayoutSeed: 7)
        let repeatedLayout = NoteGraphLayoutEngine.generate(for: snapshot, relayoutSeed: 7)

        assertLayout(layout, coversEveryNodeOf: snapshot)
        XCTAssertEqual(layout, repeatedLayout)

        let pinnedID = try XCTUnwrap(snapshot.selectedNodeID)
        let pinnedPosition = try XCTUnwrap(layout.positions[pinnedID])
        XCTAssertEqual(pinnedPosition.x, 0, accuracy: 0.0001)
        XCTAssertEqual(pinnedPosition.y, 0, accuracy: 0.0001)

        // Layouts are normalized so the farthest node sits at radius 1.68; if the
        // approximate repulsion had collapsed or blown up the simulation this
        // would not hold.
        let maxRadius = layout.positions.values.map { hypot($0.x, $0.y) }.max() ?? 0
        XCTAssertEqual(maxRadius, 1.68, accuracy: 0.001)
    }

    func testBarnesHutScatterLayoutIsFiniteDeterministicAndCoversEveryNode() {
        let snapshot = makeSyntheticSnapshot(nodeCount: 400, isolatedNodeCount: 400)
        XCTAssertTrue(snapshot.edges.isEmpty)
        XCTAssertEqual(NoteGraphLayoutEngine.repulsionStrategy(forNodeCount: snapshot.nodes.count), .barnesHut)

        let layout = NoteGraphLayoutEngine.generate(for: snapshot, relayoutSeed: 1)
        let repeatedLayout = NoteGraphLayoutEngine.generate(for: snapshot, relayoutSeed: 1)

        assertLayout(layout, coversEveryNodeOf: snapshot)
        XCTAssertEqual(layout, repeatedLayout)
    }

    func testRecenterTranslatesLayoutSoPreviousPinnedNodeLeavesTheOrigin() throws {
        let urls = (0..<6).map { URL(fileURLWithPath: "/vault/N\($0).md") }
        let nodes = urls.enumerated().map { index, url in
            NoteGraphNode(
                id: url,
                url: url,
                title: "N\(index)",
                relativePath: "N\(index).md",
                incomingCount: 1,
                outgoingCount: 1
            )
        }
        let edges = (0..<5).map { NoteGraphEdge(source: urls[$0], target: urls[$0 + 1]) }

        func snapshot(selecting url: URL) -> NoteGraphSnapshot {
            NoteGraphSnapshot(nodes: nodes, edges: edges, selectedNodeID: url, connectedNodeIDs: [])
        }

        let settled = NoteGraphLayoutEngine.generate(for: snapshot(selecting: urls[0]), relayoutSeed: 3)
        let recentered = try XCTUnwrap(
            NoteGraphLayoutEngine.recenter(settled, for: snapshot(selecting: urls[1]))
        )

        let newPinned = try XCTUnwrap(recentered.positions[urls[1]])
        XCTAssertEqual(newPinned.x, 0, accuracy: 0.0001)
        XCTAssertEqual(newPinned.y, 0, accuracy: 0.0001)

        // The previously pinned node must no longer sit on top of the new one.
        let oldPinned = try XCTUnwrap(recentered.positions[urls[0]])
        XCTAssertGreaterThan(hypot(oldPinned.x, oldPinned.y), 0.05)

        // Re-centering is a rigid translation followed by uniform scaling, so the
        // relative geometry is preserved: a ratio of distances stays the same.
        let settledOrigin = try XCTUnwrap(settled.positions[urls[1]])
        let settledA = try XCTUnwrap(settled.positions[urls[0]])
        let settledB = try XCTUnwrap(settled.positions[urls[2]])
        let recenteredB = try XCTUnwrap(recentered.positions[urls[2]])
        let settledRatio = hypot(settledB.x - settledOrigin.x, settledB.y - settledOrigin.y)
            / hypot(settledA.x - settledOrigin.x, settledA.y - settledOrigin.y)
        let recenteredRatio = hypot(recenteredB.x, recenteredB.y) / hypot(oldPinned.x, oldPinned.y)
        XCTAssertEqual(settledRatio, recenteredRatio, accuracy: 0.0001)

        // Farthest node sits on the normalization radius.
        let maxRadius = recentered.positions.values.map { hypot($0.x, $0.y) }.max() ?? 0
        XCTAssertEqual(maxRadius, 1.68, accuracy: 0.001)

        XCTAssertNil(
            NoteGraphLayoutEngine.recenter(
                NoteGraphLayout(positions: [urls[0]: .zero]),
                for: snapshot(selecting: urls[0])
            )
        )
    }

    func testPreviewPreprocessorRewritesObsidianNoteLinksToFileURLs() throws {
        let vaultURL = try makeVault()
        let sourceURL = vaultURL.appendingPathComponent("Source.md")
        let targetURL = vaultURL.appendingPathComponent("Target.md")

        try Data("# Source\n".utf8).write(to: sourceURL, options: .atomic)
        try Data("# Target\n".utf8).write(to: targetURL, options: .atomic)

        let context = PreviewContext(
            documentURL: sourceURL,
            vaultURL: vaultURL,
            assetLookupByFilename: [
                sourceURL.lastPathComponent: [sourceURL],
                targetURL.lastPathComponent: [targetURL]
            ]
        )

        let document = MarkdownPreprocessor.preprocess("[[Target|Open Target]]", context: context)

        XCTAssertEqual(
            document.normalizedMarkdown,
            "[Open Target](<\(targetURL.absoluteString)>)"
        )
    }

    private func assertLayout(
        _ layout: NoteGraphLayout,
        coversEveryNodeOf snapshot: NoteGraphSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(layout.positions.count, snapshot.nodes.count, file: file, line: line)
        XCTAssertEqual(Set(layout.positions.keys), Set(snapshot.nodes.map(\.id)), file: file, line: line)

        for (nodeID, position) in layout.positions {
            XCTAssertTrue(
                position.x.isFinite && position.y.isFinite,
                "Non-finite position for \(nodeID.lastPathComponent): \(position)",
                file: file,
                line: line
            )
        }
    }

    /// Builds a deterministic synthetic graph: the first `nodeCount - isolatedNodeCount`
    /// nodes form a ring with hub and cross links (one connected component); the
    /// remaining nodes have no edges so several components are exercised.
    private func makeSyntheticSnapshot(nodeCount: Int, isolatedNodeCount: Int) -> NoteGraphSnapshot {
        let nodeURLs = (0..<nodeCount).map { index in
            URL(fileURLWithPath: "/tmp/synthetic-graph/Note-\(index).md").standardizedFileURL
        }
        let linkedNodeCount = max(nodeCount - isolatedNodeCount, 0)

        var edges: [NoteGraphEdge] = []
        var seenEdges = Set<NoteGraphEdge>()
        var incomingCounts = [Int](repeating: 0, count: nodeCount)
        var outgoingCounts = [Int](repeating: 0, count: nodeCount)

        func addEdge(from source: Int, to target: Int) {
            guard source != target else { return }
            let edge = NoteGraphEdge(source: nodeURLs[source], target: nodeURLs[target])
            guard seenEdges.insert(edge).inserted else { return }
            edges.append(edge)
            outgoingCounts[source] += 1
            incomingCounts[target] += 1
        }

        if linkedNodeCount > 1 {
            for index in 0..<linkedNodeCount {
                addEdge(from: index, to: (index + 1) % linkedNodeCount)
                if index.isMultiple(of: 10) {
                    addEdge(from: index, to: 0)
                }
                addEdge(from: index, to: (index * 7) % linkedNodeCount)
            }
        }

        let nodes = nodeURLs.enumerated().map { index, url in
            NoteGraphNode(
                id: url,
                url: url,
                title: "Note \(index)",
                relativePath: "Note-\(index).md",
                incomingCount: incomingCounts[index],
                outgoingCount: outgoingCounts[index]
            )
        }

        let selectedNodeID = nodeURLs[0]
        let connectedNodeIDs = Set(edges.compactMap { edge -> URL? in
            if edge.source == selectedNodeID {
                return edge.target
            }
            if edge.target == selectedNodeID {
                return edge.source
            }
            return nil
        })

        return NoteGraphSnapshot(
            nodes: nodes,
            edges: edges,
            selectedNodeID: selectedNodeID,
            connectedNodeIDs: connectedNodeIDs
        )
    }

    private func makeVault() throws -> URL {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteGraphTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: vaultURL)
        }
        return vaultURL
    }

    private func makeFileItem(_ url: URL) -> FileItem {
        FileItem(
            id: url.standardizedFileURL,
            name: url.lastPathComponent,
            url: url.standardizedFileURL,
            modificationDate: Date(),
            noteTitle: url.deletingPathExtension().lastPathComponent
        )
    }
}

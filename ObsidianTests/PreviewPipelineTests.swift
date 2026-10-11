import AppKit
import Foundation
import XCTest

@testable import Obsidian

final class PreviewPipelineTests: XCTestCase {
    func testPreviewURLPolicyAllowsOnlySafeExternalSchemes() throws {
        XCTAssertTrue(PreviewURLPolicy.canOpenExternally(try XCTUnwrap(URL(string: "https://example.com"))))
        XCTAssertTrue(PreviewURLPolicy.canOpenExternally(try XCTUnwrap(URL(string: "mailto:hello@example.com"))))
        XCTAssertFalse(PreviewURLPolicy.canOpenExternally(URL(fileURLWithPath: "/tmp/note.md")))
        XCTAssertFalse(PreviewURLPolicy.canOpenExternally(try XCTUnwrap(URL(string: "shortcuts://run-shortcut?name=Unsafe"))))
        XCTAssertFalse(PreviewURLPolicy.canOpenExternally(try XCTUnwrap(URL(string: "javascript:alert(1)"))))
        XCTAssertFalse(PreviewURLPolicy.canOpenExternally(try XCTUnwrap(URL(string: "data:text/html,hello"))))
    }

    func testPreviewURLPolicyRoutesOnlyExistingVaultNotesAndImagesInternally() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: vault) }
        let note = vault.appendingPathComponent("Note.md")
        let image = vault.appendingPathComponent("Image.png")
        let other = vault.appendingPathComponent("File.pdf")
        try Data("note".utf8).write(to: note)
        try Data([0]).write(to: image)
        try Data([0]).write(to: other)

        XCTAssertEqual(PreviewURLPolicy.internalVaultFile(note, vaultURL: vault), note.standardizedFileURL)
        XCTAssertEqual(PreviewURLPolicy.internalVaultFile(image, vaultURL: vault), image.standardizedFileURL)
        XCTAssertNil(PreviewURLPolicy.internalVaultFile(other, vaultURL: vault))
        XCTAssertNil(PreviewURLPolicy.internalVaultFile(URL(fileURLWithPath: "/tmp/outside.md"), vaultURL: vault))
    }

    func testRemotePreviewImageResponseRequiresImageMIMEAndSizeLimit() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/image.png"))
        let valid = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png", "Content-Length": "1024"]
        ))
        let html = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html", "Content-Length": "1024"]
        ))
        let oversized = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "image/png",
                "Content-Length": "\(PreviewImageSourceLoader.maximumRemoteImageBytes + 1)"
            ]
        ))

        XCTAssertTrue(PreviewImageSourceLoader.isValidRemoteImageResponse(valid, for: url))
        XCTAssertFalse(PreviewImageSourceLoader.isValidRemoteImageResponse(html, for: url))
        XCTAssertFalse(PreviewImageSourceLoader.isValidRemoteImageResponse(oversized, for: url))
    }

    func testEditorLinkDetectorFindsBareURLAtCharacterIndex() {
        let text = "Visit https://21st.dev/community/components for components."
        let index = (text as NSString).range(of: "21st.dev").location

        let url = EditorLinkDetector.url(near: index, in: text)

        XCTAssertEqual(url?.absoluteString, "https://21st.dev/community/components")
    }

    func testEditorLinkDetectorFindsMarkdownLinkAtCharacterIndex() {
        let text = "[Componentful](https://www.componentful.com/)"
        let index = (text as NSString).range(of: "Componentful").location + 2

        let url = EditorLinkDetector.url(near: index, in: text)

        XCTAssertEqual(url?.absoluteString, "https://www.componentful.com/")
    }

    func testEditorLinkDetectorIgnoresMarkdownImages() {
        let text = "![Preview](https://example.com/image.png)"
        let index = (text as NSString).range(of: "Preview").location

        let url = EditorLinkDetector.url(near: index, in: text)

        XCTAssertNil(url)
    }

    func testAssetResolverResolvesDocumentRelativeImage() throws {
        let fixture = try makeFixture()

        let resolver = AssetResolver(context: fixture.context)
        let asset = resolver.resolve(reference: "doc-image.png")

        XCTAssertEqual(asset?.fileURL, fixture.documentImageURL)
        XCTAssertEqual(asset?.kind, .image)
    }

    func testAssetResolverResolvesVaultRelativeImage() throws {
        let fixture = try makeFixture()

        let resolver = AssetResolver(context: fixture.context)
        let asset = resolver.resolve(reference: "assets/vault-image.png")

        XCTAssertEqual(asset?.fileURL, fixture.vaultImageURL)
        XCTAssertEqual(asset?.kind, .image)
    }

    func testAssetResolverResolvesAbsolutePath() throws {
        let fixture = try makeFixture()

        let resolver = AssetResolver(context: fixture.context)
        let asset = resolver.resolve(reference: fixture.documentImageURL.path)

        XCTAssertEqual(asset?.fileURL, fixture.documentImageURL)
    }

    func testAssetResolverRejectsPathsOutsideVault() throws {
        let fixture = try makeFixture()
        let outsideURL = fixture.rootURL.appendingPathComponent("secret.png")
        try fixturePNGData().write(to: outsideURL)

        let resolver = AssetResolver(context: fixture.context)
        XCTAssertNil(resolver.resolve(reference: outsideURL.path))
        XCTAssertNil(resolver.resolve(reference: outsideURL.absoluteString))
        XCTAssertNil(resolver.resolve(reference: "../../secret.png"))
    }

    func testAssetResolverResolvesFileURL() throws {
        let fixture = try makeFixture()

        let resolver = AssetResolver(context: fixture.context)
        let asset = resolver.resolve(reference: fixture.documentImageURL.absoluteString)

        XCTAssertEqual(asset?.fileURL, fixture.documentImageURL)
    }

    func testAssetResolverResolvesUniqueBareFilenameWithinVault() throws {
        let fixture = try makeFixture()

        let resolver = AssetResolver(context: fixture.context)
        let asset = resolver.resolve(reference: fixture.bareFilenameImageURL.lastPathComponent)

        XCTAssertEqual(asset?.fileURL, fixture.bareFilenameImageURL)
    }

    func testAssetResolverReturnsNilForMissingFiles() throws {
        let fixture = try makeFixture()

        let resolver = AssetResolver(context: fixture.context)
        XCTAssertNil(resolver.resolve(reference: "missing-image.png"))
    }

    func testAssetResolverClassifiesNonImageFileEmbeds() throws {
        let fixture = try makeFixture()

        let resolver = AssetResolver(context: fixture.context)
        let asset = resolver.resolve(reference: fixture.pdfURL.lastPathComponent)

        XCTAssertEqual(asset?.fileURL, fixture.pdfURL)
        XCTAssertEqual(asset?.kind, .file)
        XCTAssertEqual(asset?.mimeType, "application/pdf")
    }

    func testPreprocessorLeavesPlainMarkdownUntouched() throws {
        let fixture = try makeFixture()
        let markdown = "# Title\n\nParagraph text."

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)

        XCTAssertEqual(document.normalizedMarkdown, markdown)
        XCTAssertEqual(document.preferredRenderMode, .native)
    }

    func testPreprocessorConvertsObsidianImageEmbedIntoMarkdownImage() throws {
        let fixture = try makeFixture()

        let document = MarkdownPreprocessor.preprocess("![[doc-image.png]]", context: fixture.context)

        XCTAssertEqual(
            document.normalizedMarkdown,
            "![doc-image](<\(fixture.documentImageURL.absoluteString)>)"
        )
    }

    func testPreprocessorConvertsObsidianFileEmbedIntoMarkdownLink() throws {
        let fixture = try makeFixture()

        let document = MarkdownPreprocessor.preprocess("![[reference.pdf]]", context: fixture.context)

        XCTAssertEqual(
            document.normalizedMarkdown,
            "[reference](<\(fixture.pdfURL.absoluteString)>)"
        )
    }

    func testPreprocessorMarksWidthQualifiedObsidianImageEmbedsForHTMLFallback() throws {
        let fixture = try makeFixture()

        let document = MarkdownPreprocessor.preprocess("![[doc-image.png|300]]", context: fixture.context)

        XCTAssertTrue(document.requiresHTMLFallback)
        XCTAssertEqual(document.preferredRenderMode, .html)
        XCTAssertTrue(document.normalizedMarkdown.contains("codex-obsidian-width-300"))
    }

    func testPreprocessorSplitsMermaidBlocksIntoSegments() throws {
        let fixture = try makeFixture()
        let markdown = """
        Before

        ```mermaid
        graph TD
        A-->B
        ```

        After
        """

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)

        XCTAssertEqual(document.segments.count, 3)

        if case .markdown(let leading) = document.segments[0] {
            XCTAssertTrue(leading.contains("Before"))
        } else {
            XCTFail("Expected leading markdown segment")
        }

        if case .mermaid(let source, let diagram) = document.segments[1] {
            XCTAssertEqual(source, "graph TD\nA-->B")
            XCTAssertNotNil(diagram)
        } else {
            XCTFail("Expected mermaid segment")
        }

        if case .markdown(let trailing) = document.segments[2] {
            XCTAssertTrue(trailing.contains("After"))
        } else {
            XCTFail("Expected trailing markdown segment")
        }
    }

    func testPreprocessorEncodesInlineAndBlockMathAsTokens() throws {
        let fixture = try makeFixture()
        let markdown = """
        Inline $$a^2 + b^2 = c^2$$ example.

        $$
        \\int_0^\\infty e^{-x} dx = 1
        $$

        Also \\(\\alpha + \\beta\\) and \\[\\sum_i i\\].
        """

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)

        XCTAssertTrue(document.requiresHTMLFallback, "Math requires HTML fallback for KaTeX")
        let body = document.normalizedMarkdown
        XCTAssertTrue(body.contains(MathTokenCoder.displayPrefix), "Expected display math token")
        XCTAssertTrue(body.contains(MathTokenCoder.inlinePrefix), "Expected inline math token")
        XCTAssertFalse(body.contains("$$a^2"), "Original delimiters should be replaced")
        XCTAssertFalse(body.contains("\\("), "Inline LaTeX delimiters should be replaced")
    }

    func testPreprocessorPreservesMathInsideCodeSpans() throws {
        let fixture = try makeFixture()
        let markdown = "Code `$$a^2$$` stays as literal."

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)

        XCTAssertFalse(document.requiresHTMLFallback, "Math tokens inside code must not trigger fallback")
        XCTAssertTrue(document.normalizedMarkdown.contains("`$$a^2$$`"))
    }

    func testHTMLRendererSubstitutesMathTokensWithSpans() throws {
        let fixture = try makeFixture()
        let markdown = "Inline $$x + y$$ example."

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)
        let html = HTMLPreviewRenderer.render(document: document)

        XCTAssertTrue(html.contains("<span class=\"math-display\">x + y</span>"),
                      "Expected KaTeX target span; got: \(html)")
        XCTAssertFalse(html.contains(MathTokenCoder.displayPrefix),
                       "All tokens should be substituted in final HTML")
    }

    func testPreprocessorDoesNotRewriteObsidianEmbedsInsideCode() throws {
        let fixture = try makeFixture()
        let markdown = """
        `![[doc-image.png]]`

        ```md
        ![[doc-image.png]]
        ```
        """

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)

        XCTAssertTrue(document.normalizedMarkdown.contains("`![[doc-image.png]]`"))
        XCTAssertTrue(document.normalizedMarkdown.contains("![[doc-image.png]]"))
        XCTAssertFalse(document.normalizedMarkdown.contains(fixture.documentImageURL.absoluteString))
    }

    func testHTMLRendererUsesDownForStandardMarkdownFeatures() throws {
        let fixture = try makeFixture()
        let markdown = """
        # Heading

        - one
        - two

        > quoted

        | A | B |
        | - | - |
        | 1 | 2 |

        ```swift
        let x = 1
        ```

        [link](https://example.com)

        https://example.com

        ~~done~~
        """

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)
        let html = HTMLPreviewRenderer.render(document: document)

        XCTAssertTrue(html.contains("<h1>Heading</h1>"))
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<table>"), html)
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">link</a>"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">https://example.com</a>"), html)
        XCTAssertTrue(html.contains("<del>done</del>"), html)
    }

    func testHTMLRendererUsesFileURLsForLocalImages() throws {
        let fixture = try makeFixture()

        let document = MarkdownPreprocessor.preprocess("![alt](doc-image.png)", context: fixture.context)
        let html = HTMLPreviewRenderer.render(document: document)

        XCTAssertTrue(html.contains(fixture.documentImageURL.absoluteString))
        XCTAssertFalse(html.contains("data:image"))
    }

    func testHTMLRendererOnlyInjectsAppGeneratedMermaidSVG() throws {
        let fixture = try makeFixture()
        let markdown = """
        <script>alert('bad')</script>

        ```mermaid
        graph TD
        A-->B
        ```
        """

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)
        let html = HTMLPreviewRenderer.render(document: document)

        XCTAssertTrue(html.contains("<svg"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testNativePreviewSelectionStaysNativeForSupportedDocuments() throws {
        let fixture = try makeFixture()

        let document = MarkdownPreprocessor.preprocess(
            "# Title\n\n![[doc-image.png]]",
            context: fixture.context
        )

        XCTAssertEqual(document.preferredRenderMode, .native)
    }

    func testNativeImageSourceLoaderResolvesDocumentAndVaultRelativeImages() throws {
        let fixture = try makeFixture()

        let documentRelative = PreviewImageSourceLoader.resolvedImageURL(
            for: try XCTUnwrap(URL(string: "doc-image.png")),
            context: fixture.context
        )
        let vaultRelative = PreviewImageSourceLoader.resolvedImageURL(
            for: try XCTUnwrap(URL(string: "assets/vault-image.png")),
            context: fixture.context
        )

        XCTAssertEqual(documentRelative, fixture.documentImageURL)
        XCTAssertEqual(vaultRelative, fixture.vaultImageURL)
    }

    func testNativePreviewSelectionFallsBackForMermaidAndWidthQualifiedEmbeds() throws {
        let fixture = try makeFixture()

        let mermaidDocument = MarkdownPreprocessor.preprocess(
            """
            ```mermaid
            graph TD
            A-->B
            ```
            """,
            context: fixture.context
        )
        let widthDocument = MarkdownPreprocessor.preprocess(
            "![[doc-image.png|240]]",
            context: fixture.context
        )

        XCTAssertEqual(mermaidDocument.preferredRenderMode, .html)
        XCTAssertEqual(widthDocument.preferredRenderMode, .html)
    }

    // MARK: - Asset index fingerprint and cache invalidation

    func testAssetLookupFingerprintIsOrderIndependentAndTracksEntries() {
        let vault = URL(fileURLWithPath: "/tmp/fingerprint-vault", isDirectory: true)
        let entries: [(String, [URL])] = (0..<64).map { index in
            ("file-\(index).png", [vault.appendingPathComponent("folder-\(index % 5)/file-\(index).png")])
        }
        var forward: [String: [URL]] = [:]
        for (name, urls) in entries { forward[name] = urls }
        var backward: [String: [URL]] = [:]
        for (name, urls) in entries.reversed() { backward[name] = urls }

        let forwardFingerprint = PreviewContext(documentURL: nil, vaultURL: vault, assetLookupByFilename: forward)
            .assetLookupFingerprint
        let backwardFingerprint = PreviewContext(documentURL: nil, vaultURL: vault, assetLookupByFilename: backward)
            .assetLookupFingerprint
        XCTAssertEqual(forwardFingerprint, backwardFingerprint, "Insertion order must not matter")

        var added = forward
        added["extra.png"] = [vault.appendingPathComponent("extra.png")]
        XCTAssertNotEqual(
            PreviewContext(documentURL: nil, vaultURL: vault, assetLookupByFilename: added).assetLookupFingerprint,
            forwardFingerprint,
            "A newly indexed file changes the fingerprint"
        )

        var moved = forward
        moved["file-0.png"] = [vault.appendingPathComponent("elsewhere/file-0.png")]
        XCTAssertNotEqual(
            PreviewContext(documentURL: nil, vaultURL: vault, assetLookupByFilename: moved).assetLookupFingerprint,
            forwardFingerprint,
            "A file moving between folders (same filename) changes the fingerprint"
        )
    }

    func testPreprocessCachedReResolvesEmbedWhenAssetIndexGainsTheFile() throws {
        let fixture = try makeFixture()
        let droppedURL = fixture.bareFilenameImageURL
            .deletingLastPathComponent()
            .appendingPathComponent("dropped-image.png")
        let markdown = "![[dropped-image.png]]"

        let unresolved = MarkdownPreprocessor.preprocessCached(markdown, context: fixture.context)
        XCTAssertEqual(unresolved.normalizedMarkdown, markdown, "Not indexed yet, so the embed stays verbatim")

        // Simulate dropping an image into the vault: the file appears on disk
        // and the asset index gains an entry, while the note text is unchanged.
        try fixturePNGData().write(to: droppedURL)
        var indexedContext = fixture.context
        indexedContext.assetLookupByFilename["dropped-image.png"] = [droppedURL]
        XCTAssertNotEqual(indexedContext.assetLookupFingerprint, fixture.context.assetLookupFingerprint)

        let expectedURL = try XCTUnwrap(
            AssetResolver(context: indexedContext).resolve(reference: "dropped-image.png")?.fileURL
        )
        let resolved = MarkdownPreprocessor.preprocessCached(markdown, context: indexedContext)
        XCTAssertEqual(
            resolved.normalizedMarkdown,
            "![dropped-image](<\(expectedURL.absoluteString)>)",
            "Same text and document, but the changed asset index must bypass the cached parse"
        )
    }

    func testAssetResolverDoesNotWalkVaultForUnindexedBareFilename() throws {
        let fixture = try makeFixture()
        let unindexedURL = fixture.bareFilenameImageURL
            .deletingLastPathComponent()
            .appendingPathComponent("unindexed-image.png")
        try fixturePNGData().write(to: unindexedURL)

        let resolver = AssetResolver(context: fixture.context)
        XCTAssertNil(
            resolver.resolve(reference: "unindexed-image.png"),
            "Bare filenames resolve through the asset index only; the vault is never enumerated"
        )
    }

    // MARK: - Post-processing passes

    func testHTMLRendererKeepsTextBetweenMultipleMathTokensInOrder() throws {
        let fixture = try makeFixture()
        let markdown = """
        A $$x$$ B $$y$$ C

        D \\(z\\) E \\(w\\) F
        """

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)
        let html = HTMLPreviewRenderer.render(document: document)

        XCTAssertTrue(
            html.contains("<p>A <span class=\"math-display\">x</span> B <span class=\"math-display\">y</span> C</p>"),
            html
        )
        XCTAssertTrue(
            html.contains("<p>D <span class=\"math-inline\">z</span> E <span class=\"math-inline\">w</span> F</p>"),
            html
        )
        XCTAssertFalse(html.contains(MathTokenCoder.displayPrefix), html)
        XCTAssertFalse(html.contains(MathTokenCoder.inlinePrefix), html)
    }

    func testHTMLRendererNeutralizesDangerousSchemesInEveryQuoteStyle() throws {
        let fixture = try makeFixture()
        let markdown = """
        [one](javascript:alert(1)) and [two](vbscript:msgbox) and [three](data:text/html,hi)

        ![ok](data:image/png;base64,AAAA)
        """

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)
        let html = HTMLPreviewRenderer.render(document: document)

        XCTAssertFalse(html.lowercased().contains("javascript:"), html)
        XCTAssertFalse(html.lowercased().contains("vbscript:"), html)
        XCTAssertFalse(html.contains("data:text/html"), html)
        XCTAssertTrue(html.contains("data:image/png"), "data:image/ sources must survive: \(html)")
    }

    // MARK: - Segment identity

    func testIdentifiedSegmentsKeepEmbedIdentityWhenParagraphInsertedAbove() throws {
        let fixture = try makeFixture()
        let embedURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let before = MarkdownPreprocessor.preprocess(
            "Intro\n\n\(embedURL)\n\nOutro",
            context: fixture.context
        )
        let after = MarkdownPreprocessor.preprocess(
            "New paragraph\n\nIntro\n\n\(embedURL)\n\nOutro",
            context: fixture.context
        )

        func embedID(in document: PreviewDocument) -> String? {
            document.identifiedSegments.first { identified in
                if case .embed = identified.segment { return true }
                return false
            }?.id
        }

        XCTAssertEqual(before.preferredRenderMode, .embedded)
        XCTAssertNotNil(embedID(in: before))
        XCTAssertEqual(embedID(in: before), embedID(in: after), "The embed keeps its identity after an insertion above it")
        // The text on either side of the embed is the same structural slot, so
        // inserting above the embed keeps every segment's identity.
        XCTAssertEqual(before.identifiedSegments.map(\.id), after.identifiedSegments.map(\.id))
        XCTAssertEqual(after.identifiedSegments.count, after.segments.count)
        XCTAssertEqual(Set(after.identifiedSegments.map(\.id)).count, after.segments.count, "Every id is unique")
    }

    func testIdentifiedSegmentsKeepIdentityWhenTypingInsideASegment() throws {
        let fixture = try makeFixture()
        let embedURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        func ids(_ markdown: String) -> [String] {
            MarkdownPreprocessor.preprocess(markdown, context: fixture.context).identifiedSegments.map(\.id)
        }

        let original = ids("Intro\n\n\(embedURL)\n\nOutro\n\n```mermaid\ngraph TD\nA-->B\n```\n")
        XCTAssertGreaterThanOrEqual(original.count, 4)

        // A keystroke in the paragraph above the embed, one below it, and one
        // inside the mermaid block must each leave every id untouched, or
        // SwiftUI would recreate that segment's web view per keystroke.
        XCTAssertEqual(original, ids("Intro!\n\n\(embedURL)\n\nOutro\n\n```mermaid\ngraph TD\nA-->B\n```\n"))
        XCTAssertEqual(original, ids("Intro\n\n\(embedURL)\n\nOutro!\n\n```mermaid\ngraph TD\nA-->B\n```\n"))
        XCTAssertEqual(original, ids("Intro\n\n\(embedURL)\n\nOutro\n\n```mermaid\ngraph TD\nA-->B\nB-->C\n```\n"))
        XCTAssertEqual(Set(original).count, original.count, "Every id is unique: \(original)")
    }

    func testIdentifiedSegmentsDoNotShiftLaterSegmentsWhenTextIsInsertedAboveMultipleEmbeds() throws {
        let fixture = try makeFixture()
        let first = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let second = "https://www.youtube.com/watch?v=9bZkp7q19f0"
        func ids(_ markdown: String) -> [String] {
            MarkdownPreprocessor.preprocess(markdown, context: fixture.context).identifiedSegments.map(\.id)
        }

        let before = ids("A\n\n\(first)\n\nB\n\n\(second)\n\nC")
        let after = ids("Top\n\nA\n\n\(first)\n\nB\n\n\(second)\n\nC")
        XCTAssertEqual(before, after)
        XCTAssertEqual(Set(before).count, before.count, "Every id is unique: \(before)")
    }

    func testIdentifiedSegmentsDisambiguateDuplicateContent() throws {
        let fixture = try makeFixture()
        let markdown = """
        ```mermaid
        graph TD
        A-->B
        ```

        ```mermaid
        graph TD
        A-->B
        ```
        """

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)
        let ids = document.identifiedSegments.map(\.id)

        XCTAssertEqual(ids.count, document.segments.count)
        XCTAssertEqual(Set(ids).count, ids.count, "Identical segments must still get distinct ids: \(ids)")
        XCTAssertEqual(ids.filter { $0.contains("/mermaid#") }.count, 2)
    }

    // MARK: - Image attachments

    func testImageSizeReadsPixelDimensionsFromImageMetadata() throws {
        let size = try PreviewImageSourceLoader.imageSize(
            for: try fixturePNGData(),
            url: URL(fileURLWithPath: "/tmp/fixture.png")
        )
        XCTAssertEqual(size, CGSize(width: 1, height: 1))

        XCTAssertThrowsError(
            try PreviewImageSourceLoader.imageSize(
                for: Data("not an image".utf8),
                url: URL(fileURLWithPath: "/tmp/broken.png")
            )
        )
    }

    func testPixelSizeHonorsRotatedOrientations() {
        XCTAssertEqual(
            PreviewImageSourceLoader.pixelSize(width: 400, height: 200, orientation: 1),
            CGSize(width: 400, height: 200)
        )
        XCTAssertEqual(
            PreviewImageSourceLoader.pixelSize(width: 400, height: 200, orientation: 4),
            CGSize(width: 400, height: 200)
        )
        for orientation in UInt32(5)...8 {
            XCTAssertEqual(
                PreviewImageSourceLoader.pixelSize(width: 400, height: 200, orientation: orientation),
                CGSize(width: 200, height: 400),
                "orientation \(orientation) rotates by 90°"
            )
        }
        XCTAssertNil(PreviewImageSourceLoader.pixelSize(width: 0, height: 200, orientation: 1))
    }

    func testPreviewDecodedImageHoldsDecodedBitmap() throws {
        let decoded = PreviewDecodedImage(data: try fixturePNGData())
        XCTAssertNotNil(decoded.image)
        XCTAssertEqual(decoded.image?.representations.first?.pixelsWide, 1)
    }
}

private struct PreviewFixture {
    let rootURL: URL
    let context: PreviewContext
    let documentImageURL: URL
    let vaultImageURL: URL
    let bareFilenameImageURL: URL
    let pdfURL: URL
}

private extension XCTestCase {
    /// Builds a throwaway vault under the temporary directory and removes it
    /// again when the current test finishes.
    func makeFixture() throws -> PreviewFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }
        return try buildFixture(at: rootURL)
    }
}

private func buildFixture(at rootURL: URL) throws -> PreviewFixture {
    let vaultURL = rootURL.appendingPathComponent("Vault", isDirectory: true)
    let notesURL = vaultURL.appendingPathComponent("Notes", isDirectory: true)
    let assetsURL = vaultURL.appendingPathComponent("assets", isDirectory: true)
    let attachmentsURL = vaultURL.appendingPathComponent("Attachments", isDirectory: true)
    let docsURL = vaultURL.appendingPathComponent("Docs", isDirectory: true)

    for directory in [vaultURL, notesURL, assetsURL, attachmentsURL, docsURL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let documentURL = notesURL.appendingPathComponent("Note.md")
    try "# Fixture".write(to: documentURL, atomically: true, encoding: .utf8)

    let documentImageURL = notesURL.appendingPathComponent("doc-image.png")
    let vaultImageURL = assetsURL.appendingPathComponent("vault-image.png")
    let bareFilenameImageURL = attachmentsURL.appendingPathComponent("unique-bare-image.png")
    let pdfURL = docsURL.appendingPathComponent("reference.pdf")

    try fixturePNGData().write(to: documentImageURL)
    try fixturePNGData().write(to: vaultImageURL)
    try fixturePNGData().write(to: bareFilenameImageURL)
    try Data("%PDF-1.4".utf8).write(to: pdfURL)

    // Mirrors the workspace asset index, which lists every regular file in
    // the vault. Bare-filename references resolve only through this index;
    // the resolver no longer enumerates the vault on disk.
    let assetLookupByFilename: [String: [URL]] = [
        documentURL.lastPathComponent: [documentURL],
        documentImageURL.lastPathComponent: [documentImageURL],
        vaultImageURL.lastPathComponent: [vaultImageURL],
        bareFilenameImageURL.lastPathComponent: [bareFilenameImageURL],
        pdfURL.lastPathComponent: [pdfURL],
    ]

    return PreviewFixture(
        rootURL: rootURL,
        context: PreviewContext(
            documentURL: documentURL,
            vaultURL: vaultURL,
            assetLookupByFilename: assetLookupByFilename
        ),
        documentImageURL: documentImageURL,
        vaultImageURL: vaultImageURL,
        bareFilenameImageURL: bareFilenameImageURL,
        pdfURL: pdfURL
    )
}

private func fixturePNGData() throws -> Data {
    let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO0pNzsAAAAASUVORK5CYII="
    return try XCTUnwrap(Data(base64Encoded: base64))
}

/// Cross-checks that the four link/image consumers — the editor syntax
/// highlighter and Cmd-click resolver (both backed by the NSString-based
/// `EditorLinkScanner`), the note-graph extractor, and the preview rewriter
/// (both backed by the Character-based `MarkdownNoteLinkExtractor`) — agree
/// on what counts as a link or image for the representative syntax forms, so
/// the two underlying tokenizers cannot silently diverge.
@MainActor
final class LinkParserParityTests: XCTestCase {
    func testConsumersAgreeOnMarkdownLink() {
        let text = "See [Docs](https://example.com/docs) for details"
        let linkRange = (text as NSString).range(of: "[Docs](https://example.com/docs)")
        let labelRange = (text as NSString).range(of: "Docs")

        assertMarkdownLinkStyling(in: text, range: linkRange, labelRange: labelRange)

        // The detector resolves a click anywhere inside the link span, and
        // nowhere outside it.
        for index in linkRange.location..<NSMaxRange(linkRange) {
            XCTAssertEqual(
                EditorLinkDetector.url(near: index, in: text)?.absoluteString,
                "https://example.com/docs",
                "index \(index)"
            )
        }
        XCTAssertNil(EditorLinkDetector.url(near: 0, in: text))
        XCTAssertNil(EditorLinkDetector.url(near: NSMaxRange(linkRange) + 1, in: text))

        // The graph extractor sees the same destination.
        XCTAssertEqual(
            MarkdownNoteLinkExtractor.references(in: text).map(\.destination),
            ["https://example.com/docs"]
        )
    }

    func testConsumersAgreeOnBareURL() {
        let text = "Visit https://example.com/page today"
        let linkRange = (text as NSString).range(of: "https://example.com/page")

        assertLinkUnderline(in: text, range: linkRange)

        for index in linkRange.location..<NSMaxRange(linkRange) {
            XCTAssertEqual(
                EditorLinkDetector.url(near: index, in: text)?.absoluteString,
                "https://example.com/page",
                "index \(index)"
            )
        }

        // Bare URLs never reference a vault note, so the graph extractor
        // intentionally produces no reference for them.
        XCTAssertTrue(MarkdownNoteLinkExtractor.references(in: text).isEmpty)
    }

    func testConsumersAgreeOnObsidianNoteLink() {
        let text = "See [[Project Plan]] and [[2024-report|Q4 Results]]"
        let plainRange = (text as NSString).range(of: "[[Project Plan]]")
        let aliasRange = (text as NSString).range(of: "[[2024-report|Q4 Results]]")

        assertLinkUnderline(in: text, range: plainRange)
        assertLinkUnderline(in: text, range: aliasRange)

        XCTAssertEqual(
            MarkdownNoteLinkExtractor.references(in: text).map(\.destination),
            ["Project Plan", "2024-report"]
        )

        let aliasMatch = MarkdownNoteLinkExtractor.obsidianNoteLink(
            in: Array(text),
            from: aliasRange.location
        )
        XCTAssertEqual(aliasMatch?.displayName, "Q4 Results")
        XCTAssertEqual(aliasMatch?.nextIndex, NSMaxRange(aliasRange))

        // Wiki links are highlighted for navigation but intentionally do not
        // resolve to an external URL on Cmd-click.
        XCTAssertNil(EditorLinkDetector.url(near: plainRange.location + 3, in: text))
    }

    func testConsumersAgreeOnMarkdownImage() throws {
        let text = "![Alt text](images/photo.png \"Caption\")"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let labelRange = (text as NSString).range(of: "Alt text")

        assertMarkdownLinkStyling(in: text, range: fullRange, labelRange: labelRange)

        let match = try XCTUnwrap(MarkdownNoteLinkExtractor.markdownImage(in: Array(text), from: 0))
        XCTAssertEqual(match.original, text)
        XCTAssertEqual(match.altText, "Alt text")
        XCTAssertEqual(match.destination, "images/photo.png")
        XCTAssertEqual(match.title, "Caption")
        XCTAssertEqual(match.nextIndex, fullRange.length)

        // The preview adapter observes the very same parse.
        XCTAssertEqual(
            PreviewMarkdownSyntax.parseStandaloneMarkdownImage(in: text)?.destination,
            "images/photo.png"
        )

        // Images are highlighted but never resolve to an openable editor URL,
        // and produce no graph edge.
        XCTAssertNil(EditorLinkDetector.url(near: 3, in: text))
        XCTAssertTrue(MarkdownNoteLinkExtractor.references(in: text).isEmpty)
    }

    func testConsumersAgreeOnObsidianEmbed() throws {
        let text = "![[diagram.png|300]]"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        assertLinkUnderline(in: text, range: fullRange)

        let embed = try XCTUnwrap(MarkdownNoteLinkExtractor.obsidianEmbed(in: Array(text), from: 0))
        XCTAssertEqual(embed.original, text)
        XCTAssertEqual(embed.rawReference, "diagram.png|300")
        XCTAssertEqual(embed.nextIndex, fullRange.length)

        // One shared reference parse feeds the note-link view (alias as
        // display text) and the embed view (alias as pixel width).
        let descriptor = MarkdownNoteLinkExtractor.parseObsidianReference(embed.rawReference)
        XCTAssertEqual(descriptor.destination, "diagram.png")
        XCTAssertEqual(descriptor.alias, "300")
        XCTAssertEqual(descriptor.width, 300)
        XCTAssertEqual(descriptor.fileName, "diagram")

        let previewReference = PreviewMarkdownSyntax.parseObsidianReference(embed.rawReference)
        XCTAssertEqual(previewReference.target, "diagram.png")
        XCTAssertEqual(previewReference.width, 300)
        XCTAssertEqual(previewReference.displayName, "diagram")

        let noteReference = MarkdownNoteLinkExtractor.parseObsidianNoteReference(embed.rawReference)
        XCTAssertEqual(noteReference.destination, "diagram.png")
        XCTAssertEqual(noteReference.displayName, "300")

        XCTAssertTrue(MarkdownNoteLinkExtractor.references(in: text).isEmpty)
    }

    /// Asserts the highlighter marks every character of `range` as a link.
    private func assertLinkUnderline(
        in text: String,
        range: NSRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let storage = NSTextStorage(string: text)
        SyntaxHighlighter(preferences: AppPreferences()).highlight(storage)

        for index in range.location..<NSMaxRange(range) {
            XCTAssertEqual(
                storage.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int,
                NSUnderlineStyle.single.rawValue,
                "expected link underline at index \(index)",
                file: file,
                line: line
            )
        }
    }

    /// Markdown keeps the reader-facing label prominent while treating the
    /// punctuation and destination as quiet authoring metadata.
    private func assertMarkdownLinkStyling(
        in text: String,
        range: NSRange,
        labelRange: NSRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let storage = NSTextStorage(string: text)
        SyntaxHighlighter(preferences: AppPreferences()).highlight(storage)

        for index in range.location..<NSMaxRange(range) {
            if NSLocationInRange(index, labelRange) {
                XCTAssertEqual(
                    storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor,
                    Theme.linkColor,
                    "expected reader-facing label color at index \(index)",
                    file: file,
                    line: line
                )
                XCTAssertEqual(
                    storage.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int,
                    NSUnderlineStyle.single.rawValue,
                    "expected reader-facing label underline at index \(index)",
                    file: file,
                    line: line
                )
            } else {
                XCTAssertEqual(
                    storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor,
                    Theme.metaColor,
                    "expected muted Markdown syntax at index \(index)",
                    file: file,
                    line: line
                )
                XCTAssertEqual(
                    storage.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int,
                    0,
                    "expected unadorned Markdown syntax at index \(index)",
                    file: file,
                    line: line
                )
            }
        }
    }
}

/// The stylesheet memo and the rendered-page cache are main-actor bound
/// (they read `AppPreferences`), so these run on the main actor.
@MainActor
final class PreviewRenderingCacheTests: XCTestCase {
    func testStylesheetFollowsPreferenceChangesWithoutGoingStale() throws {
        let preferences = try makePreferences()
        preferences.previewFontSize = 15

        let first = PreviewStylesheet.css(using: preferences)
        XCTAssertEqual(PreviewStylesheet.css(using: preferences), first)
        XCTAssertTrue(first.contains("font-size: 15px"), first)

        preferences.previewFontSize = 18
        let resized = PreviewStylesheet.css(using: preferences)
        XCTAssertNotEqual(resized, first)
        XCTAssertTrue(resized.contains("font-size: 18px"), resized)

        preferences.previewFontSize = 15
        XCTAssertEqual(PreviewStylesheet.css(using: preferences), first)
        XCTAssertEqual(
            PreviewStylesheet.StyleSignature(preferences: preferences),
            PreviewStylesheet.StyleSignature(preferences: preferences)
        )
    }

    func testPreviewPageCacheServesIdenticalPageForUnchangedInput() throws {
        let preferences = try makePreferences()
        let context = PreviewContext(
            documentURL: URL(fileURLWithPath: "/tmp/page-cache-vault/Note.md"),
            vaultURL: URL(fileURLWithPath: "/tmp/page-cache-vault", isDirectory: true)
        )
        let document = MarkdownPreprocessor.preprocess("# Title\n\nInline $$x$$ math.", context: context)

        let first = PreviewPageCache.page(for: document, preferences: preferences, compact: false)
        let second = PreviewPageCache.page(for: document, preferences: preferences, compact: false)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("<h1>Title</h1>"), first)
        XCTAssertTrue(first.contains("class=\"math-display\""), first)

        let compact = PreviewPageCache.page(for: document, preferences: preferences, compact: true)
        XCTAssertNotEqual(compact, first)
        XCTAssertTrue(compact.contains("overflow:hidden"), compact)

        preferences.previewFontSize = 20
        let restyled = PreviewPageCache.page(for: document, preferences: preferences, compact: false)
        XCTAssertNotEqual(restyled, first, "A preference the stylesheet reads must miss the cache")
        XCTAssertTrue(restyled.contains("font-size: 20px"), restyled)

        let edited = MarkdownPreprocessor.preprocess("# Title\n\nEdited.", context: context)
        let editedPage = PreviewPageCache.page(for: edited, preferences: preferences, compact: false)
        XCTAssertNotEqual(editedPage, restyled)
        XCTAssertTrue(editedPage.contains("Edited."), editedPage)
    }

    func testPreviewPageCacheDistinguishesSingleSegmentDocumentsSharingSource() throws {
        let preferences = try makePreferences()
        let context = PreviewContext(
            documentURL: URL(fileURLWithPath: "/tmp/page-cache-vault/Note.md"),
            vaultURL: URL(fileURLWithPath: "/tmp/page-cache-vault", isDirectory: true)
        )
        let full = MarkdownPreprocessor.preprocess("First\n\n$$\nx\n$$\n\nSecond", context: context)
        XCTAssertGreaterThanOrEqual(full.segments.count, 1)

        // The embedded preview renders each segment as its own fitted page
        // that shares the parent's `source`; the cache must not conflate them.
        let firstOnly = PreviewDocument(
            source: full.source,
            context: full.context,
            segments: [.markdown("First")],
            requiresHTMLFallback: true
        )
        let secondOnly = PreviewDocument(
            source: full.source,
            context: full.context,
            segments: [.markdown("Second")],
            requiresHTMLFallback: true
        )

        let firstPage = PreviewPageCache.page(for: firstOnly, preferences: preferences, compact: true)
        let secondPage = PreviewPageCache.page(for: secondOnly, preferences: preferences, compact: true)
        XCTAssertNotEqual(firstPage, secondPage)
        XCTAssertTrue(firstPage.contains("<p>First</p>"), firstPage)
        XCTAssertTrue(secondPage.contains("<p>Second</p>"), secondPage)
    }

    func testPreviewPageIsIdenticalForSegmentsRegardlessOfSurroundingNoteSource() throws {
        let preferences = try makePreferences()
        let context = PreviewContext(
            documentURL: URL(fileURLWithPath: "/tmp/page-cache-vault/Note.md"),
            vaultURL: URL(fileURLWithPath: "/tmp/page-cache-vault", isDirectory: true)
        )

        // Two keystrokes elsewhere in the note change the shared `source` but
        // not this segment. Its page must be byte-identical (same cache entry,
        // same CSP nonce) or the web view reloads on every keystroke.
        func fitted(source: String) -> PreviewDocument {
            PreviewDocument(
                source: source,
                context: context,
                segments: [.markdown("Value $$x^2$$ here")],
                requiresHTMLFallback: true
            )
        }

        let first = PreviewPageCache.page(for: fitted(source: "Intro\n\nValue $$x^2$$ here"), preferences: preferences, compact: true)
        let second = PreviewPageCache.page(for: fitted(source: "Intro!\n\nValue $$x^2$$ here"), preferences: preferences, compact: true)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("Value"), first)
    }

    func testStylesheetPageIsDeterministicForAnUnchangedBody() throws {
        let preferences = try makePreferences()
        let body = "<p>Inline <span class=\"math-inline\">x</span></p>"

        let first = PreviewStylesheet.page(body: body, preferences: preferences, compact: true)
        // Not served from any cache: the page is a pure function of its inputs,
        // so an unchanged body never makes the web view reload.
        XCTAssertEqual(first, PreviewStylesheet.page(body: body, preferences: preferences, compact: true))

        let other = PreviewStylesheet.page(body: body + "<p>More</p>", preferences: preferences, compact: true)
        XCTAssertNotEqual(first, other)
        XCTAssertTrue(first.contains("<script nonce=\""), first)
        XCTAssertTrue(first.contains("script-src 'nonce-"), first)
    }

    /// Preferences backed by a throwaway defaults suite so the test never
    /// touches the user's real settings.
    private func makePreferences() throws -> AppPreferences {
        let suiteName = "PreviewRenderingCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return AppPreferences(userDefaults: defaults)
    }
}

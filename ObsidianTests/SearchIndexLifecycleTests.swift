import Foundation
import XCTest

@testable import Obsidian

@MainActor
final class SearchIndexLifecycleTests: XCTestCase {
    func testAdvancedMetadataTracksUnsavedSavedAndExternalChanges() async throws {
        let initialBody = "---\ntags: [draft]\nstatus: active\n---\n# Project\n"
        let fixture = try makeVault(files: [("Project", initialBody)])
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fixture.fileURLs[0])
        let originalSnapshot = workspace.makeSearchEntries()
        XCTAssertEqual(
            ObsidianAdvancedSearchEvaluator.search(originalSnapshot, query: "tag:draft property:status=active").count,
            1
        )

        workspace.text = "---\ntags: [published]\nstatus: done\n---\n# Project\n"
        let editedSnapshot = workspace.makeSearchEntries()
        XCTAssertEqual(
            ObsidianAdvancedSearchEvaluator.search(editedSnapshot, query: "tag:published property:status=done").count,
            1
        )
        XCTAssertTrue(ObsidianAdvancedSearchEvaluator.search(editedSnapshot, query: "tag:draft").isEmpty)
        XCTAssertEqual(ObsidianAdvancedSearchEvaluator.search(originalSnapshot, query: "tag:draft").count, 1)

        workspace.saveCurrentFile()
        XCTAssertEqual(
            ObsidianAdvancedSearchEvaluator.search(workspace.makeSearchEntries(), query: "tag:published").count,
            1
        )

        try "---\ntags: [external]\nstatus: archived\n---\n# Project\n".write(
            to: fixture.fileURLs[0], atomically: true, encoding: .utf8
        )
        workspace.handleExternalChanges([.changed(fixture.fileURLs[0])])
        for _ in 0..<200 where workspace.isLoadingSnapshot {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(workspace.isLoadingSnapshot)
        let externalSnapshot = workspace.makeSearchEntries()
        XCTAssertEqual(
            ObsidianAdvancedSearchEvaluator.search(externalSnapshot, query: "tag:external property:status=archived").count,
            1
        )
        XCTAssertTrue(ObsidianAdvancedSearchEvaluator.search(externalSnapshot, query: "tag:published").isEmpty)
    }

    func testIndexIncrementallyReusesUnchangedBodiesAcrossAddChangeRenameAndDelete() throws {
        let fixture = try makeVault(files: [
            ("Alpha", "# Alpha\n\nfirst body"),
            ("Beta", "# Beta\n\nsecond body")
        ])
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        let initialEntries = workspace.makeSearchEntries()
        let alphaStorage = try XCTUnwrap(initialEntries.first(where: { $0.title == "Alpha" })?.bodyStorage)
        let initialRevision = workspace.searchIndexRevision

        let gammaURL = fixture.vaultURL.appendingPathComponent("Gamma.md")
        try "# Gamma\n\nthird body".write(to: gammaURL, atomically: true, encoding: .utf8)
        workspace.refreshFiles()

        XCTAssertGreaterThan(workspace.searchIndexRevision, initialRevision)
        XCTAssertEqual(workspace.makeSearchEntries().count, 3)
        XCTAssertTrue(
            try XCTUnwrap(workspace.makeSearchEntries().first(where: { $0.title == "Alpha" })?.bodyStorage)
                === alphaStorage
        )

        try "# Beta\n\nchanged searchable body".write(
            to: fixture.fileURLs[1],
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(30)],
            ofItemAtPath: fixture.fileURLs[1].path
        )
        workspace.refreshFiles()
        XCTAssertEqual(Workspace.search(workspace.makeSearchEntries(), query: "searchable").map(\.title), ["Beta"])

        let renamedURL = try workspace.renameItem(gammaURL, to: "Delta")
        let renamedEntries = workspace.makeSearchEntries()
        XCTAssertFalse(renamedEntries.contains(where: { $0.url == gammaURL }))
        XCTAssertTrue(renamedEntries.contains(where: { $0.url == renamedURL }))

        workspace.deleteItem(renamedURL)
        XCTAssertFalse(workspace.makeSearchEntries().contains(where: { $0.url == renamedURL }))
        XCTAssertEqual(workspace.makeSearchEntries().count, 2)
    }

    func testSearchSnapshotRemainsSafeDuringSimultaneousRename() async throws {
        let fixture = try makeVault(files: [
            ("Old", "# Old\n\nconcurrent needle"),
            ("Other", "# Other\n\nbody")
        ])
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        let snapshot = workspace.makeSearchEntries()

        let inFlightSearch = Task.detached {
            (0..<100).flatMap { _ in Workspace.search(snapshot, query: "needle") }
        }
        let renamedURL = try workspace.renameItem(fixture.fileURLs[0], to: "Renamed")
        let oldSnapshotResults = await inFlightSearch.value

        XCTAssertFalse(oldSnapshotResults.isEmpty)
        XCTAssertTrue(oldSnapshotResults.allSatisfy { $0.url == fixture.fileURLs[0] })
        XCTAssertEqual(
            Workspace.search(workspace.makeSearchEntries(), query: "needle").map(\.url),
            [renamedURL]
        )
    }

    func testICloudConflictCopiesRemainDistinctSearchableNotes() throws {
        let fixture = try makeVault(files: [
            ("Plan", "# Plan\n\ncanonical copy"),
            ("Plan (Erlin's conflicted copy 2026-08-01)", "# Plan conflict\n\nconflict-only-token")
        ])
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        let results = Workspace.search(workspace.makeSearchEntries(), query: "conflict-only-token")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.url, fixture.fileURLs[1])
        XCTAssertEqual(workspace.makeSearchEntries().count, 2)
    }

    func testLatestConcurrentVaultRefreshWinsWithoutDroppingChanges() async throws {
        let fixture = try makeVault(files: [
            ("First", "# First\n\nold token"),
            ("DeleteMe", "# DeleteMe\n\nremove me")
        ])
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        try "# First\n\nnew token".write(to: fixture.fileURLs[0], atomically: true, encoding: .utf8)
        // Presenter events must invalidate by path even when a provider keeps
        // the previous timestamp, as some iCloud conflict resolutions do.
        let originalDate = workspace.files.first(where: { $0.url == fixture.fileURLs[0] })?.modificationDate
        if let originalDate {
            try FileManager.default.setAttributes(
                [.modificationDate: originalDate],
                ofItemAtPath: fixture.fileURLs[0].path
            )
        }
        workspace.handleExternalChanges([.changed(fixture.fileURLs[0])])

        let addedURL = fixture.vaultURL.appendingPathComponent("Added.md")
        try "# Added\n\nadded token".write(to: addedURL, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: fixture.fileURLs[1])
        workspace.handleExternalChanges([
            .changed(addedURL),
            .changed(fixture.fileURLs[1])
        ])

        for _ in 0..<200 {
            let entries = workspace.makeSearchEntries()
            if !workspace.isLoadingSnapshot,
               Workspace.search(entries, query: "new token").count == 1,
               Workspace.search(entries, query: "added token").count == 1,
               !entries.contains(where: { $0.url == fixture.fileURLs[1] }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let finalEntries = workspace.makeSearchEntries()
        XCTAssertEqual(Workspace.search(finalEntries, query: "new token").count, 1)
        XCTAssertEqual(Workspace.search(finalEntries, query: "added token").count, 1)
        XCTAssertFalse(finalEntries.contains(where: { $0.url == fixture.fileURLs[1] }))
    }

    func testSaveReplacesOnlyTheSavedNoteRecordInPlace() throws {
        let fixture = try makeVault(files: [
            ("Alpha", "# Alpha\n\nfirst body"),
            ("Beta", "# Beta\n\nsecond body")
        ])
        let workspace = try makeWorkspace()
        workspace.sortOrder = .byName
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fixture.fileURLs[0])

        let initialEntries = workspace.makeSearchEntries()
        let alphaStorage = try XCTUnwrap(initialEntries.first(where: { $0.title == "Alpha" })?.bodyStorage)
        let betaStorage = try XCTUnwrap(initialEntries.first(where: { $0.title == "Beta" })?.bodyStorage)
        let initialRevision = workspace.searchIndexRevision

        workspace.text = "# Alpha\n\nedited needle body"
        XCTAssertEqual(workspace.saveCurrentFile(), .saved)

        let savedEntries = workspace.makeSearchEntries()
        XCTAssertGreaterThan(workspace.searchIndexRevision, initialRevision)
        XCTAssertEqual(savedEntries.map(\.title), ["Alpha", "Beta"])
        XCTAssertFalse(try XCTUnwrap(savedEntries.first(where: { $0.title == "Alpha" })?.bodyStorage) === alphaStorage)
        XCTAssertTrue(try XCTUnwrap(savedEntries.first(where: { $0.title == "Beta" })?.bodyStorage) === betaStorage)
        XCTAssertEqual(Workspace.search(savedEntries, query: "needle").map(\.title), ["Alpha"])
        XCTAssertTrue(Workspace.search(savedEntries, query: "first body").isEmpty)
        XCTAssertEqual(workspace.files.map(\.name), ["Alpha.md", "Beta.md"])
    }

    func testSortOrderChangeResortsInMemoryWithoutWalkingDisk() throws {
        let fixture = try makeVault(files: [
            ("Alpha", "# Alpha\n\nolder"),
            ("Beta", "# Beta\n\nnewer")
        ])
        let folderURL = fixture.vaultURL.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let oneURL = folderURL.appendingPathComponent("One.md")
        let twoURL = folderURL.appendingPathComponent("Two.md")
        try "# One\n\nolder".write(to: oneURL, atomically: true, encoding: .utf8)
        try "# Two\n\nnewer".write(to: twoURL, atomically: true, encoding: .utf8)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        for (url, offset) in [(fixture.fileURLs[0], 0.0), (oneURL, 10.0), (fixture.fileURLs[1], 60.0), (twoURL, 90.0)] {
            try FileManager.default.setAttributes(
                [.modificationDate: baseDate.addingTimeInterval(offset)],
                ofItemAtPath: url.path
            )
        }

        let workspace = try makeWorkspace()
        workspace.sortOrder = .byName
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertEqual(workspace.files.map(\.name), ["Alpha.md", "Beta.md", "One.md", "Two.md"])
        XCTAssertEqual(workspace.sidebarNodes.map(\.name), ["Nested", "Alpha", "Beta"])
        XCTAssertEqual(workspace.sidebarNodes[0].children.map(\.name), ["One", "Two"])

        // A file that appears on disk after the refresh must stay invisible:
        // a sort change only reorders what is already loaded.
        try "# Gamma".write(
            to: fixture.vaultURL.appendingPathComponent("Gamma.md"),
            atomically: true,
            encoding: .utf8
        )
        let revisionBeforeSort = workspace.searchIndexRevision

        workspace.sortOrder = .byDate

        XCTAssertFalse(workspace.isLoadingSnapshot)
        XCTAssertEqual(workspace.files.map(\.name), ["Two.md", "Beta.md", "One.md", "Alpha.md"])
        XCTAssertEqual(workspace.sidebarNodes.map(\.name), ["Nested", "Beta", "Alpha"])
        XCTAssertEqual(workspace.sidebarNodes[0].children.map(\.name), ["Two", "One"])
        XCTAssertFalse(workspace.files.contains(where: { $0.name == "Gamma.md" }))
        XCTAssertGreaterThan(workspace.searchIndexRevision, revisionBeforeSort)
        XCTAssertEqual(workspace.makeSearchEntries().map(\.title), ["Two", "Beta", "One", "Alpha"])

        workspace.sortOrder = .byName
        XCTAssertEqual(workspace.files.map(\.name), ["Alpha.md", "Beta.md", "One.md", "Two.md"])
        XCTAssertEqual(workspace.sidebarNodes[0].children.map(\.name), ["One", "Two"])
    }

    func testFileLookupsResolveSymlinkedURLsWithoutRescanning() throws {
        let fixture = try makeVault(files: [("Alpha", "# Alpha Heading\n\nbody")])
        let linkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: fixture.vaultURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: linkURL) }
        let linkedFileURL = linkURL.appendingPathComponent("Alpha.md")

        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        let file = try XCTUnwrap(workspace.fileItem(for: linkedFileURL))
        XCTAssertEqual(file.url, fixture.fileURLs[0])
        XCTAssertEqual(file.canonicalPath, FileItem.canonicalPath(for: fixture.fileURLs[0]))
        XCTAssertEqual(workspace.canonicalPath(for: linkedFileURL), file.canonicalPath)
        XCTAssertEqual(workspace.title(for: file), "Alpha Heading")
        XCTAssertNil(workspace.fileItem(for: linkURL.appendingPathComponent("Missing.md")))

        XCTAssertTrue(workspace.selectFile(linkedFileURL))
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, fixture.fileURLs[0].standardizedFileURL)
        XCTAssertEqual(workspace.selectedFileName, "Alpha Heading")

        workspace.text = "# Live Title\n\nbody"
        XCTAssertEqual(workspace.title(for: file), "Live Title")
        XCTAssertEqual(workspace.noteBody(for: linkedFileURL), "# Live Title\n\nbody")
        XCTAssertEqual(workspace.saveCurrentFile(), .saved)
        XCTAssertEqual(workspace.fileItem(for: linkedFileURL)?.noteTitle, "Live Title")
        XCTAssertEqual(Workspace.search(workspace.makeSearchEntries(), query: "live title").map(\.title), ["Live Title"])
    }

    func testParallelSearchMatchesSequentialResultsExactly() {
        let entries = (0..<1_500).map { index -> NoteSearchEntry in
            let title: String
            switch index % 7 {
            case 0: title = "needle"
            case 1: title = "needle prefix \(index)"
            case 2: title = "contains needle \(index)"
            case 3: title = "Haystack \(index)"
            default: title = "Note \(index)"
            }
            let body = index % 5 == 0 ? "body with needle \(index)" : "plain body \(index)"
            let url = URL(fileURLWithPath: "/parallel/\(index).md")
            return NoteSearchEntry(
                id: url,
                url: url,
                title: title,
                relativePath: "\(index).md",
                body: body,
                foldedTitle: Workspace.foldedForSearch(title),
                foldedTitleHaystack: Workspace.foldedForSearch("\(title)\n\(index).md"),
                searchMetadata: nil
            )
        }

        for query in ["needle", "NEEDLE PREFIX", "haystack 1", "zzz-absent"] {
            let sequential = Workspace.search(entries, query: query, maximumConcurrency: 1)
            let parallel = Workspace.search(entries, query: query, maximumConcurrency: 8)
            let defaulted = Workspace.search(entries, query: query)
            XCTAssertEqual(parallel.map(\.id), sequential.map(\.id), query)
            XCTAssertEqual(parallel.map(\.isBodyMatch), sequential.map(\.isBodyMatch), query)
            XCTAssertEqual(defaulted.map(\.id), sequential.map(\.id), query)
        }
        XCTAssertEqual(Workspace.search(entries, query: "needle", maximumConcurrency: 8).first?.title, "needle")
    }

    func testNoteSearchIndexUpdateReplacesOnlyExistingRecords() throws {
        func makeEntry(_ name: String, body: String) -> NoteSearchEntry {
            let url = URL(fileURLWithPath: "/index/\(name).md")
            return NoteSearchEntry(
                id: url,
                url: url,
                title: name,
                relativePath: "\(name).md",
                body: body,
                foldedTitle: Workspace.foldedForSearch(name),
                foldedTitleHaystack: Workspace.foldedForSearch(name)
            )
        }

        var index = NoteSearchIndex()
        let alpha = makeEntry("Alpha", body: "one")
        let beta = makeEntry("Beta", body: "two")
        XCTAssertTrue(index.reconcile([alpha, beta]))
        XCTAssertNil(index.entry(forPath: "/index/Gamma.md"))
        XCTAssertTrue(try XCTUnwrap(index.entry(forPath: "/index/Alpha.md")).bodyStorage === alpha.bodyStorage)

        let replacement = makeEntry("Alpha", body: "changed")
        XCTAssertTrue(index.update(replacement))
        XCTAssertFalse(index.update(replacement), "An identical record is not a change")
        XCTAssertFalse(index.update(makeEntry("Gamma", body: "unknown")), "Unknown paths are left to reconcile")
        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index.entries.map(\.title), ["Alpha", "Beta"])
        XCTAssertTrue(index.entries[0].bodyStorage === replacement.bodyStorage)
        XCTAssertTrue(index.entries[1].bodyStorage === beta.bodyStorage)
    }

    func testSnapshotIndexesNestedFoldersAndLegacyEncodings() throws {
        let fixture = try makeVault(files: [("Alpha", "# Alpha\n\nroot note")])
        let folderURL = fixture.vaultURL.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try "# Beta\n\nnested needle".write(
            to: folderURL.appendingPathComponent("Beta.md"),
            atomically: true,
            encoding: .utf8
        )
        var latin1 = Array("# Caf".utf8)
        latin1.append(0xE9)
        try Data(latin1).write(to: folderURL.appendingPathComponent("Latin1.md"), options: .atomic)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: folderURL.appendingPathComponent("photo.png"), options: .atomic)

        let workspace = try makeWorkspace()
        workspace.sortOrder = .byName
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        XCTAssertEqual(workspace.files.map(\.name), ["Alpha.md", "Beta.md", "Latin1.md"])
        XCTAssertEqual(workspace.files.map(\.noteTitle), ["Alpha", "Beta", "Café"])
        XCTAssertEqual(workspace.sidebarNodes.map(\.name), ["Nested", "Alpha"])
        XCTAssertEqual(workspace.sidebarNodes[0].children.map(\.name), ["Beta", "Latin1", "photo.png"])
        XCTAssertEqual(workspace.assetLookupSnapshot["photo.png"]?.count, 1)

        let entries = workspace.makeSearchEntries()
        XCTAssertEqual(Workspace.search(entries, query: "nested needle").map(\.title), ["Beta"])
        XCTAssertEqual(Workspace.search(entries, query: "cafe").map(\.title), ["Café"])
        XCTAssertEqual(workspace.relativePath(for: workspace.files[1]), "Nested/Beta.md")
    }

    func testMoveResolvesAliasLinksFromCachedMetadata() throws {
        let fixture = try makeVault(files: [
            ("Old", "---\naliases: [Legacy]\n---\n# Old"),
            ("Index", "See [[Legacy]] and [[Old]].")
        ])
        let folderURL = fixture.vaultURL.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        // Neither note is open, so the aliases used to resolve `[[Legacy]]`
        // must come from the cached, already parsed note metadata.
        XCTAssertTrue(workspace.moveItem(fixture.fileURLs[0], toFolder: folderURL))

        let updatedIndex = try String(contentsOf: fixture.fileURLs[1], encoding: .utf8)
        XCTAssertFalse(updatedIndex.contains("[[Legacy]]"))
        XCTAssertTrue(updatedIndex.contains("[[Old]]"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("Old.md").path))
    }

    // MARK: - External change coalescing

    func testChangeBatchCoalescesChangedPathsAndKeepsMovesInOrder() {
        let first = URL(fileURLWithPath: "/vault/First.md")
        let second = URL(fileURLWithPath: "/vault/Second.md")
        let third = URL(fileURLWithPath: "/vault/Third.md")
        var batch = VaultFileChangeBatch()

        batch.append(.changed(first))
        batch.append(.moved(from: first, to: second))
        batch.append(.changed(URL(fileURLWithPath: "/vault/./First.md")))
        batch.append(contentsOf: [.changed(second), .changed(second), .moved(from: second, to: third)])
        batch.append(.moved(from: first, to: second))

        XCTAssertEqual(batch.changes, [
            .changed(first),
            .moved(from: first, to: second),
            .changed(second),
            .moved(from: second, to: third),
            .moved(from: first, to: second)
        ])
        XCTAssertEqual(batch.takeAll().count, 5)
        XCTAssertTrue(batch.isEmpty)

        // Taking the batch also resets coalescing for the next one.
        batch.append(.changed(first))
        XCTAssertEqual(batch.changes, [.changed(first)])
    }

    func testPresenterDeliversQueuedCallbacksAsOneCoalescedBatch() {
        let vaultURL = URL(fileURLWithPath: "/presenter-vault", isDirectory: true)
        let recorder = VaultChangeRecorder()
        let presenter = VaultFilePresenter(vaultURL: vaultURL) { recorder.record($0) }
        let queue = presenter.presentedItemOperationQueue
        let first = vaultURL.appendingPathComponent("First.md")
        let second = vaultURL.appendingPathComponent("Second.md")

        // Holding the queue stands in for a burst of callbacks already queued.
        queue.isSuspended = true
        presenter.presentedSubitemDidChange(at: first)
        presenter.presentedSubitemDidChange(at: first)
        presenter.presentedSubitem(at: first, didMoveTo: second)
        presenter.presentedSubitemDidChange(at: second)
        XCTAssertTrue(recorder.batches.isEmpty)

        queue.isSuspended = false
        queue.waitUntilAllOperationsAreFinished()
        XCTAssertEqual(recorder.batches, [[.changed(first), .moved(from: first, to: second), .changed(second)]])
    }

    func testPresenterHandsOnFullBatchesWithoutWaitingForTheBurstToEnd() {
        let vaultURL = URL(fileURLWithPath: "/presenter-vault", isDirectory: true)
        let recorder = VaultChangeRecorder()
        let presenter = VaultFilePresenter(vaultURL: vaultURL) { recorder.record($0) }
        let queue = presenter.presentedItemOperationQueue
        let threshold = VaultFileChangeBatch.leadingFlushThreshold
        let changeCount = threshold * 2 + 10

        queue.isSuspended = true
        for index in 0..<changeCount {
            presenter.presentedSubitemDidChange(at: vaultURL.appendingPathComponent("Note \(index).md"))
        }
        XCTAssertEqual(recorder.batches.map(\.count), [threshold, threshold])

        queue.isSuspended = false
        queue.waitUntilAllOperationsAreFinished()
        XCTAssertEqual(recorder.batches.map(\.count), [threshold, threshold, 10])
        XCTAssertEqual(
            recorder.batches.flatMap { $0 },
            (0..<changeCount).map { VaultFileChange.changed(vaultURL.appendingPathComponent("Note \($0).md")) }
        )
    }

    func testExternalChangesWaitForTheDebounceUnlessTheBatchOverflows() async throws {
        let fixture = try makeVault(files: [("Note", "original")])
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[0]))

        // Repeated events for one path coalesce into a single pending change,
        // which waits for the trailing debounce instead of being handled inline.
        try "first external".write(to: fixture.fileURLs[0], atomically: true, encoding: .utf8)
        workspace.scheduleExternalChangeHandling(
            Array(repeating: .changed(fixture.fileURLs[0]), count: 1_000)
        )
        XCTAssertEqual(workspace.text, "original")
        for _ in 0..<500 where workspace.text != "first external" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(workspace.text, "first external")

        // More distinct paths than the threshold are handled immediately.
        try "second external".write(to: fixture.fileURLs[0], atomically: true, encoding: .utf8)
        let burst = (0...VaultFileChangeBatch.leadingFlushThreshold).map {
            VaultFileChange.changed(fixture.vaultURL.appendingPathComponent("Burst \($0).md"))
        }
        workspace.scheduleExternalChangeHandling(burst)
        XCTAssertEqual(workspace.text, "second external")
        XCTAssertTrue(workspace.isLoadingSnapshot)
    }

    func testFolderEventEvictsCachedNotesInsideIt() async throws {
        let fixture = try makeVault(files: [("Root", "# Root\n\nroot body")])
        let folderURL = fixture.vaultURL.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let nestedURL = folderURL.appendingPathComponent("Deep.md")
        try "# Deep\n\nold nested token".write(to: nestedURL, atomically: true, encoding: .utf8)

        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        let originalDate = try XCTUnwrap(workspace.files.first(where: { $0.name == "Deep.md" })?.modificationDate)

        // Providers can replace content while keeping the timestamp, so only
        // the folder event can tell the snapshot to re-read the nested note.
        try "# Deep\n\nnew nested token".write(to: nestedURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: nestedURL.path)
        workspace.handleExternalChanges([.changed(folderURL)])

        for _ in 0..<500 {
            let entries = workspace.makeSearchEntries()
            if !workspace.isLoadingSnapshot, Workspace.search(entries, query: "new nested token").count == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let entries = workspace.makeSearchEntries()
        XCTAssertEqual(Workspace.search(entries, query: "new nested token").map(\.title), ["Deep"])
        XCTAssertTrue(Workspace.search(entries, query: "old nested token").isEmpty)
        XCTAssertEqual(Workspace.search(entries, query: "root body").map(\.title), ["Root"])
    }

    private func makeVault(files: [(name: String, content: String)]) throws -> (vaultURL: URL, fileURLs: [URL]) {
        let vaultURL = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        let fileURLs = try files.map { file -> URL in
            let fileURL = vaultURL.appendingPathComponent(file.name).appendingPathExtension("md")
            try file.content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL.standardizedFileURL
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: vaultURL)
        }
        return (vaultURL, fileURLs)
    }

    /// A workspace whose persisted state lives in a throwaway defaults suite
    /// and recovery directory, never in the app's real ones.
    private func makeWorkspace() throws -> Workspace {
        let suiteName = "SearchIndexLifecycleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchIndexLifecycleTests-Recovery-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: recoveryURL)
        }
        return Workspace(
            preferences: AppPreferences(userDefaults: defaults),
            recoveryStore: RecoveryStore(directoryURL: recoveryURL),
            userDefaults: defaults
        )
    }
}

/// Collects presenter deliveries, which arrive on the presenter queue.
private final class VaultChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedBatches: [[VaultFileChange]] = []

    func record(_ changes: [VaultFileChange]) {
        lock.lock()
        recordedBatches.append(changes)
        lock.unlock()
    }

    var batches: [[VaultFileChange]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedBatches
    }
}

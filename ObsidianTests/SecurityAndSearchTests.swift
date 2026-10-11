import Foundation
import XCTest

@testable import Obsidian

@MainActor
final class SecurityAndSearchTests: XCTestCase {

    // MARK: - HTML preview sanitization (C1 regression)

    /// Renders `markdown` through the HTML preview path. A trailing mermaid
    /// block forces the document into HTML render mode so the renderer (the XSS
    /// sink) is actually exercised.
    private func renderHTML(_ markdown: String) -> String {
        let payload = """
        \(markdown)

        ```mermaid
        graph TD
        A-->B
        ```
        """
        let context = PreviewContext(documentURL: nil, vaultURL: nil)
        let document = MarkdownPreprocessor.preprocess(payload, context: context)
        return HTMLPreviewRenderer.render(document: document)
    }

    func testRawHTMLIframeIsNeutralized() {
        // Single-line iframe containing "://" — the exact vector the old
        // hand-rolled escaper let through via its autolink whitelist.
        let html = renderHTML("<iframe src=\"https://evil.example\"></iframe>")
        XCTAssertFalse(html.contains("<iframe"), "Raw <iframe> must not survive into preview HTML; got: \(html)")
    }

    func testMultiLineRawHTMLEventHandlerIsNeutralized() {
        // Tag split across two lines — defeated the old line-scoped escaper.
        // The `<` must be escaped so no live <img> tag (and thus no live
        // onerror handler) reaches the DOM; the text may still appear inert.
        let html = renderHTML("<img src=x\nonerror=alert(document.domain)>")
        XCTAssertFalse(html.contains("<img"), "Raw <img> tag must not survive as live HTML; got: \(html)")
        XCTAssertTrue(html.contains("&lt;img"), "The opening bracket should be escaped; got: \(html)")
    }

    func testRawScriptTagIsNeutralized() {
        let html = renderHTML("<script>alert('xss')</script>")
        XCTAssertFalse(html.contains("<script>alert"), "Raw <script> must not survive; got: \(html)")
    }

    func testJavascriptLinkSchemeIsNeutralized() {
        let html = renderHTML("[click me](javascript:alert(1))")
        XCTAssertFalse(html.contains("javascript:"), "javascript: URL must be stripped; got: \(html)")
    }

    func testHTTPAutolinkStillWorks() {
        // Safe mode must not break legitimate angle autolinks.
        let html = renderHTML("<https://example.com>")
        XCTAssertTrue(html.contains("href=\"https://example.com\""), "Autolink should still render; got: \(html)")
    }

    // MARK: - Full-text search

    func testSearchMatchesTitleAndBody() throws {
        let fixture = try makeVault(files: [
            ("Apple", "# Apple\n\nA crunchy fruit"),
            ("Banana", "# Banana\n\nA yellow fruit")
        ])
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        let entries = workspace.makeSearchEntries()

        let titleHit = Workspace.search(entries, query: "banana")
        XCTAssertEqual(titleHit.count, 1)
        XCTAssertEqual(titleHit.first?.url.standardizedFileURL, fixture.fileURLs[1].standardizedFileURL)
        XCTAssertFalse(titleHit.first?.isBodyMatch ?? true)

        let bodyHit = Workspace.search(entries, query: "yellow")
        XCTAssertEqual(bodyHit.count, 1)
        XCTAssertEqual(bodyHit.first?.url.standardizedFileURL, fixture.fileURLs[1].standardizedFileURL)
        XCTAssertTrue(bodyHit.first?.isBodyMatch ?? false)
        XCTAssertEqual(bodyHit.first?.subtitle, "A yellow fruit")

        XCTAssertEqual(Workspace.search(entries, query: "").count, entries.count)
        XCTAssertTrue(Workspace.search(entries, query: "zzz-nomatch").isEmpty)
    }

    func testSearchIsCaseAndDiacriticInsensitive() throws {
        let decomposedCafe = "Cafe\u{301}"
        let fixture = try makeVault(files: [
            ("Cafe", "# \(decomposedCafe)\n\nEspresso résumé"),
            ("Istanbul", "# İstanbul\n\nBosphorus"),
            ("Igdir", "# IĞDIR\n\nTurkish casing"),
            ("Angstrom", "# A\u{30A}ngström\n\nCanonical normalization")
        ])
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        let entries = workspace.makeSearchEntries()

        XCTAssertEqual(Workspace.search(entries, query: "cafe").count, 1)
        XCTAssertEqual(Workspace.search(entries, query: "RESUME").count, 1)
        XCTAssertEqual(Workspace.search(entries, query: "istanbul").count, 1)
        XCTAssertEqual(Workspace.search(entries, query: "ığdır").map(\.title), ["IĞDIR"])
        XCTAssertEqual(Workspace.search(entries, query: "angstrom").map(\.title), ["Ångström"])
    }

    func testInvalidOrExpiredBookmarkIsRemovedInsteadOfRetriedForever() throws {
        let defaults = try makeUserDefaults()
        defaults.set(Data("expired-security-scope".utf8), forKey: "vaultBookmark")

        let workspace = try makeWorkspace(userDefaults: defaults)

        XCTAssertNil(workspace.vaultURL)
        XCTAssertNil(defaults.data(forKey: "vaultBookmark"))
    }

    func testWorkspacePersistsVaultStateInItsInjectedDefaults() async throws {
        let fixture = try makeVault(files: [
            ("Alpha", "# Alpha"),
            ("Beta", "# Beta")
        ])
        let defaults = try makeUserDefaults()
        let workspace = try makeWorkspace(userDefaults: defaults)
        workspace.vaultURL = fixture.vaultURL
        workspace.sortOrder = .byName
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[1]))

        let vaultPath = fixture.vaultURL.standardizedFileURL.path
        XCTAssertEqual(defaults.string(forKey: "sortOrder::" + vaultPath), SortOrder.byName.rawValue)
        XCTAssertEqual(defaults.string(forKey: "selectedFile::" + vaultPath), fixture.fileURLs[1].standardizedFileURL.path)

        // A second workspace on the same defaults restores the vault's order
        // and, once its snapshot lands, the selected note.
        let restoredWorkspace = try makeWorkspace(userDefaults: defaults)
        XCTAssertTrue(restoredWorkspace.openVault(fixture.vaultURL))
        XCTAssertEqual(restoredWorkspace.sortOrder, .byName)
        for _ in 0..<500 where restoredWorkspace.isLoadingSnapshot {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(restoredWorkspace.isLoadingSnapshot)
        XCTAssertEqual(
            restoredWorkspace.selectedFileURL?.standardizedFileURL,
            fixture.fileURLs[1].standardizedFileURL
        )
    }

    func testSearchSnippetCentersOnMatch() throws {
        let prefix = String(repeating: "lorem ipsum ", count: 20)
        let suffix = String(repeating: " dolor sit", count: 20)
        let body = prefix + "NEEDLE" + suffix

        let snippet = try XCTUnwrap(Workspace.searchSnippet(in: body, query: "needle"))
        XCTAssertTrue(snippet.contains("NEEDLE"))
        XCTAssertTrue(snippet.hasPrefix("\u{2026}"))
        XCTAssertTrue(snippet.hasSuffix("\u{2026}"))
        XCTAssertLessThanOrEqual(snippet.count, 142)
    }

    func testBodyResultMaterializesAndCachesSnippetOnlyOnDemand() throws {
        let fixture = try makeVault(files: [("Lazy", "# Lazy\n\nbody-only-needle")])
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        let result = try XCTUnwrap(Workspace.search(workspace.makeSearchEntries(), query: "needle").first)
        let source = try XCTUnwrap(result.snippetSource)
        XCTAssertFalse(source.isMaterialized)

        XCTAssertEqual(result.subtitle, "body-only-needle")
        XCTAssertTrue(source.isMaterialized)
        XCTAssertEqual(result.subtitle, "body-only-needle")
    }

    // MARK: - External-change conflict (H1) and write-error surfacing (H2)

    func testExternalChangeProducesConflictInsteadOfClobbering() throws {
        let fixture = try makeVault(files: [("Note", "# Note\n\noriginal")])
        let fileURL = fixture.fileURLs[0]
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fileURL)

        // User edits in the editor…
        workspace.text = "# Note\n\nmy local edits"

        // …meanwhile another process rewrites the file with a newer timestamp.
        let externalContent = "# Note\n\nchanged on disk by another app"
        try Data(externalContent.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: fileURL.path
        )

        workspace.saveCurrentFile()

        // The external edits must NOT be clobbered, and a conflict surfaced.
        XCTAssertNotNil(workspace.saveConflict)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), externalContent)

        // Resolving in favor of the local buffer writes it through.
        workspace.resolveSaveConflictKeepingMine()
        XCTAssertNil(workspace.saveConflict)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "# Note\n\nmy local edits")
    }

    func testKeepMyVersionUsesEditsTypedDuringConflictAlert() throws {
        let fixture = try makeVault(files: [("Note", "# Note\n\noriginal")])
        let fileURL = fixture.fileURLs[0]
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fileURL)

        workspace.text = "# Note\n\nmy local edits"
        let externalContent = "# Note\n\nchanged on disk by another app"
        try Data(externalContent.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: fileURL.path
        )
        workspace.saveCurrentFile()
        XCTAssertNotNil(workspace.saveConflict)

        // Further typing while the conflict alert is open must still be kept.
        workspace.text = "# Note\n\nedits after conflict alert"
        workspace.resolveSaveConflictKeepingMine()

        XCTAssertNil(workspace.saveConflict)
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "# Note\n\nedits after conflict alert"
        )
        XCTAssertFalse(workspace.hasUnsavedChanges)
    }

    func testReloadFromDiskAdoptsExternalContent() throws {
        let fixture = try makeVault(files: [("Note", "# Note\n\noriginal")])
        let fileURL = fixture.fileURLs[0]
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fileURL)
        workspace.text = "# Note\n\nmy local edits"

        let externalContent = "# Note\n\nexternal wins"
        try Data(externalContent.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: fileURL.path
        )
        workspace.saveCurrentFile()
        XCTAssertNotNil(workspace.saveConflict)

        workspace.resolveSaveConflictUsingDisk()
        XCTAssertNil(workspace.saveConflict)
        XCTAssertEqual(workspace.text, externalContent)
    }

    // MARK: - Non-UTF-8 decoding (M12)

    func testNonUTF8FileIsNotReadAsEmpty() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: vaultURL)
        }
        let fileURL = vaultURL.appendingPathComponent("Latin1.md").standardizedFileURL
        // "# Café" with the é encoded as ISO Latin-1 (0xE9) — invalid UTF-8.
        var bytes = Array("# Caf".utf8)
        bytes.append(0xE9)
        try Data(bytes).write(to: fileURL, options: .atomic)

        let workspace = try makeWorkspace()
        workspace.vaultURL = vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fileURL)

        XCTAssertFalse(workspace.text.isEmpty, "Non-UTF-8 file must not load as empty (would clobber on save)")
        XCTAssertTrue(workspace.text.contains("Caf"))
    }

    // MARK: - Document safety and crash recovery

    func testOpeningFrontmatterNotePreservesBytesAndDoesNotInsertHeading() throws {
        let original = """
        ---
        title: Project Atlas
        aliases:
          - Atlas
        tags: [work, active]
        ---

        Body without an H1.
        """
        let fixture = try makeVault(files: [("Atlas", original)])
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[0]))

        XCTAssertEqual(workspace.text, original)
        XCTAssertEqual(try String(contentsOf: fixture.fileURLs[0], encoding: .utf8), original)
        XCTAssertEqual(workspace.saveCurrentFile(), .noChanges)
    }

    func testReadFailureKeepsCurrentSelectionAndBuffer() throws {
        let fixture = try makeVault(files: [("Current", "Current body")])
        let unreadableURL = fixture.vaultURL.appendingPathComponent("Unreadable.md", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadableURL, withIntermediateDirectories: false)

        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[0]))

        XCTAssertFalse(workspace.selectFile(unreadableURL))
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, fixture.fileURLs[0].standardizedFileURL)
        XCTAssertEqual(workspace.text, "Current body")
        XCTAssertNotNil(workspace.saveError)
    }

    func testFailedSaveBlocksNoteAndVaultSwitchAndKeepsDirtyText() throws {
        let fixture = try makeVault(files: [
            ("First", "first on disk"),
            ("Second", "second on disk")
        ])
        let otherVault = try makeVault(files: [("Other", "other vault")])
        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: recoveryURL) }

        let workspace = try makeWorkspace(recoveryStore: RecoveryStore(directoryURL: recoveryURL))
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[0]))
        workspace.text = "unsaved text that must survive"

        // Simulate an unavailable iCloud item after it was opened.
        try FileManager.default.removeItem(at: fixture.fileURLs[0])

        let saveResult = workspace.saveCurrentFile()
        guard case .failed(let message) = saveResult else {
            return XCTFail("Expected actionable save failure, got \(saveResult)")
        }
        XCTAssertTrue(message.contains("recovery"))
        XCTAssertNotNil(workspace.recoveryDraft(for: fixture.fileURLs[0]))

        XCTAssertFalse(workspace.selectFile(fixture.fileURLs[1]))
        XCTAssertFalse(workspace.openVault(otherVault.vaultURL))
        XCTAssertEqual(workspace.vaultURL?.standardizedFileURL, fixture.vaultURL.standardizedFileURL)
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, fixture.fileURLs[0].standardizedFileURL)
        XCTAssertEqual(workspace.text, "unsaved text that must survive")
        XCTAssertTrue(workspace.hasUnsavedChanges)
    }

    func testFailedSaveDoesNotClaimRecoveryWhenRecoveryWriteFails() throws {
        let fixture = try makeVault(files: [("Note", "base")])
        let blockedRecoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: blockedRecoveryURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: blockedRecoveryURL) }

        let workspace = try makeWorkspace(recoveryStore: RecoveryStore(directoryURL: blockedRecoveryURL))
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[0]))
        workspace.text = "unsaved"
        try FileManager.default.removeItem(at: fixture.fileURLs[0])

        guard case .failed(let message) = workspace.saveCurrentFile() else {
            return XCTFail("Expected the unavailable note save to fail")
        }
        XCTAssertTrue(message.contains("recovery could not be written"))
        XCTAssertNil(workspace.recoveryDraft(for: fixture.fileURLs[0]))
    }

    func testExternalChangeBatchAlwaysRechecksSelectedNote() throws {
        let fixture = try makeVault(files: [("Note", "original")])
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[0]))

        try Data("external".utf8).write(to: fixture.fileURLs[0], options: .atomic)
        let unrelated = fixture.vaultURL.appendingPathComponent("unrelated.png")
        workspace.handleExternalChanges([.changed(unrelated)])

        XCTAssertEqual(workspace.text, "external")
        XCTAssertNil(workspace.saveConflict)
    }

    func testUnrelatedPresenterEventDoesNotConflictWithOrdinaryUnsavedEdits() async throws {
        let fixture = try makeVault(files: [("Note", "original")])
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[0]))
        workspace.text = "local unsaved"

        workspace.handleExternalChanges([
            .changed(fixture.vaultURL.appendingPathComponent("unrelated.png"))
        ])

        XCTAssertEqual(workspace.text, "local unsaved")
        XCTAssertNil(workspace.saveConflict)
        XCTAssertTrue(workspace.hasUnsavedChanges)

        // The background refresh the event started must not touch the
        // buffer either. Waiting for it also lets the workspace go away with
        // the test instead of drafting into a removed recovery directory.
        for _ in 0..<500 where workspace.isLoadingSnapshot {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(workspace.isLoadingSnapshot)
        XCTAssertEqual(workspace.text, "local unsaved")
        XCTAssertTrue(workspace.hasUnsavedChanges)
    }

    func testExternalMoveRemapsSelectedNoteWithoutLosingBuffer() throws {
        let fixture = try makeVault(files: [("Old", "body")])
        let oldURL = fixture.fileURLs[0]
        let newURL = fixture.vaultURL.appendingPathComponent("New.md")
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(oldURL))

        try FileManager.default.moveItem(at: oldURL, to: newURL)
        workspace.handleExternalChanges([.moved(from: oldURL, to: newURL)])

        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, newURL.standardizedFileURL)
        XCTAssertEqual(workspace.text, "body")
    }

    func testRecoveryStoreRestoresDraftWhenDiskStillMatchesItsBase() throws {
        let fixture = try makeVault(files: [("Note", "base content")])
        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: recoveryURL) }
        let recoveryStore = RecoveryStore(directoryURL: recoveryURL)

        let firstWorkspace = try makeWorkspace(recoveryStore: recoveryStore)
        firstWorkspace.vaultURL = fixture.vaultURL
        firstWorkspace.refreshFiles()
        XCTAssertTrue(firstWorkspace.selectFile(fixture.fileURLs[0]))
        firstWorkspace.text = "locally recovered edit"
        firstWorkspace.persistRecoveryDraftNow()

        let restoredWorkspace = try makeWorkspace(recoveryStore: recoveryStore)
        restoredWorkspace.vaultURL = fixture.vaultURL
        restoredWorkspace.refreshFiles()
        XCTAssertTrue(restoredWorkspace.selectFile(fixture.fileURLs[0]))

        XCTAssertEqual(restoredWorkspace.text, "locally recovered edit")
        XCTAssertEqual(
            restoredWorkspace.recoveredDraftURL?.standardizedFileURL,
            fixture.fileURLs[0].standardizedFileURL
        )
        XCTAssertTrue(restoredWorkspace.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: fixture.fileURLs[0], encoding: .utf8), "base content")
    }

    func testRecoveryDraftStoresOnlyADigestOfItsBase() throws {
        let recoveryURL = makeTemporaryDirectoryURL()
        let store = RecoveryStore(directoryURL: recoveryURL)
        let noteURL = URL(fileURLWithPath: "/vault/Note.md")

        try store.save(content: "edited", baseContent: "base", for: noteURL)

        let draftFiles = try FileManager.default.contentsOfDirectory(at: recoveryURL, includingPropertiesForKeys: nil)
        XCTAssertEqual(draftFiles.count, 1)
        let draftFile = try XCTUnwrap(draftFiles.first)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: draftFile)) as? [String: Any]
        )
        XCTAssertNil(json["baseContent"], "Drafts must not store a second full copy of the note")
        XCTAssertEqual(json["baseContentDigest"] as? String, RecoveryDraft.digest(of: "base"))
        XCTAssertEqual(json["content"] as? String, "edited")

        let draft = try XCTUnwrap(store.draft(for: noteURL))
        XCTAssertTrue(draft.isBased(on: "base"))
        XCTAssertFalse(draft.isBased(on: "base "))
        // SHA-256 test vector, so digests stay comparable across versions.
        XCTAssertEqual(
            RecoveryDraft.digest(of: "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testLegacyDraftWithFullBaseRestoresOnlyWhileDiskStillMatchesThatBase() throws {
        let fixture = try makeVault(files: [
            ("Matching", "matching base"),
            ("Diverged", "changed on disk since the draft")
        ])
        let store = RecoveryStore(directoryURL: makeTemporaryDirectoryURL())
        try writeLegacyDraft(content: "matching edit", baseContent: "matching base", for: fixture.fileURLs[0], in: store)
        try writeLegacyDraft(content: "diverged edit", baseContent: "diverged base", for: fixture.fileURLs[1], in: store)

        XCTAssertEqual(
            store.draft(for: fixture.fileURLs[0])?.baseContentDigest,
            RecoveryDraft.digest(of: "matching base")
        )

        let matchingWorkspace = try makeWorkspace(recoveryStore: store)
        matchingWorkspace.vaultURL = fixture.vaultURL
        matchingWorkspace.refreshFiles()
        XCTAssertTrue(matchingWorkspace.selectFile(fixture.fileURLs[0]))
        XCTAssertEqual(matchingWorkspace.text, "matching edit")
        XCTAssertTrue(matchingWorkspace.hasUnsavedChanges)

        let divergedWorkspace = try makeWorkspace(recoveryStore: store)
        divergedWorkspace.vaultURL = fixture.vaultURL
        divergedWorkspace.refreshFiles()
        XCTAssertTrue(divergedWorkspace.selectFile(fixture.fileURLs[1]))
        XCTAssertEqual(divergedWorkspace.text, "changed on disk since the draft")
        XCTAssertNil(divergedWorkspace.recoveredDraftURL)
        // The divergent draft is kept for explicit recovery.
        XCTAssertEqual(store.draft(for: fixture.fileURLs[1])?.content, "diverged edit")
    }

    func testDeferredDraftWriteNeverLandsAfterANewerWriteOrRemoval() throws {
        let store = RecoveryStore(directoryURL: makeTemporaryDirectoryURL())
        let noteURL = URL(fileURLWithPath: "/vault/Note.md")

        let staleTicket = store.reserveDeferredWrite(for: noteURL)
        let newerTicket = store.reserveDeferredWrite(for: noteURL)
        XCTAssertTrue(store.save(content: "newer", baseContent: "base", ifCurrent: newerTicket))
        XCTAssertFalse(store.save(content: "stale", baseContent: "base", ifCurrent: staleTicket))
        XCTAssertFalse(store.save(content: "repeat", baseContent: "base", ifCurrent: newerTicket))
        XCTAssertEqual(store.draft(for: noteURL)?.content, "newer")

        let ticketBeforeSave = store.reserveDeferredWrite(for: noteURL)
        try store.save(content: "saved synchronously", baseContent: "base", for: noteURL)
        XCTAssertFalse(store.save(content: "late", baseContent: "base", ifCurrent: ticketBeforeSave))
        XCTAssertEqual(store.draft(for: noteURL)?.content, "saved synchronously")

        let ticketBeforeRemoval = store.reserveDeferredWrite(for: noteURL)
        store.removeDraft(for: noteURL)
        XCTAssertFalse(store.save(content: "resurrected", baseContent: "base", ifCurrent: ticketBeforeRemoval))
        XCTAssertNil(store.draft(for: noteURL))

        // Tickets are per note: removing another note's draft supersedes nothing.
        let ticketForNote = store.reserveDeferredWrite(for: noteURL)
        store.removeDraft(for: URL(fileURLWithPath: "/vault/Other.md"))
        XCTAssertTrue(store.save(content: "kept", baseContent: "base", ifCurrent: ticketForNote))
        XCTAssertEqual(store.draft(for: noteURL)?.content, "kept")
    }

    func testTypingPauseWritesTheRecoveryDraftInTheBackground() async throws {
        let fixture = try makeVault(files: [("Note", "original")])
        let store = RecoveryStore(directoryURL: makeTemporaryDirectoryURL())
        let workspace = try makeWorkspace(recoveryStore: store)
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[0]))

        workspace.text = "typed but unsaved"
        // The draft is debounced and written off the main actor, never inline.
        XCTAssertNil(store.draft(for: fixture.fileURLs[0]))

        for _ in 0..<500 where store.draft(for: fixture.fileURLs[0]) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let draft = try XCTUnwrap(store.draft(for: fixture.fileURLs[0]))
        XCTAssertEqual(draft.content, "typed but unsaved")
        XCTAssertTrue(draft.isBased(on: "original"))

        XCTAssertEqual(workspace.saveCurrentFile(), .saved)
        XCTAssertNil(store.draft(for: fixture.fileURLs[0]))
    }

    // MARK: - Fixture

    private func makeVault(files: [(name: String, content: String)]) throws -> (vaultURL: URL, fileURLs: [URL]) {
        let vaultURL = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

        let fileURLs = try files.map { file -> URL in
            let fileURL = vaultURL
                .appendingPathComponent(file.name)
                .appendingPathExtension("md")
                .standardizedFileURL
            try Data(file.content.utf8).write(to: fileURL, options: .atomic)
            return fileURL
        }

        addTeardownBlock {
            try? FileManager.default.removeItem(at: vaultURL)
        }

        return (vaultURL, fileURLs)
    }

    /// A workspace whose persisted state lives in a throwaway defaults suite
    /// (and, unless given a store, a throwaway recovery directory).
    private func makeWorkspace(
        recoveryStore: RecoveryStore? = nil,
        userDefaults: UserDefaults? = nil
    ) throws -> Workspace {
        let defaults: UserDefaults
        if let userDefaults {
            defaults = userDefaults
        } else {
            defaults = try makeUserDefaults()
        }
        return Workspace(
            preferences: AppPreferences(userDefaults: defaults),
            recoveryStore: recoveryStore ?? RecoveryStore(directoryURL: makeTemporaryDirectoryURL()),
            userDefaults: defaults
        )
    }

    private func makeUserDefaults() throws -> UserDefaults {
        let suiteName = "SecurityAndSearchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    /// A directory URL under the temporary directory, removed at teardown.
    /// The directory itself is created lazily by whoever writes into it.
    private func makeTemporaryDirectoryURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecurityAndSearchTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Replaces the draft file `store` keeps for `url` with the pre-digest
    /// format, which stored the complete base text.
    private func writeLegacyDraft(
        content: String,
        baseContent: String,
        for url: URL,
        in store: RecoveryStore
    ) throws {
        let existingNames = Set(draftFileNames(in: store))
        try store.save(content: content, baseContent: baseContent, for: url)
        let createdName = try XCTUnwrap(draftFileNames(in: store).first { !existingNames.contains($0) })
        let legacyDraft: [String: Any] = [
            "sourcePath": url.standardizedFileURL.path,
            "content": content,
            "baseContent": baseContent,
            "updatedAt": 0
        ]
        try JSONSerialization.data(withJSONObject: legacyDraft)
            .write(to: store.directoryURL.appendingPathComponent(createdName), options: .atomic)
    }

    private func draftFileNames(in store: RecoveryStore) -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: store.directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls.map(\.lastPathComponent)
    }
}

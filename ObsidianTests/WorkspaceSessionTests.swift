import Foundation
import XCTest

@testable import Obsidian

@MainActor
final class WorkspaceSessionTests: XCTestCase {
    func testPersistsOpenPinnedAndSplitStateRelativeToVault() throws {
        let suite = "WorkspaceSessionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = URL(fileURLWithPath: "/tmp/Vault", isDirectory: true)
        let first = vault.appendingPathComponent("First.md")
        let second = vault.appendingPathComponent("Folder/Second.md")
        let available: Set<URL> = [first, second]

        let session = WorkspaceSession(userDefaults: defaults)
        session.load(for: vault, availableFiles: available)
        session.noteSelected(first)
        session.noteSelected(second)
        session.togglePinned(first)
        session.splitPreview = true

        let restored = WorkspaceSession(userDefaults: defaults)
        restored.load(for: vault, availableFiles: available)

        XCTAssertEqual(restored.tabs, [first, second])
        XCTAssertTrue(restored.isPinned(first))
        XCTAssertTrue(restored.splitPreview)
    }

    func testPrunesMissingFilesAndSelectsNeighborWhenClosingCurrentTab() throws {
        let suite = "WorkspaceSessionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = URL(fileURLWithPath: "/tmp/Vault", isDirectory: true)
        let first = vault.appendingPathComponent("First.md")
        let second = vault.appendingPathComponent("Second.md")

        let session = WorkspaceSession(userDefaults: defaults)
        session.load(for: vault, availableFiles: [first, second])
        session.noteSelected(first)
        session.noteSelected(second)

        XCTAssertEqual(session.close(second, selectedURL: second), first)
        session.prune(availableFiles: [])
        XCTAssertTrue(session.tabs.isEmpty)
    }

    func testDefersRestoreUntilAsyncVaultInventoryIsReady() throws {
        let suite = "WorkspaceSessionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = URL(fileURLWithPath: "/tmp/Vault", isDirectory: true)
        let first = vault.appendingPathComponent("First.md")

        let writer = WorkspaceSession(userDefaults: defaults)
        writer.load(for: vault, availableFiles: [first])
        writer.noteSelected(first)
        writer.togglePinned(first)

        let restored = WorkspaceSession(userDefaults: defaults)
        XCTAssertFalse(restored.load(for: vault, availableFiles: [], inventoryReady: false))
        XCTAssertFalse(restored.isLoaded(for: vault))

        XCTAssertTrue(restored.load(for: vault, availableFiles: [first], inventoryReady: true))
        XCTAssertEqual(restored.tabs, [first])
        XCTAssertTrue(restored.isPinned(first))
    }

    func testClosingFinalTabClearsWorkspaceSelection() throws {
        let suite = "WorkspaceSessionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let note = vault.appendingPathComponent("Only.md")
        try "# Only\n\nBody".write(to: note, atomically: true, encoding: .utf8)

        let workspace = makeWorkspace(userDefaults: defaults)
        workspace.vaultURL = vault
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(note))

        let session = WorkspaceSession(userDefaults: defaults)
        session.load(for: vault, availableFiles: [note])
        session.noteSelected(note)

        XCTAssertTrue(NoteTabCoordinator.close(note, workspace: workspace, session: session))
        XCTAssertTrue(session.tabs.isEmpty)
        XCTAssertNil(workspace.selectedFileURL)
        XCTAssertEqual(workspace.text, "")
    }

    func testClosingTabKeepsDirtyDocumentOpenWhenSaveFails() throws {
        let suite = "WorkspaceSessionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let note = vault.appendingPathComponent("Only.md")
        try "original".write(to: note, atomically: true, encoding: .utf8)

        let workspace = makeWorkspace(userDefaults: defaults)
        workspace.vaultURL = vault
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(note))
        workspace.text = "dirty text that must remain open"

        let session = WorkspaceSession(userDefaults: defaults)
        session.load(for: vault, availableFiles: [note])
        session.noteSelected(note)
        try FileManager.default.removeItem(at: note)

        XCTAssertFalse(NoteTabCoordinator.close(note, workspace: workspace, session: session))
        XCTAssertEqual(session.tabs, [note.standardizedFileURL])
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, note.standardizedFileURL)
        XCTAssertEqual(workspace.text, "dirty text that must remain open")
    }

    func testImageSelectionExitsBasesMode() {
        XCTAssertEqual(
            WorkspaceViewModePolicy.modeAfterSelection(
                current: .bases,
                preferred: .editor,
                isMarkdown: false,
                isImage: true
            ),
            .preview
        )
    }

    /// A workspace on the test's own defaults suite, with recovery drafts in a
    /// throwaway directory rather than the app's Application Support folder.
    private func makeWorkspace(userDefaults: UserDefaults) -> Workspace {
        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSessionTests-Recovery-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: recoveryURL)
        }
        return Workspace(
            preferences: AppPreferences(userDefaults: userDefaults),
            recoveryStore: RecoveryStore(directoryURL: recoveryURL),
            userDefaults: userDefaults
        )
    }
}

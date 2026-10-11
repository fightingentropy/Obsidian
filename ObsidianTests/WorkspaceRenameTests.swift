import Foundation
import XCTest

@testable import Obsidian

@MainActor
final class WorkspaceRenameTests: XCTestCase {
    func testOpenRequestedFilesOverridesRestoredSelection() async throws {
        let fixture = try makeWorkspaceFixture(
            files: [
                ("Old", "# Old\n\nBody"),
                ("New", "# New\n\nBody")
            ]
        )

        // Both workspaces share one defaults suite, as consecutive launches do.
        let defaults = try makeUserDefaultsSuite().defaults
        let initialWorkspace = try makeWorkspace(userDefaults: defaults)
        initialWorkspace.openVault(fixture.vaultURL)
        initialWorkspace.selectFile(fixture.fileURLs[0])
        XCTAssertEqual(initialWorkspace.selectedFileURL?.standardizedFileURL, fixture.fileURLs[0].standardizedFileURL)

        let restoredWorkspace = try makeWorkspace(userDefaults: defaults)
        for _ in 0..<20 {
            if restoredWorkspace.selectedFileURL?.standardizedFileURL == fixture.fileURLs[0].standardizedFileURL {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(restoredWorkspace.selectedFileURL?.standardizedFileURL, fixture.fileURLs[0].standardizedFileURL)

        restoredWorkspace.openRequestedFiles([fixture.fileURLs[1]])

        XCTAssertEqual(restoredWorkspace.selectedFileURL?.standardizedFileURL, fixture.fileURLs[1].standardizedFileURL)
        XCTAssertEqual(restoredWorkspace.text, "# New\n\nBody")
    }

    func testRenameItemUpdatesSelectionAndHeadingWhenTitleMatchesFilename() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Old", content: "# Old\n\nBody")
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fixture.fileURL)
        workspace.persistEditorSelection(NSRange(location: 7, length: 0), for: fixture.fileURL)

        let renamedURL = try workspace.renameItem(fixture.fileURL, to: "New")

        XCTAssertEqual(renamedURL.lastPathComponent, "New.md")
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, renamedURL.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedURL.path))
        XCTAssertEqual(try String(contentsOf: renamedURL, encoding: .utf8), "# New\n\nBody")
        XCTAssertEqual(workspace.editorSelection(for: renamedURL), NSRange(location: 7, length: 0))
        XCTAssertNil(workspace.editorSelection(for: fixture.fileURL))
    }

    func testRenameItemPreservesCustomHeading() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Old", content: "# Custom Title\n\nBody")
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        let renamedURL = try workspace.renameItem(fixture.fileURL, to: "Renamed")

        XCTAssertEqual(try String(contentsOf: renamedURL, encoding: .utf8), "# Custom Title\n\nBody")
    }

    func testRenameUpdatesIncomingWikiAndMarkdownLinks() throws {
        let fixture = try makeWorkspaceFixture(
            files: [
                ("Old", "# Old\n\nBody"),
                ("Index", "See [[Old]] and [Old](Old.md)."),
            ]
        )
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        _ = try workspace.renameItem(fixture.fileURLs[0], to: "New")

        XCTAssertEqual(
            try String(contentsOf: fixture.fileURLs[1], encoding: .utf8),
            "See [[New]] and [Old](New.md)."
        )
    }

    func testRenameItemRejectsExistingDestination() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Old", content: "# Old\n\nBody")
        let destinationURL = fixture.vaultURL.appendingPathComponent("Taken.md")
        try Data("# Taken\n".utf8).write(to: destinationURL, options: .atomic)

        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        XCTAssertThrowsError(try workspace.renameItem(fixture.fileURL, to: "Taken")) { error in
            XCTAssertEqual(error as? ItemRenameError, .nameAlreadyExists)
        }
    }

    func testRenameFolderMovesFolderAndKeepsContents() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Old", content: "# Old\n\nBody")
        let folderURL = fixture.vaultURL.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let nestedFileURL = folderURL.appendingPathComponent("Nested").appendingPathExtension("md")
        try Data("# Nested\n\nBody".utf8).write(to: nestedFileURL, options: .atomic)

        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        let renamedFolderURL = try workspace.renameItem(folderURL, to: "Archive")

        XCTAssertEqual(renamedFolderURL.lastPathComponent, "Archive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedFolderURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: renamedFolderURL.appendingPathComponent("Nested.md").path
            )
        )
    }

    func testRenameFolderRemapsSelectedDescendantAndCursorState() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Existing", content: "# Existing\n\nBody")
        let folderURL = fixture.vaultURL.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let nestedFileURL = folderURL.appendingPathComponent("Nested.md")
        try Data("# Nested\n\nBody".utf8).write(to: nestedFileURL, options: .atomic)

        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(nestedFileURL)
        workspace.persistEditorSelection(NSRange(location: 11, length: 2), for: nestedFileURL)

        let renamedFolderURL = try workspace.renameItem(folderURL, to: "Archive")
        let renamedNestedURL = renamedFolderURL.appendingPathComponent("Nested.md")

        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, renamedNestedURL.standardizedFileURL)
        XCTAssertEqual(workspace.text, "# Nested\n\nBody")
        XCTAssertEqual(workspace.editorSelection(for: renamedNestedURL), NSRange(location: 11, length: 2))
        XCTAssertNil(workspace.editorSelection(for: nestedFileURL))
    }

    func testMoveFolderRemapsSelectedDescendantAndCursorState() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Existing", content: "# Existing\n\nBody")
        let folderURL = fixture.vaultURL.appendingPathComponent("Drafts", isDirectory: true)
        let destinationFolderURL = fixture.vaultURL.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationFolderURL, withIntermediateDirectories: true)
        let nestedFileURL = folderURL.appendingPathComponent("Nested.md")
        try Data("# Nested\n\nBody".utf8).write(to: nestedFileURL, options: .atomic)

        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(nestedFileURL)
        workspace.persistEditorSelection(NSRange(location: 4, length: 0), for: nestedFileURL)

        XCTAssertTrue(workspace.moveItem(folderURL, toFolder: destinationFolderURL))
        let movedNestedURL = destinationFolderURL
            .appendingPathComponent("Drafts", isDirectory: true)
            .appendingPathComponent("Nested.md")

        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, movedNestedURL.standardizedFileURL)
        XCTAssertEqual(workspace.text, "# Nested\n\nBody")
        XCTAssertEqual(workspace.editorSelection(for: movedNestedURL), NSRange(location: 4, length: 0))
        XCTAssertNil(workspace.editorSelection(for: nestedFileURL))
    }

    func testRefreshFilesDoesNotRewriteFilesWithoutHeadings() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Untitled", content: "Plain body")
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL

        workspace.refreshFiles()

        XCTAssertEqual(try String(contentsOf: fixture.fileURL, encoding: .utf8), "Plain body")
        XCTAssertEqual(workspace.files.first?.noteTitle, "Untitled")
    }

    func testEditorSelectionPersistsPerFile() throws {
        let fixture = try makeWorkspaceFixture(
            files: [
                ("First", "# First\n\nBody"),
                ("Second", "# Second\n\nBody")
            ]
        )
        let workspace = try makeWorkspace()

        workspace.persistEditorSelection(NSRange(location: 5, length: 0), for: fixture.fileURLs[0])
        workspace.persistEditorSelection(NSRange(location: 12, length: 3), for: fixture.fileURLs[1])

        XCTAssertEqual(workspace.editorSelection(for: fixture.fileURLs[0]), NSRange(location: 5, length: 0))
        XCTAssertEqual(workspace.editorSelection(for: fixture.fileURLs[1]), NSRange(location: 12, length: 3))
    }

    func testEditorSelectionsPersistInOneDictionaryPerVault() async throws {
        let fixture = try makeWorkspaceFixture(
            files: [
                ("First", "# First\n\nBody"),
                ("Second", "# Second\n\nBody")
            ]
        )
        let suite = try makeUserDefaultsSuite()
        let workspace = try makeWorkspace(userDefaults: suite.defaults)
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        workspace.persistEditorSelection(NSRange(location: 5, length: 0), for: fixture.fileURLs[0])
        workspace.persistEditorSelection(NSRange(location: 12, length: 3), for: fixture.fileURLs[1])

        // Writes are debounced; wait for the single dictionary to land.
        let storageKey = editorSelectionsKey(for: fixture.vaultURL)
        for _ in 0..<500 where suite.defaults.dictionary(forKey: storageKey)?.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            suite.defaults.dictionary(forKey: storageKey) as? [String: [Int]],
            [
                FileItem.canonicalPath(for: fixture.fileURLs[0]): [5, 0],
                FileItem.canonicalPath(for: fixture.fileURLs[1]): [12, 3]
            ]
        )
        let storedKeys = suite.defaults.persistentDomain(forName: suite.name)?.keys.map { $0 } ?? []
        XCTAssertFalse(storedKeys.contains { $0.hasPrefix("editorSelection::") })

        let restoredWorkspace = try makeWorkspace(userDefaults: suite.defaults)
        restoredWorkspace.vaultURL = fixture.vaultURL
        XCTAssertEqual(restoredWorkspace.editorSelection(for: fixture.fileURLs[0]), NSRange(location: 5, length: 0))
        XCTAssertEqual(restoredWorkspace.editorSelection(for: fixture.fileURLs[1]), NSRange(location: 12, length: 3))
    }

    func testSnapshotPrunesSelectionsOfNotesThatNoLongerExist() throws {
        let fixture = try makeWorkspaceFixture(
            files: [
                ("Keep", "# Keep\n\nBody"),
                ("Gone", "# Gone\n\nBody")
            ]
        )
        let suite = try makeUserDefaultsSuite()
        let workspace = try makeWorkspace(userDefaults: suite.defaults)
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.persistEditorSelection(NSRange(location: 2, length: 0), for: fixture.fileURLs[0])
        workspace.persistEditorSelection(NSRange(location: 3, length: 1), for: fixture.fileURLs[1])

        // Removed behind the workspace's back, so only the snapshot sees it.
        try FileManager.default.removeItem(at: fixture.fileURLs[1])
        workspace.refreshFiles()

        XCTAssertEqual(workspace.editorSelection(for: fixture.fileURLs[0]), NSRange(location: 2, length: 0))
        XCTAssertNil(workspace.editorSelection(for: fixture.fileURLs[1]))
        // Pruning writes the dictionary through immediately.
        XCTAssertEqual(
            suite.defaults.dictionary(forKey: editorSelectionsKey(for: fixture.vaultURL)) as? [String: [Int]],
            [FileItem.canonicalPath(for: fixture.fileURLs[0]): [2, 0]]
        )
    }

    func testExternalMoveRemapsStoredSelectionOfAnyNote() throws {
        let fixture = try makeWorkspaceFixture(
            files: [
                ("Open", "# Open\n\nBody"),
                ("Moved", "# Moved\n\nBody")
            ]
        )
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[0]))
        workspace.persistEditorSelection(NSRange(location: 4, length: 1), for: fixture.fileURLs[1])

        let destinationURL = fixture.vaultURL.appendingPathComponent("Renamed.md")
        try FileManager.default.moveItem(at: fixture.fileURLs[1], to: destinationURL)
        workspace.handleExternalChanges([.moved(from: fixture.fileURLs[1], to: destinationURL)])

        XCTAssertEqual(workspace.editorSelection(for: destinationURL), NSRange(location: 4, length: 1))
        XCTAssertNil(workspace.editorSelection(for: fixture.fileURLs[1]))
    }

    func testLegacyPerNoteSelectionKeysAreImportedOnceAndRemoved() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Note", content: "# Note\n\nBody")
        let suite = try makeUserDefaultsSuite()
        let notePath = FileItem.canonicalPath(for: fixture.fileURL)
        suite.defaults.set([6, 2], forKey: "editorSelection::" + notePath)
        suite.defaults.set([1, 0], forKey: "editorSelection::/elsewhere/Other.md")

        let workspace = try makeWorkspace(userDefaults: suite.defaults)
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        XCTAssertEqual(workspace.editorSelection(for: fixture.fileURL), NSRange(location: 6, length: 2))
        // Only the loaded vault's legacy keys are consumed; another vault's
        // keys stay until that vault is opened.
        let storedKeys = suite.defaults.persistentDomain(forName: suite.name)?.keys.map { $0 } ?? []
        XCTAssertEqual(
            storedKeys.filter { $0.hasPrefix("editorSelection::") },
            ["editorSelection::/elsewhere/Other.md"]
        )
        XCTAssertEqual(
            suite.defaults.dictionary(forKey: editorSelectionsKey(for: fixture.vaultURL)) as? [String: [Int]],
            [notePath: [6, 2]]
        )

        // The import runs once per vault; later legacy keys are ignored.
        suite.defaults.set([9, 9], forKey: "editorSelection::" + notePath)
        let laterWorkspace = try makeWorkspace(userDefaults: suite.defaults)
        laterWorkspace.vaultURL = fixture.vaultURL
        XCTAssertEqual(laterWorkspace.editorSelection(for: fixture.fileURL), NSRange(location: 6, length: 2))
    }

    func testLegacySelectionMigrationOfOneVaultKeepsOtherVaultsKeys() throws {
        let first = try makeWorkspaceFixture(fileName: "First", content: "# First\n\nBody")
        let second = try makeWorkspaceFixture(fileName: "Second", content: "# Second\n\nBody")
        let suite = try makeUserDefaultsSuite()
        let firstPath = FileItem.canonicalPath(for: first.fileURL)
        let secondPath = FileItem.canonicalPath(for: second.fileURL)
        suite.defaults.set([3, 1], forKey: "editorSelection::" + firstPath)
        suite.defaults.set([8, 0], forKey: "editorSelection::" + secondPath)

        let firstWorkspace = try makeWorkspace(userDefaults: suite.defaults)
        firstWorkspace.vaultURL = first.vaultURL
        firstWorkspace.refreshFiles()
        XCTAssertEqual(firstWorkspace.editorSelection(for: first.fileURL), NSRange(location: 3, length: 1))
        XCTAssertNil(suite.defaults.object(forKey: "editorSelection::" + firstPath))
        XCTAssertNotNil(suite.defaults.object(forKey: "editorSelection::" + secondPath))

        // Opening the second vault later still imports its saved positions.
        let secondWorkspace = try makeWorkspace(userDefaults: suite.defaults)
        secondWorkspace.vaultURL = second.vaultURL
        secondWorkspace.refreshFiles()
        XCTAssertEqual(secondWorkspace.editorSelection(for: second.fileURL), NSRange(location: 8, length: 0))
        XCTAssertNil(suite.defaults.object(forKey: "editorSelection::" + secondPath))
        XCTAssertEqual(
            suite.defaults.dictionary(forKey: editorSelectionsKey(for: second.vaultURL)) as? [String: [Int]],
            [secondPath: [8, 0]]
        )
    }

    func testSnapshotWithUnlistableFolderDoesNotPruneSelections() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Keep", content: "# Keep\n\nBody")
        let folderURL = fixture.vaultURL.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let lockedNoteURL = folderURL.appendingPathComponent("Hidden.md")
        try Data("# Hidden\n\nBody".utf8).write(to: lockedNoteURL, options: .atomic)

        let suite = try makeUserDefaultsSuite()
        let workspace = try makeWorkspace(userDefaults: suite.defaults)
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertNotNil(workspace.fileItem(for: lockedNoteURL))
        workspace.persistEditorSelection(NSRange(location: 4, length: 0), for: lockedNoteURL)
        workspace.persistEditorSelection(NSRange(location: 2, length: 0), for: fixture.fileURL)

        // Registered after the fixture's own teardown, so it runs first and
        // lets the directory be removed.
        let vaultURL = fixture.vaultURL
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folderURL.path)
            try? FileManager.default.removeItem(at: vaultURL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folderURL.path)
        workspace.refreshFiles()

        // The folder could not be listed, so its note is missing from the
        // inventory, but its saved position must survive.
        XCTAssertNil(workspace.fileItem(for: lockedNoteURL))
        XCTAssertEqual(workspace.editorSelection(for: lockedNoteURL), NSRange(location: 4, length: 0))
        XCTAssertEqual(workspace.editorSelection(for: fixture.fileURL), NSRange(location: 2, length: 0))

        // Once the folder lists again, a complete snapshot prunes normally.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folderURL.path)
        try FileManager.default.removeItem(at: lockedNoteURL)
        workspace.refreshFiles()
        XCTAssertNil(workspace.editorSelection(for: lockedNoteURL))
        XCTAssertEqual(workspace.editorSelection(for: fixture.fileURL), NSRange(location: 2, length: 0))
    }

    func testSnapshotKeepsSelectionsOfNotesOutsideTheVault() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Inside", content: "# Inside\n\nBody")
        let outside = try makeWorkspaceFixture(fileName: "Outside", content: "# Outside\n\nBody")
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.persistEditorSelection(NSRange(location: 5, length: 0), for: outside.fileURL)

        workspace.refreshFiles()

        XCTAssertEqual(workspace.editorSelection(for: outside.fileURL), NSRange(location: 5, length: 0))
    }

    func testSortChangeDuringBackgroundSnapshotAppliesNewOrder() async throws {
        let fixture = try makeWorkspaceFixture(
            files: [
                ("Alpha", "# Alpha\n\nBody"),
                ("Bravo", "# Bravo\n\nBody"),
                ("Charlie", "# Charlie\n\nBody")
            ]
        )
        // Newest first by date is the reverse of name order.
        for (index, url) in fixture.fileURLs.enumerated() {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 1_000)],
                ofItemAtPath: url.path
            )
        }
        let suite = try makeUserDefaultsSuite()
        let workspace = try makeWorkspace(userDefaults: suite.defaults)

        XCTAssertTrue(workspace.openVault(fixture.vaultURL))
        XCTAssertEqual(workspace.sortOrder, .byDate)
        XCTAssertTrue(workspace.isLoadingSnapshot)
        // The walk started in date order; the user switches to name order
        // before it lands.
        workspace.sortOrder = .byName

        for _ in 0..<500 where workspace.isLoadingSnapshot {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(workspace.isLoadingSnapshot)
        XCTAssertEqual(workspace.sortOrder, .byName)
        XCTAssertEqual(workspace.files.map(\.name), ["Alpha.md", "Bravo.md", "Charlie.md"])
        XCTAssertEqual(workspace.sidebarNodes.map(\.name), ["Alpha", "Bravo", "Charlie"])
    }

    func testCreateNewFileInFolderSelectsCreatedFile() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Existing", content: "# Existing\n\nBody")
        let folderURL = fixture.vaultURL.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        workspace.createNewFile(in: folderURL)

        let createdURL = folderURL.appendingPathComponent("Untitled.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdURL.path))
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, createdURL.standardizedFileURL)
        XCTAssertEqual(workspace.text, "# Untitled\n\n")
    }

    func testDroppedExternalMarkdownImportsIntoCurrentVault() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Existing", content: "# Existing")
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("External-\(UUID().uuidString).md")
        try "# Imported".write(to: external, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: external) }

        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.importDroppedFile(external)

        let imported = fixture.vaultURL.appendingPathComponent(external.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
        XCTAssertEqual(workspace.vaultURL?.standardizedFileURL, fixture.vaultURL.standardizedFileURL)
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, imported.standardizedFileURL)
    }

    func testDeleteItemRemovesSelectedMarkdownFileAndClearsSelectionState() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Old", content: "# Old\n\nBody")
        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fixture.fileURL)
        workspace.persistEditorSelection(NSRange(location: 7, length: 0), for: fixture.fileURL)

        workspace.deleteItem(fixture.fileURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertNil(workspace.selectedFileURL)
        XCTAssertEqual(workspace.text, "")
        XCTAssertNil(workspace.editorSelection(for: fixture.fileURL))
    }

    func testDeleteItemRemovesFolderAndClearsNestedSelectionState() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Existing", content: "# Existing\n\nBody")
        let folderURL = fixture.vaultURL.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let nestedFileURL = folderURL.appendingPathComponent("Nested.md")
        try Data("# Nested\n\nBody".utf8).write(to: nestedFileURL, options: .atomic)

        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(nestedFileURL)
        workspace.persistEditorSelection(NSRange(location: 10, length: 0), for: nestedFileURL)

        workspace.deleteItem(folderURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
        XCTAssertNil(workspace.selectedFileURL)
        XCTAssertEqual(workspace.text, "")
        XCTAssertNil(workspace.editorSelection(for: nestedFileURL))
    }

    func testMoveMarkdownFileIntoFolderUpdatesSelectionAndEditorState() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Note", content: "# Note\n\nBody")
        let folderURL = fixture.vaultURL.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fixture.fileURL)
        workspace.persistEditorSelection(NSRange(location: 7, length: 0), for: fixture.fileURL)

        let didMove = workspace.moveItem(fixture.fileURL, toFolder: folderURL)
        let movedURL = folderURL.appendingPathComponent("Note.md")

        XCTAssertTrue(didMove)
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, movedURL.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedURL.path))
        XCTAssertEqual(workspace.text, "# Note\n\nBody")
        XCTAssertEqual(workspace.editorSelection(for: movedURL), NSRange(location: 7, length: 0))
        XCTAssertNil(workspace.editorSelection(for: fixture.fileURL))
    }

    func testMoveSelectedImageToVaultRootPreservesSelection() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Existing", content: "# Existing\n\nBody")
        let folderURL = fixture.vaultURL.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let imageURL = folderURL.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL, options: .atomic)

        let workspace = try makeWorkspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(imageURL)

        let didMove = workspace.moveItem(imageURL, toFolder: nil)
        let movedURL = fixture.vaultURL.appendingPathComponent("photo.png")

        XCTAssertTrue(didMove)
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, movedURL.standardizedFileURL)
        XCTAssertTrue(workspace.selectedFileIsImage)
        XCTAssertEqual(workspace.selectedFileName, "photo.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedURL.path))
    }

    func testSidebarExpansionRestoreDefersUntilFoldersAreLoaded() {
        let folderURL = URL(fileURLWithPath: "/tmp/vault/misc", isDirectory: true)
        let storedPaths = [folderURL.path]

        let deferredResult = SidebarExpansionPersistence.restoreResult(
            storedPaths: storedPaths,
            validFolderURLs: [],
            isLoadingSnapshot: true
        )

        XCTAssertEqual(deferredResult, .deferred)

        let restoredResult = SidebarExpansionPersistence.restoreResult(
            storedPaths: storedPaths,
            validFolderURLs: [folderURL],
            isLoadingSnapshot: false
        )

        XCTAssertEqual(restoredResult, .restored([folderURL]))
    }

    func testSidebarExpansionLiveFilterMatchesStandardizedURLsOnly() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarExpansion-\(UUID().uuidString)", isDirectory: true)
        let projectsURL = URL(fileURLWithPath: rootURL.path + "/Projects", isDirectory: true)
        let archiveURL = URL(fileURLWithPath: rootURL.path + "/Archive", isDirectory: true)
        let validFolderURLs: Set<URL> = [projectsURL, archiveURL]

        // (a) Another spelling of a valid folder is kept, in the valid set's form.
        let dottedProjectsURL = URL(fileURLWithPath: rootURL.path + "/./Projects", isDirectory: true)
        XCTAssertNotEqual(dottedProjectsURL, projectsURL)
        XCTAssertEqual(
            SidebarExpansionPersistence.filteredExpandedFolderURLs(
                [dottedProjectsURL],
                validFolderURLs: validFolderURLs
            ),
            [projectsURL]
        )

        // (b) A folder that is no longer in the sidebar is dropped.
        let removedURL = URL(fileURLWithPath: rootURL.path + "/Removed", isDirectory: true)
        XCTAssertEqual(
            SidebarExpansionPersistence.filteredExpandedFolderURLs(
                [archiveURL, removedURL],
                validFolderURLs: validFolderURLs
            ),
            [archiveURL]
        )

        // (c) A symlink that names a valid folder only once resolved is not
        // matched by the live filter; that resolution is reserved for the
        // stored-path restore.
        let realURL = URL(fileURLWithPath: rootURL.path + "/Real", isDirectory: true)
        let linkURL = URL(fileURLWithPath: rootURL.path + "/Link", isDirectory: true)
        try FileManager.default.createDirectory(at: realURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realURL)
        XCTAssertEqual(
            linkURL.resolvingSymlinksInPath().standardizedFileURL.path,
            realURL.resolvingSymlinksInPath().standardizedFileURL.path
        )

        XCTAssertEqual(
            SidebarExpansionPersistence.filteredExpandedFolderURLs(
                [linkURL],
                validFolderURLs: [realURL]
            ),
            []
        )
        XCTAssertEqual(
            SidebarExpansionPersistence.restoreResult(
                storedPaths: [linkURL.path],
                validFolderURLs: [realURL],
                isLoadingSnapshot: false
            ),
            .restored([realURL])
        )
    }

    private func makeWorkspaceFixture(fileName: String, content: String) throws -> (vaultURL: URL, fileURL: URL) {
        let fixture = try makeWorkspaceFixture(files: [(fileName, content)])
        return (fixture.vaultURL, fixture.fileURLs[0])
    }

    private func makeWorkspaceFixture(files: [(name: String, content: String)]) throws -> (vaultURL: URL, fileURLs: [URL]) {
        let vaultURL = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

        let fileURLs = try files.map { file in
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
    /// and recovery directory, never in the app's real ones.
    private func makeWorkspace(userDefaults: UserDefaults? = nil) throws -> Workspace {
        let defaults: UserDefaults
        if let userDefaults {
            defaults = userDefaults
        } else {
            defaults = try makeUserDefaultsSuite().defaults
        }
        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceRenameTests-Recovery-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: recoveryURL)
        }
        return Workspace(
            preferences: AppPreferences(userDefaults: defaults),
            recoveryStore: RecoveryStore(directoryURL: recoveryURL),
            userDefaults: defaults
        )
    }

    private func makeUserDefaultsSuite() throws -> (defaults: UserDefaults, name: String) {
        let name = "WorkspaceRenameTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        return (defaults, name)
    }

    private func editorSelectionsKey(for vaultURL: URL) -> String {
        "editorSelections::" + vaultURL.standardizedFileURL.path
    }
}

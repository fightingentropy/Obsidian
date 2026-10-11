import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import Obsidian

final class AttachmentStoreTests: XCTestCase {
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    func testUsesObsidianAttachmentFolderAndCreatesCollisionSafeEmbed() throws {
        let fixture = try makeFixture(appJSON: #"{"attachmentFolderPath":"media"}"#)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }

        let sourceURL = fixture.vaultURL.deletingLastPathComponent().appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let first = try AttachmentStore.importFile(
            sourceURL,
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        )
        let second = try AttachmentStore.importFile(
            sourceURL,
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        )

        XCTAssertEqual(first.vaultRelativePath, "media/photo.png")
        XCTAssertEqual(first.markdownEmbed, "![[media/photo.png]]")
        XCTAssertEqual(second.vaultRelativePath, "media/photo 2.png")
        XCTAssertEqual(try Data(contentsOf: first.fileURL), Data([1, 2, 3]))
    }

    func testFallsBackToExistingImgFolder() throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        try FileManager.default.createDirectory(
            at: fixture.vaultURL.appendingPathComponent("img", isDirectory: true),
            withIntermediateDirectories: true
        )

        let folder = try AttachmentStore.attachmentFolderURL(
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        )
        XCTAssertEqual(folder.lastPathComponent, "img")
    }

    func testDotSlashResolvesNextToTheNote() throws {
        let fixture = try makeFixture(appJSON: #"{"attachmentFolderPath":"./"}"#)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }

        let folder = try AttachmentStore.attachmentFolderURL(
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        )
        XCTAssertEqual(folder.path, resolvedPath(fixture.documentURL.deletingLastPathComponent()))

        let imported = try AttachmentStore.importImageData(
            Data([1, 2, 3]),
            suggestedFilename: "shot.png",
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        )
        XCTAssertEqual(imported.vaultRelativePath, "Notes/shot.png")
    }

    func testDotSlashSubfolderResolvesUnderTheNoteFolder() throws {
        let fixture = try makeFixture(appJSON: #"{"attachmentFolderPath":"./media"}"#)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }

        let imported = try AttachmentStore.importImageData(
            Data([1, 2, 3]),
            suggestedFilename: "shot.png",
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        )
        XCTAssertEqual(imported.vaultRelativePath, "Notes/media/shot.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.fileURL.path))
    }

    func testDotSlashFallsBackToTheVaultWithoutADocument() throws {
        let fixture = try makeFixture(appJSON: #"{"attachmentFolderPath":"./media"}"#)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }

        let folder = try AttachmentStore.attachmentFolderURL(documentURL: nil, vaultURL: fixture.vaultURL)
        XCTAssertEqual(folder.path, resolvedPath(fixture.vaultURL.appendingPathComponent("media", isDirectory: true)))
    }

    func testDocumentRelativeSettingsAreRecognised() {
        XCTAssertEqual(AttachmentStore.documentRelativeSubfolder("."), "")
        XCTAssertEqual(AttachmentStore.documentRelativeSubfolder("./"), "")
        XCTAssertEqual(AttachmentStore.documentRelativeSubfolder("./media/"), "media")
        XCTAssertEqual(AttachmentStore.documentRelativeSubfolder("./media/shots"), "media/shots")
        XCTAssertNil(AttachmentStore.documentRelativeSubfolder("media"))
        XCTAssertNil(AttachmentStore.documentRelativeSubfolder(".obsidian"))
        XCTAssertNil(AttachmentStore.documentRelativeSubfolder(""))
    }

    func testStripsLeadingDotsSoAttachmentsAreNeverHidden() throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }

        let hidden = try AttachmentStore.importImageData(
            Data([1, 2, 3]),
            suggestedFilename: ".hidden.png",
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        )
        XCTAssertEqual(hidden.vaultRelativePath, "attachments/hidden.png")

        let dotsOnly = try AttachmentStore.importImageData(
            Data([1, 2, 3]),
            suggestedFilename: "....png",
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        )
        XCTAssertEqual(dotsOnly.vaultRelativePath, "attachments/Attachment.png")
    }

    func testRejectsAttachmentFolderTraversal() throws {
        let fixture = try makeFixture(appJSON: #"{"attachmentFolderPath":"../Outside"}"#)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }

        XCTAssertThrowsError(
            try AttachmentStore.attachmentFolderURL(
                documentURL: fixture.documentURL,
                vaultURL: fixture.vaultURL
            )
        )
    }

    func testRejectsAttachmentFolderSymlinkOutsideVault() throws {
        let fixture = try makeFixture(appJSON: #"{"attachmentFolderPath":"media"}"#)
        let outsideURL = fixture.vaultURL.deletingLastPathComponent()
            .appendingPathComponent("AttachmentStoreOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.vaultURL.appendingPathComponent("media", isDirectory: true),
            withDestinationURL: outsideURL
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.vaultURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }

        XCTAssertThrowsError(
            try AttachmentStore.importImageData(
                Data([1, 2, 3]),
                suggestedFilename: "escape.png",
                documentURL: fixture.documentURL,
                vaultURL: fixture.vaultURL
            )
        ) { error in
            guard case AttachmentStoreError.unsafeAttachmentFolder = error else {
                return XCTFail("Expected unsafeAttachmentFolder, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outsideURL.appendingPathComponent("escape.png").path)
        )
    }

    func testRejectsNestedAttachmentFolderSymlinkOutsideVault() throws {
        let fixture = try makeFixture(appJSON: #"{"attachmentFolderPath":"safe/media"}"#)
        let outsideURL = fixture.vaultURL.deletingLastPathComponent()
            .appendingPathComponent("NestedAttachmentOutside-\(UUID().uuidString)", isDirectory: true)
        let safeURL = fixture.vaultURL.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: safeURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: safeURL.appendingPathComponent("media", isDirectory: true),
            withDestinationURL: outsideURL
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.vaultURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }

        XCTAssertThrowsError(
            try AttachmentStore.importImageData(
                Data([1, 2, 3]),
                suggestedFilename: "escape.png",
                documentURL: fixture.documentURL,
                vaultURL: fixture.vaultURL
            )
        ) { error in
            guard case AttachmentStoreError.unsafeAttachmentFolder = error else {
                return XCTFail("Expected unsafeAttachmentFolder, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outsideURL.appendingPathComponent("escape.png").path)
        )
    }

    func testExclusiveImageInstallNeverReplacesExistingFile() throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        let folderURL = fixture.vaultURL.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let destinationURL = folderURL.appendingPathComponent("same.png")
        let original = Data("original".utf8)
        try original.write(to: destinationURL)

        XCTAssertFalse(
            try AttachmentStore.writeDataIfAbsent(
                Data("replacement".utf8),
                to: destinationURL,
                fileManager: .default
            )
        )
        XCTAssertEqual(try Data(contentsOf: destinationURL), original)
    }

    // MARK: - Pasteboard read (main actor)

    @MainActor
    func testImportRequestCapturesPastedPNGAndItsDestination() throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data([1, 2, 3]), forType: .png)

        let request = try XCTUnwrap(AttachmentStore.importRequest(
            from: pasteboard,
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        ))

        XCTAssertEqual(
            request,
            AttachmentImportRequest(
                payload: .png(Data([1, 2, 3])),
                documentURL: fixture.documentURL,
                vaultURL: fixture.vaultURL
            )
        )
    }

    @MainActor
    func testImportRequestPrefersADroppedFileOverImageData() throws {
        let fixture = try makeFixture(appJSON: nil)
        let sourceURL = try makeSourceFile(named: "photo.png", contents: Data([4, 5, 6]))
        defer {
            try? FileManager.default.removeItem(at: fixture.vaultURL)
            try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString(sourceURL.absoluteString, forType: .fileURL)
        item.setData(Data([1, 2, 3]), forType: .png)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let request = try XCTUnwrap(AttachmentStore.importRequest(
            from: pasteboard,
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        ))

        guard case .file(let url) = request.payload else {
            return XCTFail("Expected the dropped file, got \(request.payload)")
        }
        XCTAssertEqual(url.standardizedFileURL.path, sourceURL.standardizedFileURL.path)
    }

    @MainActor
    func testImportRequestIgnoresPlainTextAndRequiresAVault() throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("just words", forType: .string)

        XCTAssertNil(try AttachmentStore.importRequest(
            from: pasteboard,
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        ))
        XCTAssertThrowsError(
            try AttachmentStore.importRequest(from: pasteboard, documentURL: nil, vaultURL: nil)
        ) { error in
            guard case AttachmentStoreError.missingVault = error else {
                return XCTFail("Expected missingVault, got \(error)")
            }
        }
    }

    @MainActor
    func testSynchronousImportStillHandlesPastedImages() throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setData(Data([1, 2, 3]), forType: .png)
        let png = try XCTUnwrap(AttachmentStore.importFirstAttachment(
            from: pasteboard,
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        ))
        XCTAssertTrue(png.vaultRelativePath.hasPrefix("attachments/Pasted image "))
        XCTAssertTrue(png.vaultRelativePath.hasSuffix(".png"))
        XCTAssertEqual(try Data(contentsOf: png.fileURL), Data([1, 2, 3]))

        pasteboard.clearContents()
        pasteboard.setData(try makeTIFFData(), forType: .tiff)
        let tiff = try XCTUnwrap(AttachmentStore.importFirstAttachment(
            from: pasteboard,
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        ))
        XCTAssertNotEqual(tiff.vaultRelativePath, png.vaultRelativePath)
        XCTAssertTrue(tiff.vaultRelativePath.hasSuffix(".png"))
        XCTAssertEqual(try Data(contentsOf: tiff.fileURL).prefix(8), Self.pngSignature)

        // TIFF that cannot be decoded is still "nothing to import" here.
        pasteboard.clearContents()
        pasteboard.setData(Data([1, 2, 3]), forType: .tiff)
        XCTAssertNil(try AttachmentStore.importFirstAttachment(
            from: pasteboard,
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        ))
    }

    // MARK: - Background import

    func testBackgroundImportTranscodesTIFFToPNG() async throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        let request = AttachmentImportRequest(
            payload: .tiff(try makeTIFFData()),
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        )

        let imported = try await AttachmentStore.importAttachment(request)

        XCTAssertTrue(imported.vaultRelativePath.hasPrefix("attachments/Pasted image "))
        XCTAssertTrue(imported.vaultRelativePath.hasSuffix(".png"))
        XCTAssertEqual(imported.markdownEmbed, "![[\(imported.vaultRelativePath)]]")
        let written = try Data(contentsOf: imported.fileURL)
        XCTAssertEqual(written.prefix(8), Self.pngSignature)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: written))
        XCTAssertEqual(decoded.pixelsWide, 2)
        XCTAssertEqual(decoded.pixelsHigh, 2)
    }

    func testBackgroundImportRejectsUndecodableTIFFWithoutWriting() async throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        let request = AttachmentImportRequest(
            payload: .tiff(Data([1, 2, 3])),
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        )

        do {
            _ = try await AttachmentStore.importAttachment(request)
            XCTFail("Expected unsupportedAttachment")
        } catch AttachmentStoreError.unsupportedAttachment {
            // Expected.
        } catch {
            XCTFail("Expected unsupportedAttachment, got \(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.vaultURL.appendingPathComponent("attachments").path)
        )
    }

    func testConcurrentBackgroundImportsKeepCollisionSafeNames() async throws {
        let fixture = try makeFixture(appJSON: #"{"attachmentFolderPath":"media"}"#)
        let sourceURL = try makeSourceFile(named: "photo.png", contents: Data([1, 2, 3]))
        defer {
            try? FileManager.default.removeItem(at: fixture.vaultURL)
            try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(
            at: fixture.vaultURL.appendingPathComponent("media", isDirectory: true),
            withIntermediateDirectories: true
        )
        let request = AttachmentImportRequest(
            payload: .file(sourceURL),
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        )

        async let first = AttachmentStore.importAttachment(request)
        async let second = AttachmentStore.importAttachment(request)
        let imported = try await [first, second]

        XCTAssertEqual(Set(imported.map(\.vaultRelativePath)), ["media/photo.png", "media/photo 2.png"])
        for attachment in imported {
            XCTAssertEqual(try Data(contentsOf: attachment.fileURL), Data([1, 2, 3]))
        }
    }

    func testBackgroundImportKeepsTheVaultContainmentCheck() async throws {
        let fixture = try makeFixture(appJSON: #"{"attachmentFolderPath":"media"}"#)
        let outsideURL = fixture.vaultURL.deletingLastPathComponent()
            .appendingPathComponent("BackgroundAttachmentOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.vaultURL.appendingPathComponent("media", isDirectory: true),
            withDestinationURL: outsideURL
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.vaultURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }
        let request = AttachmentImportRequest(
            payload: .png(Data([1, 2, 3])),
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        )

        do {
            _ = try await AttachmentStore.importAttachment(request)
            XCTFail("Expected unsafeAttachmentFolder")
        } catch AttachmentStoreError.unsafeAttachmentFolder {
            // Expected.
        } catch {
            XCTFail("Expected unsafeAttachmentFolder, got \(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outsideURL.path), [])
    }

    // MARK: - Import anchor

    func testAnchorShiftsForEditsBeforeItAndIgnoresEditsAfterIt() {
        let anchor = AttachmentImportAnchor(range: NSRange(location: 10, length: 4))

        // Typing and deleting before it shift it.
        XCTAssertEqual(
            anchor.adjusted(forEditReplacing: NSRange(location: 2, length: 0), withLength: 3).range,
            NSRange(location: 13, length: 4)
        )
        XCTAssertEqual(
            anchor.adjusted(forEditReplacing: NSRange(location: 0, length: 5), withLength: 0).range,
            NSRange(location: 5, length: 4)
        )
        // An insertion right at its start lands before it; right at its end, after it.
        XCTAssertEqual(
            anchor.adjusted(forEditReplacing: NSRange(location: 10, length: 0), withLength: 2).range,
            NSRange(location: 12, length: 4)
        )
        XCTAssertEqual(
            anchor.adjusted(forEditReplacing: NSRange(location: 14, length: 0), withLength: 2).range,
            NSRange(location: 10, length: 4)
        )
        // Edits further along leave it alone.
        XCTAssertEqual(
            anchor.adjusted(forEditReplacing: NSRange(location: 20, length: 3), withLength: 9).range,
            NSRange(location: 10, length: 4)
        )
    }

    func testAnchorCollapsesWhenAnEditOverlapsIt() {
        let anchor = AttachmentImportAnchor(range: NSRange(location: 10, length: 4))

        // Typed over, inserted into, partly overlapped from either side, or deleted with its surroundings.
        XCTAssertEqual(
            anchor.adjusted(forEditReplacing: NSRange(location: 10, length: 4), withLength: 6).range,
            NSRange(location: 16, length: 0)
        )
        XCTAssertEqual(
            anchor.adjusted(forEditReplacing: NSRange(location: 12, length: 0), withLength: 1).range,
            NSRange(location: 13, length: 0)
        )
        XCTAssertEqual(
            anchor.adjusted(forEditReplacing: NSRange(location: 8, length: 4), withLength: 0).range,
            NSRange(location: 8, length: 0)
        )
        XCTAssertEqual(
            anchor.adjusted(forEditReplacing: NSRange(location: 12, length: 6), withLength: 1).range,
            NSRange(location: 13, length: 0)
        )
        XCTAssertEqual(
            anchor.adjusted(forEditReplacing: NSRange(location: 0, length: 30), withLength: 2).range,
            NSRange(location: 2, length: 0)
        )
    }

    func testCaretAnchorStaysPutForEditsAtOrAfterItAndShiftsForEditsBefore() {
        let anchor = AttachmentImportAnchor(range: NSRange(location: 7, length: 0))

        XCTAssertEqual(
            anchor.adjusted(forEditReplacing: NSRange(location: 7, length: 0), withLength: 2).range,
            NSRange(location: 9, length: 0)
        )
        XCTAssertEqual(
            anchor.adjusted(forEditReplacing: NSRange(location: 7, length: 3), withLength: 0).range,
            NSRange(location: 7, length: 0)
        )
        XCTAssertEqual(
            anchor.adjusted(forEditReplacing: NSRange(location: 3, length: 4), withLength: 1).range,
            NSRange(location: 4, length: 0)
        )
        XCTAssertEqual(
            anchor.adjusted(forEditReplacing: NSRange(location: 5, length: 5), withLength: 1).range,
            NSRange(location: 6, length: 0)
        )
    }

    func testSelectionFollowsTheEmbedLanding() {
        let replaced = NSRange(location: 10, length: 20)
        func adjusted(_ location: Int, _ length: Int, replacementLength: Int = 5) -> NSRange {
            AttachmentImportAnchor.adjustedSelection(
                NSRange(location: location, length: length),
                afterReplacing: replaced,
                withLength: replacementLength
            )
        }

        // Before the replaced text, including a caret right at its start: untouched.
        XCTAssertEqual(adjusted(2, 3), NSRange(location: 2, length: 3))
        XCTAssertEqual(adjusted(10, 0), NSRange(location: 10, length: 0))
        // After it, including a caret right at its end: shifted by the length change.
        XCTAssertEqual(adjusted(30, 0), NSRange(location: 15, length: 0))
        XCTAssertEqual(adjusted(40, 2, replacementLength: 25), NSRange(location: 45, length: 2))
        // Spanning it: resized, so it covers the replacement instead.
        XCTAssertEqual(adjusted(5, 30), NSRange(location: 5, length: 15))
        // Exactly the replaced text (the caret never moved): a caret after the replacement.
        XCTAssertEqual(adjusted(10, 20), NSRange(location: 15, length: 0))
        // Only partly overlapping it: collapsed to just past the replacement.
        XCTAssertEqual(adjusted(15, 20), NSRange(location: 15, length: 0))
        XCTAssertEqual(adjusted(5, 10), NSRange(location: 15, length: 0))
        // A caret that has not moved from an empty anchor ends up after the insertion.
        XCTAssertEqual(
            AttachmentImportAnchor.adjustedSelection(
                NSRange(location: 7, length: 0),
                afterReplacing: NSRange(location: 7, length: 0),
                withLength: 4
            ),
            NSRange(location: 11, length: 0)
        )
    }

    // MARK: - Editor paste flow

    @MainActor
    func testPasteLeavesTheNoteUntouchedUntilTheImportLandsThenUndoesInOneStep() async throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        let pasteboard = makePNGPasteboard()
        defer { pasteboard.releaseGlobally() }
        let note = NoteText("Before  after")
        let coordinator = try makeCoordinator(documentURL: fixture.documentURL, vaultURL: fixture.vaultURL, note: note)
        let textView = makeTextView(note.value, selection: NSRange(location: 7, length: 0), coordinator: coordinator)

        XCTAssertTrue(coordinator.sourceTextView(textView, importAttachmentFrom: pasteboard))

        // Nothing temporary is typed into the note while the write runs off the main actor.
        XCTAssertEqual(textView.string, "Before  after")
        XCTAssertEqual(note.value, "Before  after")

        let undoManager = textView.testUndoManager
        undoManager.beginUndoGrouping()
        await coordinator.settleAttachmentImports()
        undoManager.endUndoGrouping()

        let text = textView.string
        XCTAssertTrue(text.hasPrefix("Before ![[attachments/Pasted image "))
        XCTAssertTrue(text.hasSuffix(".png]] after"))
        XCTAssertFalse(text.contains("importing"))
        let embed = String(text.dropFirst("Before ".count).dropLast(" after".count))
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: ("Before \(embed)" as NSString).length, length: 0)
        )
        let relativePath = String(embed.dropFirst(3).dropLast(2))
        XCTAssertEqual(
            try Data(contentsOf: fixture.vaultURL.appendingPathComponent(relativePath)),
            Data([1, 2, 3])
        )

        // One undo removes the embed; there is no intermediate state to land on.
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(textView.string, "Before  after")
        XCTAssertFalse(undoManager.canUndo)
    }

    @MainActor
    func testPasteReplacesTheSelectionWhenItIsUntouched() async throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        let pasteboard = makePNGPasteboard()
        defer { pasteboard.releaseGlobally() }
        let note = NoteText("Keep this text")
        let coordinator = try makeCoordinator(documentURL: fixture.documentURL, vaultURL: fixture.vaultURL, note: note)
        let textView = makeTextView(note.value, selection: NSRange(location: 5, length: 4), coordinator: coordinator)
        // The view has no event loop to open undo groups, and registering an
        // undo outside a group raises an Objective-C exception, which aborts
        // an async test. Hold one group open for the whole test.
        textView.testUndoManager.beginUndoGrouping()
        defer { textView.testUndoManager.endUndoGrouping() }

        XCTAssertTrue(coordinator.sourceTextView(textView, importAttachmentFrom: pasteboard))
        XCTAssertEqual(textView.string, "Keep this text")
        await coordinator.settleAttachmentImports()

        let text = textView.string
        XCTAssertTrue(text.hasPrefix("Keep ![[attachments/Pasted image "))
        XCTAssertTrue(text.hasSuffix(".png]] text"))
        XCTAssertFalse(text.contains("this"))
    }

    @MainActor
    func testEmbedLandsWherePasteWasMadeAfterLaterEdits() async throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        let pasteboard = makePNGPasteboard()
        defer { pasteboard.releaseGlobally() }
        let note = NoteText("Before  after")
        let coordinator = try makeCoordinator(documentURL: fixture.documentURL, vaultURL: fixture.vaultURL, note: note)
        let textView = makeTextView(note.value, selection: NSRange(location: 7, length: 0), coordinator: coordinator)
        // The view has no event loop to open undo groups, and registering an
        // undo outside a group raises an Objective-C exception, which aborts
        // an async test. Hold one group open for the whole test.
        textView.testUndoManager.beginUndoGrouping()
        defer { textView.testUndoManager.endUndoGrouping() }

        XCTAssertTrue(coordinator.sourceTextView(textView, importAttachmentFrom: pasteboard))
        // The user keeps typing before and after the paste point while the import runs.
        textView.insertText("XX", replacementRange: NSRange(location: 0, length: 0))
        textView.insertText("!", replacementRange: NSRange(location: textView.documentNSStringLength, length: 0))
        note.value = textView.string
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        await coordinator.settleAttachmentImports()

        let text = textView.string
        XCTAssertTrue(text.hasPrefix("XXBefore ![[attachments/Pasted image "))
        XCTAssertTrue(text.hasSuffix(".png]] after!"))
        // The caret was elsewhere, so it stays put.
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    @MainActor
    func testTypingOverTheReplacedSelectionKeepsTheTypedTextAndAddsTheEmbedAfterIt() async throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        let pasteboard = makePNGPasteboard()
        defer { pasteboard.releaseGlobally() }
        let note = NoteText("Keep this text")
        let coordinator = try makeCoordinator(documentURL: fixture.documentURL, vaultURL: fixture.vaultURL, note: note)
        let textView = makeTextView(note.value, selection: NSRange(location: 5, length: 4), coordinator: coordinator)
        // The view has no event loop to open undo groups, and registering an
        // undo outside a group raises an Objective-C exception, which aborts
        // an async test. Hold one group open for the whole test.
        textView.testUndoManager.beginUndoGrouping()
        defer { textView.testUndoManager.endUndoGrouping() }

        XCTAssertTrue(coordinator.sourceTextView(textView, importAttachmentFrom: pasteboard))
        textView.insertText("that", replacementRange: NSRange(location: 5, length: 4))
        note.value = textView.string
        await coordinator.settleAttachmentImports()

        let text = textView.string
        XCTAssertTrue(text.hasPrefix("Keep that![[attachments/Pasted image "))
        XCTAssertTrue(text.hasSuffix(".png]] text"))
    }

    @MainActor
    func testImportStartedInAnotherNoteNeverTouchesTheNoteNowShown() async throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        let pasteboard = makePNGPasteboard()
        defer { pasteboard.releaseGlobally() }
        // Both notes hold the same text, so only the document change can tell them apart.
        let note = NoteText("Same text")
        let coordinator = try makeCoordinator(documentURL: fixture.documentURL, vaultURL: fixture.vaultURL, note: note)
        _ = coordinator.setCurrentDocument(fixture.documentURL)
        let textView = makeTextView(note.value, selection: NSRange(location: 4, length: 0), coordinator: coordinator)

        XCTAssertTrue(coordinator.sourceTextView(textView, importAttachmentFrom: pasteboard))
        XCTAssertTrue(coordinator.setCurrentDocument(fixture.vaultURL.appendingPathComponent("Notes/Other.md")))
        await coordinator.settleAttachmentImports()

        XCTAssertEqual(textView.string, "Same text")
        XCTAssertEqual(note.value, "Same text")
        XCTAssertFalse(textView.string.contains("importing"))
        // The copy is kept rather than deleted; it simply is not referenced.
        let attachments = fixture.vaultURL.appendingPathComponent("attachments")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: attachments.path).count, 1)
    }

    @MainActor
    func testImportIsDroppedWhenTheModelNoLongerHoldsTheEditorsText() async throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        let pasteboard = makePNGPasteboard()
        defer { pasteboard.releaseGlobally() }
        let note = NoteText("Note A")
        let coordinator = try makeCoordinator(documentURL: fixture.documentURL, vaultURL: fixture.vaultURL, note: note)
        let textView = makeTextView(note.value, selection: NSRange(location: 6, length: 0), coordinator: coordinator)

        XCTAssertTrue(coordinator.sourceTextView(textView, importAttachmentFrom: pasteboard))
        // The workspace already switched notes; SwiftUI has not updated the editor yet.
        note.value = "Note B"
        await coordinator.settleAttachmentImports()

        XCTAssertEqual(textView.string, "Note A")
        XCTAssertEqual(note.value, "Note B")
    }

    @MainActor
    func testFailedImportLeavesTheNoteExactlyAsItWas() async throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data([1, 2, 3]), forType: .tiff)
        let note = NoteText("Keep this text")
        let coordinator = try makeCoordinator(documentURL: fixture.documentURL, vaultURL: fixture.vaultURL, note: note)
        let textView = makeTextView(note.value, selection: NSRange(location: 5, length: 4), coordinator: coordinator)

        XCTAssertTrue(coordinator.sourceTextView(textView, importAttachmentFrom: pasteboard))
        XCTAssertEqual(textView.string, "Keep this text")
        await coordinator.settleAttachmentImports()

        XCTAssertEqual(textView.string, "Keep this text")
        XCTAssertEqual(note.value, "Keep this text")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 4))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.vaultURL.appendingPathComponent("attachments").path)
        )
    }

    @MainActor
    func testPasteWithoutAnAttachmentFallsBackToTheTextView() throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("just words", forType: .string)
        let note = NoteText("Unchanged")
        let coordinator = try makeCoordinator(documentURL: fixture.documentURL, vaultURL: fixture.vaultURL, note: note)
        let textView = makeTextView(note.value, selection: NSRange(location: 0, length: 0), coordinator: coordinator)

        XCTAssertFalse(coordinator.sourceTextView(textView, importAttachmentFrom: pasteboard))
        XCTAssertEqual(textView.string, "Unchanged")
    }

    @MainActor
    func testFinishingAnImportRefusesAnAnchorOutsideTheText() {
        let textView = makeTextView("Short", selection: NSRange(location: 2, length: 0), coordinator: nil)

        let landed = SourceEditorView.Coordinator.finishAttachmentImport(
            AttachmentImportAnchor(range: NSRange(location: 4, length: 5)),
            with: "![[a.png]]",
            in: textView
        )

        XCTAssertFalse(landed)
        XCTAssertEqual(textView.string, "Short")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    // MARK: - Filenames

    func testLeadingDotsAreStrippedEvenBehindLeadingWhitespace() throws {
        for name in [" .notes.png", ".notes.png", " . .notes.png"] {
            let fixture = try makeFixture(appJSON: nil)
            let sourceURL = try makeSourceFile(named: name, contents: Data([1]))
            defer {
                try? FileManager.default.removeItem(at: fixture.vaultURL)
                try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
            }

            let imported = try AttachmentStore.importFile(
                sourceURL,
                documentURL: fixture.documentURL,
                vaultURL: fixture.vaultURL
            )

            XCTAssertEqual(imported.vaultRelativePath, "attachments/notes.png", name)
        }
    }

    // MARK: - Helpers

    /// The note text the editor's binding reads and writes, standing in for
    /// the workspace.
    private final class NoteText: @unchecked Sendable {
        var value: String
        init(_ value: String) { self.value = value }
    }

    /// A plain-text view set up like the editor's, so no automatic
    /// substitution can rewrite text behind the test's back, with an undo
    /// manager of its own so undo works without a window.
    private final class UndoableTextView: NSTextView {
        let testUndoManager = UndoManager()
        override var undoManager: UndoManager? { testUndoManager }
        var documentNSStringLength: Int { (string as NSString).length }
        /// `delegate` is weak, so the view keeps its forwarder alive.
        var editForwarder: EditForwarder?
    }

    @MainActor
    private final class EditForwarder: NSObject, NSTextViewDelegate {
        private let coordinator: SourceEditorView.Coordinator

        init(_ coordinator: SourceEditorView.Coordinator) {
            self.coordinator = coordinator
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            coordinator.textView(textView, shouldChangeTextIn: affectedCharRange, replacementString: replacementString)
        }
    }

    @MainActor
    private func makeTextView(
        _ string: String,
        selection: NSRange,
        coordinator: SourceEditorView.Coordinator?
    ) -> UndoableTextView {
        let textView = UndoableTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.string = string
        textView.setSelectedRange(selection)
        textView.testUndoManager.groupsByEvent = false
        textView.allowsUndo = true
        // The editor's coordinator hears of every edit before it happens,
        // which is how pending imports follow the text. Only that call is
        // forwarded, so the highlighting that follows a text change in the
        // real editor stays out of these tests.
        if let coordinator {
            let forwarder = EditForwarder(coordinator)
            textView.editForwarder = forwarder
            textView.delegate = forwarder
        }
        return textView
    }

    private func makePNGPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setData(Data([1, 2, 3]), forType: .png)
        return pasteboard
    }

    /// An editor coordinator for `documentURL` in `vaultURL` whose text binding
    /// reads and writes `note`, with preferences backed by a throwaway
    /// defaults suite.
    @MainActor
    private func makeCoordinator(
        documentURL: URL?,
        vaultURL: URL?,
        note: NoteText
    ) throws -> SourceEditorView.Coordinator {
        let suiteName = "AttachmentStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        let editor = SourceEditorView(
            text: Binding(get: { note.value }, set: { note.value = $0 }),
            documentURL: documentURL,
            vaultURL: vaultURL,
            noteLinkCompletions: [],
            controller: EditorController(),
            preferences: AppPreferences(userDefaults: defaults),
            savedSelection: nil,
            onSelectionChange: { _, _ in }
        )
        return SourceEditorView.Coordinator(editor)
    }

    /// A real 2×2 TIFF, the kind a screenshot puts on the pasteboard.
    private func makeTIFFData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.tiffRepresentation)
    }

    /// A file outside any vault, in its own temporary folder so a fixed name
    /// never collides with another test's file.
    private func makeSourceFile(named name: String, contents: Data) throws -> URL {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentStoreSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let fileURL = folderURL.appendingPathComponent(name)
        try contents.write(to: fileURL)
        return fileURL
    }

    /// `attachmentFolderURL` returns symlink-resolved, standardized paths;
    /// compare against the same form of the expected location.
    private func resolvedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func makeFixture(appJSON: String?) throws -> (vaultURL: URL, documentURL: URL) {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        let documentURL = vaultURL.appendingPathComponent("Notes/Note.md")
        try FileManager.default.createDirectory(
            at: documentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# Note".write(to: documentURL, atomically: true, encoding: .utf8)

        if let appJSON {
            let obsidianURL = vaultURL.appendingPathComponent(".obsidian", isDirectory: true)
            try FileManager.default.createDirectory(at: obsidianURL, withIntermediateDirectories: true)
            try appJSON.write(
                to: obsidianURL.appendingPathComponent("app.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        return (vaultURL, documentURL)
    }
}

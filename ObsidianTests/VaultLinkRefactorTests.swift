import Foundation
import XCTest

@testable import Obsidian

final class VaultLinkRefactorTests: XCTestCase {
    func testRenameUpdatesWikiMarkdownAndAttachmentLinks() throws {
        let vault = URL(fileURLWithPath: "/Vault", isDirectory: true)
        let old = vault.appendingPathComponent("Notes/Old.md")
        let new = vault.appendingPathComponent("Archive/New.md")
        let source = vault.appendingPathComponent("Index.md")
        let photo = vault.appendingPathComponent("Notes/photo.png")
        let notes = [
            VaultLinkNoteSnapshot(url: old, body: "# Old", aliases: []),
            VaultLinkNoteSnapshot(
                url: source,
                body: "[[Old]] [[Notes/Old]] [note](Notes/Old.md) ![](Notes/photo.png) ![[Notes/photo.png]]",
                aliases: []
            ),
        ]

        let edits = VaultLinkRefactor.edits(
            notes: notes,
            moving: vault.appendingPathComponent("Notes", isDirectory: true),
            to: vault.appendingPathComponent("Archive", isDirectory: true),
            sourceIsDirectory: true,
            vaultURL: vault,
            assetURLs: [photo]
        )
        let updated = try XCTUnwrap(edits.first(where: { $0.originalURL == source })).updatedBody

        XCTAssertTrue(updated.contains("[[Old]]"), "Folder moves preserve a note's basename")
        XCTAssertTrue(updated.contains("[[Archive/Old]]"))
        XCTAssertTrue(updated.contains("[note](Archive/Old.md)"))
        XCTAssertTrue(updated.contains("![](Archive/photo.png)"))
        XCTAssertTrue(updated.contains("![[Archive/photo.png]]"))
    }

    func testRenameSkipsLinksInsideCodeFencesAndInlineCode() throws {
        let vault = URL(fileURLWithPath: "/Vault", isDirectory: true)
        let old = vault.appendingPathComponent("Old.md")
        let new = vault.appendingPathComponent("New.md")
        let source = vault.appendingPathComponent("Index.md")
        let body = """
        See [[Old]].
        `[[Old]]`
        ```
        [[Old]]
        [Old](Old.md)
        ```
        """

        let edits = VaultLinkRefactor.edits(
            notes: [
                VaultLinkNoteSnapshot(url: old, body: "# Old", aliases: []),
                VaultLinkNoteSnapshot(url: source, body: body, aliases: []),
            ],
            moving: old,
            to: new,
            sourceIsDirectory: false,
            vaultURL: vault
        )
        let updated = try XCTUnwrap(edits.first(where: { $0.originalURL == source })).updatedBody

        XCTAssertTrue(updated.contains("See [[New]]."))
        XCTAssertTrue(updated.contains("`[[Old]]`"))
        XCTAssertTrue(updated.contains("[[Old]]\n[Old](Old.md)"))
    }

    func testReplaceIfCurrentRejectsChangedBodies() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("Note.md")
        try Data("expected".utf8).write(to: url)

        XCTAssertFalse(try VaultLinkRefactor.replaceIfCurrent(
            at: url,
            expected: "stale",
            replacement: "replacement"
        ))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "expected")

        XCTAssertTrue(try VaultLinkRefactor.replaceIfCurrent(
            at: url,
            expected: "expected",
            replacement: "replacement"
        ))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "replacement")
    }

    func testSingleNoteRenameUpdatesBareWikiTarget() throws {
        let vault = URL(fileURLWithPath: "/Vault", isDirectory: true)
        let old = vault.appendingPathComponent("Old.md")
        let new = vault.appendingPathComponent("New.md")
        let source = vault.appendingPathComponent("Index.md")
        let edits = VaultLinkRefactor.edits(
            notes: [
                VaultLinkNoteSnapshot(url: old, body: "# Old", aliases: []),
                VaultLinkNoteSnapshot(url: source, body: "See [[Old|label]].", aliases: []),
            ],
            moving: old,
            to: new,
            sourceIsDirectory: false,
            vaultURL: vault
        )
        XCTAssertEqual(
            try XCTUnwrap(edits.first(where: { $0.originalURL == source })).updatedBody,
            "See [[New|label]]."
        )
    }

    func testAmbiguousBareWikiTargetIsNotRewritten() {
        let vault = URL(fileURLWithPath: "/Vault", isDirectory: true)
        let first = vault.appendingPathComponent("One/Shared.md")
        let second = vault.appendingPathComponent("Two/Shared.md")
        let renamed = vault.appendingPathComponent("One/Renamed.md")
        let source = vault.appendingPathComponent("Index.md")

        let edits = VaultLinkRefactor.edits(
            notes: [
                VaultLinkNoteSnapshot(url: first, body: "# First", aliases: []),
                VaultLinkNoteSnapshot(url: second, body: "# Second", aliases: []),
                VaultLinkNoteSnapshot(url: source, body: "See [[Shared]].", aliases: []),
            ],
            moving: first,
            to: renamed,
            sourceIsDirectory: false,
            vaultURL: vault
        )

        XCTAssertNil(edits.first(where: { $0.originalURL == source }))
    }

    func testRollbackDoesNotOverwriteNewerExternalEdit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appendingPathComponent("First.md")
        let secondURL = directory.appendingPathComponent("Second.md")
        try Data("first original".utf8).write(to: firstURL)
        try Data("second external".utf8).write(to: secondURL)
        let edits = [
            VaultLinkRefactorEdit(
                originalURL: firstURL,
                destinationURL: firstURL,
                originalBody: "first original",
                updatedBody: "first updated"
            ),
            VaultLinkRefactorEdit(
                originalURL: secondURL,
                destinationURL: secondURL,
                originalBody: "second original",
                updatedBody: "second updated"
            ),
        ]

        XCTAssertThrowsError(try VaultLinkRefactor.apply(edits) { edit in
            if edit.destinationURL == firstURL {
                try? Data("first external after refactor".utf8).write(to: firstURL, options: .atomic)
            }
        })

        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), "first external after refactor")
        XCTAssertEqual(try String(contentsOf: secondURL, encoding: .utf8), "second external")
    }

    func testWikiAndMarkdownLinksAreRewrittenTogetherAroundCode() throws {
        let vault = URL(fileURLWithPath: "/Vault", isDirectory: true)
        let old = vault.appendingPathComponent("Old.md")
        let new = vault.appendingPathComponent("New.md")
        let source = vault.appendingPathComponent("Index.md")
        let body = "[[Old]] `[[Old]]` [note](Old.md) ![[Old.md]] `[x](Old.md)`"

        let edits = VaultLinkRefactor.edits(
            notes: [
                VaultLinkNoteSnapshot(url: old, body: "# Old", aliases: []),
                VaultLinkNoteSnapshot(url: source, body: body, aliases: []),
            ],
            moving: old,
            to: new,
            sourceIsDirectory: false,
            vaultURL: vault
        )

        XCTAssertEqual(
            try XCTUnwrap(edits.first(where: { $0.originalURL == source })).updatedBody,
            "[[New]] `[[Old]]` [note](New.md) ![[New.md]] `[x](Old.md)`"
        )
    }

    func testRenameRewritesLinksAfterMultiUnitCodeAndInCRLFNotes() throws {
        let vault = URL(fileURLWithPath: "/Vault", isDirectory: true)
        let old = vault.appendingPathComponent("Old.md")
        let new = vault.appendingPathComponent("New.md")
        let emojiSource = vault.appendingPathComponent("Emoji.md")
        let crlfSource = vault.appendingPathComponent("Windows.md")

        let edits = VaultLinkRefactor.edits(
            notes: [
                VaultLinkNoteSnapshot(url: old, body: "# Old", aliases: []),
                // Each masked emoji or combining sequence is one Character but
                // two UTF-16 code units; masking it with a single space shifted
                // every later range read back out of the body.
                VaultLinkNoteSnapshot(url: emojiSource, body: "`👍 e\u{301}` [[Old]] [note](Old.md)", aliases: []),
                // "\r\n" is one Character, so a CRLF note was never split into
                // lines and its opening fence masked the whole note.
                VaultLinkNoteSnapshot(url: crlfSource, body: "```\r\n[[Old]]\r\n```\r\nSee [[Old]].\r\n", aliases: []),
            ],
            moving: old,
            to: new,
            sourceIsDirectory: false,
            vaultURL: vault
        )

        XCTAssertEqual(
            try XCTUnwrap(edits.first(where: { $0.originalURL == emojiSource })).updatedBody,
            "`👍 e\u{301}` [[New]] [note](New.md)"
        )
        XCTAssertEqual(
            try XCTUnwrap(edits.first(where: { $0.originalURL == crlfSource })).updatedBody,
            "```\r\n[[Old]]\r\n```\r\nSee [[New]].\r\n"
        )
    }
}

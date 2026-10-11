import Foundation
import XCTest

@testable import Obsidian

final class VaultHealthTests: XCTestCase {
    func testFindsBrokenLinksMissingAttachmentsDuplicatesAndFrontmatter() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let notes = [
            VaultHealthNote(
                url: vault.appendingPathComponent("One.md"),
                title: "Same",
                body: "---\ntitle: Broken\n[[Missing]]\n![](missing.png)"
            ),
            VaultHealthNote(
                url: vault.appendingPathComponent("Two.md"),
                title: "Same",
                body: "# Two"
            ),
        ]

        let report = VaultHealthScanner.scan(vaultURL: vault, notes: notes)
        XCTAssertEqual(report.errorCount, 2, "The wiki link and the image are both missing")
        XCTAssertEqual(report.warningCount, 2, "One duplicate target plus one unterminated frontmatter block")
        XCTAssertTrue(report.issues.contains { $0.title == "Unterminated frontmatter" })
        XCTAssertEqual(report.issues.filter { $0.title == "Duplicate note target" }.count, 1)
    }

    func testNotesWhoseStemTitleAndHeadingCoincideAreNotDuplicates() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let notes = [
            VaultHealthNote(url: vault.appendingPathComponent("Two.md"), title: "Two", body: "Plain text"),
            VaultHealthNote(url: vault.appendingPathComponent("Old.md"), title: "Old", body: "# Old"),
        ]

        let report = VaultHealthScanner.scan(vaultURL: vault, notes: notes)
        XCTAssertFalse(report.issues.contains { $0.title == "Duplicate note target" })
        XCTAssertEqual(report.warningCount, 0)
    }

    func testSharedAliasAcrossDifferentNotesIsReportedOnce() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let notes = [
            VaultHealthNote(
                url: vault.appendingPathComponent("A.md"),
                title: "A",
                body: "---\naliases: [Shared]\n---\n# A"
            ),
            VaultHealthNote(
                url: vault.appendingPathComponent("B.md"),
                title: "B",
                body: "---\naliases:\n  - shared\n---\n# B"
            ),
        ]

        let report = VaultHealthScanner.scan(vaultURL: vault, notes: notes)
        let duplicates = report.issues.filter { $0.title == "Duplicate note target" }
        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates.first?.detail, "“shared” resolves to 2 notes.")
    }

    func testIgnoresLinksInsideCodeRegions() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        let body = """
        Inline `[[Missing]]` example.
        ```
        [[Also Missing]]
        ![](nope.png)
        ```
        """
        let report = VaultHealthScanner.scan(
            vaultURL: vault,
            notes: [VaultHealthNote(url: vault.appendingPathComponent("Code.md"), title: "Code", body: body)]
        )

        XCTAssertEqual(report.errorCount, 0)
    }

    func testFrontmatterCheckMatchesTheMetadataParser() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        func frontmatterIssues(for body: String) -> [VaultHealthIssue] {
            VaultHealthScanner.scan(
                vaultURL: vault,
                notes: [VaultHealthNote(url: vault.appendingPathComponent("Note.md"), title: "Note", body: body)]
            ).issues.filter { $0.title == "Unterminated frontmatter" }
        }

        XCTAssertTrue(frontmatterIssues(for: "---\nA thematic break, not a property block.").isEmpty)
        XCTAssertTrue(frontmatterIssues(for: "\u{feff}---\ntitle: Closed\n---\nBody").isEmpty)
        XCTAssertEqual(frontmatterIssues(for: "\u{feff}---\ntitle: Open\nBody").count, 1)
        XCTAssertEqual(frontmatterIssues(for: "---\ntitle: Open\nBody").first?.severity, .warning)
    }

    func testUnterminatedFrontmatterRecognizesAnyParserAcceptedKey() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }

        func flagged(_ body: String) -> Bool {
            VaultHealthScanner.scan(
                vaultURL: vault,
                notes: [VaultHealthNote(url: vault.appendingPathComponent("Note.md"), title: "Note", body: body)]
            ).issues.contains { $0.title == "Unterminated frontmatter" }
        }

        XCTAssertTrue(flagged("---\nDue date: 2026-10-11\ntags: [x]\nBody"))
        XCTAssertTrue(flagged("---\nt\u{ED}tulo: x\nBody"))
        XCTAssertTrue(flagged("---\n\"quoted key\": x\nBody"))
        XCTAssertTrue(flagged("---\n\n# comment\ntitle: x\nBody"))
        XCTAssertFalse(flagged("---\n- item: not a key\nBody"))
        XCTAssertFalse(flagged("---\n  indented: no\nBody"))
        XCTAssertFalse(flagged("---\nPlain prose without a colon\nBody"))
        XCTAssertFalse(flagged("---\n\nJust a paragraph after a rule."))
    }

    private func makeVault() throws -> URL {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultHealthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        return vault
    }
}

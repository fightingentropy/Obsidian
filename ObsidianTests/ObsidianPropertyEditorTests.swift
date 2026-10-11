import XCTest

@testable import Obsidian

final class ObsidianPropertyEditorTests: XCTestCase {
    func testAddsFrontmatterWithoutChangingBody() throws {
        let updated = try ObsidianPropertyEditor.setting(
            key: "tags",
            value: .strings(["work", "deep/research"]),
            in: "# Note\nBody"
        )
        XCTAssertEqual(updated, "---\ntags: [\"work\", \"deep/research\"]\n---\n# Note\nBody")
    }

    func testReplacesListPropertyLosslesslyAroundOtherProperties() throws {
        let markdown = "---\r\ntitle: Keep\r\ntags:\r\n  - old\r\nstatus: active\r\n---\r\nBody"
        let updated = try ObsidianPropertyEditor.setting(
            key: "tags",
            value: .strings(["new"]),
            in: markdown
        )
        XCTAssertEqual(updated, "---\r\ntitle: Keep\r\ntags: [\"new\"]\r\nstatus: active\r\n---\r\nBody")
    }

    func testRemovesPropertyAndPreservesRest() throws {
        XCTAssertEqual(
            try ObsidianPropertyEditor.setting(
                key: "aliases",
                value: nil,
                in: "---\naliases: [A, B]\nstatus: active\n---\nBody"
            ),
            "---\nstatus: active\n---\nBody"
        )
    }

    func testEditsBOMPrefixedNoteAndKeepsTheBOM() throws {
        let updated = try ObsidianPropertyEditor.setting(
            key: "status",
            value: .string("done"),
            in: "\u{feff}---\nstatus: draft\n---\nBody"
        )
        XCTAssertEqual(updated, "\u{feff}---\nstatus: \"done\"\n---\nBody")
    }

    func testColumnZeroListItemsStayWithTheirKey() throws {
        let updated = try ObsidianPropertyEditor.setting(
            key: "links",
            value: .strings(["c"]),
            in: "---\nlinks:\n- url: a\n- url: b\nstatus: active\n---\nBody"
        )
        XCTAssertEqual(updated, "---\nlinks: [\"c\"]\nstatus: active\n---\nBody")
    }

    func testWritesIntegralNumbersWithoutFractionalPart() throws {
        XCTAssertEqual(
            try ObsidianPropertyEditor.setting(key: "priority", value: .number(3), in: "Body"),
            "---\npriority: 3\n---\nBody"
        )
        XCTAssertEqual(
            try ObsidianPropertyEditor.setting(key: "weight", value: .number(2.5), in: "Body"),
            "---\nweight: 2.5\n---\nBody"
        )
    }
}

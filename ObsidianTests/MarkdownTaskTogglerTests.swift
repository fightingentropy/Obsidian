import Foundation
import XCTest

@testable import Obsidian

final class MarkdownTaskTogglerTests: XCTestCase {
    func testTogglesOpenAndCompletedTasks() {
        let text = "- [ ] One\n- [x] Two"
        let result = MarkdownTaskToggler.toggle(
            in: text,
            selection: NSRange(location: 0, length: (text as NSString).length)
        )
        XCTAssertEqual(result.text, "- [x] One\n- [ ] Two")
    }

    func testTurnsPlainLineIntoTaskPreservingIndentation() {
        let text = "  Remember this"
        let result = MarkdownTaskToggler.toggle(
            in: text,
            selection: NSRange(location: 4, length: 0)
        )
        XCTAssertEqual(result.text, "  - [ ] Remember this")
    }

    func testPreservesCRLFLineEndingsAndTogglesEveryTask() {
        let text = "- [ ] One\r\n- [x] Two\r\n"
        let result = MarkdownTaskToggler.toggle(
            in: text,
            selection: NSRange(location: 0, length: (text as NSString).length)
        )
        XCTAssertEqual(result.text, "- [x] One\r\n- [ ] Two\r\n")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: (result.text as NSString).length))
    }

    func testBlankLineBetweenSelectedTasksStaysBlank() {
        let text = "- [ ] One\n\n- [ ] Two"
        let result = MarkdownTaskToggler.toggle(
            in: text,
            selection: NSRange(location: 0, length: (text as NSString).length)
        )
        XCTAssertEqual(result.text, "- [x] One\n\n- [x] Two")
    }

    func testCaretOnSingleLineKeepsItsNewline() {
        let text = "- [ ] One\nNext"
        let result = MarkdownTaskToggler.toggle(in: text, selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(result.text, "- [x] One\nNext")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 10))
    }

    func testCaretOnLoneBlankLineStartsATask() {
        let text = "Intro\n\nOutro"
        let result = MarkdownTaskToggler.toggle(in: text, selection: NSRange(location: 6, length: 0))
        XCTAssertEqual(result.text, "Intro\n- [ ] \nOutro")
    }
}

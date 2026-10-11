import Foundation
import XCTest

@testable import Obsidian

final class EditorTextCountsTests: XCTestCase {
    func testEmptyAndWhitespaceOnlyTextHasNoWordsOrParagraphs() {
        XCTAssertEqual(EditorTextCounts.compute(for: ""), .zero)
        assertCounts("", words: 0, characters: 0, paragraphs: 0)
        assertCounts("   ", words: 0, characters: 3, paragraphs: 0)
    }

    func testSingleLineIsOneParagraph() {
        assertCounts("one two", words: 2, characters: 7, paragraphs: 1)
    }

    func testBlankLinesSeparateParagraphs() {
        assertCounts("a\n\nb", words: 2, characters: 4, paragraphs: 2)
        // Consecutive non-blank lines form one paragraph, and a trailing
        // newline adds none.
        assertCounts("a\nb\n\n\nc d\n", words: 4, characters: 10, paragraphs: 2)
        // A line holding only whitespace is blank.
        assertCounts("a\n   \nb", words: 2, characters: 7, paragraphs: 2)
        // CRLF is a single grapheme cluster.
        assertCounts("a\r\n\r\nb", words: 2, characters: 4, paragraphs: 2)
    }

    func testUnicodeWhitespaceSplitsWords() {
        assertCounts("tab\tsep\u{00A0}nbsp", words: 3, characters: 12, paragraphs: 1)
    }

    func testCharactersCountGraphemeClustersNotScalars() {
        assertCounts("e\u{0301}", words: 1, characters: 1, paragraphs: 1)
        assertCounts("\u{1F44D}\u{1F3FD}", words: 1, characters: 1, paragraphs: 1)
        assertCounts("\u{1F1FA}\u{1F1F8}", words: 1, characters: 1, paragraphs: 1)
        assertCounts(
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}",
            words: 1, characters: 1, paragraphs: 1)
    }

    private func assertCounts(
        _ text: String,
        words: Int,
        characters: Int,
        paragraphs: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            EditorTextCounts.compute(for: text),
            EditorTextCounts(words: words, characters: characters, paragraphs: paragraphs),
            text.debugDescription,
            file: file,
            line: line
        )
    }
}

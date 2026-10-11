import AppKit
import XCTest

@testable import Obsidian

@MainActor
final class SyntaxHighlighterTests: XCTestCase {
    func testHighlightsHeadingAndInlineBold() {
        let storage = makeStorage("# Title with **bold**")

        let headingIndex = index(of: "Title", in: storage)
        let headingMarkerIndex = index(of: "#", in: storage)
        let boldIndex = index(of: "bold", in: storage)
        let boldMarkerIndex = index(of: "**", in: storage)

        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: headingIndex, effectiveRange: nil) as? NSColor,
            Theme.headingColor
        )
        XCTAssertTrue(
            (storage.attribute(.font, at: boldIndex, effectiveRange: nil) as? NSFont)?
                .fontDescriptor
                .symbolicTraits
                .contains(.bold) == true
        )
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: headingMarkerIndex, effectiveRange: nil) as? NSColor,
            Theme.metaColor
        )
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: boldMarkerIndex, effectiveRange: nil) as? NSColor,
            Theme.metaColor
        )
    }

    func testHighlightsMarkdownAndBareLinks() {
        let storage = makeStorage("[link](https://example.com)\nhttps://example.com")

        let markdownLinkIndex = index(of: "link", in: storage)
        let markdownDestinationIndex = index(of: "https://example.com", in: storage)
        let bareLinkIndex = index(of: "https://example.com", in: storage, occurrence: 2)

        XCTAssertEqual(
            storage.attribute(.underlineStyle, at: markdownLinkIndex, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: markdownDestinationIndex, effectiveRange: nil) as? NSColor,
            Theme.metaColor
        )
        XCTAssertEqual(
            storage.attribute(.underlineStyle, at: markdownDestinationIndex, effectiveRange: nil) as? Int,
            0
        )
        XCTAssertEqual(
            storage.attribute(.underlineStyle, at: bareLinkIndex, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
    }

    func testHighlightsInlineCodeAndCodeBlocks() {
        let storage = makeStorage("`code`\n\n```swift\nlet value = 1\n```")

        let inlineCodeIndex = index(of: "code", in: storage)
        let codeBlockIndex = index(of: "let value = 1", in: storage)

        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: inlineCodeIndex, effectiveRange: nil) as? NSColor,
            Theme.codeBackground
        )
        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: codeBlockIndex, effectiveRange: nil) as? NSColor,
            Theme.codeBackground
        )
    }

    func testHighlightsQuotesListsAndHorizontalRules() {
        let storage = makeStorage("> Quote\n  - item\n12. numbered\n---")

        let quoteIndex = index(of: "Quote", in: storage)
        let unorderedMarkerIndex = index(of: "-", in: storage)
        let orderedMarkerIndex = index(of: "12.", in: storage)
        let horizontalRuleIndex = index(of: "---", in: storage)

        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: quoteIndex, effectiveRange: nil) as? NSColor,
            Theme.quoteColor
        )
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: unorderedMarkerIndex, effectiveRange: nil) as? NSColor,
            Theme.metaColor
        )
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: orderedMarkerIndex, effectiveRange: nil) as? NSColor,
            Theme.metaColor
        )
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: horizontalRuleIndex, effectiveRange: nil) as? NSColor,
            Theme.metaColor
        )
    }

    func testHighlightsTildeFencedCodeBlocks() {
        let storage = makeStorage("~~~swift\nlet value = 1\n~~~\nafter **bold**")

        let codeIndex = index(of: "let value = 1", in: storage)
        let afterIndex = index(of: "after", in: storage)
        let boldIndex = index(of: "bold", in: storage)

        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: codeIndex, effectiveRange: nil) as? NSColor,
            Theme.codeBackground
        )
        XCTAssertNil(storage.attribute(.backgroundColor, at: afterIndex, effectiveRange: nil))
        XCTAssertTrue(isBold(at: boldIndex, in: storage))
    }

    func testClosingFenceMustUseTheOpeningFenceCharacter() {
        let storage = makeStorage("```\ncode\n~~~\nstill code\n```\nafter **bold**")

        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: index(of: "~~~", in: storage), effectiveRange: nil) as? NSColor,
            Theme.codeBackground
        )
        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: index(of: "still code", in: storage), effectiveRange: nil) as? NSColor,
            Theme.codeBackground
        )
        XCTAssertNil(storage.attribute(.backgroundColor, at: index(of: "after", in: storage), effectiveRange: nil))
        XCTAssertTrue(isBold(at: index(of: "bold", in: storage), in: storage))
    }

    func testClosingFenceMustBeAtLeastAsLongAsTheOpeningFence() {
        let storage = makeStorage("````\ncode\n```\nstill code\n`````\nafter **bold**")

        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: index(of: "still code", in: storage), effectiveRange: nil) as? NSColor,
            Theme.codeBackground
        )
        XCTAssertNil(storage.attribute(.backgroundColor, at: index(of: "after", in: storage), effectiveRange: nil))
        XCTAssertTrue(isBold(at: index(of: "bold", in: storage), in: storage))
    }

    func testIncrementalRangeReportsParagraphCodeBlockOrFullPass() {
        let text = "# Title\n\n```\ncode\n```\nfooter"
        let nsText = text as NSString
        let storage = NSTextStorage(string: text)
        let highlighter = SyntaxHighlighter(preferences: AppPreferences())

        let titleEdit = NSRange(location: nsText.range(of: "Title").location, length: 1)
        XCTAssertEqual(
            highlighter.incrementalRange(for: titleEdit, in: storage),
            SyntaxHighlighter.IncrementalRange(range: nsText.range(of: "# Title\n"), codeBlockState: .outsideCodeBlock)
        )

        let codeEdit = NSRange(location: nsText.range(of: "code").location, length: 1)
        XCTAssertEqual(
            highlighter.incrementalRange(for: codeEdit, in: storage),
            SyntaxHighlighter.IncrementalRange(range: nsText.range(of: "```\ncode\n```"), codeBlockState: .wholeCodeBlock)
        )

        let footerEdit = NSRange(location: nsText.range(of: "footer").location + 2, length: 0)
        XCTAssertEqual(
            highlighter.incrementalRange(for: footerEdit, in: storage),
            SyntaxHighlighter.IncrementalRange(range: nsText.range(of: "footer"), codeBlockState: .outsideCodeBlock)
        )

        let fenceEdit = NSRange(location: nsText.range(of: "```").location, length: 1)
        XCTAssertNil(highlighter.incrementalRange(for: fenceEdit, in: storage))
        XCTAssertNil(highlighter.incrementalRange(for: nil, in: storage))

        let emptyStorage = NSTextStorage(string: "")
        XCTAssertEqual(
            highlighter.incrementalRange(for: NSRange(location: 0, length: 0), in: emptyStorage),
            SyntaxHighlighter.IncrementalRange(range: NSRange(location: 0, length: 0), codeBlockState: .outsideCodeBlock)
        )
    }

    func testUnterminatedCodeBlockExtendsToEndOfDocument() {
        let text = "intro\n~~~\ncode\nmore"
        let nsText = text as NSString
        let storage = NSTextStorage(string: text)
        let highlighter = SyntaxHighlighter(preferences: AppPreferences())

        let moreEdit = NSRange(location: nsText.range(of: "more").location, length: 1)
        XCTAssertEqual(
            highlighter.incrementalRange(for: moreEdit, in: storage),
            SyntaxHighlighter.IncrementalRange(range: nsText.range(of: "~~~\ncode\nmore"), codeBlockState: .wholeCodeBlock)
        )

        highlighter.highlight(storage)
        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: index(of: "more", in: storage), effectiveRange: nil) as? NSColor,
            Theme.codeBackground
        )
        XCTAssertNil(storage.attribute(.backgroundColor, at: index(of: "intro", in: storage), effectiveRange: nil))
    }

    func testIncrementalHighlightMatchesFullPass() throws {
        let highlighter = SyntaxHighlighter(preferences: AppPreferences())
        let storage = NSTextStorage(string: "# Title\n\nplain\n\n```\ncode\n```\n[[Note]]")
        highlighter.highlight(storage)

        // Typing inside a paragraph outside any fence recolors that paragraph.
        let plainLocation = index(of: "plain", in: storage)
        let boldInsertion = "**bold** "
        storage.replaceCharacters(in: NSRange(location: plainLocation, length: 0), with: boldInsertion)
        let paragraphEdit = NSRange(location: plainLocation, length: (boldInsertion as NSString).length)
        let paragraph = try XCTUnwrap(highlighter.incrementalRange(for: paragraphEdit, in: storage))
        XCTAssertEqual(paragraph.codeBlockState, .outsideCodeBlock)
        highlighter.highlight(storage, range: paragraph.range, codeBlockState: paragraph.codeBlockState)

        XCTAssertTrue(isBold(at: index(of: "bold", in: storage), in: storage))
        assertAttributesMatchFullPass(storage, highlighter: highlighter)

        // Typing inside a code block recolors the whole block as code.
        let codeLocation = index(of: "code", in: storage)
        let codeInsertion = "**not bold** "
        storage.replaceCharacters(in: NSRange(location: codeLocation, length: 0), with: codeInsertion)
        let codeEdit = NSRange(location: codeLocation, length: (codeInsertion as NSString).length)
        let block = try XCTUnwrap(highlighter.incrementalRange(for: codeEdit, in: storage))
        XCTAssertEqual(block.codeBlockState, .wholeCodeBlock)
        highlighter.highlight(storage, range: block.range, codeBlockState: block.codeBlockState)

        XCTAssertFalse(isBold(at: index(of: "not bold", in: storage), in: storage))
        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: index(of: "not bold", in: storage), effectiveRange: nil) as? NSColor,
            Theme.codeBackground
        )
        assertAttributesMatchFullPass(storage, highlighter: highlighter)
    }

    private func assertAttributesMatchFullPass(
        _ storage: NSTextStorage,
        highlighter: SyntaxHighlighter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = NSTextStorage(string: storage.string)
        highlighter.highlight(expected)
        XCTAssertEqual(storage.length, expected.length, file: file, line: line)

        let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .underlineStyle, .paragraphStyle]
        for location in 0..<min(storage.length, expected.length) {
            for key in keys {
                XCTAssertEqual(
                    storage.attribute(key, at: location, effectiveRange: nil) as? NSObject,
                    expected.attribute(key, at: location, effectiveRange: nil) as? NSObject,
                    "\(key.rawValue) differs from the full pass at \(location)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func isBold(at location: Int, in storage: NSTextStorage) -> Bool {
        (storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?
            .fontDescriptor
            .symbolicTraits
            .contains(.bold) == true
    }

    private func makeStorage(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        SyntaxHighlighter(preferences: AppPreferences()).highlight(storage)
        return storage
    }

    private func index(of substring: String, in storage: NSTextStorage, occurrence: Int = 1) -> Int {
        let nsText = storage.string as NSString
        var searchRange = NSRange(location: 0, length: nsText.length)

        for _ in 1..<occurrence {
            let found = nsText.range(of: substring, options: [], range: searchRange)
            XCTAssertNotEqual(found.location, NSNotFound)
            let nextLocation = NSMaxRange(found)
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }

        let range = nsText.range(of: substring, options: [], range: searchRange)
        XCTAssertNotEqual(range.location, NSNotFound)
        return range.location
    }
}

import Foundation
import XCTest

@testable import Obsidian

final class UnlinkedMentionsTests: XCTestCase {
    func testFindsPlainMentionsButSkipsExistingLinksAndPartialWords() {
        let source = URL(fileURLWithPath: "/tmp/Source.md")
        let mentions = UnlinkedMentionFinder.find(
            targetNames: ["Project Atlas", "Atlas"],
            sources: [(
                source,
                "Source",
                "Project Atlas is active. [[Project Atlas]] and Atlasian are not unlinked mentions."
            )],
            excluding: nil
        )

        XCTAssertEqual(mentions.count, 1)
        XCTAssertEqual(mentions[0].matchedText, "Project Atlas")
        XCTAssertTrue(mentions[0].snippet.contains("active"))
    }

    func testReplacementRefusesStaleBodyAndLinksExactMention() throws {
        let source = URL(fileURLWithPath: "/tmp/Source.md")
        let body = "Read Atlas today."
        let mention = try XCTUnwrap(UnlinkedMentionFinder.find(
            targetNames: ["Atlas"],
            sources: [(source, "Source", body)],
            excluding: nil
        ).first)

        XCTAssertEqual(
            UnlinkedMentionFinder.replacingMention(mention, in: body),
            "Read [[Atlas]] today."
        )
        XCTAssertNil(UnlinkedMentionFinder.replacingMention(mention, in: body + " Changed"))
    }

    func testSkipsTheTargetNoteItself() {
        let target = URL(fileURLWithPath: "/tmp/Atlas.md")
        let other = URL(fileURLWithPath: "/tmp/Other.md")
        let mentions = UnlinkedMentionFinder.find(
            targetNames: ["Atlas"],
            sources: [
                (target, "Atlas", "Atlas mentions itself."),
                (other, "Other", "Atlas is mentioned here."),
            ],
            excluding: URL(fileURLWithPath: "/tmp/./Atlas.md")
        )

        XCTAssertEqual(mentions.map(\.sourceURL), [other])
    }
}

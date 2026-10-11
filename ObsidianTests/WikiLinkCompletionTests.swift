import Foundation
import XCTest

@testable import Obsidian

final class WikiLinkCompletionTests: XCTestCase {
    func testFindsPartialRangeAfterLastOpeningWikiLink() throws {
        let text = "See [[Pro"
        let range = try XCTUnwrap(WikiLinkCompletion.partialRange(
            in: text,
            selection: NSRange(location: (text as NSString).length, length: 0)
        ))
        XCTAssertEqual((text as NSString).substring(with: range), "Pro")
    }

    func testSuppressesCompletionAfterClosingBracketOrOnAnotherLine() {
        let closed = "[[Project]]"
        XCTAssertNil(WikiLinkCompletion.partialRange(
            in: closed,
            selection: NSRange(location: (closed as NSString).length, length: 0)
        ))

        let anotherLine = "[[Project\nNext"
        XCTAssertNil(WikiLinkCompletion.partialRange(
            in: anotherLine,
            selection: NSRange(location: (anotherLine as NSString).length, length: 0)
        ))
    }

    func testRanksPrefixMatchesAndAddsClosingBrackets() {
        XCTAssertEqual(
            WikiLinkCompletion.suggestions(
                for: "pro",
                candidates: ["Work Project", "Profile", "Projects"]
            ),
            ["Profile]]", "Projects]]", "Work Project]]"]
        )
    }

    func testNSStringPartialRangeMatchesStringOverload() throws {
        let text = "Intro [[Done]] and [[Pro"
        let selection = NSRange(location: (text as NSString).length, length: 0)

        let stringRange = try XCTUnwrap(WikiLinkCompletion.partialRange(in: text, selection: selection))
        let nsStringRange = try XCTUnwrap(WikiLinkCompletion.partialRange(in: text as NSString, selection: selection))

        XCTAssertEqual(nsStringRange, stringRange)
        XCTAssertEqual((text as NSString).substring(with: nsStringRange), "Pro")

        let closed = "[[Project]]"
        XCTAssertNil(WikiLinkCompletion.partialRange(
            in: closed as NSString,
            selection: NSRange(location: (closed as NSString).length, length: 0)
        ))
        XCTAssertNil(WikiLinkCompletion.partialRange(
            in: text as NSString,
            selection: NSRange(location: 0, length: 2)
        ))
    }

    func testSuggestionsMatchFoldPerComparisonOracleForManyCandidates() {
        let candidates = makeCandidates(count: 200)
        XCTAssertEqual(candidates.count, 200)

        for query in ["pro", "PRO", "Pró", "cafe", "note", "ARCHIVE", " 1", "", "zzz"] {
            XCTAssertEqual(
                WikiLinkCompletion.suggestions(for: query, candidates: candidates),
                oracleSuggestions(for: query, candidates: candidates),
                "Default limit differs for query \"\(query)\""
            )
            XCTAssertEqual(
                WikiLinkCompletion.suggestions(for: query, candidates: candidates, limit: candidates.count),
                oracleSuggestions(for: query, candidates: candidates, limit: candidates.count),
                "Unlimited result differs for query \"\(query)\""
            )
        }
    }

    /// Deterministic candidate list mixing case, diacritics, digits and
    /// duplicates that only differ by case, so the comparator's tie-breaking
    /// is exercised as well as the prefix/contains split.
    private func makeCandidates(count: Int) -> [String] {
        let stems = [
            "Project", "profile", "Prototype", "Work Project", "Café", "cafe",
            "Résumé", "Note", "note", "Archive", "próximo", "Daily",
        ]
        return (0..<count).map { index in
            let stem = stems[index % stems.count]
            let suffix: String
            switch index % 4 {
            case 0: suffix = " \(index)"
            case 1: suffix = "-\(index * 7 % 13)"
            case 2: suffix = ""
            default: suffix = " v\(index % 3)"
            }
            let name = stem + suffix
            return index % 5 == 0 ? name.uppercased() : name
        }
    }

    /// The previous implementation, which folded inside `filter` and twice per
    /// comparison inside `sorted`; kept verbatim as the ordering oracle.
    private func oracleSuggestions(for partial: String, candidates: [String], limit: Int = 20) -> [String] {
        let query = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let foldedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)

        return candidates
            .filter { candidate in
                foldedQuery.isEmpty || candidate.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: nil
                ).contains(foldedQuery)
            }
            .sorted { lhs, rhs in
                let leftStarts = lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .hasPrefix(foldedQuery)
                let rightStarts = rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .hasPrefix(foldedQuery)
                if leftStarts != rightStarts { return leftStarts }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 + "]]" }
    }
}

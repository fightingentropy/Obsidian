import Foundation
import XCTest

@testable import Obsidian

final class ObsidianAdvancedSearchEvaluatorTests: XCTestCase {
    func testFiltersByTagPropertyTaskPathAndExclusion() {
        let entries = [
            entry(
                title: "Project",
                path: "work/Project.md",
                body: "---\ntags: [swift]\nstatus: active\n---\n- [ ] Ship it"
            ),
            entry(
                title: "Archive",
                path: "archive/Old.md",
                body: "---\ntags: [swift, archive]\nstatus: done\n---\n- [x] Done"
            )
        ]

        let results = ObsidianAdvancedSearchEvaluator.search(
            entries,
            query: "tag:swift property:status=active task:open path:work -tag:archive"
        )

        XCTAssertEqual(results.map(\.title), ["Project"])
    }

    func testSupportsOrGroupsAndExactPhraseSnippet() {
        let entries = [
            entry(title: "One", path: "One.md", body: "The exact phrase is here."),
            entry(title: "Two", path: "Two.md", body: "Nothing relevant."),
        ]

        let results = ObsidianAdvancedSearchEvaluator.search(
            entries,
            query: "\"exact phrase\" OR file:Two"
        )

        XCTAssertEqual(results.map(\.title), ["One", "Two"])
        XCTAssertTrue(results[0].subtitle?.contains("exact phrase") == true)
    }

    func testPlainTextUsesFastRankedSearch() {
        let entries = [
            entry(title: "Body First", path: "Body First.md", body: "A note about markets."),
            entry(title: "Markets Archive", path: "Markets Archive.md", body: ""),
            entry(title: "Markets", path: "Markets.md", body: ""),
        ]

        let results = ObsidianAdvancedSearchEvaluator.search(entries, query: "markets")

        XCTAssertEqual(results.map(\.title), ["Markets", "Markets Archive", "Body First"])
        XCTAssertEqual(results.map(\.isBodyMatch), [false, false, true])
    }

    func testPlainTextRoutingRecognizesOnlyActualAdvancedSyntax() {
        XCTAssertEqual(
            ObsidianAdvancedSearchParser.plainTextQuery(in: "interface craft"),
            "interface craft"
        )
        XCTAssertEqual(
            ObsidianAdvancedSearchParser.plainTextQuery(in: "\"exact phrase\""),
            "exact phrase"
        )
        XCTAssertNil(ObsidianAdvancedSearchParser.plainTextQuery(in: "tag:swift"))
        XCTAssertNil(ObsidianAdvancedSearchParser.plainTextQuery(in: "project OR archive"))
        XCTAssertNil(ObsidianAdvancedSearchParser.plainTextQuery(in: "-draft"))
    }

    func testAdvancedSearchUsesCachedSearchMetadata() {
        let cachedMetadata = ObsidianSearchMetadata(tags: ["swift"], properties: [:])
        let entries = [
            entry(
                title: "Cached",
                path: "Cached.md",
                body: "Body deliberately contains no tag.",
                searchMetadata: cachedMetadata
            )
        ]

        XCTAssertEqual(
            ObsidianAdvancedSearchEvaluator.search(entries, query: "tag:swift").map(\.title),
            ["Cached"]
        )
    }

    func testConcurrentFiltersShareNoteBodiesWithoutChangingResults() async {
        let entries = [
            entry(
                title: "Project",
                path: "work/Project.md",
                body: "---\ntags: [swift]\nstatus: active\n---\n- [ ] Ship it"
            ),
            entry(
                title: "Archive",
                path: "archive/Old.md",
                body: "---\ntags: [archive]\nstatus: done\n---\n- [x] Done"
            )
        ]

        let outputs = await withTaskGroup(of: [String].self, returning: [[String]].self) { group in
            for _ in 0..<24 {
                group.addTask {
                    ObsidianAdvancedSearchEvaluator.search(
                        entries,
                        query: "tag:swift property:status=active task:open"
                    ).map(\.title)
                }
            }
            var outputs: [[String]] = []
            for await output in group { outputs.append(output) }
            return outputs
        }

        XCTAssertEqual(outputs.count, 24)
        XCTAssertTrue(outputs.allSatisfy { $0 == ["Project"] })
    }

    func testTaskFiltersPreserveMarkersLineEndingsAndUnicodeMatching() {
        let entries = [
            entry(title: "Open", path: "Open.md", body: "Preamble\r\n\t+ [ ] Ship\r\n"),
            entry(title: "Done", path: "Done.md", body: "Intro\n  * [X] Re\u{301}sume\u{301}\u{2028}- [x] Done"),
            entry(title: "Other", path: "Other.md", body: "- [y] Not a task\nInline - [ ] Not a task")
        ]

        for (query, expected) in [
            ("task:any", ["Open", "Done"]),
            ("task:open", ["Open"]),
            ("task:done", ["Done"]),
            ("task:resume", ["Done"]),
            ("-task:any", ["Other"])
        ] {
            XCTAssertEqual(ObsidianAdvancedSearchEvaluator.search(entries, query: query).map(\.title), expected)
        }
    }

    func testTextPredicateFoldsCaseAndDiacriticsAcrossTitlePathAndBody() {
        let entries = [
            entry(title: "Cafe\u{301}", path: "menu/Cafe.md", body: "Espresso only."),
            entry(title: "Été", path: "saisons/E\u{301}te\u{301}.md", body: "chaleur"),
            entry(title: "Plain", path: "Plain.md", body: "A re\u{301}sume\u{301} inside the body."),
            entry(title: "Notes", path: "Archives/misc.md", body: "nothing here"),
        ]

        // `-tag:` keeps every query on the advanced evaluator path.
        XCTAssertEqual(
            ObsidianAdvancedSearchEvaluator.search(entries, query: "CAFE -tag:archive").map(\.title),
            ["Café"]
        )
        XCTAssertEqual(
            ObsidianAdvancedSearchEvaluator.search(entries, query: "ete -tag:archive").map(\.title),
            ["Été"]
        )
        XCTAssertEqual(
            ObsidianAdvancedSearchEvaluator.search(entries, query: "archives -tag:archive").map(\.title),
            ["Notes"]
        )

        let bodyResults = ObsidianAdvancedSearchEvaluator.search(entries, query: "RÉSUMÉ -tag:archive")
        XCTAssertEqual(bodyResults.map(\.title), ["Plain"])
        XCTAssertEqual(bodyResults.map(\.isBodyMatch), [true])
        XCTAssertTrue(bodyResults[0].subtitle?.contains("re\u{301}sume\u{301}") == true)

        XCTAssertEqual(
            ObsidianAdvancedSearchEvaluator.search(entries, query: "-cafe -tag:archive").map(\.title),
            ["Été", "Plain", "Notes"]
        )
    }

    func testFilePathAndTagPredicatesFoldLikeTextPredicates() {
        let entries = [
            entry(title: "kapi", path: "docs/kapi.md", body: "kapi door"),
            entry(title: "Other", path: "docs/other.md", body: "nothing"),
        ]

        // The text term and the file/path terms agree on dotless i.
        XCTAssertEqual(
            ObsidianAdvancedSearchEvaluator.search(entries, query: "kap\u{131} file:kap\u{131}").map(\.title),
            ["kapi"]
        )
        XCTAssertEqual(
            ObsidianAdvancedSearchEvaluator.search(entries, query: "kapi path:KAP\u{131}").map(\.title),
            ["kapi"]
        )
        XCTAssertEqual(
            ObsidianAdvancedSearchEvaluator.search(entries, query: "-file:KAP\u{131} -tag:x").map(\.title),
            ["Other"]
        )
    }

    func testTaskSummaryCapturesStatesAndFoldedLinesOnce() {
        let summary = NoteTaskSummary.make(
            from: "Intro\n- [ ] Ship Re\u{301}sume\u{301}\r\n  * [X] Done\n- [y] Not a task\nInline - [ ] no"
        )

        XCTAssertTrue(summary.hasAnyTask)
        XCTAssertTrue(summary.hasOpenTask)
        XCTAssertTrue(summary.hasDoneTask)
        XCTAssertEqual(summary.taskLines, ["- [ ] Ship Re\u{301}sume\u{301}", "  * [X] Done"])
        XCTAssertEqual(summary.foldedTaskLines, ["- [ ] ship resume", "  * [x] done"])

        XCTAssertEqual(NoteTaskSummary.make(from: ""), .empty)
        XCTAssertEqual(NoteTaskSummary.make(from: "Nothing to do"), .empty)
        XCTAssertFalse(NoteTaskSummary.make(from: "- [ ] open only").hasDoneTask)
        XCTAssertFalse(NoteTaskSummary.make(from: "+ [x] done only").hasOpenTask)

        let body = SearchableNoteBody("- [ ] cached")
        XCTAssertEqual(body.taskSummary, body.taskSummary)
        XCTAssertEqual(body.taskSummary.taskLines, ["- [ ] cached"])
    }

    func testTaskTextFilterFoldsQueryAndIgnoresNonTaskLines() {
        let entries = [
            entry(title: "Todo", path: "Todo.md", body: "- [ ] Ship Re\u{301}sume\u{301}\n- [x] Archive old"),
            entry(title: "Prose", path: "Prose.md", body: "Re\u{301}sume\u{301} is mentioned but not a task."),
        ]

        XCTAssertEqual(ObsidianAdvancedSearchEvaluator.search(entries, query: "task:RESUME").map(\.title), ["Todo"])
        XCTAssertEqual(ObsidianAdvancedSearchEvaluator.search(entries, query: "task:résumé").map(\.title), ["Todo"])
        XCTAssertEqual(ObsidianAdvancedSearchEvaluator.search(entries, query: "task:archive").map(\.title), ["Todo"])
        XCTAssertTrue(ObsidianAdvancedSearchEvaluator.search(entries, query: "task:mentioned").isEmpty)
        XCTAssertEqual(ObsidianAdvancedSearchEvaluator.search(entries, query: "-task:any").map(\.title), ["Prose"])
        XCTAssertEqual(ObsidianAdvancedSearchEvaluator.search(entries, query: "task:open task:done").map(\.title), ["Todo"])
    }

    private func entry(
        title: String,
        path: String,
        body: String,
        searchMetadata: ObsidianSearchMetadata? = nil
    ) -> NoteSearchEntry {
        let url = URL(fileURLWithPath: "/tmp/\(path)")
        return NoteSearchEntry(
            id: url,
            url: url,
            title: title,
            relativePath: path,
            body: body,
            foldedTitle: Workspace.foldedForSearch(title),
            foldedTitleHaystack: Workspace.foldedForSearch("\(title)\n\(path)"),
            searchMetadata: searchMetadata
        )
    }
}

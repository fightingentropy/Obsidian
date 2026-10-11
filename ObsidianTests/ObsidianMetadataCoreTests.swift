import Foundation
import XCTest

@testable import Obsidian

final class ObsidianMetadataCoreTests: XCTestCase {
    func testParsesCommonPropertiesAndPreservesFrontmatterExactly() throws {
        let expectedFrontmatter = """
        ---
        title: "Project Atlas"
        aliases:
          - Atlas
          - "Project A"
        tags: [work, "deep/research"]
        status: active
        score: 4.5
        published: false
        ---

        """
        let markdown = expectedFrontmatter + """
        # Body
        Text #Swift and #deep/research.
        """

        let metadata = ObsidianMetadataParser.parse(markdown)
        let frontmatter = try XCTUnwrap(metadata.frontmatter)

        XCTAssertEqual(metadata.title, "Project Atlas")
        XCTAssertEqual(metadata.aliases, ["Atlas", "Project A"])
        XCTAssertEqual(metadata.frontmatterTags, ["work", "deep/research"])
        XCTAssertEqual(metadata.inlineTags, ["Swift", "deep/research"])
        XCTAssertEqual(metadata.tags, ["work", "deep/research", "Swift"])
        XCTAssertEqual(metadata.properties["status"], .string("active"))
        XCTAssertEqual(metadata.properties["score"], .number(4.5))
        XCTAssertEqual(metadata.properties["published"], .boolean(false))
        XCTAssertEqual(String(markdown[Range(frontmatter.sourceRange, in: markdown)!]), frontmatter.rawBlock)
        XCTAssertEqual(frontmatter.rawBlock, expectedFrontmatter)
    }

    func testFrontmatterKeepsCRLFAndUnsupportedYamlRaw() throws {
        let markdown = "---\r\ntitle: Note\r\ncomplex:\r\n  nested: value\r\n---\r\nBody"
        let metadata = ObsidianMetadataParser.parse(markdown)
        let frontmatter = try XCTUnwrap(metadata.frontmatter)

        XCTAssertTrue(frontmatter.rawBlock.contains("\r\n"))
        XCTAssertEqual(frontmatter.value(forKey: "TITLE"), .string("Note"))
        XCTAssertEqual(frontmatter.value(forKey: "complex"), .raw("\n  nested: value"))
    }

    func testColumnZeroBlockSequenceItemsStayWithTheirKey() {
        let markdown = """
        ---
        links:
        - url: a
          title: First
        - url: b
        tags:
        - alpha
        - beta
        status: active
        ---
        Body
        """

        let metadata = ObsidianMetadataParser.parse(markdown)

        // The colon inside `- url: a` used to start a bogus "- url" key and
        // leave `links` empty.
        XCTAssertEqual(Set(metadata.properties.keys), ["links", "tags", "status"])
        XCTAssertEqual(metadata.properties["links"], .raw("\n- url: a\n  title: First\n- url: b"))
        XCTAssertEqual(metadata.properties["tags"], .strings(["alpha", "beta"]))
        XCTAssertEqual(metadata.frontmatterTags, ["alpha", "beta"])
        XCTAssertEqual(metadata.properties["status"], .string("active"))

        // A column-0 sequence decodes exactly like the indented spelling.
        XCTAssertEqual(
            ObsidianMetadataParser.parse("---\nrefs:\n- url: a\n- b\n---\n").properties["refs"],
            ObsidianMetadataParser.parse("---\nrefs:\n  - url: a\n  - b\n---\n").properties["refs"]
        )
    }

    func testUnterminatedFrontmatterIsNotGuessed() {
        let markdown = "---\ntitle: Not metadata\n# Heading"
        let metadata = ObsidianMetadataParser.parse(markdown)

        XCTAssertNil(metadata.frontmatter)
        XCTAssertNil(metadata.title)
    }

    func testInlineTagsIgnoreCodeEscapesUrlsAndNumericOnlyTags() {
        let markdown = """
        # Heading, not a tag
        Keep #alpha and #nested/topic plus #café.
        Ignore `#inline` and \\#escaped and https://example.com/#fragment and #2026.
        ```swift
        let tag = "#fenced"
        ```
        """

        let metadata = ObsidianMetadataParser.parse(markdown)
        XCTAssertEqual(metadata.inlineTags, ["alpha", "nested/topic", "café"])
    }

    func testBuildsNestedOutlineAndIgnoresCodeFences() {
        let markdown = """
        # One
        ## Child ###
        ```md
        # Not a heading
        ```
        ### Grandchild
        ## Sibling
        Setext
        ------
        # Two
        """

        let outline = ObsidianMetadataParser.parse(markdown).outline
        XCTAssertEqual(outline.map(\.title), ["One", "Two"])
        XCTAssertEqual(outline[0].children.map(\.title), ["Child", "Sibling", "Setext"])
        XCTAssertEqual(outline[0].children[0].children.map(\.title), ["Grandchild"])
        XCTAssertEqual(outline[0].lineNumber, 1)
    }

    func testNumberDecodingAcceptsOnlyPlainDecimalLiterals() {
        let markdown = """
        ---
        integer: 5
        trailingDot: 5.
        leadingDot: .5
        signed: +5
        negative: -0.5
        exponent: 1e5
        hexadecimal: 0x10
        infinity: inf
        notANumber: nan
        doubleDot: 1.2.3
        quoted: "7"
        underscored: 1_000
        ---
        Body
        """

        let properties = ObsidianMetadataParser.parse(markdown).properties

        XCTAssertEqual(properties["integer"], .number(5))
        XCTAssertEqual(properties["trailingDot"], .number(5))
        XCTAssertEqual(properties["leadingDot"], .number(0.5))
        XCTAssertEqual(properties["signed"], .number(5))
        XCTAssertEqual(properties["negative"], .number(-0.5))
        XCTAssertEqual(properties["exponent"], .string("1e5"))
        XCTAssertEqual(properties["hexadecimal"], .string("0x10"))
        XCTAssertEqual(properties["infinity"], .string("inf"))
        XCTAssertEqual(properties["notANumber"], .string("nan"))
        XCTAssertEqual(properties["doubleDot"], .string("1.2.3"))
        XCTAssertEqual(properties["quoted"], .string("7"))
        XCTAssertEqual(properties["underscored"], .string("1_000"))
    }

    func testAliasesHelperReadsBothKeysAndDeduplicatesCaseInsensitively() {
        XCTAssertEqual(
            ObsidianMetadataParser.aliases(in: ["aliases": .strings(["Atlas", "atlas", "Project A", ""])]),
            ["Atlas", "Project A"]
        )
        XCTAssertEqual(ObsidianMetadataParser.aliases(in: ["Alias": .string("Solo")]), ["Solo"])
        XCTAssertEqual(ObsidianMetadataParser.aliases(in: ["title": .string("No aliases")]), [])
        XCTAssertEqual(
            ObsidianMetadataParser.aliases(in: ObsidianMetadataParser.searchMetadata(in: "---\naliases: [One, two]\n---\n").properties),
            ["One", "two"]
        )
    }

    func testAtxHeadingsStripOnlyClosingHashRuns() {
        let markdown = """
        # Title ##
        ## Keep #hashtag
        ### Only ###
        #### Spaced   ##
        """

        let outline = ObsidianMetadataParser.parse(markdown).outline

        XCTAssertEqual(outline.map(\.title), ["Title"])
        XCTAssertEqual(outline[0].children.map(\.title), ["Keep #hashtag"])
        XCTAssertEqual(outline[0].children[0].children.map(\.title), ["Only"])
        XCTAssertEqual(outline[0].children[0].children[0].children.map(\.title), ["Spaced"])
    }

    func testRendersBuiltInTemplateVariablesDeterministically() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 7
        components.day = 12
        components.hour = 21
        components.minute = 7
        let date = try XCTUnwrap(components.date)

        let rendered = ObsidianTemplateRenderer.render(
            "# {{title}}\nCreated {{date}} at {{time}}",
            title: "Daily Note",
            date: date,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(rendered, "# Daily Note\nCreated 2026-07-12 at 21:07")
    }

    func testParsesAdvancedSearchIntoAndOrGroups() {
        let query = ObsidianAdvancedSearchParser.parse(
            "file:\"Project Plan\" path:work tag:#swift property:status=active task:todo \"exact phrase\" -tag:archive -draft OR property:priority=high"
        )

        XCTAssertEqual(query.groups.count, 2)
        XCTAssertEqual(
            query.groups[0].terms,
            [
                ObsidianSearchTerm(predicate: .file(value: "Project Plan", quoted: true), isExcluded: false),
                ObsidianSearchTerm(predicate: .path(value: "work", quoted: false), isExcluded: false),
                ObsidianSearchTerm(predicate: .tag(value: "swift", quoted: false), isExcluded: false),
                ObsidianSearchTerm(predicate: .property(name: "status", value: "active", quoted: false), isExcluded: false),
                ObsidianSearchTerm(predicate: .task(.open), isExcluded: false),
                ObsidianSearchTerm(predicate: .text(value: "exact phrase", quoted: true), isExcluded: false),
                ObsidianSearchTerm(predicate: .tag(value: "archive", quoted: false), isExcluded: true),
                ObsidianSearchTerm(predicate: .text(value: "draft", quoted: false), isExcluded: true),
            ]
        )
        XCTAssertEqual(
            query.groups[1].terms,
            [ObsidianSearchTerm(predicate: .property(name: "priority", value: "high", quoted: false), isExcluded: false)]
        )
    }

    func testSearchKeepsQuotedOrAndModelsTaskAndPropertyPresence() {
        let query = ObsidianAdvancedSearchParser.parse("\"OR\" property:status task:done task:custom")

        XCTAssertEqual(query.groups.count, 1)
        XCTAssertEqual(
            query.groups[0].terms,
            [
                ObsidianSearchTerm(predicate: .text(value: "OR", quoted: true), isExcluded: false),
                ObsidianSearchTerm(predicate: .property(name: "status", value: nil, quoted: false), isExcluded: false),
                ObsidianSearchTerm(predicate: .task(.done), isExcluded: false),
                ObsidianSearchTerm(predicate: .task(.text("custom")), isExcluded: false),
            ]
        )
    }
}

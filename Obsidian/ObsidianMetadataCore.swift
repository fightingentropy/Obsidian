import Foundation

/// A deliberately small, lossless view of the YAML value shapes used by
/// Obsidian's Properties UI. Unsupported YAML remains available as `.raw`
/// instead of being guessed at or reformatted.
enum ObsidianPropertyValue: Equatable, Sendable {
    case string(String)
    case strings([String])
    case boolean(Bool)
    case number(Double)
    case null
    case raw(String)

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var stringValues: [String]? {
        switch self {
        case .string(let value):
            return [value]
        case .strings(let values):
            return values
        default:
            return nil
        }
    }
}

struct ObsidianFrontmatter: Equatable, Sendable {
    /// Exact bytes-as-String from the opening delimiter through the closing
    /// delimiter, including original newline style and a trailing newline when
    /// present. Consumers can inspect metadata without normalizing the source.
    let rawBlock: String
    let sourceRange: NSRange
    let properties: [String: ObsidianPropertyValue]

    func value(forKey key: String) -> ObsidianPropertyValue? {
        properties.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

struct ObsidianOutlineNode: Equatable, Sendable {
    let level: Int
    let title: String
    let lineNumber: Int
    let children: [ObsidianOutlineNode]
}

struct ObsidianDocumentMetadata: Equatable, Sendable {
    let frontmatter: ObsidianFrontmatter?
    let title: String?
    let aliases: [String]
    let frontmatterTags: [String]
    let inlineTags: [String]
    let properties: [String: ObsidianPropertyValue]
    let outline: [ObsidianOutlineNode]

    var tags: [String] {
        ObsidianMetadataParser.uniquedCaseInsensitive(frontmatterTags + inlineTags)
    }
}

/// The subset of note metadata needed by command-palette filters. Keeping this
/// separate from `ObsidianDocumentMetadata` avoids rebuilding a note's outline
/// when a search only needs tags and frontmatter properties.
struct ObsidianSearchMetadata: Equatable, Sendable {
    let tags: [String]
    let properties: [String: ObsidianPropertyValue]
}

enum ObsidianMetadataParser {
    /// Matches a closing ATX hash run (`## Title ##`) so it can be stripped.
    private static let trailingHashRunPattern = try! NSRegularExpression(pattern: #"\s+#+\s*$"#)

    static func parse(_ markdown: String) -> ObsidianDocumentMetadata {
        let lines = sourceLines(in: markdown)
        let frontmatterParse = parseFrontmatter(in: markdown, lines: lines)
        let properties = frontmatterParse.frontmatter?.properties ?? [:]

        let title = scalarString(forKeys: ["title"], in: properties)
        let frontmatterTags = stringList(forKeys: ["tags", "tag"], in: properties)
            .compactMap(normalizedTag(_:))

        let contentStartLine = frontmatterParse.closingLineIndex.map { $0 + 1 } ?? 0
        let bodyLines = contentStartLine < lines.count ? Array(lines[contentStartLine...]) : []

        return ObsidianDocumentMetadata(
            frontmatter: frontmatterParse.frontmatter,
            title: title,
            aliases: aliases(in: properties),
            frontmatterTags: uniquedCaseInsensitive(frontmatterTags),
            inlineTags: extractInlineTags(from: bodyLines),
            properties: properties,
            outline: buildOutline(from: bodyLines)
        )
    }

    /// The de-duplicated `aliases`/`alias` list of already parsed frontmatter
    /// properties. Callers that cache `ObsidianSearchMetadata` can resolve
    /// aliases from it without re-parsing the note body.
    static func aliases(in properties: [String: ObsidianPropertyValue]) -> [String] {
        uniquedCaseInsensitive(stringList(forKeys: ["aliases", "alias"], in: properties))
    }

    static func searchMetadata(in markdown: String) -> ObsidianSearchMetadata {
        let lines = sourceLines(in: markdown)
        let frontmatterParse = parseFrontmatter(in: markdown, lines: lines)
        let properties = frontmatterParse.frontmatter?.properties ?? [:]
        let frontmatterTags = stringList(forKeys: ["tags", "tag"], in: properties)
            .compactMap(normalizedTag(_:))
        let contentStartLine = frontmatterParse.closingLineIndex.map { $0 + 1 } ?? 0
        let bodyLines = contentStartLine < lines.count ? Array(lines[contentStartLine...]) : []

        return ObsidianSearchMetadata(
            tags: uniquedCaseInsensitive(frontmatterTags + extractInlineTags(from: bodyLines)),
            properties: properties
        )
    }

    // MARK: - Frontmatter

    private struct SourceLine {
        let text: String
        let rawRange: Range<String.Index>
        let lineNumber: Int
    }

    private struct FrontmatterParse {
        let frontmatter: ObsidianFrontmatter?
        let closingLineIndex: Int?
    }

    private struct PropertyBuffer {
        let key: String
        let firstValue: String
        var continuationLines: [String]
    }

    private static func parseFrontmatter(
        in source: String,
        lines: [SourceLine]
    ) -> FrontmatterParse {
        guard let first = lines.first else {
            return FrontmatterParse(frontmatter: nil, closingLineIndex: nil)
        }

        let firstText = first.text.first == "\u{feff}" ? String(first.text.dropFirst()) : first.text
        guard firstText == "---" else {
            return FrontmatterParse(frontmatter: nil, closingLineIndex: nil)
        }

        guard let closingIndex = lines.indices.dropFirst().first(where: {
            lines[$0].text == "---" || lines[$0].text == "..."
        }) else {
            // An unterminated delimiter is ordinary Markdown, not frontmatter.
            return FrontmatterParse(frontmatter: nil, closingLineIndex: nil)
        }

        let propertyLines = closingIndex > 1 ? Array(lines[1..<closingIndex].map(\.text)) : []
        let properties = parseTopLevelProperties(propertyLines)
        let blockRange = first.rawRange.lowerBound..<lines[closingIndex].rawRange.upperBound
        let rawBlock = String(source[blockRange])

        return FrontmatterParse(
            frontmatter: ObsidianFrontmatter(
                rawBlock: rawBlock,
                sourceRange: NSRange(blockRange, in: source),
                properties: properties
            ),
            closingLineIndex: closingIndex
        )
    }

    /// Parses only top-level `key: value` pairs. Nested mappings, multiline
    /// scalars, anchors, and other richer YAML are retained as `.raw`.
    private static func parseTopLevelProperties(_ lines: [String]) -> [String: ObsidianPropertyValue] {
        var buffers: [PropertyBuffer] = []
        var current: PropertyBuffer?

        func flush() {
            if let current {
                buffers.append(current)
            }
            current = nil
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                if current != nil {
                    current?.continuationLines.append(line)
                }
                continue
            }

            if line.first?.isWhitespace != true,
               !isBlockSequenceItem(line),
               let delimiter = topLevelKeyDelimiter(in: line) {
                flush()
                let key = line[..<delimiter].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                let valueStart = line.index(after: delimiter)
                let value = line[valueStart...].trimmingCharacters(in: .whitespaces)
                current = PropertyBuffer(key: key, firstValue: value, continuationLines: [])
            } else if current != nil {
                current?.continuationLines.append(line)
            }
        }
        flush()

        var result: [String: ObsidianPropertyValue] = [:]
        for buffer in buffers {
            result[buffer.key] = decodeProperty(buffer)
        }
        return result
    }

    /// Block-sequence items (`- url: a`) belong to the key above them even at
    /// column 0, as `ObsidianPropertyEditor` treats them, so a colon inside an
    /// item never starts a bogus top-level key such as `- url`.
    private static func isBlockSequenceItem(_ line: String) -> Bool {
        let unindented = line.drop(while: { $0 == " " || $0 == "\t" })
        return unindented == "-" || unindented.hasPrefix("- ")
    }

    private static func topLevelKeyDelimiter(in line: String) -> String.Index? {
        var quote: Character?
        var escaped = false

        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote != nil {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                continue
            }
            if character == ":", quote == nil {
                return index
            }
        }
        return nil
    }

    private static func decodeProperty(_ buffer: PropertyBuffer) -> ObsidianPropertyValue {
        let meaningfulContinuation = buffer.continuationLines.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }

        if buffer.firstValue.isEmpty, !meaningfulContinuation.isEmpty {
            let listValues = meaningfulContinuation.compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") || trimmed == "-" else { return nil }
                let value = trimmed == "-" ? "" : String(trimmed.dropFirst(2))
                return decodeSimpleString(value)
            }
            if listValues.count == meaningfulContinuation.count {
                return .strings(listValues)
            }
        }

        guard meaningfulContinuation.isEmpty else {
            let raw = ([buffer.firstValue] + buffer.continuationLines).joined(separator: "\n")
            return .raw(raw)
        }

        let value = buffer.firstValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return .null }

        if value == "|" || value == ">" || value.hasPrefix("|") || value.hasPrefix(">") {
            return .raw(value)
        }

        if value.hasPrefix("["), value.hasSuffix("]") {
            guard let values = decodeInlineList(String(value.dropFirst().dropLast())) else {
                return .raw(value)
            }
            return .strings(values)
        }

        let lowered = value.lowercased()
        if lowered == "true" { return .boolean(true) }
        if lowered == "false" { return .boolean(false) }
        if lowered == "null" || lowered == "~" { return .null }
        if let number = Double(value), isPlainDecimalLiteral(value) {
            return .number(number)
        }

        return .string(decodeSimpleString(value))
    }

    /// Accepts exactly what the former `^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$` check
    /// did: an optional sign followed by digits with an optional fraction, or
    /// a fraction alone. Exponents, hexadecimal and `inf`/`nan` spellings that
    /// `Double.init` would accept therefore stay strings. Only ASCII digits
    /// need checking because `Double.init` rejects every other digit system.
    private static func isPlainDecimalLiteral(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        var index = 0
        if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" {
            index += 1
        }

        var integerDigits = 0
        while index < scalars.count, isASCIIDigit(scalars[index]) {
            integerDigits += 1
            index += 1
        }

        var hasFractionSeparator = false
        var fractionDigits = 0
        if index < scalars.count, scalars[index] == "." {
            hasFractionSeparator = true
            index += 1
            while index < scalars.count, isASCIIDigit(scalars[index]) {
                fractionDigits += 1
                index += 1
            }
        }

        guard index == scalars.count else { return false }
        if hasFractionSeparator {
            return integerDigits > 0 || fractionDigits > 0
        }
        return integerDigits > 0
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
    }

    private static func decodeInlineList(_ body: String) -> [String]? {
        if body.trimmingCharacters(in: .whitespaces).isEmpty { return [] }

        var values: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for character in body {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != nil {
                escaped = true
                current.append(character)
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                current.append(character)
                continue
            }
            if character == ",", quote == nil {
                values.append(decodeSimpleString(current))
                current = ""
            } else {
                current.append(character)
            }
        }

        guard quote == nil, !escaped else { return nil }
        values.append(decodeSimpleString(current))
        return values
    }

    private static func decodeSimpleString(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              let last = trimmed.last,
              first == last,
              first == "\"" || first == "'" else {
            return trimmed
        }

        let inner = String(trimmed.dropFirst().dropLast())
        if first == "'" {
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    private static func scalarString(
        forKeys keys: [String],
        in properties: [String: ObsidianPropertyValue]
    ) -> String? {
        for key in keys {
            if let value = properties.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value,
               let string = value.stringValue,
               !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private static func stringList(
        forKeys keys: [String],
        in properties: [String: ObsidianPropertyValue]
    ) -> [String] {
        for key in keys {
            if let value = properties.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value,
               let values = value.stringValues {
                return values.filter { !$0.isEmpty }
            }
        }
        return []
    }

    // MARK: - Tags

    private static func extractInlineTags(from lines: [SourceLine]) -> [String] {
        var tags: [String] = []
        var fence: Fence?

        for line in lines {
            let leadingTrimmed = line.text.drop(while: { $0 == " " || $0 == "\t" })
            if let marker = fenceMarker(in: String(leadingTrimmed)) {
                if let active = fence {
                    if active.character == marker.character, marker.length >= active.length {
                        fence = nil
                    }
                } else {
                    fence = marker
                }
                continue
            }
            guard fence == nil else { continue }
            tags.append(contentsOf: inlineTags(in: line.text))
        }

        return uniquedCaseInsensitive(tags)
    }

    private static func inlineTags(in line: String) -> [String] {
        let characters = Array(line)
        var result: [String] = []
        var index = 0
        var inlineFenceLength: Int?

        while index < characters.count {
            if characters[index] == "`" {
                let start = index
                while index < characters.count, characters[index] == "`" { index += 1 }
                let length = index - start
                if inlineFenceLength == length {
                    inlineFenceLength = nil
                } else if inlineFenceLength == nil {
                    inlineFenceLength = length
                }
                continue
            }

            guard inlineFenceLength == nil, characters[index] == "#" else {
                index += 1
                continue
            }

            let previous = index > 0 ? characters[index - 1] : nil
            guard previous != "\\", isTagBoundary(previous) else {
                index += 1
                continue
            }

            var cursor = index + 1
            while cursor < characters.count, isTagCharacter(characters[cursor]) {
                cursor += 1
            }
            guard cursor > index + 1 else {
                index += 1
                continue
            }

            let candidate = String(characters[(index + 1)..<cursor])
                .trimmingCharacters(in: CharacterSet(charactersIn: "/-_"))
            guard normalizedTag(candidate) != nil,
                  candidate.contains(where: { $0.isLetter || $0 == "_" }) else {
                index = cursor
                continue
            }

            result.append(candidate)
            index = cursor
        }
        return result
    }

    private static func isTagBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        return character.isWhitespace || "([{'\".,;:!?>".contains(character)
    }

    private static func isTagCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-" || character == "/"
    }

    private static func normalizedTag(_ tag: String) -> String? {
        var normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasPrefix("#") { normalized.removeFirst() }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.isEmpty ? nil : normalized
    }

    static func uniquedCaseInsensitive(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return seen.insert(key).inserted
        }
    }

    // MARK: - Outline

    private struct FlatHeading {
        let level: Int
        let title: String
        let lineNumber: Int
    }

    private struct Fence {
        let character: Character
        let length: Int
    }

    private static func buildOutline(from lines: [SourceLine]) -> [ObsidianOutlineNode] {
        var flat: [FlatHeading] = []
        var fence: Fence?
        var previousEligibleLine: SourceLine?

        for line in lines {
            let leadingTrimmed = line.text.drop(while: { $0 == " " || $0 == "\t" })
            if let marker = fenceMarker(in: String(leadingTrimmed)) {
                if let active = fence {
                    if active.character == marker.character, marker.length >= active.length {
                        fence = nil
                    }
                } else {
                    fence = marker
                }
                previousEligibleLine = nil
                continue
            }
            guard fence == nil else {
                previousEligibleLine = nil
                continue
            }

            if let level = setextLevel(in: line.text),
               let previous = previousEligibleLine,
               !previous.text.trimmingCharacters(in: .whitespaces).isEmpty {
                flat.append(
                    FlatHeading(
                        level: level,
                        title: previous.text.trimmingCharacters(in: .whitespaces),
                        lineNumber: previous.lineNumber
                    )
                )
                previousEligibleLine = nil
                continue
            }

            if let heading = atxHeading(in: line.text, lineNumber: line.lineNumber) {
                flat.append(heading)
                previousEligibleLine = nil
            } else {
                previousEligibleLine = line.text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : line
            }
        }

        var index = 0
        return outlineNodes(from: flat, index: &index, parentLevel: 0)
    }

    private static func atxHeading(in line: String, lineNumber: Int) -> FlatHeading? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        guard leadingSpaces <= 3 else { return nil }
        let trimmed = line.dropFirst(leadingSpaces)
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let afterHashes = trimmed.dropFirst(level)
        guard afterHashes.isEmpty || afterHashes.first?.isWhitespace == true else { return nil }

        var title = afterHashes.trimmingCharacters(in: .whitespaces)
        let titleRange = NSRange(title.startIndex..<title.endIndex, in: title)
        if let match = trailingHashRunPattern.firstMatch(in: title, range: titleRange),
           let hashRun = Range(match.range, in: title) {
            title.removeSubrange(hashRun)
        }
        guard !title.isEmpty else { return nil }
        return FlatHeading(level: level, title: title, lineNumber: lineNumber)
    }

    private static func setextLevel(in line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 1 else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func outlineNodes(
        from headings: [FlatHeading],
        index: inout Int,
        parentLevel: Int
    ) -> [ObsidianOutlineNode] {
        var nodes: [ObsidianOutlineNode] = []
        while index < headings.count, headings[index].level > parentLevel {
            let heading = headings[index]
            index += 1
            let children = outlineNodes(from: headings, index: &index, parentLevel: heading.level)
            nodes.append(
                ObsidianOutlineNode(
                    level: heading.level,
                    title: heading.title,
                    lineNumber: heading.lineNumber,
                    children: children
                )
            )
        }
        return nodes
    }

    private static func fenceMarker(in line: String) -> Fence? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let length = line.prefix(while: { $0 == first }).count
        return length >= 3 ? Fence(character: first, length: length) : nil
    }

    // MARK: - Source lines

    private static func sourceLines(in source: String) -> [SourceLine] {
        guard !source.isEmpty else { return [] }
        var result: [SourceLine] = []
        var start = source.startIndex
        var lineNumber = 1

        while start < source.endIndex {
            let newline = source[start...].firstIndex(where: \.isNewline)
            let contentEnd = newline ?? source.endIndex
            let rawEnd = newline.map { source.index(after: $0) } ?? source.endIndex
            var text = String(source[start..<contentEnd])
            if text.hasSuffix("\r") { text.removeLast() }
            result.append(SourceLine(text: text, rawRange: start..<rawEnd, lineNumber: lineNumber))
            start = rawEnd
            lineNumber += 1
        }
        return result
    }
}

enum ObsidianTemplateRenderer {
    static func render(
        _ template: String,
        title: String,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.calendar = Calendar(identifier: .gregorian)
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = "HH:mm"

        return template
            .replacingOccurrences(of: "{{title}}", with: title)
            .replacingOccurrences(of: "{{date}}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{{time}}", with: timeFormatter.string(from: date))
    }
}

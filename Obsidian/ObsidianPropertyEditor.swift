import Foundation

enum ObsidianPropertyEditorError: LocalizedError {
    case invalidKey
    case rawValueNotEditable

    var errorDescription: String? {
        switch self {
        case .invalidKey: "Property names may contain letters, numbers, underscores, and hyphens."
        case .rawValueNotEditable: "This complex YAML value must be edited in source mode."
        }
    }
}

enum ObsidianPropertyEditor {
    private static let byteOrderMark: Character = "\u{feff}"

    static func setting(
        key: String,
        value: ObsidianPropertyValue?,
        in markdown: String
    ) throws -> String {
        // The parser tolerates a leading BOM but reports it as part of the
        // frontmatter block. Edit the note without it and put it back after.
        if markdown.first == byteOrderMark {
            let edited = try setting(key: key, value: value, in: String(markdown.dropFirst()))
            return String(byteOrderMark) + edited
        }

        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanKey.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ObsidianPropertyEditorError.invalidKey
        }
        if case .raw = value { throw ObsidianPropertyEditorError.rawValueNotEditable }

        let metadata = ObsidianMetadataParser.parse(markdown)
        guard let frontmatter = metadata.frontmatter,
              let sourceRange = Range(frontmatter.sourceRange, in: markdown) else {
            guard let value else { return markdown }
            let newline = markdown.contains("\r\n") ? "\r\n" : "\n"
            return "---\(newline)\(cleanKey): \(try encoded(value))\(newline)---\(newline)" + markdown
        }

        let newline = frontmatter.rawBlock.contains("\r\n") ? "\r\n" : "\n"
        var lines = frontmatter.rawBlock.components(separatedBy: newline)
        guard lines.first == "---" else { return markdown }
        let closingIndex = lines.indices.dropFirst().first(where: {
            lines[$0] == "---" || lines[$0] == "..."
        }) ?? max(1, lines.count - 1)

        var propertyStart: Int?
        for index in 1..<closingIndex {
            let line = lines[index]
            guard line.first?.isWhitespace != true,
                  !isListItem(line),
                  let colon = line.firstIndex(of: ":") else { continue }
            let existingKey = line[..<colon].trimmingCharacters(in: .whitespaces)
            if existingKey.caseInsensitiveCompare(cleanKey) == .orderedSame {
                propertyStart = index
                break
            }
        }

        if let propertyStart {
            var propertyEnd = propertyStart + 1
            while propertyEnd < closingIndex {
                let line = lines[propertyEnd]
                if line.first?.isWhitespace != true,
                   line.first != "#",
                   !isListItem(line),
                   line.contains(":") {
                    break
                }
                propertyEnd += 1
            }
            lines.removeSubrange(propertyStart..<propertyEnd)
            if let value {
                lines.insert("\(cleanKey): \(try encoded(value))", at: propertyStart)
            }
        } else if let value {
            lines.insert("\(cleanKey): \(try encoded(value))", at: closingIndex)
        }

        var updated = markdown
        updated.replaceSubrange(sourceRange, with: lines.joined(separator: newline))
        return updated
    }

    /// Block-sequence items (`- url: a`) belong to the key above them even at
    /// column 0, so they must not be mistaken for the next top-level key.
    private static func isListItem(_ line: String) -> Bool {
        let unindented = line.drop(while: { $0 == " " || $0 == "\t" })
        return unindented == "-" || unindented.hasPrefix("- ")
    }

    private static func encoded(_ value: ObsidianPropertyValue) throws -> String {
        switch value {
        case .string(let value):
            return quote(value)
        case .strings(let values):
            return "[" + values.map(quote).joined(separator: ", ") + "]"
        case .boolean(let value):
            return value ? "true" : "false"
        case .number(let value):
            return formatted(value)
        case .null:
            return "null"
        case .raw:
            throw ObsidianPropertyEditorError.rawValueNotEditable
        }
    }

    /// Writes integral values without a fractional part so `3` round-trips as
    /// `3` rather than `3.0`.
    private static func formatted(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static func quote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

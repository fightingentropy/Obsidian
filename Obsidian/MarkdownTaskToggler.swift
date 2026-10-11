import Foundation

struct MarkdownTaskToggleResult: Equatable {
    let text: String
    let selection: NSRange
}

enum MarkdownTaskToggler {
    private static let openTaskRegex = try! NSRegularExpression(pattern: #"^(\s*[-*+]\s+)\[ \](\s*)"#)
    private static let doneTaskRegex = try! NSRegularExpression(pattern: #"^(\s*[-*+]\s+)\[[xX]\](\s*)"#)

    static func toggle(in text: String, selection: NSRange) -> MarkdownTaskToggleResult {
        let nsText = text as NSString
        let safeLocation = min(max(selection.location, 0), nsText.length)
        let safeLength = min(max(selection.length, 0), nsText.length - safeLocation)
        let lineRange = nsText.lineRange(for: NSRange(location: safeLocation, length: safeLength))
        let selectionEnd = NSMaxRange(lineRange)

        // Walk each line with its own terminator so CRLF, CR, and LF notes keep
        // their line endings byte-for-byte.
        var lines: [(content: String, terminator: String)] = []
        var cursor = lineRange.location
        while cursor < selectionEnd {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            nsText.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: cursor, length: 0)
            )
            lines.append((
                content: nsText.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart)),
                terminator: nsText.substring(with: NSRange(location: contentsEnd, length: lineEnd - contentsEnd))
            ))
            guard lineEnd > cursor else { break }
            cursor = lineEnd
        }

        // Blank lines inside a multi-line selection stay blank; a lone blank
        // line is the one case where the command should start a task.
        let togglesBlankLines = lines.count == 1
        let transformed = lines.map { line in
            let content = line.content.isEmpty && !togglesBlankLines ? line.content : toggleLine(line.content)
            return content + line.terminator
        }.joined()

        let updated = nsText.replacingCharacters(in: lineRange, with: transformed)
        return MarkdownTaskToggleResult(
            text: updated,
            selection: NSRange(location: lineRange.location, length: (transformed as NSString).length)
        )
    }

    private static func toggleLine(_ line: String) -> String {
        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)

        if let match = openTaskRegex.firstMatch(in: line, range: fullRange) {
            let prefix = nsLine.substring(with: match.range(at: 1))
            let spacing = nsLine.substring(with: match.range(at: 2))
            return openTaskRegex.stringByReplacingMatches(
                in: line,
                range: match.range,
                withTemplate: NSRegularExpression.escapedTemplate(for: "\(prefix)[x]\(spacing)")
            )
        }

        if let match = doneTaskRegex.firstMatch(in: line, range: fullRange) {
            let prefix = nsLine.substring(with: match.range(at: 1))
            let spacing = nsLine.substring(with: match.range(at: 2))
            return doneTaskRegex.stringByReplacingMatches(
                in: line,
                range: match.range,
                withTemplate: NSRegularExpression.escapedTemplate(for: "\(prefix)[ ]\(spacing)")
            )
        }

        let leadingWhitespace = line.prefix(while: { $0 == " " || $0 == "\t" })
        let content = line.dropFirst(leadingWhitespace.count)
        return "\(leadingWhitespace)- [ ] \(content)"
    }
}

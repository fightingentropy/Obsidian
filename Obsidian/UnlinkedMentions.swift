import Foundation

struct UnlinkedMention: Identifiable, Equatable {
    let sourceURL: URL
    let sourceTitle: String
    let matchedText: String
    let range: NSRange
    let snippet: String
    let expectedBody: String

    var id: String {
        "\(sourceURL.standardizedFileURL.path):\(range.location):\(range.length)"
    }
}

enum UnlinkedMentionFinder {
    static func find(
        targetNames: [String],
        sources: [(url: URL, title: String, body: String)],
        excluding targetURL: URL?
    ) -> [UnlinkedMention] {
        let names = targetNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
            .reduce(into: [String]()) { result, name in
                if !result.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    result.append(name)
                }
            }
            .sorted { $0.count > $1.count }
        guard !names.isEmpty else { return [] }

        // The search itself is a plain NSString scan per name (no regex or
        // folding), so the only per-source work worth hoisting is the
        // excluded URL, which was being re-standardized for every source.
        let excludedURL = targetURL?.standardizedFileURL
        var mentions: [UnlinkedMention] = []
        for source in sources where source.url.standardizedFileURL != excludedURL {
            let nsBody = source.body as NSString
            var occupiedRanges: [NSRange] = []

            for name in names {
                var searchRange = NSRange(location: 0, length: nsBody.length)
                while searchRange.length > 0 {
                    let match = nsBody.range(
                        of: name,
                        options: [.caseInsensitive, .diacriticInsensitive],
                        range: searchRange
                    )
                    guard match.location != NSNotFound else { break }

                    let nextLocation = NSMaxRange(match)
                    searchRange = NSRange(location: nextLocation, length: nsBody.length - nextLocation)

                    guard isWordBoundary(match, in: nsBody),
                          !occupiedRanges.contains(where: { NSIntersectionRange($0, match).length > 0 }),
                          !isInsideExistingLink(match, in: nsBody) else {
                        continue
                    }

                    occupiedRanges.append(match)
                    mentions.append(
                        UnlinkedMention(
                            sourceURL: source.url,
                            sourceTitle: source.title,
                            matchedText: nsBody.substring(with: match),
                            range: match,
                            snippet: snippet(around: match, in: nsBody),
                            expectedBody: source.body
                        )
                    )
                }
            }
        }

        return mentions.sorted {
            if $0.sourceTitle != $1.sourceTitle {
                return $0.sourceTitle.localizedCaseInsensitiveCompare($1.sourceTitle) == .orderedAscending
            }
            return $0.range.location < $1.range.location
        }
    }

    static func replacingMention(_ mention: UnlinkedMention, in body: String) -> String? {
        guard body == mention.expectedBody else { return nil }
        let nsBody = body as NSString
        guard NSMaxRange(mention.range) <= nsBody.length,
              nsBody.substring(with: mention.range) == mention.matchedText else { return nil }
        return nsBody.replacingCharacters(in: mention.range, with: "[[\(mention.matchedText)]]")
    }

    private static func isWordBoundary(_ range: NSRange, in body: NSString) -> Bool {
        func isNameCharacter(_ codeUnit: unichar) -> Bool {
            guard let scalar = UnicodeScalar(codeUnit) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || codeUnit == 95
        }

        let beforeIsName = range.location > 0 && isNameCharacter(body.character(at: range.location - 1))
        let afterIsName = NSMaxRange(range) < body.length && isNameCharacter(body.character(at: NSMaxRange(range)))
        return !beforeIsName && !afterIsName
    }

    private static func isInsideExistingLink(_ range: NSRange, in body: NSString) -> Bool {
        let lineRange = body.lineRange(for: range)
        let line = body.substring(with: lineRange) as NSString
        let localLocation = range.location - lineRange.location

        let prefix = line.substring(to: localLocation) as NSString
        let lastWikiOpen = prefix.range(of: "[[", options: .backwards).location
        let lastWikiClose = prefix.range(of: "]]", options: .backwards).location
        if lastWikiOpen != NSNotFound && (lastWikiClose == NSNotFound || lastWikiOpen > lastWikiClose) {
            return true
        }

        let lastLabelOpen = prefix.range(of: "[", options: .backwards).location
        let lastLabelClose = prefix.range(of: "]", options: .backwards).location
        if lastLabelOpen != NSNotFound && (lastLabelClose == NSNotFound || lastLabelOpen > lastLabelClose) {
            let suffix = line.substring(from: min(NSMaxRange(NSRange(location: localLocation, length: range.length)), line.length))
            if suffix.contains("](") { return true }
        }
        return false
    }

    private static func snippet(around range: NSRange, in body: NSString) -> String {
        let line = body.substring(with: body.lineRange(for: range))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count > 150 else { return line }
        return String(line.prefix(147)) + "…"
    }
}

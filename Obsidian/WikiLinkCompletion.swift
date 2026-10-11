import Foundation

enum WikiLinkCompletion {
    static func partialRange(in text: String, selection: NSRange) -> NSRange? {
        partialRange(in: text as NSString, selection: selection)
    }

    /// `NSString` entry point for the editor, which already holds the document
    /// as an `NSString` and so avoids bridging it through a Swift `String`
    /// copy on every keystroke.
    static func partialRange(in nsText: NSString, selection: NSRange) -> NSRange? {
        guard selection.length == 0,
              selection.location <= nsText.length else { return nil }

        let prefixRange = NSRange(location: 0, length: selection.location)
        let openingRange = nsText.range(of: "[[", options: .backwards, range: prefixRange)
        guard openingRange.location != NSNotFound else { return nil }

        let start = NSMaxRange(openingRange)
        let length = selection.location - start
        let partialRange = NSRange(location: start, length: length)
        let partial = nsText.substring(with: partialRange)
        guard !partial.contains("]"), !partial.contains("\n") else { return nil }
        return partialRange
    }

    private struct Match {
        let original: String
        let startsWithQuery: Bool
    }

    static func suggestions(
        for partial: String,
        candidates: [String],
        limit: Int = 20
    ) -> [String] {
        let query = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let foldedQuery = fold(query)

        // Fold each candidate exactly once; the filter and the prefix test both
        // read the folded form, so neither the filter nor the sort comparator
        // has to fold again.
        var matches: [Match] = []
        for candidate in candidates {
            let folded = fold(candidate)
            guard foldedQuery.isEmpty || folded.contains(foldedQuery) else { continue }
            matches.append(Match(original: candidate, startsWithQuery: folded.hasPrefix(foldedQuery)))
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.startsWithQuery != rhs.startsWithQuery { return lhs.startsWithQuery }
                return lhs.original.localizedCaseInsensitiveCompare(rhs.original) == .orderedAscending
            }
            .prefix(limit)
            .map { $0.original + "]]" }
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

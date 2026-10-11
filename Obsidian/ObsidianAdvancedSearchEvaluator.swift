import Foundation

enum ObsidianAdvancedSearchEvaluator {
    /// A query term with its text values folded once, before the entries
    /// loop, so no entry pays for folding or locale-aware range searches.
    private struct CompiledTerm {
        let predicate: CompiledPredicate
        let isExcluded: Bool
    }

    private enum CompiledPredicate {
        case text(folded: String)
        case file(folded: String)
        case path(folded: String)
        case tag(folded: String)
        case property(name: String, foldedValue: String?)
        case task(ObsidianTaskSearchState, foldedText: String?)
    }

    static func search(_ entries: [NoteSearchEntry], query source: String) -> [NoteSearchResult] {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Workspace.search(entries, query: "") }
        if let plainText = ObsidianAdvancedSearchParser.plainTextQuery(in: trimmed) {
            return Workspace.search(entries, query: plainText)
        }

        let query = ObsidianAdvancedSearchParser.parse(trimmed)
        guard !query.isEmpty else { return Workspace.search(entries, query: trimmed) }

        let snippetTerm = query.groups
            .flatMap(\.terms)
            .first(where: { !$0.isExcluded && isTextPredicate($0.predicate) })
        let snippetQuery = snippetTerm.flatMap { term -> String? in
            guard case .text(let value, _) = term.predicate else { return nil }
            return value
        }
        let foldedSnippetQuery = snippetQuery.map(Workspace.foldedForSearch)
        let compiledGroups = query.groups.map { group in
            group.terms.map(compile)
        }

        var results: [NoteSearchResult] = []
        for entry in entries {
            guard !Task.isCancelled else { return [] }
            // The relative path is folded at most once per entry, and only
            // when a text predicate has to look past the title.
            var foldedRelativePath: String?
            guard compiledGroups.contains(where: { group in
                group.allSatisfy { term in
                    let matches = matches(term.predicate, entry: entry, foldedRelativePath: &foldedRelativePath)
                    return term.isExcluded ? !matches : matches
                }
            }) else { continue }

            if let snippetQuery, let foldedSnippetQuery,
               entry.bodyStorage.foldedText.contains(foldedSnippetQuery) {
                results.append(
                    NoteSearchResult(
                        id: entry.id,
                        url: entry.url,
                        title: entry.title,
                        fallbackSubtitle: entry.relativePath,
                        snippetSource: NoteSearchSnippetSource(
                            bodyStorage: entry.bodyStorage,
                            query: snippetQuery
                        ),
                        isBodyMatch: true
                    )
                )
            } else {
                results.append(
                    NoteSearchResult(
                        id: entry.id,
                        url: entry.url,
                        title: entry.title,
                        subtitle: entry.relativePath,
                        isBodyMatch: false
                    )
                )
            }
        }
        return results
    }

    private static func compile(_ term: ObsidianSearchTerm) -> CompiledTerm {
        let predicate: CompiledPredicate
        switch term.predicate {
        case .text(let value, _):
            predicate = .text(folded: Workspace.foldedForSearch(value))
        case .file(let value, _):
            predicate = .file(folded: Workspace.foldedForSearch(value))
        case .path(let value, _):
            predicate = .path(folded: Workspace.foldedForSearch(value))
        case .tag(let value, _):
            predicate = .tag(folded: Workspace.foldedForSearch(value))
        case .property(let name, let value, _):
            predicate = .property(name: name, foldedValue: value.map(Workspace.foldedForSearch))
        case .task(let state):
            if case .text(let value) = state {
                predicate = .task(state, foldedText: Workspace.foldedForSearch(value))
            } else {
                predicate = .task(state, foldedText: nil)
            }
        }
        return CompiledTerm(predicate: predicate, isExcluded: term.isExcluded)
    }

    private static func matches(
        _ predicate: CompiledPredicate,
        entry: NoteSearchEntry,
        foldedRelativePath: inout String?
    ) -> Bool {
        switch predicate {
        case .text(let folded):
            guard !folded.isEmpty else { return false }
            if entry.foldedTitle.contains(folded) { return true }
            let relativePath = foldedRelativePath ?? Workspace.foldedForSearch(entry.relativePath ?? "")
            foldedRelativePath = relativePath
            return relativePath.contains(folded)
                || entry.bodyStorage.foldedText.contains(folded)
        case .file(let folded):
            return contains(folded, in: entry.title)
                || contains(folded, in: entry.url.lastPathComponent)
        case .path(let folded):
            return contains(folded, in: entry.relativePath ?? entry.url.path)
        case .tag(let folded):
            return entry.metadataForSearch.tags.contains { tag in
                contains(folded, in: tag)
            }
        case .property(let name, let foldedValue):
            guard let property = entry.metadataForSearch.properties.first(where: {
                $0.key.caseInsensitiveCompare(name) == .orderedSame
            })?.value else { return false }
            guard let foldedValue else { return true }
            return contains(foldedValue, in: propertyText(property))
        case .task(let state, let foldedText):
            return matchesTask(state, foldedText: foldedText, summary: entry.bodyStorage.taskSummary)
        }
    }

    private static func matchesTask(
        _ state: ObsidianTaskSearchState,
        foldedText: String?,
        summary: NoteTaskSummary
    ) -> Bool {
        switch state {
        case .any:
            return summary.hasAnyTask
        case .open:
            return summary.hasOpenTask
        case .done:
            return summary.hasDoneTask
        case .text:
            guard let foldedText, !foldedText.isEmpty else { return false }
            return summary.foldedTaskLines.contains { $0.contains(foldedText) }
        }
    }

    private static func propertyText(_ value: ObsidianPropertyValue) -> String {
        switch value {
        case .string(let value): value
        case .strings(let values): values.joined(separator: " ")
        case .boolean(let value): value ? "true" : "false"
        case .number(let value): String(value)
        case .null: "null"
        case .raw(let value): value
        }
    }

    /// `foldedNeedle` is already folded by `compile`. Uses the same folding
    /// and character-wise comparison as plain text search, so every
    /// predicate in one query agrees on dotless i and accents.
    private static func contains(_ foldedNeedle: String, in haystack: String) -> Bool {
        guard !foldedNeedle.isEmpty else { return false }
        return Workspace.foldedForSearch(haystack).contains(foldedNeedle)
    }

    private static func isTextPredicate(_ predicate: ObsidianSearchPredicate) -> Bool {
        if case .text = predicate { return true }
        return false
    }
}

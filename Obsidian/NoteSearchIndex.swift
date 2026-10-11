import Foundation

/// Immutable note text shared by the metadata cache, maintained search index,
/// palette snapshots, and lazy result snippets. `String` is copy-on-write, but
/// an explicit reference makes that sharing durable as arrays and dictionaries
/// are reconciled during iCloud bursts. Parsed search metadata is also shared
/// across palette sessions. All mutable cache access is protected by the lock.
final class SearchableNoteBody: @unchecked Sendable {
    let text: String
    let foldedText: String
    private let metadataLock = NSLock()
    private var cachedSearchMetadata: ObsidianSearchMetadata?
    private let taskSummaryLock = NSLock()
    private var cachedTaskSummary: NoteTaskSummary?

    init(_ text: String) {
        self.text = text
        self.foldedText = Workspace.foldedForSearch(text)
    }

    var searchMetadata: ObsidianSearchMetadata {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        if let cachedSearchMetadata {
            return cachedSearchMetadata
        }
        let metadata = ObsidianMetadataParser.searchMetadata(in: text)
        cachedSearchMetadata = metadata
        return metadata
    }

    /// Task-list facts for `task:` filters, scanned once per body instead of
    /// once per query.
    var taskSummary: NoteTaskSummary {
        taskSummaryLock.lock()
        defer { taskSummaryLock.unlock() }
        if let cachedTaskSummary {
            return cachedTaskSummary
        }
        let summary = NoteTaskSummary.make(from: text)
        cachedTaskSummary = summary
        return summary
    }
}

/// Everything the advanced-search `task:` predicates need to know about one
/// note body. Only lines matching the task pattern are retained, both as
/// written and folded for `task:text` matching.
struct NoteTaskSummary: Sendable, Equatable {
    static let taskPattern = try! NSRegularExpression(pattern: #"^\s*[-*+]\s+\[([ xX])\]"#)
    static let empty = NoteTaskSummary(hasOpenTask: false, hasDoneTask: false, taskLines: [], foldedTaskLines: [])

    let hasOpenTask: Bool
    let hasDoneTask: Bool
    /// Every task line's text, in document order.
    let taskLines: [String]
    /// `taskLines` passed through `Workspace.foldedForSearch`.
    let foldedTaskLines: [String]

    var hasAnyTask: Bool { !taskLines.isEmpty }

    static func make(from text: String) -> NoteTaskSummary {
        guard !text.isEmpty else { return .empty }
        var hasOpenTask = false
        var hasDoneTask = false
        var taskLines: [String] = []

        for line in text.components(separatedBy: .newlines) {
            guard let isDone = taskState(in: line) else { continue }
            if isDone {
                hasDoneTask = true
            } else {
                hasOpenTask = true
            }
            taskLines.append(line)
        }

        guard !taskLines.isEmpty else { return .empty }
        return NoteTaskSummary(
            hasOpenTask: hasOpenTask,
            hasDoneTask: hasDoneTask,
            taskLines: taskLines,
            foldedTaskLines: taskLines.map(Workspace.foldedForSearch)
        )
    }

    /// `true` for a completed task line, `false` for an open one and `nil`
    /// when the line is not a task at all.
    static func taskState(in line: String) -> Bool? {
        let nsLine = line as NSString
        guard let match = taskPattern.firstMatch(
            in: line,
            range: NSRange(location: 0, length: nsLine.length)
        ),
              match.numberOfRanges > 1 else { return nil }
        let marker = nsLine.substring(with: match.range(at: 1))
        return marker.lowercased() == "x"
    }
}

/// A self-contained, `Sendable` index record. Small title/path strings are
/// values; the complete note body is shared through `SearchableNoteBody`.
struct NoteSearchEntry: Sendable, Identifiable {
    let id: URL
    let url: URL
    let title: String
    let relativePath: String?
    let bodyStorage: SearchableNoteBody
    let foldedTitle: String
    let foldedTitleHaystack: String
    var searchMetadata: ObsidianSearchMetadata? = nil

    var body: String { bodyStorage.text }
    var metadataForSearch: ObsidianSearchMetadata {
        searchMetadata ?? bodyStorage.searchMetadata
    }

    init(
        id: URL,
        url: URL,
        title: String,
        relativePath: String?,
        body: String,
        foldedTitle: String,
        foldedTitleHaystack: String,
        searchMetadata: ObsidianSearchMetadata? = nil
    ) {
        self.init(
            id: id,
            url: url,
            title: title,
            relativePath: relativePath,
            bodyStorage: SearchableNoteBody(body),
            foldedTitle: foldedTitle,
            foldedTitleHaystack: foldedTitleHaystack,
            searchMetadata: searchMetadata
        )
    }

    init(
        id: URL,
        url: URL,
        title: String,
        relativePath: String?,
        bodyStorage: SearchableNoteBody,
        foldedTitle: String,
        foldedTitleHaystack: String,
        searchMetadata: ObsidianSearchMetadata? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.relativePath = relativePath
        self.bodyStorage = bodyStorage
        self.foldedTitle = foldedTitle
        self.foldedTitleHaystack = foldedTitleHaystack
        self.searchMetadata = searchMetadata
    }
}

/// A snippet recipe rather than an eagerly allocated snippet. SwiftUI's lazy
/// result rows ask for `subtitle` only when they are rendered.
final class NoteSearchSnippetSource: @unchecked Sendable {
    let bodyStorage: SearchableNoteBody
    let query: String
    private let lock = NSLock()
    private var cachedSnippet: String?
    private var hasComputedSnippet = false

    init(bodyStorage: SearchableNoteBody, query: String) {
        self.bodyStorage = bodyStorage
        self.query = query
    }

    var isMaterialized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasComputedSnippet
    }

    func snippet() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if hasComputedSnippet {
            return cachedSnippet
        }
        cachedSnippet = Workspace.searchSnippet(in: bodyStorage.text, query: query)
        hasComputedSnippet = true
        return cachedSnippet
    }
}

struct NoteSearchResult: Sendable, Identifiable {
    let id: URL
    let url: URL
    let title: String
    let fallbackSubtitle: String?
    let snippetSource: NoteSearchSnippetSource?
    let isBodyMatch: Bool

    var subtitle: String? {
        guard let snippetSource else { return fallbackSubtitle }
        return snippetSource.snippet() ?? fallbackSubtitle
    }

    init(
        id: URL,
        url: URL,
        title: String,
        subtitle: String?,
        isBodyMatch: Bool
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.fallbackSubtitle = subtitle
        self.snippetSource = nil
        self.isBodyMatch = isBodyMatch
    }

    init(
        id: URL,
        url: URL,
        title: String,
        fallbackSubtitle: String?,
        snippetSource: NoteSearchSnippetSource,
        isBodyMatch: Bool
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.fallbackSubtitle = fallbackSubtitle
        self.snippetSource = snippetSource
        self.isBodyMatch = isBodyMatch
    }
}

/// Main-actor-owned, incrementally reconciled search index. Unchanged records
/// retain their body storage and parsed advanced-search metadata. Add/change/
/// rename/delete operations only replace the affected dictionary entries.
struct NoteSearchIndex: Sendable {
    private var recordsByPath: [String: NoteSearchEntry] = [:]
    private var orderedPaths: [String] = []

    var count: Int { recordsByPath.count }

    var entries: [NoteSearchEntry] {
        orderedPaths.compactMap { recordsByPath[$0] }
    }

    @discardableResult
    mutating func reconcile(_ candidates: [NoteSearchEntry]) -> Bool {
        let candidatePaths = candidates.map { Self.key(for: $0.url) }
        var nextRecords: [String: NoteSearchEntry] = [:]
        nextRecords.reserveCapacity(candidates.count)
        var didChange = candidatePaths != orderedPaths || candidates.count != recordsByPath.count

        for (path, candidate) in zip(candidatePaths, candidates) {
            if let existing = recordsByPath[path], Self.canReuse(existing, for: candidate) {
                nextRecords[path] = existing
            } else {
                nextRecords[path] = candidate
                didChange = true
            }
        }

        recordsByPath = nextRecords
        orderedPaths = candidatePaths
        return didChange
    }

    mutating func removeAll() -> Bool {
        guard !recordsByPath.isEmpty || !orderedPaths.isEmpty else { return false }
        recordsByPath.removeAll(keepingCapacity: false)
        orderedPaths.removeAll(keepingCapacity: false)
        return true
    }

    /// The indexed record whose URL standardizes to `path`, if any.
    func entry(forPath path: String) -> NoteSearchEntry? {
        recordsByPath[path]
    }

    /// Replaces one record in place without touching the others or the
    /// result order. Returns `true` when the stored record changed. A path
    /// that is not indexed yet is left alone and returns `false`; callers
    /// fall back to `reconcile(_:)` in that case.
    @discardableResult
    mutating func update(_ entry: NoteSearchEntry) -> Bool {
        let path = Self.key(for: entry.url)
        guard let existing = recordsByPath[path] else { return false }
        guard !Self.canReuse(existing, for: entry) else { return false }
        recordsByPath[path] = entry
        return true
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func canReuse(_ existing: NoteSearchEntry, for candidate: NoteSearchEntry) -> Bool {
        existing.id == candidate.id
            && existing.url == candidate.url
            && existing.title == candidate.title
            && existing.relativePath == candidate.relativePath
            && existing.foldedTitle == candidate.foldedTitle
            && existing.foldedTitleHaystack == candidate.foldedTitleHaystack
            && existing.bodyStorage === candidate.bodyStorage
    }
}

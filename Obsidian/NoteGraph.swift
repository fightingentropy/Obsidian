import CoreGraphics
import Foundation

struct NoteLinkReference: Hashable, Sendable {
    let destination: String
}

struct NoteGraphNode: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let title: String
    let relativePath: String
    let incomingCount: Int
    let outgoingCount: Int

    var degree: Int {
        incomingCount + outgoingCount
    }
}

struct NoteGraphEdge: Identifiable, Hashable, Sendable {
    let source: URL
    let target: URL

    var id: String {
        source.path + "->" + target.path
    }
}

struct NoteGraphSnapshot: Sendable, Equatable {
    let nodes: [NoteGraphNode]
    let edges: [NoteGraphEdge]
    let selectedNodeID: URL?
    let connectedNodeIDs: Set<URL>

    static let empty = NoteGraphSnapshot(
        nodes: [],
        edges: [],
        selectedNodeID: nil,
        connectedNodeIDs: []
    )

    var selectedNode: NoteGraphNode? {
        guard let selectedNodeID else { return nil }
        return nodes.first(where: { $0.id == selectedNodeID })
    }

    func backlinks(to targetID: URL?) -> [NoteGraphNode] {
        guard let targetID else { return [] }

        let sourceIDs = Set(edges.compactMap { edge -> URL? in
            edge.target == targetID ? edge.source : nil
        })

        return nodes
            .filter { sourceIDs.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func neighbors(of nodeID: URL?) -> [NoteGraphNode] {
        guard let nodeID else { return [] }

        let relatedIDs = edges.reduce(into: Set<URL>()) { result, edge in
            if edge.source == nodeID {
                result.insert(edge.target)
            } else if edge.target == nodeID {
                result.insert(edge.source)
            }
        }

        // Filter down to the (typically small) neighbourhood before sorting so
        // the cost scales with the node's degree rather than the whole graph.
        return nodes
            .filter { relatedIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.degree != rhs.degree {
                    return lhs.degree > rhs.degree
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }
}

struct NoteGraphLayout: Sendable, Equatable {
    let positions: [URL: CGPoint]

    static let empty = NoteGraphLayout(positions: [:])
}

/// The single, shared tokenizer for wiki-style and markdown link/image syntax.
///
/// Consumed by the note-graph builder (`references(in:)`), the preview
/// rewriter (embeds, note links, and images), and — via
/// `EditorLinkScanner` parity tests — the editor highlighter and Cmd-click
/// detector, so every feature agrees on what counts as a link. The editor's
/// per-keystroke path uses the NSString-based `EditorLinkScanner` twin instead
/// (Character arrays would be too costly there); unit tests assert the two
/// tokenizers accept the same syntax.
enum MarkdownNoteLinkExtractor {
    struct ObsidianNoteLinkMatch {
        let destination: String
        let displayName: String
        let nextIndex: Int
    }

    struct MarkdownLinkMatch {
        let destination: String
        let nextIndex: Int
    }

    struct MarkdownImageMatch {
        let original: String
        let altText: String
        let destination: String
        let title: String?
        let nextIndex: Int
    }

    struct ObsidianEmbedMatch {
        let rawReference: String
        let original: String
        let nextIndex: Int
    }

    /// Parsed form of the body of a `[[...]]`/`![[...]]` reference: the note or
    /// asset destination, the optional `|alias` segment, and derived forms
    /// (embed width, filename fallback) used by the various consumers.
    struct ObsidianReferenceDescriptor {
        let destination: String
        let alias: String?
        let width: Int?
        /// Filename-derived fallback label (path and extension stripped).
        let fileName: String
    }

    private struct FenceDescriptor {
        let character: Character
        let count: Int
    }

    static func references(in markdown: String) -> [NoteLinkReference] {
        let sanitized = sanitizedMarkdown(markdown)
        let characters = Array(sanitized)
        var references: [NoteLinkReference] = []
        var index = 0

        while index < characters.count {
            if let match = obsidianNoteLink(in: characters, from: index) {
                references.append(NoteLinkReference(destination: match.destination))
                index = match.nextIndex
                continue
            }

            if let match = markdownLink(in: characters, from: index) {
                references.append(NoteLinkReference(destination: match.destination))
                index = match.nextIndex
                continue
            }

            index += 1
        }

        return references
    }

    static func obsidianNoteLink(
        in characters: [Character],
        from index: Int
    ) -> ObsidianNoteLinkMatch? {
        guard index + 3 < characters.count else { return nil }
        guard characters[index] == "[",
              characters[index + 1] == "[",
              (index == 0 || characters[index - 1] != "!") else {
            return nil
        }

        var cursor = index + 2
        while cursor + 1 < characters.count {
            if characters[cursor] == "]", characters[cursor + 1] == "]" {
                let rawReference = String(characters[(index + 2)..<cursor])
                let descriptor = parseObsidianNoteReference(rawReference)
                guard !descriptor.destination.isEmpty else {
                    return nil
                }

                return ObsidianNoteLinkMatch(
                    destination: descriptor.destination,
                    displayName: descriptor.displayName,
                    nextIndex: cursor + 2
                )
            }

            if characters[cursor].isNewline {
                return nil
            }

            cursor += 1
        }

        return nil
    }

    static func markdownLink(
        in characters: [Character],
        from index: Int
    ) -> MarkdownLinkMatch? {
        guard index < characters.count,
              characters[index] == "[",
              (index == 0 || characters[index - 1] != "!") else {
            return nil
        }

        var cursor = index + 1
        while cursor < characters.count, characters[cursor] != "]" {
            if characters[cursor].isNewline {
                return nil
            }
            cursor += 1
        }

        guard cursor < characters.count,
              cursor > index + 1,
              cursor + 1 < characters.count,
              characters[cursor + 1] == "(" else {
            return nil
        }

        cursor += 2
        cursor = skipWhitespace(in: characters, from: cursor)

        let destination: String
        if cursor < characters.count, characters[cursor] == "<" {
            cursor += 1
            let start = cursor
            while cursor < characters.count, characters[cursor] != ">" {
                if characters[cursor].isNewline {
                    return nil
                }
                cursor += 1
            }

            guard cursor < characters.count else { return nil }
            destination = String(characters[start..<cursor])
            cursor += 1
        } else {
            let start = cursor
            while cursor < characters.count,
                  characters[cursor] != ")",
                  !characters[cursor].isWhitespace {
                if characters[cursor].isNewline {
                    return nil
                }
                cursor += 1
            }

            destination = String(characters[start..<cursor])
        }

        guard !destination.isEmpty else { return nil }

        cursor = skipWhitespace(in: characters, from: cursor)
        if cursor < characters.count, characters[cursor] != ")" {
            let quote = characters[cursor]
            guard quote == "\"" || quote == "'" else { return nil }

            cursor += 1
            while cursor < characters.count, characters[cursor] != quote {
                if characters[cursor].isNewline {
                    return nil
                }
                cursor += 1
            }

            guard cursor < characters.count else { return nil }
            cursor += 1
            cursor = skipWhitespace(in: characters, from: cursor)
        }

        guard cursor < characters.count, characters[cursor] == ")" else {
            return nil
        }

        return MarkdownLinkMatch(destination: destination, nextIndex: cursor + 1)
    }

    /// Parses `![alt](destination "title")` starting at the leading `!`.
    ///
    /// Shared with the preview rewriter so image syntax is recognized
    /// identically everywhere. Unlike `markdownLink`, the alt-text and title
    /// scans tolerate newlines (matching what the preview has historically
    /// accepted).
    static func markdownImage(
        in characters: [Character],
        from index: Int
    ) -> MarkdownImageMatch? {
        guard index + 3 < characters.count,
              characters[index] == "!",
              characters[index + 1] == "[" else {
            return nil
        }

        var cursor = index + 2
        while cursor < characters.count {
            if characters[cursor] == "]" {
                break
            }

            cursor += 1
        }

        guard cursor < characters.count,
              cursor + 1 < characters.count,
              characters[cursor] == "]",
              characters[cursor + 1] == "(" else {
            return nil
        }

        let altText = String(characters[(index + 2)..<cursor])
        cursor += 2
        cursor = skipWhitespace(in: characters, from: cursor)

        let destination: String
        if cursor < characters.count, characters[cursor] == "<" {
            cursor += 1
            let destinationStart = cursor
            while cursor < characters.count, characters[cursor] != ">" {
                cursor += 1
            }

            guard cursor < characters.count else {
                return nil
            }

            destination = String(characters[destinationStart..<cursor])
            cursor += 1
        } else {
            let destinationStart = cursor
            while cursor < characters.count,
                  characters[cursor] != ")",
                  !characters[cursor].isWhitespace {
                cursor += 1
            }

            destination = String(characters[destinationStart..<cursor])
        }

        guard !destination.isEmpty else {
            return nil
        }

        cursor = skipWhitespace(in: characters, from: cursor)

        var title: String?
        if cursor < characters.count, characters[cursor] != ")" {
            let quote = characters[cursor]
            guard quote == "\"" || quote == "'" else {
                return nil
            }

            cursor += 1
            let titleStart = cursor
            while cursor < characters.count, characters[cursor] != quote {
                cursor += 1
            }

            guard cursor < characters.count else {
                return nil
            }

            title = String(characters[titleStart..<cursor])
            cursor += 1
            cursor = skipWhitespace(in: characters, from: cursor)
        }

        guard cursor < characters.count, characters[cursor] == ")" else {
            return nil
        }

        let nextIndex = cursor + 1
        return MarkdownImageMatch(
            original: String(characters[index..<nextIndex]),
            altText: altText,
            destination: destination,
            title: title,
            nextIndex: nextIndex
        )
    }

    /// Parses an `![[...]]` Obsidian embed starting at the leading `!`,
    /// returning the raw inner reference for `parseObsidianReference(_:)`.
    static func obsidianEmbed(
        in characters: [Character],
        from index: Int
    ) -> ObsidianEmbedMatch? {
        guard index + 3 < characters.count,
              characters[index] == "!",
              characters[index + 1] == "[",
              characters[index + 2] == "[" else {
            return nil
        }

        var cursor = index + 3
        while cursor + 1 < characters.count {
            if characters[cursor] == "]", characters[cursor + 1] == "]" {
                return ObsidianEmbedMatch(
                    rawReference: String(characters[(index + 3)..<cursor]),
                    original: String(characters[index..<(cursor + 2)]),
                    nextIndex: cursor + 2
                )
            }

            cursor += 1
        }

        return nil
    }

    /// The one parser for the body of a `[[...]]`/`![[...]]` reference. Both
    /// note-link consumers (alias as display text) and embed consumers (alias
    /// as pixel width) derive their views from this shared descriptor.
    static func parseObsidianReference(_ rawReference: String) -> ObsidianReferenceDescriptor {
        let trimmed = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: "|", maxSplits: 1).map(String.init)
        let destinationWithFragment = pieces.first ?? trimmed
        let destination = destinationWithFragment
            .split(separator: "#", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawAlias = pieces.count > 1
            ? pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let alias = rawAlias.flatMap { $0.isEmpty ? nil : $0 }
        let fileName = ((destination as NSString).deletingPathExtension as NSString).lastPathComponent

        return ObsidianReferenceDescriptor(
            destination: destination,
            alias: alias,
            width: alias.flatMap { Int($0) },
            fileName: fileName
        )
    }

    static func parseObsidianNoteReference(_ rawReference: String) -> (destination: String, displayName: String) {
        let descriptor = parseObsidianReference(rawReference)
        let displayName = descriptor.alias
            ?? (descriptor.fileName.isEmpty ? descriptor.destination : descriptor.fileName)

        return (descriptor.destination, displayName)
    }

    /// Masks fenced and inline code with spaces so link scanners can skip
    /// examples without shifting ranges. Every masked `Character` becomes one
    /// space per UTF-16 code unit and line terminators are copied verbatim,
    /// so the result always has the same `NSString` length as `markdown` and
    /// an `NSRange` found in it indexes `markdown` directly.
    static func maskingCodeRegions(_ markdown: String) -> String {
        sanitizedMarkdown(markdown)
    }

    private static func sanitizedMarkdown(_ markdown: String) -> String {
        var sanitized = ""
        // Masking never adds UTF-8 bytes, so this is an upper bound.
        sanitized.reserveCapacity(markdown.utf8.count)
        var activeFence: FenceDescriptor?
        var lineStart = markdown.startIndex

        while lineStart < markdown.endIndex {
            // Any newline Character ends a line. "\r\n" is one Character, so
            // splitting on "\n" alone never split CRLF notes into lines.
            let lineEnd = markdown[lineStart...].firstIndex(where: { $0.isNewline }) ?? markdown.endIndex
            let lineString = String(markdown[lineStart..<lineEnd])
            let trimmed = lineString.trimmingLeadingWhitespace()

            if let fence = fenceDescriptor(in: trimmed) {
                if let currentFence = activeFence {
                    if currentFence.character == fence.character, fence.count >= currentFence.count {
                        activeFence = nil
                    }
                } else {
                    activeFence = fence
                }

                sanitized += maskedSpaces(utf16Length: lineString.utf16.count)
            } else if activeFence != nil {
                sanitized += maskedSpaces(utf16Length: lineString.utf16.count)
            } else {
                sanitized += maskInlineCode(in: lineString)
            }

            guard lineEnd < markdown.endIndex else { break }
            sanitized.append(markdown[lineEnd])
            lineStart = markdown.index(after: lineEnd)
        }

        return sanitized
    }

    private static func maskInlineCode(in line: String) -> String {
        let characters = Array(line)
        var result = ""
        result.reserveCapacity(line.utf8.count)
        var index = 0
        var activeFenceLength: Int?

        while index < characters.count {
            if characters[index] == "`" {
                let runStart = index
                var runUTF16Length = 0
                while index < characters.count, characters[index] == "`" {
                    runUTF16Length += characters[index].utf16.count
                    index += 1
                }

                let fenceLength = index - runStart
                result += maskedSpaces(utf16Length: runUTF16Length)

                if activeFenceLength == fenceLength {
                    activeFenceLength = nil
                } else if activeFenceLength == nil {
                    activeFenceLength = fenceLength
                }

                continue
            }

            if activeFenceLength == nil {
                result.append(characters[index])
            } else {
                // An emoji or combining sequence is one Character but several
                // UTF-16 code units; pad all of them.
                result += maskedSpaces(utf16Length: characters[index].utf16.count)
            }

            index += 1
        }

        return result
    }

    /// Spaces standing in for masked text of `utf16Length` UTF-16 code units.
    private static func maskedSpaces(utf16Length: Int) -> String {
        String(repeating: " ", count: utf16Length)
    }

    private static func fenceDescriptor(in trimmedLine: String) -> FenceDescriptor? {
        guard let first = trimmedLine.first, first == "`" || first == "~" else {
            return nil
        }

        let count = trimmedLine.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        return FenceDescriptor(character: first, count: count)
    }

    private static func skipWhitespace(in characters: [Character], from startIndex: Int) -> Int {
        var cursor = startIndex
        while cursor < characters.count, characters[cursor].isWhitespace {
            cursor += 1
        }
        return cursor
    }
}

struct NoteReferenceResolver: Sendable {
    private let vaultURL: URL?
    private let noteURLs: Set<URL>
    private let relativePathLookup: [String: URL]
    private let relativeStemLookup: [String: URL]
    private let basenameLookup: [String: [URL]]
    private let stemLookup: [String: [URL]]

    init(noteURLs: [URL], vaultURL: URL?) {
        let standardizedVaultURL = vaultURL?.resolvingSymlinksInPath().standardizedFileURL
        let standardizedNoteURLs = noteURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL }

        self.vaultURL = standardizedVaultURL
        self.noteURLs = Set(standardizedNoteURLs)

        var relativePathLookup: [String: URL] = [:]
        var relativeStemLookup: [String: URL] = [:]
        var basenameEntries: [(String, URL)] = []
        var stemEntries: [(String, URL)] = []

        for noteURL in standardizedNoteURLs {
            let fileName = noteURL.lastPathComponent
            basenameEntries.append((Self.normalizeLookupKey(fileName), noteURL))
            stemEntries.append((Self.normalizeLookupKey(noteURL.deletingPathExtension().lastPathComponent), noteURL))

            if let standardizedVaultURL,
               let relativePath = Self.relativePath(from: standardizedVaultURL, to: noteURL) {
                let normalizedRelativePath = Self.normalizeLookupKey(relativePath)
                relativePathLookup[normalizedRelativePath] = noteURL

                let relativeStem = (relativePath as NSString).deletingPathExtension
                relativeStemLookup[Self.normalizeLookupKey(relativeStem)] = noteURL
            }
        }

        self.relativePathLookup = relativePathLookup
        self.relativeStemLookup = relativeStemLookup
        self.basenameLookup = Self.groupedLookup(from: basenameEntries)
        self.stemLookup = Self.groupedLookup(from: stemEntries)
    }

    func resolve(destination rawDestination: String, from sourceURL: URL?) -> URL? {
        // Web/non-file destinations can never resolve to a vault note, so skip the
        // (potentially costly) normalization and multi-dictionary lookup entirely.
        if Self.isExternalDestination(rawDestination) {
            return nil
        }

        let normalizedDestination = Self.normalizedDestination(rawDestination)
        guard !normalizedDestination.isEmpty else {
            return nil
        }

        if let directURL = Self.explicitFileURL(from: normalizedDestination) {
            return noteURLs.contains(directURL) ? directURL : nil
        }

        if let sourceURL,
           let relativeMatch = resolveRelativeDestination(normalizedDestination, from: sourceURL) {
            return relativeMatch
        }

        let normalizedLookupKey = Self.normalizeLookupKey(normalizedDestination)
        if let match = relativePathLookup[normalizedLookupKey] {
            return match
        }

        if let match = relativeStemLookup[Self.normalizeLookupKey(Self.removingKnownExtension(from: normalizedDestination))] {
            return match
        }

        let fileName = (normalizedDestination as NSString).lastPathComponent
        if let match = bestCandidate(
            in: basenameLookup,
            key: Self.normalizeLookupKey(fileName),
            exactComponent: fileName,
            from: sourceURL,
            componentForURL: { $0.lastPathComponent }
        ) {
            return match
        }

        let stem = (fileName as NSString).deletingPathExtension
        if let match = bestCandidate(
            in: stemLookup,
            key: Self.normalizeLookupKey(stem),
            exactComponent: stem,
            from: sourceURL,
            componentForURL: { $0.deletingPathExtension().lastPathComponent }
        ) {
            return match
        }

        if normalizedDestination.hasPrefix("/"),
           let vaultRelativeMatch = relativePathLookup[Self.normalizeLookupKey(String(normalizedDestination.dropFirst()))] {
            return vaultRelativeMatch
        }

        return nil
    }

    /// Resolve an ambiguous basename/stem key to a single note.
    ///
    /// When more than one note shares the (case-folded) key, pick deterministically
    /// instead of dropping the link: prefer an exact-case component match, then a
    /// match in the source note's directory, then the shortest path, then alphabetical.
    /// On case-sensitive volumes this keeps case-distinct notes from colliding;
    /// on case-insensitive volumes the folded key still resolves as before.
    private func bestCandidate(
        in lookup: [String: [URL]],
        key: String,
        exactComponent: String,
        from sourceURL: URL?,
        componentForURL: (URL) -> String
    ) -> URL? {
        guard let candidates = lookup[key], !candidates.isEmpty else {
            return nil
        }

        if candidates.count == 1 {
            return candidates[0]
        }

        // Prefer candidates whose on-disk component matches the requested case exactly.
        let exactCaseMatches = candidates.filter { componentForURL($0) == exactComponent }
        let pool = exactCaseMatches.isEmpty ? candidates : exactCaseMatches

        if pool.count == 1 {
            return pool[0]
        }

        let sourceDirectoryPath = sourceURL?.deletingLastPathComponent().standardizedFileURL.path

        return pool.min { lhs, rhs in
            if let sourceDirectoryPath {
                let lhsLocal = lhs.deletingLastPathComponent().path == sourceDirectoryPath
                let rhsLocal = rhs.deletingLastPathComponent().path == sourceDirectoryPath
                if lhsLocal != rhsLocal {
                    return lhsLocal
                }
            }

            if lhs.path.count != rhs.path.count {
                return lhs.path.count < rhs.path.count
            }

            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private func resolveRelativeDestination(_ destination: String, from sourceURL: URL) -> URL? {
        let sourceDirectoryURL = sourceURL.deletingLastPathComponent()

        for candidate in Self.relativeCandidates(for: destination, relativeTo: sourceDirectoryURL) {
            if noteURLs.contains(candidate) {
                return candidate
            }
        }

        if let standardizedVaultURL = vaultURL {
            for candidate in Self.relativeCandidates(for: destination, relativeTo: standardizedVaultURL) {
                if noteURLs.contains(candidate) {
                    return candidate
                }
            }
        }

        return nil
    }

    private static func groupedLookup(from entries: [(String, URL)]) -> [String: [URL]] {
        var grouped: [String: [URL]] = [:]
        for (key, url) in entries where !key.isEmpty {
            grouped[key, default: []].append(url)
        }
        return grouped
    }

    /// Reports whether the destination is an external (non-vault) link such as a
    /// web URL or `mailto:`/`tel:` scheme that can never resolve to a note.
    /// Only absolute `file:` references are treated as in-vault here; everything
    /// else with a recognized non-file scheme is short-circuited.
    private static func isExternalDestination(_ rawDestination: String) -> Bool {
        var trimmed = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }

        guard let schemeRange = trimmed.range(of: "://") ?? trimmed.range(of: ":") else {
            return false
        }

        let scheme = trimmed[trimmed.startIndex..<schemeRange.lowerBound].lowercased()
        guard !scheme.isEmpty, scheme != "file" else {
            return false
        }

        // A bare drive-letter-like or Windows path won't contain a clean scheme;
        // only treat it as external when the scheme is purely alphanumeric.
        guard scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
              scheme.first?.isLetter == true else {
            return false
        }

        return externalLinkSchemes.contains(scheme) || trimmed.contains("://")
    }

    private static func relativeCandidates(for destination: String, relativeTo baseURL: URL) -> [URL] {
        let destinationPathExtension = (destination as NSString).pathExtension.lowercased()
        let candidates: [String]

        if markdownNoteExtensions.contains(destinationPathExtension) {
            candidates = [destination]
        } else if destinationPathExtension.isEmpty {
            candidates = markdownNoteExtensionsInPriorityOrder.map { destination + "." + $0 }
        } else {
            candidates = []
        }

        return candidates.map { candidate in
            URL(fileURLWithPath: candidate, relativeTo: baseURL)
                .resolvingSymlinksInPath()
                .standardizedFileURL
        }
    }

    private static func normalizedDestination(_ destination: String) -> String {
        var trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }

        let withoutFragment = trimmed.split(separator: "#", maxSplits: 1).first.map(String.init) ?? trimmed
        let decoded = withoutFragment.removingPercentEncoding ?? withoutFragment
        return decoded.replacingOccurrences(of: "\\", with: "/")
    }

    private static func normalizeLookupKey(_ key: String) -> String {
        key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
    }

    private static func removingKnownExtension(from destination: String) -> String {
        let pathExtension = (destination as NSString).pathExtension.lowercased()
        guard markdownNoteExtensions.contains(pathExtension) else {
            return destination
        }

        return (destination as NSString).deletingPathExtension
    }

    private static func explicitFileURL(from destination: String) -> URL? {
        if let url = URL(string: destination), url.scheme?.lowercased() == "file" {
            return url.resolvingSymlinksInPath().standardizedFileURL
        }

        guard destination.hasPrefix("/") else {
            return nil
        }

        return URL(fileURLWithPath: destination)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func relativePath(from baseURL: URL, to fileURL: URL) -> String? {
        let standardizedBaseURL = baseURL.standardizedFileURL
        let standardizedFileURL = fileURL.standardizedFileURL
        let basePath = standardizedBaseURL.path.hasSuffix("/") ? standardizedBaseURL.path : standardizedBaseURL.path + "/"
        guard standardizedFileURL.path.hasPrefix(basePath) else {
            return nil
        }

        return String(standardizedFileURL.path.dropFirst(basePath.count))
    }
}

enum NoteGraphBuilder {
    private struct NoteEntry {
        let url: URL
        let title: String
        let relativePath: String
        let links: [NoteLinkReference]
    }

    static func makeSnapshot(
        files: [FileItem],
        metadataByPath: [String: CachedMarkdownMetadata],
        vaultURL: URL?,
        selectedFileURL: URL?,
        liveSelectedMarkdown: String?
    ) -> NoteGraphSnapshot {
        let standardizedSelectedFileURL = selectedFileURL?.resolvingSymlinksInPath().standardizedFileURL
        let standardizedVaultURL = vaultURL?.resolvingSymlinksInPath().standardizedFileURL

        let entries = files.map { file -> NoteEntry in
            let standardizedURL = file.url.resolvingSymlinksInPath().standardizedFileURL
            let metadataKey = standardizedURL.path
            let cachedMetadata = metadataByPath[metadataKey]
            let isSelected = standardizedSelectedFileURL == standardizedURL

            let title: String
            let links: [NoteLinkReference]

            if isSelected, let liveSelectedMarkdown {
                title = Workspace.extractTitle(from: liveSelectedMarkdown) ?? file.sidebarTitle
                links = MarkdownNoteLinkExtractor.references(in: liveSelectedMarkdown)
            } else {
                title = cachedMetadata?.noteTitle ?? file.sidebarTitle
                links = cachedMetadata?.noteLinks ?? []
            }

            let relativePath = relativePath(for: standardizedURL, relativeTo: standardizedVaultURL) ?? file.name
            return NoteEntry(
                url: standardizedURL,
                title: title,
                relativePath: relativePath,
                links: links
            )
        }

        let resolver = NoteReferenceResolver(
            noteURLs: entries.map(\.url),
            vaultURL: standardizedVaultURL
        )

        var outgoingBySource: [URL: Set<URL>] = [:]
        var incomingCounts: [URL: Int] = [:]
        var uniqueEdges: Set<NoteGraphEdge> = []

        for entry in entries {
            for reference in entry.links {
                guard let resolvedURL = resolver.resolve(destination: reference.destination, from: entry.url),
                      resolvedURL != entry.url else {
                    continue
                }

                let edge = NoteGraphEdge(source: entry.url, target: resolvedURL)
                guard uniqueEdges.insert(edge).inserted else { continue }

                outgoingBySource[entry.url, default: []].insert(resolvedURL)
                incomingCounts[resolvedURL, default: 0] += 1
            }
        }

        let nodes = entries.map { entry in
            NoteGraphNode(
                id: entry.url,
                url: entry.url,
                title: entry.title,
                relativePath: entry.relativePath,
                incomingCount: incomingCounts[entry.url, default: 0],
                outgoingCount: outgoingBySource[entry.url]?.count ?? 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.title != rhs.title {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }

        let edges = uniqueEdges.sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return lhs.source.path.localizedStandardCompare(rhs.source.path) == .orderedAscending
            }
            return lhs.target.path.localizedStandardCompare(rhs.target.path) == .orderedAscending
        }

        let connectedNodeIDs = edges.reduce(into: Set<URL>()) { result, edge in
            guard let standardizedSelectedFileURL else { return }

            if edge.source == standardizedSelectedFileURL {
                result.insert(edge.target)
            } else if edge.target == standardizedSelectedFileURL {
                result.insert(edge.source)
            }
        }

        let selectedNodeID = nodes.contains(where: { $0.id == standardizedSelectedFileURL })
            ? standardizedSelectedFileURL
            : nil

        return NoteGraphSnapshot(
            nodes: nodes,
            edges: edges,
            selectedNodeID: selectedNodeID,
            connectedNodeIDs: connectedNodeIDs
        )
    }

    private static func relativePath(for url: URL, relativeTo vaultURL: URL?) -> String? {
        guard let vaultURL else { return nil }
        let basePath = vaultURL.path.hasSuffix("/") ? vaultURL.path : vaultURL.path + "/"
        guard url.path.hasPrefix(basePath) else { return nil }
        return String(url.path.dropFirst(basePath.count))
    }
}

enum NoteGraphLayoutEngine {
    /// How the n-body repulsion term of the force simulation is evaluated.
    enum RepulsionStrategy: Equatable, Sendable {
        /// Every pair of nodes is visited: O(n²) per iteration, exact.
        case exact
        /// Barnes-Hut quadtree approximation: O(n log n) per iteration.
        case barnesHut
    }

    /// Graphs with more nodes than this use the Barnes-Hut approximation for
    /// repulsion; smaller graphs keep the exact all-pairs computation so their
    /// layouts are unchanged.
    static let barnesHutNodeThreshold = 300

    /// Barnes-Hut opening angle. A quadtree cell is treated as a single point
    /// mass when its width divided by its distance from the body is below this.
    static let barnesHutTheta: CGFloat = 0.8

    /// The repulsion strategy the engine uses for a graph of `nodeCount` nodes.
    static func repulsionStrategy(forNodeCount nodeCount: Int) -> RepulsionStrategy {
        nodeCount > barnesHutNodeThreshold ? .barnesHut : .exact
    }

    static func generate(for snapshot: NoteGraphSnapshot, relayoutSeed: Int) -> NoteGraphLayout {
        generatedLayouts(
            for: snapshot,
            relayoutSeed: relayoutSeed,
            capturesMotion: false
        ).last ?? .empty
    }

    /// Samples the force simulation as it settles so the graph can render the
    /// same live, physical motion as a browser force-directed graph.
    static func animationFrames(
        for snapshot: NoteGraphSnapshot,
        relayoutSeed: Int
    ) -> [NoteGraphLayout] {
        generatedLayouts(
            for: snapshot,
            relayoutSeed: relayoutSeed,
            capturesMotion: true
        )
    }

    private static func generatedLayouts(
        for snapshot: NoteGraphSnapshot,
        relayoutSeed: Int,
        capturesMotion: Bool
    ) -> [NoteGraphLayout] {
        guard !snapshot.nodes.isEmpty else {
            return [.empty]
        }

        if snapshot.nodes.count == 1, let node = snapshot.nodes.first {
            return [NoteGraphLayout(positions: [node.id: .zero])]
        }

        if snapshot.edges.isEmpty {
            return [scatterLayout(
                for: snapshot.nodes,
                pinnedNodeID: snapshot.selectedNodeID,
                relayoutSeed: relayoutSeed
            )]
        }

        let nodes = snapshot.nodes
        let indexedNodes = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        let pinnedNodeID = snapshot.selectedNodeID
        let components = connectedComponents(for: snapshot)
        let componentByNode = Dictionary(uniqueKeysWithValues: components.enumerated().flatMap { componentIndex, component in
            component.map { ($0, componentIndex) }
        })
        let componentAnchors = makeComponentAnchors(
            for: components,
            pinnedNodeID: pinnedNodeID,
            relayoutSeed: relayoutSeed
        )
        var positions = initialPositions(
            for: nodes,
            pinnedNodeID: pinnedNodeID,
            componentByNode: componentByNode,
            componentAnchors: componentAnchors,
            components: components,
            relayoutSeed: relayoutSeed
        )
        var velocities = Array(repeating: CGVector.zero, count: nodes.count)
        var temperature: CGFloat = 0.11
        let idealEdgeLength = max(0.34, 1.22 / sqrt(CGFloat(max(nodes.count, 1))))
        let maxRadius: CGFloat = 2.4
        let selectedComponentIndex = pinnedNodeID.flatMap { componentByNode[$0] }
        let frameStride = 5
        var sampledPositions: [[CGPoint]] = capturesMotion ? [positions] : []
        let strategy = repulsionStrategy(forNodeCount: nodes.count)
        // The tree is only populated on the approximate path; keep the exact
        // path's allocation at its minimum.
        var quadtree = RepulsionQuadtree(bodyCount: strategy == .barnesHut ? nodes.count : 0)

        for iteration in 0..<220 {
            var displacement = Array(repeating: CGVector.zero, count: nodes.count)

            switch strategy {
            case .exact:
                for firstIndex in nodes.indices {
                    for secondIndex in nodes.indices where secondIndex > firstIndex {
                        let deltaX = positions[firstIndex].x - positions[secondIndex].x
                        let deltaY = positions[firstIndex].y - positions[secondIndex].y
                        let distance = max(0.045, hypot(deltaX, deltaY))
                        let sameComponent = componentByNode[nodes[firstIndex].id] == componentByNode[nodes[secondIndex].id]
                        let repulsion = sameComponent ? 0.016 / (distance * distance) : 0.009 / (distance * distance)
                        let directionX = deltaX / distance
                        let directionY = deltaY / distance
                        let vector = CGVector(dx: directionX * repulsion, dy: directionY * repulsion)
                        displacement[firstIndex].dx += vector.dx
                        displacement[firstIndex].dy += vector.dy
                        displacement[secondIndex].dx -= vector.dx
                        displacement[secondIndex].dy -= vector.dy
                    }
                }

            case .barnesHut:
                // Component weighting: the exact path repels nodes from *different*
                // components slightly less (0.009 vs 0.016) so clusters sit closer
                // together. A quadtree cell aggregates nodes from many components,
                // so a per-pair factor is not available here. Rather than building
                // one tree per component plus a global tree (twice the traversals,
                // and vaults have many singleton components), the approximate path
                // uses the same-component constant for every pair: at this node
                // count the component anchors and edge springs dominate the
                // arrangement, and the difference is within the approximation error.
                quadtree.rebuild(with: positions)
                quadtree.accumulateRepulsion(
                    into: &displacement,
                    positions: positions,
                    strength: 0.016,
                    minimumDistance: 0.045,
                    theta: barnesHutTheta
                )
            }

            for edge in snapshot.edges {
                guard let sourceIndex = indexedNodes[edge.source],
                      let targetIndex = indexedNodes[edge.target] else {
                    continue
                }

                let deltaX = positions[sourceIndex].x - positions[targetIndex].x
                let deltaY = positions[sourceIndex].y - positions[targetIndex].y
                let distance = max(0.045, hypot(deltaX, deltaY))
                let force = (distance - idealEdgeLength) * 0.11
                let directionX = deltaX / distance
                let directionY = deltaY / distance
                let vector = CGVector(dx: directionX * force, dy: directionY * force)

                displacement[sourceIndex].dx -= vector.dx
                displacement[sourceIndex].dy -= vector.dy
                displacement[targetIndex].dx += vector.dx
                displacement[targetIndex].dy += vector.dy
            }

            for index in nodes.indices {
                let node = nodes[index]

                if node.id == pinnedNodeID {
                    positions[index] = .zero
                    velocities[index] = .zero
                    continue
                }

                let componentIndex = componentByNode[node.id] ?? 0
                let componentAnchor = componentAnchors[componentIndex] ?? .zero
                let anchorStrength: CGFloat = componentIndex == selectedComponentIndex ? 0.055 : 0.04
                displacement[index].dx += (componentAnchor.x - positions[index].x) * anchorStrength
                displacement[index].dy += (componentAnchor.y - positions[index].y) * anchorStrength

                // Keep isolated or weakly-connected components inside a circular field without boxing them in.
                displacement[index].dx += -positions[index].x * 0.012
                displacement[index].dy += -positions[index].y * 0.012

                velocities[index].dx = (velocities[index].dx + displacement[index].dx) * 0.84
                velocities[index].dy = (velocities[index].dy + displacement[index].dy) * 0.84

                let velocityMagnitude = max(0.001, hypot(velocities[index].dx, velocities[index].dy))
                let limitedDistance = min(temperature, velocityMagnitude)
                positions[index].x += (velocities[index].dx / velocityMagnitude) * limitedDistance
                positions[index].y += (velocities[index].dy / velocityMagnitude) * limitedDistance

                let radius = hypot(positions[index].x, positions[index].y)
                if radius > maxRadius {
                    let scale = maxRadius / radius
                    positions[index].x *= scale
                    positions[index].y *= scale
                }
            }

            temperature *= 0.989

            if capturesMotion,
               (iteration + 1).isMultiple(of: frameStride) || iteration == 219 {
                sampledPositions.append(positions)
            }
        }

        if !capturesMotion {
            sampledPositions = [positions]
        }

        return sampledPositions.map { sampledPosition in
            let normalizedPositions = normalized(
                sampledPosition,
                pinnedNodeID: pinnedNodeID,
                nodes: nodes
            )
            return NoteGraphLayout(
                positions: Dictionary(uniqueKeysWithValues: zip(nodes.map(\.id), normalizedPositions))
            )
        }
    }

    /// Cheaply re-centers an existing layout on a (possibly new) pinned node
    /// without re-running the O(n²) force simulation.
    ///
    /// Reuses the node positions already computed for `existing` and only re-pins
    /// the selected node to the origin and re-normalizes. Returns `nil` when the
    /// existing layout cannot cover the snapshot (caller should fall back to
    /// `generate`).
    static func recenter(_ existing: NoteGraphLayout, for snapshot: NoteGraphSnapshot) -> NoteGraphLayout? {
        guard !snapshot.nodes.isEmpty else {
            return .empty
        }

        let nodes = snapshot.nodes
        guard nodes.allSatisfy({ existing.positions[$0.id] != nil }) else {
            return nil
        }

        // Translate so the newly selected node becomes the origin. `normalized`
        // only forces the pinned node to (0, 0); without the translation the
        // previously pinned node (already at the origin) would land on top of it.
        let origin = snapshot.selectedNodeID.flatMap { existing.positions[$0] } ?? .zero
        let positions = nodes.map { node -> CGPoint in
            let point = existing.positions[node.id] ?? .zero
            return CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        }
        let normalizedPositions = normalized(
            positions,
            pinnedNodeID: snapshot.selectedNodeID,
            nodes: nodes
        )
        return NoteGraphLayout(
            positions: Dictionary(uniqueKeysWithValues: zip(nodes.map(\.id), normalizedPositions))
        )
    }

    private static func connectedComponents(
        for snapshot: NoteGraphSnapshot
    ) -> [[URL]] {
        let nodeIDs = snapshot.nodes.map(\.id)
        var adjacency: [URL: Set<URL>] = Dictionary(uniqueKeysWithValues: nodeIDs.map { ($0, []) })

        for edge in snapshot.edges {
            adjacency[edge.source, default: []].insert(edge.target)
            adjacency[edge.target, default: []].insert(edge.source)
        }

        var remaining = Set(nodeIDs)
        var components: [[URL]] = []

        while let start = remaining.first {
            var stack = [start]
            var component: [URL] = []
            remaining.remove(start)

            while let nodeID = stack.popLast() {
                component.append(nodeID)

                for neighbor in adjacency[nodeID, default: []] where remaining.contains(neighbor) {
                    remaining.remove(neighbor)
                    stack.append(neighbor)
                }
            }

            components.append(component)
        }

        return components.sorted { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.first?.path.localizedStandardCompare(rhs.first?.path ?? "") == .orderedAscending
        }
    }

    private static func makeComponentAnchors(
        for components: [[URL]],
        pinnedNodeID: URL?,
        relayoutSeed: Int
    ) -> [Int: CGPoint] {
        let selectedComponentIndex = pinnedNodeID.flatMap { pinnedNodeID in
            components.firstIndex(where: { $0.contains(pinnedNodeID) })
        }

        var anchors: [Int: CGPoint] = [:]
        if let selectedComponentIndex {
            anchors[selectedComponentIndex] = .zero
        }

        let otherComponentIndices = components.indices.filter { $0 != selectedComponentIndex }
        let goldenAngle = CGFloat.pi * (3 - sqrt(5))

        for (offset, componentIndex) in otherComponentIndices.enumerated() {
            let baseAngle = CGFloat(offset + 1) * goldenAngle
            let jitter = (random01(for: "component-\(componentIndex)", seed: relayoutSeed, salt: 1) - 0.5) * 0.75
            let angle = baseAngle + jitter
            let radius = 0.95 + CGFloat(offset / 6) * 0.55 + sqrt(CGFloat(max(components[componentIndex].count, 1))) * 0.09
            anchors[componentIndex] = CGPoint(
                x: cos(angle) * radius,
                y: sin(angle) * radius
            )
        }

        if anchors.isEmpty {
            anchors[0] = .zero
        }

        return anchors
    }

    private static func scatterLayout(
        for nodes: [NoteGraphNode],
        pinnedNodeID: URL?,
        relayoutSeed: Int
    ) -> NoteGraphLayout {
        var positions = nodes.map { node in
            if node.id == pinnedNodeID {
                return CGPoint.zero
            }

            let angle = random01(for: node.id.path, seed: relayoutSeed, salt: 1) * (.pi * 2)
            let radius = 0.32 + sqrt(random01(for: node.id.path, seed: relayoutSeed, salt: 2)) * 1.65
            return CGPoint(
                x: cos(angle) * radius,
                y: sin(angle) * radius
            )
        }
        var velocities = Array(repeating: CGVector.zero, count: nodes.count)
        var temperature: CGFloat = 0.075
        let maxRadius: CGFloat = 2.1
        let strategy = repulsionStrategy(forNodeCount: nodes.count)
        // The tree is only populated on the approximate path; keep the exact
        // path's allocation at its minimum.
        var quadtree = RepulsionQuadtree(bodyCount: strategy == .barnesHut ? nodes.count : 0)

        for _ in 0..<140 {
            var displacement = Array(repeating: CGVector.zero, count: nodes.count)

            switch strategy {
            case .exact:
                for firstIndex in nodes.indices {
                    for secondIndex in nodes.indices where secondIndex > firstIndex {
                        let deltaX = positions[firstIndex].x - positions[secondIndex].x
                        let deltaY = positions[firstIndex].y - positions[secondIndex].y
                        let distance = max(0.05, hypot(deltaX, deltaY))
                        let repulsion = 0.02 / (distance * distance)
                        let directionX = deltaX / distance
                        let directionY = deltaY / distance
                        let vector = CGVector(dx: directionX * repulsion, dy: directionY * repulsion)
                        displacement[firstIndex].dx += vector.dx
                        displacement[firstIndex].dy += vector.dy
                        displacement[secondIndex].dx -= vector.dx
                        displacement[secondIndex].dy -= vector.dy
                    }
                }

            case .barnesHut:
                quadtree.rebuild(with: positions)
                quadtree.accumulateRepulsion(
                    into: &displacement,
                    positions: positions,
                    strength: 0.02,
                    minimumDistance: 0.05,
                    theta: barnesHutTheta
                )
            }

            for index in nodes.indices {
                if nodes[index].id == pinnedNodeID {
                    positions[index] = .zero
                    velocities[index] = .zero
                    continue
                }

                displacement[index].dx += -positions[index].x * 0.016
                displacement[index].dy += -positions[index].y * 0.016

                velocities[index].dx = (velocities[index].dx + displacement[index].dx) * 0.82
                velocities[index].dy = (velocities[index].dy + displacement[index].dy) * 0.82

                let velocityMagnitude = max(0.001, hypot(velocities[index].dx, velocities[index].dy))
                let limitedDistance = min(temperature, velocityMagnitude)
                positions[index].x += (velocities[index].dx / velocityMagnitude) * limitedDistance
                positions[index].y += (velocities[index].dy / velocityMagnitude) * limitedDistance

                let radius = hypot(positions[index].x, positions[index].y)
                if radius > maxRadius {
                    let scale = maxRadius / radius
                    positions[index].x *= scale
                    positions[index].y *= scale
                }
            }

            temperature *= 0.988
        }

        let normalizedPositions = normalized(
            positions,
            pinnedNodeID: pinnedNodeID,
            nodes: nodes
        )
        return NoteGraphLayout(
            positions: Dictionary(uniqueKeysWithValues: zip(nodes.map(\.id), normalizedPositions))
        )
    }

    private static func initialPositions(
        for nodes: [NoteGraphNode],
        pinnedNodeID: URL?,
        componentByNode: [URL: Int],
        componentAnchors: [Int: CGPoint],
        components: [[URL]],
        relayoutSeed: Int
    ) -> [CGPoint] {
        nodes.map { node in
            if node.id == pinnedNodeID {
                return .zero
            }

            let componentIndex = componentByNode[node.id] ?? 0
            let componentAnchor = componentAnchors[componentIndex] ?? .zero
            let clusterRadius = 0.18 + sqrt(CGFloat(max(components[componentIndex].count, 1))) * 0.055
            let angle = random01(for: node.id.path, seed: relayoutSeed, salt: 3) * (.pi * 2)
            let radius = sqrt(random01(for: node.id.path, seed: relayoutSeed, salt: 4)) * clusterRadius
            return CGPoint(
                x: componentAnchor.x + cos(angle) * radius,
                y: componentAnchor.y + sin(angle) * radius
            )
        }
    }

    private static func normalized(
        _ positions: [CGPoint],
        pinnedNodeID: URL?,
        nodes: [NoteGraphNode]
    ) -> [CGPoint] {
        if let pinnedNodeID {
            let adjusted = positions.enumerated().map { index, point in
                nodes[index].id == pinnedNodeID ? CGPoint.zero : point
            }
            let maxRadius = adjusted
                .enumerated()
                .filter { nodes[$0.offset].id != pinnedNodeID }
                .map { hypot($0.element.x, $0.element.y) }
                .max() ?? 1
            let scale = 1.68 / max(maxRadius, 0.01)

            return adjusted.enumerated().map { index, point in
                nodes[index].id == pinnedNodeID
                    ? .zero
                    : CGPoint(x: point.x * scale, y: point.y * scale)
            }
        }

        let centroid = CGPoint(
            x: positions.map(\.x).reduce(0, +) / CGFloat(max(positions.count, 1)),
            y: positions.map(\.y).reduce(0, +) / CGFloat(max(positions.count, 1))
        )
        let recentered = positions.map {
            CGPoint(x: $0.x - centroid.x, y: $0.y - centroid.y)
        }
        let maxRadius = recentered.map { hypot($0.x, $0.y) }.max() ?? 1
        let scale = 1.68 / max(maxRadius, 0.01)

        return recentered.map { point in
            CGPoint(x: point.x * scale, y: point.y * scale)
        }
    }

    private static func random01(for key: String, seed: Int, salt: Int) -> CGFloat {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(key)#\(seed)#\(salt)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        let normalized = Double(hash % 10_000) / 10_000
        return CGFloat(normalized)
    }
}

/// Barnes-Hut quadtree used to approximate n-body repulsion in O(n log n).
///
/// Cells live in one flat array; an internal cell's four children are stored
/// contiguously starting at `firstChild`. The tree is rebuilt from scratch each
/// simulation step (reusing the array storage). Bodies are inserted in index
/// order and children are visited in a fixed order, so for a given set of
/// positions the tree, the traversal and therefore the accumulated forces are
/// fully deterministic — no randomness or hashing order is involved.
private struct RepulsionQuadtree {
    private struct Cell {
        var centerX: CGFloat
        var centerY: CGFloat
        var halfSize: CGFloat
        /// Number of bodies in this cell's subtree.
        var mass: CGFloat = 0
        /// Sum of the positions of the bodies in this subtree (centre of mass × mass).
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        /// Index of the first of four contiguous child cells, or -1 for a leaf.
        var firstChild: Int = -1
        /// Body stored in this leaf, or -1 when the leaf is empty.
        var body: Int = -1
    }

    /// Subdivision stops at this depth; bodies that still share a cell there are
    /// treated as coincident and kept together in a single multi-body leaf.
    private static let maximumDepth = 32

    private var cells: [Cell] = []
    private var traversalStack: [Int] = []

    init(bodyCount: Int) {
        cells.reserveCapacity(max(bodyCount * 2, 16))
        traversalStack.reserveCapacity(64)
    }

    mutating func rebuild(with positions: [CGPoint]) {
        cells.removeAll(keepingCapacity: true)
        guard let first = positions.first else { return }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in positions.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        // Pad the root slightly so bodies on the bounding box are strictly inside.
        let halfSize = max(maxX - minX, maxY - minY) / 2 + 0.001
        cells.append(Cell(
            centerX: (minX + maxX) / 2,
            centerY: (minY + maxY) / 2,
            halfSize: halfSize
        ))

        for (body, point) in positions.enumerated() {
            insert(body: body, at: point, positions: positions)
        }
    }

    /// Adds the repulsion every other body exerts on each body to `displacement`.
    ///
    /// Matches the exact path's force law: `strength / distance²` along the
    /// separation vector, with the distance clamped to `minimumDistance`.
    mutating func accumulateRepulsion(
        into displacement: inout [CGVector],
        positions: [CGPoint],
        strength: CGFloat,
        minimumDistance: CGFloat,
        theta: CGFloat
    ) {
        guard !cells.isEmpty else { return }

        for body in positions.indices {
            let point = positions[body]
            var forceX: CGFloat = 0
            var forceY: CGFloat = 0

            traversalStack.removeAll(keepingCapacity: true)
            traversalStack.append(0)

            while let cellIndex = traversalStack.popLast() {
                let cell = cells[cellIndex]
                guard cell.mass > 0 else { continue }

                let isLeaf = cell.firstChild < 0
                if isLeaf, cell.mass == 1, cell.body == body {
                    // A body does not repel itself.
                    continue
                }

                let centerOfMassX = cell.sumX / cell.mass
                let centerOfMassY = cell.sumY / cell.mass
                let deltaX = point.x - centerOfMassX
                let deltaY = point.y - centerOfMassY
                let distance = max(minimumDistance, hypot(deltaX, deltaY))

                if !isLeaf, (cell.halfSize * 2) / distance >= theta {
                    // Too close to approximate: descend. Push in reverse so the
                    // children pop in index order, keeping floating-point
                    // accumulation order stable between runs.
                    var offset = 3
                    while offset >= 0 {
                        traversalStack.append(cell.firstChild + offset)
                        offset -= 1
                    }
                    continue
                }

                // Either a distant cell treated as one point mass, or a leaf
                // holding another body (or coincident bodies, whose combined
                // centre of mass sits on top of `point` and contributes ~0).
                let repulsion = strength * cell.mass / (distance * distance)
                forceX += (deltaX / distance) * repulsion
                forceY += (deltaY / distance) * repulsion
            }

            displacement[body].dx += forceX
            displacement[body].dy += forceY
        }
    }

    private mutating func insert(body: Int, at point: CGPoint, positions: [CGPoint]) {
        var cellIndex = 0
        var depth = 0

        while true {
            cells[cellIndex].mass += 1
            cells[cellIndex].sumX += point.x
            cells[cellIndex].sumY += point.y

            let firstChild = cells[cellIndex].firstChild
            if firstChild >= 0 {
                cellIndex = firstChild + quadrant(of: point, in: cells[cellIndex])
                depth += 1
                continue
            }

            if cells[cellIndex].body < 0 {
                // Empty leaf: claim it.
                cells[cellIndex].body = body
                return
            }

            if depth >= Self.maximumDepth {
                // Coincident bodies share this leaf. Only the first is recorded
                // in `body`; the aggregate mass and centre of mass cover the rest.
                return
            }

            // Occupied leaf: subdivide and push the existing body down one level,
            // then keep descending with the new body.
            let existing = cells[cellIndex].body
            let existingPoint = positions[existing]
            cells[cellIndex].body = -1
            cells[cellIndex].firstChild = cells.count
            appendChildren(of: cellIndex)

            let existingChild = cells[cellIndex].firstChild + quadrant(of: existingPoint, in: cells[cellIndex])
            cells[existingChild].mass = 1
            cells[existingChild].sumX = existingPoint.x
            cells[existingChild].sumY = existingPoint.y
            cells[existingChild].body = existing

            cellIndex = cells[cellIndex].firstChild + quadrant(of: point, in: cells[cellIndex])
            depth += 1
        }
    }

    private mutating func appendChildren(of cellIndex: Int) {
        let parent = cells[cellIndex]
        let childHalfSize = parent.halfSize / 2

        for quadrant in 0..<4 {
            let offsetX = (quadrant & 1) == 0 ? -childHalfSize : childHalfSize
            let offsetY = (quadrant & 2) == 0 ? -childHalfSize : childHalfSize
            cells.append(Cell(
                centerX: parent.centerX + offsetX,
                centerY: parent.centerY + offsetY,
                halfSize: childHalfSize
            ))
        }
    }

    /// Quadrant index of `point` within `cell`: bit 0 is east, bit 1 is south.
    private func quadrant(of point: CGPoint, in cell: Cell) -> Int {
        (point.x >= cell.centerX ? 1 : 0) + (point.y >= cell.centerY ? 2 : 0)
    }
}

private let markdownNoteExtensionsInPriorityOrder = ["md", "markdown", "mdown"]
private let markdownNoteExtensions: Set<String> = Set(markdownNoteExtensionsInPriorityOrder)

/// Schemes that always point outside the vault and should never trigger note resolution.
private let externalLinkSchemes: Set<String> = [
    "http", "https", "mailto", "tel", "ftp", "ftps", "sms", "data", "javascript"
]

private extension String {
    func trimmingLeadingWhitespace() -> String {
        let trimmedScalars = unicodeScalars.drop(while: { CharacterSet.whitespaces.contains($0) })
        return String(String.UnicodeScalarView(trimmedScalars))
    }
}

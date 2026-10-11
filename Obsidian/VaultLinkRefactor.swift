import Foundation

struct VaultLinkNoteSnapshot: Sendable {
    let url: URL
    let body: String
    let aliases: [String]
}

struct VaultLinkRefactorEdit: Sendable {
    let originalURL: URL
    let destinationURL: URL
    let originalBody: String
    let updatedBody: String
}

enum VaultLinkRefactor {
    static func edits(
        notes: [VaultLinkNoteSnapshot],
        moving oldRoot: URL,
        to newRoot: URL,
        sourceIsDirectory: Bool,
        vaultURL: URL,
        assetURLs: Set<URL> = []
    ) -> [VaultLinkRefactorEdit] {
        let standardizedNotes = notes.map {
            VaultLinkNoteSnapshot(url: $0.url.standardizedFileURL, body: $0.body, aliases: $0.aliases)
        }
        let noteURLs = Set(standardizedNotes.map(\.url))
        let resolvableURLs = noteURLs.union(assetURLs.map { $0.standardizedFileURL })
        var nameLookup: [String: Set<URL>] = [:]
        for note in standardizedNotes {
            let names = [note.url.deletingPathExtension().lastPathComponent] + note.aliases
            for name in names {
                nameLookup[name.lowercased(), default: []].insert(note.url)
            }
        }

        return standardizedNotes.compactMap { note in
            let destinationURL = mappedURL(
                note.url,
                oldRoot: oldRoot,
                newRoot: newRoot,
                sourceIsDirectory: sourceIsDirectory
            ) ?? note.url
            // Mask fenced and inline code once per note. Both scans search the
            // masked text and read their targets back from the original body,
            // so every replacement range refers to `note.body`.
            let searchable = MarkdownNoteLinkExtractor.maskingCodeRegions(note.body)
            let wikiReplacements = wikiLinkReplacements(
                in: note.body,
                searchable: searchable,
                sourceURL: note.url,
                resolvableURLs: resolvableURLs,
                nameLookup: nameLookup,
                oldRoot: oldRoot,
                newRoot: newRoot,
                sourceIsDirectory: sourceIsDirectory,
                vaultURL: vaultURL
            )
            // The wiki pass used to run first and the Markdown pass on its
            // output, so an overlapping range is resolved in the wiki pass's favor.
            let markdownReplacements = markdownLinkReplacements(
                in: note.body,
                searchable: searchable,
                sourceURL: note.url,
                destinationSourceURL: destinationURL,
                oldRoot: oldRoot,
                newRoot: newRoot,
                sourceIsDirectory: sourceIsDirectory
            ).filter { candidate in
                !wikiReplacements.contains { NSIntersectionRange($0.0, candidate.0).length > 0 }
            }
            let fullyUpdated = replacing(note.body, replacements: wikiReplacements + markdownReplacements)

            guard fullyUpdated != note.body else { return nil }
            return VaultLinkRefactorEdit(
                originalURL: note.url,
                destinationURL: destinationURL,
                originalBody: note.body,
                updatedBody: fullyUpdated
            )
        }
    }

    static func apply(
        _ edits: [VaultLinkRefactorEdit],
        afterApplying: ((VaultLinkRefactorEdit) -> Void)? = nil
    ) throws {
        var applied: [VaultLinkRefactorEdit] = []
        do {
            for edit in edits {
                guard try replaceIfCurrent(
                    at: edit.destinationURL,
                    expected: edit.originalBody,
                    replacement: edit.updatedBody
                ) else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [
                        NSFilePathErrorKey: edit.destinationURL.path,
                        NSLocalizedDescriptionKey: "A note changed while links were being updated."
                    ])
                }
                applied.append(edit)
                afterApplying?(edit)
            }
        } catch {
            for edit in applied.reversed() {
                // Never let rollback clobber a newer external edit. Restore the
                // original only while our own updated body is still current.
                _ = try? replaceIfCurrent(
                    at: edit.destinationURL,
                    expected: edit.updatedBody,
                    replacement: edit.originalBody
                )
            }
            throw error
        }
    }

    static func mappedURL(
        _ url: URL,
        oldRoot: URL,
        newRoot: URL,
        sourceIsDirectory: Bool
    ) -> URL? {
        let source = url.standardizedFileURL
        let old = oldRoot.standardizedFileURL
        let new = newRoot.standardizedFileURL
        if source == old { return new }
        guard sourceIsDirectory, source.path.hasPrefix(old.path + "/") else { return nil }
        let suffix = String(source.path.dropFirst(old.path.count + 1))
        return new.appendingPathComponent(suffix).standardizedFileURL
    }

    /// Conditional replacement under one file-coordination accessor. This
    /// closes the read/write race for normal iCloud and document-provider
    /// writers, and gives rollback the same version guard.
    static func replaceIfCurrent(
        at url: URL,
        expected: String,
        replacement: String
    ) throws -> Bool {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var accessorResult: Result<Bool, Error>?

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            accessorResult = Result {
                let onDisk = try String(contentsOf: coordinatedURL, encoding: .utf8)
                guard onDisk == expected else { return false }
                try Data(replacement.utf8).write(to: coordinatedURL, options: .atomic)
                return true
            }
        }

        if let coordinationError { throw coordinationError }
        guard let accessorResult else { throw CocoaError(.fileWriteUnknown) }
        return try accessorResult.get()
    }

    private static let wikiLinkRegex = try! NSRegularExpression(pattern: #"!?\[\[([^\]|#]+)"#)
    private static let markdownLinkRegex = try! NSRegularExpression(
        pattern: #"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)"#
    )

    /// Replacement ranges for wiki links in `body`. `searchable` is the
    /// code-masked copy of `body`, so its match ranges index `body` directly.
    private static func wikiLinkReplacements(
        in body: String,
        searchable: String,
        sourceURL: URL,
        resolvableURLs: Set<URL>,
        nameLookup: [String: Set<URL>],
        oldRoot: URL,
        newRoot: URL,
        sourceIsDirectory: Bool,
        vaultURL: URL
    ) -> [(NSRange, String)] {
        let nsBody = body as NSString
        let searchRange = NSRange(location: 0, length: (searchable as NSString).length)
        var replacements: [(NSRange, String)] = []

        for match in wikiLinkRegex.matches(in: searchable, range: searchRange) {
            let range = match.range(at: 1)
            let target = nsBody.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let resolved = resolveWikiTarget(
                target,
                sourceURL: sourceURL,
                resolvableURLs: resolvableURLs,
                nameLookup: nameLookup,
                vaultURL: vaultURL
            ), let mapped = mappedURL(
                resolved,
                oldRoot: oldRoot,
                newRoot: newRoot,
                sourceIsDirectory: sourceIsDirectory
            ) else { continue }

            let replacement: String
            if target.contains("/") || !(target as NSString).pathExtension.isEmpty {
                replacement = vaultRelativePath(mapped, vaultURL: vaultURL, droppingMarkdownExtension: (target as NSString).pathExtension.isEmpty)
            } else {
                replacement = mapped.deletingPathExtension().lastPathComponent
            }
            replacements.append((range, replacement))
        }

        return replacements
    }

    /// Replacement ranges for Markdown link targets in `body`, indexed the
    /// same way as `wikiLinkReplacements`.
    private static func markdownLinkReplacements(
        in body: String,
        searchable: String,
        sourceURL: URL,
        destinationSourceURL: URL,
        oldRoot: URL,
        newRoot: URL,
        sourceIsDirectory: Bool
    ) -> [(NSRange, String)] {
        let nsBody = body as NSString
        let searchRange = NSRange(location: 0, length: (searchable as NSString).length)
        var replacements: [(NSRange, String)] = []

        for match in markdownLinkRegex.matches(in: searchable, range: searchRange) {
            let range = match.range(at: 1)
            let rawTarget = nsBody.substring(with: range)
            guard URL(string: rawTarget)?.scheme == nil else { continue }
            let decoded = rawTarget.removingPercentEncoding ?? rawTarget
            let resolved = sourceURL.deletingLastPathComponent()
                .appendingPathComponent(decoded)
                .standardizedFileURL
            guard let mapped = mappedURL(
                resolved,
                oldRoot: oldRoot,
                newRoot: newRoot,
                sourceIsDirectory: sourceIsDirectory
            ) else { continue }

            let relative = relativePath(from: destinationSourceURL.deletingLastPathComponent(), to: mapped)
            replacements.append((range, relative.replacingOccurrences(of: " ", with: "%20")))
        }
        return replacements
    }

    private static func resolveWikiTarget(
        _ target: String,
        sourceURL: URL,
        resolvableURLs: Set<URL>,
        nameLookup: [String: Set<URL>],
        vaultURL: URL
    ) -> URL? {
        if !target.contains("/"), (target as NSString).pathExtension.isEmpty,
           let named = nameLookup[target.lowercased()], named.count == 1 {
            return named.first
        }

        let candidates = [
            sourceURL.deletingLastPathComponent().appendingPathComponent(target),
            vaultURL.appendingPathComponent(target),
        ].flatMap { candidate -> [URL] in
            if candidate.pathExtension.isEmpty {
                return [candidate.appendingPathExtension("md"), candidate]
            }
            return [candidate]
        }.map { $0.standardizedFileURL }
        return candidates.first { resolvableURLs.contains($0) }
    }

    private static func vaultRelativePath(
        _ url: URL,
        vaultURL: URL,
        droppingMarkdownExtension: Bool
    ) -> String {
        let prefix = vaultURL.standardizedFileURL.path + "/"
        var path = url.standardizedFileURL.path.hasPrefix(prefix)
            ? String(url.standardizedFileURL.path.dropFirst(prefix.count))
            : url.lastPathComponent
        if droppingMarkdownExtension, ["md", "markdown", "mdown"].contains((path as NSString).pathExtension.lowercased()) {
            path = (path as NSString).deletingPathExtension
        }
        return path
    }

    private static func relativePath(from directory: URL, to target: URL) -> String {
        let from = directory.standardizedFileURL.pathComponents
        let to = target.standardizedFileURL.pathComponents
        var shared = 0
        while shared < min(from.count, to.count), from[shared] == to[shared] {
            shared += 1
        }
        let upwards = Array(repeating: "..", count: from.count - shared)
        let downwards = Array(to.dropFirst(shared))
        return (upwards + downwards).joined(separator: "/")
    }

    private static func replacing(_ source: String, replacements: [(NSRange, String)]) -> String {
        let mutable = NSMutableString(string: source)
        for (range, replacement) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            mutable.replaceCharacters(in: range, with: replacement)
        }
        return mutable as String
    }
}

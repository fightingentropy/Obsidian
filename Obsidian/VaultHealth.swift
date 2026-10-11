import Foundation

enum VaultHealthSeverity: Int, Comparable, Sendable {
    case info
    case warning
    case error

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct VaultHealthIssue: Identifiable, Sendable {
    let severity: VaultHealthSeverity
    let title: String
    let detail: String
    let fileURL: URL?

    var id: String {
        "\(severity.rawValue):\(fileURL?.path ?? "vault"):\(title):\(detail)"
    }
}

struct VaultHealthNote: Sendable {
    let url: URL
    let title: String
    let body: String
}

struct VaultHealthReport: Sendable {
    let issues: [VaultHealthIssue]
    let noteCount: Int
    let attachmentCount: Int
    let recoveryDraftCount: Int

    var errorCount: Int { issues.filter { $0.severity == .error }.count }
    var warningCount: Int { issues.filter { $0.severity == .warning }.count }
}

enum VaultHealthScanner {
    static func scan(vaultURL: URL, notes: [VaultHealthNote]) -> VaultHealthReport {
        let fileManager = FileManager.default
        let metadata = Dictionary(uniqueKeysWithValues: notes.map {
            ($0.url.standardizedFileURL, ObsidianMetadataParser.parse($0.body))
        })
        var targetLookup: [String: Set<URL>] = [:]
        for note in notes {
            let parsed = metadata[note.url.standardizedFileURL]
            let names = [note.url.deletingPathExtension().lastPathComponent, note.title, parsed?.title]
                .compactMap { $0 } + (parsed?.aliases ?? [])
            // A note's stem, title, and frontmatter title usually coincide, so
            // de-duplicate per note before counting how many notes share a name.
            for name in Set(names.map { $0.lowercased() }) {
                targetLookup[name, default: []].insert(note.url)
            }
        }

        var issues: [VaultHealthIssue] = []
        for (name, urls) in targetLookup.sorted(by: { $0.key < $1.key }) where urls.count > 1 {
            issues.append(VaultHealthIssue(
                severity: .warning,
                title: "Duplicate note target",
                detail: "“\(name)” resolves to \(urls.count) notes.",
                fileURL: urls.sorted { $0.path < $1.path }.first
            ))
        }

        for note in notes {
            if hasUnterminatedFrontmatter(note.body) {
                issues.append(VaultHealthIssue(
                    severity: .warning,
                    title: "Unterminated frontmatter",
                    detail: "The opening YAML delimiter has no closing delimiter, so the block is treated as ordinary Markdown.",
                    fileURL: note.url
                ))
            }

            // Links inside fenced or inline code are examples, not references.
            let searchable = MarkdownNoteLinkExtractor.maskingCodeRegions(note.body)

            for target in wikiTargets(in: searchable) {
                let cleanTarget = target
                    .split(separator: "#", maxSplits: 1).first.map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !cleanTarget.isEmpty else { continue }

                if cleanTarget.contains("/") || !(cleanTarget as NSString).pathExtension.isEmpty {
                    if resolveLocalReference(cleanTarget, from: note.url, vaultURL: vaultURL, fileManager: fileManager) == nil,
                       targetLookup[(cleanTarget as NSString).deletingPathExtension.lowercased()] == nil {
                        issues.append(missingIssue(target: cleanTarget, note: note))
                    }
                } else if targetLookup[cleanTarget.lowercased()] == nil {
                    issues.append(missingIssue(target: cleanTarget, note: note))
                }
            }

            for target in markdownImageTargets(in: searchable) where !isRemoteReference(target) {
                if resolveLocalReference(target, from: note.url, vaultURL: vaultURL, fileManager: fileManager) == nil {
                    issues.append(missingIssue(target: target, note: note))
                }
            }
        }

        let attachmentCount = countAttachments(in: vaultURL, fileManager: fileManager)
        let recoveryDraftCount = countRecoveryDrafts(for: vaultURL)
        if recoveryDraftCount > 0 {
            issues.append(VaultHealthIssue(
                severity: .info,
                title: "Recovery drafts available",
                detail: "\(recoveryDraftCount) crash-recovery draft(s) belong to this vault.",
                fileURL: nil
            ))
        }

        return VaultHealthReport(
            issues: issues.sorted { $0.severity > $1.severity },
            noteCount: notes.count,
            attachmentCount: attachmentCount,
            recoveryDraftCount: recoveryDraftCount
        )
    }

    private static func missingIssue(target: String, note: VaultHealthNote) -> VaultHealthIssue {
        VaultHealthIssue(
            severity: .error,
            title: "Missing link or attachment",
            detail: "\(target) referenced by \(note.title)",
            fileURL: note.url
        )
    }

    private static let wikiTargetRegex = try! NSRegularExpression(pattern: #"!?\[\[([^\]|]+)"#)
    private static let markdownImageRegex = try! NSRegularExpression(
        pattern: #"!\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)"#
    )

    private static func wikiTargets(in body: String) -> [String] {
        regexCaptures(wikiTargetRegex, in: body)
    }

    private static func markdownImageTargets(in body: String) -> [String] {
        regexCaptures(markdownImageRegex, in: body)
    }

    private static func regexCaptures(_ regex: NSRegularExpression, in text: String) -> [String] {
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap {
            guard $0.numberOfRanges > 1, $0.range(at: 1).location != NSNotFound else { return nil }
            return nsText.substring(with: $0.range(at: 1))
        }
    }

    /// Mirrors `ObsidianMetadataParser`: the opening delimiter must be exactly
    /// `---` on the first line (after an optional BOM) and a block without a
    /// closing delimiter is ordinary Markdown. The scanner only flags the case
    /// that looks like a property block the author forgot to close, i.e. the
    /// first meaningful line (blank and `#` comment lines skipped) is a
    /// top-level `key: value` line by the parser's own rules, so keys with
    /// spaces, non-ASCII letters, or quotes are recognized too.
    private static func hasUnterminatedFrontmatter(_ body: String) -> Bool {
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard var first = lines.first else { return false }
        if first.first == "\u{feff}" { first.removeFirst() }
        guard first == "---", lines.count > 1 else { return false }
        guard !lines.dropFirst().contains(where: { $0 == "---" || $0 == "..." }) else { return false }

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            return isTopLevelKeyLine(line)
        }
        return false
    }

    /// Same acceptance rule as the metadata parser's top-level key detection:
    /// not indented, not a block-sequence item, and a non-empty key before the
    /// first colon that is not inside quotes.
    private static func isTopLevelKeyLine(_ line: String) -> Bool {
        guard line.first?.isWhitespace != true else { return false }
        if line == "-" || line.hasPrefix("- ") { return false }

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
                return !line[..<index].trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
        return false
    }

    private static func resolveLocalReference(
        _ reference: String,
        from noteURL: URL,
        vaultURL: URL,
        fileManager: FileManager
    ) -> URL? {
        let decoded = reference.removingPercentEncoding ?? reference
        let candidates = [
            noteURL.deletingLastPathComponent().appendingPathComponent(decoded),
            vaultURL.appendingPathComponent(decoded),
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.standardizedFileURL.path) }
    }

    private static func isRemoteReference(_ reference: String) -> Bool {
        guard let scheme = URL(string: reference)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "data"
    }

    private static func countAttachments(in vaultURL: URL, fileManager: FileManager) -> Int {
        guard let enumerator = fileManager.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]
        return enumerator.compactMap { $0 as? URL }.filter {
            !markdownExtensions.contains($0.pathExtension.lowercased())
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.count
    }

    private static func countRecoveryDrafts(for vaultURL: URL) -> Int {
        let directory = RecoveryStore().directoryURL
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return 0 }
        let prefix = vaultURL.standardizedFileURL.path + "/"
        return urls.compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(RecoveryDraft.self, from: $0) }
            .filter { $0.sourcePath.hasPrefix(prefix) }
            .count
    }
}

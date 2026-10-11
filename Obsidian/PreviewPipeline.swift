import AppKit
import Down
import Foundation
import ImageIO
import libcmark
import SwiftUI
import Textual

struct PreviewContext: Equatable {
    let documentURL: URL?
    let vaultURL: URL?
    var assetLookupByFilename: [String: [URL]] = [:]

    var documentDirectoryURL: URL? {
        documentURL?.deletingLastPathComponent()
    }

    var previewBaseURL: URL? {
        documentDirectoryURL ?? vaultURL
    }

    /// Cheap, order-independent fingerprint of `assetLookupByFilename`.
    ///
    /// Every entry is hashed on its own and the per-entry digests are XORed
    /// together, so the result does not depend on dictionary iteration order
    /// and nothing is sorted or copied. Values are included (not just keys) so
    /// a note that moves between folders without changing its filename still
    /// changes the fingerprint. `Hasher` is seeded per process, which is fine
    /// for the in-memory caches this feeds.
    var assetLookupFingerprint: Int {
        var combined = 0
        for (filename, urls) in assetLookupByFilename {
            var entryHasher = Hasher()
            entryHasher.combine(filename)
            entryHasher.combine(urls.count)
            for url in urls {
                entryHasher.combine(url)
            }
            combined ^= entryHasher.finalize()
        }

        var hasher = Hasher()
        hasher.combine(assetLookupByFilename.count)
        hasher.combine(combined)
        return hasher.finalize()
    }
}

struct ResolvedAsset: Equatable {
    enum Kind: Equatable {
        case image
        case file
    }

    let fileURL: URL
    let kind: Kind
    let mimeType: String

    var isImage: Bool {
        kind == .image
    }
}

enum PreviewSegment {
    case markdown(String)
    case embed(EditorLinkPreview)
    case mermaid(source: String, diagram: MermaidDiagram?)
}

enum PreviewRenderMode {
    case embedded
    case native
    case html
}

struct PreviewDocument {
    let source: String
    let context: PreviewContext
    let segments: [PreviewSegment]
    let requiresHTMLFallback: Bool

    var containsMermaid: Bool {
        segments.contains { segment in
            if case .mermaid = segment {
                return true
            }

            return false
        }
    }

    var preferredRenderMode: PreviewRenderMode {
        if segments.contains(where: { if case .embed = $0 { return true }; return false }) {
            return .embedded
        }
        if requiresHTMLFallback || containsMermaid {
            return .html
        }

        return .native
    }

    var normalizedMarkdown: String {
        segments.compactMap { segment in
            if case .markdown(let markdown) = segment {
                return markdown
            }

            return nil
        }
        .joined(separator: "\n")
    }

    /// The segments paired with identities that survive both edits inside a
    /// segment and insertions above it.
    ///
    /// Embeds are keyed by their `EditorLinkPreview` id (plus an ordinal for
    /// repeats of the same embed). Markdown and mermaid segments are keyed
    /// structurally, never by content: by the embed that precedes them (or the
    /// document start) and by their ordinal among segments of the same kind
    /// since that anchor, e.g. `after:embed:abc#0/markdown#1`. Typing inside a
    /// segment therefore keeps its id, so SwiftUI updates the existing view
    /// (and its `WKWebView` and measured height) in place instead of tearing it
    /// down on every keystroke, while inserting a paragraph above an embed does
    /// not re-target the embed cards or the segments below them.
    var identifiedSegments: [IdentifiedPreviewSegment] {
        var embedOccurrences: [String: Int] = [:]
        var anchor = "start"
        var ordinalsSinceAnchor: [String: Int] = [:]
        var identified: [IdentifiedPreviewSegment] = []
        identified.reserveCapacity(segments.count)

        for segment in segments {
            let id: String
            switch segment {
            case .embed(let preview):
                let base = "embed:\(preview.id)"
                let ordinal = embedOccurrences[base, default: 0]
                embedOccurrences[base] = ordinal + 1
                id = "\(base)#\(ordinal)"
                anchor = id
                ordinalsSinceAnchor.removeAll(keepingCapacity: true)
            case .markdown:
                id = Self.structuralIdentity(kind: "markdown", anchor: anchor, ordinals: &ordinalsSinceAnchor)
            case .mermaid:
                id = Self.structuralIdentity(kind: "mermaid", anchor: anchor, ordinals: &ordinalsSinceAnchor)
            }
            identified.append(IdentifiedPreviewSegment(id: id, segment: segment))
        }

        return identified
    }

    private static func structuralIdentity(
        kind: String,
        anchor: String,
        ordinals: inout [String: Int]
    ) -> String {
        let ordinal = ordinals[kind, default: 0]
        ordinals[kind] = ordinal + 1
        return "after:\(anchor)/\(kind)#\(ordinal)"
    }
}

struct IdentifiedPreviewSegment: Identifiable {
    let id: String
    let segment: PreviewSegment
}

enum PreviewPipelineError: Error {
    case unresolvedImageReference(String)
    case invalidImageData(URL)
    case invalidRemoteImageResponse(URL)
    case remoteImageTooLarge(URL)
}

struct AssetResolver {
    private enum Constants {
        static let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "svg", "tiff", "bmp",
        ]
    }

    let context: PreviewContext

    func resolve(reference: String) -> ResolvedAsset? {
        guard let fileURL = resolveFileURL(reference: reference) else {
            return nil
        }

        return ResolvedAsset(
            fileURL: fileURL,
            kind: isImageFile(fileURL) ? .image : .file,
            mimeType: mimeType(for: fileURL.pathExtension)
        )
    }

    func resolveImage(reference: String) -> ResolvedAsset? {
        guard let asset = resolve(reference: reference), asset.isImage else {
            return nil
        }

        return asset
    }

    func resolveImageURL(for markupURL: URL) -> URL? {
        if markupURL.isFileURL {
            let standardized = markupURL.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path), isImageFile(standardized) else {
                return nil
            }

            return standardized
        }

        if let scheme = markupURL.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return markupURL
        }

        return resolveImage(reference: markupURL.absoluteString)?.fileURL
    }

    func resolveInlineImageFileURL(forLine line: String) -> URL? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let reference = PreviewMarkdownSyntax.standaloneObsidianImageReference(in: trimmed) {
            return resolveImage(reference: reference.target)?.fileURL
        }

        if let image = PreviewMarkdownSyntax.parseStandaloneMarkdownImage(in: trimmed) {
            return resolveImage(reference: image.destination)?.fileURL
        }

        return nil
    }

    private func resolveFileURL(reference: String) -> URL? {
        let normalized = normalizeReference(reference)
        guard !normalized.isEmpty else {
            return nil
        }

        if let fileSchemeURL = fileURL(from: normalized) {
            return containedAssetURL(fileSchemeURL.standardizedFileURL)
        }

        if normalized.hasPrefix("/") {
            return containedAssetURL(URL(fileURLWithPath: normalized).standardizedFileURL)
        }

        let baseCandidates = [context.documentDirectoryURL, context.vaultURL]
        for baseURL in baseCandidates.compactMap({ $0 }) {
            let candidate = URL(fileURLWithPath: normalized, relativeTo: baseURL).standardizedFileURL
            if let contained = containedAssetURL(candidate) {
                return contained
            }
        }

        // The asset index (`assetLookupByFilename`) already lists every regular
        // file in the vault, so a bare filename that is not in it does not
        // exist; there is no need to walk the vault on disk here.
        if let indexedMatches = context.assetLookupByFilename[normalized], !indexedMatches.isEmpty {
            let match = indexedMatches.count == 1 ? indexedMatches[0] : indexedMatches.first
            return match.flatMap(containedAssetURL)
        }

        return nil
    }

    private func containedAssetURL(_ url: URL) -> URL? {
        if let vaultURL = context.vaultURL {
            return PreviewURLPolicy.fileInsideVault(url, vaultURL: vaultURL)
        }

        guard let documentDirectoryURL = context.documentDirectoryURL else {
            return nil
        }
        let resolvedDirectory = documentDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let isInside = resolvedURL.path == resolvedDirectory.path
            || resolvedURL.path.hasPrefix(resolvedDirectory.path + "/")
        guard isInside, FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return nil
        }
        return resolvedURL
    }

    private func fileURL(from reference: String) -> URL? {
        guard let url = URL(string: reference), url.scheme?.lowercased() == "file" else {
            return nil
        }

        return url
    }

    private func normalizeReference(_ reference: String) -> String {
        var trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }

        return trimmed
    }

    private func isImageFile(_ url: URL) -> Bool {
        Constants.imageExtensions.contains(url.pathExtension.lowercased())
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "heic":
            return "image/heic"
        case "heif":
            return "image/heif"
        case "svg":
            return "image/svg+xml"
        case "tiff":
            return "image/tiff"
        case "bmp":
            return "image/bmp"
        case "pdf":
            return "application/pdf"
        default:
            return "application/octet-stream"
        }
    }
}

/// Encodes LaTeX source into an ASCII-only placeholder token that survives
/// cmark and our HTML-escape pass unchanged. The token is replaced with a
/// KaTeX-targeted `<span>` in post-processing.
enum MathTokenCoder {
    static let inlinePrefix = "MATHXINLINESTART"
    static let inlineSuffix = "MATHXINLINEEND"
    static let displayPrefix = "MATHXDISPLAYSTART"
    static let displaySuffix = "MATHXDISPLAYEND"

    static func encode(_ latex: String, display: Bool) -> String {
        let hex = Data(latex.utf8).map { String(format: "%02x", $0) }.joined()
        return display
            ? displayPrefix + hex + displaySuffix
            : inlinePrefix + hex + inlineSuffix
    }

    static func decode(hex: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var iter = hex.unicodeScalars.makeIterator()
        while let first = iter.next(), let second = iter.next() {
            guard let byte = UInt8("\(first)\(second)", radix: 16) else { return "" }
            bytes.append(byte)
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}

private final class PreviewDocumentBox {
    let document: PreviewDocument
    init(_ document: PreviewDocument) { self.document = document }
}

private final class NoteReferenceResolverBox {
    let resolver: NoteReferenceResolver
    init(_ resolver: NoteReferenceResolver) { self.resolver = resolver }
}

enum MarkdownPreprocessor {
    // Cache of recent `PreviewDocument` values keyed by document path,
    // markdown contents and the asset-index fingerprint. The preview pipeline
    // runs on every body evaluation — at least twice per render (once to
    // choose the render mode, once inside the native markup parser) — so
    // reusing unchanged parses avoids redundant O(doc-length) scanning on
    // every keystroke. Including the asset fingerprint means a newly indexed
    // file (e.g. a just-dropped image) re-resolves without a text change.
    nonisolated(unsafe) private static let preprocessCache: NSCache<NSString, PreviewDocumentBox> = {
        let cache = NSCache<NSString, PreviewDocumentBox>()
        cache.countLimit = 8
        return cache
    }()

    // Cache of recently built `NoteReferenceResolver`s. Building one resolves
    // symlinks for every note in the vault, which is far too expensive to
    // repeat on every keystroke when the asset index has not changed.
    nonisolated(unsafe) private static let noteResolverCache: NSCache<NSString, NoteReferenceResolverBox> = {
        let cache = NSCache<NSString, NoteReferenceResolverBox>()
        cache.countLimit = 4
        return cache
    }()

    static func preprocessCached(_ markdown: String, context: PreviewContext) -> PreviewDocument {
        let fingerprint = context.assetLookupFingerprint
        let key = cacheKey(for: markdown, context: context, assetLookupFingerprint: fingerprint)
        if let cached = preprocessCache.object(forKey: key) {
            return cached.document
        }
        let document = preprocess(markdown, context: context, assetLookupFingerprint: fingerprint)
        preprocessCache.setObject(PreviewDocumentBox(document), forKey: key)
        return document
    }

    private static func cacheKey(
        for markdown: String,
        context: PreviewContext,
        assetLookupFingerprint: Int
    ) -> NSString {
        var hasher = Hasher()
        hasher.combine(markdown)
        hasher.combine(context.documentURL)
        hasher.combine(context.vaultURL)
        hasher.combine(assetLookupFingerprint)
        let digest = hasher.finalize()
        return "\(context.documentURL?.path ?? "")|\(markdown.utf8.count)|\(assetLookupFingerprint)|\(digest)" as NSString
    }

    private static func noteResolver(for context: PreviewContext, assetLookupFingerprint: Int) -> NoteReferenceResolver {
        let key = "\(assetLookupFingerprint)|\(context.vaultURL?.path ?? "")" as NSString
        if let cached = noteResolverCache.object(forKey: key) {
            return cached.resolver
        }

        let resolver = NoteReferenceResolver(
            noteURLs: context.assetLookupByFilename.values
                .flatMap { $0 }
                .filter(Workspace.isMarkdownFile),
            vaultURL: context.vaultURL
        )
        noteResolverCache.setObject(NoteReferenceResolverBox(resolver), forKey: key)
        return resolver
    }

    static func preprocess(_ markdown: String, context: PreviewContext) -> PreviewDocument {
        preprocess(markdown, context: context, assetLookupFingerprint: context.assetLookupFingerprint)
    }

    private static func preprocess(
        _ markdown: String,
        context: PreviewContext,
        assetLookupFingerprint: Int
    ) -> PreviewDocument {
        let normalizedSource = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedSource.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let embeds = Dictionary(uniqueKeysWithValues: EditorLinkPreviewDetector.presentationPreviews(in: normalizedSource)
            .map { ($0.paragraphRange.location, $0) })
        var lineOffsets: [Int] = []
        var offset = 0
        for line in lines {
            lineOffsets.append(offset)
            offset += (line as NSString).length + 1
        }
        let resolver = AssetResolver(context: context)
        let noteResolver = noteResolver(for: context, assetLookupFingerprint: assetLookupFingerprint)

        let references = embeds.isEmpty ? "" : referenceDefinitions(in: lines)
        var segments: [PreviewSegment] = []
        var markdownBuffer: [String] = []
        var requiresHTMLFallback = false
        var index = 0

        func flushMarkdownBuffer() {
            guard !markdownBuffer.isEmpty else {
                return
            }

            segments.append(.markdown(markdownBuffer.joined(separator: "\n") + (references.isEmpty ? "" : "\n\n" + references)))
            markdownBuffer.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let embed = embeds[lineOffsets[index]] {
                flushMarkdownBuffer()
                segments.append(.embed(embed))
                index += 1
                continue
            }

            if let fence = codeFenceMarker(in: trimmed) {
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if language.lowercased() == "mermaid" {
                    flushMarkdownBuffer()
                    index += 1

                    var mermaidLines: [String] = []
                    while index < lines.count {
                        let candidate = lines[index]
                        if candidate.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                            index += 1
                            break
                        }

                        mermaidLines.append(candidate)
                        index += 1
                    }

                    let source = mermaidLines.joined(separator: "\n")
                    segments.append(.mermaid(source: source, diagram: MermaidParser.parse(source)))
                    continue
                }

                markdownBuffer.append(line)
                index += 1
                while index < lines.count {
                    let candidate = lines[index]
                    markdownBuffer.append(candidate)
                    index += 1

                    if candidate.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        break
                    }
                }
                continue
            }

            // Block math: `$$` on its own line opens a display-math block that
            // closes on the next standalone `$$`. Emitted as a placeholder
            // token so cmark leaves the LaTeX source untouched.
            if trimmed == "$$" {
                index += 1
                var mathLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.trimmingCharacters(in: .whitespaces) == "$$" {
                        index += 1
                        break
                    }
                    mathLines.append(candidate)
                    index += 1
                }

                let source = mathLines.joined(separator: "\n")
                if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    markdownBuffer.append("")
                    markdownBuffer.append(MathTokenCoder.encode(source, display: true))
                    markdownBuffer.append("")
                    requiresHTMLFallback = true
                }
                continue
            }

            markdownBuffer.append(
                rewriteInlineSyntax(
                    in: line,
                    resolver: resolver,
                    noteResolver: noteResolver,
                    documentURL: context.documentURL,
                    requiresHTMLFallback: &requiresHTMLFallback
                )
            )
            index += 1
        }

        flushMarkdownBuffer()

        if segments.isEmpty {
            segments = [.markdown("")]
        }

        return PreviewDocument(
            source: normalizedSource,
            context: context,
            segments: segments,
            requiresHTMLFallback: requiresHTMLFallback
        )
    }

    private static let referenceDefinitionPattern = try! NSRegularExpression(
        pattern: #"^ {0,3}\[[^\]\n]+\]:[ \t]*\S+"#
    )

    private static func referenceDefinitions(in lines: [String]) -> String {
        var definitions: [String] = []
        var fence: String?
        let definition = referenceDefinitionPattern
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = codeFenceMarker(in: trimmed) {
                if let activeFence = fence {
                    if marker.first == activeFence.first, marker.count >= activeFence.count,
                       trimmed.allSatisfy({ $0 == activeFence.first || $0.isWhitespace }) { fence = nil }
                } else { fence = marker }
            } else if fence == nil, definition.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                definitions.append(line)
                if index + 1 < lines.count {
                    let next = lines[index + 1]
                    let title = next.trimmingCharacters(in: .whitespaces)
                    let isTitle = (title.hasPrefix("\"") && title.hasSuffix("\"")) ||
                        (title.hasPrefix("'") && title.hasSuffix("'")) ||
                        (title.hasPrefix("(") && title.hasSuffix(")"))
                    if next.first?.isWhitespace == true, isTitle {
                        definitions.append(next)
                        index += 1
                    }
                }
            }
            index += 1
        }
        return definitions.joined(separator: "\n")
    }

    private static func codeFenceMarker(in trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") else {
            return nil
        }

        let marker = trimmedLine.prefix { $0 == trimmedLine.first }
        guard marker.count >= 3 else {
            return nil
        }

        return String(marker)
    }

    private static func rewriteInlineSyntax(
        in line: String,
        resolver: AssetResolver,
        noteResolver: NoteReferenceResolver,
        documentURL: URL?,
        requiresHTMLFallback: inout Bool
    ) -> String {

        let characters = Array(line)
        var result = ""
        var index = 0
        var activeInlineCodeFenceLength: Int?

        while index < characters.count {
            if characters[index] == "`" {
                let runStart = index
                while index < characters.count, characters[index] == "`" {
                    index += 1
                }

                let fenceLength = index - runStart
                result.append(contentsOf: characters[runStart..<index])

                if activeInlineCodeFenceLength == fenceLength {
                    activeInlineCodeFenceLength = nil
                } else if activeInlineCodeFenceLength == nil {
                    activeInlineCodeFenceLength = fenceLength
                }

                continue
            }

            if activeInlineCodeFenceLength == nil {
                if let rewrite = rewriteMathSpan(
                    in: characters,
                    from: index
                ) {
                    result += rewrite.rendered
                    index = rewrite.nextIndex
                    requiresHTMLFallback = true
                    continue
                }

                if let rewrite = rewriteObsidianEmbed(
                    in: characters,
                    from: index,
                    resolver: resolver,
                    requiresHTMLFallback: &requiresHTMLFallback
                ) {
                    result += rewrite.rendered
                    index = rewrite.nextIndex
                    continue
                }

                if let rewrite = rewriteObsidianNoteLink(
                    in: characters,
                    from: index,
                    resolver: noteResolver,
                    documentURL: documentURL
                ) {
                    result += rewrite.rendered
                    index = rewrite.nextIndex
                    continue
                }

                if let rewrite = rewriteMarkdownImage(
                    in: characters,
                    from: index,
                    resolver: resolver
                ) {
                    result += rewrite.rendered
                    index = rewrite.nextIndex
                    continue
                }
            }

            result.append(characters[index])
            index += 1
        }

        return result
    }

    /// Detects inline LaTeX math on a single line and replaces the delimited
    /// span with a placeholder token. We support the unambiguous delimiters
    /// `$$...$$`, `\(...\)`, and `\[...\]` — single-dollar `$...$` is skipped
    /// intentionally because it collides with currency values (`cost $5`).
    private static func rewriteMathSpan(
        in characters: [Character],
        from index: Int
    ) -> (rendered: String, nextIndex: Int)? {
        guard index < characters.count else { return nil }

        if characters[index] == "$",
           index + 1 < characters.count,
           characters[index + 1] == "$" {
            return consumeMath(
                in: characters,
                contentStart: index + 2,
                closing: ["$", "$"],
                display: true
            )
        }

        if characters[index] == "\\",
           index + 1 < characters.count {
            switch characters[index + 1] {
            case "(":
                return consumeMath(
                    in: characters,
                    contentStart: index + 2,
                    closing: ["\\", ")"],
                    display: false
                )
            case "[":
                return consumeMath(
                    in: characters,
                    contentStart: index + 2,
                    closing: ["\\", "]"],
                    display: true
                )
            default:
                return nil
            }
        }

        return nil
    }

    private static func consumeMath(
        in characters: [Character],
        contentStart: Int,
        closing: [Character],
        display: Bool
    ) -> (rendered: String, nextIndex: Int)? {
        guard closing.count == 2 else { return nil }

        var cursor = contentStart
        while cursor + 1 < characters.count {
            if characters[cursor] == closing[0],
               characters[cursor + 1] == closing[1] {
                let latex = String(characters[contentStart..<cursor])
                guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                let nextIndex = cursor + 2
                return (MathTokenCoder.encode(latex, display: display), nextIndex)
            }
            cursor += 1
        }

        return nil
    }

    private static func rewriteObsidianEmbed(
        in characters: [Character],
        from index: Int,
        resolver: AssetResolver,
        requiresHTMLFallback: inout Bool
    ) -> (rendered: String, nextIndex: Int)? {
        guard let match = MarkdownNoteLinkExtractor.obsidianEmbed(in: characters, from: index) else {
            return nil
        }

        let descriptor = PreviewMarkdownSyntax.parseObsidianReference(match.rawReference)

        guard let asset = resolver.resolve(reference: descriptor.target) else {
            return (match.original, match.nextIndex)
        }

        if asset.isImage {
            let title = descriptor.width.map { PreviewMarkdownSyntax.widthTitleMarker(for: $0) }
            if descriptor.width != nil {
                requiresHTMLFallback = true
            }

            return (
                PreviewMarkdownSyntax.imageMarkdown(
                    altText: descriptor.displayName,
                    destination: asset.fileURL,
                    title: title
                ),
                match.nextIndex
            )
        }

        return (
            PreviewMarkdownSyntax.linkMarkdown(
                label: descriptor.displayName,
                destination: asset.fileURL
            ),
            match.nextIndex
        )
    }

    private static func rewriteObsidianNoteLink(
        in characters: [Character],
        from index: Int,
        resolver: NoteReferenceResolver,
        documentURL: URL?
    ) -> (rendered: String, nextIndex: Int)? {
        guard let match = MarkdownNoteLinkExtractor.obsidianNoteLink(in: characters, from: index) else {
            return nil
        }

        let original = String(characters[index..<match.nextIndex])
        guard let destination = resolver.resolve(destination: match.destination, from: documentURL) else {
            return (original, match.nextIndex)
        }

        return (
            PreviewMarkdownSyntax.linkMarkdown(
                label: match.displayName,
                destination: destination
            ),
            match.nextIndex
        )
    }

    private static func rewriteMarkdownImage(
        in characters: [Character],
        from index: Int,
        resolver: AssetResolver
    ) -> (rendered: String, nextIndex: Int)? {
        guard let parsed = MarkdownNoteLinkExtractor.markdownImage(in: characters, from: index) else {
            return nil
        }

        guard let asset = resolver.resolveImage(reference: parsed.destination) else {
            return (parsed.original, parsed.nextIndex)
        }

        return (
            PreviewMarkdownSyntax.imageMarkdown(
                altText: parsed.altText,
                destination: asset.fileURL,
                title: parsed.title
            ),
            parsed.nextIndex
        )
    }
}

enum HTMLPreviewRenderer {
    private static let gfmExtensionNames = ["table", "strikethrough", "autolink"]

    // Pre-compiled regexes used in the post-processing hot path.
    // Compiling NSRegularExpression is relatively expensive; re-compiling on
    // every render (which happens on every keystroke in the editor) was
    // repeatedly rebuilding these. Cache them once at first use.
    private static let obsidianWidthTitlePattern = try! NSRegularExpression(
        pattern: #"title="codex-obsidian-width-(\d+)""#
    )
    private static let paragraphBlockPattern = try! NSRegularExpression(
        pattern: #"<p>((?s:.*?))</p>"#
    )
    private static let bareURLPattern = try! NSRegularExpression(
        pattern: #"(?<![=\"'])https?://[^\s<\"]+"#
    )
    private static let strikethroughPattern = try! NSRegularExpression(
        pattern: #"~~(.+?)~~"#
    )
    private static let tableAlignmentPattern = try! NSRegularExpression(
        pattern: #"^[\s|:\-]+$"#
    )
    private static let mathInlineTokenPattern = try! NSRegularExpression(
        pattern: "\(MathTokenCoder.inlinePrefix)([0-9a-fA-F]+)\(MathTokenCoder.inlineSuffix)"
    )
    private static let mathDisplayTokenPattern = try! NSRegularExpression(
        pattern: "\(MathTokenCoder.displayPrefix)([0-9a-fA-F]+)\(MathTokenCoder.displaySuffix)"
    )
    private static let mathDisplayParagraphPattern = try! NSRegularExpression(
        pattern: "<p>\\s*(<span class=\"math-display\">[^<]*</span>)\\s*</p>"
    )
    private static let dangerousURLSchemePatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)(href|src)\s*=\s*"\s*(?:javascript|vbscript):[^"]*""#),
        try! NSRegularExpression(pattern: #"(?i)(href|src)\s*=\s*'\s*(?:javascript|vbscript):[^']*'"#),
        try! NSRegularExpression(pattern: #"(?i)(href|src)\s*=\s*"\s*data:(?!image/)[^"]*""#),
        try! NSRegularExpression(pattern: #"(?i)(href|src)\s*=\s*'\s*data:(?!image/)[^']*'"#),
    ]

    // Cache of rendered mermaid SVGs keyed by the mermaid source text.
    // The preview pipeline re-runs on every text change; diagrams are
    // expensive to stringify and the common case is that a diagram is
    // unchanged between successive renders.
    //
    // `NSCache` is documented thread-safe, but the Swift 6 compiler does not
    // (yet) recognise it as `Sendable`, so the `nonisolated(unsafe)`
    // annotation opts out of strict-concurrency checking for this one
    // reference. The cache itself handles locking internally.
    nonisolated(unsafe) private static let mermaidSVGCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 128
        return cache
    }()

    static func render(document: PreviewDocument) -> String {
        document.segments.map(render).joined(separator: "\n")
    }

    private static func render(_ segment: PreviewSegment) -> String {
        switch segment {
        case .embed(let preview):
            // Static HTML/export keeps a usable source link. The app renders
            // this segment with the same interactive card as the editor.
            return "<p><a href=\"\(escapeHTML(preview.url.absoluteString))\">\(escapeHTML(preview.title))</a></p>"
        case .markdown(let markdown):
            guard !markdown.isEmpty else {
                return ""
            }

            let html = renderMarkdown(markdown)
            return applyAppSpecificPostProcessing(to: html)

        case .mermaid(let source, let diagram):
            guard let diagram else {
                return applyAppSpecificPostProcessing(
                    to: renderMarkdown("```mermaid\n\(source)\n```")
                )
            }

            let key = source as NSString
            if let cached = mermaidSVGCache.object(forKey: key) {
                return cached as String
            }
            let rendered = "<div class=\"mermaid-diagram\">\(MermaidRenderer.renderToSVG(diagram))</div>"
            mermaidSVGCache.setObject(rendered as NSString, forKey: key)
            return rendered
        }
    }

    private static func renderMarkdown(_ markdown: String) -> String {
        // We keep CMARK_OPT_UNSAFE because the preview legitimately relies on
        // it to emit `file://` <img> sources for local vault images (cmark's
        // safe mode strips the `file:` scheme). To stay safe we instead:
        //   1. Neutralize *all* raw user HTML before parsing (escapeUserHTML),
        //      using a sound per-`<` escaper with no multi-line or scheme
        //      bypass — genuine http(s)/mailto autolinks are preserved.
        //   2. Strip dangerous link/script schemes from the rendered output
        //      (sanitizeDangerousURLSchemes in applyAppSpecificPostProcessing).
        // A strict CSP and a WKNavigationDelegate provide defense in depth.
        let sanitizedMarkdown = escapeUserHTML(in: markdown)
        let options = Int32(CMARK_OPT_UNSAFE)

        guard let parser = cmark_parser_new(options) else {
            return ""
        }
        defer { cmark_parser_free(parser) }

        for extensionName in gfmExtensionNames {
            extensionName.withCString { name in
                guard let syntaxExtension = cmark_find_syntax_extension(name) else {
                    return
                }

                _ = cmark_parser_attach_syntax_extension(parser, syntaxExtension)
            }
        }

        sanitizedMarkdown.withCString { markdownCString in
            cmark_parser_feed(parser, markdownCString, strlen(markdownCString))
        }

        guard let document = cmark_parser_finish(parser) else {
            return ""
        }
        defer { cmark_node_free(document) }

        guard let renderedHTML = cmark_render_html(
            document,
            options,
            cmark_parser_get_syntax_extensions(parser)
        ) else {
            return ""
        }
        defer {
            cmark_get_default_mem_allocator()?.pointee.free(renderedHTML)
        }

        return String(cString: renderedHTML)
    }

    private static func applyAppSpecificPostProcessing(to html: String) -> String {
        let range = NSRange(location: 0, length: (html as NSString).length)
        let widthAdjustedHTML = obsidianWidthTitlePattern.stringByReplacingMatches(
            in: html,
            range: range,
            withTemplate: "width=\"$1\""
        )

        let paragraphTransformed = transformParagraphBlocks(in: widthAdjustedHTML)
        let mathTransformed = transformMathTokens(in: paragraphTransformed)
        return sanitizeDangerousURLSchemes(in: mathTransformed)
    }

    /// cmark with CMARK_OPT_UNSAFE does not sanitize link/image destinations,
    /// so a `[x](javascript:…)` markdown link would render a live
    /// `javascript:` href. Neutralize dangerous schemes in href/src attributes
    /// here (keeping `data:image/…` so inline images still work).
    private static func sanitizeDangerousURLSchemes(in html: String) -> String {
        var result = html
        for regex in dangerousURLSchemePatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1=\"#\"")
        }
        return result
    }

    private static func transformMathTokens(in html: String) -> String {
        var result = substituteMathTokens(in: html, pattern: mathInlineTokenPattern, cssClass: "math-inline")
        result = substituteMathTokens(in: result, pattern: mathDisplayTokenPattern, cssClass: "math-display")

        // Unwrap `<p>` wrappers that cmark adds around a standalone display
        // block so the `<span class="math-display">` flows at block level
        // without an intervening paragraph.
        let nsResult = result as NSString
        let range = NSRange(location: 0, length: nsResult.length)
        return mathDisplayParagraphPattern.stringByReplacingMatches(
            in: result,
            range: range,
            withTemplate: "$1"
        )
    }

    /// Replaces every match of `pattern` in `string` in a single forward pass.
    ///
    /// `replacement` receives each match and the original `NSString`, and
    /// returns the text to emit in place of the whole match, or `nil` to keep
    /// the matched text untouched. Untouched slices and replacements are
    /// appended to one pre-sized buffer, so the cost is linear in the length
    /// of the string plus the number of matches — unlike repeatedly calling
    /// `replacingCharacters(in:with:)`, which rebuilds the whole string per
    /// match and is quadratic in the number of matches.
    private static func replacingMatches(
        of pattern: NSRegularExpression,
        in string: String,
        using replacement: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        let nsString = string as NSString
        let length = nsString.length
        let matches = pattern.matches(in: string, range: NSRange(location: 0, length: length))
        guard !matches.isEmpty else { return string }

        let result = NSMutableString(capacity: length + matches.count * 32)
        var cursor = 0
        for match in matches {
            guard let replacementText = replacement(match, nsString) else {
                continue
            }

            let matchRange = match.range
            if matchRange.location > cursor {
                result.append(nsString.substring(with: NSRange(location: cursor, length: matchRange.location - cursor)))
            }
            result.append(replacementText)
            cursor = NSMaxRange(matchRange)
        }

        if cursor < length {
            result.append(nsString.substring(from: cursor))
        }

        return result as String
    }

    private static func substituteMathTokens(
        in html: String,
        pattern: NSRegularExpression,
        cssClass: String
    ) -> String {
        replacingMatches(of: pattern, in: html) { match, nsHTML in
            let hexRange = match.range(at: 1)
            guard hexRange.location != NSNotFound else { return nil }
            let hex = nsHTML.substring(with: hexRange)
            let latex = MathTokenCoder.decode(hex: hex)
            let escaped = escapeHTML(latex)
            return "<span class=\"\(cssClass)\">\(escaped)</span>"
        }
    }

    private static func transformParagraphBlocks(in html: String) -> String {
        replacingMatches(of: paragraphBlockPattern, in: html) { match, nsHTML in
            let contentRange = match.range(at: 1)
            guard contentRange.location != NSNotFound else {
                return nil
            }

            let originalContent = nsHTML.substring(with: contentRange)
            if let tableHTML = renderTableParagraphIfNeeded(from: originalContent) {
                return tableHTML
            }

            return "<p>\(replaceStrikethrough(in: autolinkBareURLs(in: originalContent)))</p>"
        }
    }

    private static func renderTableParagraphIfNeeded(from paragraphContent: String) -> String? {
        let lines = paragraphContent.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2,
              lines[0].contains("|") else {
            return nil
        }
        let alignmentLine = lines[1] as NSString
        let alignmentRange = NSRange(location: 0, length: alignmentLine.length)
        guard tableAlignmentPattern.firstMatch(in: lines[1], range: alignmentRange) != nil else {
            return nil
        }

        let headers = parseTableRow(lines[0])
        let alignments = parseTableAlignments(lines[1])
        guard !headers.isEmpty else {
            return nil
        }

        var html = "<table>\n<thead>\n<tr>\n"
        for (index, header) in headers.enumerated() {
            let alignment = alignments.count > index ? alignments[index] : nil
            let attribute = alignment.map { " style=\"text-align:\($0)\"" } ?? ""
            html += "<th\(attribute)>\(escapeHTML(unescapeHTML(header)))</th>\n"
        }
        html += "</tr>\n</thead>\n<tbody>\n"

        for rowLine in lines.dropFirst(2) where !rowLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cells = parseTableRow(rowLine)
            html += "<tr>\n"
            for (index, cell) in cells.enumerated() {
                let alignment = alignments.count > index ? alignments[index] : nil
                let attribute = alignment.map { " style=\"text-align:\($0)\"" } ?? ""
                html += "<td\(attribute)>\(escapeHTML(unescapeHTML(cell)))</td>\n"
            }
            html += "</tr>\n"
        }

        html += "</tbody>\n</table>"
        return html
    }

    private static func autolinkBareURLs(in string: String) -> String {
        replacingMatches(of: bareURLPattern, in: string) { match, nsString in
            let url = nsString.substring(with: match.range)
            return "<a href=\"\(url)\">\(url)</a>"
        }
    }

    private static func replaceStrikethrough(in string: String) -> String {
        replacingMatches(of: strikethroughPattern, in: string) { match, nsString in
            let innerRange = match.range(at: 1)
            guard innerRange.location != NSNotFound else {
                return nil
            }

            let content = nsString.substring(with: innerRange)
            return "<del>\(content)</del>"
        }
    }

    private static func parseTableRow(_ line: String) -> [String] {
        line.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseTableAlignments(_ line: String) -> [String] {
        parseTableRow(line).map { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(":"), trimmed.hasSuffix(":") {
                return "center"
            }

            if trimmed.hasSuffix(":") {
                return "right"
            }

            if trimmed.hasPrefix(":") {
                return "left"
            }

            return ""
        }
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func unescapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Raw HTML neutralization

    /// Escapes raw user-authored HTML before cmark parses it (cmark runs with
    /// CMARK_OPT_UNSAFE so that legitimate `file://` image sources survive).
    ///
    /// This is the corrected successor to a previous escaper that had two
    /// bypasses: it was line-scoped (a tag split across lines slipped through)
    /// and it whitelisted any run containing `://` or `@` (so
    /// `<iframe src="https://…">` passed through). This version decides per `<`
    /// with no multi-line dependency and only exempts genuine URL autolinks
    /// whose scheme appears *immediately* after the `<`.
    private static func escapeUserHTML(in markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var sanitizedLines: [String] = []
        var isInsideCodeBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                isInsideCodeBlock.toggle()
                sanitizedLines.append(line)
                continue
            }

            sanitizedLines.append(isInsideCodeBlock ? line : escapeRawHTMLAngles(in: line))
        }

        return sanitizedLines.joined(separator: "\n")
    }

    private static let autolinkSchemePrefixes = ["http://", "https://", "mailto:"]

    private static func escapeRawHTMLAngles(in line: String) -> String {
        let characters = Array(line)
        var result = ""
        var index = 0
        var activeInlineCodeFenceLength: Int?

        while index < characters.count {
            let character = characters[index]

            if character == "`" {
                let runStart = index
                while index < characters.count, characters[index] == "`" {
                    index += 1
                }
                let fenceLength = index - runStart
                result.append(contentsOf: characters[runStart..<index])
                if activeInlineCodeFenceLength == fenceLength {
                    activeInlineCodeFenceLength = nil
                } else if activeInlineCodeFenceLength == nil {
                    activeInlineCodeFenceLength = fenceLength
                }
                continue
            }

            if activeInlineCodeFenceLength == nil, character == "<" {
                // Preserve a genuine URL autolink only when the scheme appears
                // immediately after `<` (e.g. `<https://example.com>`).
                let lookaheadEnd = min(index + 1 + 8, characters.count)
                let lookahead = String(characters[(index + 1)..<lookaheadEnd]).lowercased()
                let isAutolink = autolinkSchemePrefixes.contains { lookahead.hasPrefix($0) }

                if !isAutolink {
                    let next = index + 1 < characters.count ? characters[index + 1] : nil
                    if let next, next.isLetter || next == "/" || next == "!" || next == "?" {
                        // Looks like an HTML tag/comment/closing tag — neutralize
                        // just the opening bracket; the rest renders as text.
                        result.append("&lt;")
                        index += 1
                        continue
                    }
                }
            }

            result.append(character)
            index += 1
        }

        return result
    }

}

@MainActor
struct NativePreviewMarkupParser: MarkupParser {
    let context: PreviewContext

    func attributedString(for input: String) throws -> AttributedString {
        let document = MarkdownPreprocessor.preprocessCached(input, context: context)
        guard document.preferredRenderMode == .native else {
            return AttributedString()
        }

        let parser = AttributedStringMarkdownParser.markdown(baseURL: context.previewBaseURL)
        return try parser.attributedString(for: document.normalizedMarkdown)
    }
}

struct PreviewImageAttachmentLoader: AttachmentLoader {
    typealias Attachment = PreviewImageAttachment

    let context: PreviewContext

    func attachment(
        for url: URL,
        text: String,
        environment _: ColorEnvironmentValues
    ) async throws -> PreviewImageAttachment {
        let loaded = try await PreviewImageSourceLoader.loadImageData(for: url, context: context)
        let size = try PreviewImageSourceLoader.imageSize(for: loaded.data, url: loaded.resolvedURL)

        return PreviewImageAttachment(
            id: loaded.resolvedURL.absoluteString,
            text: text,
            image: PreviewDecodedImage(data: loaded.data),
            intrinsicSize: size
        )
    }
}

/// Holds the `NSImage` decoded once for a `PreviewImageAttachment` so the
/// attachment's `body` does not re-create it on every evaluation.
///
/// `NSImage` is not formally `Sendable`, but the instance here is created
/// once, never mutated afterwards and only drawn from, which is the usage
/// AppKit documents as safe across threads.
final class PreviewDecodedImage: @unchecked Sendable {
    let image: NSImage?

    init(data: Data) {
        image = NSImage(data: data)
    }
}

enum PreviewImageSourceLoader {
    static let maximumRemoteImageBytes = 20 * 1_024 * 1_024

    private static let remoteSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func resolvedImageURL(for url: URL, context: PreviewContext) -> URL? {
        let resolver = AssetResolver(context: context)
        return resolver.resolveImageURL(for: url)
    }

    static func loadImageData(for url: URL, context: PreviewContext) async throws -> (data: Data, resolvedURL: URL) {
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 15
            )
            request.setValue("image/avif,image/webp,image/png,image/jpeg,image/gif,image/*;q=0.8", forHTTPHeaderField: "Accept")

            let (data, response) = try await remoteSession.data(for: request)
            guard isValidRemoteImageResponse(response, for: url) else {
                throw PreviewPipelineError.invalidRemoteImageResponse(url)
            }
            guard data.count <= maximumRemoteImageBytes else {
                throw PreviewPipelineError.remoteImageTooLarge(url)
            }
            return (data, url)
        }

        guard let resolvedURL = resolvedImageURL(for: url, context: context) else {
            throw PreviewPipelineError.unresolvedImageReference(url.absoluteString)
        }

        return (try Data(contentsOf: resolvedURL), resolvedURL)
    }

    static func isValidRemoteImageResponse(_ response: URLResponse, for url: URL) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              httpResponse.mimeType?.lowercased().hasPrefix("image/") == true else {
            return false
        }

        let expectedLength = httpResponse.expectedContentLength
        return expectedLength < 0 || expectedLength <= Int64(maximumRemoteImageBytes)
    }

    /// Reads the pixel size from the image container's metadata without
    /// decoding the bitmap. Formats ImageIO cannot read (notably SVG) fall
    /// back to a full `NSImage` decode.
    static func imageSize(for data: Data, url: URL) throws -> CGSize {
        if let size = pixelSizeFromImageSource(data) {
            return size
        }

        guard let image = NSImage(data: data) else {
            throw PreviewPipelineError.invalidImageData(url)
        }

        if let representation = image.representations.first,
           representation.pixelsWide > 0,
           representation.pixelsHigh > 0 {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }

        return image.size
    }

    private static func pixelSizeFromImageSource(_ data: Data) -> CGSize? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return nil
        }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return pixelSize(width: width, height: height, orientation: orientation)
    }

    /// Applies an EXIF/TIFF orientation (1...8) to raw pixel dimensions.
    /// Orientations 5 through 8 rotate by 90°, swapping width and height.
    static func pixelSize(width: Int, height: Int, orientation: UInt32) -> CGSize? {
        guard width > 0, height > 0 else {
            return nil
        }

        if (5...8).contains(orientation) {
            return CGSize(width: height, height: width)
        }

        return CGSize(width: width, height: height)
    }
}

struct PreviewImageAttachment: Attachment {
    let id: String
    let text: String
    let image: PreviewDecodedImage
    let intrinsicSize: CGSize

    var description: String {
        text
    }

    @MainActor
    var body: some View {
        Group {
            if let nsImage = image.image {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text(text)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
        guard intrinsicSize.width > 0, intrinsicSize.height > 0 else {
            return CGSize(width: proposal.width ?? 320, height: 180)
        }

        let proposedWidth = proposal.width ?? intrinsicSize.width
        let width = min(proposedWidth, intrinsicSize.width)
        let aspectRatio = intrinsicSize.height / intrinsicSize.width
        return CGSize(width: width, height: width * aspectRatio)
    }

    static func == (lhs: PreviewImageAttachment, rhs: PreviewImageAttachment) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(text)
    }
}

/// Markdown/Obsidian rendering helpers for the preview. All *recognition* of
/// link/image syntax lives in the shared `MarkdownNoteLinkExtractor`
/// tokenizer; this enum only keeps the preview-specific emission helpers and
/// thin adapters over the shared parses.
enum PreviewMarkdownSyntax {
    struct ObsidianReference {
        let target: String
        let displayName: String
        let width: Int?
    }

    static func standaloneObsidianImageReference(in line: String) -> ObsidianReference? {
        guard line.hasPrefix("![["), line.hasSuffix("]]"), line.count >= 5 else {
            return nil
        }

        let start = line.index(line.startIndex, offsetBy: 3)
        let end = line.index(line.endIndex, offsetBy: -2)
        return parseObsidianReference(String(line[start..<end]))
    }

    static func parseObsidianReference(_ rawReference: String) -> ObsidianReference {
        let descriptor = MarkdownNoteLinkExtractor.parseObsidianReference(rawReference)
        let displayName = descriptor.fileName.isEmpty ? descriptor.destination : descriptor.fileName

        return ObsidianReference(
            target: descriptor.destination,
            displayName: displayName,
            width: descriptor.width
        )
    }

    static func parseStandaloneMarkdownImage(in line: String) -> MarkdownNoteLinkExtractor.MarkdownImageMatch? {
        let characters = Array(line)
        guard let parsed = MarkdownNoteLinkExtractor.markdownImage(in: characters, from: 0),
              parsed.nextIndex == characters.count else {
            return nil
        }

        return parsed
    }

    static func imageMarkdown(altText: String, destination: URL, title: String? = nil) -> String {
        let escapedAlt = escapeMarkdownLabel(altText)
        let escapedDestination = "<\(destination.absoluteString)>"

        if let title, !title.isEmpty {
            return "![\(escapedAlt)](\(escapedDestination) \"\(escapeMarkdownTitle(title))\")"
        }

        return "![\(escapedAlt)](\(escapedDestination))"
    }

    static func linkMarkdown(label: String, destination: URL) -> String {
        "[\(escapeMarkdownLabel(label))](<\(destination.absoluteString)>)"
    }

    static func widthTitleMarker(for width: Int) -> String {
        "codex-obsidian-width-\(width)"
    }

    private static func escapeMarkdownLabel(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func escapeMarkdownTitle(_ string: String) -> String {
        string.replacingOccurrences(of: "\"", with: "\\\"")
    }
}

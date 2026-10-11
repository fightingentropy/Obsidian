import AppKit

enum EditorLinkDetector {
    /// Resolves the URL at (or just after) `characterIndex` when the caret or
    /// click lands on a markdown link or a bare http(s) URL.
    ///
    /// Link recognition is shared with the syntax highlighter through
    /// `EditorLinkScanner`, so a span that is highlighted as a link is exactly
    /// the span Cmd-click / Cmd-Return can open. Wiki-style `[[note]]` links
    /// are highlighted for navigation but intentionally do not resolve to an
    /// external URL here.
    static func url(near characterIndex: Int, in text: String) -> URL? {
        let nsText = text as NSString
        guard nsText.length > 0 else {
            return nil
        }

        let candidateIndices = Set([
            characterIndex,
            max(0, characterIndex - 1),
        ].filter { $0 < nsText.length })

        for index in candidateIndices.sorted() {
            if let url = markdownLinkURL(at: index, in: nsText) {
                return url
            }

            if let url = bareLinkURL(at: index, in: nsText) {
                return url
            }
        }

        return nil
    }

    private static func markdownLinkURL(at characterIndex: Int, in nsText: NSString) -> URL? {
        // Markdown links cannot span a newline, so scanning only the click's
        // line keeps this O(line) instead of O(document) on large notes.
        let lineRange = nsText.lineRange(for: NSRange(location: characterIndex, length: 0))
        let limit = NSMaxRange(lineRange)
        var location = lineRange.location

        while location < limit {
            let character = nsText.character(at: location)

            if character == 33 {
                // Skip images and embeds: they are highlighted but never
                // resolve to an openable URL from the editor.
                if let embedRange = EditorLinkScanner.obsidianImageRange(startingAt: location, in: nsText, limit: limit) {
                    location = NSMaxRange(embedRange)
                    continue
                }

                if let imageMatch = EditorLinkScanner.markdownLink(startingAt: location, in: nsText, limit: limit, isImage: true) {
                    location = NSMaxRange(imageMatch.range)
                    continue
                }
            } else if character == 91,
                      let match = EditorLinkScanner.markdownLink(startingAt: location, in: nsText, limit: limit, isImage: false) {
                guard NSLocationInRange(characterIndex, match.range) else {
                    location = NSMaxRange(match.range)
                    continue
                }

                let urlString = nsText.substring(with: match.destinationRange)
                guard let url = URL(string: urlString), url.scheme != nil else {
                    return nil
                }

                return url
            }

            location += 1
        }

        return nil
    }

    private static func bareLinkURL(at characterIndex: Int, in nsText: NSString) -> URL? {
        // Bare links are terminated by whitespace, so they never cross a line
        // boundary; scanning only the click's line keeps this bounded.
        let lineRange = nsText.lineRange(for: NSRange(location: characterIndex, length: 0))
        let limit = NSMaxRange(lineRange)
        var location = lineRange.location

        while location < limit {
            guard nsText.character(at: location) == 104 else {
                location += 1
                continue
            }

            if let linkRange = EditorLinkScanner.bareLinkRange(startingAt: location, in: nsText, limit: limit) {
                guard NSLocationInRange(characterIndex, linkRange) else {
                    location = NSMaxRange(linkRange)
                    continue
                }

                return URL(string: nsText.substring(with: linkRange))
            }

            location += 1
        }

        return nil
    }
}

/// NSString/UTF-16-based link and image scanners shared by the syntax
/// highlighter (which colors link spans) and `EditorLinkDetector` (which
/// resolves Cmd-click / Cmd-Return targets), giving the editor a single
/// definition of "what is a link".
///
/// The note-graph extractor and preview rewriter instead use the
/// Character-based `MarkdownNoteLinkExtractor` tokenizer; unit tests assert
/// the two agree on representative link forms so the implementations cannot
/// silently diverge.
private enum EditorLinkScanner {
    struct MarkdownLinkMatch {
        /// Range of the whole `[text](destination)` construct.
        let range: NSRange
        /// Range of the reader-facing label inside the square brackets.
        let labelRange: NSRange
        /// Range of just the destination inside the parentheses.
        let destinationRange: NSRange
    }

    static func markdownLink(
        startingAt location: Int,
        in text: NSString,
        limit: Int,
        isImage: Bool
    ) -> MarkdownLinkMatch? {
        let bracketLocation = isImage ? location + 1 : location
        guard bracketLocation < limit, text.character(at: bracketLocation) == 91 else { return nil }

        let textStart = bracketLocation + 1
        guard textStart < limit else { return nil }

        guard let closingBracket = index(of: 93, in: text, from: textStart, limit: limit) else {
            return nil
        }

        if !isImage, closingBracket == textStart {
            return nil
        }

        let openingParen = closingBracket + 1
        guard openingParen < limit, text.character(at: openingParen) == 40 else { return nil }

        let destinationStart = openingParen + 1
        guard destinationStart < limit else { return nil }

        var destinationEnd = destinationStart
        while destinationEnd < limit {
            let character = text.character(at: destinationEnd)
            if character == 41 {
                break
            }
            if isNewline(character) || (!isImage && isWhitespace(character)) {
                return nil
            }
            destinationEnd += 1
        }

        guard destinationEnd < limit, destinationEnd > destinationStart else { return nil }
        return MarkdownLinkMatch(
            range: NSRange(location: location, length: destinationEnd + 1 - location),
            labelRange: NSRange(location: textStart, length: closingBracket - textStart),
            destinationRange: NSRange(location: destinationStart, length: destinationEnd - destinationStart)
        )
    }

    static func obsidianImageRange(
        startingAt location: Int,
        in text: NSString,
        limit: Int
    ) -> NSRange? {
        guard location + 3 < limit else { return nil }
        guard text.character(at: location) == 33,
              text.character(at: location + 1) == 91,
              text.character(at: location + 2) == 91 else {
            return nil
        }

        var closing = location + 3
        while closing + 1 < limit {
            if text.character(at: closing) == 93, text.character(at: closing + 1) == 93 {
                return NSRange(location: location, length: closing + 2 - location)
            }
            if isNewline(text.character(at: closing)) {
                return nil
            }
            closing += 1
        }

        return nil
    }

    static func obsidianNoteRange(
        startingAt location: Int,
        in text: NSString,
        limit: Int
    ) -> NSRange? {
        guard location + 3 < limit else { return nil }
        guard text.character(at: location) == 91,
              text.character(at: location + 1) == 91 else {
            return nil
        }

        var closing = location + 2
        while closing + 1 < limit {
            if text.character(at: closing) == 93, text.character(at: closing + 1) == 93 {
                return NSRange(location: location, length: closing + 2 - location)
            }

            if isNewline(text.character(at: closing)) {
                return nil
            }

            closing += 1
        }

        return nil
    }

    static func bareLinkRange(
        startingAt location: Int,
        in text: NSString,
        limit: Int
    ) -> NSRange? {
        guard location < limit, text.character(at: location) == 104 else { return nil }

        let prefixLength: Int
        if matchesHTTPPrefix(at: location, in: text, limit: limit) {
            prefixLength = 7
        } else if matchesHTTPSPrefix(at: location, in: text, limit: limit) {
            prefixLength = 8
        } else {
            return nil
        }

        var end = location + prefixLength
        while end < limit {
            let character = text.character(at: end)
            if isWhitespace(character) || isNewline(character) || character == 41 || character == 62 || character == 34 {
                break
            }
            end += 1
        }

        guard end > location + prefixLength else { return nil }
        return NSRange(location: location, length: end - location)
    }

    private static func matchesHTTPPrefix(at location: Int, in text: NSString, limit: Int) -> Bool {
        guard location + 7 <= limit else { return false }
        return text.character(at: location + 1) == 116 &&
            text.character(at: location + 2) == 116 &&
            text.character(at: location + 3) == 112 &&
            text.character(at: location + 4) == 58 &&
            text.character(at: location + 5) == 47 &&
            text.character(at: location + 6) == 47
    }

    private static func matchesHTTPSPrefix(at location: Int, in text: NSString, limit: Int) -> Bool {
        guard location + 8 <= limit else { return false }
        return text.character(at: location + 1) == 116 &&
            text.character(at: location + 2) == 116 &&
            text.character(at: location + 3) == 112 &&
            text.character(at: location + 4) == 115 &&
            text.character(at: location + 5) == 58 &&
            text.character(at: location + 6) == 47 &&
            text.character(at: location + 7) == 47
    }

    private static func index(of character: unichar, in text: NSString, from start: Int, limit: Int) -> Int? {
        guard start < limit else { return nil }

        var location = start
        while location < limit {
            let current = text.character(at: location)
            if current == character {
                return location
            }
            if isNewline(current) {
                return nil
            }
            location += 1
        }

        return nil
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 32 || character == 9
    }

    private static func isNewline(_ character: unichar) -> Bool {
        character == 10 || character == 13
    }
}

@MainActor
final class SyntaxHighlighter {
    private struct StyleSignature: Equatable {
        let fontChoice: EditorFontChoice
        let fontSize: Double
        let lineSpacing: Double
    }

    private struct Styles {
        let defaultAttributes: [NSAttributedString.Key: Any]
        let headingAttributes: [[NSAttributedString.Key: Any]]
        let boldAttributes: [NSAttributedString.Key: Any]
        let inlineCodeAttributes: [NSAttributedString.Key: Any]
        let codeBlockAttributes: [NSAttributedString.Key: Any]
        let linkAttributes: [NSAttributedString.Key: Any]
        let linkSyntaxAttributes: [NSAttributedString.Key: Any]
        let quoteAttributes: [NSAttributedString.Key: Any]
        let metaAttributes: [NSAttributedString.Key: Any]
    }

    /// What the single per-keystroke document walk learned about the span it
    /// hands back, so `highlight(_:range:codeBlockState:)` can skip the
    /// document-wide fence scan instead of rediscovering the code-block layout.
    enum CodeBlockState: Equatable {
        /// The range covers whole paragraphs that lie outside every fenced
        /// code block, so inline highlighting alone is enough.
        case outsideCodeBlock
        /// The range is exactly one fenced code block (fences included), so the
        /// code style applies to all of it and inline highlighting is skipped.
        case wholeCodeBlock
    }

    /// The span an incremental edit needs re-highlighted, together with the
    /// code-block knowledge gathered while computing it.
    struct IncrementalRange: Equatable {
        let range: NSRange
        let codeBlockState: CodeBlockState
    }

    private struct FenceMarker: Equatable {
        let character: unichar
        let length: Int

        /// A fence line closes an open block only when it uses the same
        /// character and is at least as long as the opening fence, matching
        /// the preview, metadata parser and link extractor.
        func closes(_ opening: FenceMarker) -> Bool {
            character == opening.character && length >= opening.length
        }
    }

    private let preferences: AppPreferences
    private var cachedStyleSignature: StyleSignature?
    private var cachedStyles: Styles?

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    /// Computes the span an edit touching `editedRange` needs re-highlighted.
    /// Returns `nil` when the edit forces a full-document pass: fence-affecting
    /// edits invalidate code-block parity for the whole document, so callers
    /// can coalesce those expensive passes off the per-keystroke path instead
    /// of running one synchronously each time.
    ///
    /// This is the only document walk on the per-keystroke path. Callers hand
    /// the result to `highlight(_:range:codeBlockState:)`, which then needs no
    /// further scan to know whether the span is a plain paragraph or a whole
    /// code block.
    func incrementalRange(for editedRange: NSRange?, in textStorage: NSTextStorage) -> IncrementalRange? {
        guard let editedRange else { return nil }

        let text = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        guard fullRange.length > 0 else {
            return IncrementalRange(range: fullRange, codeBlockState: .outsideCodeBlock)
        }

        let clampedLocation = min(max(editedRange.location, 0), fullRange.length)
        let clampedLength = min(max(editedRange.length, 0), max(0, fullRange.length - clampedLocation))
        let clampedRange = NSRange(location: clampedLocation, length: clampedLength)
        let probeRange = probeRange(for: clampedRange, fullRange: fullRange)
        let paragraphRange = text.paragraphRange(for: probeRange)

        if paragraphMayAffectCodeBlockState(paragraphRange, in: text) {
            return nil
        }

        if let codeBlockRange = codeBlockRange(containing: probeRange.location, in: text) {
            return IncrementalRange(range: codeBlockRange, codeBlockState: .wholeCodeBlock)
        }

        return IncrementalRange(range: paragraphRange, codeBlockState: .outsideCodeBlock)
    }

    /// Full-document pass: resets every attribute, then colors fenced code
    /// blocks and runs inline highlighting over everything outside them.
    func highlight(_ textStorage: NSTextStorage) {
        let text = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)

        let styles = currentStyles()
        textStorage.beginEditing()
        textStorage.setAttributes(styles.defaultAttributes, range: fullRange)

        let codeBlockRanges = highlightCodeBlocks(textStorage, text: text, styles: styles)
        let safeRanges = subtractRanges(codeBlockRanges, from: fullRange)

        for range in safeRanges {
            highlightInRange(textStorage, text: text, range: range, styles: styles)
        }

        textStorage.endEditing()
    }

    /// Incremental pass over the span `incrementalRange(for:in:)` returned. The
    /// code-block state decided there is reused here, so a paragraph outside
    /// any fence skips the fence scan entirely and a whole code block takes
    /// the code style directly.
    func highlight(_ textStorage: NSTextStorage, range: NSRange, codeBlockState: CodeBlockState) {
        let styles = currentStyles()
        textStorage.beginEditing()
        textStorage.setAttributes(styles.defaultAttributes, range: range)

        switch codeBlockState {
        case .wholeCodeBlock:
            applyCodeBlockStyle(textStorage, range: range, styles: styles)
        case .outsideCodeBlock:
            let text = textStorage.string as NSString
            highlightInRange(textStorage, text: text, range: range, styles: styles)
        }

        textStorage.endEditing()
    }

    // MARK: - Code Blocks

    private func highlightCodeBlocks(
        _ textStorage: NSTextStorage,
        text: NSString,
        styles: Styles
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        enumerateCodeBlocks(in: text) { range in
            applyCodeBlockStyle(textStorage, range: range, styles: styles)
            ranges.append(range)
            return true
        }
        return ranges
    }

    private func applyCodeBlockStyle(_ textStorage: NSTextStorage, range: NSRange, styles: Styles) {
        textStorage.addAttributes(styles.codeBlockAttributes, range: range)
    }

    // MARK: - Inline Highlighting

    private func highlightInRange(_ textStorage: NSTextStorage, text: NSString, range: NSRange, styles: Styles) {
        guard range.length > 0 else { return }

        var location = range.location
        let rangeEnd = NSMaxRange(range)

        while location < rangeEnd {
            let fullLineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let lineRange = NSIntersectionRange(fullLineRange, range)
            let lineContentRange = contentRange(forLineRange: lineRange, in: text)

            if lineContentRange.length > 0 {
                if lineRange.location == fullLineRange.location {
                    highlightLineMetadata(textStorage, text: text, lineRange: lineContentRange, styles: styles)
                }

                applyBoldSpans(to: textStorage, in: text, range: lineContentRange, styles: styles)
                applyInlineCodeSpans(to: textStorage, in: text, range: lineContentRange, styles: styles)
                applyBareLinks(to: textStorage, in: text, range: lineContentRange, styles: styles)
                applyMarkdownConstructs(to: textStorage, in: text, range: lineContentRange, styles: styles)
            }

            let nextLocation = NSMaxRange(fullLineRange)
            guard nextLocation > location else { break }
            location = nextLocation
        }
    }

    // MARK: - Helpers

    private func highlightLineMetadata(
        _ textStorage: NSTextStorage,
        text: NSString,
        lineRange: NSRange,
        styles: Styles
    ) {
        if let level = headingLevel(for: lineRange, in: text) {
            textStorage.addAttributes(styles.headingAttributes[level - 1], range: lineRange)
            textStorage.addAttributes(
                styles.metaAttributes,
                range: NSRange(location: lineRange.location, length: level + 1)
            )
        }

        if isBlockquoteLine(lineRange, in: text) {
            textStorage.addAttributes(styles.quoteAttributes, range: lineRange)
        }

        if let markerRange = unorderedListMarkerRange(for: lineRange, in: text) {
            textStorage.addAttributes(styles.metaAttributes, range: markerRange)
        }

        if let markerRange = orderedListMarkerRange(for: lineRange, in: text) {
            textStorage.addAttributes(styles.metaAttributes, range: markerRange)
        }

        if isHorizontalRuleLine(lineRange, in: text) {
            textStorage.addAttributes(styles.metaAttributes, range: lineRange)
        }
    }

    private func applyBoldSpans(
        to storage: NSTextStorage,
        in text: NSString,
        range: NSRange,
        styles: Styles
    ) {
        var location = range.location
        let end = NSMaxRange(range)

        while location + 1 < end {
            guard text.character(at: location) == 42, text.character(at: location + 1) == 42 else {
                location += 1
                continue
            }

            let contentStart = location + 2
            var closing = contentStart
            var matchedRange: NSRange?

            while closing + 1 < end {
                let character = text.character(at: closing)
                if isNewline(character) {
                    break
                }

                if character == 42, text.character(at: closing + 1) == 42, closing > contentStart {
                    matchedRange = NSRange(location: location, length: closing + 2 - location)
                    break
                }

                closing += 1
            }

            if let matchedRange {
                storage.addAttributes(styles.boldAttributes, range: matchedRange)
                storage.addAttributes(
                    styles.metaAttributes,
                    range: NSRange(location: matchedRange.location, length: 2)
                )
                storage.addAttributes(
                    styles.metaAttributes,
                    range: NSRange(location: NSMaxRange(matchedRange) - 2, length: 2)
                )
                location = NSMaxRange(matchedRange)
            } else {
                location += 2
            }
        }
    }

    private func applyInlineCodeSpans(
        to storage: NSTextStorage,
        in text: NSString,
        range: NSRange,
        styles: Styles
    ) {
        var location = range.location
        let end = NSMaxRange(range)

        while location < end {
            guard text.character(at: location) == 96 else {
                location += 1
                continue
            }

            let contentStart = location + 1
            var closing = contentStart
            var matchedRange: NSRange?

            while closing < end {
                let character = text.character(at: closing)
                if isNewline(character) {
                    break
                }

                if character == 96, closing > contentStart {
                    matchedRange = NSRange(location: location, length: closing + 1 - location)
                    break
                }

                closing += 1
            }

            if let matchedRange {
                storage.addAttributes(styles.inlineCodeAttributes, range: matchedRange)
                location = NSMaxRange(matchedRange)
            } else {
                location += 1
            }
        }
    }

    private func applyMarkdownConstructs(
        to storage: NSTextStorage,
        in text: NSString,
        range: NSRange,
        styles: Styles
    ) {
        var location = range.location
        let end = NSMaxRange(range)

        while location < end {
            let character = text.character(at: location)

            if character == 33 {
                if let embedRange = EditorLinkScanner.obsidianImageRange(startingAt: location, in: text, limit: end) {
                    storage.addAttributes(styles.linkAttributes, range: embedRange)
                    location = NSMaxRange(embedRange)
                    continue
                }

                if let imageMatch = EditorLinkScanner.markdownLink(
                    startingAt: location,
                    in: text,
                    limit: end,
                    isImage: true
                ) {
                    applyMarkdownLinkStyle(imageMatch, to: storage, styles: styles)
                    location = NSMaxRange(imageMatch.range)
                    continue
                }
            } else if character == 91,
                      let obsidianNoteRange = EditorLinkScanner.obsidianNoteRange(
                        startingAt: location,
                        in: text,
                        limit: end
                      ) {
                storage.addAttributes(styles.linkAttributes, range: obsidianNoteRange)
                location = NSMaxRange(obsidianNoteRange)
                continue
            } else if character == 91,
                      let linkMatch = EditorLinkScanner.markdownLink(
                        startingAt: location,
                        in: text,
                        limit: end,
                        isImage: false
                      ) {
                applyMarkdownLinkStyle(linkMatch, to: storage, styles: styles)
                location = NSMaxRange(linkMatch.range)
                continue
            }

            location += 1
        }
    }

    private func applyMarkdownLinkStyle(
        _ match: EditorLinkScanner.MarkdownLinkMatch,
        to storage: NSTextStorage,
        styles: Styles
    ) {
        let prefixRange = NSRange(
            location: match.range.location,
            length: match.labelRange.location - match.range.location
        )
        let suffixRange = NSRange(
            location: NSMaxRange(match.labelRange),
            length: NSMaxRange(match.range) - NSMaxRange(match.labelRange)
        )

        if prefixRange.length > 0 {
            storage.addAttributes(styles.linkSyntaxAttributes, range: prefixRange)
        }
        storage.addAttributes(styles.linkAttributes, range: match.labelRange)
        if suffixRange.length > 0 {
            storage.addAttributes(styles.linkSyntaxAttributes, range: suffixRange)
        }
    }

    private func applyBareLinks(
        to storage: NSTextStorage,
        in text: NSString,
        range: NSRange,
        styles: Styles
    ) {
        var location = range.location
        let end = NSMaxRange(range)

        while location < end {
            guard text.character(at: location) == 104 else {
                location += 1
                continue
            }

            if let linkRange = EditorLinkScanner.bareLinkRange(startingAt: location, in: text, limit: end) {
                storage.addAttributes(styles.linkAttributes, range: linkRange)
                location = NSMaxRange(linkRange)
            } else {
                location += 1
            }
        }
    }

    private func currentStyles() -> Styles {
        let signature = StyleSignature(
            fontChoice: preferences.editorFontChoice,
            fontSize: preferences.editorFontSize,
            lineSpacing: preferences.editorLineSpacing
        )

        if let cachedStyleSignature, cachedStyleSignature == signature, let cachedStyles {
            return cachedStyles
        }

        let editorBoldFont = Theme.editorBoldFont(using: preferences)
        let codeFont = Theme.codeFont(using: preferences)
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        let linkSyntaxAttributes: [NSAttributedString.Key: Any] = [
            .font: preferences.editorFontChoice.nsFont(
                size: max(11, preferences.editorFontSizeCGFloat * 0.75)
            ),
            .foregroundColor: Theme.metaColor,
            .underlineStyle: 0
        ]

        let styles = Styles(
            defaultAttributes: Theme.defaultAttributes(using: preferences),
            headingAttributes: (1...6).map { Theme.headingAttributes(level: $0, using: preferences) },
            boldAttributes: [.font: editorBoldFont],
            inlineCodeAttributes: [.font: codeFont, .foregroundColor: Theme.codeColor, .backgroundColor: Theme.codeBackground],
            codeBlockAttributes: [.font: codeFont, .foregroundColor: Theme.codeColor, .backgroundColor: Theme.codeBackground],
            linkAttributes: linkAttributes,
            linkSyntaxAttributes: linkSyntaxAttributes,
            quoteAttributes: [.foregroundColor: Theme.quoteColor],
            metaAttributes: [.foregroundColor: Theme.metaColor]
        )

        cachedStyleSignature = signature
        cachedStyles = styles
        return styles
    }

    private func probeRange(for editedRange: NSRange, fullRange: NSRange) -> NSRange {
        guard editedRange.length == 0 else { return editedRange }

        let location = min(editedRange.location, max(0, fullRange.length - 1))
        return NSRange(location: location, length: 1)
    }

    private func paragraphMayAffectCodeBlockState(_ range: NSRange, in text: NSString) -> Bool {
        guard range.length > 0 else { return false }

        var location = range.location
        let end = NSMaxRange(range)

        while location < end {
            let fullLineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let lineRange = NSIntersectionRange(fullLineRange, range)
            let lineContentRange = contentRange(forLineRange: lineRange, in: text)
            if fenceMarker(for: lineContentRange, in: text) != nil {
                return true
            }

            let nextLocation = NSMaxRange(fullLineRange)
            guard nextLocation > location else { break }
            location = nextLocation
        }

        return false
    }

    /// The fenced code block that contains `location`, including the position
    /// just past the closing fence's content (the fence line's terminator).
    private func codeBlockRange(containing location: Int, in text: NSString) -> NSRange? {
        var matchedRange: NSRange?

        enumerateCodeBlocks(in: text) { range in
            // Blocks arrive in document order, so once one starts past the
            // location no later block can contain it.
            guard range.location <= location else { return false }

            if NSLocationInRange(location, range) || location == NSMaxRange(range) {
                matchedRange = range
                return false
            }
            return true
        }

        return matchedRange
    }

    /// Walks the document once, reporting every fenced code block in order:
    /// from the start of its opening fence line through the end of its closing
    /// fence's content, or through the end of the text when it is never
    /// closed. A block closes only on a fence that matches its opening marker.
    /// The body returns `false` to stop early.
    private func enumerateCodeBlocks(in text: NSString, _ body: (NSRange) -> Bool) {
        var openingFence: FenceMarker?
        var blockStart = 0

        enumerateLines(in: text) { lineRange, contentRange in
            guard let marker = fenceMarker(for: contentRange, in: text) else { return true }

            if let opening = openingFence {
                guard marker.closes(opening) else { return true }

                openingFence = nil
                let range = NSRange(location: blockStart, length: max(0, NSMaxRange(contentRange) - blockStart))
                return body(range)
            }

            openingFence = marker
            blockStart = lineRange.location
            return true
        }

        if openingFence != nil {
            let range = NSRange(location: blockStart, length: max(0, text.length - blockStart))
            _ = body(range)
        }
    }

    private func enumerateLines(
        in text: NSString,
        _ body: (NSRange, NSRange) -> Bool
    ) {
        guard text.length > 0 else { return }

        var location = 0
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let contentRange = contentRange(forLineRange: lineRange, in: text)
            guard body(lineRange, contentRange) else { return }

            let nextLocation = NSMaxRange(lineRange)
            guard nextLocation > location else { return }
            location = nextLocation
        }
    }

    private func contentRange(forLineRange lineRange: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location, isNewline(text.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: lineRange.location, length: end - lineRange.location)
    }

    /// Recognizes a fence line: optional leading whitespace followed by a run
    /// of at least three backticks or tildes (anything after the run, such as
    /// a language tag, is ignored). The run's character and length are what a
    /// closing fence is matched against, in line with the preview, metadata
    /// parser and link extractor.
    private func fenceMarker(for range: NSRange, in text: NSString) -> FenceMarker? {
        let start = skipLeadingWhitespace(in: range, text: text)
        let end = NSMaxRange(range)
        guard start < end else { return nil }

        let character = text.character(at: start)
        guard character == 96 || character == 126 else { return nil }

        var location = start
        while location < end, text.character(at: location) == character {
            location += 1
        }

        let length = location - start
        return length >= 3 ? FenceMarker(character: character, length: length) : nil
    }

    private func headingLevel(for range: NSRange, in text: NSString) -> Int? {
        guard range.length >= 2 else { return nil }
        guard text.character(at: range.location) == 35 else { return nil }

        var location = range.location
        var hashCount = 0
        let end = NSMaxRange(range)

        while location < end, text.character(at: location) == 35, hashCount < 6 {
            hashCount += 1
            location += 1
        }

        guard hashCount > 0, location < end else { return nil }
        return isWhitespace(text.character(at: location)) ? hashCount : nil
    }

    private func isBlockquoteLine(_ range: NSRange, in text: NSString) -> Bool {
        guard range.length > 0 else { return false }
        return text.character(at: range.location) == 62
    }

    private func unorderedListMarkerRange(for range: NSRange, in text: NSString) -> NSRange? {
        let markerLocation = skipLeadingWhitespace(in: range, text: text)
        guard markerLocation < NSMaxRange(range) else { return nil }

        let marker = text.character(at: markerLocation)
        guard marker == 45 || marker == 42 || marker == 43 else { return nil }

        let whitespaceLocation = markerLocation + 1
        guard whitespaceLocation < NSMaxRange(range), isWhitespace(text.character(at: whitespaceLocation)) else {
            return nil
        }

        return NSRange(location: range.location, length: whitespaceLocation + 1 - range.location)
    }

    private func orderedListMarkerRange(for range: NSRange, in text: NSString) -> NSRange? {
        var location = skipLeadingWhitespace(in: range, text: text)
        let end = NSMaxRange(range)
        let firstDigitLocation = location

        while location < end, isDigit(text.character(at: location)) {
            location += 1
        }

        guard location > firstDigitLocation, location + 1 < end else { return nil }
        guard text.character(at: location) == 46, isWhitespace(text.character(at: location + 1)) else {
            return nil
        }

        return NSRange(location: range.location, length: location + 2 - range.location)
    }

    private func isHorizontalRuleLine(_ range: NSRange, in text: NSString) -> Bool {
        guard range.length > 0, !isWhitespace(text.character(at: range.location)) else { return false }

        var markerCount = 0
        var location = range.location
        let end = NSMaxRange(range)

        while location < end {
            let character = text.character(at: location)
            if character == 45 || character == 42 || character == 95 {
                markerCount += 1
            } else if !isWhitespace(character) {
                return false
            }
            location += 1
        }

        return markerCount >= 3
    }

    private func skipLeadingWhitespace(in range: NSRange, text: NSString) -> Int {
        var location = range.location
        let end = NSMaxRange(range)
        while location < end, isWhitespace(text.character(at: location)) {
            location += 1
        }
        return location
    }

    private func isWhitespace(_ character: unichar) -> Bool {
        character == 32 || character == 9
    }

    private func isNewline(_ character: unichar) -> Bool {
        character == 10 || character == 13
    }

    private func isDigit(_ character: unichar) -> Bool {
        character >= 48 && character <= 57
    }

    private func subtractRanges(_ exclusions: [NSRange], from full: NSRange) -> [NSRange] {
        let sorted = exclusions.sorted { $0.location < $1.location }
        var result: [NSRange] = []
        var pos = full.location
        for ex in sorted {
            if ex.location > pos {
                result.append(NSRange(location: pos, length: ex.location - pos))
            }
            pos = ex.location + ex.length
        }
        let end = full.location + full.length
        if pos < end {
            result.append(NSRange(location: pos, length: end - pos))
        }
        return result
    }
}

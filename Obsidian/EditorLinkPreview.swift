import AppKit
import SwiftUI
@preconcurrency import WebKit

enum EditorLinkPreviewKind: Equatable {
    case xPost(username: String, statusID: String)
    case youtube(videoID: String)
}

struct EditorLinkPreview: Equatable, Identifiable {
    let url: URL
    let kind: EditorLinkPreviewKind
    let label: String?
    let sourceRange: NSRange
    let paragraphRange: NSRange
    var occurrence: Int = 0

    var id: String {
        "\(url.absoluteString)#\(occurrence)"
    }

    var title: String {
        switch kind {
        case .xPost(let username, _):
            return label?.nilIfEmpty ?? "@\(username) on X"
        case .youtube:
            return label?.nilIfEmpty ?? "YouTube video"
        }
    }

    var subtitle: String {
        switch kind {
        case .xPost(let username, let statusID):
            return "@\(username) · Post \(statusID)"
        case .youtube(let videoID):
            return "youtube.com · \(videoID)"
        }
    }

    /// Poster frames for the YouTube thumbnail card, best first.
    var thumbnailURLs: [URL] {
        guard case .youtube(let videoID) = kind else { return [] }
        return YouTubeThumbnail.urls(videoID: videoID)
    }

    var youtubeStartSeconds: Int? {
        guard case .youtube = kind,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawValue = components.queryItems?
                .first(where: { $0.name.lowercased() == "t" || $0.name.lowercased() == "start" })?
                .value else {
            return nil
        }
        return Self.parseYouTubeTime(rawValue)
    }

    /// Compiled once: `youtubeStartSeconds` runs on every update of every visible card.
    private static let youtubeTimeExpression = try! NSRegularExpression(
        pattern: #"^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$"#,
        options: [.caseInsensitive]
    )

    private static func parseYouTubeTime(_ rawValue: String) -> Int? {
        if let seconds = Int(rawValue), seconds >= 0 {
            return seconds
        }

        let range = NSRange(rawValue.startIndex..<rawValue.endIndex, in: rawValue)
        guard let match = youtubeTimeExpression.firstMatch(in: rawValue, range: range),
              match.range == range else {
            return nil
        }

        func component(at index: Int) -> Int {
            guard match.range(at: index).location != NSNotFound,
                  let swiftRange = Range(match.range(at: index), in: rawValue) else {
                return 0
            }
            return Int(rawValue[swiftRange]) ?? 0
        }

        let seconds = component(at: 1) * 3_600 + component(at: 2) * 60 + component(at: 3)
        return seconds > 0 ? seconds : nil
    }
}

enum EditorLinkPreviewDetector {
    private static let markdownLinkRegex = try! NSRegularExpression(
        pattern: #"(!?)\[([^\]]*)\]\((https?://[^)\s]+)\)"#,
        options: [.caseInsensitive]
    )
    private static let bareLinkRegex = try! NSRegularExpression(
        pattern: #"https?://[^\s<>\"]+"#,
        options: [.caseInsensitive]
    )
    private static let standaloneMarkerRegex = try! NSRegularExpression(
        pattern: #"^(?:>\s*)?(?:(?:[-+*]|\d+[.)])\s*)?$"#
    )

    static func previews(in markdown: String) -> [EditorLinkPreview] {
        let text = markdown as NSString
        guard text.length > 0 else { return [] }

        var results: [EditorLinkPreview] = []
        var occurrencesByURL: [String: Int] = [:]
        var location = 0
        var insideFence = false

        while location < text.length {
            let paragraphRange = text.paragraphRange(for: NSRange(location: location, length: 0))
            let contentRange = lineContentRange(paragraphRange, in: text)
            let line = text.substring(with: contentRange)
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") {
                insideFence.toggle()
            } else if !insideFence,
                      var preview = firstPreview(
                        in: text,
                        contentRange: contentRange,
                        paragraphRange: paragraphRange
                      ) {
                let key = preview.url.absoluteString
                preview.occurrence = occurrencesByURL[key, default: 0]
                occurrencesByURL[key, default: 0] += 1
                results.append(preview)
            }

            let next = NSMaxRange(paragraphRange)
            guard next > location else { break }
            location = next
        }

        return results
    }

    /// Detection remains intentionally broad because it is shared with the
    /// canonical Markdown link parser. Presentation is narrower: large cards
    /// belong only to links that own their line.
    static func presentationPreviews(in markdown: String) -> [EditorLinkPreview] {
        let text = markdown as NSString
        return previews(in: markdown).filter { preview in
            isStandalonePreview(
                sourceRange: preview.sourceRange,
                contentRange: lineContentRange(preview.paragraphRange, in: text),
                in: text
            )
        }
    }

    private static func firstPreview(
        in text: NSString,
        contentRange: NSRange,
        paragraphRange: NSRange
    ) -> EditorLinkPreview? {
        let fullText = text as String
        let markdownMatches = markdownLinkRegex.matches(in: fullText, range: contentRange)

        for match in markdownMatches {
            guard match.numberOfRanges >= 4 else { continue }
            let label = text.substring(with: match.range(at: 2))
            let urlRange = match.range(at: 3)
            guard let url = normalizedURL(text.substring(with: urlRange)),
                  let kind = previewKind(for: url) else {
                continue
            }
            return EditorLinkPreview(
                url: url,
                kind: kind,
                label: label,
                sourceRange: match.range,
                paragraphRange: paragraphRange
            )
        }

        for match in bareLinkRegex.matches(in: fullText, range: contentRange) {
            if markdownMatches.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) {
                continue
            }

            let rawURL = text.substring(with: match.range)
            let trimmedURL = rawURL.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
            guard let url = normalizedURL(trimmedURL),
                  let kind = previewKind(for: url) else {
                continue
            }
            let trimmedLength = (trimmedURL as NSString).length
            let sourceRange = NSRange(location: match.range.location, length: trimmedLength)
            return EditorLinkPreview(
                url: url,
                kind: kind,
                label: nil,
                sourceRange: sourceRange,
                paragraphRange: paragraphRange
            )
        }

        return nil
    }

    /// Inline links should read like ordinary prose. Large embeds are reserved
    /// for a URL that owns its line; otherwise a card turns a sentence or list
    /// item into disconnected fragments. Lightweight wrappers and a list/quote
    /// marker are treated as presentation syntax, not surrounding commentary.
    private static func isStandalonePreview(
        sourceRange: NSRange,
        contentRange: NSRange,
        in text: NSString
    ) -> Bool {
        let leadingRange = NSRange(
            location: contentRange.location,
            length: max(0, sourceRange.location - contentRange.location)
        )
        let trailingStart = NSMaxRange(sourceRange)
        let trailingRange = NSRange(
            location: trailingStart,
            length: max(0, NSMaxRange(contentRange) - trailingStart)
        )
        var remainder = text.substring(with: leadingRange) + text.substring(with: trailingRange)

        for wrapper in ["<u>", "</u>", "<U>", "</U>", "**", "__"] {
            remainder = remainder.replacingOccurrences(of: wrapper, with: "")
        }
        remainder = remainder.trimmingCharacters(in: .whitespaces)
        remainder = remainder.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))

        guard !remainder.isEmpty else { return true }
        let range = NSRange(location: 0, length: (remainder as NSString).length)
        return standaloneMarkerRegex.firstMatch(in: remainder, range: range)?.range == range
    }

    private static func normalizedURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            return nil
        }
        return components.url
    }

    private static func previewKind(for url: URL) -> EditorLinkPreviewKind? {
        guard let host = url.host?.lowercased() else { return nil }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        if normalizedHost == "x.com"
            || normalizedHost == "twitter.com"
            || normalizedHost == "mobile.twitter.com" {
            guard pathComponents.count >= 3,
                  pathComponents[1].lowercased() == "status",
                  !pathComponents[0].isEmpty,
                  !pathComponents[2].isEmpty,
                  pathComponents[2].allSatisfy(\.isNumber) else {
                return nil
            }
            return .xPost(username: pathComponents[0], statusID: pathComponents[2])
        }

        if normalizedHost == "youtu.be" {
            guard let videoID = pathComponents.first, isValidYouTubeID(videoID) else { return nil }
            return .youtube(videoID: videoID)
        }

        if normalizedHost == "youtube.com"
            || normalizedHost == "m.youtube.com"
            || normalizedHost == "youtube-nocookie.com" {
            if pathComponents.first?.lowercased() == "watch",
               let videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value,
               isValidYouTubeID(videoID) {
                return .youtube(videoID: videoID)
            }

            if pathComponents.count >= 2,
               ["shorts", "embed", "live"].contains(pathComponents[0].lowercased()),
               isValidYouTubeID(pathComponents[1]) {
                return .youtube(videoID: pathComponents[1])
            }
        }

        return nil
    }

    private static func isValidYouTubeID(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func lineContentRange(_ paragraphRange: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(paragraphRange)
        while end > paragraphRange.location {
            let character = text.character(at: end - 1)
            if character == 10 || character == 13 {
                end -= 1
            } else {
                break
            }
        }
        return NSRange(location: paragraphRange.location, length: end - paragraphRange.location)
    }
}

/// Keeps the visible text line fixed while attributes above it change the
/// document's layout. Preserving the raw scroll offset is not enough here: an
/// embed growing above the viewport moves the caret even when that offset is
/// restored exactly.
@MainActor
struct EditorViewportAnchor {
    private enum VerticalPosition {
        case line(characterLocation: Int, offset: CGFloat)
        case documentBottom
    }

    private let verticalPosition: VerticalPosition
    private let horizontalOrigin: CGFloat

    static func capture(in textView: NSTextView) -> EditorViewportAnchor? {
        guard let scrollView = textView.enclosingScrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return nil
        }

        let visibleRect = scrollView.contentView.bounds
        let textLength = textView.textStorage?.length ?? 0
        let selection = textView.selectedRange()
        let selectionLocation = min(NSMaxRange(selection), textLength)
        ensureLayout(
            at: selectionLocation,
            in: textView,
            layoutManager: layoutManager,
            textContainer: textContainer
        )

        let anchorLocation: Int
        let anchorFrame: NSRect
        if let selectionFrame = lineFrame(
            at: selectionLocation,
            in: textView,
            layoutManager: layoutManager,
            textContainer: textContainer
        ), selectionFrame.intersects(visibleRect) {
            anchorLocation = selectionLocation
            anchorFrame = selectionFrame
        } else {
            let containerOrigin = textView.textContainerOrigin
            let pointNearVisibleTop = CGPoint(
                x: 0,
                y: max(0, visibleRect.minY - containerOrigin.y + 1)
            )
            let location = min(
                layoutManager.characterIndex(
                    for: pointNearVisibleTop,
                    in: textContainer,
                    fractionOfDistanceBetweenInsertionPoints: nil
                ),
                textLength
            )
            guard let visibleLineFrame = lineFrame(
                at: location,
                in: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            ) else {
                return nil
            }
            anchorLocation = location
            anchorFrame = visibleLineFrame
        }

        let isVisibleCaretAtDocumentEnd =
            selection.length == 0
            && selection.location == textLength
            && anchorLocation == selectionLocation
            && anchorFrame.intersects(visibleRect)

        return EditorViewportAnchor(
            verticalPosition: isVisibleCaretAtDocumentEnd
                ? .documentBottom
                : .line(
                    characterLocation: anchorLocation,
                    offset: anchorFrame.minY - visibleRect.minY
                ),
            horizontalOrigin: visibleRect.minX
        )
    }

    func restore(in textView: NSTextView) {
        guard let scrollView = textView.enclosingScrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        let textLength = textView.textStorage?.length ?? 0
        let contentView = scrollView.contentView
        let desiredY: CGFloat

        switch verticalPosition {
        case .documentBottom:
            Self.ensureLayout(
                at: textLength,
                in: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            )
            desiredY = Self.documentHeight(
                for: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            ) - contentView.bounds.height

        case .line(let characterLocation, let verticalOffset):
            Self.ensureLayout(
                at: min(characterLocation, textLength),
                in: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            )
            guard let anchorFrame = Self.lineFrame(
                at: min(characterLocation, textLength),
                in: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            ) else {
                return
            }
            desiredY = anchorFrame.minY - verticalOffset
        }

        let documentHeight = Self.documentHeight(
            for: textView,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let maxX = max(0, textView.frame.width - contentView.bounds.width)
        let maxY = max(0, documentHeight - contentView.bounds.height)
        let origin = CGPoint(
            x: min(max(horizontalOrigin, 0), maxX),
            y: min(max(desiredY, 0), maxY)
        )

        contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(contentView)
    }

    /// `NSTextView` updates its document-view height one run-loop after some
    /// paragraph-spacing changes. An end caret needs one final bottom restore
    /// after that resize; otherwise the newly measured tail embed can leave the
    /// caret just below the viewport.
    func restoreAfterPendingLayout(in textView: NSTextView) {
        restore(in: textView)
        guard case .documentBottom = verticalPosition else { return }

        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            restore(in: textView)
        }
    }

    private static func ensureLayout(
        at characterLocation: Int,
        in textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) {
        let textLength = textView.textStorage?.length ?? 0
        guard textLength > 0 else {
            layoutManager.ensureLayout(forBoundingRect: .zero, in: textContainer)
            return
        }

        layoutManager.ensureLayout(
            forCharacterRange: NSRange(
                location: min(characterLocation, textLength - 1),
                length: 1
            )
        )
    }

    private static func documentHeight(
        for textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> CGFloat {
        max(
            textView.frame.height,
            layoutManager.usedRect(for: textContainer).maxY + textView.textContainerInset.height
        )
    }

    private static func lineFrame(
        at characterLocation: Int,
        in textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        let textLength = textView.textStorage?.length ?? 0
        let containerOrigin = textView.textContainerOrigin

        if characterLocation >= textLength,
           layoutManager.extraLineFragmentTextContainer === textContainer {
            return layoutManager.extraLineFragmentRect.offsetBy(
                dx: containerOrigin.x,
                dy: containerOrigin.y
            )
        }

        guard textLength > 0 else {
            let font = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            return NSRect(
                x: containerOrigin.x,
                y: containerOrigin.y,
                width: 0,
                height: layoutManager.defaultLineHeight(for: font)
            )
        }

        let characterIndex = min(characterLocation, textLength - 1)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: characterIndex, length: 1),
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }

        return layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil
        ).offsetBy(dx: containerOrigin.x, dy: containerOrigin.y)
    }
}

@MainActor
final class EditorLinkPreviewController {
    private static let initialXCardHeight: CGFloat = 220
    private static let cardTopSpacing: CGFloat = 2
    private static let cardBottomSpacing: CGFloat = 8
    private static let youtubeCardWidth: CGFloat = 640
    private static let xCardWidth: CGFloat = 550

    private let embedCache: EditorEmbedCache
    private let retainedOffscreenCardLimit: Int
    private var previews: [EditorLinkPreview] = []
    private var cardViews: [String: NSHostingView<EditorLinkPreviewCard>] = [:]
    private var attachedCardIDs: Set<String> = []
    private var cardAccessOrder: [String] = []
    private var measuredXCardHeights: [String: CGFloat] = [:]
    private var measuredXCardWidths: [String: Int] = [:]
    private var cardPreviews: [String: EditorLinkPreview] = [:]
    private var hoveredPreviewIDs: Set<String> = []
    /// The one wheel forwarder for every card in the text view; cards built
    /// here therefore opt out of `EmbedScrollForwarder`.
    private var scrollWheelMonitor: ScrollWheelMonitorToken?
    private var openURLHandler: ((URL) -> Void)?

    var visibleCardCount: Int {
        attachedCardIDs.count
    }

    var retainedCardCount: Int {
        cardViews.count
    }

    init(
        embedCache: EditorEmbedCache = .shared,
        retainedOffscreenCardLimit: Int = 6
    ) {
        self.embedCache = embedCache
        self.retainedOffscreenCardLimit = max(0, retainedOffscreenCardLimit)
    }

    deinit {
        if let scrollWheelMonitor {
            NSEvent.removeMonitor(scrollWheelMonitor.value)
        }
    }

    @discardableResult
    func refresh(
        in textView: NSTextView,
        openURL: @escaping (URL) -> Void
    ) -> Int {
        let viewportAnchor = EditorViewportAnchor.capture(in: textView)
        installScrollWheelForwarding(in: textView)
        clearSourcePresentation(in: textView)
        previews = EditorLinkPreviewDetector.presentationPreviews(in: textView.string)
        openURLHandler = openURL
        let activeIDs = Set(previews.map(\.id))
        pruneInactiveCards(activeIDs: activeIDs)
        measuredXCardHeights = measuredXCardHeights.filter { activeIDs.contains($0.key) }
        measuredXCardWidths = measuredXCardWidths.filter { activeIDs.contains($0.key) }
        restoreCachedXHeights(in: textView)
        hoveredPreviewIDs.formIntersection(activeIDs)
        let spacingUpdateCount = applyReservedSpacing(in: textView)
        updateSourcePresentation(in: textView)
        viewportAnchor?.restoreAfterPendingLayout(in: textView)
        layoutCards(in: textView)
        return spacingUpdateCount
    }

    func selectionDidChange(in textView: NSTextView) {
        updateSourcePresentation(in: textView)
    }

    func layoutCards(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        let containerOrigin = textView.textContainerOrigin
        let availableWidth = max(0, textContainer.containerSize.width)
        if restoreCachedXHeights(in: textView) {
            let anchor = EditorViewportAnchor.capture(in: textView)
            applyReservedSpacing(in: textView)
            anchor?.restoreAfterPendingLayout(in: textView)
        }
        updateDocumentMinimumHeight(
            in: textView,
            layoutManager: layoutManager,
            containerOrigin: containerOrigin,
            availableWidth: availableWidth
        )
        let visibleRect = textView.visibleRect
        let maximumCardFootprint = max(
            Self.youtubeCardWidth * 9 / 16,
            measuredXCardHeights.values.max() ?? Self.initialXCardHeight
        ) + Self.cardTopSpacing + Self.cardBottomSpacing
        let candidateRect = NSRect(
            x: 0,
            y: max(0, visibleRect.minY - containerOrigin.y - maximumCardFootprint),
            width: availableWidth,
            height: visibleRect.height + maximumCardFootprint
        )
        layoutManager.ensureLayout(forBoundingRect: candidateRect, in: textContainer)
        let candidateGlyphRange = layoutManager.glyphRange(
            forBoundingRect: candidateRect,
            in: textContainer
        )
        let candidateCharacterRange = layoutManager.characterRange(
            forGlyphRange: candidateGlyphRange,
            actualGlyphRange: nil
        )
        let visiblePreviews = Array(previews.lazy.filter { preview in
            NSIntersectionRange(preview.paragraphRange, candidateCharacterRange).length > 0
        }.filter { preview in
            self.frame(
                for: preview,
                layoutManager: layoutManager,
                containerOrigin: containerOrigin,
                availableWidth: availableWidth
            )?.intersects(visibleRect) == true
        })

        synchronizeCards(for: visiblePreviews, in: textView)

        for preview in visiblePreviews {
            guard let card = cardViews[preview.id],
                  let cardFrame = frame(
                    for: preview,
                    layoutManager: layoutManager,
                    containerOrigin: containerOrigin,
                    availableWidth: availableWidth
                  ) else {
                continue
            }
            card.frame = cardFrame
        }
    }

    func removeAll() {
        if let scrollWheelMonitor {
            NSEvent.removeMonitor(scrollWheelMonitor.value)
            self.scrollWheelMonitor = nil
        }
        cardViews.values.forEach { detachCard($0) }
        cardViews.removeAll()
        attachedCardIDs.removeAll()
        cardAccessOrder.removeAll()
        measuredXCardHeights.removeAll()
        measuredXCardWidths.removeAll()
        cardPreviews.removeAll()
        hoveredPreviewIDs.removeAll()
        openURLHandler = nil
        previews.removeAll()
    }

    private func installScrollWheelForwarding(in textView: NSTextView) {
        guard scrollWheelMonitor == nil else { return }

        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: {
            [weak self, weak textView] event in
            guard let self,
                  let textView,
                  event.window === textView.window,
                  let scrollView = textView.enclosingScrollView else {
                return event
            }

            let point = textView.convert(event.locationInWindow, from: nil)
            let isOverEmbed = self.attachedCardIDs.contains { id in
                guard let card = self.cardViews[id] else { return false }
                return !card.isHiddenOrHasHiddenAncestor && card.frame.contains(point)
            }
            guard isOverEmbed else { return event }

            scrollView.scrollWheel(with: event)
            return nil
        }) else { return }
        scrollWheelMonitor = ScrollWheelMonitorToken(monitor)
    }

    @discardableResult
    private func applyReservedSpacing(in textView: NSTextView) -> Int {
        guard let storage = textView.textStorage, storage.length > 0 else { return 0 }
        let availableWidth = max(
            0,
            textView.textContainer?.containerSize.width ?? Self.youtubeCardWidth
        )

        var updates: [(range: NSRange, style: NSMutableParagraphStyle)] = []
        for preview in previews {
            guard preview.paragraphRange.length > 0,
                  NSMaxRange(preview.paragraphRange) <= storage.length else {
                continue
            }
            let current = storage.attribute(
                .paragraphStyle,
                at: preview.paragraphRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            let desiredSpacing =
                height(for: preview, availableWidth: availableWidth)
                    + Self.cardTopSpacing
                    + Self.cardBottomSpacing
            guard abs((current?.paragraphSpacing ?? 0) - desiredSpacing) > 0.5 else {
                continue
            }

            let style = (current?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.paragraphSpacing = desiredSpacing
            updates.append((preview.paragraphRange, style))
        }

        guard !updates.isEmpty else { return 0 }

        storage.beginEditing()
        for update in updates {
            storage.addAttribute(.paragraphStyle, value: update.style, range: update.range)
        }
        storage.endEditing()
        return updates.count
    }

    /// AppKit omits `paragraphSpacing` after the document's final paragraph.
    /// Link cards normally live inside that spacing, so a card attached to the
    /// last line can extend beyond the NSTextView's document frame and become
    /// impossible to reach by scrolling. Keep the document view tall enough to
    /// contain that terminal overlay explicitly.
    private func updateDocumentMinimumHeight(
        in textView: NSTextView,
        layoutManager: NSLayoutManager,
        containerOrigin: CGPoint,
        availableWidth: CGFloat
    ) {
        guard let scrollView = textView.enclosingScrollView else { return }

        var requiredHeight = scrollView.contentSize.height
        let textLength = textView.textStorage?.length ?? 0
        if let terminalPreview = previews.last(where: {
            NSMaxRange($0.paragraphRange) >= textLength
        }) {
            layoutManager.ensureLayout(
                forCharacterRange: terminalPreview.sourceRange
            )
            if let terminalCardFrame = frame(
                for: terminalPreview,
                layoutManager: layoutManager,
                containerOrigin: containerOrigin,
                availableWidth: availableWidth
            ) {
                requiredHeight = max(
                    requiredHeight,
                    terminalCardFrame.maxY + Self.cardBottomSpacing
                )
            }
        }

        requiredHeight = ceil(requiredHeight)
        guard abs(textView.minSize.height - requiredHeight) > 0.5 else { return }

        textView.minSize.height = requiredHeight
        textView.sizeToFit()
    }

    private func synchronizeCards(
        for visiblePreviews: [EditorLinkPreview],
        in textView: NSTextView
    ) {
        guard openURLHandler != nil else { return }
        let visibleIDs = Set(visiblePreviews.map(\.id))
        let offscreenIDs = attachedCardIDs.filter { !visibleIDs.contains($0) }
        for id in offscreenIDs {
            if let card = cardViews[id] { detachCard(card) }
            attachedCardIDs.remove(id)
        }

        for preview in visiblePreviews {
            if let existing = cardViews[preview.id], cardPreviews[preview.id] == preview {
                if existing.superview !== textView { textView.addSubview(existing) }
                EmbedViewLifecycle.setPresented(true, in: existing)
                attachedCardIDs.insert(preview.id)
                markCardRecentlyUsed(preview.id)
                continue
            }
            let card = EditorLinkPreviewCard(
                preview: preview,
                openURL: { [weak self] url in self?.openURLHandler?(url) },
                xEmbedHeightChanged: { [weak self, weak textView] height in
                    guard let self, let textView else { return }
                    self.updateXEmbedHeight(height, for: preview, in: textView)
                },
                xHoverChanged: { [weak self, weak textView] isHovering in
                    guard let self, let textView else { return }
                    self.setHover(isHovering, for: preview, in: textView)
                },
                youtubeHoverChanged: { [weak self, weak textView] isHovering in
                    guard let self, let textView else { return }
                    self.setHover(isHovering, for: preview, in: textView)
                },
                forwardsScrollWheel: false
            )
            if let existing = cardViews[preview.id] {
                existing.rootView = card
                if existing.superview !== textView {
                    textView.addSubview(existing)
                }
            } else {
                let hostingView = NSHostingView(rootView: card)
                hostingView.wantsLayer = true
                textView.addSubview(hostingView)
                cardViews[preview.id] = hostingView
            }
            cardPreviews[preview.id] = preview
            if let view = cardViews[preview.id] { EmbedViewLifecycle.setPresented(true, in: view) }
            attachedCardIDs.insert(preview.id)
            markCardRecentlyUsed(preview.id)
        }
        trimRetainedOffscreenCards()
    }

    private func pruneInactiveCards(activeIDs: Set<String>) {
        let inactiveIDs = cardViews.keys.filter { !activeIDs.contains($0) }
        for id in inactiveIDs {
            if let view = cardViews.removeValue(forKey: id) { detachCard(view) }
            cardPreviews.removeValue(forKey: id)
            attachedCardIDs.remove(id)
        }
        cardAccessOrder.removeAll { !activeIDs.contains($0) }
    }

    private func markCardRecentlyUsed(_ id: String) {
        cardAccessOrder.removeAll { $0 == id }
        cardAccessOrder.append(id)
    }

    private func trimRetainedOffscreenCards() {
        let detachedIDs = cardAccessOrder.filter { !attachedCardIDs.contains($0) }
        let removalCount = max(0, detachedIDs.count - retainedOffscreenCardLimit)
        for id in detachedIDs.prefix(removalCount) {
            if let view = cardViews.removeValue(forKey: id) { detachCard(view) }
            cardPreviews.removeValue(forKey: id)
            cardAccessOrder.removeAll { $0 == id }
        }
    }

    private func detachCard(_ view: NSView) {
        EmbedViewLifecycle.setPresented(false, in: view)
        view.removeFromSuperview()
    }

    @discardableResult
    private func restoreCachedXHeights(in textView: NSTextView) -> Bool {
        let width = min(Self.xCardWidth, textView.textContainer?.containerSize.width ?? Self.xCardWidth)
        let widthKey = Int(max(1, width).rounded())
        var changed = false
        for preview in previews {
            guard case .xPost(_, let statusID) = preview.kind,
                  measuredXCardWidths[preview.id] != widthKey else { continue }
            measuredXCardWidths[preview.id] = widthKey
            measuredXCardHeights[preview.id] = max(Self.initialXCardHeight,
                embedCache.xHeight(for: statusID, width: width) ?? Self.initialXCardHeight)
            changed = true
        }
        return changed
    }

    private func frame(
        for preview: EditorLinkPreview,
        layoutManager: NSLayoutManager,
        containerOrigin: CGPoint,
        availableWidth: CGFloat
    ) -> NSRect? {
        guard preview.sourceRange.length > 0,
              let textStorage = layoutManager.textStorage else {
            return nil
        }

        // Paragraph spacing reserves the card's footprint after the complete
        // paragraph. Anchor the overlay there as well. Using the URL's last
        // glyph puts the card on top of any prose that follows the URL and
        // wraps onto later visual lines in the same paragraph.
        let paragraphStart = preview.paragraphRange.location
        var paragraphContentEnd = min(
            NSMaxRange(preview.paragraphRange),
            textStorage.length
        )
        let text = textStorage.string as NSString
        while paragraphContentEnd > paragraphStart {
            let character = text.character(at: paragraphContentEnd - 1)
            guard character == 10 || character == 13 else { break }
            paragraphContentEnd -= 1
        }
        let anchorRange = paragraphContentEnd > paragraphStart
            ? NSRange(location: paragraphContentEnd - 1, length: 1)
            : preview.sourceRange
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: anchorRange,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }

        let lastGlyph = max(glyphRange.location, NSMaxRange(glyphRange) - 1)
        let lineRect = layoutManager.lineFragmentUsedRect(
            forGlyphAt: lastGlyph,
            effectiveRange: nil
        )
        return NSRect(
            x: containerOrigin.x,
            y: containerOrigin.y + lineRect.maxY + Self.cardTopSpacing,
            width: min(width(for: preview), availableWidth),
            height: height(for: preview, availableWidth: availableWidth)
        )
    }

    private func width(for preview: EditorLinkPreview) -> CGFloat {
        switch preview.kind {
        case .xPost:
            return Self.xCardWidth
        case .youtube:
            return Self.youtubeCardWidth
        }
    }

    private func height(for preview: EditorLinkPreview, availableWidth: CGFloat) -> CGFloat {
        switch preview.kind {
        case .xPost:
            return measuredXCardHeights[preview.id] ?? Self.initialXCardHeight
        case .youtube:
            let playerWidth = min(Self.youtubeCardWidth, availableWidth)
            return max(200, playerWidth * 9 / 16)
        }
    }

    private func setHover(
        _ isHovering: Bool,
        for preview: EditorLinkPreview,
        in textView: NSTextView
    ) {
        if isHovering {
            hoveredPreviewIDs.insert(preview.id)
        } else {
            hoveredPreviewIDs.remove(preview.id)
        }
        updateSourcePresentation(in: textView)
    }

    private func updateSourcePresentation(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let selection = textView.selectedRange()

        for preview in previews {
            clearTemporarySourceAttributes(for: preview, in: layoutManager)
            guard !hoveredPreviewIDs.contains(preview.id),
                  !selectionTouches(preview.paragraphRange, selection: selection) else {
                continue
            }

            layoutManager.addTemporaryAttributes(
                [
                    .foregroundColor: NSColor.clear,
                    .underlineColor: NSColor.clear,
                    .underlineStyle: 0
                ],
                forCharacterRange: preview.sourceRange
            )
        }
    }

    private func clearSourcePresentation(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        for preview in previews {
            clearTemporarySourceAttributes(for: preview, in: layoutManager)
        }
    }

    private func clearTemporarySourceAttributes(
        for preview: EditorLinkPreview,
        in layoutManager: NSLayoutManager
    ) {
        for key in [
            NSAttributedString.Key.foregroundColor,
            .underlineColor,
            .underlineStyle
        ] {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: preview.sourceRange)
        }
    }

    private func selectionTouches(_ paragraphRange: NSRange, selection: NSRange) -> Bool {
        if selection.length > 0 {
            return NSIntersectionRange(paragraphRange, selection).length > 0
        }
        return selection.location >= paragraphRange.location
            && selection.location < NSMaxRange(paragraphRange)
    }

    private func updateXEmbedHeight(
        _ reportedHeight: CGFloat,
        for preview: EditorLinkPreview,
        in textView: NSTextView
    ) {
        guard case .xPost = preview.kind, reportedHeight.isFinite, reportedHeight > 0 else { return }
        guard reportedHeight <= 100_000 else { return }
        let height = max(Self.initialXCardHeight, ceil(reportedHeight) + 4)
        guard abs((measuredXCardHeights[preview.id] ?? 0) - height) > 2 else { return }

        let viewportAnchor = EditorViewportAnchor.capture(in: textView)
        measuredXCardHeights[preview.id] = height
        if case .xPost(_, let statusID) = preview.kind {
            let width = min(Self.xCardWidth, textView.textContainer?.containerSize.width ?? Self.xCardWidth)
            embedCache.saveXHeight(height, for: statusID, width: width)
        }
        applyReservedSpacing(in: textView)
        viewportAnchor?.restoreAfterPendingLayout(in: textView)
        layoutCards(in: textView)
    }
}

enum YouTubeEmbedURL {
    static func url(videoID: String, startSeconds: Int?, origin: URL? = nil) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !videoID.isEmpty, videoID.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube-nocookie.com"
        components.path = "/embed/\(videoID)"
        components.queryItems = [
            URLQueryItem(name: "autoplay", value: "0"),
            URLQueryItem(name: "controls", value: "1"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "rel", value: "0")
        ]
        if let startSeconds, startSeconds > 0 {
            components.queryItems?.append(
                URLQueryItem(name: "start", value: String(startSeconds))
            )
        }
        if let origin {
            components.queryItems?.append(URLQueryItem(name: "enablejsapi", value: "1"))
            components.queryItems?.append(URLQueryItem(name: "origin", value: origin.absoluteString))
        }
        return components.url
    }
}

/// YouTube publishes poster frames at fixed paths. `maxresdefault` (1280×720)
/// exists only for HD uploads; `hqdefault` (480×360, letterboxed) exists for
/// every public video, so it is the fallback.
enum YouTubeThumbnail {
    static func urls(videoID: String) -> [URL] {
        guard !videoID.isEmpty, videoID.utf8.count <= 64,
              videoID.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
        else { return [] }
        return ["maxresdefault", "hqdefault"].compactMap { URL(string: "https://i.ytimg.com/vi/\(videoID)/\($0).jpg") }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

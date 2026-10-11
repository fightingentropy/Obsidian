import AppKit
import SwiftUI
import Textual
import WebKit

enum PreviewURLPolicy {
    private static let externallyOpenableSchemes: Set<String> = [
        "http", "https", "mailto"
    ]

    static func canOpenExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return externallyOpenableSchemes.contains(scheme)
    }

    static func internalVaultFile(_ url: URL, vaultURL: URL?) -> URL? {
        guard let resolvedURL = fileInsideVault(url, vaultURL: vaultURL),
              Workspace.isMarkdownFile(resolvedURL) || Workspace.isImageFile(resolvedURL) else {
            return nil
        }
        return resolvedURL
    }

    /// Any regular file contained by the vault (or equal to the vault root).
    static func fileInsideVault(_ url: URL, vaultURL: URL?) -> URL? {
        guard url.isFileURL, let vaultURL else { return nil }
        let resolvedVault = vaultURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let isInside = resolvedURL.path == resolvedVault.path
            || resolvedURL.path.hasPrefix(resolvedVault.path + "/")
        guard isInside, FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return nil
        }
        return resolvedURL
    }
}

struct MarkdownPreview: View {
    let markdown: String
    let documentURL: URL?
    let vaultURL: URL?
    let assetLookupByFilename: [String: [URL]]
    let preferences: AppPreferences
    let onOpenInternalFile: (URL) -> Void

    private var context: PreviewContext {
        PreviewContext(
            documentURL: documentURL,
            vaultURL: vaultURL,
            assetLookupByFilename: assetLookupByFilename
        )
    }

    var body: some View {
        let document = MarkdownPreprocessor.preprocessCached(markdown, context: context)
        switch document.preferredRenderMode {
        case .embedded:
            EmbeddedMarkdownPreview(document: document, preferences: preferences, onOpenInternalFile: onOpenInternalFile)
        case .native:
            NativeMarkdownPreview(
                markdown: markdown,
                context: context,
                preferences: preferences,
                onOpenInternalFile: onOpenInternalFile
            )
        case .html:
            HTMLMarkdownPreview(
                document: document,
                preferences: preferences,
                onOpenInternalFile: onOpenInternalFile
            )
        }
    }
}

private struct NativeMarkdownPreview: View {
    let markdown: String
    let context: PreviewContext
    let preferences: AppPreferences
    let onOpenInternalFile: (URL) -> Void

    var body: some View {
        ScrollView {
            NativeMarkdownContent(markdown: markdown, context: context, preferences: preferences)
                .padding(.horizontal, 72)
                .padding(.top, 48)
                .padding(.bottom, 120)
                .frame(maxWidth: preferences.previewPageWidthCGFloat, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.openURL, OpenURLAction { url in
            if let internalURL = PreviewURLPolicy.internalVaultFile(url, vaultURL: context.vaultURL) {
                onOpenInternalFile(internalURL)
                return .handled
            }
            guard PreviewURLPolicy.canOpenExternally(url) else {
                NSSound.beep()
                return .discarded
            }

            return NSWorkspace.shared.open(url) ? .handled : .discarded
        })
    }
}

private struct NativeMarkdownContent: View {
    let markdown: String
    let context: PreviewContext
    let preferences: AppPreferences

    private var inlineStyle: InlineStyle {
        InlineStyle.gitHub.code(
            .font(preferences.previewCodeFontChoice.swiftUIFont(size: preferences.previewCodeFontSizeCGFloat)),
            .backgroundColor(Color(nsColor: .quaternaryLabelColor).opacity(0.22))
        )
    }

    var body: some View {
            StructuredText(markdown, parser: NativePreviewMarkupParser(context: context))
                .font(preferences.previewFontChoice.swiftUIFont(size: preferences.previewFontSizeCGFloat))
                .textual.structuredTextStyle(.gitHub)
                .textual.inlineStyle(inlineStyle)
                .textual.codeBlockStyle(ConfigurablePreviewCodeBlockStyle(preferences: preferences))
                .textual.imageAttachmentLoader(PreviewImageAttachmentLoader(context: context))
                .textual.overflowMode(.wrap)
    }
}

private struct EmbeddedMarkdownPreview: View {
    let document: PreviewDocument
    let preferences: AppPreferences
    let onOpenInternalFile: (URL) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // Keyed by structural identities (see
                // `PreviewDocument.identifiedSegments`): stable while the user
                // types inside a segment (the view and its WKWebView are
                // updated in place) and when a paragraph is inserted above an
                // embed (no later WKWebView is re-targeted).
                ForEach(document.identifiedSegments) { identified in
                    switch identified.segment {
                    case .embed(let preview):
                        ReadingEmbedCard(preview: preview, openURL: openURL)
                    case .markdown(let markdown) where !document.requiresHTMLFallback:
                        NativeMarkdownContent(markdown: markdown, context: document.context, preferences: preferences)
                    default:
                        FittedHTMLPreview(document: PreviewDocument(source: document.source, context: document.context,
                            segments: [identified.segment], requiresHTMLFallback: true), preferences: preferences,
                            onOpenInternalFile: onOpenInternalFile)
                    }
                }
            }
            .padding(.horizontal, 72)
            .padding(.top, 48)
            .padding(.bottom, 120)
            .frame(maxWidth: preferences.previewPageWidthCGFloat, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.openURL, OpenURLAction { url in openURL(url); return .handled })
    }

    private func openURL(_ url: URL) {
        if let internalURL = PreviewURLPolicy.internalVaultFile(url, vaultURL: document.context.vaultURL) {
            onOpenInternalFile(internalURL)
        } else if PreviewURLPolicy.canOpenExternally(url) { NSWorkspace.shared.open(url) }
    }
}

private struct ReadingEmbedCard: View {
    let preview: EditorLinkPreview
    let openURL: (URL) -> Void
    @State private var tweetHeight: CGFloat = 220
    @State private var width: CGFloat = 550
    @State private var visible = false

    private var isTweet: Bool { if case .xPost = preview.kind { return true }; return false }

    var body: some View {
        EditorLinkPreviewCard(preview: preview, openURL: openURL, xEmbedHeightChanged: { value in
            guard value.isFinite, value > 0, value <= 100_000 else { return }
            tweetHeight = max(220, ceil(value) + 4)
            if case .xPost(_, let statusID) = preview.kind {
                EditorEmbedCache.shared.saveXHeight(tweetHeight, for: statusID, width: width)
            }
        }, isPresented: visible)
        .frame(maxWidth: isTweet ? 550 : 640)
        .frame(height: isTweet ? tweetHeight : max(200, width * 9 / 16))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            guard newWidth > 0, width != newWidth else { return }
            width = newWidth
            if case .xPost(_, let statusID) = preview.kind {
                tweetHeight = EditorEmbedCache.shared.xHeight(for: statusID, width: newWidth) ?? 220
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .onDisappear { visible = false }
    }
}

private struct FittedHTMLPreview: View {
    let document: PreviewDocument
    let preferences: AppPreferences
    let onOpenInternalFile: (URL) -> Void
    @State private var height: CGFloat = 1

    var body: some View {
        HTMLPreviewWebView(html: PreviewPageCache.page(for: document, preferences: preferences, compact: true),
            baseURL: document.context.previewBaseURL, documentURL: document.context.documentURL,
            vaultURL: document.context.vaultURL, onOpenInternalFile: onOpenInternalFile,
            heightChanged: { height = max(1, $0) })
            .frame(height: height)
    }
}

private struct HTMLMarkdownPreview: View {
    let document: PreviewDocument
    let preferences: AppPreferences
    let onOpenInternalFile: (URL) -> Void

    var body: some View {
        HTMLPreviewWebView(
            html: PreviewPageCache.page(for: document, preferences: preferences, compact: false),
            baseURL: document.context.previewBaseURL,
            documentURL: document.context.documentURL,
            vaultURL: document.context.vaultURL,
            onOpenInternalFile: onOpenInternalFile
        )
    }
}

/// Memoizes fully rendered preview pages. SwiftUI evaluates `body` far more
/// often than the input changes, and each evaluation used to re-run cmark
/// plus the post-processing passes and rebuild the page; with this cache an
/// evaluation with unchanged input is a dictionary lookup.
@MainActor
enum PreviewPageCache {
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 32
        return cache
    }()

    static func page(for document: PreviewDocument, preferences: AppPreferences, compact: Bool) -> String {
        let signature = PreviewStylesheet.StyleSignature(preferences: preferences)
        let key = cacheKey(for: document, signature: signature, compact: compact)
        if let cached = cache.object(forKey: key) {
            return cached as String
        }

        let page = PreviewStylesheet.page(
            body: HTMLPreviewRenderer.render(document: document),
            preferences: preferences,
            compact: compact
        )
        cache.setObject(page as NSString, forKey: key)
        return page
    }

    /// Everything the rendered page depends on: the exact segments being
    /// rendered (they already carry the resolved asset URLs, and
    /// `HTMLPreviewRenderer.render(document:)` reads nothing else), the
    /// stylesheet inputs and the compact flag. The note's full `source` and
    /// document URL are deliberately left out: a fitted single-segment
    /// document shares them with its siblings, so keying on them would miss the
    /// cache for every segment on every keystroke.
    private static func cacheKey(
        for document: PreviewDocument,
        signature: PreviewStylesheet.StyleSignature,
        compact: Bool
    ) -> NSString {
        var hasher = Hasher()
        hasher.combine(document.segments.count)
        for segment in document.segments {
            switch segment {
            case .markdown(let markdown):
                hasher.combine(0 as UInt8)
                hasher.combine(markdown)
            case .mermaid(let source, _):
                // The diagram is derived from `source` by `MermaidParser`.
                hasher.combine(1 as UInt8)
                hasher.combine(source)
            case .embed(let preview):
                hasher.combine(2 as UInt8)
                hasher.combine(preview.id)
                hasher.combine(preview.title)
                hasher.combine(preview.url)
            }
        }
        hasher.combine(signature)
        hasher.combine(compact)
        let digest = hasher.finalize()
        return "\(document.segments.count)|\(compact)|\(digest)" as NSString
    }
}

private struct ConfigurablePreviewCodeBlockStyle: StructuredText.CodeBlockStyle {
    let preferences: AppPreferences

    func makeBody(configuration: Configuration) -> some View {
        Overflow {
            configuration.label
                .textual.lineSpacing(.fontScaled(0.225))
                .textual.fontScale(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .font(preferences.previewCodeFontChoice.swiftUIFont(size: preferences.previewCodeFontSizeCGFloat))
                .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .textual.blockSpacing(.init(top: 0, bottom: 16))
    }
}

/// Serves bundled KaTeX assets to the preview WKWebView via a custom URL
/// scheme so LaTeX rendering works completely offline. Resources live under
/// `Obsidian/Resources/katex/` in the app bundle.
final class KaTeXBundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "katex-asset"

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Path component is of the form `/katex.min.css` or `/fonts/XYZ.woff2`.
        let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty,
              !trimmedPath.contains(".."),
              let resourceURL = Bundle.main.url(forResource: "katex/\(trimmedPath)", withExtension: nil),
              let data = try? Data(contentsOf: resourceURL) else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            return
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": Self.mimeType(for: url.pathExtension),
                "Content-Length": "\(data.count)",
                "Cache-Control": "public, max-age=31536000, immutable",
            ]
        ) else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            return
        }

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // No async work to cancel.
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "css": return "text/css; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }
}

private struct HTMLPreviewWebView: NSViewRepresentable {
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var lastHTML: String?
        var scrollForwarder: EmbedScrollForwarder?
        var lastBaseURL: URL?
        var lastDocumentURL: URL?
        var heightChanged: ((CGFloat) -> Void)?
        var vaultURL: URL?
        var onOpenInternalFile: (URL) -> Void

        /// Latest vertical scroll offset reported by the page (CSS pixels).
        /// Reloading the page resets it to the top, so `updateNSView` carries
        /// this value over through `pendingScrollRestore` when the same
        /// document is re-rendered after an edit.
        var scrollY: CGFloat = 0
        var pendingScrollRestore: CGFloat?

        init(vaultURL: URL?, onOpenInternalFile: @escaping (URL) -> Void) {
            self.vaultURL = vaultURL
            self.onOpenInternalFile = onOpenInternalFile
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.frameInfo.isMainFrame else { return }
            if message.name == "previewHeight", let value = message.body as? Double,
               value.isFinite, value > 0 {
                heightChanged?(CGFloat(ceil(value)))
                return
            }
            if message.name == "previewScroll" {
                if let value = message.body as? Double, value.isFinite, value >= 0 {
                    scrollY = CGFloat(value)
                }
                return
            }
            guard message.name == "openLink",
                  let urlString = message.body as? String,
                  let url = URL(string: urlString) else { return }
            route(url)
        }

        /// Authoritative navigation policy. The preview frame must only ever
        /// display the HTML we load programmatically; user-initiated link
        /// clicks open in the default browser (http/https/mailto) or are
        /// rejected outright. This prevents `javascript:`/`file:`/`data:`
        /// links from navigating the file:// preview in place.
        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            switch navigationAction.navigationType {
            case .linkActivated:
                if let url = navigationAction.request.url {
                    route(url)
                }
                decisionHandler(.cancel)
            case .other, .reload, .formSubmitted, .formResubmitted, .backForward:
                // `.other` covers our own `loadHTMLString`. Everything that is
                // not an explicit link click stays inside the (app-generated)
                // page; we still never let it leave the loaded document.
                decisionHandler(.allow)
            @unknown default:
                decisionHandler(.allow)
            }
        }

        /// Re-applies the scroll offset captured before the reload, so editing
        /// a note in split mode does not snap the preview back to the top.
        /// `evaluateJavaScript` is native-injected and therefore not subject
        /// to the page's CSP. The browser clamps the offset if the new page is
        /// shorter.
        @MainActor
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let offset = pendingScrollRestore else { return }
            pendingScrollRestore = nil
            guard offset > 0 else { return }
            webView.evaluateJavaScript("window.scrollTo(0, \(Int(offset.rounded())));", completionHandler: nil)
        }

        private func route(_ url: URL) {
            if let internalURL = PreviewURLPolicy.internalVaultFile(url, vaultURL: vaultURL) {
                onOpenInternalFile(internalURL)
            } else if PreviewURLPolicy.canOpenExternally(url) {
                NSWorkspace.shared.open(url)
            }
        }

        func tearDown(_ webView: WKWebView) {
            scrollForwarder = nil
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
        }
    }

    let html: String
    let baseURL: URL?
    /// Identity of the note being shown. Scroll position is preserved across
    /// reloads only while this stays the same; a different note starts at top.
    let documentURL: URL?
    let vaultURL: URL?
    let onOpenInternalFile: (URL) -> Void
    var heightChanged: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(vaultURL: vaultURL, onOpenInternalFile: onOpenInternalFile)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        #if DEBUG
        // Web Inspector is a developer convenience; never ship it enabled.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        configuration.setURLSchemeHandler(
            KaTeXBundleSchemeHandler(),
            forURLScheme: KaTeXBundleSchemeHandler.scheme
        )

        let script = WKUserScript(
            source: """
            document.addEventListener('click', function(e) {
                var target = e.target;
                while (target && target.tagName !== 'A') {
                    target = target.parentElement;
                }
                if (target && target.href && target.href.startsWith('http')) {
                    e.preventDefault();
                    e.stopPropagation();
                    window.webkit.messageHandlers.openLink.postMessage(target.href);
                }
            }, true);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(context.coordinator, name: "openLink")
        if heightChanged != nil {
            configuration.userContentController.add(context.coordinator, name: "previewHeight")
            configuration.userContentController.addUserScript(WKUserScript(source: """
                function reportPreviewHeight() {
                    window.webkit.messageHandlers.previewHeight.postMessage(document.body.getBoundingClientRect().height);
                }
                new ResizeObserver(reportPreviewHeight).observe(document.body);
                reportPreviewHeight();
                """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        } else {
            // Full-page mode only: fitted (compact) pages never scroll, their
            // host SwiftUI ScrollView does. A WKUserScript is injected by the
            // engine rather than the document, so the page CSP does not apply
            // to it; it only posts the offset, throttled to one message per
            // frame, and never reads anything back.
            configuration.userContentController.add(context.coordinator, name: "previewScroll")
            configuration.userContentController.addUserScript(WKUserScript(source: """
                (function() {
                    var pending = false;
                    function reportPreviewScroll() {
                        pending = false;
                        var element = document.scrollingElement || document.documentElement;
                        window.webkit.messageHandlers.previewScroll.postMessage(element.scrollTop);
                    }
                    window.addEventListener('scroll', function() {
                        if (pending) { return; }
                        pending = true;
                        window.requestAnimationFrame(reportPreviewScroll);
                    }, { passive: true });
                })();
                """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        if heightChanged != nil { context.coordinator.scrollForwarder = EmbedScrollForwarder(host: webView) }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.heightChanged = heightChanged
        context.coordinator.vaultURL = vaultURL
        context.coordinator.onOpenInternalFile = onOpenInternalFile
        guard context.coordinator.lastHTML != html || context.coordinator.lastBaseURL != baseURL else {
            return
        }

        // Carry the reader's position over the reload only when it is the
        // same note being re-rendered; switching notes starts at the top.
        let isSameDocument = context.coordinator.lastHTML != nil
            && context.coordinator.lastDocumentURL == documentURL
        context.coordinator.pendingScrollRestore = isSameDocument ? context.coordinator.scrollY : nil
        if !isSameDocument {
            context.coordinator.scrollY = 0
        }

        context.coordinator.lastHTML = html
        context.coordinator.lastBaseURL = baseURL
        context.coordinator.lastDocumentURL = documentURL
        nsView.loadHTMLString(html, baseURL: baseURL)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown(nsView)
    }
}

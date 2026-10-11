import AppKit
import ImageIO
import SwiftUI
@preconcurrency import WebKit

private let embedMessageName = "embedEvent"

struct EditorLinkPreviewCard: View {
    let preview: EditorLinkPreview
    let openURL: (URL) -> Void
    var xEmbedHeightChanged: (CGFloat) -> Void = { _ in }
    var xHoverChanged: (Bool) -> Void = { _ in }
    var youtubeHoverChanged: (Bool) -> Void = { _ in }
    var isPresented = true
    /// Cards hosted by `EditorLinkPreviewController` rely on its single
    /// text-view-level wheel monitor instead of a forwarder per card.
    var forwardsScrollWheel = true
    @Environment(\.colorScheme) private var colorScheme
    /// YouTube cards start as a poster frame; the player loads only on request.
    @State private var isPlayerRequested = false
    /// Set once the requested player is ready or has failed. Until then the
    /// poster frame stays on top while the player boots underneath.
    @State private var isPlayerSettled = false

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onHover { hovering in
                switch preview.kind {
                case .xPost: xHoverChanged(hovering)
                case .youtube: youtubeHoverChanged(hovering)
                }
            }
            .help(preview.url.absoluteString)
    }

    @ViewBuilder
    private var content: some View {
        switch preview.kind {
        case .xPost:
            embed(playOnReady: false)
        case .youtube(let videoID):
            ZStack {
                if isPlayerRequested {
                    embed(playOnReady: true)
                }
                if !isPlayerSettled {
                    YouTubeThumbnailButton(videoID: videoID, title: preview.title, isLoading: isPlayerRequested) {
                        isPlayerRequested = true
                    }
                }
            }
        }
    }

    private func embed(playOnReady: Bool) -> some View {
        ProviderEmbedView(preview: preview, theme: colorScheme == .dark ? "dark" : "light",
                          isPresented: isPresented, forwardsScrollWheel: forwardsScrollWheel,
                          playOnReady: playOnReady, openURL: openURL, heightChanged: xEmbedHeightChanged,
                          loadStateChanged: { state in
                              switch state {
                              case .ready, .failed: isPlayerSettled = true
                              case .idle, .loading: break
                              }
                          })
            .accessibilityLabel(preview.title)
    }
}

struct ProviderEmbedView: NSViewRepresentable {
    let preview: EditorLinkPreview
    let theme: String
    let isPresented: Bool
    let forwardsScrollWheel: Bool
    /// Plays as soon as the player is ready; set when the user clicked play.
    var playOnReady = false
    let openURL: (URL) -> Void
    let heightChanged: (CGFloat) -> Void
    var loadStateChanged: (EmbedLoadState) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Scripts in the card (widgets.js, provider iframes, ads) must not open
        // windows on their own; only a user gesture reaches the UI delegate.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // The macOS default, stated because a clicked YouTube thumbnail starts
        // playback from script. Unrequested playback is paused by the card.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        return configuration
    }

    func makeNSView(context: Context) -> CachedEmbedWebView {
        let webView = EmbedWebViewPool.shared.dequeue()
        let contentController = webView.configuration.userContentController
        contentController.removeScriptMessageHandler(forName: embedMessageName)
        contentController.add(context.coordinator, name: embedMessageName)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = false
        EmbedWebViewAppearance.makeTransparent(webView)
        webView.setAccessibilityLabel(preview.title)
        let container = CachedEmbedWebView(webView: webView, forwardsScrollWheel: forwardsScrollWheel)
        // Applied once per card: later updates must not re-arm playback.
        container.playOnReady = playOnReady
        update(container, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: CachedEmbedWebView, context: Context) {
        update(container, coordinator: context.coordinator)
    }

    private func update(_ container: CachedEmbedWebView, coordinator: Coordinator) {
        coordinator.container = container
        coordinator.preview = preview
        coordinator.theme = theme
        coordinator.openURL = openURL
        coordinator.heightChanged = heightChanged
        container.openOriginal = { [weak coordinator] in
            guard let coordinator, let preview = coordinator.preview else { return }
            coordinator.openURL?(preview.url)
        }
        container.pausePlayer = { [weak container] in
            container?.webView.evaluateJavaScript("window.embedPause && window.embedPause()", completionHandler: nil)
        }
        container.playPlayer = { [weak container] in
            container?.webView.evaluateJavaScript("window.embedPlay && window.embedPlay()", completionHandler: nil)
        }
        container.onLoadStateChange = loadStateChanged
        container.setPresented(isPresented)
        let key: String
        switch preview.kind {
        case .xPost(_, let statusID): key = "x-\(statusID)-\(theme)"
        case .youtube(let videoID): key = "youtube-\(videoID)-\(preview.youtubeStartSeconds ?? 0)-\(theme)"
        }
        container.configure(contentKey: key) { [weak coordinator] token in coordinator?.load(token: token) }
    }

    static func dismantleNSView(_ container: CachedEmbedWebView, coordinator: Coordinator) {
        container.tearDown()
        coordinator.container = nil
        EmbedWebViewPool.shared.recycle(container.webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        weak var container: CachedEmbedWebView?
        var preview: EditorLinkPreview?
        var theme = "light"
        var openURL: ((URL) -> Void)?
        var heightChanged: ((CGFloat) -> Void)?

        func load(token: String) {
            guard let container, let preview else { return }
            let html: String
            switch preview.kind {
            case .xPost(_, let statusID):
                html = XPostEmbedHTML.document(statusID: statusID, theme: theme, token: token)
            case .youtube(let videoID):
                let seconds = EmbedPlaybackStore.shared.position(for: preview.id) ?? Double(preview.youtubeStartSeconds ?? 0)
                html = YouTubeEmbedHTML.document(videoID: videoID, startSeconds: seconds, token: token)
            }
            container.webView.loadHTMLString(html, baseURL: EmbedHTML.appOrigin())
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == embedMessageName, message.frameInfo.isMainFrame,
                  let payload = message.body as? [String: Any] else { return }
            receive(payload)
        }

        func receive(_ payload: [String: Any]) {
            guard let container, let preview, let token = payload["token"] as? String,
                  token == container.loadToken, !token.isEmpty,
                  let type = payload["type"] as? String else { return }
            switch type {
            case "ready":
                container.markReady()
            case "height":
                guard case .xPost = preview.kind,
                      container.loadState == .loading || container.loadState == .ready,
                      let value = payload["height"] as? Double, value.isFinite, value > 0, value <= 100_000 else { return }
                heightChanged?(CGFloat(value))
                container.markReady()
            case "position":
                guard case .youtube = preview.kind, let seconds = payload["seconds"] as? Double else { return }
                EmbedPlaybackStore.shared.save(seconds, for: preview.id)
            case "error":
                let message: String
                if case .youtube = preview.kind {
                    switch payload["code"] as? Int {
                    case 100: message = "This video is unavailable or private."
                    case 101, 150: message = "This video can only be watched on YouTube."
                    default: message = "YouTube couldn’t load this video. Try again or open the original."
                    }
                } else {
                    message = "This post is unavailable, or X couldn’t be reached."
                }
                container.fail(message)
            default: break
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            container?.fail("The embed stopped responding. Try loading it again.")
        }
        private func navigationFailed(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            container?.fail("Couldn’t connect. Check your connection and try again.")
        }

        /// Hands a destination to the host app; the card itself never leaves
        /// the app-generated document.
        private func openExternally(_ url: URL) {
            guard PreviewURLPolicy.canOpenExternally(url), !EmbedNavigationPolicy.isAppOrigin(url) else { return }
            openURL?(url)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
            let target: EmbedNavigationPolicy.Target
            if let targetFrame = navigationAction.targetFrame {
                target = targetFrame.isMainFrame ? .mainFrame : .subframe
            } else {
                target = .newWindow
            }
            let hosts = preview.map { EmbedNavigationPolicy.subframeHosts(for: $0.kind) } ?? []
            switch EmbedNavigationPolicy.disposition(for: url, navigationType: navigationAction.navigationType,
                                                     target: target, subframeHosts: hosts) {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            case .openExternally:
                openExternally(url)
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // A user-initiated window.open opens in the default browser instead of a child
            // web view; script-initiated popups never get here (see makeNSView).
            if let url = navigationAction.request.url { openExternally(url) }
            return nil
        }
    }
}

@MainActor
enum EmbedWebViewAppearance {
    /// `drawsBackground` is private WebKit API reached through KVC. Prefer the
    /// public under-page color, and never let a renamed key raise at runtime.
    static func makeTransparent(_ webView: WKWebView) {
        webView.underPageBackgroundColor = .clear
        let setters = ["setDrawsBackground:", "_setDrawsBackground:"].map(NSSelectorFromString)
        guard setters.contains(where: { webView.responds(to: $0) }) else { return }
        webView.setValue(false, forKey: "drawsBackground")
    }
}

/// An embed document may only ever show the app-generated page. Provider
/// content lives in sub-frames on known hosts; everything else leaves the card.
enum EmbedNavigationPolicy {
    static let xFrameHosts = ["platform.x.com", "platform.twitter.com", "syndication.x.com", "syndication.twitter.com"]
    static let youtubeFrameHosts = ["www.youtube-nocookie.com", "www.youtube.com"]

    static func subframeHosts(for kind: EditorLinkPreviewKind) -> Set<String> {
        switch kind {
        case .xPost: return Set(xFrameHosts)
        case .youtube: return Set(youtubeFrameHosts)
        }
    }

    /// `about:blank` and `about:srcdoc` are the empty documents WebKit itself creates.
    static func isLocalDocument(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "about"
    }

    static func isAppOrigin(_ url: URL, appOrigin: URL = EmbedHTML.appOrigin()) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              let originHost = appOrigin.host?.lowercased() else { return false }
        return host == originHost
    }

    static func allowsMainFrame(_ url: URL, appOrigin: URL = EmbedHTML.appOrigin()) -> Bool {
        isLocalDocument(url) || isAppOrigin(url, appOrigin: appOrigin)
    }

    enum Target: Equatable { case mainFrame, subframe, newWindow }
    enum Disposition: Equatable { case allow, cancel, openExternally }

    /// Only a user-activated link may leave the card. A new-window request with
    /// no link behind it is `window.open`; `javaScriptCanOpenWindowsAutomatically`
    /// is off, so WebKit only reports one when the user's click triggered it (the
    /// providers' share and intent buttons). Script-driven redirects of the
    /// main document and form submits are cancelled without side effects.
    static func disposition(for url: URL, navigationType: WKNavigationType, target: Target,
                            subframeHosts: Set<String>, appOrigin: URL = EmbedHTML.appOrigin()) -> Disposition {
        if navigationType == .linkActivated { return .openExternally }
        switch target {
        case .newWindow: return navigationType == .other ? .openExternally : .cancel
        case .mainFrame: return allowsMainFrame(url, appOrigin: appOrigin) ? .allow : .cancel
        case .subframe: return allowsSubframe(url, hosts: subframeHosts) ? .allow : .cancel
        }
    }

    static func allowsSubframe(_ url: URL, hosts: Set<String>) -> Bool {
        if isLocalDocument(url) { return true }
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }
}

enum EmbedHTML {
    static func appOrigin(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        URL(string: "https://\((bundleIdentifier ?? "com.md.Obsidian").lowercased())")!
    }

    static func js(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    }

    /// Inline bootstrap scripts need 'unsafe-inline'; every network-reaching
    /// directive is pinned to the provider hosts the document actually uses.
    static func contentSecurityPolicy(scripts: [String], frames: [String], connects: [String], images: [String],
                                      styles: [String] = []) -> String {
        func directive(_ name: String, _ keywords: [String], _ hosts: [String]) -> String {
            ([name] + keywords + hosts.map { "https://\($0)" }).joined(separator: " ")
        }
        let directives = [
            "default-src 'none'",
            directive("script-src", ["'self'", "'unsafe-inline'"], scripts),
            directive("frame-src", [], frames),
            directive("connect-src", ["'self'"], connects),
            directive("img-src", ["'self'", "data:"], images),
            directive("style-src", ["'self'", "'unsafe-inline'"], styles),
            "base-uri 'none'",
            "form-action 'none'"
        ]
        return "<meta http-equiv=\"Content-Security-Policy\" content=\"\(directives.joined(separator: "; "))\">"
    }

    static func bridge(token: String) -> String {
        """
        function emit(type, values = {}) {
          window.webkit.messageHandlers.\(embedMessageName).postMessage(Object.assign({type, token: \(js(token))}, values));
        }
        function embedFail(code) { emit('error', {code: code || 0}); }
        """
    }
}

enum YouTubeEmbedHTML {
    static let contentSecurityPolicy = EmbedHTML.contentSecurityPolicy(
        scripts: ["www.youtube.com", "www.youtube-nocookie.com", "s.ytimg.com"],
        frames: EmbedNavigationPolicy.youtubeFrameHosts,
        connects: ["www.youtube.com", "www.youtube-nocookie.com"],
        images: ["i.ytimg.com", "www.youtube.com", "www.youtube-nocookie.com", "s.ytimg.com"]
    )

    static func document(videoID: String, startSeconds: Double, token: String) -> String {
        let seconds = startSeconds.isFinite ? max(0, min(startSeconds, Double(Int32.max))) : 0
        let url = YouTubeEmbedURL.url(videoID: videoID, startSeconds: Int(seconds), origin: EmbedHTML.appOrigin())!
        return """
        <!doctype html><html><head><meta charset="utf-8">
        \(contentSecurityPolicy)
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body,#player{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}iframe{border:0}</style>
        </head><body><div id="player"></div><script>
        \(EmbedHTML.bridge(token: token))
        let player, timer;
        function savePosition() {
          if (player && player.getCurrentTime) emit('position', {seconds: player.getCurrentTime()});
        }
        window.embedPause = function() {
          clearInterval(timer); savePosition();
          if (player && player.pauseVideo) player.pauseVideo();
        };
        window.embedPlay = function() {
          if (player && player.playVideo) player.playVideo();
        };
        window.onYouTubeIframeAPIReady = function() {
          const frame = document.createElement('iframe');
          frame.id = 'player'; frame.src = \(EmbedHTML.js(url.absoluteString));
          frame.allow = 'accelerometer; autoplay; encrypted-media; gyroscope; picture-in-picture; fullscreen';
          frame.setAttribute('allowfullscreen', ''); frame.title = 'YouTube video player';
          document.getElementById('player').replaceWith(frame);
          player = new YT.Player(frame, {events: {
            onReady: function() { emit('ready'); },
            onError: function(event) { clearInterval(timer); embedFail(event.data); },
            onStateChange: function(event) {
              clearInterval(timer);
              if (event.data === 0) { emit('position', {seconds: 0}); }
              else if (event.data === 1 || event.data === 2) { savePosition(); }
              if (event.data === 1) timer = setInterval(savePosition, 1000);
            }
          }});
        };
        window.addEventListener('pagehide', window.embedPause);
        </script><script async src="https://www.youtube.com/iframe_api" onerror="embedFail()"></script></body></html>
        """
    }
}

enum XPostEmbedHTML {
    /// widgets.js lazy-loads chunks from platform.*, reads settings through
    /// syndication.*, and reaches the tweet CDN for embedded media.
    static let contentSecurityPolicy = EmbedHTML.contentSecurityPolicy(
        scripts: EmbedNavigationPolicy.xFrameHosts + ["cdn.syndication.twimg.com"],
        frames: EmbedNavigationPolicy.xFrameHosts,
        connects: EmbedNavigationPolicy.xFrameHosts + ["cdn.syndication.twimg.com"],
        images: EmbedNavigationPolicy.xFrameHosts + ["pbs.twimg.com", "abs.twimg.com", "ton.twimg.com"],
        styles: ["platform.x.com", "platform.twitter.com"]
    )

    static func document(statusID: String, theme: String, token: String = "") -> String {
        let safeStatusID = statusID.filter { $0.isASCII && $0.isNumber }
        let safeTheme = theme == "dark" ? "dark" : "light"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        \(contentSecurityPolicy)
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>:root{color-scheme:\(safeTheme)}html,body{margin:0;padding:0;width:100%;background:transparent;overflow:hidden}
        #tweet{width:100%;min-height:220px}#tweet iframe{margin:0!important}</style></head>
        <body><div id="tweet"></div><script>
        \(EmbedHTML.bridge(token: token))
        let tweetReady = false;
        function reportHeight() {
          const frame = document.querySelector('#tweet iframe');
          if (tweetReady && frame) emit('height', {height: Math.ceil(frame.getBoundingClientRect().height)});
        }
        new ResizeObserver(reportHeight).observe(document.getElementById('tweet'));
        function loadTweet() {
          if (!window.twttr) { embedFail(); return; }
          twttr.ready(function(api) {
            api.widgets.createTweet('\(safeStatusID)', document.getElementById('tweet'), {
              theme: '\(safeTheme)', dnt: true, conversation: 'none', align: 'left'
            }).then(function(element) {
              if (!element) { embedFail(); return; }
              tweetReady = true;
              // X can resize the iframe after its factory promise resolves,
              // including when a quoted post or media finishes loading.
              new ResizeObserver(reportHeight).observe(element);
              reportHeight();
            }).catch(function() { embedFail(); });
          });
        }
        </script><script async src="https://platform.x.com/widgets.js" onload="loadTweet()" onerror="embedFail()" charset="utf-8"></script>
        </body></html>
        """
    }
}

/// The YouTube card before the player exists: the video's poster frame and a
/// play button. One click loads the player, which starts playing when ready.
struct YouTubeThumbnailButton: View {
    let videoID: String
    let title: String
    let isLoading: Bool
    let play: () -> Void
    @State private var image: NSImage?

    var body: some View {
        // Not `.disabled` while loading: that would grey out the poster.
        Button {
            if !isLoading { play() }
        } label: {
            ZStack {
                Color.black
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .transition(.opacity)
                }
                badge
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLoading ? "Loading \(title)" : "Play \(title)")
        .accessibilityHint(isLoading ? "" : "Loads the YouTube player and starts the video.")
        .task(id: videoID) {
            if let cached = YouTubeThumbnailLoader.shared.cachedImage(for: videoID) {
                image = cached
                return
            }
            let loaded = await YouTubeThumbnailLoader.shared.image(for: videoID)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }

    /// The play glyph turns into a spinner in the same place once clicked.
    private var badge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.7))
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .environment(\.colorScheme, .dark)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 68, height: 48)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }
}

/// Fetches YouTube poster frames without cookies and decodes them off the main
/// thread. Requests for the same video share one download, decoded frames are
/// kept in memory, and the HTTP cache on disk serves later launches.
@MainActor
final class YouTubeThumbnailLoader {
    typealias Fetch = @Sendable (URL) async throws -> (Data, URLResponse)

    static let shared = YouTubeThumbnailLoader()

    private let fetch: Fetch
    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    init(fetch: @escaping Fetch = YouTubeThumbnailLoader.defaultFetch) {
        self.fetch = fetch
        cache.countLimit = 64
    }

    func cachedImage(for videoID: String) -> NSImage? {
        cache.object(forKey: videoID as NSString)
    }

    func image(for videoID: String) async -> NSImage? {
        if let cached = cachedImage(for: videoID) { return cached }
        let task: Task<CGImage?, Never>
        if let existing = inFlight[videoID] {
            task = existing
        } else {
            let urls = YouTubeThumbnail.urls(videoID: videoID)
            let fetch = self.fetch
            task = Task.detached(priority: .userInitiated) {
                await YouTubeThumbnailLoader.firstFrame(from: urls, fetch: fetch)
            }
            inFlight[videoID] = task
        }
        let frame = await task.value
        inFlight[videoID] = nil
        if let cached = cachedImage(for: videoID) { return cached }
        guard let frame else { return nil }
        let image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        cache.setObject(image, forKey: videoID as NSString)
        return image
    }

    /// Tries each URL in order and returns the first real frame.
    nonisolated static func firstFrame(from urls: [URL], fetch: Fetch) async -> CGImage? {
        for url in urls {
            guard !Task.isCancelled else { return nil }
            guard let (data, response) = try? await fetch(url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let frame = decode(data) else { continue }
            return frame
        }
        return nil
    }

    /// Decodes at most `maxPixelSize` wide. YouTube answers a missing frame
    /// with a 120×90 grey placeholder, which is treated as no frame.
    nonisolated static func decode(_ data: Data, maxPixelSize: Int = 1_280) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              frame.width > 120 || frame.height > 90 else { return nil }
        return frame
    }

    nonisolated static let defaultFetch: Fetch = { url in try await session.data(from: url) }

    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        configuration.urlCache = URLCache(
            memoryCapacity: 4 * 1_024 * 1_024,
            diskCapacity: 64 * 1_024 * 1_024,
            directory: caches.appendingPathComponent("Obsidian/YouTubeThumbnails", isDirectory: true)
        )
        return URLSession(configuration: configuration)
    }()
}

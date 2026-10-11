import AppKit
@preconcurrency import WebKit

enum EmbedLoadState: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}

@MainActor
final class CachedEmbedWebView: NSView {
    let webView: WKWebView
    private(set) var loadState: EmbedLoadState = .idle {
        didSet {
            guard loadState != oldValue else { return }
            // Delivered on the next main-queue turn: transitions also happen
            // while SwiftUI is updating views, where hosts must not mutate state.
            let state = loadState
            DispatchQueue.main.async { [weak self] in self?.onLoadStateChange?(state) }
        }
    }
    private(set) var loadToken = ""
    private(set) var isMediaActive = false
    var openOriginal: (() -> Void)?
    var pausePlayer: (() -> Void)?
    /// Starts playback in the provider page.
    var playPlayer: (() -> Void)?
    var onLoadStateChange: ((EmbedLoadState) -> Void)?
    /// Set when the user asked this card to play (the YouTube thumbnail was
    /// clicked). The first time the ready player is on screen it plays instead
    /// of being paused; leaving the screen first withdraws the request.
    var playOnReady = false

    private let loadTimeout: Duration
    private var contentKey: String?
    private var snapshotKey: String?
    /// The key whose cached PNG is currently shown as the placeholder.
    private var cachedSnapshotKey: String?
    private var statusBackgroundAlpha: CGFloat = 1
    private var load: ((String) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var presented = true
    private var scrollForwarder: EmbedScrollForwarder?
    private let snapshotView = NSImageView()
    private let statusView = NSView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Loading…")
    private let progress = NSProgressIndicator()
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let openButton = NSButton(title: "Open original", target: nil, action: nil)

    /// `forwardsScrollWheel` installs a per-card wheel monitor. Cards owned by
    /// `EditorLinkPreviewController` pass `false` because the controller
    /// already forwards wheel events for every card it hosts.
    init(webView: WKWebView, loadTimeout: Duration = .seconds(20), forwardsScrollWheel: Bool = true) {
        self.webView = webView
        self.loadTimeout = loadTimeout
        super.init(frame: .zero)
        addSubview(webView)
        if forwardsScrollWheel { scrollForwarder = EmbedScrollForwarder(host: self) }
        snapshotView.imageScaling = .scaleProportionallyUpOrDown
        snapshotView.setAccessibilityElement(false)
        snapshotView.isHidden = true
        addSubview(snapshotView)
        statusView.wantsLayer = true
        statusView.layer?.cornerRadius = 12
        addSubview(statusView)
        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        retryButton.target = self
        retryButton.action = #selector(retry)
        openButton.target = self
        openButton.action = #selector(openSource)
        let buttons = NSStackView(views: [retryButton, openButton])
        buttons.spacing = 12
        let stack = NSStackView(views: [progress, statusLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: statusView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: statusView.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: statusView.widthAnchor, constant: -32)
        ])
        updateStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        webView.frame = bounds
        snapshotView.frame = bounds
        statusView.frame = bounds
        refreshSnapshotKey()
        updateMediaActivity()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMediaActivity()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshSnapshotKey()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStatusBackground()
    }

    func configure(contentKey: String, load: @escaping (String) -> Void) {
        self.load = load
        guard self.contentKey != contentKey else { return }
        self.contentKey = contentKey
        snapshotKey = nil
        retry()
    }

    @objc func retry() {
        guard let load else { return }
        timeoutTask?.cancel()
        snapshotTask?.cancel()
        webView.stopLoading()
        loadToken = UUID().uuidString
        loadState = .loading
        snapshotView.image = nil
        snapshotView.isHidden = true
        updateStatus()
        refreshSnapshotKey(force: true)
        let token = loadToken
        let timeout = loadTimeout
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.loadToken == token else { return }
            self.fail("This embed took too long to load. Check your connection and try again.")
        }
        load(token)
    }

    @objc private func openSource() { openOriginal?() }

    func markReady() {
        guard loadState == .loading else { return }
        timeoutTask?.cancel()
        loadState = .ready
        snapshotView.isHidden = true
        updateStatus()
        // Readiness can arrive after this card has already scrolled away.
        updateMediaActivity(force: true)
        // A placeholder decoded from disk for this exact key is already current;
        // capturing, encoding and writing it again would only burn CPU and I/O.
        let hasCachedSnapshot = cachedSnapshotKey != nil && cachedSnapshotKey == snapshotKey
        if !hasCachedSnapshot { scheduleSnapshot() }
    }

    func fail(_ message: String) {
        guard loadState != .idle else { return }
        timeoutTask?.cancel()
        snapshotTask?.cancel()
        loadState = .failed(message)
        snapshotView.isHidden = true
        webView.stopLoading()
        pausePlayer?()
        webView.pauseAllMediaPlayback(completionHandler: nil)
        updateStatus()
    }

    func setPresented(_ presented: Bool) {
        self.presented = presented
        updateMediaActivity()
    }

    private func updateMediaActivity(force: Bool = false) {
        let active = presented && window != nil && !isHiddenOrHasHiddenAncestor
        guard force || active != isMediaActive else { return }
        isMediaActive = active
        // Completions also check that the web view is still this card's: a
        // recycled web view may already serve another card when WebKit replies.
        if active {
            // WebKit may resume suspended media when suspension is lifted.
            // Pause after lifting it, so returning to a note never autoplays,
            // unless the user has just asked this card to play. The choice is
            // made now: WebKit answers in order, so an earlier activation's
            // pending pause can never undo the play, nor turn into one.
            let shouldPlay = playOnReady && loadState == .ready
            if shouldPlay { playOnReady = false }
            webView.setAllMediaPlaybackSuspended(false) { [weak self] in
                guard let self, self.isMediaActive, self.webView.superview === self else { return }
                if shouldPlay {
                    self.playPlayer?()
                } else {
                    self.pausePlayer?()
                    self.webView.pauseAllMediaPlayback(completionHandler: nil)
                }
            }
        } else {
            playOnReady = false
            pausePlayer?()
            webView.pauseAllMediaPlayback { [weak self] in
                guard let self, !self.isMediaActive, self.webView.superview === self else { return }
                self.webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
            }
        }
    }

    func tearDown() {
        onLoadStateChange = nil
        setPresented(false)
        timeoutTask?.cancel()
        snapshotTask?.cancel()
        loadToken = ""
        loadState = .idle
        load = nil
        scrollForwarder = nil
        openOriginal = nil
        pausePlayer = nil
        playPlayer = nil
        playOnReady = false
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    private func updateStatus() {
        statusBackgroundAlpha = 1
        applyStatusBackground()
        statusView.isHidden = loadState == .ready || loadState == .idle
        webView.isHidden = loadState != .ready
        if case .failed(let message) = loadState {
            statusLabel.stringValue = message
            retryButton.isHidden = false
            progress.stopAnimation(nil)
            progress.isHidden = true
        } else {
            statusLabel.stringValue = "Loading embed…"
            retryButton.isHidden = true
            progress.isHidden = false
            progress.startAnimation(nil)
        }
    }

    /// A `CGColor` resolves a dynamic color once, so the layer is refreshed
    /// under the current appearance whenever it changes.
    private func applyStatusBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            statusView.layer?.backgroundColor = NSColor.controlBackgroundColor
                .withAlphaComponent(statusBackgroundAlpha).cgColor
        }
    }

    private func refreshSnapshotKey(force: Bool = false) {
        guard let contentKey, bounds.width > 1 else { return }
        let key = EmbedSnapshotKey.make(content: contentKey, width: bounds.width, scale: window?.backingScaleFactor ?? 2)
        guard force || key != snapshotKey else { return }
        snapshotKey = key
        cachedSnapshotKey = nil
        snapshotTask?.cancel()
        if loadState == .ready {
            scheduleSnapshot()
        } else if loadState == .loading {
            let token = loadToken
            snapshotTask = Task { [weak self] in
                let image = await EditorEmbedCache.shared.snapshot(for: key)
                guard let self, !Task.isCancelled, self.loadToken == token,
                      self.snapshotKey == key, self.loadState == .loading else { return }
                self.cachedSnapshotKey = image == nil ? nil : key
                self.snapshotView.image = image
                self.snapshotView.isHidden = image == nil
                // Loading controls remain reachable even with a cached card.
                self.statusBackgroundAlpha = image == nil ? 1 : 0.92
                self.applyStatusBackground()
            }
        }
    }

    private func scheduleSnapshot() {
        snapshotTask?.cancel()
        guard let key = snapshotKey, bounds.width > 1, bounds.height > 1 else { return }
        let token = loadToken
        snapshotTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, self.loadToken == token, self.loadState == .ready else { return }
            // Avoid allocating an enormous bitmap for very tall posts.
            guard self.bounds.height <= 8_192 else { return }
            self.webView.takeSnapshot(with: nil) { [weak self] image, _ in
                guard let self, self.loadToken == token, self.snapshotKey == key,
                      self.loadState == .ready, let image else { return }
                Task { await EditorEmbedCache.shared.saveSnapshot(image, for: key) }
            }
        }
    }
}

/// Keeps a few torn-down provider web views so a new card skips WebKit's view,
/// page and content-process setup. Idle views show a blank page with no
/// delegates or script handlers, so nothing from a previous card survives.
@MainActor
final class EmbedWebViewPool {
    static let shared = EmbedWebViewPool()

    let capacity: Int
    private let makeWebView: () -> WKWebView
    private(set) var idleWebViews: [WKWebView] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(capacity: Int = 3, observesMemoryPressure: Bool = true,
         makeWebView: @escaping () -> WKWebView = {
             WKWebView(frame: .zero, configuration: ProviderEmbedView.makeConfiguration())
         }) {
        self.capacity = max(0, capacity)
        self.makeWebView = makeWebView
        guard observesMemoryPressure else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drain() }
        }
        source.resume()
        memoryPressureSource = source
    }

    func dequeue() -> WKWebView {
        idleWebViews.popLast() ?? makeWebView()
    }

    func recycle(_ webView: WKWebView) {
        webView.removeFromSuperview()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.stopLoading()
        webView.pauseAllMediaPlayback(completionHandler: nil)
        guard idleWebViews.count < capacity, !idleWebViews.contains(where: { $0 === webView }) else { return }
        // Unload the provider document: its scripts, timers and players stop here.
        webView.loadHTMLString("", baseURL: nil)
        idleWebViews.append(webView)
    }

    /// Frees every idle web view, for example under memory pressure.
    func drain() {
        idleWebViews.removeAll()
    }
}

@MainActor
enum EmbedViewLifecycle {
    static func setPresented(_ presented: Bool, in view: NSView) {
        if let embed = view as? CachedEmbedWebView { embed.setPresented(presented) }
        else { view.subviews.forEach { setPresented(presented, in: $0) } }
    }
}

/// Wraps the opaque monitor handle from `NSEvent.addLocalMonitorForEvents` so
/// a main-actor owner can still remove it from its nonisolated `deinit`.
final class ScrollWheelMonitorToken: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

/// WKWebView consumes wheel events even when its document has no overflow.
/// Route vertical scrolling to the containing note, leaving player clicks alone.
@MainActor
final class EmbedScrollForwarder {
    private var token: ScrollWheelMonitorToken?

    init(host: NSView) {
        if let value = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak host] event in
            guard let host, host.window != nil, event.window === host.window,
                  !host.isHiddenOrHasHiddenAncestor, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
                  host.visibleRect.contains(host.convert(event.locationInWindow, from: nil)),
                  let scrollView = host.enclosingScrollView else { return event }
            scrollView.scrollWheel(with: event)
            return nil
        }) { token = ScrollWheelMonitorToken(value) }
    }

    deinit { if let token { NSEvent.removeMonitor(token.value) } }
}

import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit
import XCTest
@testable import Obsidian

@MainActor
final class EmbedReliabilityTests: XCTestCase {
    func testRetryIgnoresCallbacksFromPreviousLoadAndRequiresProviderReadiness() throws {
        let container = CachedEmbedWebView(webView: WKWebView())
        defer { container.tearDown() }
        let coordinator = ProviderEmbedView.Coordinator()
        coordinator.container = container
        coordinator.preview = try XCTUnwrap(EditorLinkPreviewDetector.previews(in: "https://youtu.be/AVEZBy1uAk8").first)
        var loads = 0
        container.configure(contentKey: "video") { _ in loads += 1 }
        let firstToken = container.loadToken
        XCTAssertEqual(container.loadState, .loading)
        coordinator.receive(["token": firstToken, "type": "error", "code": 100])
        XCTAssertEqual(container.loadState, .failed("This video is unavailable or private."))
        container.retry()
        let secondToken = container.loadToken
        XCTAssertNotEqual(firstToken, secondToken)
        coordinator.receive(["token": firstToken, "type": "ready"])
        XCTAssertEqual(container.loadState, .loading)
        coordinator.receive(["token": secondToken, "type": "ready"])
        XCTAssertEqual(container.loadState, .ready)
        XCTAssertEqual(loads, 2)
        coordinator.webViewWebContentProcessDidTerminate(container.webView)
        if case .failed = container.loadState {} else { XCTFail("Process exit must expose retry") }
    }

    func testOffscreenReadinessPausesAndReattachingDoesNotAutoplay() async {
        let container = CachedEmbedWebView(webView: WKWebView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        defer { container.tearDown(); window.contentView = nil }
        var pauses = 0
        container.pausePlayer = { pauses += 1 }
        container.configure(contentKey: "video") { _ in }
        container.setPresented(false)
        XCTAssertFalse(container.isMediaActive)
        let beforeReady = pauses
        container.markReady()
        XCTAssertGreaterThan(pauses, beforeReady)
        let pausedAfterReattach = expectation(description: "Pause after WebKit lifts suspension")
        var shouldFulfill = true
        container.pausePlayer = {
            if shouldFulfill { shouldFulfill = false; pausedAfterReattach.fulfill() }
        }
        container.setPresented(true)
        XCTAssertTrue(container.isMediaActive)
        await fulfillment(of: [pausedAfterReattach], timeout: 5)
        container.removeFromSuperview()
        XCTAssertFalse(container.isMediaActive)
    }

    func testTimeoutIsRecoverableAndCannotReplaceReadyState() async throws {
        let container = CachedEmbedWebView(webView: WKWebView(), loadTimeout: .milliseconds(10))
        defer { container.tearDown() }
        container.configure(contentKey: "never-finishes") { _ in }
        try await Task.sleep(for: .milliseconds(100))
        if case .failed = container.loadState {} else { XCTFail("Loading must time out") }
        container.retry()
        container.markReady()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(container.loadState, .ready)
    }

    func testTallTweetHeightPassesThroughButInvalidMeasurementsAreRejected() throws {
        let container = CachedEmbedWebView(webView: WKWebView())
        defer { container.tearDown() }
        let coordinator = ProviderEmbedView.Coordinator()
        coordinator.container = container
        coordinator.preview = try XCTUnwrap(EditorLinkPreviewDetector.previews(in: "https://x.com/user/status/12345").first)
        var heights: [CGFloat] = []
        coordinator.heightChanged = { heights.append($0) }
        container.configure(contentKey: "tweet") { _ in }
        let token = container.loadToken
        for height in [1400.0, -10, Double.infinity, Double.nan, 100_001] {
            coordinator.receive(["token": token, "type": "height", "height": height])
        }
        XCTAssertEqual(heights, [1400])
        XCTAssertEqual(container.loadState, .ready)
    }

    func testWidgetReportsLateIframeResizeThroughTheRealScriptBridge() async throws {
        let coordinator = ProviderEmbedView.Coordinator()
        coordinator.preview = try XCTUnwrap(EditorLinkPreviewDetector.previews(in: "https://x.com/user/status/12345").first)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(coordinator, name: "embedEvent")
        let container = CachedEmbedWebView(webView: WKWebView(frame: .zero, configuration: configuration))
        container.frame = NSRect(x: 0, y: 0, width: 550, height: 1500)
        container.layoutSubtreeIfNeeded()
        coordinator.container = container
        defer { container.tearDown() }
        let resized = expectation(description: "Late iframe size reaches the native card")
        var fulfilled = false
        coordinator.heightChanged = { height in
            if height >= 1400, !fulfilled { fulfilled = true; resized.fulfill() }
        }
        container.configure(contentKey: "late-resize") { token in
            let html = XPostEmbedHTML.document(statusID: "12345", theme: "light", token: token)
            let prefix = html.components(separatedBy: "<script async src=\"https://platform.x.com/widgets.js\"")[0]
            let fixture = prefix + """
            <script>
            window.twttr = {ready: function(callback) { callback({widgets: {createTweet: function(id, parent) {
              const frame = document.createElement('iframe');
              frame.style.cssText = 'position:absolute;width:550px;height:900px;border:0';
              parent.appendChild(frame);
              setTimeout(function() { frame.style.height = '1400px'; }, 100);
              return Promise.resolve(frame);
            }}}); }};
            loadTweet();
            </script></body></html>
            """
            container.webView.loadHTMLString(fixture, baseURL: EmbedHTML.appOrigin())
        }
        await fulfillment(of: [resized], timeout: 8)
        XCTAssertEqual(container.loadState, .ready)
    }

    func testCacheSeparatesWidthsAndDisplayScales() throws {
        let suite = "EmbedReliabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = EditorEmbedCache(userDefaults: defaults)
        cache.saveXHeight(1400, for: "123", width: 320)
        cache.saveXHeight(750, for: "123", width: 550)
        XCTAssertEqual(cache.xHeight(for: "123", width: 320), 1400)
        XCTAssertEqual(cache.xHeight(for: "123", width: 550), 750)
        XCTAssertNil(cache.xHeight(for: "123", width: 480))
        let key = EmbedSnapshotKey.make(content: "x-123-dark", width: 550, scale: 2)
        XCTAssertNotEqual(key, EmbedSnapshotKey.make(content: "x-123-dark", width: 320, scale: 2))
        XCTAssertNotEqual(key, EmbedSnapshotKey.make(content: "x-123-dark", width: 550, scale: 1))
    }

    func testDiskCacheEvictsExpiredAndOldestOverBudgetFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EmbedSnapshotStore(directory: directory, byteLimit: 12, maximumAge: 100)
        for (key, age) in [("expired", 200.0), ("old", 50), ("recent", 10)] {
            let url = await store.fileURL(for: key)
            try Data(repeating: 0, count: 8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        await store.prune()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["recent.png"])
    }

    func testPlaybackStoreRejectsInvalidPositionsAndKeepsURLTimestampIndependent() {
        let store = EmbedPlaybackStore()
        store.save(123.5, for: "video?t=60")
        store.save(.nan, for: "video?t=60")
        store.save(-1, for: "video?t=60")
        XCTAssertEqual(store.position(for: "video?t=60"), 123.5)
        XCTAssertNil(store.position(for: "video?t=120"))
        for index in 0..<128 { store.save(Double(index), for: "other-\(index)") }
        XCTAssertNil(store.position(for: "video?t=60"))
    }

    func testDiskCachePrunesOnFirstUseAndAfterTheWriteThreshold() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EmbedSnapshotStore(directory: directory, byteLimit: 12, maximumAge: 100, pruneThreshold: 20)
        func save(_ key: String, age: TimeInterval) async throws {
            await store.save(Data(repeating: 0, count: 8), for: key)
            let url = await store.fileURL(for: key)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try await save("a", age: 40) // First use scans the directory; nothing to remove yet.
        try await save("b", age: 30) // 8 bytes since the scan: skipped.
        try await save("c", age: 20) // 16 bytes since the scan: skipped although over budget.
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)), ["a.png", "b.png", "c.png"])
        try await save("d", age: 10) // 24 bytes crosses the threshold and keeps only the newest.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["d.png"])
    }

    func testSnapshotEncodingHappensOutsideTheStoreAndRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bitmap = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(EmbedSnapshotStore.pngData(for: bitmap))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let store = EmbedSnapshotStore(directory: directory)
        await store.save(data, for: "round-trip")
        let restoredImage = await store.image(for: "round-trip")
        let restored = try XCTUnwrap(restoredImage)
        XCTAssertEqual(restored.width, 4)
        XCTAssertEqual(restored.height, 3)
    }

    func testHeightCacheEvictsLeastRecentlyUpdatedEntryAndCoalescesWrites() throws {
        let suite = "EmbedReliabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = EditorEmbedCache(userDefaults: defaults, heightStorageKey: "heights", snapshotDirectoryURL: directory)
        for index in 0..<512 { cache.saveXHeight(CGFloat(300 + index), for: "post-\(index)") }
        cache.saveXHeight(999, for: "post-0") // Updating the oldest entry makes it the newest.
        cache.saveXHeight(400, for: "post-512") // Evicts post-1, now the least recently updated.
        XCTAssertEqual(cache.xHeight(for: "post-0"), 999)
        XCTAssertNil(cache.xHeight(for: "post-1"))
        XCTAssertEqual(cache.xHeight(for: "post-2"), 302)
        XCTAssertEqual(cache.xHeight(for: "post-512"), 400)
        XCTAssertNil(defaults.dictionary(forKey: "heights"), "A burst of heights is serialized once, not per height")
        cache.flushPendingHeightWrites()
        let persisted = try XCTUnwrap(defaults.dictionary(forKey: "heights") as? [String: Double])
        XCTAssertEqual(persisted.count, 512)
        XCTAssertNil(persisted["post-1-w550"])
        XCTAssertEqual(persisted["post-0-w550"], 999)
        XCTAssertEqual(persisted["post-512-w550"], 400)
    }

    func testPendingHeightsFlushWhenTheAppResignsActiveOrTerminates() throws {
        let suiteName = "EmbedReliabilityTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let center = NotificationCenter()
        for name in [NSApplication.didResignActiveNotification, NSApplication.willTerminateNotification] {
            let cache = EditorEmbedCache(userDefaults: userDefaults, heightStorageKey: "heights", snapshotDirectoryURL: directory)
            cache.observeApplicationLifecycle(center: center)
            cache.saveXHeight(1_400, for: "99")
            XCTAssertNil(userDefaults.dictionary(forKey: "heights"), "The write is still debounced")
            center.post(name: name, object: nil)
            let stored = userDefaults.dictionary(forKey: "heights") as? [String: Double]
            XCTAssertEqual(stored?["99-w550"], 1_400, "\(name.rawValue) must persist the pending height")
            userDefaults.removeObject(forKey: "heights")
        }
    }

    func testEmbedDocumentsPinNetworkAccessToProviderHosts() throws {
        let post = XPostEmbedHTML.document(statusID: "12345", theme: "light", token: "token")
        let video = YouTubeEmbedHTML.document(videoID: "AVEZBy1uAk8", startSeconds: 0, token: "token")
        for html in [post, video] {
            XCTAssertTrue(html.contains("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; "))
            // The policy must precede the first script so WebKit enforces it on every load.
            let policy = try XCTUnwrap(html.range(of: "Content-Security-Policy"))
            let script = try XCTUnwrap(html.range(of: "<script"))
            XCTAssertLessThan(policy.lowerBound, script.lowerBound)
        }
        XCTAssertTrue(post.contains("script-src 'self' 'unsafe-inline' https://platform.x.com https://platform.twitter.com"))
        XCTAssertTrue(post.contains("frame-src https://platform.x.com https://platform.twitter.com"))
        XCTAssertTrue(post.contains("img-src 'self' data: https://platform.x.com"))
        XCTAssertFalse(post.contains("youtube"))
        XCTAssertTrue(video.contains("script-src 'self' 'unsafe-inline' https://www.youtube.com"))
        XCTAssertTrue(video.contains("frame-src https://www.youtube-nocookie.com https://www.youtube.com"))
        XCTAssertFalse(video.contains("twitter"))
    }

    func testNavigationPolicyKeepsMainFrameOnAppOriginAndSubframesOnProviderHosts() throws {
        func url(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }
        let origin = EmbedHTML.appOrigin(bundleIdentifier: "com.md.Obsidian")
        XCTAssertTrue(EmbedNavigationPolicy.allowsMainFrame(origin, appOrigin: origin))
        XCTAssertTrue(EmbedNavigationPolicy.allowsMainFrame(try url("about:blank"), appOrigin: origin))
        XCTAssertFalse(EmbedNavigationPolicy.allowsMainFrame(try url("https://x.com/user/status/1"), appOrigin: origin))
        XCTAssertFalse(EmbedNavigationPolicy.allowsMainFrame(try url("http://com.md.obsidian/"), appOrigin: origin))
        XCTAssertFalse(EmbedNavigationPolicy.allowsMainFrame(try url("javascript:alert(1)"), appOrigin: origin))

        let xHosts = EmbedNavigationPolicy.subframeHosts(for: .xPost(username: "user", statusID: "1"))
        XCTAssertTrue(EmbedNavigationPolicy.allowsSubframe(try url("https://platform.twitter.com/embed/Tweet.html?id=1"), hosts: xHosts))
        XCTAssertTrue(EmbedNavigationPolicy.allowsSubframe(try url("https://platform.x.com/embed/Tweet.html?id=1"), hosts: xHosts))
        XCTAssertTrue(EmbedNavigationPolicy.allowsSubframe(try url("about:blank"), hosts: xHosts))
        XCTAssertFalse(EmbedNavigationPolicy.allowsSubframe(try url("http://platform.twitter.com/embed/Tweet.html"), hosts: xHosts))
        XCTAssertFalse(EmbedNavigationPolicy.allowsSubframe(try url("https://www.youtube-nocookie.com/embed/a"), hosts: xHosts))

        let youtubeHosts = EmbedNavigationPolicy.subframeHosts(for: .youtube(videoID: "a"))
        XCTAssertTrue(EmbedNavigationPolicy.allowsSubframe(try url("https://www.youtube-nocookie.com/embed/a"), hosts: youtubeHosts))
        XCTAssertFalse(EmbedNavigationPolicy.allowsSubframe(try url("https://evil.example/"), hosts: youtubeHosts))
        XCTAssertFalse(EmbedNavigationPolicy.allowsSubframe(try url("https://platform.x.com/embed/Tweet.html"), hosts: youtubeHosts))
    }

    func testOnlyUserActivatedLinksAndClickPopupsLeaveTheCard() throws {
        func url(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }
        let origin = EmbedHTML.appOrigin(bundleIdentifier: "com.md.Obsidian")
        let hosts = EmbedNavigationPolicy.subframeHosts(for: .youtube(videoID: "a"))
        func disposition(_ string: String, _ type: WKNavigationType, _ target: EmbedNavigationPolicy.Target) throws
            -> EmbedNavigationPolicy.Disposition {
            EmbedNavigationPolicy.disposition(for: try url(string), navigationType: type, target: target,
                                              subframeHosts: hosts, appOrigin: origin)
        }
        let outside = "https://example.com/page"
        // A clicked link opens externally from any frame, including target=_blank.
        XCTAssertEqual(try disposition(outside, .linkActivated, .mainFrame), .openExternally)
        XCTAssertEqual(try disposition(outside, .linkActivated, .subframe), .openExternally)
        XCTAssertEqual(try disposition(outside, .linkActivated, .newWindow), .openExternally)
        // Script redirects of the main document, script form submits and other
        // non-click navigations are cancelled without launching anything.
        XCTAssertEqual(try disposition(outside, .other, .mainFrame), .cancel)
        XCTAssertEqual(try disposition("mailto:a@example.com", .other, .mainFrame), .cancel)
        XCTAssertEqual(try disposition(outside, .formSubmitted, .newWindow), .cancel)
        XCTAssertEqual(try disposition(outside, .formSubmitted, .mainFrame), .cancel)
        XCTAssertEqual(try disposition(outside, .other, .subframe), .cancel)
        // window.open only reaches the policy after a user gesture (automatic popups are off).
        XCTAssertEqual(try disposition(outside, .other, .newWindow), .openExternally)
        // The app document and provider frames still load.
        XCTAssertEqual(try disposition("about:blank", .other, .mainFrame), .allow)
        XCTAssertEqual(try disposition("https://www.youtube-nocookie.com/embed/a", .other, .subframe), .allow)
    }

    func testProviderWebViewBlocksAutomaticScriptPopups() {
        let configuration = ProviderEmbedView.makeConfiguration()
        XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
    }

    func testYouTubeUsesApplicationIdentityAndDoesNotAutoplay() throws {
        let origin = EmbedHTML.appOrigin(bundleIdentifier: "com.md.Obsidian")
        XCTAssertEqual(origin.absoluteString, "https://com.md.obsidian")
        let url = try XCTUnwrap(YouTubeEmbedURL.url(videoID: "AVEZBy1uAk8", startSeconds: 123, origin: origin))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "origin" })?.value, origin.absoluteString)
        XCTAssertEqual(items.first(where: { $0.name == "autoplay" })?.value, "0")
        XCTAssertEqual(items.first(where: { $0.name == "enablejsapi" })?.value, "1")
        XCTAssertEqual(items.first(where: { $0.name == "start" })?.value, "123")
    }

    func testReferenceLinksRemainResolvedAcrossEmbeds() {
        let document = MarkdownPreprocessor.preprocess("""
        Read [the guide][guide].

        https://youtu.be/AVEZBy1uAk8

        [guide]: https://example.com/guide
        """, context: PreviewContext(documentURL: nil, vaultURL: nil))
        let html = HTMLPreviewRenderer.render(document: document)
        XCTAssertTrue(html.contains("<a href=\"https://example.com/guide\">the guide</a>"))
    }

    func testEditorAndReadingPreviewDetectTheSameEmbedsIncludingMixedMarkdown() {
        let source = """
        # Before 😀

        https://x.com/user/status/12345

        Commentary with https://youtu.be/AVEZBy1uAk8 stays inline.

        ![](https://youtube.com/shorts/AVEZBy1uAk8?t=1m2s)

        ```text
        https://x.com/user/status/99999
        ```

        $$
        E = mc^2
        $$

        ```mermaid
        graph TD
        A --> B
        ```
        """
        let context = PreviewContext(documentURL: nil, vaultURL: nil)
        let document = MarkdownPreprocessor.preprocess(source, context: context)
        let embeds = document.segments.compactMap { segment -> EditorLinkPreview? in
            if case .embed(let preview) = segment { return preview }; return nil
        }
        XCTAssertEqual(embeds, EditorLinkPreviewDetector.presentationPreviews(in: source))
        XCTAssertEqual(embeds.count, 2)
        XCTAssertEqual(embeds.last?.youtubeStartSeconds, 62)
        XCTAssertEqual(document.preferredRenderMode, .embedded)
        XCTAssertTrue(document.requiresHTMLFallback)
        XCTAssertTrue(document.containsMermaid)
        let html = HTMLPreviewRenderer.render(document: document)
        XCTAssertTrue(html.contains("Commentary with"))
        XCTAssertFalse(html.contains("youtube-card"))
        XCTAssertTrue(html.contains("math-display"))
    }

    // MARK: - Image viewer decoding

    private func writeImage(width: Int, height: Int, frames: Int, type: UTType, to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("image-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "bin")")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil))
        for frame in 0..<frames {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(red: CGFloat(frame) / 4, green: 0.5, blue: 0.25, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testImageViewerLeavesAnimatedFilesToNSImageAndKeepsStillImagesSharp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A multi-frame GIF must stay on the NSImage(data:) path or it stops animating.
        let animated = try writeImage(width: 16, height: 16, frames: 2, type: .gif, to: directory)
        let animatedDecode = await ImagePreview.decodeImage(at: animated)
        XCTAssertNil(animatedDecode)
        let animatedImage = try XCTUnwrap(NSImage(data: try Data(contentsOf: animated)))
        XCTAssertEqual((animatedImage.representations.first as? NSBitmapImageRep)?.value(forProperty: .frameCount) as? Int, 2)

        // A still image wider than any screen-sized cap keeps every pixel.
        let wide = try writeImage(width: 3_000, height: 100, frames: 1, type: .png, to: directory)
        let wideResult = await ImagePreview.decodeImage(at: wide)
        let wideDecode = try XCTUnwrap(wideResult)
        XCTAssertEqual(wideDecode.bitmap.width, 3_000)
        XCTAssertEqual(wideDecode.bitmap.height, 100)
        XCTAssertEqual(wideDecode.pointSize.width, 3_000, accuracy: 0.5)

        // Only an image over the pixel budget is downsampled, and its point size is unchanged.
        let large = try writeImage(width: 400, height: 400, frames: 1, type: .png, to: directory)
        let largeResult = await ImagePreview.decodeImage(at: large, pixelBudget: 40_000)
        let largeDecode = try XCTUnwrap(largeResult)
        XCTAssertEqual(Double(largeDecode.bitmap.width), 200, accuracy: 2)
        XCTAssertEqual(largeDecode.pointSize.width, 400, accuracy: 0.5)
    }

    func testDecodedPixelCapOnlyAppliesBeyondTheBudget() {
        XCTAssertEqual(ImagePreview.maximumPixelSize(width: 4_032, height: 3_024, pixelBudget: ImagePreview.decodedPixelBudget), 4_032)
        XCTAssertEqual(ImagePreview.maximumPixelSize(width: 8_000, height: 6_000, pixelBudget: 12_000_000), 4_000)
        XCTAssertEqual(ImagePreview.maximumPixelSize(width: 100, height: 50, pixelBudget: 0), 100)
    }

    // MARK: - YouTube poster frame and play-on-request

    func testRequestedPlaybackPlaysOnceWhenTheReadyPlayerIsOnScreen() async {
        let container = CachedEmbedWebView(webView: WKWebView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        defer { container.tearDown(); window.contentView = nil }
        container.playOnReady = true
        let played = expectation(description: "Plays once the player is ready on screen")
        container.playPlayer = { played.fulfill() }
        container.configure(contentKey: "video") { _ in }
        container.markReady()
        await fulfillment(of: [played], timeout: 5)
        XCTAssertFalse(container.playOnReady, "A play request is used once")

        // Coming back later behaves like any card: pause, never autoplay.
        container.playPlayer = { XCTFail("Returning to the card must not autoplay") }
        container.setPresented(false)
        let pausedAfterReturn = expectation(description: "Pauses after returning")
        var shouldFulfill = true
        container.pausePlayer = { if shouldFulfill { shouldFulfill = false; pausedAfterReturn.fulfill() } }
        container.setPresented(true)
        await fulfillment(of: [pausedAfterReturn], timeout: 5)
    }

    func testLeavingTheScreenWithdrawsARequestedPlay() async {
        let container = CachedEmbedWebView(webView: WKWebView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        defer { container.tearDown(); window.contentView = nil }
        container.playOnReady = true
        container.playPlayer = { XCTFail("A card that left the screen must not start playing") }
        container.configure(contentKey: "video") { _ in }
        container.setPresented(false)
        XCTAssertFalse(container.playOnReady)
        let paused = expectation(description: "Pauses when shown again")
        var shouldFulfill = true
        container.pausePlayer = { if shouldFulfill { shouldFulfill = false; paused.fulfill() } }
        container.setPresented(true)
        container.markReady()
        await fulfillment(of: [paused], timeout: 5)
    }

    func testLoadStateChangesArriveAfterTheCurrentUpdateAndStopAtTearDown() async {
        let container = CachedEmbedWebView(webView: WKWebView())
        var states: [EmbedLoadState] = []
        let ready = expectation(description: "Ready is reported")
        container.onLoadStateChange = { state in
            states.append(state)
            if state == .ready { ready.fulfill() }
        }
        container.configure(contentKey: "video") { _ in }
        XCTAssertTrue(states.isEmpty, "Hosts are told on a later main-queue turn, never mid-update")
        container.markReady()
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(states, [.loading, .ready])

        container.tearDown()
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertEqual(states, [.loading, .ready], "A torn-down card reports nothing more")
    }

    func testYouTubePlayerExposesAPlayHookAndDelegatesAutoplayToItsFrame() {
        let html = YouTubeEmbedHTML.document(videoID: "AVEZBy1uAk8", startSeconds: 0, token: "token")
        XCTAssertTrue(html.contains("window.embedPlay = function()"))
        XCTAssertTrue(html.contains("'accelerometer; autoplay; encrypted-media;"))
        XCTAssertTrue(ProviderEmbedView.makeConfiguration().mediaTypesRequiringUserActionForPlayback.isEmpty)
    }

    func testThumbnailLoaderFallsBackToTheAlwaysAvailableFrameAndSharesOneDownload() async throws {
        let frame = try Self.solidPNG(width: 480, height: 360)
        let log = ThumbnailRequestLog()
        let loader = YouTubeThumbnailLoader { url in
            await log.record(url)
            let status = url.lastPathComponent == "maxresdefault.jpg" ? 404 : 200
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (frame, response)
        }
        async let first = loader.image(for: "AVEZBy1uAk8")
        async let second = loader.image(for: "AVEZBy1uAk8")
        let (a, b) = await (first, second)
        let image = try XCTUnwrap(a)
        XCTAssertTrue(image === b, "Concurrent requests share one image")
        XCTAssertTrue(loader.cachedImage(for: "AVEZBy1uAk8") === image)
        let requested = await log.files
        XCTAssertEqual(requested, ["maxresdefault.jpg", "hqdefault.jpg"], "One download chain, best frame first")
        XCTAssertEqual(image.size, NSSize(width: 480, height: 360))
    }

    func testThumbnailLoaderTreatsYouTubesGreyPlaceholderAsNoFrame() async throws {
        let placeholder = try Self.solidPNG(width: 120, height: 90)
        let loader = YouTubeThumbnailLoader { url in
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (placeholder, response)
        }
        let image = await loader.image(for: "AVEZBy1uAk8")
        XCTAssertNil(image)
        XCTAssertNil(loader.cachedImage(for: "AVEZBy1uAk8"))
        XCTAssertNil(YouTubeThumbnailLoader.decode(Data("not an image".utf8)))
    }

    func testSavedSnapshotShowsUncoveredWhileTheLiveEmbedLoads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "EmbedSnapshotPlaceholder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let cache = EditorEmbedCache(userDefaults: defaults, snapshotDirectoryURL: directory)
        let container = CachedEmbedWebView(webView: WKWebView(), snapshotCache: cache)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        defer { container.tearDown(); window.contentView = nil }
        container.layoutSubtreeIfNeeded()
        let key = EmbedSnapshotKey.make(content: "x-1-dark", width: container.bounds.width, scale: window.backingScaleFactor)
        let picture = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        await cache.saveSnapshot(picture, for: key)

        container.configure(contentKey: "x-1-dark") { _ in }
        for _ in 0..<200 where container.isShowingStatusPanel {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(container.loadState, .loading)
        XCTAssertFalse(container.isShowingStatusPanel, "The saved card is not covered while the live embed loads")

        container.fail("Couldn’t connect.")
        XCTAssertTrue(container.isShowingStatusPanel, "A failed load still shows Retry and Open original")
    }

    // MARK: - Web view reuse

    func testPoolReusesTornDownWebViewsWithinItsCapacity() {
        var created = 0
        let pool = EmbedWebViewPool(capacity: 1, observesMemoryPressure: false) {
            created += 1
            return WKWebView()
        }
        let coordinator = ProviderEmbedView.Coordinator()
        let first = pool.dequeue()
        XCTAssertEqual(created, 1)
        let host = NSView()
        host.addSubview(first)
        first.navigationDelegate = coordinator
        first.uiDelegate = coordinator
        pool.recycle(first)
        XCTAssertNil(first.superview, "A recycled web view leaves its old card")
        XCTAssertNil(first.navigationDelegate)
        XCTAssertNil(first.uiDelegate)
        XCTAssertTrue(pool.dequeue() === first, "The next card reuses it")
        XCTAssertEqual(created, 1)

        let a = pool.dequeue()
        let b = pool.dequeue()
        XCTAssertEqual(created, 3)
        pool.recycle(a)
        pool.recycle(b)
        pool.recycle(a)
        XCTAssertEqual(pool.idleWebViews.count, 1, "Capacity bounds the idle views, and each is kept once")
        pool.drain()
        XCTAssertTrue(pool.idleWebViews.isEmpty)
    }

    private static func solidPNG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(EmbedSnapshotStore.pngData(for: image))
    }
}

private actor ThumbnailRequestLog {
    private(set) var files: [String] = []

    func record(_ url: URL) {
        files.append(url.lastPathComponent)
    }
}

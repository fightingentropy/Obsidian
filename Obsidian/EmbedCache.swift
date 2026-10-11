import AppKit
import ImageIO
import UniformTypeIdentifiers

/// PNG decoding and disk maintenance never run on the UI thread, and encoding
/// happens before a save enters the actor so reads never wait behind it.
actor EmbedSnapshotStore {
    let directory: URL
    let byteLimit: Int
    let maximumAge: TimeInterval
    /// A directory scan only pays off once this many new bytes could have
    /// pushed the cache over budget.
    let pruneThreshold: Int
    private var bytesWrittenSincePrune = 0
    private var hasPruned = false

    init(directory: URL, byteLimit: Int = 64 * 1_024 * 1_024, maximumAge: TimeInterval = 7 * 24 * 3600,
         pruneThreshold: Int = 8 * 1_024 * 1_024) {
        self.directory = directory
        self.byteLimit = max(0, byteLimit)
        self.maximumAge = maximumAge
        self.pruneThreshold = max(0, pruneThreshold)
    }

    /// Pure CPU work with no actor state, so callers encode on the cooperative
    /// pool and hand the actor only the finished bytes.
    nonisolated static func pngData(for image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    func image(for key: String) -> CGImage? {
        let url = fileURL(for: key)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate,
              Date().timeIntervalSince(date) < maximumAge else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    func save(_ data: Data, for key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: fileURL(for: key), options: .atomic)) != nil else { return }
        bytesWrittenSincePrune += data.count
        if !hasPruned || bytesWrittenSincePrune >= pruneThreshold { prune() }
    }

    func prune() {
        hasPruned = true
        bytesWrittenSincePrune = 0
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        let entries = files.compactMap { url -> (URL, Date, Int)? in
            guard url.pathExtension == "png", let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var retainedBytes = 0
        for (url, date, size) in entries {
            if Date().timeIntervalSince(date) >= maximumAge || size > byteLimit - retainedBytes {
                try? FileManager.default.removeItem(at: url)
            } else {
                retainedBytes += size
            }
        }
    }

    func fileURL(for key: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        return directory.appendingPathComponent("\(safeKey).png")
    }
}

enum EmbedSnapshotKey {
    static func make(content: String, width: CGFloat, scale: CGFloat) -> String {
        "v2-\(content)-w\(Int(max(1, width).rounded()))-s\(Int(max(1, scale) * 100))"
    }
}

@MainActor
final class EditorEmbedCache {
    static let shared: EditorEmbedCache = {
        let cache = EditorEmbedCache()
        cache.observeApplicationLifecycle()
        return cache
    }()
    private static let heightLimit = 512
    private let userDefaults: UserDefaults
    private let heightStorageKey: String
    private var heights: [String: Double]
    /// Oldest first; a key moves to the end whenever its height changes.
    private var heightAccessOrder: [String]
    private var pendingHeightWrite: Task<Void, Never>?
    private let imageCache = NSCache<NSString, NSImage>()
    private let store: EmbedSnapshotStore

    init(userDefaults: UserDefaults = .standard, heightStorageKey: String = "editorEmbedCache.xHeights.v2", snapshotDirectoryURL: URL? = nil) {
        self.userDefaults = userDefaults
        self.heightStorageKey = heightStorageKey
        let storedHeights = userDefaults.dictionary(forKey: heightStorageKey) as? [String: Double] ?? [:]
        self.heights = storedHeights
        self.heightAccessOrder = storedHeights.keys.sorted()
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        store = EmbedSnapshotStore(directory: snapshotDirectoryURL ?? base.appendingPathComponent("Markdown/EmbedSnapshots", isDirectory: true))
        imageCache.countLimit = 24
        imageCache.totalCostLimit = 32 * 1_024 * 1_024
        Task { await store.prune() }
    }

    func xHeight(for statusID: String, width: CGFloat = 550) -> CGFloat? {
        guard let height = heights[heightKey(statusID, width)], height.isFinite, height > 0 else { return nil }
        return CGFloat(height)
    }

    func saveXHeight(_ height: CGFloat, for statusID: String, width: CGFloat = 550) {
        guard height.isFinite, height > 0 else { return }
        let key = heightKey(statusID, width)
        let value = Double(height)
        guard heights[key] != value else { return }
        heights[key] = value
        heightAccessOrder.removeAll { $0 == key }
        heightAccessOrder.append(key)
        while heightAccessOrder.count > Self.heightLimit {
            heights.removeValue(forKey: heightAccessOrder.removeFirst())
        }
        scheduleHeightPersistence()
    }

    /// Persists coalesced height changes now instead of after the debounce.
    func flushPendingHeightWrites() {
        guard let pendingHeightWrite else { return }
        pendingHeightWrite.cancel()
        self.pendingHeightWrite = nil
        userDefaults.set(heights, forKey: heightStorageKey)
    }

    /// The debounce must never lose a measurement to quitting or backgrounding,
    /// so the app-wide cache flushes whenever the app terminates or deactivates.
    func observeApplicationLifecycle(center: NotificationCenter = .default) {
        for name in [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                // AppKit posts both on the main thread, so the flush runs
                // synchronously before the process can exit.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.flushPendingHeightWrites() }
                } else {
                    Task { @MainActor in self?.flushPendingHeightWrites() }
                }
            }
        }
    }

    /// A burst of measurements serializes the dictionary once, not once per height.
    private func scheduleHeightPersistence() {
        guard pendingHeightWrite == nil else { return }
        pendingHeightWrite = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.pendingHeightWrite = nil
            self.userDefaults.set(self.heights, forKey: self.heightStorageKey)
        }
    }

    func snapshot(for key: String) async -> NSImage? {
        if let image = imageCache.object(forKey: key as NSString) { return image }
        guard let bitmap = await store.image(for: key) else { return nil }
        let image = NSImage(cgImage: bitmap, size: .zero)
        imageCache.setObject(image, forKey: key as NSString, cost: bitmap.bytesPerRow * bitmap.height)
        return image
    }

    func saveSnapshot(_ image: NSImage, for key: String) async {
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        imageCache.setObject(image, forKey: key as NSString, cost: bitmap.bytesPerRow * bitmap.height)
        guard let data = await Self.encodePNG(bitmap) else { return }
        await store.save(data, for: key)
    }

    /// Runs on the cooperative pool: neither the main actor nor the store
    /// waits on the encoder.
    private nonisolated static func encodePNG(_ image: CGImage) async -> Data? {
        EmbedSnapshotStore.pngData(for: image)
    }

    private func heightKey(_ statusID: String, _ width: CGFloat) -> String {
        "\(statusID)-w\(Int(max(1, width).rounded()))"
    }
}

/// Session-only playback positions survive view eviction without autoplaying.
@MainActor
final class EmbedPlaybackStore {
    static let shared = EmbedPlaybackStore()
    private var positions: [String: Double] = [:]
    private var accessOrder: [String] = []

    func position(for key: String) -> Double? { positions[key] }

    func save(_ seconds: Double, for key: String) {
        guard seconds.isFinite, seconds >= 0 else { return }
        positions[key] = seconds
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        if accessOrder.count > 128 { positions.removeValue(forKey: accessOrder.removeFirst()) }
    }
}

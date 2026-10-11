import Foundation

enum VaultFileChange: Sendable, Equatable {
    case changed(URL)
    case moved(from: URL, to: URL)

    var affectedURLs: [URL] {
        switch self {
        case .changed(let url):
            [url]
        case .moved(let oldURL, let newURL):
            [oldURL, newURL]
        }
    }
}

/// External changes waiting to be handled together. Handling a `.changed`
/// path is idempotent, so each standardized path is kept once, at its first
/// position; moves are always kept, in arrival order, so every pair still
/// remaps the paths of the moves that follow it.
struct VaultFileChangeBatch: Sendable {
    /// The size at which a burst is handed on immediately instead of
    /// waiting for it to end, which keeps every batch bounded.
    static let leadingFlushThreshold = 256

    private(set) var changes: [VaultFileChange] = []
    private var changedPaths: Set<String> = []

    var count: Int { changes.count }
    var isEmpty: Bool { changes.isEmpty }

    mutating func append(_ change: VaultFileChange) {
        if case .changed(let url) = change,
           !changedPaths.insert(url.standardizedFileURL.path).inserted {
            return
        }
        changes.append(change)
    }

    mutating func append(contentsOf newChanges: [VaultFileChange]) {
        for change in newChanges {
            append(change)
        }
    }

    /// Returns the pending changes and leaves the batch empty.
    mutating func takeAll() -> [VaultFileChange] {
        let taken = changes
        changes.removeAll(keepingCapacity: true)
        changedPaths.removeAll(keepingCapacity: true)
        return taken
    }
}

/// Forwards file-presenter callbacks in coalesced batches. Callbacks that
/// arrive back to back on the serial presenter queue are delivered together
/// by one operation queued behind them, and a batch that reaches
/// `VaultFileChangeBatch.leadingFlushThreshold` is delivered at once, so an
/// iCloud or git burst reaches the workspace in bounded batches rather than
/// as thousands of single-event hops.
final class VaultFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: @Sendable ([VaultFileChange]) -> Void
    private var isRegistered = false
    /// Guards `pendingChanges` and `isDeliveryScheduled`. Callbacks normally
    /// arrive on the serial presenter queue, but the lock keeps the buffer
    /// consistent for any caller.
    private let pendingLock = NSLock()
    private var pendingChanges = VaultFileChangeBatch()
    private var isDeliveryScheduled = false

    init(vaultURL: URL, onChange: @escaping @Sendable ([VaultFileChange]) -> Void) {
        self.presentedItemURL = vaultURL.standardizedFileURL
        self.onChange = onChange
        let queue = OperationQueue()
        queue.name = "com.md.obsidian.file-presenter"
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue
        super.init()
    }

    func start() {
        guard !isRegistered else { return }
        NSFileCoordinator.addFilePresenter(self)
        isRegistered = true
    }

    func stop() {
        guard isRegistered else { return }
        NSFileCoordinator.removeFilePresenter(self)
        isRegistered = false
    }

    func presentedItemDidChange() {
        if let presentedItemURL { record(.changed(presentedItemURL)) }
    }

    func presentedSubitemDidChange(at url: URL) {
        record(.changed(url))
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        record(.moved(from: oldURL, to: newURL))
    }

    private func record(_ change: VaultFileChange) {
        pendingLock.lock()
        pendingChanges.append(change)
        var fullBatch: [VaultFileChange]?
        if pendingChanges.count >= VaultFileChangeBatch.leadingFlushThreshold {
            fullBatch = pendingChanges.takeAll()
        }
        let needsDelivery = fullBatch == nil && !isDeliveryScheduled
        if needsDelivery {
            isDeliveryScheduled = true
        }
        pendingLock.unlock()

        if let fullBatch {
            onChange(fullBatch)
        } else if needsDelivery {
            // Runs after every callback already waiting on the serial queue,
            // so one delivery carries the whole run of queued events.
            presentedItemOperationQueue.addOperation { [weak self] in
                self?.deliverPendingChanges()
            }
        }
    }

    private func deliverPendingChanges() {
        pendingLock.lock()
        let changes = pendingChanges.takeAll()
        isDeliveryScheduled = false
        pendingLock.unlock()

        guard !changes.isEmpty else { return }
        onChange(changes)
    }
}

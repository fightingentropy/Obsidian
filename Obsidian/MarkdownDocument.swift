import AppKit
import CryptoKit
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable, Sendable {
    let id: URL
    let name: String
    let url: URL
    let modificationDate: Date
    let noteTitle: String?
    /// `url` with symlinks resolved and standardized. Workspace lookups
    /// compare this string so matching a file never resolves URLs again.
    let canonicalPath: String

    init(
        id: URL,
        name: String,
        url: URL,
        modificationDate: Date,
        noteTitle: String?,
        canonicalPath: String
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.modificationDate = modificationDate
        self.noteTitle = noteTitle
        self.canonicalPath = canonicalPath
    }

    /// Resolves `canonicalPath` from `url`. Construction sites that already
    /// hold the canonical path pass it to the designated initializer instead.
    init(id: URL, name: String, url: URL, modificationDate: Date, noteTitle: String?) {
        self.init(
            id: id,
            name: name,
            url: url,
            modificationDate: modificationDate,
            noteTitle: noteTitle,
            canonicalPath: Self.canonicalPath(for: url)
        )
    }

    static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    var sidebarTitle: String {
        noteTitle ?? displayName
    }
}

struct SidebarNode: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case folder
        case file
    }

    let id: URL
    let url: URL
    let name: String
    let kind: Kind
    let modificationDate: Date
    var children: [SidebarNode] = []

    var isFolder: Bool {
        kind == .folder
    }
}

enum SortOrder: String, Sendable {
    case byName
    case byDate
}

enum ItemRenameError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case nameAlreadyExists

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a name."
        case .invalidName:
            "Names can't contain slashes, colons, or line breaks."
        case .nameAlreadyExists:
            "An item with that name already exists."
        }
    }
}

/// The result of an explicit or automatic save. Callers that are about to
/// replace the editor buffer should only proceed when `allowsTransition` is
/// true; conflicts and I/O failures deliberately keep the current note open.
enum DocumentSaveResult: Equatable, Sendable {
    case saved
    case noChanges
    case noEditableDocument
    case conflict
    case failed(String)

    var allowsTransition: Bool {
        switch self {
        case .saved, .noChanges, .noEditableDocument:
            true
        case .conflict, .failed:
            false
        }
    }
}

enum WorkspaceFileOperationError: LocalizedError {
    case unsavedChanges(String)

    var errorDescription: String? {
        switch self {
        case .unsavedChanges(let message):
            message
        }
    }
}

struct RecoveryDraft: Codable, Equatable, Sendable {
    let sourcePath: String
    let content: String
    /// Lowercase hex SHA-256 of the on-disk text the unsaved edits were made
    /// against. Automatic restore only needs to know whether disk still holds
    /// exactly that base, so the base text itself is not stored.
    let baseContentDigest: String
    let updatedAt: Date

    init(sourcePath: String, content: String, baseContentDigest: String, updatedAt: Date) {
        self.sourcePath = sourcePath
        self.content = content
        self.baseContentDigest = baseContentDigest
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case sourcePath
        case content
        case baseContentDigest
        case updatedAt
        /// Drafts written before digests stored the complete base text.
        case legacyBaseContent = "baseContent"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        content = try container.decode(String.self, forKey: .content)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        if let digest = try container.decodeIfPresent(String.self, forKey: .baseContentDigest) {
            baseContentDigest = digest
        } else {
            // A legacy draft stays restorable exactly while disk still equals
            // its stored base, which comparing digests of the two preserves.
            let legacyBaseContent = try container.decode(String.self, forKey: .legacyBaseContent)
            baseContentDigest = Self.digest(of: legacyBaseContent)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourcePath, forKey: .sourcePath)
        try container.encode(content, forKey: .content)
        try container.encode(baseContentDigest, forKey: .baseContentDigest)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    /// Whether `diskContent` is exactly the text these edits were made against.
    func isBased(on diskContent: String) -> Bool {
        baseContentDigest == Self.digest(of: diskContent)
    }

    /// Lowercase hex SHA-256 of the UTF-8 bytes of `content`.
    static func digest(of content: String) -> String {
        SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Identifies one deferred draft write reserved with
/// `RecoveryStore.reserveDeferredWrite(for:)`.
struct RecoveryDraftWriteTicket: Sendable {
    let url: URL
    fileprivate let key: String
    fileprivate let generation: UInt64
}

/// Orders recovery-draft I/O between the main actor and detached writes.
/// Every reservation gets a new generation; a deferred write runs only while
/// its generation is still the newest for its note, and every write, move
/// and removal runs under the lock. A slow stale write therefore can never
/// land after a newer write or removal of the same note.
private final class RecoveryDraftWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastGeneration: UInt64 = 0
    /// Notes with an outstanding deferred write, keyed by draft key.
    private var reservedGenerationByKey: [String: UInt64] = [:]

    func reserve(url: URL, key: String) -> RecoveryDraftWriteTicket {
        lock.lock()
        defer { lock.unlock() }
        lastGeneration &+= 1
        reservedGenerationByKey[key] = lastGeneration
        return RecoveryDraftWriteTicket(url: url, key: key, generation: lastGeneration)
    }

    /// Runs `body` if `ticket` is still the newest request for its note.
    @discardableResult
    func runIfCurrent<T>(_ ticket: RecoveryDraftWriteTicket, _ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard reservedGenerationByKey[ticket.key] == ticket.generation else { return nil }
        reservedGenerationByKey.removeValue(forKey: ticket.key)
        return body()
    }

    /// Supersedes every outstanding deferred write for `keys`, then runs
    /// `body`, after any write already in progress has finished.
    @discardableResult
    func supersedeAndRun<T>(keys: [String], _ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        for key in keys {
            reservedGenerationByKey.removeValue(forKey: key)
        }
        return try body()
    }
}

/// A small, vault-independent crash-recovery store. Drafts live in Application
/// Support rather than beside notes, so vaults remain clean and an unavailable
/// iCloud container cannot take the only copy of unsaved text with it.
struct RecoveryStore: Sendable {
    let directoryURL: URL
    /// Shared by copies of this store, so every write through them is ordered.
    private let writeGate = RecoveryDraftWriteGate()

    init(directoryURL: URL = RecoveryStore.defaultDirectoryURL()) {
        self.directoryURL = directoryURL.standardizedFileURL
    }

    /// Writes a draft now, superseding any deferred write still pending for
    /// the note. The base text is reduced to its digest before it is stored.
    func save(content: String, baseContent: String, for url: URL) throws {
        try save(content: content, baseContentDigest: RecoveryDraft.digest(of: baseContent), for: url)
    }

    func save(content: String, baseContentDigest: String, for url: URL) throws {
        let data = try encodedDraft(content: content, baseContentDigest: baseContentDigest, for: url)
        try writeGate.supersedeAndRun(keys: [Self.draftKey(for: url)]) {
            try writeEncodedDraft(data, for: url)
        }
    }

    /// Reserves a deferred write for `url`. A later reservation, save, move or
    /// removal for the same note supersedes it.
    func reserveDeferredWrite(for url: URL) -> RecoveryDraftWriteTicket {
        writeGate.reserve(url: url, key: Self.draftKey(for: url))
    }

    /// Writes the reserved draft unless its ticket has been superseded. Safe
    /// to call off the main actor; returns whether the draft was written.
    @discardableResult
    func save(content: String, baseContent: String, ifCurrent ticket: RecoveryDraftWriteTicket) -> Bool {
        // Hash and encode before taking the gate, so a large note never
        // keeps a synchronous save or removal waiting on that work.
        let digest = RecoveryDraft.digest(of: baseContent)
        guard let data = try? encodedDraft(content: content, baseContentDigest: digest, for: ticket.url) else {
            return false
        }
        let written = writeGate.runIfCurrent(ticket) {
            (try? writeEncodedDraft(data, for: ticket.url)) != nil
        }
        return written ?? false
    }

    func draft(for url: URL) -> RecoveryDraft? {
        guard let data = try? Data(contentsOf: draftURL(for: url)),
              let draft = try? JSONDecoder().decode(RecoveryDraft.self, from: data),
              draft.sourcePath == url.standardizedFileURL.path else {
            return nil
        }
        return draft
    }

    func removeDraft(for url: URL) {
        writeGate.supersedeAndRun(keys: [Self.draftKey(for: url)]) {
            try? FileManager.default.removeItem(at: draftURL(for: url))
        }
    }

    func moveDraft(from oldURL: URL, to newURL: URL) {
        let oldKey = Self.draftKey(for: oldURL)
        let newKey = Self.draftKey(for: newURL)
        // Both paths name one draft file; moving it onto itself would delete it.
        guard oldKey != newKey else { return }
        writeGate.supersedeAndRun(keys: [oldKey, newKey]) {
            guard let draft = draft(for: oldURL) else { return }
            do {
                let data = try encodedDraft(
                    content: draft.content,
                    baseContentDigest: draft.baseContentDigest,
                    for: newURL
                )
                try writeEncodedDraft(data, for: newURL)
                try? FileManager.default.removeItem(at: draftURL(for: oldURL))
            } catch {
                // Recovery is best-effort and must never make the primary rename or
                // move fail. If this write fails, the old-path draft remains intact.
            }
        }
    }

    private func encodedDraft(content: String, baseContentDigest: String, for url: URL) throws -> Data {
        let draft = RecoveryDraft(
            sourcePath: url.standardizedFileURL.path,
            content: content,
            baseContentDigest: baseContentDigest,
            updatedAt: Date()
        )
        return try JSONEncoder().encode(draft)
    }

    /// Callers hold the write gate.
    private func writeEncodedDraft(_ data: Data, for url: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try data.write(to: draftURL(for: url), options: .atomic)
    }

    private static func draftKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func draftURL(for url: URL) -> URL {
        directoryURL
            .appendingPathComponent(Self.stablePathKey(url.standardizedFileURL.path))
            .appendingPathExtension("json")
    }

    private static func stablePathKey(_ path: String) -> String {
        // FNV-1a is deterministic across launches (unlike Swift's Hasher) and
        // keeps filenames safely below APFS's component-length limit.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func defaultDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("com.md.MarkdownEditor", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
    }
}

private let markdownFileExtensions: Set<String> = ["md", "markdown", "mdown", "txt"]
private let imageFileExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "svg", "tiff", "bmp"]

struct CachedMarkdownMetadata: Sendable {
    let modificationDate: Date
    let noteTitle: String?
    let noteLinks: [NoteLinkReference]
    let noteBodyStorage: SearchableNoteBody

    var noteBody: String { noteBodyStorage.text }
}

/// Describes an unreconciled external modification: the file on disk changed
/// since we last loaded/saved it and its contents differ from the editor
/// buffer. Carries snapshots so resolution is correct even if the user has
/// navigated to another file in the meantime.
struct SaveConflict: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let fileName: String
    let onDiskContent: String
    let editorContent: String
}

@Observable
@MainActor
final class Workspace {
    var files: [FileItem] = [] {
        didSet { updateFileLookups(from: oldValue) }
    }
    var sidebarNodes: [SidebarNode] = []
    var selectedFileURL: URL? {
        didSet {
            selectedFileCanonicalPath = selectedFileURL.map { canonicalPath(for: $0) }
        }
    }
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            scheduleNoteGraphRefresh()
            scheduleRecoveryDraft()
        }
    }
    var noteGraph: NoteGraphSnapshot = .empty
    var vaultURL: URL?
    var sortOrder: SortOrder {
        didSet {
            guard !isRestoringSortOrder, oldValue != sortOrder else { return }
            persistSortOrder()
            guard vaultURL != nil else { return }
            applySortOrderInMemory()
        }
    }
    var isCommandPalettePresented = false
    var isLoadingSnapshot = false
    private(set) var searchIndexRevision: UInt64 = 0

    /// Set when a save fails (disk full, permissions, unmounted volume, …) so
    /// the UI can surface it instead of silently dropping the user's edits. The
    /// in-memory `text` is preserved so a later save can recover the content.
    var saveError: String?
    /// Set when the file changed on disk since we last read/wrote it, so we can
    /// ask the user how to resolve instead of clobbering the external edits.
    var saveConflict: SaveConflict?
    /// The note whose unsaved buffer was safely restored from local recovery.
    /// This is observable so a future UI can show a non-blocking recovery badge.
    var recoveredDraftURL: URL?

    var hasVault: Bool { vaultURL != nil }
    var hasUnsavedChanges: Bool {
        selectedFileIsMarkdown && persistedText != nil && persistedText != text
    }
    var selectedFileIsMarkdown: Bool {
        guard let selectedFileURL else { return false }
        return Self.isMarkdownFile(selectedFileURL)
    }

    var selectedFileIsImage: Bool {
        guard let selectedFileURL else { return false }
        return Self.isImageFile(selectedFileURL)
    }

    var selectedFileName: String {
        guard let selectedFileURL else { return "" }
        if let selected = fileItem(for: selectedFileURL) {
            return title(for: selected)
        }
        if let node = sidebarNode(for: selectedFileURL) {
            return node.name
        }
        return selectedFileURL.deletingPathExtension().lastPathComponent
    }

    var sortedFiles: [FileItem] { files }
    var assetLookupSnapshot: [String: [URL]] { assetLookupByFilename }

    private static let bookmarkKey = "vaultBookmark"
    /// One `[canonical path: [location, length]]` dictionary per vault.
    private static let editorSelectionsKeyPrefix = "editorSelections::"
    /// Per-note keys written by earlier versions; migrated once per vault,
    /// then removed.
    private static let legacyEditorSelectionKeyPrefix = "editorSelection::"
    /// Per-vault marker (suffixed with the vault path) recording that the
    /// vault's legacy keys were imported and removed.
    private static let legacyEditorSelectionsMigratedKeyPrefix = "editorSelectionsLegacyKeysMigrated::"
    private static let noteGraphDebounceNanoseconds: UInt64 = 250_000_000
    private let preferences: AppPreferences
    private let recoveryStore: RecoveryStore
    private let userDefaults: UserDefaults
    private var activeSecurityScopedVaultURL: URL?
    private var autosaveTask: Task<Void, Never>?
    private var recoveryDraftTask: Task<Void, Never>?
    private var snapshotLoadTask: Task<Void, Never>?
    private var noteGraphRefreshTask: Task<Void, Never>?
    private var externalChangeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingExternalChanges = VaultFileChangeBatch()
    private var vaultFilePresenter: VaultFilePresenter?
    private var snapshotGeneration = 0
    private var noteGraphGeneration = 0
    private var cachedMarkdownMetadataByPath: [String: CachedMarkdownMetadata] = [:]
    private var noteSearchIndex = NoteSearchIndex()
    private var assetLookupByFilename: [String: [URL]] = [:]
    /// The open vault's editor selections keyed by canonical path, read from
    /// defaults once per vault. `editorSelection(for:)` runs while views
    /// evaluate, so this state stays out of observation tracking.
    @ObservationIgnored private var editorSelectionsByPath: [String: [Int]] = [:]
    /// The defaults key `editorSelectionsByPath` belongs to; `nil` while no
    /// vault is open, when selections are only kept in memory.
    @ObservationIgnored private var loadedEditorSelectionsKey: String?
    @ObservationIgnored private var hasLoadedEditorSelections = false
    @ObservationIgnored private var hasPendingEditorSelectionsWrite = false
    @ObservationIgnored private var editorSelectionsPersistTask: Task<Void, Never>?
    private var persistedText: String?
    private var isReplacingEditorBuffer = false
    /// Memoized `FileItem.canonicalPath(for:)` results. Lookups fill it, so
    /// it must not take part in observation tracking.
    @ObservationIgnored private var canonicalPathCache: [URL: String] = [:]
    /// `files` keyed by canonical path, rebuilt in the `files` observer.
    private var filesByCanonicalPath: [String: FileItem] = [:]
    @ObservationIgnored private var fileIndexByCanonicalPath: [String: Int] = [:]
    /// `selectedFileURL`'s canonical path, computed once per selection change.
    private var selectedFileCanonicalPath: String?
    @ObservationIgnored private var isRestoringSortOrder = false

    init(
        preferences: AppPreferences = AppPreferences(),
        recoveryStore: RecoveryStore = RecoveryStore(),
        userDefaults: UserDefaults = .standard
    ) {
        self.preferences = preferences
        self.recoveryStore = recoveryStore
        self.userDefaults = userDefaults
        self.sortOrder = preferences.defaultSortOrder
        if let data = userDefaults.data(forKey: Self.bookmarkKey) {
            restoreVault(from: data)
        }
    }

    // MARK: - Vault Management

    func pickVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder for your markdown files"
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVault(url)
    }

    @discardableResult
    func openVault(_ url: URL) -> Bool {
        guard saveCurrentFile().allowsTransition else { return false }

        beginAccessingVault(url)
        persistVaultBookmark(for: url)
        vaultURL = url
        restoreSortOrder()
        selectedFileURL = nil
        replaceEditorBuffer(with: "", persistedContent: nil)
        recoveredDraftURL = nil
        clearInventory()
        refreshFilesInBackground(
            preferredSelectionURL: restoreSelectedFileURL(),
            selectFirstFileIfNeeded: true
        )
        return true
    }

    /// Drops every loaded directory artifact (inventory, caches, search index
    /// and graph) ahead of a fresh snapshot.
    private func clearInventory() {
        files = []
        sidebarNodes = []
        cachedMarkdownMetadataByPath = [:]
        assetLookupByFilename = [:]
        canonicalPathCache.removeAll(keepingCapacity: false)
        resetSearchIndex()
        clearNoteGraph()
    }

    private func restoreVault(from bookmarkData: Data) {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            // Do not leave an expired/corrupt bookmark poisoning every launch.
            userDefaults.removeObject(forKey: Self.bookmarkKey)
            return
        }

        if isStale {
            guard let fresh = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else {
                userDefaults.removeObject(forKey: Self.bookmarkKey)
                return
            }
            userDefaults.set(fresh, forKey: Self.bookmarkKey)
        }

        beginAccessingVault(url)
        vaultURL = url
        restoreSortOrder()

        selectedFileURL = nil
        replaceEditorBuffer(with: "", persistedContent: nil)
        recoveredDraftURL = nil
        clearInventory()
        refreshFilesInBackground(
            preferredSelectionURL: restoreSelectedFileURL(),
            selectFirstFileIfNeeded: true
        )
    }

    // MARK: - File Operations

    func refreshFiles() {
        snapshotLoadTask?.cancel()
        snapshotGeneration += 1
        isLoadingSnapshot = false

        guard let vaultURL else {
            clearInventory()
            return
        }

        let snapshot = Self.snapshotDirectory(
            at: vaultURL,
            sortOrder: sortOrder,
            cachedMarkdownMetadataByPath: cachedMarkdownMetadataByPath
        )
        applyDirectorySnapshot(snapshot)

        if let selectedFileURL {
            if let matchingURL = matchingSidebarURL(for: selectedFileURL) {
                self.selectedFileURL = matchingURL
            } else {
                preserveDirtyBufferOrClearMissingSelection(selectedFileURL)
            }
        }

        refreshNoteGraph()
    }

    @discardableResult
    func selectFile(_ url: URL) -> Bool {
        let canonicalURL = matchingSidebarURL(for: url) ?? url
        if let selectedFileURL, urlsMatch(selectedFileURL, canonicalURL) {
            return true
        }

        guard saveCurrentFile().allowsTransition else { return false }
        if Self.isMarkdownFile(canonicalURL) {
            let diskContent: String
            do {
                diskContent = try Self.readFileContentsThrowing(canonicalURL)
            } catch {
                saveError = Self.openErrorMessage(for: canonicalURL, error: error)
                return false
            }

            selectedFileURL = canonicalURL
            let recoveredContent = recoverableContent(for: canonicalURL, diskContent: diskContent)
            replaceEditorBuffer(with: recoveredContent, persistedContent: diskContent)
            persistSelectedFileURL(canonicalURL)
            updateCachedMetadata(for: canonicalURL, content: diskContent)
        } else {
            selectedFileURL = canonicalURL
            replaceEditorBuffer(with: "", persistedContent: nil)
            recoveredDraftURL = nil
            persistSelectedFileURL(canonicalURL)
        }
        return true
    }

    /// Closes the active document without closing the vault. The transition is
    /// refused when the current buffer cannot be saved, matching file and vault
    /// switching semantics so closing the final tab cannot discard edits.
    @discardableResult
    func clearSelection() -> Bool {
        guard saveCurrentFile().allowsTransition else { return false }
        selectedFileURL = nil
        replaceEditorBuffer(with: "", persistedContent: nil)
        recoveredDraftURL = nil
        clearStoredSelectedFileURL()
        return true
    }

    private func readFile(_ url: URL) -> String? {
        Self.readFileContents(url)
    }

    @discardableResult
    func saveCurrentFile() -> DocumentSaveResult {
        autosaveTask?.cancel()
        guard let url = selectedFileURL else { return .noEditableDocument }
        guard Self.isMarkdownFile(url) else { return .noEditableDocument }
        // While a conflict alert is pending, don't keep re-writing/re-prompting.
        guard saveConflict == nil else {
            persistRecoveryDraftNow()
            return .conflict
        }
        guard persistedText != nil else {
            let message = "Couldn’t save \(url.lastPathComponent) because its original contents were not loaded. Reopen the note before saving; the current buffer was kept unchanged."
            saveError = message
            return .failed(message)
        }
        guard persistedText != text else {
            recoveryStore.removeDraft(for: url)
            return .noChanges
        }
        return writeBuffer(text, to: url)
    }

    /// Writes `content` to `url`, but first guards against clobbering an
    /// external modification, and surfaces (rather than swallows) write errors.
    private func writeBuffer(_ content: String, to url: URL) -> DocumentSaveResult {
        guard let persistedText else {
            let message = "Couldn’t save \(url.lastPathComponent) because its original contents were not loaded."
            saveError = message
            return .failed(message)
        }
        do {
            let outcome = try Self.coordinatedConditionalWrite(
                Data(content.utf8),
                expectedContent: persistedText,
                to: url
            )
            if case .conflict(let diskContent) = outcome {
                saveConflict = SaveConflict(
                    url: url,
                    fileName: url.lastPathComponent,
                    onDiskContent: diskContent,
                    editorContent: content
                )
                _ = persistRecoveryDraftNow()
                return .conflict
            }

            saveError = nil
            self.persistedText = content
            recoveryStore.removeDraft(for: url)
            updateCachedMetadata(for: url, content: content)
            return .saved
        } catch {
            let recoverySaved = persistRecoveryDraftNow()
            let message = Self.saveErrorMessage(
                for: url,
                error: error,
                recoverySaved: recoverySaved
            )
            saveError = message
            return .failed(message)
        }
    }

    /// Conflict resolution: overwrite the on-disk file with the editor buffer.
    /// Uses the live buffer when the conflict file is still selected so edits
    /// typed while the alert was open are not discarded with the recovery draft.
    func resolveSaveConflictKeepingMine() {
        guard let conflict = saveConflict else { return }
        let contentToKeep: String
        if let selectedFileURL, urlsMatch(selectedFileURL, conflict.url) {
            contentToKeep = text
        } else {
            contentToKeep = conflict.editorContent
        }
        saveConflict = nil
        do {
            try Self.coordinatedWrite(Data(contentToKeep.utf8), to: conflict.url)
            saveError = nil
            if let selectedFileURL, urlsMatch(selectedFileURL, conflict.url) {
                persistedText = contentToKeep
            }
            recoveryStore.removeDraft(for: conflict.url)
            updateCachedMetadata(for: conflict.url, content: contentToKeep)
        } catch {
            let recoverySaved = persistRecoveryDraftNow()
            saveError = Self.saveErrorMessage(
                for: conflict.url,
                error: error,
                recoverySaved: recoverySaved
            )
        }
    }

    /// Conflict resolution: discard the editor buffer and adopt the on-disk
    /// version (loading it into the editor if it is still the selected file).
    func resolveSaveConflictUsingDisk() {
        guard let conflict = saveConflict else { return }
        saveConflict = nil
        if let selectedFileURL, urlsMatch(selectedFileURL, conflict.url) {
            replaceEditorBuffer(with: conflict.onDiskContent, persistedContent: conflict.onDiskContent)
            recoveredDraftURL = nil
        }
        recoveryStore.removeDraft(for: conflict.url)
        updateCachedMetadata(for: conflict.url, content: conflict.onDiskContent)
    }

    func scheduleAutosave() {
        guard selectedFileIsMarkdown else { return }

        autosaveTask?.cancel()
        let delayNanoseconds = UInt64(preferences.autosaveDelaySeconds * 1_000_000_000)
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.saveCurrentFile()
        }
    }

    private func scheduleRecoveryDraft() {
        guard !isReplacingEditorBuffer, selectedFileIsMarkdown, persistedText != nil else { return }
        recoveryDraftTask?.cancel()

        guard hasUnsavedChanges else {
            if let selectedFileURL {
                recoveryStore.removeDraft(for: selectedFileURL)
            }
            return
        }

        recoveryDraftTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.writeRecoveryDraftInBackground()
        }
    }

    /// Hands the dirty buffer to a detached write so typing pauses never wait
    /// on disk. The write's ticket is reserved here, on the main actor: any
    /// later save, removal, move or newer draft for the note supersedes it,
    /// so a slow stale write can never replace newer recovery state.
    private func writeRecoveryDraftInBackground() {
        guard let selectedFileURL,
              selectedFileIsMarkdown,
              let persistedText,
              persistedText != text else {
            return
        }
        let recoveryStore = recoveryStore
        let ticket = recoveryStore.reserveDeferredWrite(for: selectedFileURL)
        let content = text
        Task.detached(priority: .userInitiated) {
            recoveryStore.save(content: content, baseContent: persistedText, ifCurrent: ticket)
        }
    }

    /// Flushes the current dirty buffer to local recovery immediately. Save
    /// failure and conflict paths call this synchronously before returning;
    /// the write supersedes any detached draft write still in flight.
    @discardableResult
    func persistRecoveryDraftNow() -> Bool {
        recoveryDraftTask?.cancel()
        guard let selectedFileURL,
              selectedFileIsMarkdown,
              let persistedText,
              persistedText != text else {
            return false
        }
        do {
            try recoveryStore.save(content: text, baseContent: persistedText, for: selectedFileURL)
            return true
        } catch {
            return false
        }
    }

    func recoveryDraft(for url: URL) -> RecoveryDraft? {
        recoveryStore.draft(for: url)
    }

    /// Allows a future recovery UI to restore even a draft whose base no longer
    /// matches disk. Automatic restore is intentionally stricter (see below).
    @discardableResult
    func restoreRecoveryDraft(for url: URL) -> Bool {
        guard let selectedFileURL,
              urlsMatch(selectedFileURL, url),
              let draft = recoveryStore.draft(for: url) else {
            return false
        }
        isReplacingEditorBuffer = true
        text = draft.content
        isReplacingEditorBuffer = false
        recoveredDraftURL = url.standardizedFileURL
        return true
    }

    func createNewFile(in directoryURL: URL? = nil) {
        if let destinationDirectoryURL = destinationDirectoryURL(for: directoryURL) {
            for _ in 0..<32 {
                let fileURL = uniqueMarkdownFileURL(in: destinationDirectoryURL)
                let name = fileURL.deletingPathExtension().lastPathComponent
                let content = Data("# \(name)\n\n".utf8)

                do {
                    guard try ExclusiveAtomicFileWriter.writeIfAbsent(
                        content,
                        to: fileURL,
                        fileManager: .default
                    ) else {
                        continue
                    }
                    refreshFiles()
                    selectFile(fileURL)
                    return
                } catch {
                    if directoryURL == nil {
                        presentStandaloneFileSavePanel()
                    }
                    return
                }
            }

            if directoryURL == nil {
                presentStandaloneFileSavePanel()
            }
            return
        }

        presentStandaloneFileSavePanel()
    }

    /// Conditionally replaces a note body under file coordination. When the
    /// note is the selected editor buffer, updates the live buffer instead.
    @discardableResult
    func replaceNoteBody(
        at url: URL,
        expected: String,
        replacement: String
    ) -> Bool {
        let standardized = url.resolvingSymlinksInPath().standardizedFileURL
        if let selectedFileURL, urlsMatch(selectedFileURL, standardized) {
            guard text == expected else { return false }
            text = replacement
            return true
        }

        do {
            return try VaultLinkRefactor.replaceIfCurrent(
                at: standardized,
                expected: expected,
                replacement: replacement
            )
        } catch {
            return false
        }
    }

    func deleteItem(_ url: URL) {
        let itemURL = matchingSidebarURL(for: url) ?? url.resolvingSymlinksInPath().standardizedFileURL
        let isDirectory = isDirectoryURL(itemURL)
        // Resolved before trashing, while the item's path still resolves.
        let selectionRootPaths = editorSelectionRootPaths(for: itemURL)
        let shouldClearSelectedFile = selectedFileURL.map {
            deletedItem(itemURL, isDirectory: isDirectory, contains: $0)
        } ?? false

        if shouldClearSelectedFile, selectedFileIsMarkdown,
           !saveCurrentFile().allowsTransition {
            return
        }

        guard (try? FileManager.default.trashItem(at: itemURL, resultingItemURL: nil)) != nil else {
            return
        }

        removeStoredEditorSelections(underRootPaths: selectionRootPaths)

        if shouldClearSelectedFile {
            if let selectedFileURL {
                recoveryStore.removeDraft(for: selectedFileURL)
            }
            self.selectedFileURL = nil
            replaceEditorBuffer(with: "", persistedContent: nil)
            recoveredDraftURL = nil
            clearStoredSelectedFileURL()
        }

        refreshFiles()
    }

    func importDroppedFile(_ url: URL) {
        let sourceURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isMarkdownFile(sourceURL), let vaultURL else {
            _ = openRequestedFiles([sourceURL])
            return
        }

        if sourceURL.path.hasPrefix(vaultURL.standardizedFileURL.path + "/") {
            _ = selectFile(sourceURL)
            return
        }

        guard saveCurrentFile().allowsTransition else { return }
        let destinationURL = uniqueImportURL(
            for: sourceURL.lastPathComponent,
            in: vaultURL.standardizedFileURL
        )
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            refreshFiles()
            _ = selectFile(destinationURL)
        } catch {
            saveError = "Couldn’t import \(sourceURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func uniqueImportURL(for filename: String, in directoryURL: URL) -> URL {
        let pathExtension = (filename as NSString).pathExtension
        let baseName = (filename as NSString).deletingPathExtension
        var candidate = directoryURL.appendingPathComponent(filename)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = pathExtension.isEmpty
                ? "\(baseName) \(suffix)"
                : "\(baseName) \(suffix).\(pathExtension)"
            candidate = directoryURL.appendingPathComponent(nextName)
            suffix += 1
        }
        return candidate
    }

    @discardableResult
    func openRequestedFiles(_ urls: [URL]) -> Bool {
        guard let url = urls
            .map({ $0.resolvingSymlinksInPath().standardizedFileURL })
            .first(where: { Self.isMarkdownFile($0) || Self.isImageFile($0) }) else {
            return false
        }

        // If the file already lives inside the open vault, just select it.
        // Replacing the whole vault (tearing down the sidebar, file index, and
        // selection) is jarring and unnecessary for an in-vault file.
        if let vaultURL,
           url.standardizedFileURL.path.hasPrefix(vaultURL.standardizedFileURL.path + "/") {
            return selectFile(url)
        }

        guard saveCurrentFile().allowsTransition else { return false }

        let diskContent: String?
        if Self.isMarkdownFile(url) {
            do {
                diskContent = try Self.readFileContentsThrowing(url)
            } catch {
                saveError = Self.openErrorMessage(for: url, error: error)
                return false
            }
        } else {
            diskContent = nil
        }

        let parentURL = url.deletingLastPathComponent()
        beginAccessingVault(parentURL)
        persistVaultBookmark(for: parentURL)

        if vaultURL?.standardizedFileURL != parentURL.standardizedFileURL {
            // Switching vaults drops the previous inventory instead of walking
            // the new directory synchronously; the background refresh below
            // rebuilds it while the opened note is already visible.
            clearInventory()
        }
        vaultURL = parentURL
        restoreSortOrder()

        if let diskContent {
            ensureOpenedFileIsVisible(at: url, markdownContent: diskContent)
            let recoveredContent = recoverableContent(for: url, diskContent: diskContent)
            replaceEditorBuffer(with: recoveredContent, persistedContent: diskContent)
        } else {
            ensureOpenedFileIsVisible(at: url, markdownContent: nil)
            replaceEditorBuffer(with: "", persistedContent: nil)
            recoveredDraftURL = nil
        }

        selectedFileURL = url
        persistSelectedFileURL(url)
        refreshFilesInBackground(preferredSelectionURL: url, selectFirstFileIfNeeded: false)
        return true
    }

    func createNewFolder(in directoryURL: URL? = nil) {
        guard let destinationDirectoryURL = destinationDirectoryURL(for: directoryURL) else {
            pickVault()
            return
        }

        let folderURL = uniqueFolderURL(in: destinationDirectoryURL)
        guard (try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)) != nil else {
            return
        }

        refreshFiles()
    }

    @discardableResult
    func moveItem(_ url: URL, toFolder directoryURL: URL?) -> Bool {
        guard let destinationDirectoryURL = destinationDirectoryURL(for: directoryURL) else {
            return false
        }

        let sourceURL = matchingSidebarURL(for: url) ?? url.resolvingSymlinksInPath().standardizedFileURL
        let standardizedSourceURL = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let standardizedDestinationDirectoryURL = destinationDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let currentParentURL = standardizedSourceURL.deletingLastPathComponent()

        guard standardizedSourceURL != standardizedDestinationDirectoryURL else {
            return false
        }

        guard currentParentURL != standardizedDestinationDirectoryURL else {
            return false
        }

        guard !isDescendant(standardizedDestinationDirectoryURL, of: standardizedSourceURL, allowEqual: true) else {
            return false
        }

        let destinationURL = standardizedDestinationDirectoryURL.appendingPathComponent(
            standardizedSourceURL.lastPathComponent,
            isDirectory: isDirectoryURL(standardizedSourceURL)
        )

        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            return false
        }

        let sourceIsDirectory = isDirectoryURL(standardizedSourceURL)
        let selectedURLAfterMove = selectedFileURL.flatMap {
            remappedURL(
                $0,
                from: standardizedSourceURL,
                to: destinationURL,
                sourceIsDirectory: sourceIsDirectory
            )
        }
        if selectedFileIsMarkdown, !saveCurrentFile().allowsTransition {
            return false
        }

        let linkRefactorEdits = makeLinkRefactorEdits(
            moving: standardizedSourceURL,
            to: destinationURL,
            sourceIsDirectory: sourceIsDirectory
        )
        let selectionRootPaths = editorSelectionRootPaths(for: standardizedSourceURL)

        guard (try? FileManager.default.moveItem(at: standardizedSourceURL, to: destinationURL)) != nil else {
            return false
        }

        if let selectedURLAfterMove, let oldSelectedFileURL = selectedFileURL {
            selectedFileURL = selectedURLAfterMove
            persistSelectedFileURL(selectedURLAfterMove)
            recoveryStore.moveDraft(from: oldSelectedFileURL, to: selectedURLAfterMove)
        }

        moveStoredEditorSelections(fromRootPaths: selectionRootPaths, to: destinationURL)
        applyLinkRefactorEdits(linkRefactorEdits, operationName: "move")
        refreshFiles()
        return true
    }

    @discardableResult
    func renameItem(_ url: URL, to newName: String) throws -> URL {
        let newURL = try validatedRenamedURL(for: url, proposedName: newName)
        guard newURL != url else { return url }

        let sourceIsDirectory = isDirectoryURL(url)
        let isSelectedFile = selectedFileURL.map { urlsMatch($0, url) } ?? false
        let selectedURLAfterRename = selectedFileURL.flatMap {
            remappedURL($0, from: url, to: newURL, sourceIsDirectory: sourceIsDirectory)
        }
        let existingContent = Self.isMarkdownFile(url)
            ? (isSelectedFile ? text : readFile(url))
            : nil

        if selectedFileIsMarkdown {
            let result = saveCurrentFile()
            guard result.allowsTransition else {
                let message = saveError ?? "Resolve the unsaved changes before renaming this item."
                throw WorkspaceFileOperationError.unsavedChanges(message)
            }
        }


        let updatedContent = existingContent.map {
            contentAfterRename(oldURL: url, newURL: newURL, existingContent: $0)
        }
        let bodyOverrides = updatedContent.map { [url.standardizedFileURL: $0] } ?? [:]
        let linkRefactorEdits = makeLinkRefactorEdits(
            moving: url,
            to: newURL,
            sourceIsDirectory: sourceIsDirectory,
            bodyOverrides: bodyOverrides
        )
        let selectionRootPaths = editorSelectionRootPaths(for: url)

        try moveItemForRename(at: url, to: newURL)

        if let selectedURLAfterRename, let oldSelectedFileURL = selectedFileURL {
            selectedFileURL = selectedURLAfterRename
            persistSelectedFileURL(selectedURLAfterRename)
            recoveryStore.moveDraft(from: oldSelectedFileURL, to: selectedURLAfterRename)
        }
        moveStoredEditorSelections(fromRootPaths: selectionRootPaths, to: newURL)

        if let existingContent, let updatedContent {
            if updatedContent != existingContent {
                try Self.coordinatedWrite(Data(updatedContent.utf8), to: newURL)
            }

            if isSelectedFile {
                replaceEditorBuffer(with: updatedContent, persistedContent: updatedContent)
                recoveryStore.removeDraft(for: newURL)
            }
        }

        applyLinkRefactorEdits(linkRefactorEdits, operationName: "rename")

        refreshFiles()
        return newURL
    }

    private func makeLinkRefactorEdits(
        moving oldRoot: URL,
        to newRoot: URL,
        sourceIsDirectory: Bool,
        bodyOverrides: [URL: String] = [:]
    ) -> [VaultLinkRefactorEdit] {
        guard let vaultURL else { return [] }
        let liveSelectedBody = selectedFileIsMarkdown ? text : nil
        let notes = files.compactMap { file -> VaultLinkNoteSnapshot? in
            let standardizedURL = file.url.standardizedFileURL
            if let override = bodyOverrides[standardizedURL] {
                return VaultLinkNoteSnapshot(
                    url: standardizedURL,
                    body: override,
                    aliases: Self.aliases(in: override)
                )
            }
            if let liveSelectedBody, file.canonicalPath == selectedFileCanonicalPath {
                return VaultLinkNoteSnapshot(
                    url: standardizedURL,
                    body: liveSelectedBody,
                    aliases: Self.aliases(in: liveSelectedBody)
                )
            }
            // Cached bodies carry their parsed frontmatter, so aliases come
            // from the shared metadata instead of a fresh parse per note.
            let metadataKey = Self.metadataCacheKey(for: standardizedURL)
            guard let storage = cachedMarkdownMetadataByPath[metadataKey]?.noteBodyStorage else {
                return nil
            }
            return VaultLinkNoteSnapshot(
                url: standardizedURL,
                body: storage.text,
                aliases: ObsidianMetadataParser.aliases(in: storage.searchMetadata.properties)
            )
        }
        let assetURLs = Set(assetLookupByFilename.values.flatMap { $0 }.map {
            $0.resolvingSymlinksInPath().standardizedFileURL
        })
        return VaultLinkRefactor.edits(
            notes: notes,
            moving: oldRoot,
            to: newRoot,
            sourceIsDirectory: sourceIsDirectory,
            vaultURL: vaultURL,
            assetURLs: assetURLs
        )
    }

    private nonisolated static func aliases(in body: String) -> [String] {
        ObsidianMetadataParser.aliases(in: ObsidianMetadataParser.searchMetadata(in: body).properties)
    }

    private func applyLinkRefactorEdits(
        _ edits: [VaultLinkRefactorEdit],
        operationName: String
    ) {
        guard !edits.isEmpty else { return }
        do {
            try VaultLinkRefactor.apply(edits)
            if let selectedFileURL,
               let selectedEdit = edits.first(where: {
                   urlsMatch($0.destinationURL, selectedFileURL)
               }) {
                replaceEditorBuffer(
                    with: selectedEdit.updatedBody,
                    persistedContent: selectedEdit.updatedBody
                )
                recoveryStore.removeDraft(for: selectedFileURL)
            }
        } catch {
            saveError = "The item was \(operationName)d, but linked notes could not be updated safely: \(error.localizedDescription)"
        }
    }

    // MARK: - Editor Selections

    func persistEditorSelection(_ selection: NSRange, for url: URL?) {
        guard let url else { return }

        loadEditorSelectionsIfNeeded()
        let path = canonicalPath(for: url)
        let sanitizedSelection = [max(0, selection.location), max(0, selection.length)]
        guard editorSelectionsByPath[path] != sanitizedSelection else { return }
        editorSelectionsByPath[path] = sanitizedSelection
        scheduleEditorSelectionsPersist()
    }

    func editorSelection(for url: URL?) -> NSRange? {
        guard let url else {
            return nil
        }

        loadEditorSelectionsIfNeeded()
        guard let persistedSelection = editorSelectionsByPath[canonicalPath(for: url)],
              persistedSelection.count == 2 else {
            return nil
        }

        return NSRange(
            location: max(0, persistedSelection[0]),
            length: max(0, persistedSelection[1])
        )
    }

    private var editorSelectionsStorageKey: String? {
        guard let vaultURL else { return nil }
        return Self.editorSelectionsKeyPrefix + vaultURL.standardizedFileURL.path
    }

    /// Reads the open vault's selections the first time they are needed after
    /// the vault changed, writing back the previous vault's selections first.
    private func loadEditorSelectionsIfNeeded() {
        let storageKey = editorSelectionsStorageKey
        guard !hasLoadedEditorSelections || storageKey != loadedEditorSelectionsKey else { return }

        flushEditorSelections()
        hasLoadedEditorSelections = true
        loadedEditorSelectionsKey = storageKey
        guard let storageKey else {
            editorSelectionsByPath = [:]
            return
        }
        editorSelectionsByPath = Self.decodedEditorSelections(userDefaults.dictionary(forKey: storageKey))
        migrateLegacyEditorSelectionsIfNeeded()
    }

    private nonisolated static func decodedEditorSelections(_ dictionary: [String: Any]?) -> [String: [Int]] {
        guard let dictionary else { return [:] }
        return dictionary.compactMapValues { value in
            guard let selection = value as? [Int], selection.count == 2 else { return nil }
            return selection
        }
    }

    /// Earlier versions stored one `editorSelection::<path>` key per note and
    /// never pruned them. Once per vault, the entries inside the loaded
    /// vault's roots are imported and removed. Keys outside those roots
    /// belong to other vaults and stay until those vaults are opened.
    private func migrateLegacyEditorSelectionsIfNeeded() {
        guard let vaultURL else { return }
        let migratedKey = Self.legacyEditorSelectionsMigratedKeyPrefix + vaultURL.standardizedFileURL.path
        guard !userDefaults.bool(forKey: migratedKey) else { return }
        userDefaults.set(true, forKey: migratedKey)

        let prefix = Self.legacyEditorSelectionKeyPrefix
        let vaultRootPaths = editorSelectionRootPaths(for: vaultURL)
        var didImport = false
        for (key, value) in userDefaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            let path = String(key.dropFirst(prefix.count))
            guard Self.pathSuffix(of: path, underAnyOf: vaultRootPaths) != nil else { continue }
            userDefaults.removeObject(forKey: key)
            guard editorSelectionsByPath[path] == nil,
                  let selection = value as? [Int],
                  selection.count == 2 else {
                continue
            }
            editorSelectionsByPath[path] = selection
            didImport = true
        }
        if didImport {
            hasPendingEditorSelectionsWrite = true
            flushEditorSelections()
        }
    }

    private func scheduleEditorSelectionsPersist() {
        hasPendingEditorSelectionsWrite = true
        editorSelectionsPersistTask?.cancel()
        editorSelectionsPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.flushEditorSelections()
        }
    }

    /// Writes the in-memory selections back to the key they were read from.
    private func flushEditorSelections() {
        editorSelectionsPersistTask?.cancel()
        editorSelectionsPersistTask = nil
        guard hasPendingEditorSelectionsWrite else { return }
        hasPendingEditorSelectionsWrite = false
        guard let loadedEditorSelectionsKey else { return }
        if editorSelectionsByPath.isEmpty {
            userDefaults.removeObject(forKey: loadedEditorSelectionsKey)
        } else {
            userDefaults.set(editorSelectionsByPath, forKey: loadedEditorSelectionsKey)
        }
    }

    /// The spellings under which selections inside `url` may be recorded:
    /// its canonical and its standardized path. Callers resolve them before
    /// moving or trashing the item, while the item's own path still resolves.
    private func editorSelectionRootPaths(for url: URL) -> Set<String> {
        [canonicalPath(for: url), url.standardizedFileURL.path]
    }

    /// Re-keys the selections stored for an item, or anything inside it, to
    /// the item's new location. Only the in-memory dictionary is scanned.
    private func moveStoredEditorSelections(fromRootPaths oldRootPaths: Set<String>, to newRootURL: URL) {
        loadEditorSelectionsIfNeeded()
        guard !editorSelectionsByPath.isEmpty else { return }

        var movedSelections: [(oldPath: String, suffix: String, selection: [Int])] = []
        for (path, selection) in editorSelectionsByPath {
            guard let suffix = Self.pathSuffix(of: path, underAnyOf: oldRootPaths) else { continue }
            movedSelections.append((path, suffix, selection))
        }
        guard !movedSelections.isEmpty else { return }

        let newRootPath = canonicalPath(for: newRootURL)
        for moved in movedSelections {
            editorSelectionsByPath.removeValue(forKey: moved.oldPath)
        }
        for moved in movedSelections {
            editorSelectionsByPath[newRootPath + moved.suffix] = moved.selection
        }
        hasPendingEditorSelectionsWrite = true
        flushEditorSelections()
    }

    private func removeStoredEditorSelections(underRootPaths rootPaths: Set<String>) {
        loadEditorSelectionsIfNeeded()
        let removedPaths = editorSelectionsByPath.keys.filter {
            Self.pathSuffix(of: $0, underAnyOf: rootPaths) != nil
        }
        guard !removedPaths.isEmpty else { return }

        for path in removedPaths {
            editorSelectionsByPath.removeValue(forKey: path)
        }
        hasPendingEditorSelectionsWrite = true
        flushEditorSelections()
    }

    /// Drops selections of notes missing from a freshly applied snapshot, so
    /// the stored dictionary only ever holds notes that still exist. Nothing
    /// is pruned for an empty inventory (an unreadable or briefly unavailable
    /// vault), for a snapshot whose walk could not list every directory
    /// (its inventory is partial), or for selections outside the vault's
    /// roots (notes opened through a symlinked folder or from elsewhere,
    /// which the walk never inventories).
    private func pruneStoredEditorSelections(snapshotIsComplete: Bool) {
        guard snapshotIsComplete, let vaultURL else { return }
        loadEditorSelectionsIfNeeded()
        guard !editorSelectionsByPath.isEmpty, !files.isEmpty else { return }

        let vaultRootPaths = editorSelectionRootPaths(for: vaultURL)
        let stalePaths = editorSelectionsByPath.keys.filter {
            filesByCanonicalPath[$0] == nil
                && Self.pathSuffix(of: $0, underAnyOf: vaultRootPaths) != nil
        }
        guard !stalePaths.isEmpty else { return }

        for path in stalePaths {
            editorSelectionsByPath.removeValue(forKey: path)
        }
        hasPendingEditorSelectionsWrite = true
        flushEditorSelections()
    }

    /// `""` when `path` is one of `roots`, `"/rest"` when it lies inside one
    /// of them, and `nil` otherwise.
    private nonisolated static func pathSuffix(of path: String, underAnyOf roots: Set<String>) -> String? {
        for root in roots {
            if path == root {
                return ""
            }
            let rootPrefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(rootPrefix) {
                return "/" + String(path.dropFirst(rootPrefix.count))
            }
        }
        return nil
    }

    func title(for file: FileItem) -> String {
        // `selectedFileURL` is read so observers keep tracking the selection.
        if selectedFileURL != nil, file.canonicalPath == selectedFileCanonicalPath,
           let liveTitle = Self.extractTitle(from: text) {
            return liveTitle
        }
        return file.sidebarTitle
    }

    /// O(1): one memoized canonical-path lookup plus a dictionary read.
    func fileItem(for url: URL) -> FileItem? {
        guard !files.isEmpty else { return nil }
        return filesByCanonicalPath[canonicalPath(for: url)]
    }

    /// Symlink-insensitive identity for `url`. Resolving symlinks costs tens
    /// of microseconds, so results are memoized; the cache is seeded from
    /// `files`, cleared with every directory snapshot and bounded so stray
    /// URLs (stored selections, drops) cannot grow it without limit.
    func canonicalPath(for url: URL) -> String {
        if let cached = canonicalPathCache[url] {
            return cached
        }
        let path = FileItem.canonicalPath(for: url)
        if canonicalPathCache.count >= 4 * files.count + 1000 {
            canonicalPathCache.removeAll(keepingCapacity: true)
            for file in files {
                canonicalPathCache[file.url] = file.canonicalPath
            }
        }
        canonicalPathCache[url] = path
        return path
    }

    /// Symlink-insensitive URL equality backed by `canonicalPath(for:)`.
    private func urlsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalPath(for: lhs) == canonicalPath(for: rhs)
    }

    /// Keeps the canonical-path dictionaries in step with `files`. A record
    /// refreshed in place (the common autosave case) only touches its own
    /// dictionary value; any other change rebuilds both lookups.
    private func updateFileLookups(from previousFiles: [FileItem]) {
        guard previousFiles.count == files.count else {
            rebuildFileLookups()
            return
        }
        for index in files.indices where files[index].canonicalPath != previousFiles[index].canonicalPath {
            rebuildFileLookups()
            return
        }
        for index in files.indices where files[index] != previousFiles[index] {
            let file = files[index]
            // Symlinked notes can share a canonical path; the first file in
            // `files` order stays the lookup result, as `first(where:)` did.
            if fileIndexByCanonicalPath[file.canonicalPath] == index {
                filesByCanonicalPath[file.canonicalPath] = file
            }
            canonicalPathCache[file.url] = file.canonicalPath
        }
        // A memo cleared for a new snapshot is re-seeded even when no record
        // changed, so note URLs never fall back to resolving symlinks.
        if canonicalPathCache.count < files.count {
            for file in files {
                canonicalPathCache[file.url] = file.canonicalPath
            }
        }
    }

    private func rebuildFileLookups() {
        var byPath: [String: FileItem] = [:]
        var indexByPath: [String: Int] = [:]
        byPath.reserveCapacity(files.count)
        indexByPath.reserveCapacity(files.count)
        for (index, file) in files.enumerated() {
            if indexByPath[file.canonicalPath] == nil {
                byPath[file.canonicalPath] = file
                indexByPath[file.canonicalPath] = index
            }
            canonicalPathCache[file.url] = file.canonicalPath
        }
        filesByCanonicalPath = byPath
        fileIndexByCanonicalPath = indexByPath
    }

    /// Re-sorts the loaded inventory for a user-initiated sort change. The
    /// directory contents are unchanged, so there is no disk walk and no
    /// note-graph rebuild; the search index follows because its result order
    /// mirrors `files`.
    private func applySortOrderInMemory() {
        files = Self.sortFileItems(files, sortOrder: sortOrder)
        sidebarNodes = Self.sortSidebarNodesRecursively(sidebarNodes, sortOrder: sortOrder)
        reconcileSearchIndex()
    }

    func relativePath(for file: FileItem) -> String? {
        relativePath(for: file, vaultBasePath: vaultURL?.standardizedFileURL.path)
    }

    private func relativePath(for file: FileItem, vaultBasePath: String?) -> String? {
        guard let basePath = vaultBasePath else {
            return file.name == file.displayName ? nil : file.name
        }

        let filePath = file.url.standardizedFileURL.path
        guard filePath.hasPrefix(basePath) else {
            return file.name == file.displayName ? nil : file.name
        }

        let separatorAdjustedBase = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let relativePath = String(filePath.dropFirst(separatorAdjustedBase.count))
        return relativePath == file.name && file.name == file.displayName ? nil : relativePath
    }

    nonisolated static func extractTitle(from content: String) -> String? {
        let text = content as NSString
        guard text.length > 0 else { return nil }

        func isWhitespace(_ character: unichar) -> Bool {
            character == 32 || character == 9
        }

        func isNewline(_ character: unichar) -> Bool {
            character == 10 || character == 13
        }

        var location = 0
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            var start = lineRange.location
            var end = NSMaxRange(lineRange)

            while end > start, isNewline(text.character(at: end - 1)) {
                end -= 1
            }

            while start < end, isWhitespace(text.character(at: start)) {
                start += 1
            }

            while end > start, isWhitespace(text.character(at: end - 1)) {
                end -= 1
            }

            guard start < end else {
                location = NSMaxRange(lineRange)
                continue
            }

            guard text.character(at: start) == 35 else { return nil }

            while start < end, text.character(at: start) == 35 {
                start += 1
            }

            while start < end, isWhitespace(text.character(at: start)) {
                start += 1
            }

            while end > start, isWhitespace(text.character(at: end - 1)) {
                end -= 1
            }

            guard start < end else { return nil }
            return text.substring(with: NSRange(location: start, length: end - start))
        }

        return nil
    }

    private func clearNoteGraph() {
        noteGraphRefreshTask?.cancel()
        noteGraphGeneration += 1
        noteGraph = .empty
    }

    private func refreshNoteGraph() {
        scheduleNoteGraphRefresh(debounceNanoseconds: 0)
    }

    private func scheduleNoteGraphRefresh(debounceNanoseconds: UInt64? = nil) {
        let delay = debounceNanoseconds ?? Self.noteGraphDebounceNanoseconds
        noteGraphRefreshTask?.cancel()
        noteGraphGeneration += 1
        let generation = noteGraphGeneration
        let files = files
        let metadataByPath = cachedMarkdownMetadataByPath
        let vaultURL = vaultURL
        let selectedFileURL = selectedFileURL
        let liveSelectedMarkdown = selectedFileIsMarkdown ? text : nil
        // `noteGraph` only changes together with `noteGraphGeneration`, so
        // the generation check below guarantees this is still the live graph
        // when the rebuilt snapshot is compared against it.
        let previousGraph = noteGraph

        noteGraphRefreshTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }

            let changedSnapshot = await Task.detached(priority: .utility) { () -> NoteGraphSnapshot? in
                let snapshot = NoteGraphBuilder.makeSnapshot(
                    files: files,
                    metadataByPath: metadataByPath,
                    vaultURL: vaultURL,
                    selectedFileURL: selectedFileURL,
                    liveSelectedMarkdown: liveSelectedMarkdown
                )
                // An identical graph (an autosave that changed no links) is
                // dropped here so graph observers are not invalidated for it.
                return snapshot == previousGraph ? nil : snapshot
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, generation == self.noteGraphGeneration, let changedSnapshot else { return }
                self.noteGraph = changedSnapshot
            }
        }
    }

    /// Best-effort body lookup for a file URL, used by full-text search.
    /// Returns the live editor contents when the URL is the selected file
    /// so search reflects unsaved edits.
    func noteBody(for url: URL) -> String? {
        let canonical = canonicalPath(for: url)
        if selectedFileURL != nil,
           canonical == selectedFileCanonicalPath,
           selectedFileIsMarkdown {
            return text
        }
        return cachedMarkdownMetadataByPath[canonical]?.noteBody
    }

    /// Returns a cheap snapshot of the maintained index. Complete note bodies
    /// remain shared, so opening the palette does not retain a duplicate vault.
    func makeSearchEntries() -> [NoteSearchEntry] {
        var entries = noteSearchIndex.entries
        guard selectedFileURL != nil, selectedFileIsMarkdown,
              let selectedPath = selectedFileCanonicalPath,
              let index = searchEntryIndex(forCanonicalPath: selectedPath, in: entries),
              entries[index].body != text else {
            return entries
        }

        let existing = entries[index]
        entries[index] = NoteSearchEntry(
            id: existing.id,
            url: existing.url,
            title: existing.title,
            relativePath: existing.relativePath,
            bodyStorage: SearchableNoteBody(text),
            foldedTitle: existing.foldedTitle,
            foldedTitleHaystack: existing.foldedTitleHaystack,
            searchMetadata: nil
        )
        return entries
    }

    /// Index records follow `files` order, so the selected note is normally
    /// at the same position; the scan is only a fallback for stale snapshots.
    private func searchEntryIndex(forCanonicalPath path: String, in entries: [NoteSearchEntry]) -> Int? {
        if let index = fileIndexByCanonicalPath[path],
           entries.indices.contains(index),
           canonicalPath(for: entries[index].url) == path {
            return index
        }
        return entries.firstIndex { canonicalPath(for: $0.url) == path }
    }

    private func reconcileSearchIndex() {
        let vaultBasePath = vaultURL?.standardizedFileURL.path
        let candidates = files.map { file in
            let metadataKey = Self.metadataCacheKey(for: file.url)
            return makeSearchEntry(
                for: file,
                metadataKey: metadataKey,
                reusing: noteSearchIndex.entry(forPath: metadataKey),
                vaultBasePath: vaultBasePath
            )
        }
        if noteSearchIndex.reconcile(candidates) {
            searchIndexRevision &+= 1
        }
    }

    /// Builds the index record for `file`. When `existing` has the same
    /// title, relative path and body storage, its folded strings are reused
    /// so reconciling after an unrelated change does not re-fold every note.
    private func makeSearchEntry(
        for file: FileItem,
        metadataKey: String,
        reusing existing: NoteSearchEntry?,
        vaultBasePath: String?
    ) -> NoteSearchEntry {
        let title = title(for: file)
        let relativePath = relativePath(for: file, vaultBasePath: vaultBasePath)
        let bodyStorage = cachedMarkdownMetadataByPath[metadataKey]?.noteBodyStorage
            ?? SearchableNoteBody("")

        if let existing,
           existing.url == file.url,
           existing.title == title,
           existing.relativePath == relativePath,
           existing.bodyStorage === bodyStorage {
            return NoteSearchEntry(
                id: file.id,
                url: file.url,
                title: title,
                relativePath: relativePath,
                bodyStorage: bodyStorage,
                foldedTitle: existing.foldedTitle,
                foldedTitleHaystack: existing.foldedTitleHaystack
            )
        }

        let haystack = "\(title)\n\(file.displayName)\n\(file.name)"
        return NoteSearchEntry(
            id: file.id,
            url: file.url,
            title: title,
            relativePath: relativePath,
            bodyStorage: bodyStorage,
            foldedTitle: Self.foldedForSearch(title),
            foldedTitleHaystack: Self.foldedForSearch(haystack)
        )
    }

    private func resetSearchIndex() {
        if noteSearchIndex.removeAll() {
            searchIndexRevision &+= 1
        }
    }

    nonisolated static func foldedForSearch(_ string: String) -> String {
        string
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "İ", with: "I")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    /// Pure, `nonisolated` full-text filter so it can run inside a detached task
    /// for large vaults. Title/name matches rank above body matches; body
    /// matches carry a centered snippet for context.
    nonisolated static func search(_ entries: [NoteSearchEntry], query rawQuery: String) -> [NoteSearchResult] {
        search(entries, query: rawQuery, maximumConcurrency: ProcessInfo.processInfo.activeProcessorCount)
    }

    /// `maximumConcurrency` caps how many chunks of `entries` are scanned in
    /// parallel; `1` forces the sequential scan. Every value yields identical
    /// results in identical order, because ranking uses global indices.
    nonisolated static func search(
        _ entries: [NoteSearchEntry],
        query rawQuery: String,
        maximumConcurrency: Int
    ) -> [NoteSearchResult] {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return entries.map {
                NoteSearchResult(id: $0.id, url: $0.url, title: $0.title, subtitle: $0.relativePath, isBodyMatch: false)
            }
        }

        let foldedQuery = foldedForSearch(trimmedQuery)
        let chunkCount = searchChunkCount(entryCount: entries.count, maximumConcurrency: maximumConcurrency)
        let chunks: [SearchChunkMatches?]

        if chunkCount <= 1 {
            chunks = [
                scanSearchChunk(
                    entries[...],
                    foldedQuery: foldedQuery,
                    trimmedQuery: trimmedQuery,
                    isCancelled: { Task.isCancelled }
                )
            ]
        } else {
            // `concurrentPerform` workers run outside the calling task, so
            // they observe cancellation through a probe on that task. The
            // probe never outlives this closure.
            chunks = withUnsafeCurrentTask { currentTask -> [SearchChunkMatches?] in
                let probe = TaskCancellationProbe(task: currentTask)
                let buffer = ConcurrentResultBuffer<SearchChunkMatches>(count: chunkCount)
                let chunkSize = (entries.count + chunkCount - 1) / chunkCount
                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIndex in
                    let start = chunkIndex * chunkSize
                    let end = min(entries.count, start + chunkSize)
                    guard start < end else {
                        buffer.set(SearchChunkMatches(), at: chunkIndex)
                        return
                    }
                    if let matches = scanSearchChunk(
                        entries[start..<end],
                        foldedQuery: foldedQuery,
                        trimmedQuery: trimmedQuery,
                        isCancelled: { probe.isCancelled }
                    ) {
                        buffer.set(matches, at: chunkIndex)
                    }
                }
                return buffer.elements
            }
        }

        var titleMatches: [SearchTitleMatch] = []
        var bodyMatches: [NoteSearchResult] = []
        for chunk in chunks {
            // A missing chunk was cancelled; the sequential scan returned [].
            guard let chunk else { return [] }
            titleMatches.append(contentsOf: chunk.titleMatches)
            bodyMatches.append(contentsOf: chunk.bodyMatches)
        }

        let rankedTitleMatches = titleMatches
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.sourceIndex < $1.sourceIndex
            }
            .map(\.result)
        return rankedTitleMatches + bodyMatches
    }

    private nonisolated static func searchChunkCount(entryCount: Int, maximumConcurrency: Int) -> Int {
        let parallelThreshold = 512
        let minimumChunkSize = 256
        guard entryCount >= parallelThreshold, maximumConcurrency > 1 else { return 1 }
        return max(1, min(maximumConcurrency, entryCount / minimumChunkSize))
    }

    /// Scans one slice. Indices are the global `entries` indices, so ranking
    /// is chunk-independent. Returns `nil` when cancellation was observed.
    private nonisolated static func scanSearchChunk(
        _ entries: ArraySlice<NoteSearchEntry>,
        foldedQuery: String,
        trimmedQuery: String,
        isCancelled: () -> Bool
    ) -> SearchChunkMatches? {
        var matches = SearchChunkMatches()

        for sourceIndex in entries.indices {
            if sourceIndex.isMultiple(of: 32), isCancelled() {
                return nil
            }
            let entry = entries[sourceIndex]
            if entry.foldedTitleHaystack.contains(foldedQuery) {
                let rank: Int
                if entry.foldedTitle == foldedQuery {
                    rank = 0
                } else if entry.foldedTitle.hasPrefix(foldedQuery) {
                    rank = 1
                } else if entry.foldedTitle.contains(foldedQuery) {
                    rank = 2
                } else {
                    rank = 3
                }
                matches.titleMatches.append(
                    SearchTitleMatch(
                        rank: rank,
                        sourceIndex: sourceIndex,
                        result: NoteSearchResult(
                            id: entry.id,
                            url: entry.url,
                            title: entry.title,
                            subtitle: entry.relativePath,
                            isBodyMatch: false
                        )
                    )
                )
            } else if entry.bodyStorage.foldedText.contains(foldedQuery) {
                matches.bodyMatches.append(
                    NoteSearchResult(
                        id: entry.id,
                        url: entry.url,
                        title: entry.title,
                        fallbackSubtitle: entry.relativePath,
                        snippetSource: NoteSearchSnippetSource(
                            bodyStorage: entry.bodyStorage,
                            query: trimmedQuery
                        ),
                        isBodyMatch: true
                    )
                )
            }
        }

        return matches
    }

    /// Returns a single-line, match-centered snippet, or `nil` if `query` is not
    /// present in `body`. Offsets are computed within the trimmed line so the
    /// window stays aligned with the visible text.
    nonisolated static func searchSnippet(in body: String, query: String) -> String? {
        guard !body.isEmpty, !query.isEmpty else {
            return nil
        }

        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let matchRange = body.range(of: query, options: options)
            ?? body.range(
                of: query,
                options: options,
                range: body.startIndex..<body.endIndex,
                locale: Locale(identifier: "tr_TR")
            )
        guard let matchRange else {
            return nil
        }

        let lineRange = body.lineRange(for: matchRange)
        let trimmedLine = body[lineRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return nil }

        let maxLength = 140
        guard trimmedLine.count > maxLength else { return trimmedLine }

        // Re-locate the match inside the trimmed line so the window offsets are
        // consistent with the string we actually slice.
        let trimmedMatch = trimmedLine.range(of: query, options: options)
            ?? trimmedLine.range(
                of: query,
                options: options,
                range: trimmedLine.startIndex..<trimmedLine.endIndex,
                locale: Locale(identifier: "tr_TR")
            )
        guard let trimmedMatch else {
            return String(trimmedLine.prefix(maxLength)) + "\u{2026}"
        }

        let matchOffset = trimmedLine.distance(from: trimmedLine.startIndex, to: trimmedMatch.lowerBound)
        let windowStart = max(0, matchOffset - maxLength / 2)
        let startIndex = trimmedLine.index(trimmedLine.startIndex, offsetBy: windowStart)
        let endOffset = min(trimmedLine.count, windowStart + maxLength)
        let endIndex = trimmedLine.index(trimmedLine.startIndex, offsetBy: endOffset)
        var snippet = String(trimmedLine[startIndex..<endIndex])

        if startIndex != trimmedLine.startIndex {
            snippet = "\u{2026}" + snippet
        }
        if endIndex != trimmedLine.endIndex {
            snippet += "\u{2026}"
        }
        return snippet
    }


    private func replaceEditorBuffer(with content: String, persistedContent: String?) {
        recoveryDraftTask?.cancel()
        persistedText = persistedContent
        isReplacingEditorBuffer = true
        text = content
        isReplacingEditorBuffer = false
    }

    private func recoverableContent(for url: URL, diskContent: String) -> String {
        guard let draft = recoveryStore.draft(for: url) else {
            recoveredDraftURL = nil
            return diskContent
        }

        if draft.content == diskContent {
            recoveryStore.removeDraft(for: url)
            recoveredDraftURL = nil
            return diskContent
        }

        // Automatic recovery is safe only if the file is still the exact base
        // the unsaved edits were made against. A divergent draft remains on
        // disk for explicit recovery instead of overwriting external changes.
        guard draft.isBased(on: diskContent) else {
            recoveredDraftURL = nil
            return diskContent
        }

        recoveredDraftURL = url.standardizedFileURL
        return draft.content
    }

    private func preserveDirtyBufferOrClearMissingSelection(_ missingURL: URL) {
        guard hasUnsavedChanges else {
            selectedFileURL = nil
            replaceEditorBuffer(with: "", persistedContent: nil)
            recoveredDraftURL = nil
            clearStoredSelectedFileURL()
            return
        }

        let recoverySaved = persistRecoveryDraftNow()
        let recoveryStatus = recoverySaved
            ? "A recovery draft was kept."
            : "The recovery draft could not be written, so keep this window open and copy your text somewhere safe."
        saveError = "Couldn’t find \(missingURL.lastPathComponent). Your unsaved text is still open. \(recoveryStatus) Restore the file or use Save again after making it available."
    }

    private nonisolated static func openErrorMessage(for url: URL, error: Error) -> String {
        "Couldn’t open \(url.lastPathComponent): \(error.localizedDescription). The current note was kept unchanged."
    }

    private nonisolated static func saveErrorMessage(
        for url: URL,
        error: Error,
        recoverySaved: Bool
    ) -> String {
        let recoveryStatus = recoverySaved
            ? "Your text is still open and was copied to local recovery."
            : "Your text is still open, but local recovery could not be written; copy it somewhere safe before closing the app."
        return "Couldn’t save \(url.lastPathComponent): \(error.localizedDescription). \(recoveryStatus)"
    }

    private func remappedURL(
        _ candidateURL: URL,
        from sourceURL: URL,
        to destinationURL: URL,
        sourceIsDirectory: Bool
    ) -> URL? {
        let candidate = candidateURL.standardizedFileURL
        let source = sourceURL.standardizedFileURL
        if urlsMatch(candidate, source) {
            return destinationURL.standardizedFileURL
        }

        guard sourceIsDirectory else { return nil }
        let sourcePrefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
        guard candidate.path.hasPrefix(sourcePrefix) else { return nil }
        let relativePath = String(candidate.path.dropFirst(sourcePrefix.count))
        return destinationURL.appendingPathComponent(relativePath).standardizedFileURL
    }

    private func validatedRenamedURL(for url: URL, proposedName: String) throws -> URL {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ItemRenameError.emptyName
        }

        guard trimmedName.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\n\r")) == nil else {
            throw ItemRenameError.invalidName
        }

        let pathExtension = url.pathExtension
        var sanitizedName = trimmedName

        if !pathExtension.isEmpty {
            let extensionSuffix = "." + pathExtension
            if sanitizedName.lowercased().hasSuffix(extensionSuffix.lowercased()) {
                sanitizedName.removeLast(extensionSuffix.count)
                sanitizedName = sanitizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard !sanitizedName.isEmpty else {
            throw ItemRenameError.emptyName
        }

        let parentURL = url.deletingLastPathComponent()
        let newURL: URL

        if pathExtension.isEmpty {
            newURL = parentURL.appendingPathComponent(sanitizedName)
        } else {
            newURL = parentURL
                .appendingPathComponent(sanitizedName)
                .appendingPathExtension(pathExtension)
        }

        if newURL.standardizedFileURL == url.standardizedFileURL {
            return url
        }

        let isCaseOnlyRename = newURL.standardizedFileURL.path.caseInsensitiveCompare(url.standardizedFileURL.path) == .orderedSame
        if FileManager.default.fileExists(atPath: newURL.path), !isCaseOnlyRename {
            throw ItemRenameError.nameAlreadyExists
        }

        return newURL
    }

    private func contentAfterRename(oldURL: URL, newURL: URL, existingContent: String) -> String {
        let oldDisplayName = oldURL.deletingPathExtension().lastPathComponent
        let newDisplayName = newURL.deletingPathExtension().lastPathComponent
        guard let currentTitle = Self.extractTitle(from: existingContent), currentTitle == oldDisplayName else {
            return existingContent
        }

        return Self.replacingLeadingTitle(in: existingContent, with: newDisplayName)
    }

    private func moveItemForRename(at url: URL, to newURL: URL) throws {
        let standardizedSourceURL = url.standardizedFileURL
        let standardizedDestinationURL = newURL.standardizedFileURL
        let isCaseOnlyRename = standardizedSourceURL.path.caseInsensitiveCompare(standardizedDestinationURL.path) == .orderedSame

        if isCaseOnlyRename, standardizedSourceURL.path != standardizedDestinationURL.path {
            let temporaryURL = uniqueIntermediateRenameURL(for: url)
            try FileManager.default.moveItem(at: url, to: temporaryURL)

            do {
                try FileManager.default.moveItem(at: temporaryURL, to: newURL)
            } catch {
                try? FileManager.default.moveItem(at: temporaryURL, to: url)
                throw error
            }

            return
        }

        try FileManager.default.moveItem(at: url, to: newURL)
    }

    private func uniqueIntermediateRenameURL(for url: URL) -> URL {
        let folderURL = url.deletingLastPathComponent()
        let token = UUID().uuidString
        let baseName = "." + url.deletingPathExtension().lastPathComponent + "-" + token
        let pathExtension = url.pathExtension

        if pathExtension.isEmpty {
            return folderURL.appendingPathComponent(baseName)
        }

        return folderURL
            .appendingPathComponent(baseName)
            .appendingPathExtension(pathExtension)
    }

    private static func replacingLeadingTitle(in content: String, with title: String) -> String {
        var lineStart = content.startIndex

        while lineStart < content.endIndex {
            let lineEnd = content[lineStart...].firstIndex(where: \.isNewline) ?? content.endIndex
            let line = content[lineStart..<lineEnd]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                guard lineEnd < content.endIndex else { return content }
                lineStart = content.index(after: lineEnd)
                continue
            }

            guard trimmed.hasPrefix("#") else {
                return content
            }

            var titleStart = line.startIndex
            while titleStart < line.endIndex, line[titleStart].isWhitespace {
                titleStart = line.index(after: titleStart)
            }
            while titleStart < line.endIndex, line[titleStart] == "#" {
                titleStart = line.index(after: titleStart)
            }
            while titleStart < line.endIndex, line[titleStart].isWhitespace {
                titleStart = line.index(after: titleStart)
            }

            var updatedContent = content
            updatedContent.replaceSubrange(titleStart..<lineEnd, with: title)
            return updatedContent
        }

        return content
    }

    private func updateCachedMetadata(for url: URL, content: String) {
        let standardizedURL = url.standardizedFileURL
        let metadataKey = Self.metadataCacheKey(for: standardizedURL)
        let date = (try? standardizedURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? cachedMarkdownMetadataByPath[metadataKey]?.modificationDate
            ?? Date()
        let noteTitle = Self.extractTitle(from: content)
            ?? standardizedURL.deletingPathExtension().lastPathComponent
        let noteLinks = MarkdownNoteLinkExtractor.references(in: content)

        cachedMarkdownMetadataByPath[metadataKey] = CachedMarkdownMetadata(
            modificationDate: date,
            noteTitle: noteTitle,
            noteLinks: noteLinks,
            noteBodyStorage: SearchableNoteBody(content)
        )

        let canonical = canonicalPath(for: standardizedURL)
        guard let index = fileIndexByCanonicalPath[canonical], files.indices.contains(index) else { return }

        let updatedFile = FileItem(
            id: standardizedURL,
            name: standardizedURL.lastPathComponent,
            url: standardizedURL,
            modificationDate: date,
            noteTitle: noteTitle,
            canonicalPath: canonical
        )
        files[index] = updatedFile

        // Name order cannot change on save; date order only moves this file.
        // Unless its position moved, the index needs just this one record.
        var needsFullReconcile = false
        if sortOrder == .byDate {
            resortFiles()
            needsFullReconcile = fileIndexByCanonicalPath[canonical] != index
        }

        if !needsFullReconcile, let existingEntry = noteSearchIndex.entry(forPath: metadataKey) {
            let candidate = makeSearchEntry(
                for: updatedFile,
                metadataKey: metadataKey,
                reusing: existingEntry,
                vaultBasePath: vaultURL?.standardizedFileURL.path
            )
            if noteSearchIndex.update(candidate) {
                searchIndexRevision &+= 1
            }
        } else {
            reconcileSearchIndex()
        }
        refreshNoteGraph()
    }

    private func applyDirectorySnapshot(_ snapshot: DirectorySnapshot) {
        cachedMarkdownMetadataByPath = snapshot.markdownMetadataByPath
        assetLookupByFilename = snapshot.assetLookupByFilename
        // Symlink layout may have changed; `files` re-seeds the memo.
        canonicalPathCache.removeAll(keepingCapacity: true)
        if snapshot.sortOrder == sortOrder {
            files = snapshot.files
            sidebarNodes = snapshot.nodes
        } else {
            // The sort order changed while a background walk was running; the
            // walk sorted by the order it started with.
            files = Self.sortFileItems(snapshot.files, sortOrder: sortOrder)
            sidebarNodes = Self.sortSidebarNodesRecursively(snapshot.nodes, sortOrder: sortOrder)
        }
        reconcileSearchIndex()
        pruneStoredEditorSelections(snapshotIsComplete: snapshot.isComplete)
    }

    private func refreshFilesInBackground(
        preferredSelectionURL: URL?,
        selectFirstFileIfNeeded: Bool
    ) {
        snapshotLoadTask?.cancel()
        snapshotGeneration += 1

        guard let vaultURL else {
            isLoadingSnapshot = false
            selectedFileURL = nil
            replaceEditorBuffer(with: "", persistedContent: nil)
            recoveredDraftURL = nil
            clearInventory()
            return
        }

        isLoadingSnapshot = true
        let generation = snapshotGeneration
        let sortOrder = sortOrder
        let cachedMarkdownMetadataByPath = cachedMarkdownMetadataByPath

        snapshotLoadTask = Task { [vaultURL] in
            let walk = Task.detached(priority: .userInitiated) {
                Self.snapshotDirectoryObservingCancellation(
                    at: vaultURL,
                    sortOrder: sortOrder,
                    cachedMarkdownMetadataByPath: cachedMarkdownMetadataByPath
                )
            }
            // A superseding refresh cancels this task. Forwarding that to the
            // walk stops it early, so bursts of external changes handled in
            // batches cannot pile up full-vault walks whose results would be
            // discarded anyway.
            let snapshot = await withTaskCancellationHandler {
                await walk.value
            } onCancel: {
                walk.cancel()
            }

            guard !Task.isCancelled else { return }
            guard generation == self.snapshotGeneration else { return }
            guard self.vaultURL?.standardizedFileURL == vaultURL.standardizedFileURL else { return }

            self.applyDirectorySnapshot(snapshot)

            if let preferredSelectionURL,
               let matchingURL = self.matchingSidebarURL(for: preferredSelectionURL) {
                self.selectFile(matchingURL)
                // Selecting an already-open note schedules no graph rebuild,
                // and vault opens no longer walk the directory synchronously,
                // so the graph is refreshed here for the full inventory.
                self.refreshNoteGraph()
                self.isLoadingSnapshot = false
                return
            }

            if let selectedFileURL {
                if let matchingURL = self.matchingSidebarURL(for: selectedFileURL) {
                    self.selectedFileURL = matchingURL
                } else {
                    self.preserveDirtyBufferOrClearMissingSelection(selectedFileURL)
                }
            } else if selectFirstFileIfNeeded, let first = self.sortedFiles.first {
                self.selectFile(first.url)
            }

            self.refreshNoteGraph()
            self.isLoadingSnapshot = false
        }
    }

    /// The background refresh's walk: it stops early once its task is
    /// cancelled. The partial snapshot it then returns is never applied,
    /// because only a superseded refresh cancels the walk.
    private nonisolated static func snapshotDirectoryObservingCancellation(
        at directoryURL: URL,
        sortOrder: SortOrder,
        cachedMarkdownMetadataByPath: [String: CachedMarkdownMetadata]
    ) -> DirectorySnapshot {
        withUnsafeCurrentTask { task in
            snapshotDirectory(
                at: directoryURL,
                sortOrder: sortOrder,
                cachedMarkdownMetadataByPath: cachedMarkdownMetadataByPath,
                cancellation: TaskCancellationProbe(task: task)
            )
        }
    }

    /// Three phases: walk the tree reading only prefetched metadata, read
    /// every uncached note body concurrently, then assemble and sort nodes
    /// and files exactly as a single recursive pass would. Without a
    /// `cancellation` probe (the synchronous refresh) the walk always runs
    /// to completion.
    private nonisolated static func snapshotDirectory(
        at directoryURL: URL,
        sortOrder: SortOrder,
        cachedMarkdownMetadataByPath: [String: CachedMarkdownMetadata],
        cancellation: TaskCancellationProbe? = nil
    ) -> DirectorySnapshot {
        let tree = collectDirectoryTree(
            at: directoryURL,
            canonicalDirectoryPath: FileItem.canonicalPath(for: directoryURL),
            cancellation: cancellation
        )
        let loadedNotes = loadUncachedNotes(
            in: tree,
            cachedMarkdownMetadataByPath: cachedMarkdownMetadataByPath,
            cancellation: cancellation
        )
        return assembleSnapshot(
            from: tree,
            sortOrder: sortOrder,
            cachedMarkdownMetadataByPath: cachedMarkdownMetadataByPath,
            loadedNotes: loadedNotes
        )
    }

    private nonisolated static func collectDirectoryTree(
        at directoryURL: URL,
        canonicalDirectoryPath: String,
        cancellation: TaskCancellationProbe?
    ) -> DirectoryTree {
        guard cancellation?.isCancelled != true,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directoryURL,
                  includingPropertiesForKeys: Array(directorySnapshotResourceKeys),
                  options: .skipsHiddenFiles
              ) else {
            return DirectoryTree(entries: [], isComplete: false)
        }

        var entries: [DirectoryTreeEntry] = []
        var isComplete = true
        entries.reserveCapacity(contents.count)

        for url in contents {
            // Read the prefetched values from the enumerated URL itself; a
            // standardized copy loses that cache and pays a stat per key.
            let values = try? url.resourceValues(forKeys: directorySnapshotResourceKeys)
            let standardizedURL = url.standardizedFileURL
            let name = standardizedURL.lastPathComponent
            let modificationDate = values?.contentModificationDate ?? .distantPast

            // A non-symlink entry's canonical path is its parent's canonical
            // path plus its name, which spares a symlink resolution per file.
            let canonicalPath: String
            if values?.isSymbolicLink == false {
                canonicalPath = canonicalDirectoryPath.hasSuffix("/")
                    ? canonicalDirectoryPath + name
                    : canonicalDirectoryPath + "/" + name
            } else {
                canonicalPath = FileItem.canonicalPath(for: standardizedURL)
            }

            let kind: DirectoryTreeEntry.Kind
            if values?.isDirectory == true {
                let subtree = collectDirectoryTree(
                    at: standardizedURL,
                    canonicalDirectoryPath: canonicalPath,
                    cancellation: cancellation
                )
                isComplete = isComplete && subtree.isComplete
                kind = .directory(subtree)
            } else if Self.isMarkdownFile(standardizedURL) {
                kind = .markdown
            } else if Self.isImageFile(standardizedURL) {
                kind = .image
            } else if values?.isRegularFile == true {
                kind = .asset
            } else {
                continue
            }

            entries.append(
                DirectoryTreeEntry(
                    url: standardizedURL,
                    name: name,
                    canonicalPath: canonicalPath,
                    modificationDate: modificationDate,
                    isUbiquitous: values?.isUbiquitousItem == true,
                    kind: kind
                )
            )
        }

        return DirectoryTree(entries: entries, isComplete: isComplete)
    }

    /// Reads (and folds) every markdown body the metadata cache cannot serve,
    /// spreading the work over all cores. This runs inside a detached task
    /// or a deliberate synchronous refresh, so blocking the caller is fine.
    private nonisolated static func loadUncachedNotes(
        in tree: DirectoryTree,
        cachedMarkdownMetadataByPath: [String: CachedMarkdownMetadata],
        cancellation: TaskCancellationProbe?
    ) -> [String: LoadedNote] {
        var uncachedEntries: [DirectoryTreeEntry] = []
        collectUncachedNotes(in: tree, cachedMarkdownMetadataByPath: cachedMarkdownMetadataByPath, into: &uncachedEntries)
        guard !uncachedEntries.isEmpty, cancellation?.isCancelled != true else { return [:] }

        let pending = uncachedEntries
        let buffer = ConcurrentResultBuffer<LoadedNote>(count: pending.count)
        if pending.count == 1 {
            buffer.set(loadNote(pending[0]), at: 0)
        } else {
            DispatchQueue.concurrentPerform(iterations: pending.count) { index in
                // A cancelled walk is discarded, so its remaining reads are skipped.
                guard cancellation?.isCancelled != true else { return }
                buffer.set(loadNote(pending[index]), at: index)
            }
        }

        var loadedNotes: [String: LoadedNote] = [:]
        loadedNotes.reserveCapacity(pending.count)
        for (entry, note) in zip(pending, buffer.elements) {
            guard let note else { continue }
            loadedNotes[metadataCacheKey(for: entry.url)] = note
        }
        return loadedNotes
    }

    private nonisolated static func collectUncachedNotes(
        in tree: DirectoryTree,
        cachedMarkdownMetadataByPath: [String: CachedMarkdownMetadata],
        into pending: inout [DirectoryTreeEntry]
    ) {
        for entry in tree.entries {
            switch entry.kind {
            case .directory(let subtree):
                collectUncachedNotes(in: subtree, cachedMarkdownMetadataByPath: cachedMarkdownMetadataByPath, into: &pending)
            case .markdown:
                if !canReuseCachedMetadata(cachedMarkdownMetadataByPath[metadataCacheKey(for: entry.url)], for: entry) {
                    pending.append(entry)
                }
            case .image, .asset:
                continue
            }
        }
    }

    private nonisolated static func canReuseCachedMetadata(
        _ cachedMetadata: CachedMarkdownMetadata?,
        for entry: DirectoryTreeEntry
    ) -> Bool {
        cachedMetadata?.modificationDate == entry.modificationDate
    }

    private nonisolated static func loadNote(_ entry: DirectoryTreeEntry) -> LoadedNote {
        guard let content = readSnapshotFileContents(entry.url, isUbiquitous: entry.isUbiquitous) else {
            return .unreadable
        }
        // Filename fallback is presentation metadata only. Opening/indexing
        // a note must never inject an H1 or otherwise rewrite its bytes.
        return .loaded(
            noteTitle: Self.extractTitle(from: content)
                ?? entry.url.deletingPathExtension().lastPathComponent,
            noteLinks: MarkdownNoteLinkExtractor.references(in: content),
            noteBodyStorage: SearchableNoteBody(content)
        )
    }

    private nonisolated static func assembleSnapshot(
        from tree: DirectoryTree,
        sortOrder: SortOrder,
        cachedMarkdownMetadataByPath: [String: CachedMarkdownMetadata],
        loadedNotes: [String: LoadedNote]
    ) -> DirectorySnapshot {
        var nodes: [SidebarNode] = []
        var files: [FileItem] = []
        var markdownMetadataByPath: [String: CachedMarkdownMetadata] = [:]
        var assetLookupByFilename: [String: [URL]] = [:]

        for entry in tree.entries {
            switch entry.kind {
            case .directory(let subtree):
                let childSnapshot = assembleSnapshot(
                    from: subtree,
                    sortOrder: sortOrder,
                    cachedMarkdownMetadataByPath: cachedMarkdownMetadataByPath,
                    loadedNotes: loadedNotes
                )
                let childLatestDate = childSnapshot.nodes.map(\.modificationDate).max() ?? entry.modificationDate
                nodes.append(
                    SidebarNode(
                        id: entry.url,
                        url: entry.url,
                        name: entry.name,
                        kind: .folder,
                        modificationDate: max(entry.modificationDate, childLatestDate),
                        children: childSnapshot.nodes
                    )
                )
                files.append(contentsOf: childSnapshot.files)
                markdownMetadataByPath.merge(childSnapshot.markdownMetadataByPath) { _, newest in newest }
                mergeAssetLookup(&assetLookupByFilename, with: childSnapshot.assetLookupByFilename)
            case .markdown:
                let metadataKey = metadataCacheKey(for: entry.url)
                let file = makeFileItem(
                    for: entry,
                    cachedMetadata: cachedMarkdownMetadataByPath[metadataKey],
                    loadedNote: loadedNotes[metadataKey]
                )
                nodes.append(
                    SidebarNode(
                        id: entry.url,
                        url: entry.url,
                        name: file.file.displayName,
                        kind: .file,
                        modificationDate: file.file.modificationDate
                    )
                )
                files.append(file.file)
                markdownMetadataByPath[metadataKey] = CachedMarkdownMetadata(
                    modificationDate: file.file.modificationDate,
                    noteTitle: file.file.noteTitle,
                    noteLinks: file.noteLinks,
                    noteBodyStorage: file.noteBodyStorage
                )
                addAssetLookupEntry(for: entry.url, to: &assetLookupByFilename)
            case .image:
                nodes.append(
                    SidebarNode(
                        id: entry.url,
                        url: entry.url,
                        name: entry.name,
                        kind: .file,
                        modificationDate: entry.modificationDate
                    )
                )
                addAssetLookupEntry(for: entry.url, to: &assetLookupByFilename)
            case .asset:
                addAssetLookupEntry(for: entry.url, to: &assetLookupByFilename)
            }
        }

        return DirectorySnapshot(
            nodes: sortSidebarNodes(nodes, sortOrder: sortOrder),
            files: sortFileItems(files, sortOrder: sortOrder),
            markdownMetadataByPath: markdownMetadataByPath,
            assetLookupByFilename: sortAssetLookup(assetLookupByFilename),
            sortOrder: sortOrder,
            isComplete: tree.isComplete
        )
    }

    private nonisolated static func makeFileItem(
        for entry: DirectoryTreeEntry,
        cachedMetadata: CachedMarkdownMetadata?,
        loadedNote: LoadedNote?
    ) -> (file: FileItem, noteLinks: [NoteLinkReference], noteBodyStorage: SearchableNoteBody) {
        let noteTitle: String?
        let noteLinks: [NoteLinkReference]
        let noteBodyStorage: SearchableNoteBody
        if let cachedMetadata, canReuseCachedMetadata(cachedMetadata, for: entry) {
            noteTitle = cachedMetadata.noteTitle
            noteLinks = cachedMetadata.noteLinks
            noteBodyStorage = cachedMetadata.noteBodyStorage
        } else if case .loaded(let loadedTitle, let loadedLinks, let loadedStorage)? = loadedNote {
            noteTitle = loadedTitle
            noteLinks = loadedLinks
            noteBodyStorage = loadedStorage
        } else {
            noteTitle = nil
            noteLinks = []
            noteBodyStorage = SearchableNoteBody("")
        }

        let file = FileItem(
            id: entry.url,
            name: entry.name,
            url: entry.url,
            modificationDate: entry.modificationDate,
            noteTitle: noteTitle,
            canonicalPath: entry.canonicalPath
        )

        return (file, noteLinks, noteBodyStorage)
    }

    private nonisolated static func sortFileItems(_ files: [FileItem], sortOrder: SortOrder) -> [FileItem] {
        files.sorted { lhs, rhs in
            switch sortOrder {
            case .byName:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .byDate:
                if lhs.modificationDate != rhs.modificationDate {
                    return lhs.modificationDate > rhs.modificationDate
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private nonisolated static func metadataCacheKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private nonisolated static func addAssetLookupEntry(for url: URL, to lookup: inout [String: [URL]]) {
        lookup[url.lastPathComponent, default: []].append(url.standardizedFileURL)
    }

    private nonisolated static func mergeAssetLookup(_ target: inout [String: [URL]], with source: [String: [URL]]) {
        for (fileName, urls) in source {
            target[fileName, default: []].append(contentsOf: urls)
        }
    }

    private nonisolated static func sortAssetLookup(_ lookup: [String: [URL]]) -> [String: [URL]] {
        lookup.mapValues { urls in
            Array(Set(urls)).sorted { lhs, rhs in
                lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
        }
    }

    private func resortFiles() {
        files = Self.sortFileItems(files, sortOrder: sortOrder)
    }

    /// Sorts every level of an already loaded tree, for sort changes that
    /// must not re-read the directory.
    private nonisolated static func sortSidebarNodesRecursively(
        _ nodes: [SidebarNode],
        sortOrder: SortOrder
    ) -> [SidebarNode] {
        let sortedChildren = nodes.map { node -> SidebarNode in
            guard node.isFolder, !node.children.isEmpty else { return node }
            var sorted = node
            sorted.children = sortSidebarNodesRecursively(node.children, sortOrder: sortOrder)
            return sorted
        }
        return sortSidebarNodes(sortedChildren, sortOrder: sortOrder)
    }

    private nonisolated static func sortSidebarNodes(_ nodes: [SidebarNode], sortOrder: SortOrder) -> [SidebarNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder {
                return lhs.isFolder && !rhs.isFolder
            }

            switch sortOrder {
            case .byName:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .byDate:
                if lhs.modificationDate != rhs.modificationDate {
                    return lhs.modificationDate > rhs.modificationDate
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private nonisolated static func readFileContents(_ url: URL) -> String? {
        try? readFileContentsThrowing(url)
    }

    /// Snapshot reads of local notes skip `NSFileCoordinator`, which costs far
    /// more than the read itself. Ubiquitous (iCloud) items keep coordinated
    /// reads so a partially downloaded version is never indexed. The editor
    /// open path always stays coordinated (`readFileContentsThrowing`).
    private nonisolated static func readSnapshotFileContents(_ url: URL, isUbiquitous: Bool) -> String? {
        guard !isUbiquitous else { return readFileContents(url) }
        return try? readUncoordinatedFileContentsThrowing(url)
    }

    private nonisolated static func readUncoordinatedFileContentsThrowing(_ url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            data = try Data(contentsOf: url)
        }
        return try decodeTextData(data)
    }

    /// Coordinated reads are important for iCloud/ubiquitous documents: a read
    /// either returns a complete version or throws. A thrown read never becomes
    /// an empty editor buffer that autosave could later write over the note.
    private nonisolated static func readFileContentsThrowing(_ url: URL) throws -> String {
        let data: Data
        do {
            data = try coordinatedRead(from: url)
        } catch {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            data = try coordinatedRead(from: url)
        }
        return try decodeTextData(data)
    }

    private nonisolated static func coordinatedRead(from url: URL) throws -> Data {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private nonisolated static func coordinatedWrite(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var accessorError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                accessorError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let accessorError { throw accessorError }
    }

    private enum CoordinatedConditionalWriteOutcome {
        case written
        case conflict(String)
    }

    /// Reads the current version and replaces it inside one file-coordination
    /// accessor. iCloud and other coordinated writers therefore cannot land a
    /// new version between our conflict check and write.
    private nonisolated static func coordinatedConditionalWrite(
        _ data: Data,
        expectedContent: String,
        to url: URL
    ) throws -> CoordinatedConditionalWriteOutcome {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var accessorResult: Result<CoordinatedConditionalWriteOutcome, Error>?

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            accessorResult = Result {
                let diskData = try Data(contentsOf: coordinatedURL)
                let diskContent = try decodeTextData(diskData)
                let proposedContent = String(decoding: data, as: UTF8.self)
                if diskContent != expectedContent, diskContent != proposedContent {
                    return .conflict(diskContent)
                }
                try data.write(to: coordinatedURL, options: .atomic)
                return .written
            }
        }

        if let coordinationError { throw coordinationError }
        guard let accessorResult else { throw CocoaError(.fileWriteUnknown) }
        return try accessorResult.get()
    }

    /// UTF-8 first; UTF-16 only when a byte-order mark proves the encoding,
    /// because blindly decoding even-length data as UTF-16 silently produces
    /// garbage. ISO Latin-1 is the lossless final fallback for every byte.
    private nonisolated static func decodeTextData(_ data: Data) throws -> String {
        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        let bytes = [UInt8](data.prefix(2))
        if bytes == [0xFF, 0xFE] || bytes == [0xFE, 0xFF],
           let string = String(data: data, encoding: .utf16) {
            return string
        }
        if let string = String(data: data, encoding: .isoLatin1) {
            return string
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    nonisolated static func isMarkdownFile(_ url: URL) -> Bool {
        markdownFileExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static func isImageFile(_ url: URL) -> Bool {
        imageFileExtensions.contains(url.pathExtension.lowercased())
    }

    private func matchingSidebarURL(for url: URL) -> URL? {
        matchingSidebarURL(forCanonicalPath: canonicalPath(for: url), in: sidebarNodes)
    }

    private func sidebarNode(for url: URL) -> SidebarNode? {
        sidebarNode(forCanonicalPath: canonicalPath(for: url), in: sidebarNodes)
    }

    private func ensureOpenedFileIsVisible(at url: URL, markdownContent: String?) {
        let standardizedURL = url.standardizedFileURL
        let canonical = canonicalPath(for: standardizedURL)
        let modificationDate = (try? standardizedURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()

        if Self.isMarkdownFile(standardizedURL) {
            let noteTitle = markdownContent.flatMap(Self.extractTitle(from:))
            let noteLinks = markdownContent.map(MarkdownNoteLinkExtractor.references(in:)) ?? []
            cachedMarkdownMetadataByPath[Self.metadataCacheKey(for: standardizedURL)] = CachedMarkdownMetadata(
                modificationDate: modificationDate,
                noteTitle: noteTitle,
                noteLinks: noteLinks,
                noteBodyStorage: SearchableNoteBody(markdownContent ?? "")
            )

            let fileItem = FileItem(
                id: standardizedURL,
                name: standardizedURL.lastPathComponent,
                url: standardizedURL,
                modificationDate: modificationDate,
                noteTitle: noteTitle,
                canonicalPath: canonical
            )

            if let index = fileIndexByCanonicalPath[canonical], files.indices.contains(index) {
                files[index] = fileItem
            } else {
                files.append(fileItem)
            }
            resortFiles()
            reconcileSearchIndex()
        }
        updateAssetLookup(for: standardizedURL)

        guard !sidebarContainsNode(forCanonicalPath: canonical, in: sidebarNodes) else { return }

        sidebarNodes = Self.sortSidebarNodes(
            sidebarNodes + [
                SidebarNode(
                    id: standardizedURL,
                    url: standardizedURL,
                    name: Self.isMarkdownFile(standardizedURL) ? standardizedURL.deletingPathExtension().lastPathComponent : standardizedURL.lastPathComponent,
                    kind: .file,
                    modificationDate: modificationDate
                )
            ],
            sortOrder: sortOrder
        )
    }

    private func updateAssetLookup(for url: URL) {
        let fileName = url.lastPathComponent
        let standardizedURL = url.standardizedFileURL
        if assetLookupByFilename[fileName]?.contains(standardizedURL) != true {
            assetLookupByFilename[fileName, default: []].append(standardizedURL)
        }
        assetLookupByFilename[fileName]?.sort {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    // The sidebar recursions canonicalize the query once and compare each
    // node through the memo, which `files` keeps warm for every note URL.

    private func sidebarContainsNode(forCanonicalPath path: String, in nodes: [SidebarNode]) -> Bool {
        nodes.contains { node in
            canonicalPath(for: node.url) == path || sidebarContainsNode(forCanonicalPath: path, in: node.children)
        }
    }

    private func matchingSidebarURL(forCanonicalPath path: String, in nodes: [SidebarNode]) -> URL? {
        for node in nodes {
            if canonicalPath(for: node.url) == path {
                return node.url
            }

            if let childMatch = matchingSidebarURL(forCanonicalPath: path, in: node.children) {
                return childMatch
            }
        }

        return nil
    }

    private func sidebarNode(forCanonicalPath path: String, in nodes: [SidebarNode]) -> SidebarNode? {
        for node in nodes {
            if canonicalPath(for: node.url) == path {
                return node
            }

            if let childMatch = sidebarNode(forCanonicalPath: path, in: node.children) {
                return childMatch
            }
        }

        return nil
    }

    private func destinationDirectoryURL(for requestedDirectoryURL: URL?) -> URL? {
        guard let vaultURL else {
            return nil
        }

        let standardizedVaultURL = vaultURL.resolvingSymlinksInPath().standardizedFileURL

        guard let requestedDirectoryURL else {
            return standardizedVaultURL
        }

        let standardizedRequestedDirectoryURL = requestedDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(standardizedRequestedDirectoryURL, of: standardizedVaultURL, allowEqual: true) else {
            return nil
        }

        guard isDirectoryURL(standardizedRequestedDirectoryURL) else {
            return nil
        }

        return standardizedRequestedDirectoryURL
    }

    private func uniqueMarkdownFileURL(in directoryURL: URL) -> URL {
        let fm = FileManager.default
        var name = "Untitled"
        var counter = 1
        var fileURL = directoryURL.appendingPathComponent(name).appendingPathExtension("md")

        while fm.fileExists(atPath: fileURL.path) {
            name = "Untitled \(counter)"
            counter += 1
            fileURL = directoryURL.appendingPathComponent(name).appendingPathExtension("md")
        }

        return fileURL
    }

    private func uniqueFolderURL(in directoryURL: URL) -> URL {
        let fm = FileManager.default
        var name = "New Folder"
        var counter = 1
        var folderURL = directoryURL.appendingPathComponent(name, isDirectory: true)

        while fm.fileExists(atPath: folderURL.path) {
            counter += 1
            name = "New Folder \(counter)"
            folderURL = directoryURL.appendingPathComponent(name, isDirectory: true)
        }

        return folderURL
    }

    private func presentStandaloneFileSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Untitled.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        try? Data("# \(name)\n\n".utf8).write(to: url, options: .atomic)
        importDroppedFile(url)
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func isDescendant(_ url: URL, of parentURL: URL, allowEqual: Bool) -> Bool {
        let standardizedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let standardizedParentURL = parentURL.resolvingSymlinksInPath().standardizedFileURL

        if standardizedURL == standardizedParentURL {
            return allowEqual
        }

        let parentPath = standardizedParentURL.path.hasSuffix("/")
            ? standardizedParentURL.path
            : standardizedParentURL.path + "/"
        return standardizedURL.path.hasPrefix(parentPath)
    }

    private func persistVaultBookmark(for url: URL) {
        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            userDefaults.set(bookmark, forKey: Self.bookmarkKey)
        }
    }

    private func persistSelectedFileURL(_ url: URL) {
        guard let storageKey = selectedFileStorageKey else { return }
        userDefaults.set(url.standardizedFileURL.path, forKey: storageKey)
    }

    private func restoreSelectedFileURL() -> URL? {
        guard let storageKey = selectedFileStorageKey,
              let path = userDefaults.string(forKey: storageKey) else {
            return nil
        }

        return URL(fileURLWithPath: path)
    }

    private func clearStoredSelectedFileURL() {
        guard let storageKey = selectedFileStorageKey else { return }
        userDefaults.removeObject(forKey: storageKey)
    }

    private func deletedItem(_ deletedURL: URL, isDirectory: Bool, contains candidateURL: URL) -> Bool {
        let candidatePath = canonicalPath(for: candidateURL)
        let deletedPath = canonicalPath(for: deletedURL)

        if candidatePath == deletedPath {
            return true
        }

        guard isDirectory else {
            return false
        }

        let deletedPrefix = deletedPath.hasSuffix("/") ? deletedPath : deletedPath + "/"
        return candidatePath.hasPrefix(deletedPrefix)
    }

    private func persistSortOrder() {
        guard let storageKey = sortOrderStorageKey else { return }
        userDefaults.set(sortOrder.rawValue, forKey: storageKey)
    }

    /// Restores the vault's persisted order without the user-initiated side
    /// effects: the value is already persisted, and the caller is about to
    /// load a fresh snapshot in that order.
    private func restoreSortOrder() {
        isRestoringSortOrder = true
        defer { isRestoringSortOrder = false }

        guard let storageKey = sortOrderStorageKey,
              let rawValue = userDefaults.string(forKey: storageKey),
              let restored = SortOrder(rawValue: rawValue) else {
            sortOrder = preferences.defaultSortOrder
            return
        }

        sortOrder = restored
    }

    private var selectedFileStorageKey: String? {
        guard let vaultURL else { return nil }
        return "selectedFile::" + vaultURL.standardizedFileURL.path
    }

    private var sortOrderStorageKey: String? {
        guard let vaultURL else { return nil }
        return "sortOrder::" + vaultURL.standardizedFileURL.path
    }

    private func beginAccessingVault(_ url: URL) {
        let standardizedURL = url.standardizedFileURL

        if vaultFilePresenter?.presentedItemURL?.standardizedFileURL != standardizedURL {
            vaultFilePresenter?.stop()
            let presenter = VaultFilePresenter(vaultURL: standardizedURL) { [weak self] changes in
                Task { @MainActor [weak self] in
                    self?.scheduleExternalChangeHandling(changes)
                }
            }
            vaultFilePresenter = presenter
            presenter.start()
        }

        if activeSecurityScopedVaultURL?.standardizedFileURL == standardizedURL {
            return
        }

        if let activeSecurityScopedVaultURL {
            activeSecurityScopedVaultURL.stopAccessingSecurityScopedResource()
        }

        if standardizedURL.startAccessingSecurityScopedResource() {
            activeSecurityScopedVaultURL = standardizedURL
        } else {
            activeSecurityScopedVaultURL = nil
        }
    }

    /// Queues file-presenter changes for one debounced handling pass. `.changed`
    /// events coalesce per path and moves keep their order. Once more than
    /// `VaultFileChangeBatch.leadingFlushThreshold` changes are pending they
    /// are handled at once, so a long iCloud or git burst is processed in
    /// bounded batches instead of as one giant batch after the burst ends.
    func scheduleExternalChangeHandling(_ changes: [VaultFileChange]) {
        guard !changes.isEmpty else { return }
        pendingExternalChanges.append(contentsOf: changes)
        guard pendingExternalChanges.count <= VaultFileChangeBatch.leadingFlushThreshold else {
            handlePendingExternalChanges()
            return
        }

        externalChangeTask?.cancel()
        externalChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            self.handlePendingExternalChanges()
        }
    }

    private func handlePendingExternalChanges() {
        externalChangeTask?.cancel()
        externalChangeTask = nil
        let changes = pendingExternalChanges.takeAll()
        guard !changes.isEmpty else { return }
        handleExternalChanges(changes)
    }

    /// Applies the entire debounced change batch. Keeping move pairs intact and
    /// checking the selected file for every batch prevents a later, unrelated
    /// iCloud notification from hiding an earlier note update.
    func handleExternalChanges(_ changes: [VaultFileChange]) {
        invalidateCachedMetadata(for: changes)
        remapSelectionForExternalMoves(in: changes)
        remapStoredEditorSelections(forExternalMovesIn: changes)

        if let selectedFileURL,
           selectedFileIsMarkdown,
           let diskContent = try? Self.readFileContentsThrowing(selectedFileURL),
           diskContent != text {
            if hasUnsavedChanges {
                // A file-presenter callback for another item must not turn a
                // normal dirty buffer into a conflict merely because disk is
                // still at our known base version.
                if diskContent != persistedText {
                    _ = persistRecoveryDraftNow()
                    saveConflict = SaveConflict(
                        url: selectedFileURL,
                        fileName: selectedFileURL.lastPathComponent,
                        onDiskContent: diskContent,
                        editorContent: text
                    )
                }
            } else {
                replaceEditorBuffer(with: diskContent, persistedContent: diskContent)
                recoveryStore.removeDraft(for: selectedFileURL)
                updateCachedMetadata(for: selectedFileURL, content: diskContent)
            }
        }

        // File-presenter callbacks arrive on save and in iCloud bursts. Build
        // the recursive inventory off the main actor so those bursts cannot
        // freeze editing in a large vault.
        refreshFilesInBackground(
            preferredSelectionURL: nil,
            selectFirstFileIfNeeded: false
        )
    }

    /// File-presenter events are stronger evidence than timestamps. iCloud can
    /// preserve coarse modification metadata while replacing content, so evict
    /// only affected records (or all records for a vault-root event) before the
    /// background snapshot reconciles the maintained index.
    private func invalidateCachedMetadata(for changes: [VaultFileChange]) {
        guard let vaultURL else { return }
        let vaultPath = vaultURL.standardizedFileURL.path
        var affectedPaths: Set<Substring> = []

        for change in changes {
            for url in change.affectedURLs {
                let path = url.standardizedFileURL.path
                if path == vaultPath {
                    cachedMarkdownMetadataByPath.removeAll(keepingCapacity: true)
                    return
                }
                affectedPaths.insert(Substring(path))
            }
        }

        guard !affectedPaths.isEmpty else { return }
        // Looking each cached path and its ancestors up in a set keeps a
        // large batch linear in the cache size rather than cache x batch.
        cachedMarkdownMetadataByPath = cachedMarkdownMetadataByPath.filter { key, _ in
            !Self.isPath(key, equalToOrInsideAnyOf: affectedPaths)
        }
    }

    /// Whether `path`, or a directory containing it, is one of `roots`.
    private nonisolated static func isPath(_ path: String, equalToOrInsideAnyOf roots: Set<Substring>) -> Bool {
        var candidate = Substring(path)
        while true {
            if roots.contains(candidate) {
                return true
            }
            guard let separator = candidate.lastIndex(of: "/"),
                  separator > candidate.startIndex else {
                return false
            }
            candidate = candidate[..<separator]
        }
    }

    private func remapSelectionForExternalMoves(in changes: [VaultFileChange]) {
        guard let selectedFileURL else { return }
        let selectedPath = selectedFileURL.standardizedFileURL.path

        for change in changes {
            guard case .moved(let oldURL, let newURL) = change else { continue }
            let oldPath = oldURL.standardizedFileURL.path
            let suffix: String
            if selectedPath == oldPath {
                suffix = ""
            } else if selectedPath.hasPrefix(oldPath + "/") {
                suffix = String(selectedPath.dropFirst(oldPath.count))
            } else {
                continue
            }

            let remappedURL = URL(fileURLWithPath: newURL.standardizedFileURL.path + suffix)
                .standardizedFileURL
            guard let vaultURL,
                  isDescendant(remappedURL, of: vaultURL, allowEqual: false) else {
                continue
            }

            self.selectedFileURL = remappedURL
            persistSelectedFileURL(remappedURL)
            recoveryStore.moveDraft(from: selectedFileURL, to: remappedURL)
            // The move superseded any draft write still pending for the old
            // path, so a dirty buffer is drafted again under its new path.
            if hasUnsavedChanges {
                scheduleRecoveryDraft()
            }
            return
        }
    }

    /// Re-keys stored editor selections for every external move, in order,
    /// so chained moves within one batch land on the final path.
    private func remapStoredEditorSelections(forExternalMovesIn changes: [VaultFileChange]) {
        loadEditorSelectionsIfNeeded()
        guard !editorSelectionsByPath.isEmpty else { return }
        for change in changes {
            guard case .moved(let oldURL, let newURL) = change else { continue }
            moveStoredEditorSelections(fromRootPaths: editorSelectionRootPaths(for: oldURL), to: newURL)
        }
    }

}

private struct DirectorySnapshot: Sendable {
    let nodes: [SidebarNode]
    let files: [FileItem]
    let markdownMetadataByPath: [String: CachedMarkdownMetadata]
    let assetLookupByFilename: [String: [URL]]
    /// The order `nodes` and `files` are sorted in.
    let sortOrder: SortOrder
    /// `false` when some directory could not be listed, so the inventory may
    /// be missing notes that still exist.
    let isComplete: Bool
}

/// Prefetched for every enumerated URL so the snapshot walk never stats
/// twice. `isUbiquitousItem` decides between coordinated and plain reads;
/// `isSymbolicLink` decides whether a canonical path needs resolving.
private let directorySnapshotResourceKeys: Set<URLResourceKey> = [
    .isDirectoryKey,
    .isRegularFileKey,
    .isSymbolicLinkKey,
    .isUbiquitousItemKey,
    .contentModificationDateKey
]

/// The metadata-only result of walking one directory; entries keep the
/// enumeration order so assembly sorts exactly as the single pass did.
private struct DirectoryTree: Sendable {
    let entries: [DirectoryTreeEntry]
    /// `false` when this directory, or any below it, could not be listed.
    var isComplete = true
}

private struct DirectoryTreeEntry: Sendable {
    enum Kind: Sendable {
        case directory(DirectoryTree)
        case markdown
        case image
        case asset
    }

    let url: URL
    let name: String
    let canonicalPath: String
    let modificationDate: Date
    let isUbiquitous: Bool
    let kind: Kind
}

private enum LoadedNote: Sendable {
    case loaded(noteTitle: String?, noteLinks: [NoteLinkReference], noteBodyStorage: SearchableNoteBody)
    case unreadable
}

private struct SearchTitleMatch: Sendable {
    let rank: Int
    let sourceIndex: Int
    let result: NoteSearchResult
}

private struct SearchChunkMatches: Sendable {
    var titleMatches: [SearchTitleMatch] = []
    var bodyMatches: [NoteSearchResult] = []
}

/// Index-addressed results for `DispatchQueue.concurrentPerform` workers.
/// Each slot is written by exactly one iteration; the lock only orders the
/// writes against the final read.
private final class ConcurrentResultBuffer<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element?]

    init(count: Int) {
        storage = Array(repeating: nil, count: count)
    }

    func set(_ element: Element, at index: Int) {
        lock.lock()
        storage[index] = element
        lock.unlock()
    }

    var elements: [Element?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Lets `concurrentPerform` workers, which run outside the calling task,
/// observe that task's cancellation. `UnsafeCurrentTask.isCancelled` is an
/// atomic status read, and the probe is only used within the dynamic extent
/// of the `withUnsafeCurrentTask` call that created it.
private final class TaskCancellationProbe: @unchecked Sendable {
    private let task: UnsafeCurrentTask?

    init(task: UnsafeCurrentTask?) {
        self.task = task
    }

    var isCancelled: Bool {
        task?.isCancelled ?? false
    }
}

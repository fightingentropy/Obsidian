import Foundation

struct DailyNoteConfiguration: Codable, Equatable, Sendable {
    var folderPath: String
    var dateFormat: String
    var templateRelativePath: String?

    static let `default` = DailyNoteConfiguration(
        folderPath: "Daily Notes",
        dateFormat: "YYYY-MM-DD",
        templateRelativePath: nil
    )
}

struct TemplateLibraryConfiguration: Codable, Equatable, Sendable {
    var folderPath: String

    static let `default` = TemplateLibraryConfiguration(folderPath: "Templates")
}

private struct NoteWorkflowConfigurationSnapshot: Codable {
    var dailyNotes: DailyNoteConfiguration
    var templates: TemplateLibraryConfiguration
}

/// User-configurable locations for Daily Notes and Templates. The serialized
/// snapshot is deliberately independent of any view state so these foundations
/// can be wired into Settings without changing their persistence contract.
@Observable
@MainActor
final class NoteWorkflowConfigurationStore {
    var dailyNotes: DailyNoteConfiguration {
        didSet { persist() }
    }

    var templates: TemplateLibraryConfiguration {
        didSet { persist() }
    }

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "noteWorkflows.configuration"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey

        if let data = userDefaults.data(forKey: storageKey),
           let snapshot = try? JSONDecoder().decode(NoteWorkflowConfigurationSnapshot.self, from: data) {
            dailyNotes = snapshot.dailyNotes
            templates = snapshot.templates
        } else {
            dailyNotes = .default
            templates = .default
        }
    }

    func reset() {
        dailyNotes = .default
        templates = .default
        persist()
    }

    private func persist() {
        let snapshot = NoteWorkflowConfigurationSnapshot(
            dailyNotes: dailyNotes,
            templates: templates
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}

struct RecentVaultRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let url: URL
    var displayName: String
    var lastOpenedAt: Date

    init(url: URL, displayName: String? = nil, lastOpenedAt: Date = Date()) {
        let standardized = url.standardizedFileURL
        self.id = standardized.path
        self.url = standardized
        let suppliedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = suppliedName.flatMap { $0.isEmpty ? nil : $0 }
            ?? standardized.lastPathComponent
        self.lastOpenedAt = lastOpenedAt
    }
}

@Observable
@MainActor
final class RecentVaultStore {
    private(set) var records: [RecentVaultRecord]

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let maximumCount: Int

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "recentVaults.records",
        maximumCount: Int = 12
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.maximumCount = max(1, maximumCount)

        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([RecentVaultRecord].self, from: data) {
            records = Self.normalized(decoded, maximumCount: self.maximumCount)
        } else {
            records = []
        }
    }

    func recordOpened(_ url: URL, displayName: String? = nil, at date: Date = Date()) {
        guard url.isFileURL else { return }
        let record = RecentVaultRecord(url: url, displayName: displayName, lastOpenedAt: date)
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        records = Self.normalized(records, maximumCount: maximumCount)
        persist()
    }

    func remove(_ record: RecentVaultRecord) {
        records.removeAll { $0.id == record.id }
        persist()
    }

    func pruneUnavailable(fileManager: FileManager = .default) {
        records.removeAll { record in
            var isDirectory: ObjCBool = false
            return !fileManager.fileExists(atPath: record.url.path, isDirectory: &isDirectory)
                || !isDirectory.boolValue
        }
        persist()
    }

    func clear() {
        records = []
        userDefaults.removeObject(forKey: storageKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    private static func normalized(
        _ source: [RecentVaultRecord],
        maximumCount: Int
    ) -> [RecentVaultRecord] {
        var seenPaths: Set<String> = []
        return source
            .filter { $0.url.isFileURL && !$0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
            .filter { seenPaths.insert($0.url.standardizedFileURL.path).inserted }
            .prefix(maximumCount)
            .map { $0 }
    }
}

struct SavedAdvancedSearch: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var query: String
    let createdAt: Date
    var updatedAt: Date
}

enum SavedAdvancedSearchError: LocalizedError, Equatable {
    case emptyName
    case emptyQuery

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Give this saved search a name."
        case .emptyQuery:
            "Enter a search query before saving it."
        }
    }
}

@Observable
@MainActor
final class SavedAdvancedSearchStore {
    private(set) var searches: [SavedAdvancedSearch]

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "advancedSearch.savedQueries"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey

        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([SavedAdvancedSearch].self, from: data) {
            searches = Self.normalized(decoded)
        } else {
            searches = []
        }
    }

    @discardableResult
    func save(
        name: String,
        query: String,
        id: UUID? = nil,
        at date: Date = Date()
    ) throws -> SavedAdvancedSearch {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw SavedAdvancedSearchError.emptyName }
        guard !cleanQuery.isEmpty,
              !ObsidianAdvancedSearchParser.parse(cleanQuery).isEmpty else {
            throw SavedAdvancedSearchError.emptyQuery
        }

        let requestedIndex = id.flatMap { requestedID in
            searches.firstIndex { $0.id == requestedID }
        }
        let normalizedCleanName = Self.normalizedName(cleanName)
        let sameNameIndex = searches.firstIndex {
            Self.normalizedName($0.name) == normalizedCleanName
        }
        let existingIndex = requestedIndex ?? sameNameIndex

        let saved: SavedAdvancedSearch
        if let existingIndex {
            let existing = searches[existingIndex]
            saved = SavedAdvancedSearch(
                id: existing.id,
                name: cleanName,
                query: cleanQuery,
                createdAt: existing.createdAt,
                updatedAt: date
            )
            searches[existingIndex] = saved
        } else {
            saved = SavedAdvancedSearch(
                id: id ?? UUID(),
                name: cleanName,
                query: cleanQuery,
                createdAt: date,
                updatedAt: date
            )
            searches.append(saved)
        }

        searches.removeAll {
            $0.id != saved.id && Self.normalizedName($0.name) == normalizedCleanName
        }
        searches.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        persist()
        return saved
    }

    func remove(id: UUID) {
        searches.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        searches = []
        userDefaults.removeObject(forKey: storageKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(searches) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    /// The single notion of "same name" shared by saving and loading, so a
    /// search that saves as unique never disappears on the next launch.
    private static func normalizedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func normalized(_ source: [SavedAdvancedSearch]) -> [SavedAdvancedSearch] {
        var seenIDs: Set<UUID> = []
        var seenNames: Set<String> = []
        return source
            .filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !ObsidianAdvancedSearchParser.parse($0.query).isEmpty
            }
            .sorted {
                if normalizedName($0.name) == normalizedName($1.name) {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .filter { search in
                seenIDs.insert(search.id).inserted
                    && seenNames.insert(normalizedName(search.name)).inserted
            }
    }
}

import Foundation
import XCTest

@testable import Obsidian

@MainActor
final class NoteWorkflowServicesTests: XCTestCase {
    func testWorkflowConfigurationPersistsWithInjectedDefaults() throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }

        let store = NoteWorkflowConfigurationStore(userDefaults: fixture.defaults)
        store.dailyNotes = DailyNoteConfiguration(
            folderPath: "Journal/Daily",
            dateFormat: "YYYY/MM/DD",
            templateRelativePath: "Daily.md"
        )
        store.templates = TemplateLibraryConfiguration(folderPath: "_templates")

        let restored = NoteWorkflowConfigurationStore(userDefaults: fixture.defaults)
        XCTAssertEqual(restored.dailyNotes, store.dailyNotes)
        XCTAssertEqual(restored.templates, store.templates)
    }

    func testSharedWorkflowConfigurationUpdatesLiveConsumers() throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }

        let appStore = NoteWorkflowConfigurationStore(userDefaults: fixture.defaults)
        let editorConsumer = appStore
        let settingsConsumer = appStore
        settingsConsumer.templates = TemplateLibraryConfiguration(folderPath: "_live-templates")

        XCTAssertEqual(editorConsumer.templates.folderPath, "_live-templates")
        XCTAssertTrue(editorConsumer === settingsConsumer)
    }

    func testDailyNoteCreatesAtomicallyFromTemplateWithObsidianVariables() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let templateFolder = vault.appendingPathComponent("Templates", isDirectory: true)
        try FileManager.default.createDirectory(at: templateFolder, withIntermediateDirectories: true)
        try "# {{title}}\nDate {{date}} Time {{time}}".write(
            to: templateFolder.appendingPathComponent("Daily.md"),
            atomically: true,
            encoding: .utf8
        )
        let date = try fixedDate(year: 2026, month: 7, day: 12, hour: 21, minute: 7)
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        let result = try DailyNoteService().createOrOpen(
            in: vault,
            date: date,
            timeZone: utc,
            locale: Locale(identifier: "en_US_POSIX"),
            configuration: DailyNoteConfiguration(
                folderPath: "Journal",
                dateFormat: "YYYY/MM/DD",
                templateRelativePath: "Daily.md"
            ),
            templateConfiguration: TemplateLibraryConfiguration(folderPath: "Templates")
        )

        XCTAssertTrue(result.wasCreated)
        XCTAssertEqual(result.fileURL.path, vault.appendingPathComponent("Journal/2026/07/12.md").path)
        XCTAssertEqual(
            try String(contentsOf: result.fileURL, encoding: .utf8),
            "# 12\nDate 2026-07-12 Time 21:07"
        )
        let permissions = try FileManager.default.attributesOfItem(atPath: result.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue ?? 0, 0o644)
    }

    func testDailyNoteNeverOverwritesExistingContent() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let folder = vault.appendingPathComponent("Daily Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existingURL = folder.appendingPathComponent("2026-07-12.md")
        try "Keep this exact text".write(to: existingURL, atomically: true, encoding: .utf8)
        let date = try fixedDate(year: 2026, month: 7, day: 12)

        let result = try DailyNoteService().createOrOpen(
            in: vault,
            date: date,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            locale: Locale(identifier: "en_US_POSIX"),
            configuration: .default
        )

        XCTAssertFalse(result.wasCreated)
        XCTAssertEqual(result.fileURL, existingURL.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "Keep this exact text")
    }

    func testCreatesNamedNoteFromTemplateWithoutOverwriting() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let templateFolder = vault.appendingPathComponent("Templates", isDirectory: true)
        try FileManager.default.createDirectory(at: templateFolder, withIntermediateDirectories: true)
        let templateURL = templateFolder.appendingPathComponent("Project.md")
        try "# {{title}}\nCreated {{date}}".write(to: templateURL, atomically: true, encoding: .utf8)
        let descriptor = TemplateDescriptor(relativePath: "Project.md", fileURL: templateURL)

        let created = try TemplateNoteService().create(
            in: vault,
            title: "Atlas",
            template: descriptor,
            templateConfiguration: .default,
            destinationFolderPath: "Projects",
            date: try fixedDate(year: 2026, month: 7, day: 12),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(created.path, vault.appendingPathComponent("Projects/Atlas.md").path)
        XCTAssertEqual(try String(contentsOf: created, encoding: .utf8), "# Atlas\nCreated 2026-07-12")
        XCTAssertThrowsError(
            try TemplateNoteService().create(
                in: vault,
                title: "Atlas",
                template: descriptor,
                templateConfiguration: .default,
                destinationFolderPath: "Projects"
            )
        )
    }

    func testDailyNoteRejectsVaultTraversal() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let date = try fixedDate(year: 2026, month: 7, day: 12)

        XCTAssertThrowsError(
            try DailyNoteService().createOrOpen(
                in: vault,
                date: date,
                timeZone: TimeZone(secondsFromGMT: 0)!,
                locale: Locale(identifier: "en_US_POSIX"),
                configuration: DailyNoteConfiguration(
                    folderPath: "../Outside",
                    dateFormat: "YYYY-MM-DD",
                    templateRelativePath: nil
                )
            )
        ) { error in
            guard case NoteWorkflowFileError.unsafeRelativePath = error else {
                return XCTFail("Expected an unsafe-path error, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.deletingLastPathComponent().appendingPathComponent("Outside").path))
    }

    func testTemplateLibraryListsSupportedFilesAndRejectsSymlinkEscape() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let templates = vault.appendingPathComponent("Templates", isDirectory: true)
        try FileManager.default.createDirectory(
            at: templates.appendingPathComponent("Nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "# A".write(to: templates.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try "# B".write(to: templates.appendingPathComponent("Nested/B.txt"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: templates.appendingPathComponent("ignored.bin"))

        let service = TemplateLibraryService()
        XCTAssertEqual(
            try service.availableTemplates(in: vault, configuration: .default).map(\.relativePath),
            ["A.md", "Nested/B.txt"]
        )

        let outside = vault.deletingLastPathComponent().appendingPathComponent("Outside-\(UUID().uuidString).md")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: templates.appendingPathComponent("Escape.md"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try service.loadTemplate(relativePath: "Escape.md", in: vault, configuration: .default)
        ) { error in
            guard case NoteWorkflowFileError.unsafeRelativePath = error else {
                return XCTFail("Expected an unsafe-path error, got \(error)")
            }
        }
    }

    func testRecentVaultsDeduplicateLimitPersistAndPrune() throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentVaultTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        let third = root.appendingPathComponent("Third", isDirectory: true)
        for url in [first, second, third] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let store = RecentVaultStore(userDefaults: fixture.defaults, maximumCount: 2)
        store.recordOpened(first, at: Date(timeIntervalSince1970: 1))
        store.recordOpened(second, at: Date(timeIntervalSince1970: 2))
        store.recordOpened(first, displayName: "My Brain", at: Date(timeIntervalSince1970: 3))
        store.recordOpened(third, at: Date(timeIntervalSince1970: 4))

        XCTAssertEqual(store.records.map(\.url), [third.standardizedFileURL, first.standardizedFileURL])
        XCTAssertEqual(store.records[1].displayName, "My Brain")

        let restored = RecentVaultStore(userDefaults: fixture.defaults, maximumCount: 2)
        XCTAssertEqual(restored.records, store.records)
        try FileManager.default.removeItem(at: third)
        restored.pruneUnavailable()
        XCTAssertEqual(restored.records.map(\.url), [first.standardizedFileURL])
    }

    func testSavedAdvancedSearchesValidateDeduplicateAndPersist() throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let store = SavedAdvancedSearchStore(userDefaults: fixture.defaults)
        let created = Date(timeIntervalSince1970: 100)
        let updated = Date(timeIntervalSince1970: 200)

        let initial = try store.save(
            name: "  Active work  ",
            query: "path:work property:status=active",
            at: created
        )
        let replacement = try store.save(
            name: "active WORK",
            query: "path:work tag:#priority",
            at: updated
        )

        XCTAssertEqual(replacement.id, initial.id)
        XCTAssertEqual(replacement.createdAt, created)
        XCTAssertEqual(store.searches.count, 1)
        XCTAssertThrowsError(try store.save(name: "Invalid", query: "OR")) { error in
            XCTAssertEqual(error as? SavedAdvancedSearchError, .emptyQuery)
        }

        let restored = SavedAdvancedSearchStore(userDefaults: fixture.defaults)
        XCTAssertEqual(restored.searches, store.searches)
    }

    func testStoresRecoverFromCorruptDefaults() throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        fixture.defaults.set(Data("not-json".utf8), forKey: "noteWorkflows.configuration")
        fixture.defaults.set(Data("not-json".utf8), forKey: "recentVaults.records")
        fixture.defaults.set(Data("not-json".utf8), forKey: "advancedSearch.savedQueries")

        XCTAssertEqual(NoteWorkflowConfigurationStore(userDefaults: fixture.defaults).dailyNotes, .default)
        XCTAssertTrue(RecentVaultStore(userDefaults: fixture.defaults).records.isEmpty)
        XCTAssertTrue(SavedAdvancedSearchStore(userDefaults: fixture.defaults).searches.isEmpty)
    }

    func testDateFormatQuotesLiteralsMapsTokensIndividuallyAndRejectsOrdinals() throws {
        XCTAssertEqual(try ObsidianDateFormat.foundationFormat(from: "[Daily] YYYY-MM-DD"), "'Daily' yyyy-MM-dd")
        XCTAssertEqual(try ObsidianDateFormat.foundationFormat(from: "YYYY-MM-DD dddd"), "yyyy-MM-dd EEEE")
        XCTAssertEqual(try ObsidianDateFormat.foundationFormat(from: "[Week's] YYYY"), "'Week''s' yyyy")
        XCTAssertThrowsError(try ObsidianDateFormat.foundationFormat(from: "Do MMMM YYYY")) { error in
            XCTAssertEqual(error as? NoteWorkflowFileError, .invalidDateFormat)
        }
        XCTAssertThrowsError(try ObsidianDateFormat.foundationFormat(from: "[Unclosed YYYY")) { error in
            XCTAssertEqual(error as? NoteWorkflowFileError, .invalidDateFormat)
        }
    }

    func testDailyNotePathLocalizesNamesButKeepsLatinDigits() throws {
        let date = try fixedDate(year: 2026, month: 7, day: 12)
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let posix = Locale(identifier: "en_US_POSIX")

        XCTAssertEqual(
            try DailyNoteService.relativeDatedPath(for: date, dateFormat: "[Daily] YYYY-MM-DD", timeZone: utc, locale: posix),
            "Daily 2026-07-12.md"
        )
        XCTAssertEqual(
            try DailyNoteService.relativeDatedPath(for: date, dateFormat: "YYYY-MM-DD dddd", timeZone: utc, locale: posix),
            "2026-07-12 Sunday.md"
        )
        XCTAssertEqual(
            try DailyNoteService.relativeDatedPath(
                for: date,
                dateFormat: "YYYY-MM-DD dddd",
                timeZone: utc,
                locale: Locale(identifier: "de_DE")
            ),
            "2026-07-12 Sonntag.md"
        )
        XCTAssertEqual(
            try DailyNoteService.relativeDatedPath(
                for: date,
                dateFormat: "YYYY-MM-DD",
                timeZone: utc,
                locale: Locale(identifier: "ar_SA")
            ),
            "2026-07-12.md"
        )
        XCTAssertThrowsError(
            try DailyNoteService.relativeDatedPath(for: date, dateFormat: "Do MMMM YYYY", timeZone: utc, locale: posix)
        ) { error in
            XCTAssertEqual(error as? NoteWorkflowFileError, .invalidDateFormat)
        }
    }

    func testDailyNoteNamesDefaultToEnglishAndIgnoreRegionWeekRules() throws {
        let date = try fixedDate(year: 2026, month: 7, day: 12)
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        // The default must not depend on Locale.current or the passed region.
        XCTAssertEqual(
            try DailyNoteService.relativeDatedPath(for: date, dateFormat: "YYYY-MM-DD dddd", timeZone: utc),
            "2026-07-12 Sunday.md"
        )
        for identifier in ["en_US_POSIX", "en_US", "en_GB", "de_DE"] {
            XCTAssertEqual(
                try DailyNoteService.relativeDatedPath(
                    for: date,
                    dateFormat: "gggg-[W]ww-d",
                    timeZone: utc,
                    locale: Locale(identifier: identifier)
                ),
                "2026-W29-0.md",
                identifier
            )
        }
    }

    func testDateFormatMatchesMomentForWeekdayAndWeekTokens() throws {
        let sunday = try fixedDate(year: 2026, month: 7, day: 12)
        let monday = try fixedDate(year: 2026, month: 7, day: 13, hour: 15)
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        func path(_ format: String, _ date: Date) throws -> String {
            try DailyNoteService.relativeDatedPath(for: date, dateFormat: format, timeZone: utc)
        }

        XCTAssertEqual(try path("d dd ddd dddd", sunday), "0 Su Sun Sunday.md")
        XCTAssertEqual(try path("d E", monday), "1 1.md")
        XCTAssertEqual(try path("E", sunday), "7.md")
        XCTAssertEqual(try path("[W]WW GGGG", sunday), "W28 2026.md")
        XCTAssertEqual(try path("w ww", sunday), "29 29.md")
        XCTAssertEqual(try path("h:mm A a", monday), "3:00 PM pm.md")
        // Week 1 of 2027 begins on Sunday 2026-12-27 under Moment's en rules.
        let newYearsEve = try fixedDate(year: 2026, month: 12, day: 31)
        XCTAssertEqual(try path("gggg-[W]ww GG-[W]WW", newYearsEve), "2027-W01 26-W53.md")
    }

    func testDateFormatTreatsApostrophesAndStrayBracketsAsText() throws {
        let date = try fixedDate(year: 2026, month: 7, day: 12)
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        func path(_ format: String) throws -> String {
            try DailyNoteService.relativeDatedPath(for: date, dateFormat: format, timeZone: utc)
        }

        XCTAssertEqual(try path("MMM D 'YY"), "Jul 12 '26.md")
        XCTAssertEqual(try path("[x'] YYYY"), "x' 2026.md")
        XCTAssertEqual(try path("[a'b] YYYY"), "a'b 2026.md")
        XCTAssertEqual(try path("YYYY] MM"), "2026] 07.md")
        XCTAssertEqual(try path("YYYY-MM-DDTHH"), "2026-07-12T12.md")
        XCTAssertEqual(try path("[A][B] YYYY"), "AB 2026.md")
        XCTAssertEqual(try path("\\YYYY YYYY"), "YYYY 2026.md")
        XCTAssertEqual(try ObsidianDateFormat.foundationFormat(from: "[A][B]"), "'AB'")
    }

    func testDateFormatRejectsEveryOrdinalAndUnrepresentableToken() throws {
        let date = try fixedDate(year: 2026, month: 7, day: 12)
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let unsupported = [
            "Do", "Mo YYYY", "DDDo", "do", "Qo", "wo", "Wo", "dddd, MMMM Do YYYY",
            "SSS", "X", "x", "ZZ", "N", "YYYYYY",
            // Adjacent same-letter ICU tokens would be fused into one.
            "MMMMM", "HHH",
        ]
        for format in unsupported {
            XCTAssertThrowsError(
                try DailyNoteService.relativeDatedPath(for: date, dateFormat: format, timeZone: utc),
                format
            ) { error in
                XCTAssertEqual(error as? NoteWorkflowFileError, .invalidDateFormat, format)
            }
        }
        // The same token inside brackets is plain text.
        XCTAssertEqual(
            try DailyNoteService.relativeDatedPath(for: date, dateFormat: "[Do] YYYY", timeZone: utc),
            "Do 2026.md"
        )
    }

    func testDailyNoteOpensExistingEnglishNoteWhenAnotherLocaleIsRequested() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let date = try fixedDate(year: 2026, month: 10, day: 11)
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let configuration = DailyNoteConfiguration(
            folderPath: "",
            dateFormat: "YYYY-MM-DD dddd",
            templateRelativePath: nil
        )
        let englishURL = vault.appendingPathComponent("2026-10-11 Sunday.md").standardizedFileURL
        try "Obsidian wrote this".write(to: englishURL, atomically: true, encoding: .utf8)

        let defaulted = try DailyNoteService().createOrOpen(
            in: vault,
            date: date,
            timeZone: utc,
            configuration: configuration
        )
        XCTAssertFalse(defaulted.wasCreated)
        XCTAssertEqual(defaulted.fileURL, englishURL)

        let german = try DailyNoteService().createOrOpen(
            in: vault,
            date: date,
            timeZone: utc,
            locale: Locale(identifier: "de_DE"),
            configuration: configuration
        )
        XCTAssertFalse(german.wasCreated)
        XCTAssertEqual(german.fileURL, englishURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: vault.appendingPathComponent("2026-10-11 Sonntag.md").path)
        )

        // With no English note present, an explicit locale opts in to its names.
        let otherVault = try makeVault()
        defer { try? FileManager.default.removeItem(at: otherVault) }
        let created = try DailyNoteService().createOrOpen(
            in: otherVault,
            date: date,
            timeZone: utc,
            locale: Locale(identifier: "de_DE"),
            configuration: configuration
        )
        XCTAssertTrue(created.wasCreated)
        XCTAssertEqual(created.fileURL.lastPathComponent, "2026-10-11 Sonntag.md")
    }

    func testTemplateNoteRejectsDotPrefixedTitle() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let templateFolder = vault.appendingPathComponent("Templates", isDirectory: true)
        try FileManager.default.createDirectory(at: templateFolder, withIntermediateDirectories: true)
        let templateURL = templateFolder.appendingPathComponent("Project.md")
        try "# {{title}}".write(to: templateURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try TemplateNoteService().create(
                in: vault,
                title: ".hidden",
                template: TemplateDescriptor(relativePath: "Project.md", fileURL: templateURL),
                templateConfiguration: .default
            )
        ) { error in
            guard case NoteWorkflowFileError.unsafeRelativePath = error else {
                return XCTFail("Expected an unsafe-path error, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.appendingPathComponent(".hidden.md").path))
    }

    func testSavedSearchesTreatDiacriticVariantsAsOneName() throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let store = SavedAdvancedSearchStore(userDefaults: fixture.defaults)

        let first = try store.save(name: "Café", query: "tag:#coffee", at: Date(timeIntervalSince1970: 1))
        let second = try store.save(name: "cafe", query: "tag:#espresso", at: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(store.searches.map(\.name), ["cafe"])
        XCTAssertEqual(SavedAdvancedSearchStore(userDefaults: fixture.defaults).searches, store.searches)
    }

    func testSavedSearchLoadKeepsNewestDiacriticVariant() throws {
        let fixture = try makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let older = SavedAdvancedSearch(
            id: UUID(),
            name: "Café",
            query: "tag:#coffee",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let newer = SavedAdvancedSearch(
            id: UUID(),
            name: "Cafe",
            query: "tag:#espresso",
            createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        fixture.defaults.set(try JSONEncoder().encode([older, newer]), forKey: "advancedSearch.savedQueries")

        XCTAssertEqual(SavedAdvancedSearchStore(userDefaults: fixture.defaults).searches, [newer])
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "NoteWorkflowServicesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func makeVault() throws -> URL {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteWorkflowServicesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        return vault.standardizedFileURL
    }

    private func fixedDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 12,
        minute: Int = 0
    ) throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return try XCTUnwrap(components.date)
    }
}

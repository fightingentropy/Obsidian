import Darwin
import Foundation

struct TemplateDescriptor: Equatable, Identifiable, Sendable {
    let relativePath: String
    let fileURL: URL

    var id: String { relativePath }
    var displayName: String {
        (relativePath as NSString).deletingPathExtension
    }
}

struct TemplateRenderContext: Equatable, Sendable {
    var title: String
    var date: Date
    var timeZone: TimeZone

    init(title: String, date: Date = Date(), timeZone: TimeZone = .current) {
        self.title = title
        self.date = date
        self.timeZone = timeZone
    }
}

enum NoteWorkflowFileError: LocalizedError, Equatable {
    case missingVault
    case unsafeRelativePath(String)
    case invalidDateFormat
    case templateNotFound(String)
    case unreadableTemplate(String)
    case destinationIsDirectory(String)
    case destinationExists(String)

    var errorDescription: String? {
        switch self {
        case .missingVault:
            "Open a vault before using note workflows."
        case .unsafeRelativePath(let path):
            "The configured path points outside the vault: \(path)"
        case .invalidDateFormat:
            "The Daily Notes date format did not produce a safe file name."
        case .templateNotFound(let path):
            "The template could not be found: \(path)"
        case .unreadableTemplate(let path):
            "The template is not a readable UTF-8 text file: \(path)"
        case .destinationIsDirectory(let path):
            "The Daily Note path is already a folder: \(path)"
        case .destinationExists(let path):
            "A note already exists at: \(path)"
        }
    }
}

struct TemplateLibraryService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func availableTemplates(
        in vaultURL: URL,
        configuration: TemplateLibraryConfiguration
    ) throws -> [TemplateDescriptor] {
        let folderURL = try VaultRelativePath.directoryURL(
            root: vaultURL,
            relativePath: configuration.folderPath,
            createIfNeeded: false,
            fileManager: fileManager
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw NoteWorkflowFileError.unsafeRelativePath(configuration.folderPath)
        }

        let allowedExtensions: Set<String> = ["md", "markdown", "mdown", "txt"]
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        let folderPrefix = folderURL.path.hasSuffix("/") ? folderURL.path : folderURL.path + "/"
        var templates: [TemplateDescriptor] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  allowedExtensions.contains(url.pathExtension.lowercased()),
                  url.standardizedFileURL.path.hasPrefix(folderPrefix) else {
                continue
            }
            templates.append(
                TemplateDescriptor(
                    relativePath: String(url.standardizedFileURL.path.dropFirst(folderPrefix.count)),
                    fileURL: url.standardizedFileURL
                )
            )
        }

        return templates.sorted {
            $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
        }
    }

    func loadTemplate(
        relativePath: String,
        in vaultURL: URL,
        configuration: TemplateLibraryConfiguration
    ) throws -> String {
        var requestedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedPath.isEmpty else {
            throw NoteWorkflowFileError.templateNotFound(relativePath)
        }
        if (requestedPath as NSString).pathExtension.isEmpty {
            requestedPath += ".md"
        }

        let root = try VaultRelativePath.directoryURL(
            root: vaultURL,
            relativePath: configuration.folderPath,
            createIfNeeded: false,
            fileManager: fileManager
        )
        var isTemplateDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isTemplateDirectory),
              isTemplateDirectory.boolValue else {
            throw NoteWorkflowFileError.templateNotFound(relativePath)
        }
        let fileURL = try VaultRelativePath.existingFileURL(
            root: root,
            relativePath: requestedPath,
            fileManager: fileManager
        )

        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            if !fileManager.fileExists(atPath: fileURL.path) {
                throw NoteWorkflowFileError.templateNotFound(relativePath)
            }
            throw NoteWorkflowFileError.unreadableTemplate(relativePath)
        }
    }

    func render(_ template: String, context: TemplateRenderContext) -> String {
        ObsidianTemplateRenderer.render(
            template,
            title: context.title,
            date: context.date,
            timeZone: context.timeZone
        )
    }
}

struct DailyNoteCreationResult: Equatable, Sendable {
    let fileURL: URL
    let wasCreated: Bool
}

struct TemplateNoteService {
    private let fileManager: FileManager
    private let templateService: TemplateLibraryService

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.templateService = TemplateLibraryService(fileManager: fileManager)
    }

    func create(
        in vaultURL: URL,
        title: String,
        template: TemplateDescriptor,
        templateConfiguration: TemplateLibraryConfiguration,
        destinationFolderPath: String = "",
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> URL {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would create a hidden file that neither the sidebar
        // nor the template list shows, so the note would vanish on creation.
        guard !cleanTitle.isEmpty,
              !cleanTitle.hasPrefix("."),
              cleanTitle.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\n\r")) == nil else {
            throw NoteWorkflowFileError.unsafeRelativePath(title)
        }

        let templateText = try templateService.loadTemplate(
            relativePath: template.relativePath,
            in: vaultURL,
            configuration: templateConfiguration
        )
        let rendered = templateService.render(
            templateText,
            context: TemplateRenderContext(title: cleanTitle, date: date, timeZone: timeZone)
        )
        let relativePath = [destinationFolderPath, cleanTitle + ".md"]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "/")
        let destination = try VaultRelativePath.destinationFileURL(
            root: vaultURL,
            relativePath: relativePath,
            fileManager: fileManager
        )
        guard try ExclusiveAtomicFileWriter.writeIfAbsent(
            Data(rendered.utf8),
            to: destination,
            fileManager: fileManager
        ) else {
            throw NoteWorkflowFileError.destinationExists(relativePath)
        }
        return destination
    }
}

struct DailyNoteService {
    /// Obsidian formats daily-note names in English with Moment's default
    /// week rules unless the user changes Obsidian's own language, so file
    /// names are generated with this locale unless a caller opts in to
    /// another one. Following the macOS language or region would create a
    /// second note per day next to the one Obsidian writes.
    static let canonicalLocale = Locale(identifier: "en_US_POSIX")

    private let fileManager: FileManager
    private let templateService: TemplateLibraryService

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.templateService = TemplateLibraryService(fileManager: fileManager)
    }

    /// Creates today's note exactly once. If the note already exists (or a
    /// competing process wins the creation race), its URL is returned without
    /// altering a byte of the existing file.
    func createOrOpen(
        in vaultURL: URL,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = DailyNoteService.canonicalLocale,
        configuration: DailyNoteConfiguration,
        templateConfiguration: TemplateLibraryConfiguration = .default
    ) throws -> DailyNoteCreationResult {
        let datedPath = try Self.relativeDatedPath(
            for: date,
            dateFormat: configuration.dateFormat,
            timeZone: timeZone,
            locale: locale
        )
        let combinedPath = Self.combinedPath(folderPath: configuration.folderPath, datedPath: datedPath)
        let destinationURL = try VaultRelativePath.destinationFileURL(
            root: vaultURL,
            relativePath: combinedPath,
            fileManager: fileManager
        )

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw NoteWorkflowFileError.destinationIsDirectory(destinationURL.path)
            }
            return DailyNoteCreationResult(fileURL: destinationURL, wasCreated: false)
        }

        // A localized name must not hide the note Obsidian (or an earlier
        // launch) already wrote under the canonical English name today.
        if locale.identifier != Self.canonicalLocale.identifier,
           let canonicalPath = try? Self.relativeDatedPath(
               for: date,
               dateFormat: configuration.dateFormat,
               timeZone: timeZone,
               locale: Self.canonicalLocale
           ),
           canonicalPath != datedPath,
           let canonicalURL = try? VaultRelativePath.destinationFileURL(
               root: vaultURL,
               relativePath: Self.combinedPath(folderPath: configuration.folderPath, datedPath: canonicalPath),
               fileManager: fileManager
           ) {
            var isCanonicalDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: canonicalURL.path, isDirectory: &isCanonicalDirectory),
               !isCanonicalDirectory.boolValue {
                return DailyNoteCreationResult(fileURL: canonicalURL, wasCreated: false)
            }
        }

        let content: String
        if let templatePath = configuration.templateRelativePath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !templatePath.isEmpty {
            let template = try templateService.loadTemplate(
                relativePath: templatePath,
                in: vaultURL,
                configuration: templateConfiguration
            )
            let title = destinationURL.deletingPathExtension().lastPathComponent
            content = templateService.render(
                template,
                context: TemplateRenderContext(title: title, date: date, timeZone: timeZone)
            )
        } else {
            content = ""
        }

        let created = try ExclusiveAtomicFileWriter.writeIfAbsent(
            Data(content.utf8),
            to: destinationURL,
            fileManager: fileManager
        )
        let verifiedURL: URL
        if created {
            verifiedURL = destinationURL
        } else {
            // Revalidate after an exclusive-rename race. A path swapped to an
            // out-of-vault symlink must never be handed back to the caller.
            verifiedURL = try VaultRelativePath.destinationFileURL(
                root: vaultURL,
                relativePath: combinedPath,
                fileManager: fileManager
            )
        }
        return DailyNoteCreationResult(fileURL: verifiedURL, wasCreated: created)
    }

    private static func combinedPath(folderPath: String, datedPath: String) -> String {
        [folderPath, datedPath]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "/")
    }

    /// Month and weekday names follow `locale` (English by default, like
    /// Obsidian), while the calendar stays Gregorian and every numeric value
    /// (week numbers, weekday index) follows Moment's default English rules,
    /// so neither the region nor the calendar preference can shift a name.
    static func relativeDatedPath(
        for date: Date,
        dateFormat: String,
        timeZone: TimeZone,
        locale: Locale = DailyNoteService.canonicalLocale
    ) throws -> String {
        let trimmedFormat = dateFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFormat.isEmpty else { throw NoteWorkflowFileError.invalidDateFormat }

        let formatter = DateFormatter()
        formatter.locale = Self.formattingLocale(locale)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = try ObsidianDateFormat.foundationFormat(
            from: trimmedFormat,
            fields: MomentDateFields(date: date, timeZone: timeZone)
        )

        var path = formatter.string(from: date)
        guard !path.isEmpty else { throw NoteWorkflowFileError.invalidDateFormat }
        if !path.lowercased().hasSuffix(".md")
            && !path.lowercased().hasSuffix(".markdown") {
            path += ".md"
        }
        guard VaultRelativePath.isSafe(path) else {
            throw NoteWorkflowFileError.invalidDateFormat
        }
        return path
    }

    /// Keeps digits Latin regardless of the locale's numbering system so a
    /// Daily Note's file name never changes script between launches.
    private static func formattingLocale(_ locale: Locale) -> Locale {
        var components = Locale.Components(locale: locale)
        components.numberingSystem = Locale.NumberingSystem("latn")
        return Locale(components: components)
    }
}

/// Values for Moment tokens whose ICU counterpart numbers things differently
/// (or not at all), computed with Moment's default English rules: weeks start
/// on Sunday and week 1 contains January 1st; `W`/`G` tokens are ISO weeks.
struct MomentDateFields: Equatable, Sendable {
    /// 0...6, Sunday = 0 (Moment `d`, `e`).
    let weekday: Int
    /// 1...7, Monday = 1 (Moment `E`).
    let isoWeekday: Int
    /// Moment `w` and `gg`/`gggg`.
    let week: Int
    let weekYear: Int
    /// Moment `W` and `GG`/`GGGG`.
    let isoWeek: Int
    let isoWeekYear: Int
    let hour: Int

    init(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 1
        calendar.minimumDaysInFirstWeek = 1
        var isoCalendar = Calendar(identifier: .iso8601)
        isoCalendar.timeZone = timeZone

        weekday = calendar.component(.weekday, from: date) - 1
        isoWeekday = (weekday + 6) % 7 + 1
        week = calendar.component(.weekOfYear, from: date)
        weekYear = calendar.component(.yearForWeekOfYear, from: date)
        isoWeek = isoCalendar.component(.weekOfYear, from: date)
        isoWeekYear = isoCalendar.component(.yearForWeekOfYear, from: date)
        hour = calendar.component(.hour, from: date)
    }
}

enum ObsidianDateFormat {
    private enum Field: Sendable {
        case weekday, isoWeekday
        case week, weekPadded, weekYear2, weekYear4
        case isoWeek, isoWeekPadded, isoWeekYear2, isoWeekYear4
        case meridiemUpper, meridiemLower

        func text(from fields: MomentDateFields) -> String {
            switch self {
            case .weekday: String(fields.weekday)
            case .isoWeekday: String(fields.isoWeekday)
            case .week: String(fields.week)
            case .weekPadded: String(format: "%02d", fields.week)
            case .weekYear2: String(format: "%02d", fields.weekYear % 100)
            case .weekYear4: String(format: "%04d", fields.weekYear)
            case .isoWeek: String(fields.isoWeek)
            case .isoWeekPadded: String(format: "%02d", fields.isoWeek)
            case .isoWeekYear2: String(format: "%02d", fields.isoWeekYear % 100)
            case .isoWeekYear4: String(format: "%04d", fields.isoWeekYear)
            case .meridiemUpper: fields.hour < 12 ? "AM" : "PM"
            case .meridiemLower: fields.hour < 12 ? "am" : "pm"
            }
        }
    }

    private enum Action: Sendable {
        /// Same meaning in ICU, possibly under another spelling.
        case icu(String)
        /// Evaluated up front and emitted as a quoted literal.
        case field(Field)
        /// A Moment token with no faithful ICU equivalent (ordinals, eras,
        /// fractional seconds, time zones, ...). A clear error beats a file
        /// name that silently differs from the one Obsidian would write.
        case reject
    }

    /// Every Moment token, matched longest first so `YYYY` is consumed before
    /// `YY` and `dddd` before `dd`. Characters that are not part of a token
    /// are literal text, as in Moment.
    private static let tokenTable: [(moment: String, action: Action)] = {
        var table: [(moment: String, action: Action)] = [
            ("YYYY", .icu("yyyy")), ("YY", .icu("yy")), ("Y", .icu("y")),
            ("Q", .icu("Q")),
            ("MMMM", .icu("MMMM")), ("MMM", .icu("MMM")), ("MM", .icu("MM")), ("M", .icu("M")),
            ("DDDD", .icu("DDD")), ("DDD", .icu("D")), ("DD", .icu("dd")), ("D", .icu("d")),
            ("dddd", .icu("EEEE")), ("ddd", .icu("EEE")), ("dd", .icu("EEEEEE")),
            ("d", .field(.weekday)), ("e", .field(.weekday)), ("E", .field(.isoWeekday)),
            ("ww", .field(.weekPadded)), ("w", .field(.week)),
            ("WW", .field(.isoWeekPadded)), ("W", .field(.isoWeek)),
            ("gggg", .field(.weekYear4)), ("gg", .field(.weekYear2)),
            ("GGGG", .field(.isoWeekYear4)), ("GG", .field(.isoWeekYear2)),
            ("HH", .icu("HH")), ("H", .icu("H")), ("hh", .icu("hh")), ("h", .icu("h")),
            ("kk", .icu("kk")), ("k", .icu("k")),
            ("mm", .icu("mm")), ("m", .icu("m")), ("ss", .icu("ss")), ("s", .icu("s")),
            ("A", .field(.meridiemUpper)), ("a", .field(.meridiemLower)),
            // Ordinals and the remaining tokens ICU cannot express faithfully.
            ("Mo", .reject), ("Qo", .reject), ("Do", .reject), ("DDDo", .reject),
            ("do", .reject), ("wo", .reject), ("Wo", .reject), ("yo", .reject),
            ("ggggg", .reject), ("GGGGG", .reject),
            ("YYYYYY", .reject), ("YYYYY", .reject),
            ("y", .reject), ("yy", .reject), ("yyy", .reject), ("yyyy", .reject),
            ("N", .reject), ("NN", .reject), ("NNN", .reject), ("NNNN", .reject), ("NNNNN", .reject),
            ("x", .reject), ("X", .reject),
            ("z", .reject), ("zz", .reject), ("Z", .reject), ("ZZ", .reject),
        ]
        for count in 1...9 {
            table.append((String(repeating: "S", count: count), .reject))
        }
        return table.sorted { $0.moment.count > $1.moment.count }
    }()

    /// Obsidian's default `YYYY-MM-DD` uses Moment tokens, while DateFormatter
    /// interprets capital Y/D as week-year/day-of-year. Translate the format
    /// token by token so copied Daily Notes settings retain their intended
    /// dates: `[...]` and any non-token letter become quoted ICU literals,
    /// `\` escapes the following token, tokens that depend on week rules or
    /// number differently in ICU are evaluated from `fields`, and tokens that
    /// cannot be reproduced (every ordinal such as `Do`, eras, time zones,
    /// fractional seconds), an unbalanced `[`, or two adjacent tokens ICU
    /// would fuse into one are rejected.
    static func foundationFormat(from source: String, fields: MomentDateFields? = nil) throws -> String {
        var result = ""
        // Literal text is gathered here so adjacent literals form one quoted
        // run; emitting `'A'` next to `'B'` would read back as `A'B`.
        var pendingLiteral = ""
        var lastICULetter: Character?
        var remainder = Substring(source)

        func flushLiteral() {
            guard !pendingLiteral.isEmpty else { return }
            // An apostrophe at the edge of a quoted run would read back as an
            // escaped quote, so edge apostrophes are emitted outside the quotes.
            var core = Substring(pendingLiteral)
            var leading = 0
            while core.first == "'" {
                core.removeFirst()
                leading += 1
            }
            var trailing = 0
            while core.last == "'" {
                core.removeLast()
                trailing += 1
            }
            result += String(repeating: "''", count: leading)
            if !core.isEmpty {
                result += "'" + core.replacingOccurrences(of: "'", with: "''") + "'"
            }
            result += String(repeating: "''", count: trailing)
            pendingLiteral = ""
        }

        while let character = remainder.first {
            switch character {
            case "[":
                let body = remainder.dropFirst()
                guard let close = body.firstIndex(of: "]"),
                      !body[..<close].contains("[") else {
                    throw NoteWorkflowFileError.invalidDateFormat
                }
                pendingLiteral += body[..<close]
                remainder = body[body.index(after: close)...]
                lastICULetter = nil
            case "\\":
                remainder.removeFirst()
                guard let escaped = remainder.first else { continue }
                if escaped == "[" { throw NoteWorkflowFileError.invalidDateFormat }
                // Moment escapes a whole token ("\YYYY" prints YYYY).
                let length = tokenTable.first(where: { remainder.hasPrefix($0.moment) })?.moment.count ?? 1
                pendingLiteral += remainder.prefix(length)
                remainder.removeFirst(length)
                lastICULetter = nil
            default:
                if let token = tokenTable.first(where: { remainder.hasPrefix($0.moment) }) {
                    switch token.action {
                    case .reject:
                        throw NoteWorkflowFileError.invalidDateFormat
                    case .field(let field):
                        guard let fields else { throw NoteWorkflowFileError.invalidDateFormat }
                        pendingLiteral += field.text(from: fields)
                        lastICULetter = nil
                    case .icu(let pattern):
                        guard lastICULetter != pattern.first else {
                            throw NoteWorkflowFileError.invalidDateFormat
                        }
                        flushLiteral()
                        result += pattern
                        lastICULetter = pattern.first
                    }
                    remainder.removeFirst(token.moment.count)
                } else if character == "'" || (character.isASCII && character.isLetter) {
                    // Moment prints unknown letters and apostrophes as text.
                    pendingLiteral.append(character)
                    lastICULetter = nil
                    remainder.removeFirst()
                } else {
                    flushLiteral()
                    result.append(character)
                    lastICULetter = nil
                    remainder.removeFirst()
                }
            }
        }

        flushLiteral()
        return result
    }
}

private enum VaultRelativePath {
    static func isSafe(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0") else {
            return false
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    static func directoryURL(
        root: URL,
        relativePath: String,
        createIfNeeded: Bool,
        fileManager: FileManager
    ) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return try verifiedRoot(root, fileManager: fileManager)
        }
        guard isSafe(trimmed) else {
            throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
        }

        var current = try verifiedRoot(root, fileManager: fileManager)
        let components = trimmed.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let candidate = current.appendingPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else {
                    throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
                }
                let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
                guard isInside(resolved, root: try verifiedRoot(root, fileManager: fileManager)) else {
                    throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
                }
                current = resolved
            } else {
                guard createIfNeeded else {
                    return components[(index + 1)...].reduce(candidate) { partial, remaining in
                        partial.appendingPathComponent(remaining, isDirectory: true)
                    }.standardizedFileURL
                }
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
                current = candidate.standardizedFileURL
            }
        }
        return current
    }

    static func destinationFileURL(
        root: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws -> URL {
        guard isSafe(relativePath) else {
            throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
        }
        let components = relativePath.split(separator: "/").map(String.init)
        guard let filename = components.last else {
            throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
        }
        let directoryPath = components.dropLast().joined(separator: "/")
        let directory = try directoryURL(
            root: root,
            relativePath: directoryPath,
            createIfNeeded: true,
            fileManager: fileManager
        )
        let candidate = directory.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        if fileManager.fileExists(atPath: candidate.path) {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            let verifiedVault = try verifiedRoot(root, fileManager: fileManager)
            guard isInside(resolved, root: verifiedVault) else {
                throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
            }
        }
        return candidate
    }

    static func existingFileURL(
        root: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws -> URL {
        guard isSafe(relativePath) else {
            throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
        }
        let rootURL = try verifiedRoot(root, fileManager: fileManager)
        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(resolved, root: rootURL) else {
            throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw NoteWorkflowFileError.templateNotFound(relativePath)
        }
        return resolved
    }

    private static func verifiedRoot(_ root: URL, fileManager: FileManager) throws -> URL {
        guard root.isFileURL else { throw NoteWorkflowFileError.missingVault }
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NoteWorkflowFileError.missingVault
        }
        return resolved
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }
}

enum ExclusiveAtomicFileWriter {
    /// Writes a complete temporary file, flushes it, then atomically links it
    /// into place with RENAME_EXCL. Unlike a check-then-write sequence, this
    /// cannot replace a Daily Note created by another process in the interim.
    static func writeIfAbsent(
        _ data: Data,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporaryURL.path)

        let result = renamex_np(temporaryURL.path, destinationURL.path, UInt32(RENAME_EXCL))
        if result == 0 {
            shouldRemoveTemporaryFile = false
            return true
        }

        let errorCode = errno
        switch errorCode {
        case EEXIST:
            return false
        case ENOTSUP, EINVAL:
            // Network and FUSE volumes may not implement RENAME_EXCL. O_EXCL
            // still lets exactly one creator win, so fall back to it there.
            return try createExclusively(data, at: destinationURL, fileManager: fileManager)
        default:
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSFilePathErrorKey: destinationURL.path]
            )
        }
    }

    private static func createExclusively(
        _ data: Data,
        at destinationURL: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let descriptor = open(destinationURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            let errorCode = errno
            if errorCode == EEXIST {
                return false
            }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSFilePathErrorKey: destinationURL.path]
            )
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            // The note exists but is incomplete; never leave a truncated
            // file behind for the next launch to open as today's note.
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
        return true
    }
}

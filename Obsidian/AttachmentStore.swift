import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

enum AttachmentStoreError: LocalizedError {
    case missingVault
    case unsupportedAttachment
    case unsafeAttachmentFolder

    var errorDescription: String? {
        switch self {
        case .missingVault:
            "Open a vault before adding an attachment."
        case .unsupportedAttachment:
            "The pasted or dropped item is not a supported image or file."
        case .unsafeAttachmentFolder:
            "The configured attachment folder points outside this vault."
        }
    }
}

struct ImportedAttachment: Equatable, Sendable {
    let fileURL: URL
    let vaultRelativePath: String

    var markdownEmbed: String {
        "![[\(vaultRelativePath)]]"
    }
}

/// A paste or drop captured on the main actor: what the pasteboard offered
/// and where it should land. It holds plain values rather than the
/// pasteboard, so the slow half of the import can run off the main actor.
struct AttachmentImportRequest: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        /// A file pasted or dropped from Finder, copied into the vault.
        case file(URL)
        /// PNG bytes, written as they are.
        case png(Data)
        /// TIFF bytes (screenshots and many apps), transcoded to PNG.
        case tiff(Data)
    }

    let payload: Payload
    let documentURL: URL?
    let vaultURL: URL
}

/// Marks where a paste or drop will land while its attachment is imported in
/// the background. The editor text is left untouched meanwhile: nothing
/// temporary is ever typed into the note, so it cannot be autosaved, survive
/// a note switch, or come back through undo. The anchor only follows later
/// edits so the embed still lands where the paste was made.
struct AttachmentImportAnchor: Equatable, Sendable {
    /// The text the paste replaces (the selection), or an empty range at the
    /// caret.
    let range: NSRange

    /// Where the anchor sits after the characters in `edited` (a range of the
    /// old text) were replaced by `newLength` UTF-16 units. Edits before the
    /// anchor, including an insertion at its start, shift it; edits after it,
    /// including an insertion at its end, leave it; an edit that overlaps it
    /// collapses it to just past the replacement, so the embed is added there
    /// instead of replacing text the user has since changed.
    func adjusted(forEditReplacing edited: NSRange, withLength newLength: Int) -> AttachmentImportAnchor {
        if NSMaxRange(edited) <= range.location {
            let delta = newLength - edited.length
            return AttachmentImportAnchor(
                range: NSRange(location: max(0, range.location + delta), length: range.length)
            )
        }
        if edited.location >= NSMaxRange(range) {
            return self
        }
        return AttachmentImportAnchor(range: NSRange(location: edited.location + newLength, length: 0))
    }

    /// Where `selection` belongs once `replaced` holds `replacementLength`
    /// UTF-16 units: unchanged before it, shifted after it, resized when it
    /// spans it, and collapsed to just past the replacement when it only
    /// partly overlapped it. A selection that is exactly `replaced` (the
    /// caret has not moved since the paste) ends up as a caret after the
    /// replacement, as after an ordinary paste.
    static func adjustedSelection(
        _ selection: NSRange,
        afterReplacing replaced: NSRange,
        withLength replacementLength: Int
    ) -> NSRange {
        if selection == replaced {
            return NSRange(location: replaced.location + replacementLength, length: 0)
        }
        let delta = replacementLength - replaced.length
        if selection.location >= NSMaxRange(replaced) {
            return NSRange(location: selection.location + delta, length: selection.length)
        }
        if NSMaxRange(selection) <= replaced.location {
            return selection
        }
        if selection.location <= replaced.location, NSMaxRange(selection) >= NSMaxRange(replaced) {
            return NSRange(location: selection.location, length: selection.length + delta)
        }
        return NSRange(location: replaced.location + replacementLength, length: 0)
    }
}

enum AttachmentStore {
    private static let defaultFolderName = "attachments"
    private static let imageExtensions: Set<String> = [
        "avif", "gif", "heic", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp"
    ]

    /// Imports the first attachment on `pasteboard` in one blocking step on
    /// the main actor. The editor splits this into
    /// `importRequest(from:documentURL:vaultURL:)` and `importAttachment(_:)`
    /// instead, so a large paste never stalls typing; this entry point stays
    /// for callers (and tests) that want the whole import at once. Returns
    /// nil when the pasteboard holds nothing importable.
    @MainActor
    static func importFirstAttachment(
        from pasteboard: NSPasteboard,
        documentURL: URL?,
        vaultURL: URL?
    ) throws -> ImportedAttachment? {
        guard let request = try importRequest(
            from: pasteboard,
            documentURL: documentURL,
            vaultURL: vaultURL
        ) else {
            return nil
        }
        return try performImport(request)
    }

    /// Reads the first importable item off `pasteboard`: a file URL, else PNG
    /// data, else TIFF data. This read is the only part of an import that
    /// needs the main actor. Returns nil when the pasteboard holds none of
    /// these, and throws `missingVault` when no vault is open.
    @MainActor
    static func importRequest(
        from pasteboard: NSPasteboard,
        documentURL: URL?,
        vaultURL: URL?
    ) throws -> AttachmentImportRequest? {
        guard let vaultURL else { throw AttachmentStoreError.missingVault }

        let payload: AttachmentImportRequest.Payload
        if let sourceURL = fileURL(from: pasteboard) {
            payload = .file(sourceURL)
        } else if let pngData = pasteboard.data(forType: .png) {
            payload = .png(pngData)
        } else if let tiffData = pasteboard.data(forType: .tiff) {
            payload = .tiff(tiffData)
        } else {
            return nil
        }
        return AttachmentImportRequest(payload: payload, documentURL: documentURL, vaultURL: vaultURL)
    }

    /// Performs `request` on a detached task, so the TIFF transcode, the file
    /// copy and the fsync'd write never run on the main actor, whatever the
    /// caller's isolation. Throws `unsupportedAttachment` when TIFF data
    /// cannot be decoded.
    static func importAttachment(_ request: AttachmentImportRequest) async throws -> ImportedAttachment {
        try await Task.detached(priority: .userInitiated) { () throws -> ImportedAttachment in
            guard let attachment = try AttachmentStore.performImport(request) else {
                throw AttachmentStoreError.unsupportedAttachment
            }
            return attachment
        }.value
    }

    /// The blocking half of an import: copies the file, or writes the PNG
    /// (transcoding TIFF first), with the collision handling and vault
    /// containment checks of `importFile` and `importImageData`. Returns nil
    /// when TIFF data cannot be decoded.
    static func performImport(
        _ request: AttachmentImportRequest,
        fileManager: FileManager = .default
    ) throws -> ImportedAttachment? {
        switch request.payload {
        case .file(let sourceURL):
            return try importFile(
                sourceURL,
                documentURL: request.documentURL,
                vaultURL: request.vaultURL,
                fileManager: fileManager
            )
        case .png(let pngData):
            return try importImageData(
                pngData,
                suggestedFilename: pastedImageFilename(extension: "png"),
                documentURL: request.documentURL,
                vaultURL: request.vaultURL,
                fileManager: fileManager
            )
        case .tiff(let tiffData):
            guard let pngData = pngRepresentation(ofTIFF: tiffData) else { return nil }
            return try importImageData(
                pngData,
                suggestedFilename: pastedImageFilename(extension: "png"),
                documentURL: request.documentURL,
                vaultURL: request.vaultURL,
                fileManager: fileManager
            )
        }
    }

    /// Re-encodes TIFF data as PNG, or returns nil when it cannot be decoded.
    /// The bitmap never leaves this call, so it is safe off the main thread.
    static func pngRepresentation(ofTIFF tiffData: Data) -> Data? {
        guard let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func importFile(
        _ sourceURL: URL,
        documentURL: URL?,
        vaultURL: URL,
        fileManager: FileManager = .default
    ) throws -> ImportedAttachment {
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        guard source.isFileURL,
              fileManager.fileExists(atPath: source.path) else {
            throw AttachmentStoreError.unsupportedAttachment
        }

        let folder = try preparedAttachmentFolderURL(
            documentURL: documentURL,
            vaultURL: vaultURL,
            fileManager: fileManager
        )
        let values = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw AttachmentStoreError.unsupportedAttachment
        }

        while true {
            let destination = collisionSafeURL(
                in: folder,
                suggestedFilename: source.lastPathComponent,
                fileManager: fileManager
            )
            if try copyFileIfAbsent(source, to: destination, fileManager: fileManager) {
                return importedAttachment(at: destination, vaultURL: vaultURL)
            }
        }
    }

    static func importImageData(
        _ data: Data,
        suggestedFilename: String,
        documentURL: URL?,
        vaultURL: URL,
        fileManager: FileManager = .default
    ) throws -> ImportedAttachment {
        guard !data.isEmpty else { throw AttachmentStoreError.unsupportedAttachment }

        let folder = try preparedAttachmentFolderURL(
            documentURL: documentURL,
            vaultURL: vaultURL,
            fileManager: fileManager
        )

        while true {
            let destination = collisionSafeURL(
                in: folder,
                suggestedFilename: suggestedFilename,
                fileManager: fileManager
            )
            if try writeDataIfAbsent(data, to: destination, fileManager: fileManager) {
                return importedAttachment(at: destination, vaultURL: vaultURL)
            }
        }
    }

    static func attachmentFolderURL(
        documentURL: URL?,
        vaultURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let vault = vaultURL.resolvingSymlinksInPath().standardizedFileURL
        let configuredPath = obsidianAttachmentFolderPath(vaultURL: vault)

        let candidate: URL
        if let configuredPath, let subfolder = documentRelativeSubfolder(configuredPath) {
            // Obsidian writes "./" for "same folder as current file" and
            // "./name" for "subfolder under current folder".
            let base = documentURL?.deletingLastPathComponent() ?? vault
            candidate = subfolder.isEmpty ? base : base.appendingPathComponent(subfolder, isDirectory: true)
        } else if let configuredPath, !configuredPath.isEmpty {
            let relativePath = configuredPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            candidate = vault.appendingPathComponent(relativePath, isDirectory: true)
        } else if fileManager.fileExists(atPath: vault.appendingPathComponent("img", isDirectory: true).path) {
            candidate = vault.appendingPathComponent("img", isDirectory: true)
        } else {
            candidate = vault.appendingPathComponent(defaultFolderName, isDirectory: true)
        }

        return try validatedAttachmentFolder(candidate, vaultURL: vault)
    }

    /// Creates the selected attachment directory, then validates its resolved
    /// location a second time. The second check matters because a pre-existing
    /// path component may be a symlink and directory creation follows it.
    private static func preparedAttachmentFolderURL(
        documentURL: URL?,
        vaultURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        let candidate = try attachmentFolderURL(
            documentURL: documentURL,
            vaultURL: vaultURL,
            fileManager: fileManager
        )
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        let vault = vaultURL.resolvingSymlinksInPath().standardizedFileURL
        return try validatedAttachmentFolder(candidate, vaultURL: vault)
    }

    private static func validatedAttachmentFolder(_ candidate: URL, vaultURL: URL) throws -> URL {
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == vaultURL.path || resolved.path.hasPrefix(vaultURL.path + "/") else {
            throw AttachmentStoreError.unsafeAttachmentFolder
        }
        return resolved
    }

    /// The subfolder relative to the note's directory for a document-relative
    /// setting (`.`, `./`, `./sub`), or nil when the path is vault-relative.
    static func documentRelativeSubfolder(_ configuredPath: String) -> String? {
        if configuredPath == "." { return "" }
        guard configuredPath.hasPrefix("./") else { return nil }
        return configuredPath.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func obsidianAttachmentFolderPath(vaultURL: URL) -> String? {
        let settingsURL = vaultURL
            .appendingPathComponent(".obsidian", isDirectory: true)
            .appendingPathComponent("app.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["attachmentFolderPath"] as? String
    }

    private static func collisionSafeURL(
        in folderURL: URL,
        suggestedFilename: String,
        fileManager: FileManager
    ) -> URL {
        let sanitized = sanitizedFilename(suggestedFilename)
        let base = (sanitized as NSString).deletingPathExtension
        let ext = (sanitized as NSString).pathExtension
        var candidate = folderURL.appendingPathComponent(sanitized)
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            candidate = folderURL.appendingPathComponent(name)
            suffix += 1
        }
        return candidate
    }

    /// Copies through a private temporary file and installs it with
    /// `RENAME_EXCL`, so an iCloud or local writer that wins the destination
    /// race is never overwritten.
    private static func copyFileIfAbsent(
        _ sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let temporaryURL = temporaryURL(nextTo: destinationURL)
        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        // Attachments are data, not launchable programs. Do not preserve an
        // executable source mode inside the vault.
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporaryURL.path)

        let installed = try installTemporaryFileExclusively(
            temporaryURL,
            at: destinationURL
        )
        if installed {
            shouldRemoveTemporaryFile = false
        }
        return installed
    }

    static func writeDataIfAbsent(
        _ data: Data,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let temporaryURL = temporaryURL(nextTo: destinationURL)
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

        let installed = try installTemporaryFileExclusively(
            temporaryURL,
            at: destinationURL
        )
        if installed {
            shouldRemoveTemporaryFile = false
        }
        return installed
    }

    private static func installTemporaryFileExclusively(
        _ temporaryURL: URL,
        at destinationURL: URL
    ) throws -> Bool {
        let result = renamex_np(
            temporaryURL.path,
            destinationURL.path,
            UInt32(RENAME_EXCL)
        )
        if result == 0 {
            return true
        }

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

    private static func temporaryURL(nextTo destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).attachment-tmp",
            isDirectory: false
        )
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let fallbackExtension = imageExtensions.contains((filename as NSString).pathExtension.lowercased())
            ? (filename as NSString).pathExtension.lowercased()
            : "bin"
        let rawBase = (filename as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_()."))
        var base = rawBase.unicodeScalars
            .map { allowed.contains($0) ? Character(String($0)) : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would hide the file from the asset index. Trim around
        // the dots until neither remains, so " .notes" cannot keep one behind
        // leading whitespace.
        while let first = base.first, first == "." || first.isWhitespace {
            base.removeFirst()
        }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = base.isEmpty ? "Attachment" : base
        let rawExtension = (filename as NSString).pathExtension.lowercased()
        let safeExtension = rawExtension.range(of: "^[a-z0-9]{1,10}$", options: .regularExpression) != nil
            ? rawExtension
            : fallbackExtension
        return safeExtension.isEmpty ? safeBase : "\(safeBase).\(safeExtension)"
    }

    private static func importedAttachment(at url: URL, vaultURL: URL) -> ImportedAttachment {
        let vaultPath = vaultURL.standardizedFileURL.path.hasSuffix("/")
            ? vaultURL.standardizedFileURL.path
            : vaultURL.standardizedFileURL.path + "/"
        let relativePath = String(url.standardizedFileURL.path.dropFirst(vaultPath.count))
        return ImportedAttachment(fileURL: url, vaultRelativePath: relativePath)
    }

    private static func pastedImageFilename(extension pathExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "Pasted image \(formatter.string(from: Date())).\(pathExtension)"
    }

    @MainActor
    private static func fileURL(from pasteboard: NSPasteboard) -> URL? {
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] {
            return objects.first
        }
        return nil
    }
}

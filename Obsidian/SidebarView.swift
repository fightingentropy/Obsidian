import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct SidebarDragItem: Codable, Transferable {
    let path: String

    init(url: URL) {
        path = url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sidebarDragItem)
    }

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let encodedItem = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.sidebarDragItem.identifier, visibility: .all) { completion in
            completion(encodedItem, nil)
            return nil
        }
        return provider
    }

    static func loadFirst(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor (SidebarDragItem?) -> Void
    ) {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.sidebarDragItem.identifier) }) else {
            Task { @MainActor in
                completion(nil)
            }
            return
        }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.sidebarDragItem.identifier) { data, _ in
            let item = data.flatMap { try? JSONDecoder().decode(SidebarDragItem.self, from: $0) }
            Task { @MainActor in
                completion(item)
            }
        }
    }
}

extension UTType {
    static let sidebarDragItem = UTType(exportedAs: "com.md.markdown.sidebar-drag-item")
}

enum SidebarDropSupport {
    static let internalTypeIdentifiers = [UTType.sidebarDragItem.identifier]
    static let rootTypeIdentifiers = [
        UTType.sidebarDragItem.identifier,
        UTType.fileURL.identifier,
        UTType.url.identifier
    ]

    static func handleMoveDrop(
        providers: [NSItemProvider],
        to directoryURL: URL?,
        workspace: Workspace,
        onSuccess: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        guard providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.sidebarDragItem.identifier) }) else {
            return false
        }

        SidebarDragItem.loadFirst(from: providers) { item in
            guard let item else { return }
            if workspace.moveItem(item.url, toFolder: directoryURL) {
                onSuccess()
            }
        }

        return true
    }

    static func handleRootDrop(providers: [NSItemProvider], workspace: Workspace) -> Bool {
        if handleMoveDrop(providers: providers, to: nil, workspace: workspace) {
            return true
        }

        let urlProviders = providers.filter { $0.canLoadObject(ofClass: NSURL.self) }
        guard !urlProviders.isEmpty else {
            return false
        }

        for provider in urlProviders {
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = object as? NSURL else { return }
                let fileURL = url as URL
                guard isMD(fileURL) else { return }
                Task { @MainActor in
                    workspace.importDroppedFile(fileURL)
                }
            }
        }

        return true
    }
}

// MARK: - Sidebar Node List

struct SidebarNodeList: View {
    let nodes: [SidebarNode]
    let workspace: Workspace
    @Binding var expandedFolderURLs: Set<URL>
    let onRenameRequested: (RenameRequest) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.isFolder {
                SidebarFolderRow(
                    node: node,
                    workspace: workspace,
                    expandedFolderURLs: $expandedFolderURLs,
                    onRenameRequested: onRenameRequested
                )
            } else if let file = workspace.fileItem(for: node.url) {
                SidebarFileRow(
                    file: file,
                    workspace: workspace,
                    onRenameRequested: {
                        onRenameRequested(RenameRequest(file: file))
                    }
                )
            } else {
                SidebarAssetRow(node: node, workspace: workspace)
            }
        }
    }
}

// MARK: - Sidebar Folder Row

struct SidebarFolderRow: View {
    let node: SidebarNode
    let workspace: Workspace
    @Binding var expandedFolderURLs: Set<URL>
    let onRenameRequested: (RenameRequest) -> Void
    @State private var isDropTargeted = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        DisclosureGroup(isExpanded: expansionBinding) {
            SidebarNodeList(
                nodes: node.children,
                workspace: workspace,
                expandedFolderURLs: $expandedFolderURLs,
                onRenameRequested: onRenameRequested
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(node.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 27)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(node.name), folder")
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expansionBinding.wrappedValue.toggle()
                }
            }
            .contextMenu {
                folderActions
            }
            .onDrop(of: SidebarDropSupport.internalTypeIdentifiers, isTargeted: $isDropTargeted) { providers in
                SidebarDropSupport.handleMoveDrop(
                    providers: providers,
                    to: node.url,
                    workspace: workspace
                ) {
                    expandedFolderURLs.insert(node.url)
                }
            }
            .confirmationDialog(
                "Move “\(node.name)” and its contents to Trash?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) {
                    workspace.deleteItem(node.url)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteConfirmationMessage)
            }
        }
        .listRowInsets(sidebarRowInsets)
        .listRowBackground(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expandedFolderURLs.contains(node.url) },
            set: { isExpanded in
                if isExpanded {
                    expandedFolderURLs.insert(node.url)
                } else {
                    expandedFolderURLs.remove(node.url)
                }
            }
        )
    }

    @ViewBuilder
    private var folderActions: some View {
        Button {
            onRenameRequested(RenameRequest(folder: node))
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            expandedFolderURLs.insert(node.url)
            workspace.createNewFile(in: node.url)
        } label: {
            Label("New File", systemImage: "doc.badge.plus")
        }

        Button {
            expandedFolderURLs.insert(node.url)
            workspace.createNewFolder(in: node.url)
        } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }

        Divider()

        Button(role: .destructive) {
            showDeleteConfirmation = true
        } label: {
            Label("Move Folder to Trash", systemImage: "trash")
        }
    }

    private var deleteConfirmationMessage: String {
        let counts = descendantCounts(in: node.children)
        let contents: String
        switch (counts.folders, counts.items) {
        case (0, 0):
            contents = "The folder is empty."
        case (0, let items):
            contents = "It contains \(items) \(items == 1 ? "item" : "items")."
        case (let folders, 0):
            contents = "It contains \(folders) \(folders == 1 ? "subfolder" : "subfolders")."
        case (let folders, let items):
            contents = "It contains \(folders) \(folders == 1 ? "subfolder" : "subfolders") and \(items) \(items == 1 ? "item" : "items")."
        }
        return "\(contents) Everything will be moved to Trash and can be recovered from Finder."
    }

    private func descendantCounts(in nodes: [SidebarNode]) -> (folders: Int, items: Int) {
        nodes.reduce(into: (folders: 0, items: 0)) { result, child in
            if child.isFolder {
                result.folders += 1
                let nested = descendantCounts(in: child.children)
                result.folders += nested.folders
                result.items += nested.items
            } else {
                result.items += 1
            }
        }
    }
}

// MARK: - Sidebar Asset Row

struct SidebarAssetRow: View {
    let node: SidebarNode
    let workspace: Workspace
    @State private var showDeleteConfirmation = false

    private var isSelected: Bool {
        node.url == workspace.selectedFileURL
    }

    var body: some View {
        Button {
            workspace.selectFile(node.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(node.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 27)
            .padding(.horizontal, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(node.name), asset")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .listRowInsets(sidebarRowInsets)
        .onDrag {
            SidebarDragItem(url: node.url).itemProvider()
        }
        .contextMenu {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Move “\(node.name)” to Trash?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                workspace.deleteItem(node.url)
            }
            Button("Cancel", role: .cancel) {}
        }
        .listRowBackground(Color.clear)
    }
}

// MARK: - Sidebar File Row

struct SidebarFileRow: View {
    let file: FileItem
    let workspace: Workspace
    let onRenameRequested: () -> Void
    @State private var showDeleteConfirmation = false

    private var isSelected: Bool {
        file.url == workspace.selectedFileURL
    }

    var body: some View {
        Button {
            workspace.selectFile(file.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "doc.text.fill" : "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(workspace.title(for: file))
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 27)
            .padding(.horizontal, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(workspace.title(for: file))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .buttonStyle(.plain)
        .listRowInsets(sidebarRowInsets)
        .onDrag {
            SidebarDragItem(url: file.url).itemProvider()
        }
        .contextMenu {
            Button {
                onRenameRequested()
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button("Delete", role: .destructive) {
                showDeleteConfirmation = true
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                onRenameRequested()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.accentColor)

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Move “\(workspace.title(for: file))” to Trash?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                workspace.deleteItem(file.url)
            }
            Button("Cancel", role: .cancel) {}
        }
        .listRowBackground(Color.clear)
    }
}

let sidebarRowInsets = EdgeInsets(top: 1, leading: 2, bottom: 1, trailing: 8)

// MARK: - Sidebar Root Drop Area

struct SidebarRootDropArea: View {
    let workspace: Workspace
    @Binding var isTargeted: Bool

    var body: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onDrop(of: SidebarDropSupport.rootTypeIdentifiers, isTargeted: $isTargeted) { providers in
                SidebarDropSupport.handleRootDrop(providers: providers, workspace: workspace)
            }
    }
}

// MARK: - Backlinks Section

struct BacklinksSection: View {
    let workspace: Workspace

    var body: some View {
        // Resolved once per render; the graph walk is O(edges).
        let backlinks = workspace.noteGraph.backlinks(to: workspace.selectedFileURL)

        if !backlinks.isEmpty {
            Section {
                ForEach(backlinks) { node in
                    Button {
                        workspace.selectFile(node.url)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "link")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)

                            Text(node.title)
                                .lineLimit(1)

                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(node.title), backlink")
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(sidebarRowInsets)
                    .listRowBackground(Color.clear)
                }
            } header: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.left.up")
                        .font(.caption2)
                    Text("Backlinks")
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Sidebar Background Context Menu

struct SidebarBackgroundContextMenuHost: NSViewRepresentable {
    let onCreateFile: () -> Void
    let onCreateFolder: () -> Void
    let onDeleteSelection: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onCreateFile: onCreateFile,
            onCreateFolder: onCreateFolder,
            onDeleteSelection: onDeleteSelection
        )
    }

    func makeNSView(context: Context) -> SidebarBackgroundContextMenuView {
        let view = SidebarBackgroundContextMenuView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: SidebarBackgroundContextMenuView, context: Context) {
        context.coordinator.onCreateFile = onCreateFile
        context.coordinator.onCreateFolder = onCreateFolder
        context.coordinator.onDeleteSelection = onDeleteSelection
        nsView.coordinator = context.coordinator
    }

    @MainActor
    final class Coordinator: NSObject {
        var onCreateFile: () -> Void
        var onCreateFolder: () -> Void
        var onDeleteSelection: (() -> Void)?

        init(
            onCreateFile: @escaping () -> Void,
            onCreateFolder: @escaping () -> Void,
            onDeleteSelection: (() -> Void)?
        ) {
            self.onCreateFile = onCreateFile
            self.onCreateFolder = onCreateFolder
            self.onDeleteSelection = onDeleteSelection
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()

            let fileItem = NSMenuItem(
                title: "New File",
                action: #selector(createFile),
                keyEquivalent: ""
            )
            fileItem.target = self
            menu.addItem(fileItem)

            let folderItem = NSMenuItem(
                title: "New Folder",
                action: #selector(createFolder),
                keyEquivalent: ""
            )
            folderItem.target = self
            menu.addItem(folderItem)

            if onDeleteSelection != nil {
                menu.addItem(.separator())

                let deleteItem = NSMenuItem(
                    title: "Delete",
                    action: #selector(deleteSelection),
                    keyEquivalent: ""
                )
                deleteItem.target = self
                deleteItem.image = NSImage(
                    systemSymbolName: "trash",
                    accessibilityDescription: "Delete"
                )
                menu.addItem(deleteItem)
            }

            return menu
        }

        @objc private func createFile() {
            onCreateFile()
        }

        @objc private func createFolder() {
            onCreateFolder()
        }

        @objc private func deleteSelection() {
            onDeleteSelection?()
        }
    }
}

@MainActor
final class SidebarBackgroundContextMenuView: NSView {
    weak var coordinator: SidebarBackgroundContextMenuHost.Coordinator?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard shouldActivateForCurrentEvent(at: point) else {
            return nil
        }

        return shouldHandleBlankSidebarArea(at: point) ? self : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let localPoint = convert(event.locationInWindow, from: nil)
        guard shouldHandleBlankSidebarArea(at: localPoint) else {
            return nil
        }

        return coordinator?.makeMenu()
    }

    private func shouldActivateForCurrentEvent(at point: NSPoint) -> Bool {
        guard bounds.contains(point), let event = NSApp.currentEvent else {
            return false
        }

        switch event.type {
        case .rightMouseDown:
            return true
        case .leftMouseDown:
            return event.modifierFlags.contains(.control)
        default:
            return false
        }
    }

    private func shouldHandleBlankSidebarArea(at point: NSPoint) -> Bool {
        guard let tableView = enclosingTableView() else {
            // If SwiftUI's backing list cannot be identified, do not steal the
            // right-click from row-level context menus.
            return false
        }

        let pointInTableView = tableView.convert(point, from: self)
        guard tableView.bounds.contains(pointInTableView) else {
            return false
        }

        return tableView.row(at: pointInTableView) == -1
    }

    private func enclosingTableView() -> NSTableView? {
        guard let containerView = superview else { return nil }
        return findTableView(in: containerView, excluding: self)
    }

    private func findTableView(in view: NSView, excluding excludedView: NSView) -> NSTableView? {
        for subview in view.subviews where subview !== excludedView {
            if let tableView = subview as? NSTableView {
                return tableView
            }

            if let tableView = findTableView(in: subview, excluding: excludedView) {
                return tableView
            }
        }

        return nil
    }
}

// MARK: - Sidebar Expansion Persistence

enum SidebarExpansionRestoreResult: Equatable {
    case deferred
    case restored(Set<URL>)
}

enum SidebarExpansionPersistence {
    static func restoreResult(
        storedPaths: [String],
        validFolderURLs: Set<URL>,
        isLoadingSnapshot: Bool
    ) -> SidebarExpansionRestoreResult {
        if isLoadingSnapshot && validFolderURLs.isEmpty && !storedPaths.isEmpty {
            return .deferred
        }

        return .restored(
            matchedFolderURLs(
                for: storedPaths,
                within: validFolderURLs
            )
        )
    }

    /// Live filter applied on every `sidebarNodes` change. Both sets come from
    /// the same sidebar snapshot, so a plain standardized-URL intersection is
    /// enough; resolving symlinks for every folder is reserved for the
    /// stored-path restore below.
    static func filteredExpandedFolderURLs(
        _ expandedFolderURLs: Set<URL>,
        validFolderURLs: Set<URL>
    ) -> Set<URL> {
        let validFoldersByStandardizedURL = Dictionary(
            validFolderURLs.map { ($0.standardizedFileURL, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return Set(
            expandedFolderURLs.compactMap { validFoldersByStandardizedURL[$0.standardizedFileURL] }
        )
    }

    private static func matchedFolderURLs(
        for storedPaths: [String],
        within validFolderURLs: Set<URL>
    ) -> Set<URL> {
        let validFoldersByPath = keyedByCanonicalPath(validFolderURLs)
        return Set(
            storedPaths.compactMap { storedPath in
                validFoldersByPath[canonicalPath(forPath: storedPath)]
            }
        )
    }

    private static func keyedByCanonicalPath(_ urls: Set<URL>) -> [String: URL] {
        Dictionary(uniqueKeysWithValues: urls.map { (canonicalPath(for: $0), $0) })
    }

    private static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func canonicalPath(forPath path: String) -> String {
        canonicalPath(for: URL(fileURLWithPath: path))
    }
}

func isMD(_ url: URL) -> Bool {
    // Route through the workspace's single extension allowlist so drop targets
    // can never accept a file type the rest of the app rejects (a `.txt` drop
    // once succeeded visually but then silently did nothing).
    Workspace.isMarkdownFile(url)
}

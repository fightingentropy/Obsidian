import SwiftUI

struct ContentView: View {
    @Bindable var workspace: Workspace
    @Bindable var preferences: AppPreferences
    @State private var controller = EditorController()
    @State private var renameRequest: RenameRequest?
    @State private var viewMode: OpenViewMode
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var expandedFolderURLs: Set<URL> = []
    @State private var isSidebarRootDropTargeted = false
    @State private var restoredVaultKey: String?
    @State private var workspaceSession = WorkspaceSession()
    @State private var isInspectorPresented = false
    @Bindable var workflowConfiguration: NoteWorkflowConfigurationStore
    @State private var recentVaults = RecentVaultStore()
    @State private var selectedTemplate: TemplateDescriptor?
    @State private var workflowError: String?
    @State private var isVaultHealthPresented = false
    // Derived from the vault inventory. Cached in state so the editor and the
    // toolbar menu don't rebuild them on every keystroke; refreshed by the
    // handlers in `observedDerivedState`.
    @State private var noteLinkCompletions: [String] = []
    @State private var availableTemplates: [TemplateDescriptor] = []

    init(
        workspace: Workspace,
        preferences: AppPreferences,
        workflowConfiguration: NoteWorkflowConfigurationStore
    ) {
        self.workspace = workspace
        self.preferences = preferences
        self.workflowConfiguration = workflowConfiguration
        _viewMode = State(initialValue: preferences.defaultOpenViewMode)
    }

    // Separate layout, observation, and presentation to keep SwiftUI type checking bounded.
    private var workspaceLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
                .focusedValue(\.editorController, controller)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.gray)
        .navigationTitle("")
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    titlebarTabs
                }
                // Keep the tab bar floating directly on the titlebar; without
                // this macOS 26 draws a glass tile behind the custom view.
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    titlebarTabs
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .inspector(isPresented: $isInspectorPresented) {
            NoteInspectorView(workspace: workspace, controller: controller)
                .inspectorColumnWidth(min: 270, ideal: 320, max: 440)
        }
        .background(WindowToolbarConfigurator(title: workspace.selectedFileName))
        .background(TitlebarAccessoryInstaller(content: noteViewToolbar, layoutAttribute: .right))
        .overlay {
            if workspace.isCommandPalettePresented {
                CommandPaletteView(workspace: workspace) {
                    restoreEditorFocusAfterPaletteDismiss()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
    }

    private var observedWorkspace: some View {
        workspaceLayout
        .onAppear {
            restoreExpandedFoldersIfNeeded()
            restoreWorkspaceSession()
            recordCurrentVault()
            applyPreferredViewMode()
        }
        .onDisappear {
            persistExpandedFolders()
        }
        .onChange(of: workspace.vaultURL) { _, _ in
            restoreExpandedFoldersIfNeeded(force: true)
            restoreWorkspaceSession()
            recordCurrentVault()
        }
        .onChange(of: workspace.sidebarNodes) { _, _ in
            restoreExpandedFoldersIfNeeded()
            if !workspace.isLoadingSnapshot,
               workspaceSession.isLoaded(for: workspace.vaultURL) {
                workspaceSession.prune(availableFiles: sessionFileURLs)
            }
        }
        .onChange(of: workspace.isLoadingSnapshot) { _, _ in
            restoreExpandedFoldersIfNeeded()
            restoreWorkspaceSession()
        }
        .onChange(of: expandedFolderURLs) { _, _ in
            persistExpandedFolders()
        }
        .onChange(of: workspace.text) { _, _ in
            workspace.scheduleAutosave()
        }
        .onChange(of: workspace.selectedFileURL) { _, _ in
            if workspaceSession.isLoaded(for: workspace.vaultURL) {
                workspaceSession.noteSelected(workspace.selectedFileURL)
            }
            applyPreferredViewMode()
            controller.requestEditorFocus()
        }
        .onChange(of: preferences.restoresExpandedFolders) { _, _ in
            restoreExpandedFoldersIfNeeded(force: true)
        }
        .onChange(of: preferences.collapsesFoldersOnVaultSwitch) { _, _ in
            restoreExpandedFoldersIfNeeded(force: true)
        }
        .onChange(of: preferences.defaultOpenViewMode) { _, _ in
            applyPreferredViewMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorFindCommand)) { _ in
            guard workspace.selectedFileIsMarkdown else { return }
            showEditorForSearch()
            controller.activateSearch()
        }
    }

    /// Refreshes the cached inventory-derived state. Kept separate from
    /// `observedWorkspace` so the modifier chain stays within the type-checker's
    /// budget. `searchIndexRevision` bumps whenever the note inventory or a
    /// title changes; selection matters because the selected note's live title
    /// can differ from its on-disk title.
    private var observedDerivedState: some View {
        observedWorkspace
        .onAppear {
            refreshNoteLinkCompletions()
            refreshAvailableTemplates()
        }
        .onChange(of: workspace.vaultURL) { _, _ in
            refreshNoteLinkCompletions()
            refreshAvailableTemplates()
        }
        .onChange(of: workspace.searchIndexRevision) { _, _ in
            refreshNoteLinkCompletions()
            refreshAvailableTemplates()
        }
        .onChange(of: workspace.selectedFileURL) { _, _ in
            refreshNoteLinkCompletions()
        }
        .onChange(of: workflowConfiguration.templates) { _, _ in
            refreshAvailableTemplates()
        }
    }

    var body: some View {
        observedDerivedState
        .sheet(item: $renameRequest) { request in
            RenameItemSheet(target: request) { proposedName in
                try workspace.renameItem(request.url, to: proposedName)
            }
        }
        .sheet(item: $selectedTemplate) { template in
            if let vaultURL = workspace.vaultURL {
                TemplateCreationSheet(
                    vaultURL: vaultURL,
                    template: template,
                    templateConfiguration: workflowConfiguration.templates
                ) { url in
                    workspace.refreshFiles()
                    workspace.selectFile(url)
                }
            }
        }
        .sheet(isPresented: $isVaultHealthPresented) {
            VaultHealthView(workspace: workspace)
        }
        .alert("Note Workflow Failed", isPresented: Binding(
            get: { workflowError != nil },
            set: { if !$0 { workflowError = nil } }
        )) {
            Button("OK", role: .cancel) { workflowError = nil }
        } message: {
            Text(workflowError ?? "")
        }
        .modifier(SaveStatusAlerts(workspace: workspace))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            Button {
                workspace.isCommandPalettePresented = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))

                    Text("Search")
                        .font(.system(size: 13))

                    Spacer()

                    Text("⌘ K")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search Notes")
            .accessibilityLabel("Search Notes")
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Group {
                if workspace.sidebarNodes.isEmpty {
                    ContentUnavailableView(
                        "No Notes",
                        systemImage: "folder",
                        description: Text("This folder doesn't contain any markdown files or visible subfolders yet.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        SidebarNodeList(
                            nodes: workspace.sidebarNodes,
                            workspace: workspace,
                            expandedFolderURLs: $expandedFolderURLs,
                            onRenameRequested: { request in
                                renameRequest = request
                            }
                        )

                        BacklinksSection(workspace: workspace)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.top, 0, for: .scrollContent)
                    .contentMargins(.horizontal, 6, for: .scrollContent)
                }
            }
            .background {
                SidebarRootDropArea(
                    workspace: workspace,
                    isTargeted: $isSidebarRootDropTargeted
                )
            }
            .overlay {
                SidebarBackgroundContextMenuHost(
                    onCreateFile: { workspace.createNewFile() },
                    onCreateFolder: { workspace.createNewFolder() },
                    onDeleteSelection: {
                        guard let selectedFileURL = workspace.selectedFileURL else { return }
                        workspace.deleteItem(selectedFileURL)
                    }
                )
            }

            Divider().opacity(0.5)

            HStack(spacing: 9) {
                Image("ObsidianLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .accessibilityLabel("Obsidian")
                    .help("Obsidian")

                Text(workspace.vaultURL?.lastPathComponent ?? "Vault")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Menu {
                    Picker("Sort notes by", selection: $workspace.sortOrder) {
                        Text("Name").tag(SortOrder.byName)
                        Text("Date Modified").tag(SortOrder.byDate)
                    }
                    .pickerStyle(.inline)

                    Divider()

                    Button("Collapse All Folders", action: collapseSidebarFolders)
                        .disabled(expandedFolderURLs.isEmpty)
                } label: {
                    MoreMenuLabel()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sidebar options: sort notes or collapse folders")
                .accessibilityLabel("Sidebar options")
                .accessibilityValue(workspace.sortOrder == .byDate ? "Sorted by date modified" : "Sorted by name")

            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(Color(nsColor: Theme.sidebarBackgroundColor).ignoresSafeArea())
        .navigationSplitViewColumnWidth(min: 220, ideal: 232, max: 280)
        .overlay {
            if isSidebarRootDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                    .padding(6)
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        detailContent
    }

    @ViewBuilder
    private var titlebarTabs: some View {
        if !workspaceSession.tabs.isEmpty {
            NoteTabBar(workspace: workspace, session: workspaceSession, isCompact: true)
                // A horizontal ScrollView reports a zero ideal width before its
                // first layout pass. Give the titlebar a real starting width so
                // the restored tab is visible while still allowing it to scroll.
                .frame(minWidth: 120, maxWidth: 520, alignment: .leading)
        }
    }

    private var noteViewToolbar: some View {
        Menu {
            ForEach(OpenViewMode.allCases) { mode in
                Button {
                    viewMode = mode
                } label: {
                    Label(
                        mode.title,
                        systemImage: viewMode == mode ? "checkmark" : mode.systemImage
                    )
                }
            }

            Divider()

            Button {
                workspaceSession.splitPreview.toggle()
            } label: {
                Label(
                    workspaceSession.splitPreview ? "Hide Split Preview" : "Show Split Preview",
                    systemImage: "rectangle.split.2x1"
                )
            }
            .disabled(!workspace.selectedFileIsMarkdown || viewMode != .editor)

            Button {
                isInspectorPresented.toggle()
            } label: {
                Label(
                    isInspectorPresented ? "Hide Note Inspector" : "Show Note Inspector",
                    systemImage: "sidebar.trailing"
                )
            }

            Divider()

            Button {
                workspace.createNewFile()
            } label: {
                Label("New Note", systemImage: "plus")
            }

            Button {
                openDailyNote()
            } label: {
                Label("Open Today's Daily Note", systemImage: "calendar")
            }

            Menu("New from Template") {
                if availableTemplates.isEmpty {
                    Text("No templates in \(workflowConfiguration.templates.folderPath)")
                } else {
                    ForEach(availableTemplates) { template in
                        Button(template.displayName) {
                            selectedTemplate = template
                        }
                    }
                }
            }

            Divider()

            Button {
                showEditorForSearch()
                controller.activateSearch()
            } label: {
                Label("Find in Current Note", systemImage: "magnifyingglass")
            }
            .disabled(!workspace.selectedFileIsMarkdown)

            if let selectedURL = workspace.selectedFileURL {
                Button {
                    workspaceSession.togglePinned(selectedURL)
                } label: {
                    Label(
                        workspaceSession.isPinned(selectedURL) ? "Unpin Note" : "Pin Note",
                        systemImage: workspaceSession.isPinned(selectedURL) ? "pin.slash" : "pin"
                    )
                }
            }

            Button {
                isVaultHealthPresented = true
            } label: {
                Label("Vault Health", systemImage: "checkmark.shield")
            }
        } label: {
            MoreMenuLabel()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More Note Actions")
        .accessibilityLabel("More Note Actions")
    }

    @ViewBuilder
    private var detailContent: some View {
        if workspace.selectedFileIsImage, let selectedURL = workspace.selectedFileURL {
            ImagePreview(url: selectedURL)
        } else if viewMode == .bases {
            basesView
        } else if workspace.selectedFileURL != nil {
            noteWorkspaceView
        } else {
            ContentUnavailableView(
                "No File Selected",
                systemImage: "doc.text",
                description: Text("Select a file from the sidebar or create a new one.")
            )
        }
    }

    private var previewView: some View {
        MarkdownPreview(
            markdown: workspace.text,
            documentURL: workspace.selectedFileURL,
            vaultURL: workspace.vaultURL,
            assetLookupByFilename: workspace.assetLookupSnapshot,
            preferences: preferences,
            onOpenInternalFile: { url in
                workspace.selectFile(url)
            }
        )
        .id(workspace.selectedFileURL)
    }

    @ViewBuilder
    private var noteWorkspaceView: some View {
        if viewMode == .editor && workspaceSession.splitPreview {
            HSplitView {
                editorView
                    .frame(minWidth: 360)
                previewView
                    .frame(minWidth: 360)
            }
        } else {
            switch viewMode {
            case .editor:
                editorView
            case .preview:
                previewView
            case .graph:
                graphView
            case .bases:
                basesView
            }
        }
    }

    private var editorView: some View {
        VStack(spacing: 0) {
            SourceEditorView(
                text: $workspace.text,
                documentURL: workspace.selectedFileURL,
                vaultURL: workspace.vaultURL,
                noteLinkCompletions: noteLinkCompletions,
                controller: controller,
                preferences: preferences,
                savedSelection: workspace.editorSelection(for: workspace.selectedFileURL),
                onSelectionChange: { documentURL, selection in
                    workspace.persistEditorSelection(selection, for: documentURL)
                }
            )

            EditorStatusBar(text: workspace.text)
        }
    }

    private var graphView: some View {
        NoteGraphView(workspace: workspace)
    }

    private var basesView: some View {
        BasesView(workspace: workspace) { url in
            workspace.selectFile(url)
            viewMode = .editor
        }
    }

    private func restoreEditorFocusAfterPaletteDismiss() {
        guard viewMode == .editor, workspace.selectedFileIsMarkdown else { return }
        controller.focusEditor()
    }
}

// MARK: - Helpers

private extension ContentView {
    func refreshNoteLinkCompletions() {
        noteLinkCompletions = workspace.files.map { workspace.title(for: $0) }
    }

    /// Enumerates the templates folder on disk, so this runs only when the
    /// vault, its inventory, or the templates configuration changes.
    func refreshAvailableTemplates() {
        guard let vaultURL = workspace.vaultURL else {
            availableTemplates = []
            return
        }
        availableTemplates = (try? TemplateLibraryService().availableTemplates(
            in: vaultURL,
            configuration: workflowConfiguration.templates
        )) ?? []
    }

    func openDailyNote() {
        guard let vaultURL = workspace.vaultURL else { return }
        do {
            let result = try DailyNoteService().createOrOpen(
                in: vaultURL,
                configuration: workflowConfiguration.dailyNotes,
                templateConfiguration: workflowConfiguration.templates
            )
            workspace.refreshFiles()
            workspace.selectFile(result.fileURL)
        } catch {
            workflowError = error.localizedDescription
        }
    }

    func recordCurrentVault() {
        guard let vaultURL = workspace.vaultURL else { return }
        recentVaults.recordOpened(vaultURL)
    }

    func restoreWorkspaceSession() {
        guard workspaceSession.load(
            for: workspace.vaultURL,
            availableFiles: sessionFileURLs,
            inventoryReady: !workspace.isLoadingSnapshot
        ) else { return }
        workspaceSession.noteSelected(workspace.selectedFileURL)
    }

    func applyPreferredViewMode() {
        viewMode = WorkspaceViewModePolicy.modeAfterSelection(
            current: viewMode,
            preferred: preferences.defaultOpenViewMode,
            isMarkdown: workspace.selectedFileIsMarkdown,
            isImage: workspace.selectedFileIsImage
        )
    }

    func showEditorForSearch() {
        guard workspace.selectedFileIsMarkdown else { return }
        if viewMode != .editor {
            viewMode = .editor
        }
    }

    func collapseSidebarFolders() {
        expandedFolderURLs.removeAll()
    }

    func folderURLs(in nodes: [SidebarNode]) -> Set<URL> {
        Set(nodes.flatMap { node -> [URL] in
            if node.isFolder {
                return [node.url] + Array(folderURLs(in: node.children))
            }
            return []
        })
    }

    /// Every file-kind node in the sidebar, images included. `workspace.files`
    /// lists markdown only, but selecting an image also opens a tab, so the
    /// session must be restored and pruned against the full inventory.
    var sessionFileURLs: Set<URL> {
        fileURLs(in: workspace.sidebarNodes)
    }

    func fileURLs(in nodes: [SidebarNode]) -> Set<URL> {
        Set(nodes.flatMap { node -> [URL] in
            if node.isFolder {
                return Array(fileURLs(in: node.children))
            }
            return [node.url]
        })
    }

    func restoreExpandedFoldersIfNeeded(force: Bool = false) {
        guard let storageKey = sidebarExpansionStorageKey else {
            expandedFolderURLs = []
            restoredVaultKey = nil
            return
        }

        if !preferences.restoresExpandedFolders {
            expandedFolderURLs = []
            restoredVaultKey = storageKey
            return
        }

        if force && preferences.collapsesFoldersOnVaultSwitch {
            expandedFolderURLs = []
            restoredVaultKey = storageKey
            return
        }

        let validFolderURLs = folderURLs(in: workspace.sidebarNodes)

        guard force || restoredVaultKey != storageKey else {
            let filteredURLs = SidebarExpansionPersistence.filteredExpandedFolderURLs(
                expandedFolderURLs,
                validFolderURLs: validFolderURLs
            )
            if filteredURLs != expandedFolderURLs {
                expandedFolderURLs = filteredURLs
                persistExpandedFolders()
            }
            return
        }

        let storedPaths = UserDefaults.standard.stringArray(forKey: storageKey) ?? []

        switch SidebarExpansionPersistence.restoreResult(
            storedPaths: storedPaths,
            validFolderURLs: validFolderURLs,
            isLoadingSnapshot: workspace.isLoadingSnapshot
        ) {
        case .deferred:
            expandedFolderURLs = []
            restoredVaultKey = nil
        case .restored(let restoredURLs):
            expandedFolderURLs = restoredURLs
            restoredVaultKey = storageKey
        }
    }

    func persistExpandedFolders() {
        guard preferences.restoresExpandedFolders, let storageKey = sidebarExpansionStorageKey else { return }
        let paths = expandedFolderURLs
            .map { $0.standardizedFileURL.path }
            .sorted()
        UserDefaults.standard.set(paths, forKey: storageKey)
    }

    var sidebarExpansionStorageKey: String? {
        guard let vaultURL = workspace.vaultURL else { return nil }
        return "sidebarExpandedFolders::" + vaultURL.standardizedFileURL.path
    }
}

enum WorkspaceViewModePolicy {
    static func modeAfterSelection(
        current: OpenViewMode,
        preferred: OpenViewMode,
        isMarkdown: Bool,
        isImage: Bool
    ) -> OpenViewMode {
        if isMarkdown { return preferred }
        if isImage, current == .bases { return .preview }
        return current
    }
}

// MARK: - Save Status Alerts

/// Surfaces save failures and external-modification conflicts. Extracted into a
/// modifier so the alert closures don't bloat `ContentView.body` past the
/// type-checker's complexity budget.
private struct SaveStatusAlerts: ViewModifier {
    @Bindable var workspace: Workspace

    func body(content: Content) -> some View {
        content
            .alert(
                "File Changed on Disk",
                isPresented: Binding(
                    get: { workspace.saveConflict != nil },
                    // Dismiss without a choice must not clear the conflict; only
                    // Keep / Reload resolve it.
                    set: { _ in }
                ),
                presenting: workspace.saveConflict
            ) { _ in
                Button("Keep My Version") { workspace.resolveSaveConflictKeepingMine() }
                Button("Reload From Disk", role: .destructive) { workspace.resolveSaveConflictUsingDisk() }
            } message: { conflict in
                Text("\u{201C}\(conflict.fileName)\u{201D} was modified by another app since you opened it. Keeping your version overwrites those changes; reloading discards your unsaved edits.")
            }
            .alert(
                "Save Failed",
                isPresented: Binding(
                    get: { workspace.saveError != nil },
                    set: { if !$0 { workspace.saveError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { workspace.saveError = nil }
            } message: {
                Text(workspace.saveError ?? "")
            }
    }
}

// MARK: - Titlebar Controls

/// A borderless icon button for the titlebar. Selected segments get a soft
/// accent highlight (matching the selected tab); active toggles only tint the
/// glyph. No boxed bezels.
private struct TitlebarIconButton: View {
    let systemImage: String
    var isSelected = false
    var isActive = false
    var help: String = ""
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 26, height: 22)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(isHovering ? 0.13 : 0.09))
                    } else if isHovering, isEnabled {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        .help(help)
        .accessibilityLabel(help)
    }

    private var iconColor: Color {
        guard isEnabled else { return .secondary.opacity(0.5) }
        if isSelected || isActive { return .primary }
        return isHovering ? .primary : .secondary
    }
}

/// Word, character, and paragraph totals for the editor status bar, gathered
/// in a single pass over the text's Unicode scalars (words and paragraphs)
/// plus a grapheme-cluster count for characters.
struct EditorTextCounts: Equatable, Sendable {
    var words = 0
    var characters = 0
    var paragraphs = 0

    static let zero = EditorTextCounts()

    /// A word is a maximal run of non-whitespace scalars, characters are
    /// user-visible grapheme clusters (matching `String.count`), and a
    /// paragraph is a maximal run of non-blank lines.
    static func compute(for text: String) -> EditorTextCounts {
        var counts = EditorTextCounts()
        var isInsideWord = false
        var lineHasContent = false
        var isInsideParagraph = false

        counts.characters = text.count

        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if lineHasContent {
                    if !isInsideParagraph {
                        counts.paragraphs += 1
                        isInsideParagraph = true
                    }
                } else {
                    isInsideParagraph = false
                }
                lineHasContent = false
                isInsideWord = false
            } else if scalar.properties.isWhitespace {
                isInsideWord = false
            } else {
                lineHasContent = true
                if !isInsideWord {
                    counts.words += 1
                    isInsideWord = true
                }
            }
        }

        if lineHasContent, !isInsideParagraph {
            counts.paragraphs += 1
        }

        return counts
    }
}

private struct EditorStatusBar: View {
    let text: String

    @State private var counts = EditorTextCounts.zero

    var body: some View {
        HStack(spacing: 18) {
            Spacer()
            Text("\(counts.words.formatted()) words")
            Text("\(counts.characters.formatted()) characters")
            Text("\(counts.paragraphs.formatted()) paragraphs")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 20)
        .frame(height: 26)
        .background(Color(nsColor: Theme.editorBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(counts.words) words, \(counts.characters) characters, \(counts.paragraphs) paragraphs"
        )
        .task(id: text) {
            await refreshCounts()
        }
    }

    /// Debounces the recount so rapid typing doesn't rescan the whole note on
    /// every keystroke, then counts off the main actor. A newer edit cancels
    /// the pending task before it assigns.
    @MainActor
    private func refreshCounts() async {
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }

        let text = self.text
        let computed = await Task.detached(priority: .utility) {
            EditorTextCounts.compute(for: text)
        }.value
        guard !Task.isCancelled else { return }

        if counts != computed {
            counts = computed
        }
    }
}

private struct TitlebarSeparator: View {
    var body: some View {
        Divider()
            .frame(height: 14)
            .padding(.horizontal, 3)
            .opacity(0.6)
    }
}

private struct MoreMenuLabel: View {
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isHovering ? Color.primary : Color.secondary)
            .frame(width: 22, height: 22)
            .background {
                if isHovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.1), value: isHovering)
    }
}

// MARK: - Window Toolbar Configurator

private struct WindowToolbarConfigurator: NSViewRepresentable {
    let title: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.configure(windowOf: view, title: title)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SwiftUI re-runs this on every keystroke. Skip the dispatch entirely
        // when the window is already configured and the title is unchanged.
        if let window = nsView.window,
           window.title == title,
           context.coordinator.isConfigured(window) {
            return
        }
        DispatchQueue.main.async {
            context.coordinator.configure(windowOf: nsView, title: title)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var configuredWindow: NSWindow?
        private weak var configuredToolbar: NSToolbar?

        func isConfigured(_ window: NSWindow) -> Bool {
            guard configuredWindow === window, let configuredToolbar else { return false }
            return configuredToolbar === window.toolbar
        }

        func configure(windowOf view: NSView, title: String) {
            guard let window = view.window, let toolbar = window.toolbar else { return }

            if window.title != title {
                window.title = title
            }

            // The remaining settings are static per window (and per toolbar,
            // should SwiftUI ever swap the NSToolbar), so apply them once.
            guard !isConfigured(window) else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = Theme.editorBackgroundColor
            window.toolbarStyle = .unified
            toolbar.displayMode = .iconOnly
            toolbar.sizeMode = .regular
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            configuredWindow = window
            configuredToolbar = toolbar
        }
    }
}

private struct TitlebarAccessoryInstaller<Content: View>: NSViewRepresentable {
    let content: Content
    let layoutAttribute: NSLayoutConstraint.Attribute

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content, layoutAttribute: layoutAttribute)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.update(
                content: content,
                layoutAttribute: layoutAttribute,
                in: view
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.update(
                content: content,
                layoutAttribute: layoutAttribute,
                in: nsView
            )
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private let titlebarHeight: CGFloat = 44
        private let verticalCenteringCorrection: CGFloat = 4
        private let trailingEdgeInset: CGFloat = 8

        private let accessoryController = NSTitlebarAccessoryViewController()
        private let accessoryView = NSView()
        private let hostingView: NSHostingView<Content>
        private weak var attachedWindow: NSWindow?
        private var installedSize = NSSize.zero
        private var installedFittingSize = NSSize.zero

        init(content: Content, layoutAttribute: NSLayoutConstraint.Attribute) {
            hostingView = NSHostingView(rootView: content)
            accessoryView.addSubview(hostingView)
            accessoryController.layoutAttribute = layoutAttribute
            accessoryController.view = accessoryView
        }

        func update(
            content: Content,
            layoutAttribute: NSLayoutConstraint.Attribute,
            in containerView: NSView
        ) {
            hostingView.rootView = content
            accessoryController.layoutAttribute = layoutAttribute

            let fittingSize = hostingView.fittingSize
            let containerWindow = containerView.window
            let isAttachedToWindow = containerWindow != nil && attachedWindow === containerWindow

            // Most updates are keystrokes that change neither the window nor
            // the accessory's measured size. The installed frames are still
            // correct then, so there is nothing to re-lay-out or re-host.
            if isAttachedToWindow,
               abs(fittingSize.width - installedFittingSize.width) <= 0.5,
               abs(fittingSize.height - installedFittingSize.height) <= 0.5 {
                return
            }

            // The accessory controller is anchored to the window's right edge,
            // so the extra width becomes trailing breathing room.
            let targetSize = NSSize(
                width: ceil(max(0, fittingSize.width + trailingEdgeInset)),
                height: titlebarHeight
            )
            let sizeChanged = abs(targetSize.width - installedSize.width) > 0.5
                || abs(targetSize.height - installedSize.height) > 0.5

            hostingView.frame = NSRect(
                x: 0,
                // AppKit seats right-side titlebar accessories slightly below
                // the visual center used by native toolbar items.
                y: max(
                    0,
                    (targetSize.height - fittingSize.height) / 2
                        + verticalCenteringCorrection
                ),
                width: targetSize.width,
                height: fittingSize.height
            )
            accessoryView.setFrameSize(targetSize)
            installedSize = targetSize
            installedFittingSize = fittingSize

            guard let window = containerWindow else { return }

            // An empty accessory has no useful titlebar presence. Waiting until it
            // has a width also avoids AppKit caching a zero-width view.
            guard targetSize.width > 0.5 else {
                detach()
                return
            }

            if isAttachedToWindow {
                guard sizeChanged else { return }

                // AppKit does not reliably relayout an already-installed titlebar
                // accessory when its SwiftUI hosting view changes intrinsic width.
                // Reinstalling is cheap and keeps the accessory positioned correctly.
                detach()
            } else {
                detach()
            }

            window.addTitlebarAccessoryViewController(accessoryController)
            attachedWindow = window
        }

        func detach() {
            guard let attachedWindow,
                  let index = attachedWindow.titlebarAccessoryViewControllers.firstIndex(where: {
                      $0 === accessoryController
                  }) else {
                self.attachedWindow = nil
                return
            }
            attachedWindow.removeTitlebarAccessoryViewController(at: index)
            self.attachedWindow = nil
        }
    }
}

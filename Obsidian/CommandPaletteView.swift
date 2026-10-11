import SwiftUI

struct CommandPaletteView: View {
    let workspace: Workspace
    let onDismiss: () -> Void

    @State private var query = ""
    // A `Sendable` snapshot of the searchable corpus, captured once when the
    // palette opens. Filtering reads only this — never `workspace` — so a
    // keystroke can't trigger a fresh O(files) walk of live model state.
    @State private var entries: [NoteSearchEntry] = []
    // The current result set, recomputed exactly once per (debounced) query
    // rather than on every view render / table row.
    @State private var results: [NoteSearchResult] = []
    @State private var selectedIndex = 0
    @State private var searchGeneration: UInt64 = 0
    @State private var savedSearches = SavedAdvancedSearchStore()
    @State private var isSaveSearchPresented = false
    @State private var savedSearchName = ""
    @FocusState private var isSearchFieldFocused: Bool

    private var primaryResult: NoteSearchResult? {
        if results.indices.contains(selectedIndex) {
            return results[selectedIndex]
        }
        return results.first
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.35))
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    TextField("Search notes, tags, properties, tasks…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($isSearchFieldFocused)
                        .accessibilityLabel("Search notes")
                        .onSubmit {
                            activatePrimaryResult()
                        }

                    Menu {
                        if savedSearches.searches.isEmpty {
                            Text("No saved searches")
                        } else {
                            ForEach(savedSearches.searches) { search in
                                Button(search.name) {
                                    query = search.query
                                }
                            }
                            Divider()
                        }
                        Button("Save Current Search…") {
                            savedSearchName = query
                            isSaveSearchPresented = true
                        }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } label: {
                        Image(systemName: "bookmark")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Saved Searches")
                }
                .padding(20)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            paletteSection("Notes") {
                                if results.isEmpty {
                                    Text("No matching notes")
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                } else {
                                    ForEach(Array(results.enumerated()), id: \.element.id) { index, match in
                                        paletteButton(
                                            title: match.title,
                                            subtitle: match.subtitle,
                                            systemImage: match.url == workspace.selectedFileURL ? "doc.text.fill" : "doc.text",
                                            isSelected: index == selectedIndex
                                        ) {
                                            workspace.selectFile(match.url)
                                            dismiss()
                                        }
                                        .id(match.id)
                                    }
                                }
                            }
                        }
                        .padding(20)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: selectedIndex) { _, newValue in
                        guard results.indices.contains(newValue) else { return }
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(results[newValue].id, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: 640)
            .background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1))
            }
            .shadow(color: .black.opacity(0.2), radius: 24, y: 16)
            .padding(24)
        }
        .task {
            // The palette is an overlay, so its `onAppear` can run before the
            // text field is attached to the window. Defer the focus request by
            // one main-actor turn so it replaces the editor as first responder.
            await Task.yield()
            guard !Task.isCancelled else { return }
            isSearchFieldFocused = true
        }
        .onExitCommand {
            dismiss()
        }
        .onChange(of: query) { _, _ in
            searchGeneration &+= 1
        }
        .onChange(of: workspace.searchIndexRevision) { _, _ in
            // A file presenter, rename, save, import, or delete may update the
            // maintained index while the overlay is open. Refresh the cheap
            // record snapshot and invalidate any in-flight older generation.
            entries = workspace.makeSearchEntries()
            searchGeneration &+= 1
        }
        .alert("Save Search", isPresented: $isSaveSearchPresented) {
            TextField("Name", text: $savedSearchName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                _ = try? savedSearches.save(name: savedSearchName, query: query)
            }
        } message: {
            Text("Save this advanced search for quick access later.")
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .task(id: searchGeneration) {
            let generation = searchGeneration
            if generation == 0 {
                // The palette just opened. Snapshot the corpus here, not in
                // `onAppear`, so this task is the single producer of the
                // opening result list instead of running the search twice.
                entries = workspace.makeSearchEntries()
            } else {
                do {
                    try await Task.sleep(for: .milliseconds(70))
                } catch {
                    return
                }
                guard !Task.isCancelled, generation == searchGeneration else { return }
            }
            let snapshot = entries
            let currentQuery = query
            if generation == 0, currentQuery.isEmpty {
                // An empty query is a plain O(files) map, so produce the
                // opening list inline rather than after a worker hop that
                // would let an empty frame show first.
                results = ObsidianAdvancedSearchEvaluator.search(snapshot, query: currentQuery)
                selectedIndex = 0
                return
            }
            let worker = Task.detached(priority: .userInitiated) {
                ObsidianAdvancedSearchEvaluator.search(snapshot, query: currentQuery)
            }
            let filteredResults = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled,
                  generation == searchGeneration,
                  currentQuery == query else { return }
            results = filteredResults
            selectedIndex = 0
        }
    }

    @ViewBuilder
    private func paletteSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            content()
        }
    }

    private func paletteButton(
        title: String,
        subtitle: String?,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? .white.opacity(0.08) : .white.opacity(0.04))
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let next = selectedIndex + delta
        selectedIndex = min(max(next, 0), results.count - 1)
    }

    private func dismiss() {
        workspace.isCommandPalettePresented = false
        onDismiss()
    }

    private func activatePrimaryResult() {
        guard let match = primaryResult else { return }
        workspace.selectFile(match.url)
        dismiss()
    }
}

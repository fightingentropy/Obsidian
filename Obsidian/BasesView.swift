import SwiftUI

struct BasesView: View {
    enum Layout: String, CaseIterable, Identifiable {
        case table = "Table"
        case list = "List"
        case cards = "Cards"

        var id: String { rawValue }
    }

    let workspace: Workspace
    let onOpenNote: (URL) -> Void
    @State private var layout: Layout = .table
    @State private var query = ""
    @State private var selectedProperty = ""
    @State private var selectedTag = ""
    // Parsed once per index revision, off the main actor, instead of
    // re-parsing every note's metadata several times per render on each
    // keystroke in the filter field. The picker option lists are derived in
    // the same pass because they depend only on the rows.
    @State private var rows: [BaseNoteRow] = []
    // False until the first parse for this view finishes, so an empty `rows`
    // is not mistaken for "no matching notes".
    @State private var hasLoaded = false
    @State private var propertyNames: [String] = []
    @State private var tagNames: [String] = []

    private struct RefreshKey: Equatable {
        let revision: UInt64
        let vaultURL: URL?
    }

    private var refreshKey: RefreshKey {
        RefreshKey(revision: workspace.searchIndexRevision, vaultURL: workspace.vaultURL)
    }

    var body: some View {
        let visibleRows = Self.filteredRows(
            rows,
            query: query,
            property: selectedProperty,
            tag: selectedTag
        )

        VStack(spacing: 0) {
            controls(resultCount: hasLoaded ? visibleRows.count : nil)
            Divider()

            if !hasLoaded {
                ProgressView("Loading notes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleRows.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                switch layout {
                case .table:
                    tableView(visibleRows)
                case .list:
                    listView(visibleRows)
                case .cards:
                    cardsView(visibleRows)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: refreshKey) {
            await reloadRows()
        }
    }

    private func controls(resultCount: Int?) -> some View {
        HStack(spacing: 10) {
            TextField("Filter notes…", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 300)

            Picker("Property", selection: $selectedProperty) {
                Text("All properties").tag("")
                ForEach(propertyNames, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 180)

            Picker("Tag", selection: $selectedTag) {
                Text("All tags").tag("")
                ForEach(tagNames, id: \.self) { Text("#\($0)").tag($0) }
            }
            .frame(maxWidth: 160)

            Spacer()

            Picker("Layout", selection: $layout) {
                ForEach(Layout.allCases) { layout in
                    Text(layout.rawValue).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            Text(resultCount.map { "\($0) notes" } ?? "Loading…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func tableView(_ visibleRows: [BaseNoteRow]) -> some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0) {
                HStack(spacing: 12) {
                    tableHeader("Name", width: 240)
                    tableHeader("Tags", width: 220)
                    tableHeader("Properties", width: 360)
                    tableHeader("Modified", width: 150)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)

                ForEach(visibleRows) { row in
                    Button {
                        onOpenNote(row.url)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).lineLimit(1)
                                Text(row.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 240, alignment: .leading)

                            Text(row.tags.map { "#\($0)" }.joined(separator: "  "))
                                .lineLimit(1)
                                .frame(width: 220, alignment: .leading)

                            Text(propertySummary(row.properties))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 360, alignment: .leading)

                            Text(row.modifiedAt, style: .relative)
                                .foregroundStyle(.secondary)
                                .frame(width: 150, alignment: .leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private func listView(_ visibleRows: [BaseNoteRow]) -> some View {
        List(visibleRows) { row in
            Button {
                onOpenNote(row.url)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(row.title).font(.headline)
                        Spacer()
                        Text(row.modifiedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(row.path).font(.caption).foregroundStyle(.secondary)
                    if !row.tags.isEmpty {
                        Text(row.tags.map { "#\($0)" }.joined(separator: "  "))
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    if !row.properties.isEmpty {
                        Text(propertySummary(row.properties))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
    }

    private func cardsView(_ visibleRows: [BaseNoteRow]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(visibleRows) { row in
                    Button {
                        onOpenNote(row.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(row.title).font(.headline).lineLimit(2)
                            Text(row.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if !row.tags.isEmpty {
                                Text(row.tags.map { "#\($0)" }.joined(separator: "  "))
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                    .lineLimit(2)
                            }
                            Text(propertySummary(row.properties))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                        .padding(14)
                        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
    }

    private func tableHeader(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }

    private func propertySummary(_ properties: [String: ObsidianPropertyValue]) -> String {
        properties.keys.sorted().map { key in
            "\(key): \(displayValue(properties[key]))"
        }.joined(separator: "   ·   ")
    }

    private func displayValue(_ value: ObsidianPropertyValue?) -> String {
        switch value {
        case .string(let value): value
        case .strings(let values): values.joined(separator: ", ")
        case .boolean(let value): value ? "true" : "false"
        case .number(let value): value.formatted()
        case .null: "—"
        case .raw(let value): value.replacingOccurrences(of: "\n", with: " ")
        case nil: ""
        }
    }

    // MARK: - Row loading

    /// Snapshots the note bodies and titles on the main actor, then parses the
    /// metadata off it so a large vault does not stall the filter field.
    private func reloadRows() async {
        let sources = workspace.files.compactMap { file -> BaseNoteSource? in
            guard let body = workspace.noteBody(for: file.url) else { return nil }
            return BaseNoteSource(
                url: file.url,
                fallbackTitle: workspace.title(for: file),
                path: workspace.relativePath(for: file) ?? file.url.lastPathComponent,
                modifiedAt: file.modificationDate,
                body: body
            )
        }
        let table = await Task.detached(priority: .userInitiated) {
            Self.makeTable(from: sources)
        }.value
        guard !Task.isCancelled else { return }
        rows = table.rows
        propertyNames = table.propertyNames
        tagNames = table.tagNames
        hasLoaded = true
    }

    nonisolated private static func makeTable(from sources: [BaseNoteSource]) -> BaseNoteTable {
        let rows = sources.map { source -> BaseNoteRow in
            let metadata = ObsidianMetadataParser.parse(source.body)
            return BaseNoteRow(
                url: source.url,
                title: metadata.title ?? source.fallbackTitle,
                path: source.path,
                tags: metadata.tags,
                properties: metadata.properties,
                modifiedAt: source.modifiedAt
            )
        }
        let propertyNames = Set(rows.flatMap { $0.properties.keys }).sorted()
        let tagNames = Set(rows.flatMap(\.tags))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return BaseNoteTable(rows: rows, propertyNames: propertyNames, tagNames: tagNames)
    }

    nonisolated private static func filteredRows(
        _ rows: [BaseNoteRow],
        query: String,
        property: String,
        tag: String
    ) -> [BaseNoteRow] {
        rows.filter { row in
            let matchesQuery = query.isEmpty
                || row.title.localizedCaseInsensitiveContains(query)
                || row.path.localizedCaseInsensitiveContains(query)
                || row.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
            let matchesProperty = property.isEmpty || row.properties[property] != nil
            let matchesTag = tag.isEmpty || row.tags.contains {
                $0.caseInsensitiveCompare(tag) == .orderedSame
            }
            return matchesQuery && matchesProperty && matchesTag
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }
}

private struct BaseNoteSource: Sendable {
    let url: URL
    let fallbackTitle: String
    let path: String
    let modifiedAt: Date
    let body: String
}

private struct BaseNoteTable: Sendable {
    let rows: [BaseNoteRow]
    let propertyNames: [String]
    let tagNames: [String]
}

private struct BaseNoteRow: Identifiable, Sendable {
    let url: URL
    let title: String
    let path: String
    let tags: [String]
    let properties: [String: ObsidianPropertyValue]
    let modifiedAt: Date
    var id: URL { url }
}

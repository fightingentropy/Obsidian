import SwiftUI

struct NoteTabBar: View {
    let workspace: Workspace
    let session: WorkspaceSession
    var isCompact = false

    var body: some View {
        if !session.tabs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(session.tabs, id: \.self) { url in
                        NoteTab(
                            workspace: workspace,
                            session: session,
                            url: url,
                            isCompact: isCompact
                        )
                    }

                    Button {
                        workspace.createNewFile()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: isCompact ? 24 : 26, height: isCompact ? 30 : 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New Note")
                    .accessibilityLabel("New Note")
                }
                .padding(.horizontal, isCompact ? 4 : 8)
                .padding(.vertical, isCompact ? 2 : 6)
            }
        }
    }
}

private struct NoteTab: View {
    let workspace: Workspace
    let session: WorkspaceSession
    let url: URL
    var isCompact = false

    @State private var isHovering = false
    @State private var isCloseHovering = false

    private var isSelected: Bool {
        workspace.selectedFileURL?.standardizedFileURL == url.standardizedFileURL
    }

    private var isPinned: Bool {
        session.isPinned(url)
    }

    private var title: String {
        if let file = workspace.fileItem(for: url) {
            return workspace.title(for: file)
        }
        return url.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        HStack(spacing: 4) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Button {
                workspace.selectFile(url)
            } label: {
                Text(title)
                    .font(.system(size: isCompact ? 12 : 13, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            Button {
                closeTab()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isCloseHovering ? .primary : .secondary)
                    .frame(width: 14, height: 14)
                    .background {
                        if isCloseHovering {
                            Circle().fill(Color.primary.opacity(0.12))
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isCloseHovering = $0 }
            .opacity(isHovering || isSelected ? 0.85 : 0)
            .accessibilityLabel("Close \(title)")
        }
        .padding(.leading, isCompact ? 10 : 12)
        .padding(.trailing, isCompact ? 7 : 8)
        .frame(height: isCompact ? 30 : 34)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundColor)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.12), value: isCloseHovering)
        .contextMenu {
            Button(isPinned ? "Unpin" : "Pin") {
                session.togglePinned(url)
            }
            Button("Close") {
                closeTab()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.primary.opacity(isHovering ? 0.13 : 0.09)
        }
        return Color.primary.opacity(isHovering ? 0.08 : 0)
    }

    private func closeTab() {
        NoteTabCoordinator.close(url, workspace: workspace, session: session)
    }
}

@MainActor
enum NoteTabCoordinator {
    @discardableResult
    static func close(_ url: URL, workspace: Workspace, session: WorkspaceSession) -> Bool {
        let wasSelected = workspace.selectedFileURL?.standardizedFileURL == url.standardizedFileURL

        // Save before mutating the tab model. If the save fails or conflicts,
        // the visible tab and editor remain exactly as they were.
        if wasSelected, !workspace.saveCurrentFile().allowsTransition {
            return false
        }

        let replacement = session.close(url, selectedURL: workspace.selectedFileURL)
        guard wasSelected else { return true }

        let transitionSucceeded: Bool
        if let replacement {
            transitionSucceeded = workspace.selectFile(replacement)
        } else {
            transitionSucceeded = workspace.clearSelection()
        }

        if !transitionSucceeded {
            session.noteSelected(url)
        }
        return transitionSucceeded
    }
}

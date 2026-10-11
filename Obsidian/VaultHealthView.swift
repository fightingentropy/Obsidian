import SwiftUI

struct VaultHealthView: View {
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var report: VaultHealthReport?
    @State private var scanGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vault Health")
                        .font(.title2.weight(.semibold))
                    Text(workspace.vaultURL?.lastPathComponent ?? "Vault")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rescan") { scanGeneration += 1 }
                    .disabled(report == nil)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            if let report {
                reportContent(report)
            } else {
                ProgressView("Scanning vault…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .task(id: scanGeneration) {
            await rescan()
        }
    }

    @ViewBuilder
    private func reportContent(_ report: VaultHealthReport) -> some View {
        HStack(spacing: 12) {
            metric("Notes", value: report.noteCount, tint: .blue)
            metric("Attachments", value: report.attachmentCount, tint: .green)
            metric("Errors", value: report.errorCount, tint: .red)
            metric("Warnings", value: report.warningCount, tint: .orange)
            metric("Recovery", value: report.recoveryDraftCount, tint: .purple)
        }
        .padding(16)

        Divider()

        if report.issues.isEmpty {
            ContentUnavailableView(
                "Vault Looks Healthy",
                systemImage: "checkmark.shield",
                description: Text("No broken links, missing attachments, duplicate targets, or frontmatter errors were found.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(report.issues) { issue in
                Button {
                    if let url = issue.fileURL {
                        workspace.selectFile(url)
                        dismiss()
                    }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol(for: issue.severity))
                            .foregroundStyle(color(for: issue.severity))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(issue.title).font(.headline)
                            Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if issue.fileURL != nil {
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
    }

    /// Snapshots the note bodies on the main actor, then runs the full vault
    /// scan off it so a large vault does not stall the sheet.
    @MainActor
    private func rescan() async {
        report = nil
        guard let vaultURL = workspace.vaultURL else {
            report = VaultHealthReport(issues: [], noteCount: 0, attachmentCount: 0, recoveryDraftCount: 0)
            return
        }
        let notes = workspace.files.compactMap { file -> VaultHealthNote? in
            guard let body = workspace.noteBody(for: file.url) else { return nil }
            return VaultHealthNote(url: file.url, title: workspace.title(for: file), body: body)
        }
        let scanned = await Task.detached(priority: .userInitiated) {
            VaultHealthScanner.scan(vaultURL: vaultURL, notes: notes)
        }.value
        guard !Task.isCancelled else { return }
        report = scanned
    }

    private func metric(_ title: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.title2.weight(.semibold)).foregroundStyle(tint)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func symbol(for severity: VaultHealthSeverity) -> String {
        switch severity {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(for severity: VaultHealthSeverity) -> Color {
        switch severity {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

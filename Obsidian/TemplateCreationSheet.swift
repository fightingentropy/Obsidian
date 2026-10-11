import SwiftUI

struct TemplateCreationSheet: View {
    let vaultURL: URL
    let template: TemplateDescriptor
    let templateConfiguration: TemplateLibraryConfiguration
    let onCreated: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTitleFieldFocused: Bool
    @State private var title = ""
    @State private var destinationFolder = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Note from Template")
                .font(.title2.weight(.semibold))

            Text(template.displayName)
                .foregroundStyle(.secondary)

            TextField("Note title", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isTitleFieldFocused)
                .onSubmit { submit() }

            TextField("Destination folder (optional)", text: $destinationFolder)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            title = template.displayName
            isTitleFieldFocused = true
        }
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canCreate else { return }
        create()
    }

    private func create() {
        do {
            let url = try TemplateNoteService().create(
                in: vaultURL,
                title: title,
                template: template,
                templateConfiguration: templateConfiguration,
                destinationFolderPath: destinationFolder
            )
            onCreated(url)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

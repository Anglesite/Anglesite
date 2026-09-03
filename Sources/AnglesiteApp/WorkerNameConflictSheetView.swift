import SwiftUI
import AnglesiteCore

/// Sheet shown when `DeployCommand` detects that this site's Worker name already exists on the
/// connected Cloudflare account, and this site has never deployed before (#740) — refusing to
/// silently let `wrangler deploy` take over an unrelated (or stale) Worker. Offers a text field
/// to pick a different name, prefilled with a `<name>-2` suggestion, then retries the deploy.
struct WorkerNameConflictSheetView: View {
    let model: DeployModel
    let takenName: String
    let onCancel: () -> Void

    @State private var newName: String = ""
    @FocusState private var fieldFocused: Bool

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedName.isEmpty && trimmedName != takenName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Worker name already in use")
                    .font(.headline)
                Text("“\(takenName)” already exists on your connected Cloudflare account. Choose a different name to publish this site under.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Worker name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { submit() }

            if let error = model.workerNameConflictError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename & retry") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            newName = "\(takenName)-2"
            fieldFocused = true
        }
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await model.renameWorkerAndRetry(trimmedName) }
    }
}

#Preview {
    WorkerNameConflictSheetView(model: DeployModel(), takenName: "my-site", onCancel: {})
}

import SwiftUI
import AnglesiteCore

struct ShareComposeView: View {
    @Bindable var model: ShareComposeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.urlString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack {
                TextField("Title", text: $model.title)
                if model.isFetchingMetadata {
                    ProgressView().controlSize(.small)
                }
            }

            TextEditor(text: $model.commentary)
                .frame(minHeight: 80)
                .overlay(alignment: .topLeading) {
                    if model.commentary.isEmpty {
                        Text("Add a comment…")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

            if model.sites.isEmpty {
                Text("Open a site in Anglesite at least once to post here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Site", selection: $model.selectedSiteID) {
                    ForEach(model.sites) { site in
                        Text(site.name).tag(Optional(site.id))
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Draft") { Task { await model.save(draft: true) } }
                    .disabled(model.isBusy || model.sites.isEmpty)
                Button("Publish") { Task { await model.save(draft: false) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.sites.isEmpty)
            }
        }
        .padding()
        .frame(width: 420, height: 480)
        .task { await model.onAppear() }
    }
}

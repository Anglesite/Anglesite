import SwiftUI
import AnglesiteCore

/// Progress + result for "Publish to GitHub". The auth sub-flow is a separate sheet
/// (`GitHubTokenPromptView`) presented by `SiteWindow` when the model enters `.needsAuth`.
struct PublishSheet: View {
    @Bindable var model: PublishModel
    let siteName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Publish \u{201C}\(siteName)\u{201D} to GitHub").font(.headline)
            content
            Divider()
            HStack {
                Spacer()
                Button("Done") { model.dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isRunning)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .needsAuth:
            ProgressView().controlSize(.small)
        case .running(let milestone):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(milestone).foregroundStyle(.secondary) }
        case .published(let repo):
            VStack(alignment: .leading, spacing: 8) {
                Label("Published to GitHub", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Link(repo.url.absoluteString, destination: repo.url)
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't publish", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .blocked:
            // Normally never on screen — `PublishModel` swaps this sheet for the blocked sheet
            // the moment the gate refuses (#1959); kept exhaustive for a re-presentation.
            Label("Anglesite's safety check stopped this publish", systemImage: "shield.lefthalf.filled")
                .foregroundStyle(.orange)
        }
    }
}

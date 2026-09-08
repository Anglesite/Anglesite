import SwiftUI

/// First-deploy modal: sign in to Cloudflare via OAuth, then let the parked deploy proceed.
/// Surfaced by `DeployModel` when neither the env var, an OAuth credential, nor a legacy pasted
/// token is usable at the moment the user clicks Deploy. Replaces `CloudflareTokenPromptView`
/// (#1204) — no dashboard link, no paste field; one button drives the whole flow.
struct CloudflareOAuthSignInView: View {
    let model: DeployModel
    let onCancel: () -> Void

    /// Sign-in is waiting on Cloudflare (or the system's sign-in window). The button is disabled
    /// so a second session can't be started on top of the first; Cancel stays enabled — a sign-in
    /// that never reports back (#1951) must always be escapable from the sheet itself.
    private var isSigningIn: Bool {
        if case .checking = model.tokenVerification { return true }
        return false
    }

    /// The credential is verified and the parked deploy is about to be dispatched; both buttons
    /// are disabled for the brief hand-off since there's nothing left to cancel.
    private var isHandingOff: Bool {
        if case .connected = model.tokenVerification { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect to Cloudflare")
                    .font(.headline)
                Text("Publishing needs a one-time sign-in to your Cloudflare account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            status
                .frame(minHeight: 16, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isHandingOff)
                Button("Sign in with Cloudflare") {
                    model.beginSignInWithCloudflare()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSigningIn || isHandingOff)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder
    private var status: some View {
        switch model.tokenVerification {
        case .idle:
            EmptyView()
        case .checking:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Signing in…").foregroundStyle(.secondary)
                }
                if let hint = model.signInHint {
                    Text(hint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.footnote)
        case .connected(let accountName):
            Label(
                accountName.map { "Connected to \($0)" } ?? "Signed in",
                systemImage: "checkmark.circle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    CloudflareOAuthSignInView(model: DeployModel(), onCancel: {})
}

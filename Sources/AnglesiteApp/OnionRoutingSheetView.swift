import SwiftUI
import AnglesiteCore

struct OnionRoutingSheetView: View {
    @Bindable var model: OnionRoutingModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 300, idealHeight: 340)
    }

    // MARK: - Header

    private var header: some View {
        SheetHeader(title: headerTitle, subtitle: headerSubtitle) {
            statusIcon
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.phase {
        case .idle:
            Image(systemName: "network").font(.title3)
        case .loading, .saving:
            ProgressView().controlSize(.small)
        case .configured:
            Image(systemName: "checkmark.network").font(.title3)
                .foregroundStyle(.blue)
        case .error:
            Image(systemName: "exclamationmark.network").font(.title3)
                .foregroundStyle(.red)
        }
    }

    private var headerTitle: String {
        switch model.phase {
        case .idle:
            return "Onion Routing"
        case .loading(let domain):
            return "Reading zone settings for \(domain)…"
        case .configured(let domain, _):
            return domain
        case .saving(let domain):
            return "Updating \(domain)…"
        case .error:
            return "Error"
        }
    }

    private var headerSubtitle: String? {
        switch model.phase {
        case .configured(_, let enabled):
            return enabled
                ? "Onion Routing is enabled"
                : "Onion Routing is disabled"
        default:
            return nil
        }
    }

    // MARK: - Content

    private var content: some View {
        Group {
            switch model.phase {
            case .idle:
                domainInputView
            case .loading(let domain):
                loadingView(domain: domain)
            case .configured(_, let enabled):
                toggleView(enabled: enabled)
            case .saving(let domain):
                savingView(domain: domain)
            case .error(let message):
                errorView(message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var domainInputView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "network").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Onion Routing")
                .font(.headline)
            Text("Cloudflare's Onion Routing lets Tor Browser users reach your site over the Tor network without exiting through a third-party relay. No changes to your site or URLs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            TextField("example.com", text: $model.domainInput)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .onSubmit { model.load() }
            Spacer()
        }
        .padding(16)
    }

    private func toggleView(enabled: Bool) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "network").font(.system(size: 40)).foregroundStyle(.primary)
            Text("Lets Tor Browser users reach your site over the Tor network without exiting through a third-party relay. No changes to your site or URLs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Toggle(isOn: Binding(
                get: { enabled },
                set: { _ in model.toggle() }
            )) {
                Text("Enable Onion Routing")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .disabled(model.isRunning)
            Spacer()
        }
        .padding(16)
    }

    private func loadingView(domain: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Reading \(domain) zone settings from Cloudflare…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
    }

    private func savingView(domain: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Updating \(domain) zone settings in Cloudflare…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.network").font(.system(size: 40)).foregroundStyle(.red)
            Text("Failed to load zone settings")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            switch model.phase {
            case .idle:
                Button("Load") {
                    model.load()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .loading:
                EmptyView()
            case .configured(_, let enabled):
                Button(enabled ? "Disable" : "Enable") {
                    model.toggle()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning)
            case .saving:
                EmptyView()
            case .error:
                Button("Try Again") {
                    model.retryFromError()
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()

            Button("Close") {
                model.dismissSheet()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

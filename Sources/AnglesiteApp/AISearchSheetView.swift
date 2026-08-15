import SwiftUI
import AnglesiteCore

struct AISearchSheetView: View {
    @Bindable var model: AISearchModel
    let sourceDirectory: URL

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 620, minHeight: 380, idealHeight: 520)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle).font(.headline)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.phase {
        case .idle:
            Image(systemName: "text.magnifyingglass").font(.title3)
        case .resolvingZone, .disablingBotFightMode, .provisioning:
            ProgressView().controlSize(.small)
        case .blockedByPolicy:
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.title3)
        case .awaitingBotFightModeDecision:
            Image(systemName: "shield.lefthalf.filled").foregroundStyle(.orange).font(.title3)
        case .awaitingCostConfirmation:
            Image(systemName: "dollarsign.circle").foregroundStyle(.blue).font(.title3)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.title3)
        }
    }

    private var headerTitle: String {
        switch model.phase {
        case .idle: return "Set Up AI Search"
        case .resolvingZone(let domain): return "Checking \(domain)…"
        case .blockedByPolicy: return "Blocked by AI usage policy"
        case .awaitingBotFightModeDecision: return "Bot Fight Mode is blocking AI Search"
        case .disablingBotFightMode: return "Turning off Bot Fight Mode…"
        case .awaitingCostConfirmation(let domain, _): return "Enable AI Search for \(domain)?"
        case .provisioning(let domain): return "Provisioning AI Search for \(domain)…"
        case .succeeded: return "AI Search instance created"
        case .failed: return "AI Search setup failed"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            Form {
                TextField("Domain", text: $model.domainInput, prompt: Text("example.com"))
                    .textContentType(.URL)
            }
            .padding()
        case .resolvingZone, .disablingBotFightMode, .provisioning:
            ProgressView()
        case .blockedByPolicy(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Text(reason)
                Text("Open Content Licensing settings to review this site's AI usage policy.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding()
        case .awaitingBotFightModeDecision(let domain, _):
            VStack(alignment: .leading, spacing: 8) {
                Text("Bot Fight Mode is protecting \(domain) from automated traffic — but it also blocks Cloudflare's AI Search crawler, so AI Search can't read your site while it's on. There's no way to make an exception for just this crawler.")
                Text("Turning it off lets AI Search index your site, but reduces protection against unwanted bots. You can turn it back on any time in the Cloudflare dashboard.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding()
        case .awaitingCostConfirmation:
            VStack(alignment: .leading, spacing: 8) {
                Text("AI Search billing scales with reader traffic, unlike other Cloudflare features in this app.")
                Text("Free during open beta: 100 instances, 20,000 queries/month, 500 crawled pages/day. Reader queries run on Cloudflare's AI models — beyond free limits, usage is billed by Cloudflare.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Your site's existing search (Pagefind) keeps working for free either way — AI Search's conversational answers are an opt-in upgrade above it, not a replacement.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding()
        case .succeeded(let result):
            VStack(alignment: .leading, spacing: 8) {
                Text("Instance \"\(result.instance.name)\" is provisioned.")
                if model.keptBotFightModeOn {
                    Text("Bot Fight Mode is still on, so the AI Search crawler may be blocked. If indexing fails, turn Bot Fight Mode off in the Cloudflare dashboard and re-run indexing.")
                        .font(.callout).foregroundStyle(.orange)
                }
                Text("NLWeb enablement is still manual — finish setup in the Cloudflare dashboard:")
                Link("Open AI Search instance settings", destination: result.dashboardURL)
                Text("In the dashboard: open this instance's Settings, locate \"NLWeb Worker\", and enable it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding()
        case .failed(let reason):
            Text(reason).foregroundStyle(.secondary).padding()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            switch model.phase {
            case .idle:
                Button("Cancel") { model.dismissSheet() }
                Button("Continue") { model.checkPolicyAndResolveZone(sourceDirectory: sourceDirectory) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .awaitingBotFightModeDecision:
                Button("Cancel") { model.dismissSheet() }
                Button("Keep It On") { model.keepBotFightMode() }
                Button("Turn Off Bot Fight Mode") { model.disableBotFightMode() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .awaitingCostConfirmation:
                Button("Cancel") { model.dismissSheet() }
                Button("Enable AI Search") { model.confirmCost() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .succeeded, .blockedByPolicy, .failed:
                Button("Done") { model.dismissSheet() }
                    .keyboardShortcut(.defaultAction)
            case .resolvingZone, .disablingBotFightMode, .provisioning:
                Button("Cancel") { model.dismissSheet() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

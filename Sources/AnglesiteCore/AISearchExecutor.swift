import Foundation

/// Orchestrates provisioning a Cloudflare AI Search instance for a site: a policy preflight
/// (pure, callable before any network I/O), then provisioning. Deliberately standalone rather
/// than routed through `HardenPlanner`/`HardenExecutor` — see this plan's Global Constraints.
///
/// There is deliberately no WAF skip rule here for Bot Fight Mode. An earlier version of this
/// branch shipped one; live verification against the real Cloudflare API (2026-08-15, real
/// token) found it can never work:
/// - `action_parameters.products: ["botFight"]` is rejected by the API on every variant tried
///   (error 20119 — "skip action parameter product 'botFight' is invalid").
/// - The alternative match field, `cf.bot_management.detection_ids`, isn't entitled on free
///   zones ("a Bot Management plan is required").
/// - Even a rule that validated would do nothing: per Cloudflare's own docs
///   (bots/get-started/bot-fight-mode), Bot Fight Mode evaluates in a separate pipeline where
///   WAF custom-rule Skip/Bypass/Allow actions have no effect on it.
///
/// The only real remediation when Bot Fight Mode is blocking the AI Search crawler is turning it
/// off — an explicit owner trade-off, surfaced by `AISearchModel`'s
/// `.awaitingBotFightModeDecision` phase via `disableBotFightMode(zoneID:apiToken:)` below. Do
/// not re-add a WAF-rule workaround here without new, contrary live-verified evidence.
public struct AISearchExecutor: Sendable {
    public struct ProvisionedResult: Sendable, Equatable {
        public let instance: AISearchInstance
        public let dashboardURL: URL
    }

    private let reader: any CloudflareReading
    private let writer: any CloudflareWriting
    private let provisioner: any AISearchProvisioning

    public init(reader: any CloudflareReading, writer: any CloudflareWriting, provisioner: any AISearchProvisioning) {
        self.reader = reader
        self.writer = writer
        self.provisioner = provisioner
    }

    /// `nil` when the site's AI usage policy doesn't object; a user-facing explanation otherwise.
    public static func policyBlockReason(for policy: LicensingPolicy) -> String? {
        guard policy.usage.aiInput == .no else { return nil }
        return "This site's AI usage policy currently says no to AI input. Update it in Content Licensing settings before enabling AI Search."
    }

    public func provision(zoneID: String, domain: String, apiToken: String) async throws -> ProvisionedResult {
        let namespace = Self.namespaceID(for: domain)
        let instance = try await provisioner.createAISearchInstance(domain: domain, instanceID: namespace, apiToken: apiToken)

        // Product-root deep link, verified against Cloudflare's docs (2026-08-15): every doc page
        // links "Go to AI Search" as `?to=/:account/ai/ai-search` — note the `/ai/` segment — and
        // none deep-links into an instance's Settings (they all say select the instance, then
        // Settings). The earlier `/:account/ai-search/{namespace}/settings` guess had no `/ai/`
        // and an unverified instance sub-path; the success UI's manual steps cover the rest.
        let dashboardURL = URL(string: "https://dash.cloudflare.com/?to=/:account/ai/ai-search")!
        return ProvisionedResult(instance: instance, dashboardURL: dashboardURL)
    }

    /// Turns Bot Fight Mode off for the zone — the only real remediation when it's blocking the
    /// AI Search crawler (see the type doc comment above). Called after the site owner
    /// explicitly opts in via `AISearchModel`'s `.awaitingBotFightModeDecision` phase.
    public func disableBotFightMode(zoneID: String, apiToken: String) async throws {
        try await writer.setBotFightMode(zoneID: zoneID, enabled: false, apiToken: apiToken)
    }

    static func namespaceID(for domain: String) -> String {
        domain.lowercased().replacingOccurrences(of: ".", with: "-")
    }
}

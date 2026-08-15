import Foundation

/// Orchestrates provisioning a Cloudflare AI Search instance for a site: a policy preflight
/// (pure, callable before any network I/O), then provisioning plus a conditional WAF skip rule.
/// Deliberately standalone rather than routed through `HardenPlanner`/`HardenExecutor` — see
/// this plan's Global Constraints.
public struct AISearchExecutor: Sendable {
    public struct ProvisionedResult: Sendable, Equatable {
        public let instance: AISearchInstance
        public let wafSkipRuleAdded: Bool
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

        let state = try await reader.zoneState(zoneID: zoneID, domain: domain, apiToken: apiToken)
        var wafAdded = false
        if state.botFightMode {
            try await writer.createWAFCustomRule(
                zoneID: zoneID,
                rule: WAFRulePayload(
                    description: "Anglesite: allow Cloudflare AI Search crawler",
                    // Matches by verified-bot detection ID, not user-agent string — corrected
                    // 2026-08-06 against Cloudflare's own dashboard skip-rule guidance
                    // (developers.cloudflare.com/ai-search/configuration/data-source/website/),
                    // which identifies this crawler as Bot Detection ID 122933950. `any(...)`
                    // rather than a fixed `[0]` index: `detection_ids` can hold more than one
                    // entry, and a positional index would silently stop matching on any request
                    // where this crawler's ID isn't first — a false negative the happy path
                    // wouldn't catch in testing. Verify this exact field/operator syntax
                    // (including the any()-vs-index question) against a live dashboard-created
                    // rule (or a GET of one) before merging — inferred from docs prose, not a
                    // confirmed live response.
                    expression: "(any(cf.bot_management.detection_ids[*] eq 122933950))",
                    action: "skip",
                    actionParameters: .init(products: ["botFight"])),
                apiToken: apiToken)
            wafAdded = true
        }

        // Best-effort deep link — Cloudflare's dashboard URL scheme for an AI Search instance's
        // Settings page; re-verify at implementation time since this is a preview product.
        let dashboardURL = URL(string: "https://dash.cloudflare.com/?to=/:account/ai-search/\(namespace)/settings")!
        return ProvisionedResult(instance: instance, wafSkipRuleAdded: wafAdded, dashboardURL: dashboardURL)
    }

    static func namespaceID(for domain: String) -> String {
        domain.lowercased().replacingOccurrences(of: ".", with: "-")
    }
}

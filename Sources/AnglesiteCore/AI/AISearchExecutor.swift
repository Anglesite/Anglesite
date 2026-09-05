import Foundation

/// Orchestrates provisioning a Cloudflare AI Search instance for a site: a policy preflight
/// (pure, callable before any network I/O), then provisioning plus a conditional WAF skip rule.
/// Deliberately standalone rather than routed through `HardenPlanner`/`HardenExecutor` — see
/// this plan's Global Constraints.
public struct AISearchExecutor: Sendable {
    public struct ProvisionedResult: Sendable, Equatable {
        public let instance: AISearchInstance
        public let wafSkipRuleAdded: Bool
        /// User-facing warning when the WAF skip-rule step failed after the AI Search instance
        /// was already created. `nil` when the rule was added cleanly (or wasn't needed because
        /// Bot Fight Mode is off) — never set alongside `wafSkipRuleAdded == true`.
        public let wafSkipRuleWarning: String?
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
        // Fetch-or-create semantics (#1478): `namespace` is derived deterministically from
        // `domain`, so an "already exists" error usually means an earlier run of this wizard
        // (complete or interrupted before this point) already created exactly the instance we're
        // asking for — re-running is the natural response to any failed/interrupted attempt, and
        // it should succeed rather than fail on a duplicate-id error. But `namespaceID(for:)`'s
        // dot-to-dash normalization isn't injective ("a.b.com" and "a-b.com" collide), so an
        // "already exists" doesn't *guarantee* the existing instance is this domain's — fetch it
        // and compare `source` before trusting that (review finding on #1504). A mismatch means a
        // genuine id collision with a different site, which must fail loudly rather than silently
        // "succeed" against someone else's instance. Any other creation error propagates as-is:
        // nothing has been provisioned yet, so there's no partial state to degrade gracefully from.
        let instance: AISearchInstance
        do {
            instance = try await provisioner.createAISearchInstance(domain: domain, instanceID: namespace, apiToken: apiToken)
        } catch AISearchProvisionError.instanceAlreadyExists {
            let existingSource = try await provisioner.aiSearchInstanceSource(instanceID: namespace, apiToken: apiToken)
            guard existingSource.lowercased() == domain.lowercased() else {
                throw AISearchProvisionError.instanceIDCollision
            }
            instance = AISearchInstance(id: namespace, name: namespace)
        }

        // From here on, the AI Search instance already exists. HardenPlanner's curated WAF rule
        // set is exactly 5 rules — the free-plan quota — so a hardened free-plan zone predictably
        // fails this POST with a quota error. Throwing here would strand the just-created
        // instance (crawler still blocked by Bot Fight Mode) with no way for the caller to know
        // it half-succeeded, so zone-state read and WAF-rule write failures degrade to a warning
        // on an otherwise-successful result instead of throwing.
        var wafAdded = false
        var wafWarning: String?
        do {
            let state = try await reader.zoneState(zoneID: zoneID, domain: domain, apiToken: apiToken)
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
                        //
                        // `createWAFCustomRule` always appends this rule to the end of the
                        // ruleset, but Cloudflare's dashboard guidance orders the skip rule
                        // *first*. Harmless today — none of HardenPlanner's curated rules match
                        // crawler traffic — but if a future curated rule ever does, an earlier
                        // block/challenge rule would fire before this skip rule is reached,
                        // silently defeating it.
                        expression: "(any(cf.bot_management.detection_ids[*] eq 122933950))",
                        action: "skip",
                        actionParameters: .init(products: ["botFight"])),
                    apiToken: apiToken)
                wafAdded = true
            }
        } catch {
            wafWarning = "Couldn't add the WAF skip rule — Bot Fight Mode may block the AI Search crawler. Add a skip rule for it in the Cloudflare dashboard."
        }

        // Best-effort deep link — Cloudflare's dashboard URL scheme for an AI Search instance's
        // Settings page; re-verify at implementation time since this is a preview product.
        let dashboardURL = URL(string: "https://dash.cloudflare.com/?to=/:account/ai-search/\(namespace)/settings")!
        return ProvisionedResult(instance: instance, wafSkipRuleAdded: wafAdded, wafSkipRuleWarning: wafWarning, dashboardURL: dashboardURL)
    }

    static func namespaceID(for domain: String) -> String {
        domain.lowercased().replacingOccurrences(of: ".", with: "-")
    }
}

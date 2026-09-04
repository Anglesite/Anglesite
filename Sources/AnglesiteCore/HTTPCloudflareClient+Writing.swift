import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Body for DELETE requests, which Cloudflare's API doesn't require but tolerates.
private struct CFEmptyBody: Encodable, Sendable {}

private struct CFWorkerDomain: Decodable, Sendable { let hostname: String; let service: String }

// MARK: - CloudflareWriting conformance

extension HTTPCloudflareClient: CloudflareWriting {
    /// `PUT /zones/{id}/dnssec` with `status: active`. Enable-only — the app hardens; it never
    /// offers a "turn DNSSEC back off" path.
    public func enableDNSSEC(zoneID: String, apiToken: String) async throws {
        try await core.mutate(method: "PUT", "/zones/\(zoneID)/dnssec",
                         body: ["status": "active"], apiToken: apiToken)
    }

    /// `PUT /zones/{id}/settings/always_use_https`, mapping `enabled` to the API's `"on"/"off"`
    /// string values.
    public func setAlwaysUseHTTPS(zoneID: String, enabled: Bool, apiToken: String) async throws {
        try await core.mutate(method: "PUT", "/zones/\(zoneID)/settings/always_use_https",
                         body: ["value": enabled ? "on" : "off"], apiToken: apiToken)
    }

    /// `PUT /zones/{id}/settings/security_header` with `enabled: true` fixed — callers choose
    /// the HSTS parameters, not whether HSTS is on; disabling it is deliberately not offered.
    public func setHSTS(zoneID: String, maxAge: Int, includeSubdomains: Bool, preload: Bool,
                         apiToken: String) async throws {
        struct HSTSBody: Encodable, Sendable {
            struct Value: Encodable, Sendable {
                struct STS: Encodable, Sendable {
                    let enabled: Bool
                    let max_age: Int
                    let include_subdomains: Bool
                    let preload: Bool
                }
                let strict_transport_security: STS
            }
            let value: Value
        }
        let body = HSTSBody(value: .init(strict_transport_security: .init(
            enabled: true, max_age: maxAge, include_subdomains: includeSubdomains, preload: preload)))
        try await core.mutate(method: "PUT", "/zones/\(zoneID)/settings/security_header",
                         body: body, apiToken: apiToken)
    }

    /// `POST /zones/{id}/dns_records` — ``DNSRecordPayload`` encodes directly as the request
    /// body, so what the seam accepts and what goes over the wire can't drift apart.
    public func addDNSRecord(zoneID: String, record: DNSRecordPayload, apiToken: String) async throws {
        try await core.mutate(method: "POST", "/zones/\(zoneID)/dns_records",
                         body: record, apiToken: apiToken)
    }

    /// `DELETE /zones/{id}/dns_records/{recordID}` (with an empty JSON body Cloudflare
    /// tolerates, so the shared `mutate` helper needs no body-less variant).
    public func deleteDNSRecord(zoneID: String, recordID: String, apiToken: String) async throws {
        try await core.mutate(method: "DELETE", "/zones/\(zoneID)/dns_records/\(recordID)",
                         body: CFEmptyBody(), apiToken: apiToken)
    }

    /// `PATCH /zones/{id}/bot_management` toggling `fight_mode`.
    public func setBotFightMode(zoneID: String, enabled: Bool, apiToken: String) async throws {
        try await core.mutate(method: "PATCH", "/zones/\(zoneID)/bot_management",
                         body: ["fight_mode": enabled], apiToken: apiToken)
    }

    /// Appends `rule` to the zone's `http_request_firewall_custom` ruleset, creating that
    /// ruleset first when the zone has never had one — a fresh zone has no custom-rules
    /// ruleset, and a bare rule-POST would 404 there.
    public func createWAFCustomRule(zoneID: String, rule: WAFRulePayload, apiToken: String) async throws {
        let rulesets = try await core.get("/zones/\(zoneID)/rulesets", apiToken: apiToken, as: [CFRuleset].self)
        let existing = rulesets.first(where: { $0.phase == "http_request_firewall_custom" })

        if let rs = existing {
            try await core.mutate(method: "POST", "/zones/\(zoneID)/rulesets/\(rs.id)/rules",
                             body: rule, apiToken: apiToken)
        } else {
            struct NewRuleset: Encodable, Sendable {
                let name: String
                let kind: String
                let phase: String
                let rules: [WAFRulePayload]
            }
            try await core.mutate(method: "POST", "/zones/\(zoneID)/rulesets",
                             body: NewRuleset(name: "Anglesite security rules",
                                              kind: "zone", phase: "http_request_firewall_custom",
                                              rules: [rule]),
                             apiToken: apiToken)
        }
    }

    /// `PATCH /zones/{id}/settings/speed_brain`, mapping `enabled` to `"on"/"off"`.
    public func setSpeedBrain(zoneID: String, enabled: Bool, apiToken: String) async throws {
        try await core.mutate(method: "PATCH", "/zones/\(zoneID)/settings/speed_brain",
                         body: ["value": enabled ? "on" : "off"], apiToken: apiToken)
    }

    /// `PATCH /zones/{id}/settings/ech` (Encrypted Client Hello), mapping `enabled` to
    /// `"on"/"off"`.
    public func setECH(zoneID: String, enabled: Bool, apiToken: String) async throws {
        try await core.mutate(method: "PATCH", "/zones/\(zoneID)/settings/ech",
                         body: ["value": enabled ? "on" : "off"], apiToken: apiToken)
    }

    /// `PUT /zones/{id}/page_shield` — this endpoint takes a real boolean `enabled`, unlike the
    /// `"on"/"off"`-string settings endpoints.
    public func setPageShield(zoneID: String, enabled: Bool, apiToken: String) async throws {
        try await core.mutate(method: "PUT", "/zones/\(zoneID)/page_shield",
                         body: ["enabled": enabled], apiToken: apiToken)
    }

    /// `PATCH /zones/{id}/settings/opportunistic_onion` (Onion Routing for Tor visitors),
    /// mapping `enabled` to `"on"/"off"`.
    public func enableOnionRouting(zoneID: String, enabled: Bool, apiToken: String) async throws {
        try await core.mutate(method: "PATCH", "/zones/\(zoneID)/settings/opportunistic_onion",
                         body: ["value": enabled ? "on" : "off"], apiToken: apiToken)
    }

    /// Implements the attach as read-then-write: resolve the zone (short-circuiting to
    /// ``CustomDomainAttachResult/zoneNotFound`` for the common "nameservers not delegated yet"
    /// case before any account round-trip), list existing attachments for the hostname, and only
    /// `PUT /accounts/{id}/workers/domains` when nothing owns it — an attachment held by a
    /// *different* script comes back as ``CustomDomainAttachResult/conflict(ownedBy:)`` instead
    /// of being silently repointed (#1077).
    public func attachWorkersCustomDomain(
        hostname: String, workerScriptName: String, apiToken: String
    ) async throws -> CustomDomainAttachResult {
        // Zone lookup first (cheap, account-agnostic) so the common "not delegated to Cloudflare
        // yet" case short-circuits without an extra account-id round trip.
        guard let zoneID = try await resolveZoneID(domain: hostname, apiToken: apiToken) else {
            return .zoneNotFound
        }
        let accountID = try await core.resolveAccountID(apiToken: apiToken)
        let escapedHostname = hostname.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hostname
        let existing = try await core.get(
            "/accounts/\(accountID)/workers/domains?hostname=\(escapedHostname)",
            apiToken: apiToken, as: [CFWorkerDomain].self
        )
        if let match = existing.first(where: { $0.hostname.lowercased() == hostname.lowercased() }) {
            return match.service == workerScriptName ? .alreadyAttached : .conflict(ownedBy: match.service)
        }
        struct AttachBody: Encodable, Sendable {
            let zone_id: String
            let hostname: String
            let service: String
            let environment: String
        }
        try await core.mutate(
            method: "PUT", "/accounts/\(accountID)/workers/domains",
            body: AttachBody(zone_id: zoneID, hostname: hostname, service: workerScriptName, environment: "production"),
            apiToken: apiToken
        )
        return .attached
    }

    /// `PATCH /zones/{id}/settings/content_converter`, mapping `enabled` to `"on"/"off"` — same
    /// shape as `setSpeedBrain`/`setECH`. See ``CloudflareWriting/setMarkdownForAgents(hostname:enabled:apiToken:)``.
    public func setMarkdownForAgents(hostname: String, enabled: Bool, apiToken: String) async throws -> Bool {
        guard let zoneID = try await resolveZoneID(domain: hostname, apiToken: apiToken) else { return false }
        try await core.mutate(method: "PATCH", "/zones/\(zoneID)/settings/content_converter",
                         body: ["value": enabled ? "on" : "off"], apiToken: apiToken)
        return true
    }

    /// Adds a zstd-first (zstd → brotli → gzip) `compress_response` rule to the zone's
    /// `http_response_compression` ruleset, creating the ruleset when absent. Idempotent by
    /// inspection: an existing zstd rule means return without writing, so repeated hardening
    /// runs don't stack duplicate rules.
    public func enableZstandardCompression(zoneID: String, apiToken: String) async throws {
        struct CompressionRule: Encodable, Sendable {
            struct Params: Encodable, Sendable {
                struct Algorithm: Encodable, Sendable { let name: String }
                let algorithms: [Algorithm]
            }
            let description: String
            let expression: String
            let action: String
            let action_parameters: Params
        }
        let rule = CompressionRule(
            description: "Anglesite: prefer Zstandard compression",
            expression: "true",
            action: "compress_response",
            action_parameters: .init(algorithms: [
                .init(name: "zstd"), .init(name: "brotli"), .init(name: "gzip"),
            ]))

        let rulesets = try await core.get("/zones/\(zoneID)/rulesets", apiToken: apiToken, as: [CFRuleset].self)
        if let existing = rulesets.first(where: { $0.phase == "http_response_compression" }) {
            let full = try await core.get("/zones/\(zoneID)/rulesets/\(existing.id)", apiToken: apiToken, as: CFRuleset.self)
            let alreadyHasZstd = (full.rules ?? []).contains { rule in
                rule.action == "compress_response"
                    && (rule.action_parameters?.algorithms ?? []).contains { $0.name == "zstd" }
            }
            if alreadyHasZstd { return }
            try await core.mutate(method: "POST", "/zones/\(zoneID)/rulesets/\(existing.id)/rules",
                             body: rule, apiToken: apiToken)
        } else {
            struct NewRuleset: Encodable, Sendable {
                let name: String
                let kind: String
                let phase: String
                let rules: [CompressionRule]
            }
            try await core.mutate(method: "POST", "/zones/\(zoneID)/rulesets",
                             body: NewRuleset(name: "Anglesite compression rules",
                                              kind: "zone", phase: "http_response_compression",
                                              rules: [rule]),
                             apiToken: apiToken)
        }
    }
}

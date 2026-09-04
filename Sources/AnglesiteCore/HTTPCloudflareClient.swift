import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct CFZone: Decodable, Sendable {
    let id: String
    let name: String
    let status: String
}

private struct CFDNSSEC: Decodable, Sendable { let status: String }
private struct CFStringSetting: Decodable, Sendable { let value: String }
private struct CFSecurityHeader: Decodable, Sendable {
    struct Value: Decodable, Sendable {
        struct STS: Decodable, Sendable {
            let enabled: Bool
            let max_age: Int?
            let include_subdomains: Bool?
            let preload: Bool?
        }
        let strict_transport_security: STS
    }
    let value: Value
}
private struct CFDNSRecord: Decodable, Sendable {
    let type: String
    let name: String
    let content: String
}
private struct CFFullDNSRecord: Decodable, Sendable {
    let id: String
    let type: String
    let name: String
    let content: String
    let ttl: Int
    let proxied: Bool?
    let comment: String?
}
private struct CFWorkerScript: Decodable, Sendable { let id: String }
/// Used by `CloudflareWriting`'s `attachWorkersCustomDomain` (in
/// `HTTPCloudflareClient+Writing.swift`) as well as this file, so — like `CFRuleset`/
/// `CFRulesetRule` above — it stays `internal` (no access modifier) rather than `private`.
struct CFWorkerDomain: Decodable, Sendable { let hostname: String; let service: String }

private struct CFBotManagement: Decodable, Sendable {
    let fight_mode: Bool?
    let enable_js: Bool?
}
/// Shared with the `CloudflareWriting` conformance's `createWAFCustomRule`/`enableZstandardCompression`
/// (in `HTTPCloudflareClient+Writing.swift`), so these two types stay `internal` (no access modifier)
/// rather than `private` — a separate translation unit needs to see them.
struct CFRuleset: Decodable, Sendable {
    let id: String
    let phase: String?
    let rules: [CFRulesetRule]?
}
struct CFRulesetRule: Decodable, Sendable {
    let description: String?
    let expression: String
    let action: String
    let action_parameters: Params?
    struct Params: Decodable, Sendable {
        let algorithms: [Algorithm]?
        struct Algorithm: Decodable, Sendable { let name: String? }
    }
}
private struct CFPageShield: Decodable, Sendable { let enabled: Bool? }
private struct CFPageShieldScript: Decodable, Sendable {
    let url: String?
    let host: String?
}

/// Cloudflare v4 API client. The base conformance here is the read side
/// (``CloudflareReading``, all GETs); the write side (``CloudflareWriting`` — the hardening
/// PUT/POST/PATCH/DELETE calls) is conformed in an extension below.
public struct HTTPCloudflareClient: CloudflareReading {
    static let base = "https://api.cloudflare.com/client/v4"
    let core: CloudflareHTTPCore

    /// The transport parameter exists for tests (fake responses, no network); production uses
    /// ``defaultTransport``.
    public init(transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport) {
        self.core = CloudflareHTTPCore(baseURL: Self.base, transport: transport)
    }

    /// Production transport: a plain shared-`URLSession` request.
    public static let defaultTransport: CloudflareTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudflareError.malformedResponse }
        return (data, http)
    }

    /// Fetch every DNS record across pages (Cloudflare caps `per_page` at 100, so a
    /// single page silently truncates zones with more records).
    private func allDNSRecords(zoneID: String, apiToken: String) async throws -> [CFDNSRecord] {
        try await core.paginated("/zones/\(zoneID)/dns_records?per_page=100", apiToken: apiToken, as: CFDNSRecord.self)
    }

    /// Looks the zone up via `GET /zones?name=…&status=active`, then re-checks the name
    /// case-insensitively client-side — the API's `name=` filter is a match request, not a
    /// guarantee, and a wrong zone id here would point every later read/write at someone
    /// else's zone.
    public func resolveZoneID(domain: String, apiToken: String) async throws -> String? {
        let escaped = domain.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? domain
        let zones = try await core.get("/zones?name=\(escaped)&status=active", apiToken: apiToken, as: [CFZone].self)
        return zones.first(where: { $0.name.lowercased() == domain.lowercased() })?.id
    }

    /// Assembles the zone's security posture from a dozen endpoints. The five core reads
    /// (DNSSEC, SSL mode, Always-Use-HTTPS, security header, DNS records) fan out concurrently
    /// and *must* all succeed; the extended settings (Bot Fight Mode, WAF rules, Speed Brain,
    /// ECH, zstd, Page Shield, Onion Routing) individually degrade to their "off"/absent value
    /// on error instead — many tokens simply can't see those endpoints, and one 403 there
    /// shouldn't sink the whole audit.
    public func zoneState(zoneID: String, domain: String, apiToken: String) async throws -> CloudflareZoneState {
        // Independent reads — fan out concurrently rather than paying 5× round-trip latency.
        async let dnssecCall = core.get("/zones/\(zoneID)/dnssec", apiToken: apiToken, as: CFDNSSEC.self)
        async let sslCall = core.get("/zones/\(zoneID)/settings/ssl", apiToken: apiToken, as: CFStringSetting.self)
        async let httpsCall = core.get("/zones/\(zoneID)/settings/always_use_https", apiToken: apiToken, as: CFStringSetting.self)
        async let headerCall = core.get("/zones/\(zoneID)/settings/security_header", apiToken: apiToken, as: CFSecurityHeader.self)
        async let recordsCall = allDNSRecords(zoneID: zoneID, apiToken: apiToken)

        let dnssec = try await dnssecCall
        let ssl = try await sslCall
        let https = try await httpsCall
        let header = try await headerCall
        let records = try await recordsCall
        let apex = domain.lowercased()

        let botFight: Bool
        do {
            let bot = try await core.get("/zones/\(zoneID)/settings/bot_management", apiToken: apiToken, as: CFBotManagement.self)
            botFight = bot.fight_mode ?? false
        } catch {
            botFight = false
        }

        let wafRules = (try? await fetchWAFCustomRules(zoneID: zoneID, apiToken: apiToken)) ?? []

        let speedBrain = await settingIsOn("/zones/\(zoneID)/settings/speed_brain", apiToken: apiToken)
        let ech = await settingIsOn("/zones/\(zoneID)/settings/ech", apiToken: apiToken)
        let zstd = await zstdEnabled(zoneID: zoneID, apiToken: apiToken)
        let pageShield = await pageShieldState(zoneID: zoneID, apiToken: apiToken)
        let onionRouting = await settingIsOn("/zones/\(zoneID)/settings/opportunistic_onion", apiToken: apiToken)

        let sts = header.value.strict_transport_security
        let hsts: CloudflareZoneState.HSTS? = sts.enabled
            ? .init(maxAge: sts.max_age ?? 0, includeSubdomains: sts.include_subdomains ?? false, preload: sts.preload ?? false)
            : nil

        // Scoped to the zone apex — a record published on an unrelated subdomain must not
        // count toward the apex domain's CAA/MX/SPF/DMARC posture (that direction of error
        // produces a false "all clear" in a security audit).
        func contents(ofType t: String) -> [String] {
            records.filter { $0.type.uppercased() == t && $0.name.lowercased() == apex }.map(\.content)
        }
        let txt = records.filter { $0.type.uppercased() == "TXT" && $0.name.lowercased() == apex }
        let spf = txt.filter { $0.content.lowercased().hasPrefix("v=spf1") }.map(\.content)
        let dmarcName = "_dmarc.\(apex)"
        let dmarc = records
            .filter { $0.type.uppercased() == "TXT" && $0.name.lowercased() == dmarcName && $0.content.lowercased().hasPrefix("v=dmarc1") }
            .map(\.content)

        return CloudflareZoneState(
            dnssecActive: dnssec.status.lowercased() == "active",
            sslMode: ssl.value,
            alwaysUseHTTPS: https.value.lowercased() == "on",
            hsts: hsts,
            caaRecords: contents(ofType: "CAA"),
            mxRecords: contents(ofType: "MX"),
            spfRecords: spf,
            dmarcRecords: dmarc,
            botFightMode: botFight,
            wafCustomRules: wafRules,
            speedBrain: speedBrain, ech: ech, zstdCompression: zstd, pageShield: pageShield, onionRouting: onionRouting)
    }

    private func fetchWAFCustomRules(zoneID: String, apiToken: String) async throws -> [CloudflareZoneState.WAFCustomRule] {
        let rulesets = try await core.get("/zones/\(zoneID)/rulesets", apiToken: apiToken, as: [CFRuleset].self)
        guard let custom = rulesets.first(where: { $0.phase == "http_request_firewall_custom" }) else {
            return []
        }
        let full = try await core.get("/zones/\(zoneID)/rulesets/\(custom.id)", apiToken: apiToken, as: CFRuleset.self)
        return (full.rules ?? []).map {
            .init(description: $0.description ?? "", expression: $0.expression, action: $0.action)
        }
    }

    /// Reads an on/off zone setting, defaulting to `false` when the token can't see it.
    private func settingIsOn(_ path: String, apiToken: String) async -> Bool {
        ((try? await core.get(path, apiToken: apiToken, as: CFStringSetting.self))?.value.lowercased()) == "on"
    }

    private func zstdEnabled(zoneID: String, apiToken: String) async -> Bool {
        guard let rulesets = try? await core.get("/zones/\(zoneID)/rulesets", apiToken: apiToken, as: [CFRuleset].self),
              let compression = rulesets.first(where: { $0.phase == "http_response_compression" }),
              let full = try? await core.get("/zones/\(zoneID)/rulesets/\(compression.id)", apiToken: apiToken, as: CFRuleset.self)
        else { return false }
        return (full.rules ?? []).contains { rule in
            rule.action == "compress_response"
                && (rule.action_parameters?.algorithms ?? []).contains { $0.name == "zstd" }
        }
    }

    private func pageShieldState(zoneID: String, apiToken: String) async -> CloudflareZoneState.PageShieldState? {
        guard let shield = try? await core.get("/zones/\(zoneID)/page_shield", apiToken: apiToken, as: CFPageShield.self) else {
            return nil
        }
        let enabled = shield.enabled ?? false
        var hosts: [String] = []
        if enabled,
           let scripts = try? await core.get("/zones/\(zoneID)/page_shield/scripts", apiToken: apiToken, as: [CFPageShieldScript].self) {
            hosts = Set(scripts.compactMap { $0.host ?? $0.url.flatMap { URL(string: $0)?.host } }).sorted()
        }
        return .init(enabled: enabled, scriptHosts: hosts)
    }

    /// Lists every DNS record in the zone, walking all pages (Cloudflare caps `per_page` at
    /// 100, so a single-page read silently truncates larger zones).
    public func listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord] {
        let raw = try await core.paginated("/zones/\(zoneID)/dns_records?per_page=100", apiToken: apiToken, as: CFFullDNSRecord.self)
        return raw.map {
            DNSRecord(id: $0.id, type: $0.type, name: $0.name, content: $0.content,
                      ttl: $0.ttl, proxied: $0.proxied ?? false, comment: $0.comment)
        }
    }

    /// Lists all Worker script names visible to the token's **first** account (a personal
    /// Cloudflare token virtually always sees exactly one), walking all pages. Throws
    /// ``CloudflareError/api(message:)`` when the token can see no account at all.
    public func workerScriptNames(apiToken: String) async throws -> [String] {
        let accounts = try await core.get("/accounts?per_page=1", apiToken: apiToken, as: [CFAccount].self)
        guard let accountID = accounts.first?.id else {
            throw CloudflareError.api(message: "no Cloudflare account visible to this token")
        }
        let scripts = try await core.paginated(
            "/accounts/\(accountID)/workers/scripts?per_page=100", apiToken: apiToken, as: CFWorkerScript.self)
        return scripts.map(\.id)
    }
}

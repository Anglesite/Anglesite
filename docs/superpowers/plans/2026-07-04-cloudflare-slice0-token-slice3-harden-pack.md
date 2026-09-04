# Cloudflare Slice 0 (Unified Token) + Slice 3 (Harden Pack) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the unified "Anglesite" Cloudflare token (template + capability probe) and extend the Harden/Audit flow with the newly-free zone features: Speed Brain, Zstandard compression, ECH, and Page Shield script monitoring.

**Architecture:** Two slices from `docs/superpowers/specs/2026-07-04-cloudflare-free-services-integration-design.md`. Slice 0 adds pure-Swift types in AnglesiteCore (`TokenCapability`, `CloudflareCapabilityProber`, `AnglesiteTokenTemplate`) and repoints the token-prompt UI at the new template. Slice 3 extends the existing read→plan→execute→audit pipeline (`CloudflareZoneState` → `HardenPlanner` → `HardenExecutor` → `SecurityAudit`) with four new zone capabilities, all via `HTTPCloudflareClient` with injected transport.

**Tech Stack:** Swift 6.4 / Xcode 27, SwiftPM, Swift Testing (`import Testing`, `@Test`, `#expect`). No new dependencies.

## Global Constraints

- Run tests with: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .` (the default CommandLineTools swift is broken/too old).
- All work happens in this worktree (`.claude/worktrees/peaceful-bun-85c4b5`), branch `claude/peaceful-bun-85c4b5`. `cd` there before any git op.
- No frameworks beyond Apple's. No `Process()` outside ProcessSupervisor (this plan spawns none).
- New-endpoint reads in `zoneState` must degrade gracefully (catch → default) so existing narrow tokens keep working — same pattern as the existing `bot_management` read.
- CI note: don't call macOS-27-only Foundation symbols in AnglesiteCore/tests (links `libswift_DarwinFoundation3.dylib`, absent on CI runners). Everything in this plan uses long-available APIs.
- Conventional commits, `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` footer.

**Cloudflare API endpoints used (verified against docs 2026-07-04):**

| Feature | Read | Write |
|---|---|---|
| Speed Brain | `GET /zones/{z}/settings/speed_brain` → `{value:"on"/"off"}` | `PATCH` same path, body `{"value":"on"}` |
| ECH | `GET /zones/{z}/settings/ech` → `{value:"on"/"off"}` | `PATCH` same path, body `{"value":"on"}` |
| Zstandard | ruleset phase `http_response_compression`, rule `action:"compress_response"` with `action_parameters.algorithms[].name == "zstd"` | POST rule into that phase's ruleset (create ruleset if absent — same upsert shape as `createWAFCustomRule`) |
| Page Shield | `GET /zones/{z}/page_shield` → `{enabled}`; `GET /zones/{z}/page_shield/scripts` → `[{url, host, …}]` | `PUT /zones/{z}/page_shield`, body `{"enabled":true}` |
| Capability probes | cheap GETs per group (see Task 2 table) | — |

---

### Task 1: `TokenCapability` model

**Files:**
- Create: `Sources/AnglesiteCore/TokenCapabilities.swift`
- Test: `Tests/AnglesiteCoreTests/TokenCapabilitiesTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum TokenCapability: String, CaseIterable, Codable, Sendable` with cases `workers, zoneSettings, dns, rulesets, turnstile, emailRouting, zaraz, pageShield, registrar`; `public typealias TokenCapabilities = Set<TokenCapability>`. Task 2's prober returns `TokenCapabilities`; future slices (1/2/5/7) gate wizards on `caps.contains(.turnstile)` etc.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/TokenCapabilitiesTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

struct TokenCapabilitiesTests {
    @Test("capabilities round-trip through Codable (persistable alongside the token)")
    func codableRoundTrip() throws {
        let caps: TokenCapabilities = [.workers, .turnstile, .emailRouting]
        let data = try JSONEncoder().encode(caps.sorted { $0.rawValue < $1.rawValue })
        let decoded = TokenCapabilities(try JSONDecoder().decode([TokenCapability].self, from: data))
        #expect(decoded == caps)
    }

    @Test("every capability has a stable raw value")
    func stableRawValues() {
        #expect(TokenCapability.allCases.count == 9)
        #expect(TokenCapability.zoneSettings.rawValue == "zoneSettings")
        #expect(TokenCapability(rawValue: "registrar") == .registrar)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter TokenCapabilitiesTests`
Expected: FAIL to compile — `cannot find 'TokenCapability' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/TokenCapabilities.swift
import Foundation

/// A permission group the stored Cloudflare token has been *observed* to have, via
/// `CloudflareCapabilityProber`. Capabilities are read-probe signals: presence means the token can
/// at least read that product's API; absence (401/403 on the probe) means a wizard needing it must
/// route the user through token re-onboarding (`AnglesiteTokenTemplate`) instead of failing mid-flow.
public enum TokenCapability: String, CaseIterable, Codable, Sendable {
    /// Workers scripts (deploy).
    case workers
    /// Zone settings (SSL mode, HSTS, Speed Brain, ECH, …).
    case zoneSettings
    /// DNS record reads/writes.
    case dns
    /// Zone rulesets (WAF custom rules, compression rules).
    case rulesets
    /// Turnstile widget management.
    case turnstile
    /// Email Routing (rules + destination addresses).
    case emailRouting
    /// Zaraz configuration.
    case zaraz
    /// Page Shield (client-side security) status + script reports.
    case pageShield
    /// Registrar domain search/registration.
    case registrar
}

/// The set of permission groups a probe observed on the stored token.
public typealias TokenCapabilities = Set<TokenCapability>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter TokenCapabilitiesTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/TokenCapabilities.swift Tests/AnglesiteCoreTests/TokenCapabilitiesTests.swift
git commit -m "feat(#59): add TokenCapability model for Cloudflare token capability probing

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `CloudflareCapabilityProber`

**Files:**
- Create: `Sources/AnglesiteCore/CloudflareCapabilityProber.swift`
- Test: `Tests/AnglesiteCoreTests/CloudflareCapabilityProberTests.swift`

**Interfaces:**
- Consumes: `TokenCapability`/`TokenCapabilities` (Task 1), `CloudflareTransport` typealias (`Sources/AnglesiteCore/CloudflareReading.swift:22`), `fakeTransport(_:)` helper (`Tests/AnglesiteCoreTests/CloudflareClientTests.swift` — file-scope, visible test-target-wide).
- Produces: `public struct CloudflareCapabilityProber: Sendable` with `init(baseURL: URL = …, transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport)` and `public func probe(token: String, zoneID: String?) async -> TokenCapabilities`.

Probe endpoints (GET; **401/403 ⇒ capability absent; any other HTTP status ⇒ present** — a 404 like "Email Routing not enabled yet" still proves the permission; a thrown transport error ⇒ absent, callers may re-probe):

| Capability | Probe path |
|---|---|
| `.workers` | `accounts/{accountID}/workers/scripts` |
| `.turnstile` | `accounts/{accountID}/challenges/widgets` |
| `.registrar` | `accounts/{accountID}/registrar/domains` |
| `.zoneSettings` | `zones/{zoneID}/settings/ssl` |
| `.dns` | `zones/{zoneID}/dns_records?per_page=1` |
| `.rulesets` | `zones/{zoneID}/rulesets` |
| `.emailRouting` | `zones/{zoneID}/email/routing` |
| `.zaraz` | `zones/{zoneID}/settings/zaraz/config` |
| `.pageShield` | `zones/{zoneID}/page_shield` |

Account ID is resolved internally via `GET accounts` (first account, like `CloudflareAPITokenVerifier.accountName`). If it can't be resolved, account-scoped probes are skipped (absent). If `zoneID` is nil, zone-scoped probes are skipped (absent).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/CloudflareCapabilityProberTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

struct CloudflareCapabilityProberTests {
    private let accountsOK = (200, #"{"success":true,"result":[{"id":"acc1","name":"Acme"}]}"#)

    @Test("2xx and non-auth errors mark a capability present; 403 marks it absent")
    func classifiesStatuses() async {
        let prober = CloudflareCapabilityProber(transport: fakeTransport([
            "/accounts?": accountsOK,
            "accounts/acc1/workers/scripts": (200, #"{"success":true,"result":[]}"#),
            "accounts/acc1/challenges/widgets": (403, #"{"success":false}"#),
            "accounts/acc1/registrar/domains": (200, #"{"success":true,"result":[]}"#),
            "zones/z1/settings/ssl": (200, #"{"success":true,"result":{"value":"strict"}}"#),
            "zones/z1/dns_records": (403, #"{"success":false}"#),
            "zones/z1/rulesets": (200, #"{"success":true,"result":[]}"#),
            "zones/z1/email/routing": (404, #"{"success":false}"#),
            "zones/z1/settings/zaraz/config": (403, #"{"success":false}"#),
            "zones/z1/page_shield": (200, #"{"success":true,"result":{"enabled":false}}"#),
        ]))
        let caps = await prober.probe(token: "t", zoneID: "z1")
        #expect(caps.contains(.workers))
        #expect(!caps.contains(.turnstile))
        #expect(caps.contains(.registrar))
        #expect(caps.contains(.zoneSettings))
        #expect(!caps.contains(.dns))
        #expect(caps.contains(.rulesets))
        #expect(caps.contains(.emailRouting))  // 404 = enabled-state miss, permission present
        #expect(!caps.contains(.zaraz))
        #expect(caps.contains(.pageShield))
    }

    @Test("nil zoneID skips zone probes; unresolvable account skips account probes")
    func skipsUnscopedProbes() async {
        let prober = CloudflareCapabilityProber(transport: fakeTransport([
            "/accounts?": (403, #"{"success":false}"#),
        ]))
        let caps = await prober.probe(token: "t", zoneID: nil)
        #expect(caps.isEmpty)
    }

    @Test("probe requests carry the bearer token")
    func sendsBearer() async {
        let spy = TransportSpy()
        let inner = fakeTransport(["/accounts?": accountsOK])
        let prober = CloudflareCapabilityProber(transport: { request in
            spy.record(request)
            return try await inner(request)
        })
        _ = await prober.probe(token: "sekret", zoneID: nil)
        #expect(spy.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer sekret"
        })
    }
}
```

Note: `fakeTransport` routes by URL substring. The `"/accounts?"` needle must not collide with `accounts/acc1/...` paths — so the implementation must request the account list as `accounts?per_page=1` (the `?` disambiguates the route; longest-needle-first matching handles the rest).

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter CloudflareCapabilityProberTests`
Expected: FAIL to compile — `cannot find 'CloudflareCapabilityProber' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AnglesiteCore/CloudflareCapabilityProber.swift
import Foundation

/// Observes which permission groups a stored Cloudflare token actually has, by issuing one cheap
/// authenticated GET per group. 401/403 means the group is missing; any other response (including
/// 404s like "Email Routing not enabled") proves the permission. A thrown transport error counts as
/// missing — probes are advisory and callers may re-probe.
///
/// This exists so wizards can gate on `TokenCapabilities` up front and route the user through token
/// re-onboarding (`AnglesiteTokenTemplate`) instead of failing halfway through an API orchestration.
public struct CloudflareCapabilityProber: Sendable {
    private let baseURL: URL
    private let transport: CloudflareTransport

    public init(
        baseURL: URL = URL(string: "https://api.cloudflare.com/client/v4")!,
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func probe(token: String, zoneID: String?) async -> TokenCapabilities {
        var caps = TokenCapabilities()

        var probes: [(TokenCapability, String)] = []
        if let accountID = await firstAccountID(token: token) {
            probes += [
                (.workers, "accounts/\(accountID)/workers/scripts"),
                (.turnstile, "accounts/\(accountID)/challenges/widgets"),
                (.registrar, "accounts/\(accountID)/registrar/domains"),
            ]
        }
        if let zoneID {
            probes += [
                (.zoneSettings, "zones/\(zoneID)/settings/ssl"),
                (.dns, "zones/\(zoneID)/dns_records?per_page=1"),
                (.rulesets, "zones/\(zoneID)/rulesets"),
                (.emailRouting, "zones/\(zoneID)/email/routing"),
                (.zaraz, "zones/\(zoneID)/settings/zaraz/config"),
                (.pageShield, "zones/\(zoneID)/page_shield"),
            ]
        }
        for (cap, path) in probes {
            if await allowed(path, token: token) {
                caps.insert(cap)
            }
        }
        return caps
    }

    /// First account id visible to the token, or nil (account-scoped probes are then skipped).
    private func firstAccountID(token: String) async -> String? {
        struct Envelope: Decodable { let result: [Account]?; struct Account: Decodable { let id: String } }
        guard let (data, http) = try? await get("accounts?per_page=1", token: token),
              (200..<300).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        return envelope.result?.first?.id
    }

    private func allowed(_ path: String, token: String) async -> Bool {
        guard let (_, http) = try? await get(path, token: token) else { return false }
        return http.statusCode != 401 && http.statusCode != 403
    }

    private func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: baseURL.absoluteString + "/" + path) else {
            throw CloudflareError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await transport(request)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter CloudflareCapabilityProberTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/CloudflareCapabilityProber.swift Tests/AnglesiteCoreTests/CloudflareCapabilityProberTests.swift
git commit -m "feat(#59): probe Cloudflare token capabilities per permission group

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `AnglesiteTokenTemplate` + token prompt repoint

**Files:**
- Create: `Sources/AnglesiteCore/AnglesiteTokenTemplate.swift`
- Modify: `Sources/AnglesiteApp/CloudflareTokenPromptView.swift:26-48` (delete local `createTokenURL`, use the core type; update step copy), `Sources/AnglesiteCore/CloudflareTokenVerifier.swift:29` (invalidToken copy)
- Test: `Tests/AnglesiteCoreTests/AnglesiteTokenTemplateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum AnglesiteTokenTemplate` with `public static let tokenName: String` (= `"Anglesite"`), `public static let permissionGroups: [(key: String, type: String)]`, `public static var createTokenURL: URL`. The view consumes `createTokenURL`; docs/UI copy consume `tokenName`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/AnglesiteTokenTemplateTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

struct AnglesiteTokenTemplateTests {
    @Test("the template keeps every permission the old Workers-deploy template had")
    func supersetOfDeployTemplate() {
        let keys = Set(AnglesiteTokenTemplate.permissionGroups.map(\.key))
        for legacy in ["workers_routes", "workers_scripts", "workers_kv_storage", "workers_tail", "workers_r2"] {
            #expect(keys.contains(legacy))
        }
    }

    @Test("the template covers the new integration surface")
    func coversNewServices() {
        let keys = Set(AnglesiteTokenTemplate.permissionGroups.map(\.key))
        for needed in ["d1", "zone_settings", "dns", "zone_waf", "challenge_widgets",
                       "email_routing_rules", "email_routing_addresses", "zaraz",
                       "page_shield", "analytics", "registrar"] {
            #expect(keys.contains(needed), "missing permission group: \(needed)")
        }
    }

    @Test("createTokenURL lands on the dashboard token page with name + permission pre-fill")
    func urlShape() throws {
        let components = try #require(URLComponents(url: AnglesiteTokenTemplate.createTokenURL,
                                                    resolvingAgainstBaseURL: false))
        #expect(components.host == "dash.cloudflare.com")
        #expect(components.path == "/profile/api-tokens")
        let items = components.queryItems ?? []
        #expect(items.contains { $0.name == "name" && $0.value == "Anglesite" })
        let permissions = items.first { $0.name == "permissionGroupKeys" }?.value ?? ""
        #expect(permissions.contains(#""key":"workers_scripts""#))
        #expect(permissions.contains(#""key":"registrar""#))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AnglesiteTokenTemplateTests`
Expected: FAIL to compile — `cannot find 'AnglesiteTokenTemplate' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteCore/AnglesiteTokenTemplate.swift
import Foundation

/// The single "Anglesite" Cloudflare API token: one custom template carrying every permission the
/// app can use across deploy, harden, and the integration wizards (spec:
/// docs/superpowers/specs/2026-07-04-cloudflare-free-services-integration-design.md §4).
///
/// The dashboard pre-fill query params are undocumented; if Cloudflare changes the schema the link
/// still lands on the token page and the prompt's numbered steps describe the permissions to add by
/// hand, so the flow degrades rather than breaks (verified pre-fill behavior last on 2026-06-16 for
/// the original five groups).
public enum AnglesiteTokenTemplate {
    public static let tokenName = "Anglesite"

    /// Dashboard permission-group keys with their access level. Order is display order.
    public static let permissionGroups: [(key: String, type: String)] = [
        // Deploy (the original "Edit Cloudflare Workers" set)
        ("workers_routes", "edit"),
        ("workers_scripts", "edit"),
        ("workers_kv_storage", "edit"),
        ("workers_tail", "read"),
        ("workers_r2", "edit"),
        ("d1", "edit"),
        // Harden + zone state
        ("zone_settings", "edit"),
        ("dns", "edit"),
        ("zone_waf", "edit"),
        ("page_shield", "read"),
        ("analytics", "read"),
        // Integration wizards (slices 1, 2, 5, 7)
        ("challenge_widgets", "edit"),
        ("email_routing_rules", "edit"),
        ("email_routing_addresses", "edit"),
        ("zaraz", "edit"),
        ("registrar", "edit"),
    ]

    public static var createTokenURL: URL {
        let permissions = "[" + permissionGroups
            .map { #"{"key":"\#($0.key)","type":"\#($0.type)"}"# }
            .joined(separator: ",") + "]"
        var components = URLComponents(string: "https://dash.cloudflare.com/profile/api-tokens")!
        components.queryItems = [
            URLQueryItem(name: "name", value: tokenName),
            URLQueryItem(name: "accountId", value: "*"),
            URLQueryItem(name: "zoneId", value: "all"),
            URLQueryItem(name: "permissionGroupKeys", value: permissions),
        ]
        return components.url!
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AnglesiteTokenTemplateTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Repoint the prompt view and error copy**

In `Sources/AnglesiteApp/CloudflareTokenPromptView.swift`:
- Delete the whole `private static let createTokenURL: URL = { … }()` block (lines 26–48) and replace every use of `Self.createTokenURL` with `AnglesiteTokenTemplate.createTokenURL`.
- Update the doc comment (lines 9–14): the link now pre-fills a custom token named "Anglesite" covering deploy + harden + integrations, not the built-in "Edit Cloudflare Workers" template.
- Update the step copy at line 82 from
  `Text("The “Edit Cloudflare Workers” permissions should already be selected (if not, pick that template). Click **Continue to summary**.")`
  to
  `Text("A custom token named “Anglesite” should be pre-filled with all permissions Anglesite uses (if not, choose **Create Custom Token** and continue — deploy still works and Anglesite will ask again when a feature needs more access). Click **Continue to summary**.")`

In `Sources/AnglesiteCore/CloudflareTokenVerifier.swift:29`, change the `.invalidToken` message to:

```swift
return "That token didn’t work. Use the “Create token” link (it pre-fills the “Anglesite” token) and copy the whole token."
```

- [ ] **Step 6: Fix any test asserting the old copy, run core tests**

Run: `grep -rn "Edit Cloudflare Workers" Tests/ Sources/` — update any remaining test assertion or UI string to the new copy (the verifier tests assert `userMessage` content).
Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: PASS (full suite).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/AnglesiteTokenTemplate.swift Sources/AnglesiteApp/CloudflareTokenPromptView.swift Sources/AnglesiteCore/CloudflareTokenVerifier.swift Tests/
git commit -m "feat(#59): unify token onboarding on the Anglesite token template

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Zone-state reads for Speed Brain, ECH, Zstandard, Page Shield

**Files:**
- Modify: `Sources/AnglesiteCore/CloudflareZoneState.swift`, `Sources/AnglesiteCore/HTTPCloudflareClient.swift`
- Test: `Tests/AnglesiteCoreTests/CloudflareClientTests.swift` (append tests)

**Interfaces:**
- Consumes: existing `CFStringSetting`, `CFRuleset`, `get(_:apiToken:as:)` in `HTTPCloudflareClient`.
- Produces: on `CloudflareZoneState`: `public var speedBrain: Bool`, `public var ech: Bool`, `public var zstdCompression: Bool`, `public var pageShield: PageShieldState?` with `public struct PageShieldState: Sendable, Equatable { public var enabled: Bool; public var scriptHosts: [String] }`. All new init params are defaulted (`false`/`nil`) so every existing call site compiles unchanged. Tasks 6–8 consume these fields.

- [ ] **Step 1: Write the failing test** (append to `CloudflareClientTests.swift`)

```swift
extension CloudflareClientTests {
    private static let baseRoutes: [String: (Int, String)] = [
        "/dnssec": (200, #"{"success":true,"result":{"status":"active"}}"#),
        "/settings/ssl": (200, #"{"success":true,"result":{"value":"strict"}}"#),
        "/settings/always_use_https": (200, #"{"success":true,"result":{"value":"on"}}"#),
        "/settings/security_header": (200, #"{"success":true,"result":{"value":{"strict_transport_security":{"enabled":true,"max_age":31536000,"include_subdomains":true,"preload":false}}}}"#),
        "/dns_records": (200, #"{"success":true,"result":[]}"#),
        "/settings/bot_management": (403, #"{"success":false}"#),
    ]

    @Test("zoneState reads the harden-pack settings when the API grants them")
    func zoneStateHardenPack() async throws {
        var routes = Self.baseRoutes
        routes["/settings/speed_brain"] = (200, #"{"success":true,"result":{"value":"on"}}"#)
        routes["/settings/ech"] = (200, #"{"success":true,"result":{"value":"off"}}"#)
        routes["/zones/z/rulesets/comp1"] = (200, #"{"success":true,"result":{"id":"comp1","phase":"http_response_compression","rules":[{"expression":"true","action":"compress_response","action_parameters":{"algorithms":[{"name":"zstd"},{"name":"gzip"}]}}]}}"#)
        routes["/zones/z/rulesets"] = (200, #"{"success":true,"result":[{"id":"comp1","phase":"http_response_compression"}]}"#)
        routes["/page_shield/scripts"] = (200, #"{"success":true,"result":[{"url":"https://cdn.evil.example/t.js","host":"cdn.evil.example"}]}"#)
        routes["/page_shield"] = (200, #"{"success":true,"result":{"enabled":true}}"#)

        let client = HTTPCloudflareClient(transport: fakeTransport(routes))
        let state = try await client.zoneState(zoneID: "z", apiToken: "t")
        #expect(state.speedBrain)
        #expect(!state.ech)
        #expect(state.zstdCompression)
        #expect(state.pageShield == .init(enabled: true, scriptHosts: ["cdn.evil.example"]))
    }

    @Test("zoneState defaults the harden-pack fields when the token can't read them")
    func zoneStateHardenPackDegrades() async throws {
        // No speed_brain/ech/page_shield routes at all -> fakeTransport 404s -> envelope failure.
        var routes = Self.baseRoutes
        routes["/zones/z/rulesets"] = (403, #"{"success":false}"#)
        let client = HTTPCloudflareClient(transport: fakeTransport(routes))
        let state = try await client.zoneState(zoneID: "z", apiToken: "t")
        #expect(!state.speedBrain)
        #expect(!state.ech)
        #expect(!state.zstdCompression)
        #expect(state.pageShield == nil)
    }
}
```

Note: `fakeTransport` matches longest needle first, so `"/zones/z/rulesets/comp1"` wins over `"/zones/z/rulesets"`, and `"/page_shield/scripts"` wins over `"/page_shield"`. The 404 fallback returns `{"success":false}`, which the client maps to a thrown error — exactly what the degrade path catches. **Heads-up:** the existing WAF fetch shares `"/zones/z/rulesets"`; in `zoneStateHardenPack` it now sees the compression ruleset and no `http_request_firewall_custom` phase, which yields `wafCustomRules == []` — fine.

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter CloudflareClientTests`
Expected: FAIL to compile — `value of type 'CloudflareZoneState' has no member 'speedBrain'`.

- [ ] **Step 3: Extend `CloudflareZoneState`**

Add inside the struct (after `wafCustomRules` and `WAFCustomRule`):

```swift
    /// Speed Brain (speculation-rules prefetching) zone setting.
    public var speedBrain: Bool
    /// Encrypted Client Hello zone setting.
    public var ech: Bool
    /// Whether a compression rule enables Zstandard (`http_response_compression` phase).
    public var zstdCompression: Bool
    /// Page Shield (client-side security) status + detected script hosts. `nil` when unreadable.
    public var pageShield: PageShieldState?

    /// Page Shield script-monitor snapshot.
    public struct PageShieldState: Sendable, Equatable {
        public var enabled: Bool
        /// Unique, sorted hosts of scripts Page Shield has seen loading on the site.
        public var scriptHosts: [String]
        public init(enabled: Bool, scriptHosts: [String]) {
            self.enabled = enabled
            self.scriptHosts = scriptHosts
        }
    }
```

Extend the init signature with defaulted trailing parameters and assignments:

```swift
    public init(dnssecActive: Bool, sslMode: String, alwaysUseHTTPS: Bool, hsts: HSTS?,
                caaRecords: [String], mxRecords: [String], spfRecords: [String], dmarcRecords: [String],
                botFightMode: Bool = false, wafCustomRules: [WAFCustomRule] = [],
                speedBrain: Bool = false, ech: Bool = false, zstdCompression: Bool = false,
                pageShield: PageShieldState? = nil) {
        // …existing assignments…
        self.speedBrain = speedBrain
        self.ech = ech
        self.zstdCompression = zstdCompression
        self.pageShield = pageShield
    }
```

- [ ] **Step 4: Extend `HTTPCloudflareClient.zoneState`**

Add private decode types near the other `CF*` types in `HTTPCloudflareClient.swift`:

```swift
private struct CFPageShield: Decodable, Sendable { let enabled: Bool? }
private struct CFPageShieldScript: Decodable, Sendable {
    let url: String?
    let host: String?
}
```

Extend `CFRulesetRule` with the compression parameters:

```swift
private struct CFRulesetRule: Decodable, Sendable {
    let description: String?
    let expression: String
    let action: String
    let action_parameters: Params?
    struct Params: Decodable, Sendable {
        let algorithms: [Algorithm]?
        struct Algorithm: Decodable, Sendable { let name: String? }
    }
}
```

Add helpers to `HTTPCloudflareClient`:

```swift
    /// Reads an on/off zone setting, defaulting to `false` when the token can't see it.
    private func settingIsOn(_ path: String, apiToken: String) async -> Bool {
        ((try? await get(path, apiToken: apiToken, as: CFStringSetting.self))?.value.lowercased()) == "on"
    }

    private func zstdEnabled(zoneID: String, apiToken: String) async -> Bool {
        guard let rulesets = try? await get("/zones/\(zoneID)/rulesets", apiToken: apiToken, as: [CFRuleset].self),
              let compression = rulesets.first(where: { $0.phase == "http_response_compression" }),
              let full = try? await get("/zones/\(zoneID)/rulesets/\(compression.id)", apiToken: apiToken, as: CFRuleset.self)
        else { return false }
        return (full.rules ?? []).contains { rule in
            rule.action == "compress_response"
                && (rule.action_parameters?.algorithms ?? []).contains { $0.name == "zstd" }
        }
    }

    private func pageShieldState(zoneID: String, apiToken: String) async -> CloudflareZoneState.PageShieldState? {
        guard let shield = try? await get("/zones/\(zoneID)/page_shield", apiToken: apiToken, as: CFPageShield.self) else {
            return nil
        }
        let enabled = shield.enabled ?? false
        var hosts: [String] = []
        if enabled,
           let scripts = try? await get("/zones/\(zoneID)/page_shield/scripts", apiToken: apiToken, as: [CFPageShieldScript].self) {
            hosts = Set(scripts.compactMap { $0.host ?? $0.url.flatMap { URL(string: $0)?.host } }).sorted()
        }
        return .init(enabled: enabled, scriptHosts: hosts)
    }
```

In `zoneState(zoneID:apiToken:)`, before the final `return`, add:

```swift
        let speedBrain = await settingIsOn("/zones/\(zoneID)/settings/speed_brain", apiToken: apiToken)
        let ech = await settingIsOn("/zones/\(zoneID)/settings/ech", apiToken: apiToken)
        let zstd = await zstdEnabled(zoneID: zoneID, apiToken: apiToken)
        let pageShield = await pageShieldState(zoneID: zoneID, apiToken: apiToken)
```

and pass them in the returned initializer: `speedBrain: speedBrain, ech: ech, zstdCompression: zstd, pageShield: pageShield`.

- [ ] **Step 5: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter CloudflareClientTests`
Expected: PASS (existing + 2 new).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/CloudflareZoneState.swift Sources/AnglesiteCore/HTTPCloudflareClient.swift Tests/AnglesiteCoreTests/CloudflareClientTests.swift
git commit -m "feat(#59): read Speed Brain, ECH, Zstandard, and Page Shield zone state

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Write methods for the harden pack

**Files:**
- Modify: `Sources/AnglesiteCore/CloudflareWriting.swift`, `Sources/AnglesiteCore/HTTPCloudflareClient.swift` (CloudflareWriting extension), `Tests/AnglesiteCoreTests/HardenExecutorTests.swift:122-159` (`MockCloudflareWriter`)
- Test: `Tests/AnglesiteCoreTests/CloudflareWritingTests.swift` (append)

**Interfaces:**
- Consumes: `mutate(method:_:body:apiToken:)`, ruleset-upsert pattern from `createWAFCustomRule` (`HTTPCloudflareClient.swift:222-242`).
- Produces (protocol additions on `CloudflareWriting`):
  - `func setSpeedBrain(zoneID: String, enabled: Bool, apiToken: String) async throws`
  - `func setECH(zoneID: String, enabled: Bool, apiToken: String) async throws`
  - `func enableZstandardCompression(zoneID: String, apiToken: String) async throws`
  - `func setPageShield(zoneID: String, enabled: Bool, apiToken: String) async throws`

- [ ] **Step 1: Write the failing test** (append to `CloudflareWritingTests.swift`, following that file's existing spy/route pattern — it uses `TransportSpy` + `fakeTransport` from `CloudflareClientTests.swift`)

```swift
extension CloudflareWritingTests {
    private func spiedClient(_ routes: [String: (Int, String)]) -> (HTTPCloudflareClient, TransportSpy) {
        let spy = TransportSpy()
        let inner = fakeTransport(routes)
        let client = HTTPCloudflareClient(transport: { request in
            spy.record(request)
            return try await inner(request)
        })
        return (client, spy)
    }

    @Test("setSpeedBrain PATCHes the speed_brain setting")
    func speedBrainWrite() async throws {
        let (client, spy) = spiedClient([
            "/settings/speed_brain": (200, #"{"success":true,"result":{}}"#),
        ])
        try await client.setSpeedBrain(zoneID: "z", enabled: true, apiToken: "t")
        let request = try #require(spy.requests.last)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url!.path.hasSuffix("/zones/z/settings/speed_brain"))
        #expect(String(data: request.httpBody ?? Data(), encoding: .utf8)!.contains(#""value":"on""#))
    }

    @Test("setECH PATCHes the ech setting")
    func echWrite() async throws {
        let (client, spy) = spiedClient([
            "/settings/ech": (200, #"{"success":true,"result":{}}"#),
        ])
        try await client.setECH(zoneID: "z", enabled: true, apiToken: "t")
        let request = try #require(spy.requests.last)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url!.path.hasSuffix("/zones/z/settings/ech"))
    }

    @Test("setPageShield PUTs enabled")
    func pageShieldWrite() async throws {
        let (client, spy) = spiedClient([
            "/page_shield": (200, #"{"success":true,"result":{}}"#),
        ])
        try await client.setPageShield(zoneID: "z", enabled: true, apiToken: "t")
        let request = try #require(spy.requests.last)
        #expect(request.httpMethod == "PUT")
        #expect(String(data: request.httpBody ?? Data(), encoding: .utf8)!.contains(#""enabled":true"#))
    }

    @Test("enableZstandardCompression creates the compression ruleset when absent")
    func zstdCreatesRuleset() async throws {
        let (client, spy) = spiedClient([
            "/zones/z/rulesets": (200, #"{"success":true,"result":[]}"#),
        ])
        try await client.enableZstandardCompression(zoneID: "z", apiToken: "t")
        let post = try #require(spy.requests.last)
        #expect(post.httpMethod == "POST")
        #expect(post.url!.path.hasSuffix("/zones/z/rulesets"))
        let body = String(data: post.httpBody ?? Data(), encoding: .utf8)!
        #expect(body.contains("http_response_compression"))
        #expect(body.contains(#""name":"zstd""#))
    }

    @Test("enableZstandardCompression appends a rule when the ruleset exists")
    func zstdAppendsRule() async throws {
        let (client, spy) = spiedClient([
            "/zones/z/rulesets/comp1/rules": (200, #"{"success":true,"result":{}}"#),
            "/zones/z/rulesets": (200, #"{"success":true,"result":[{"id":"comp1","phase":"http_response_compression"}]}"#),
        ])
        try await client.enableZstandardCompression(zoneID: "z", apiToken: "t")
        let post = try #require(spy.requests.last)
        #expect(post.url!.path.hasSuffix("/zones/z/rulesets/comp1/rules"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter CloudflareWritingTests`
Expected: FAIL to compile — `value of type 'HTTPCloudflareClient' has no member 'setSpeedBrain'`.

- [ ] **Step 3: Add the protocol requirements** (in `CloudflareWriting.swift`, after `createWAFCustomRule`)

```swift
    func setSpeedBrain(zoneID: String, enabled: Bool, apiToken: String) async throws
    func setECH(zoneID: String, enabled: Bool, apiToken: String) async throws
    /// Idempotent: creates the `http_response_compression` ruleset with a zstd-first rule, or
    /// appends the rule to the existing ruleset.
    func enableZstandardCompression(zoneID: String, apiToken: String) async throws
    func setPageShield(zoneID: String, enabled: Bool, apiToken: String) async throws
```

- [ ] **Step 4: Implement in the `CloudflareWriting` extension of `HTTPCloudflareClient`**

```swift
    public func setSpeedBrain(zoneID: String, enabled: Bool, apiToken: String) async throws {
        try await mutate(method: "PATCH", "/zones/\(zoneID)/settings/speed_brain",
                         body: ["value": enabled ? "on" : "off"], apiToken: apiToken)
    }

    public func setECH(zoneID: String, enabled: Bool, apiToken: String) async throws {
        try await mutate(method: "PATCH", "/zones/\(zoneID)/settings/ech",
                         body: ["value": enabled ? "on" : "off"], apiToken: apiToken)
    }

    public func setPageShield(zoneID: String, enabled: Bool, apiToken: String) async throws {
        try await mutate(method: "PUT", "/zones/\(zoneID)/page_shield",
                         body: ["enabled": enabled], apiToken: apiToken)
    }

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

        let rulesets = try await get("/zones/\(zoneID)/rulesets", apiToken: apiToken, as: [CFRuleset].self)
        if let existing = rulesets.first(where: { $0.phase == "http_response_compression" }) {
            try await mutate(method: "POST", "/zones/\(zoneID)/rulesets/\(existing.id)/rules",
                             body: rule, apiToken: apiToken)
        } else {
            struct NewRuleset: Encodable, Sendable {
                let name: String
                let kind: String
                let phase: String
                let rules: [CompressionRule]
            }
            try await mutate(method: "POST", "/zones/\(zoneID)/rulesets",
                             body: NewRuleset(name: "Anglesite compression rules",
                                              kind: "zone", phase: "http_response_compression",
                                              rules: [rule]),
                             apiToken: apiToken)
        }
    }
```

- [ ] **Step 5: Extend `MockCloudflareWriter`** (in `HardenExecutorTests.swift`, after `createWAFCustomRule`)

```swift
    func setSpeedBrain(zoneID: String, enabled: Bool, apiToken: String) async throws {
        try record("setSpeedBrain")
    }
    func setECH(zoneID: String, enabled: Bool, apiToken: String) async throws {
        try record("setECH")
    }
    func enableZstandardCompression(zoneID: String, apiToken: String) async throws {
        try record("enableZstandardCompression")
    }
    func setPageShield(zoneID: String, enabled: Bool, apiToken: String) async throws {
        try record("setPageShield")
    }
```

Also run `grep -rn ": CloudflareWriting" Sources Tests` — if any other conformer exists, add the four methods there the same way.

- [ ] **Step 6: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter "CloudflareWritingTests|HardenExecutorTests"`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/CloudflareWriting.swift Sources/AnglesiteCore/HTTPCloudflareClient.swift Tests/AnglesiteCoreTests/CloudflareWritingTests.swift Tests/AnglesiteCoreTests/HardenExecutorTests.swift
git commit -m "feat(#59): add Speed Brain, ECH, Zstandard, Page Shield write methods

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Harden plan items + planner logic

**Files:**
- Modify: `Sources/AnglesiteCore/HardenPlan.swift`, `Sources/AnglesiteCore/HardenPlanner.swift`, `Tests/AnglesiteCoreTests/HardenPlannerTests.swift` (fixtures + new tests)

**Interfaces:**
- Consumes: `CloudflareZoneState.speedBrain/ech/zstdCompression/pageShield` (Task 4).
- Produces: `HardenPlanItem` cases `.enableSpeedBrain`, `.enableZstandardCompression`, `.enableECH`, `.enablePageShieldMonitoring` (Task 7 dispatches on these).

- [ ] **Step 1: Update fixtures and write failing tests**

In `HardenPlannerTests.swift`, extend the `hardened()` fixture's initializer call with:

```swift
            speedBrain: true, ech: true, zstdCompression: true,
            pageShield: .init(enabled: true, scriptHosts: [])
```

(`bare()` needs no change — the new init params default to off.) Then append:

```swift
    @Test("a bare zone plans the harden-pack items")
    func bareGetsHardenPack() {
        let plan = HardenPlanner.plan(from: bare(), domain: "example.com")
        #expect(plan.items.contains(.enableSpeedBrain))
        #expect(plan.items.contains(.enableZstandardCompression))
        #expect(plan.items.contains(.enableECH))
        #expect(plan.items.contains(.enablePageShieldMonitoring))
    }

    @Test("page shield monitoring is planned when the state is unreadable (nil)")
    func pageShieldNilPlansEnable() {
        var state = hardened()
        state.pageShield = nil
        let plan = HardenPlanner.plan(from: state, domain: "example.com")
        #expect(plan.items == [.enablePageShieldMonitoring])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter HardenPlannerTests`
Expected: FAIL to compile — `type 'HardenPlanItem' has no member 'enableSpeedBrain'`.

- [ ] **Step 3: Add the plan items** (in `HardenPlan.swift`, after `.enableBotFightMode` case and in `description`)

```swift
    case enableSpeedBrain
    case enableZstandardCompression
    case enableECH
    case enablePageShieldMonitoring
```

```swift
        case .enableSpeedBrain:
            return "+ Enable Speed Brain (speculative prefetching)"
        case .enableZstandardCompression:
            return "+ Enable Zstandard compression"
        case .enableECH:
            return "+ Enable Encrypted Client Hello (ECH)"
        case .enablePageShieldMonitoring:
            return "+ Enable client-side script monitoring (Page Shield)"
```

- [ ] **Step 4: Add the planner logic** (in `HardenPlanner.plan`, after the Bot Fight Mode check and before the email block)

```swift
        if !state.speedBrain {
            items.append(.enableSpeedBrain)
        }
        if !state.zstdCompression {
            items.append(.enableZstandardCompression)
        }
        if !state.ech {
            items.append(.enableECH)
        }
        if state.pageShield?.enabled != true {
            items.append(.enablePageShieldMonitoring)
        }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter HardenPlannerTests`
Expected: PASS (including the pre-existing `fullyHardenedIsEmpty`, now green because the fixture gained the new fields).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/HardenPlan.swift Sources/AnglesiteCore/HardenPlanner.swift Tests/AnglesiteCoreTests/HardenPlannerTests.swift
git commit -m "feat(#59): plan Speed Brain, Zstandard, ECH, and Page Shield hardening

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Executor dispatch for the new items

**Files:**
- Modify: `Sources/AnglesiteCore/HardenExecutor.swift:70-110` (`apply`), `Tests/AnglesiteCoreTests/HardenExecutorTests.swift` (extend `itemsDispatchCorrectly` + `MockCloudflareReader` default state)

**Interfaces:**
- Consumes: `HardenPlanItem` new cases (Task 6), `CloudflareWriting` new methods (Task 5).
- Produces: nothing new — completes the plan→write loop.

- [ ] **Step 1: Extend the dispatch test**

In `itemsDispatchCorrectly`, add to the plan array:

```swift
            .enableSpeedBrain,
            .enableZstandardCompression,
            .enableECH,
            .enablePageShieldMonitoring,
```

change `#expect(result.appliedCount == 9)` to `#expect(result.appliedCount == 13)`, and add:

```swift
        #expect(writer.calls.contains("setSpeedBrain"))
        #expect(writer.calls.contains("enableZstandardCompression"))
        #expect(writer.calls.contains("setECH"))
        #expect(writer.calls.contains("setPageShield"))
```

Also extend `MockCloudflareReader`'s default `init` state so post-harden audits stay clean (append to the `CloudflareZoneState` call):

```swift
        botFightMode: true,
        speedBrain: true, ech: true, zstdCompression: true,
        pageShield: .init(enabled: true, scriptHosts: [])
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter HardenExecutorTests`
Expected: FAIL — `switch must be exhaustive` compile error in `HardenExecutor.apply` (the new cases are unhandled).

- [ ] **Step 3: Add the dispatch cases** (in `HardenExecutor.apply`, after `.enableBotFightMode`)

```swift
        case .enableSpeedBrain:
            try await writer.setSpeedBrain(zoneID: zoneID, enabled: true, apiToken: apiToken)
        case .enableZstandardCompression:
            try await writer.enableZstandardCompression(zoneID: zoneID, apiToken: apiToken)
        case .enableECH:
            try await writer.setECH(zoneID: zoneID, enabled: true, apiToken: apiToken)
        case .enablePageShieldMonitoring:
            try await writer.setPageShield(zoneID: zoneID, enabled: true, apiToken: apiToken)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter HardenExecutorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/HardenExecutor.swift Tests/AnglesiteCoreTests/HardenExecutorTests.swift
git commit -m "feat(#59): execute harden-pack items via the Cloudflare write API

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: SecurityAudit findings for ECH + Page Shield

**Files:**
- Modify: `Sources/AnglesiteCore/SecurityAudit.swift`, `Tests/AnglesiteCoreTests/SecurityAuditTests.swift`

**Interfaces:**
- Consumes: `CloudflareZoneState.ech/pageShield` (Task 4).
- Produces: three new `.info` findings. Speed Brain and Zstandard are deliberately **not** audited — they're performance, not security; they live only in the harden plan.

- [ ] **Step 1: Update fixtures and write failing tests**

First run `grep -n "CloudflareZoneState(" Tests/AnglesiteCoreTests/SecurityAuditTests.swift` and, in every fixture the tests expect to produce **zero** findings, append the new fields:

```swift
            speedBrain: true, ech: true, zstdCompression: true,
            pageShield: .init(enabled: true, scriptHosts: [])
```

Then append tests:

```swift
    @Test("ECH off yields an info finding")
    func echOffInfo() {
        var state = clean()  // use the file's existing fully-clean fixture name
        state.ech = false
        let findings = SecurityAudit.evaluate(state, expectsMail: true)
        #expect(findings.contains { $0.title.contains("Encrypted Client Hello") && $0.severity == .info })
    }

    @Test("Page Shield disabled yields an info finding")
    func pageShieldOffInfo() {
        var state = clean()
        state.pageShield = nil
        let findings = SecurityAudit.evaluate(state, expectsMail: true)
        #expect(findings.contains { $0.title.contains("script monitoring") })
    }

    @Test("detected third-party scripts are surfaced with their hosts")
    func pageShieldScriptsSurfaced() {
        var state = clean()
        state.pageShield = .init(enabled: true, scriptHosts: ["cdn.evil.example"])
        let findings = SecurityAudit.evaluate(state, expectsMail: true)
        let finding = findings.first { $0.title.contains("Third-party scripts") }
        #expect(finding != nil)
        #expect(finding?.detail.contains("cdn.evil.example") == true)
    }
```

(If the file's clean-state fixture has a different name, keep that name — only the field additions matter.)

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SecurityAuditTests`
Expected: FAIL — new tests fail (no such findings yet); pre-existing tests pass.

- [ ] **Step 3: Add the findings** (in `SecurityAudit.evaluate`, before `return findings`)

```swift
        if !state.ech {
            add(.info, "Encrypted Client Hello is off",
                "Without ECH, the site hostname is visible in plaintext during TLS handshakes.",
                "Enable Encrypted Client Hello (ECH) in the zone's TLS settings.")
        }
        if state.pageShield?.enabled != true {
            add(.info, "Client-side script monitoring is off",
                "Page Shield is not watching which scripts run on the site, so a compromised third-party script would go unnoticed.",
                "Enable Page Shield's script monitor (free on all plans).")
        } else if let shield = state.pageShield, !shield.scriptHosts.isEmpty {
            add(.info, "Third-party scripts detected",
                "Page Shield sees scripts loading from: \(shield.scriptHosts.joined(separator: ", ")).",
                "Review each host; remove any you don't recognize and keep the CSP in sync.")
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SecurityAuditTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SecurityAudit.swift Tests/AnglesiteCoreTests/SecurityAuditTests.swift
git commit -m "feat(#59): audit ECH and Page Shield script-monitor state

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Full verification + app build + wrap-up

**Files:** none new.

- [ ] **Step 1: Full SwiftPM suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: PASS, zero failures. (If it hangs with no output: `pgrep -fl swift-test` and kill the orphan holding the `.build` lock.)

- [ ] **Step 2: App target builds** (CloudflareTokenPromptView changed)

```bash
ANGLESITE_PLUGIN_SRC=../../../../../anglesite scripts/copy-plugin.sh   # populate gitignored Resources/plugin (adjust path to the real plugin checkout: …/github.com/Anglesite/anglesite)
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: `BUILD SUCCEEDED`. (If "Too many levels of symbolic links": remove the self-pointing `Resources/plugin` symlink and re-run copy-plugin.sh.)

- [ ] **Step 3: Verify the docs stay honest**

The spec §4 says capabilities are "persisted alongside the token reference". This plan lands probe-on-demand with `Codable` types and **defers persistence to the first consumer slice** (YAGNI — nothing reads a stored value yet). Add one line to the spec's §4 noting persistence lands with Slice 1, and commit:

```bash
git add docs/superpowers/specs/2026-07-04-cloudflare-free-services-integration-design.md
git commit -m "docs: note capability persistence lands with the first consumer slice

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Finish the branch**

Invoke the superpowers:finishing-a-development-branch skill (merge vs PR decision, per repo convention: PR to `main` via `gh`). Remember: push before citing the PR.

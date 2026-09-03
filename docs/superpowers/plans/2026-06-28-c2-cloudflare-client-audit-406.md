# CloudflareClient Seam + Security Audit (Layer C2 core) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only Cloudflare API seam and a pure security-audit evaluator to `AnglesiteCore` — fetch a zone's security-relevant edge/DNS state and grade it into `AuditReport.Finding`s — with no UI and no account writes.

**Architecture:** A `CloudflareReading` protocol with an injectable `Transport` closure (mirroring the existing `CloudflareAPITokenVerifier`), a concrete `HTTPCloudflareClient` that reads Cloudflare v4 endpoints and assembles a `CloudflareZoneState` snapshot, and a pure `SecurityAudit.evaluate(_:expectsMail:)` that maps that snapshot to `[AuditReport.Finding]` (category `.security`). All in `AnglesiteCore`, fully covered by `swift test` via a fake transport with canned JSON fixtures. No SwiftUI, no Keychain, no writes.

**Tech Stack:** Swift 6 / Swift Testing (`import Testing`, `@Test`, `#expect`). `URLSession` via an injected `Transport` typealias. `Codable` for decoding. Tests run with `swift test --package-path .` (see CLAUDE.md `DEVELOPER_DIR` note).

**Issue:** [#406](https://github.com/Anglesite/Anglesite-app/issues/406) — sub-issue C2 of epic [#402](https://github.com/Anglesite/Anglesite-app/issues/402). Spec: [`docs/superpowers/specs/2026-06-27-security-story-hardening-design.md`](../specs/2026-06-27-security-story-hardening-design.md) §"C2".

## Scope

This plan is the **CI-testable core** of C2. Two pieces of the spec's C2 are deliberately deferred to their own follow-up plans so this one stays bounded and fully testable:

- **Bot Fight Mode read + WAF custom-rules listing** — the `bot_management` GET and the rulesets API (`http_request_firewall_custom` phase) have free-plan permission and shape uncertainties, and pair more naturally with C3's Harden action. Out of scope here.
- **The scorecard SwiftUI surface** — a thin app-target view modeled on `AuditModel`/`AuditSheetView`. Out of scope here (a separate small plan); this plan stops at producing `[AuditReport.Finding]`.

## Global Constraints

- **Swift 6, ES-equivalent module style** — `public` API in `AnglesiteCore`; `Sendable` everywhere; no third-party dependencies (Foundation `URLSession` only).
- **Read-only** — every method is a GET. No write/PATCH/POST/PUT/DELETE anywhere in this plan. The documented token scope for audit is read-only: Zone Read, DNS Read, Zone Settings Read. (C3 adds write scope: Zone DNS Edit, Zone Settings Edit, WAF Edit.)
- **No Keychain, no SwiftUI in `AnglesiteCore`** — the API token is passed in as a `String` parameter (the caller reads `KeychainStore().readCloudflareToken()`; that wiring is the deferred UI plan). Mirror `CloudflareAPITokenVerifier`, which also takes the token as a parameter.
- **Mirror existing patterns exactly:**
  - Seam: `public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)` with `static let defaultTransport` using `URLSession.shared.data(for:)` — copied from `Sources/AnglesiteCore/CloudflareAPITokenVerifier.swift`.
  - Findings: reuse the existing `AuditReport.Finding` (`Sources/AnglesiteCore/AuditReport.swift`) with `category: .security` and `Severity` ∈ `{critical, warning, info}`. Do **not** invent a new findings type.
  - Base URL: `https://api.cloudflare.com/client/v4`.
  - Envelope: every response is `{ "success": Bool, "errors": [...], "messages": [...], "result": <T> }`. Decode a generic `CFEnvelope<T: Decodable & Sendable>` once and reuse it.
  - Status handling: treat non-2xx as an error (`CloudflareError.http(status:)`); `401/403` → `.unauthorized` (copy the `CloudflareWebAnalyticsClient` convention).
- **API field names** follow Cloudflare's documented v4 response shapes; the fake-transport **fixtures in the tests encode the decoding contract**. When this is later wired to the live API, verify each fixture against a real response (`curl -H "Authorization: Bearer $TOKEN" …`) and adjust if Cloudflare's shape differs.
- **Swift Testing** (`@Test`/`#expect`), new tests in `Tests/AnglesiteCoreTests/`. No XCTest.
- **Work in a git worktree** branched off `main`; do not commit on the main checkout.
- **Run `swift test` before pushing** with `DEVELOPER_DIR` set per project memory (default CommandLineTools swift is too old). Filter to the new suites while iterating: `swift test --filter CloudflareClientTests --filter SecurityAuditTests`.

## File Structure

- `Sources/AnglesiteCore/CloudflareZoneState.swift` — the snapshot value type (Task 1).
- `Sources/AnglesiteCore/CloudflareReading.swift` — protocol + `Transport` typealias + `CloudflareError` (Task 1).
- `Sources/AnglesiteCore/HTTPCloudflareClient.swift` — concrete client: zone resolution (Task 2) + `zoneState` assembly (Task 3).
- `Sources/AnglesiteCore/SecurityAudit.swift` — pure evaluator (Task 4).
- `Tests/AnglesiteCoreTests/CloudflareClientTests.swift` — Tasks 2–3.
- `Tests/AnglesiteCoreTests/SecurityAuditTests.swift` — Task 4.

---

### Task 1: Snapshot type + reading seam

**Files:**
- Create: `Sources/AnglesiteCore/CloudflareZoneState.swift`
- Create: `Sources/AnglesiteCore/CloudflareReading.swift`
- Test: `Tests/AnglesiteCoreTests/CloudflareClientTests.swift`

**Interfaces:**
- Produces: `CloudflareZoneState` (Sendable, Equatable) with nested `HSTS`; `protocol CloudflareReading: Sendable`; `typealias Transport`; `enum CloudflareError: Error, Equatable`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/CloudflareClientTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct CloudflareClientTests {
    @Test("CloudflareZoneState is value-equal by field")
    func zoneStateEquatable() {
        let a = CloudflareZoneState(
            dnssecActive: true, sslMode: "strict", alwaysUseHTTPS: true,
            hsts: .init(maxAge: 31_536_000, includeSubdomains: true, preload: false),
            caaRecords: ["0 issue \"letsencrypt.org\""], mxRecords: [],
            spfRecords: ["v=spf1 -all"], dmarcRecords: ["v=DMARC1; p=reject"])
        let b = a
        #expect(a == b)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --filter CloudflareClientTests`
Expected: FAIL — `CloudflareZoneState` is not defined (compile error).

- [ ] **Step 3: Create `CloudflareZoneState`**

Create `Sources/AnglesiteCore/CloudflareZoneState.swift`:

```swift
import Foundation

/// A read-only snapshot of a Cloudflare zone's security-relevant edge/DNS state.
/// Assembled by `HTTPCloudflareClient.zoneState` and graded by `SecurityAudit`.
public struct CloudflareZoneState: Sendable, Equatable {
    /// HSTS edge setting (Zone Settings → security_header). `nil` when disabled.
    public struct HSTS: Sendable, Equatable {
        public var maxAge: Int
        public var includeSubdomains: Bool
        public var preload: Bool
        public init(maxAge: Int, includeSubdomains: Bool, preload: Bool) {
            self.maxAge = maxAge
            self.includeSubdomains = includeSubdomains
            self.preload = preload
        }
    }

    public var dnssecActive: Bool
    /// SSL/TLS encryption mode: "off" | "flexible" | "full" | "strict".
    public var sslMode: String
    public var alwaysUseHTTPS: Bool
    public var hsts: HSTS?
    /// Raw record contents (`content` field) for the relevant DNS types.
    public var caaRecords: [String]
    public var mxRecords: [String]
    /// TXT records whose content starts with `v=spf1`.
    public var spfRecords: [String]
    /// TXT records at `_dmarc.<zone>` whose content starts with `v=DMARC1`.
    public var dmarcRecords: [String]

    public init(dnssecActive: Bool, sslMode: String, alwaysUseHTTPS: Bool, hsts: HSTS?,
                caaRecords: [String], mxRecords: [String], spfRecords: [String], dmarcRecords: [String]) {
        self.dnssecActive = dnssecActive
        self.sslMode = sslMode
        self.alwaysUseHTTPS = alwaysUseHTTPS
        self.hsts = hsts
        self.caaRecords = caaRecords
        self.mxRecords = mxRecords
        self.spfRecords = spfRecords
        self.dmarcRecords = dmarcRecords
    }
}
```

- [ ] **Step 4: Create the reading seam**

Create `Sources/AnglesiteCore/CloudflareReading.swift`:

```swift
import Foundation

/// Errors surfaced by the Cloudflare read client.
public enum CloudflareError: Error, Equatable, Sendable {
    case unauthorized
    case http(status: Int)
    case api(message: String)
    case malformedResponse
    case zoneNotFound(domain: String)
}

/// Read-only Cloudflare API seam. The concrete `HTTPCloudflareClient` talks to the
/// v4 REST API; tests provide a fake. Token is passed per call (no Keychain coupling).
public protocol CloudflareReading: Sendable {
    /// Resolve a zone's id from its apex domain, or nil if the token can't see it.
    func resolveZoneID(domain: String, apiToken: String) async throws -> String?
    /// Fetch the security-relevant state for a zone.
    func zoneState(zoneID: String, apiToken: String) async throws -> CloudflareZoneState
}

/// Injectable HTTP boundary — identical shape to `CloudflareAPITokenVerifier.Transport`.
public typealias CloudflareTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --package-path . --filter CloudflareClientTests`
Expected: PASS — `zoneStateEquatable` passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/CloudflareZoneState.swift Sources/AnglesiteCore/CloudflareReading.swift Tests/AnglesiteCoreTests/CloudflareClientTests.swift
git commit -m "feat(#406): add CloudflareZoneState snapshot + read seam

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Zone resolution

**Files:**
- Create: `Sources/AnglesiteCore/HTTPCloudflareClient.swift`
- Test: `Tests/AnglesiteCoreTests/CloudflareClientTests.swift`

**Interfaces:**
- Consumes: `CloudflareReading`, `CloudflareTransport`, `CloudflareError` (Task 1).
- Produces: `struct HTTPCloudflareClient: CloudflareReading` with `init(transport: CloudflareTransport = HTTPCloudflareClient.defaultTransport)` and `static let defaultTransport`. Implements `resolveZoneID`. (`zoneState` lands in Task 3.)

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/CloudflareClientTests.swift`:

```swift
/// A fake transport that routes by URL substring to canned (Data, HTTPURLResponse).
func fakeTransport(_ routes: [String: (Int, String)]) -> CloudflareTransport {
    return { request in
        let url = request.url!.absoluteString
        for (needle, pair) in routes where url.contains(needle) {
            let resp = HTTPURLResponse(url: request.url!, statusCode: pair.0,
                                       httpVersion: nil, headerFields: nil)!
            return (Data(pair.1.utf8), resp)
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        return (Data("{\"success\":false}".utf8), resp)
    }
}

@Test("resolveZoneID returns the id of the matching active zone")
func resolveZoneIDFound() async throws {
    let json = """
    {"success":true,"errors":[],"messages":[],"result":[{"id":"zone123","name":"example.com","status":"active"}]}
    """
    let client = HTTPCloudflareClient(transport: fakeTransport(["/zones?": (200, json)]))
    let id = try await client.resolveZoneID(domain: "example.com", apiToken: "t")
    #expect(id == "zone123")
}

@Test("resolveZoneID returns nil when no zone matches")
func resolveZoneIDMissing() async throws {
    let json = "{\"success\":true,\"errors\":[],\"messages\":[],\"result\":[]}"
    let client = HTTPCloudflareClient(transport: fakeTransport(["/zones?": (200, json)]))
    let id = try await client.resolveZoneID(domain: "absent.com", apiToken: "t")
    #expect(id == nil)
}

@Test("a 403 surfaces as .unauthorized")
func unauthorizedMaps() async {
    let client = HTTPCloudflareClient(transport: fakeTransport(["/zones?": (403, "{\"success\":false}")]))
    await #expect(throws: CloudflareError.unauthorized) {
        _ = try await client.resolveZoneID(domain: "example.com", apiToken: "bad")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter CloudflareClientTests`
Expected: FAIL — `HTTPCloudflareClient` is not defined.

- [ ] **Step 3: Create `HTTPCloudflareClient` with the envelope, request helper, and `resolveZoneID`**

Create `Sources/AnglesiteCore/HTTPCloudflareClient.swift`:

```swift
import Foundation

/// Standard Cloudflare v4 response envelope.
private struct CFEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let success: Bool
    let result: T?
    struct APIError: Decodable, Sendable { let message: String }
    let errors: [APIError]?
}

private struct CFZone: Decodable, Sendable {
    let id: String
    let name: String
    let status: String
}

/// Read-only Cloudflare v4 client. All methods are GETs.
public struct HTTPCloudflareClient: CloudflareReading {
    private static let base = "https://api.cloudflare.com/client/v4"
    private let transport: CloudflareTransport

    public init(transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport) {
        self.transport = transport
    }

    public static let defaultTransport: CloudflareTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudflareError.malformedResponse }
        return (data, http)
    }

    /// GET `path`, decode `CFEnvelope<T>`, return `result` or throw a mapped error.
    private func get<T: Decodable & Sendable>(_ path: String, apiToken: String, as: T.Type) async throws -> T {
        guard let url = URL(string: Self.base + path) else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, http) = try await transport(request)
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
        let env = try JSONDecoder().decode(CFEnvelope<T>.self, from: data)
        guard env.success, let result = env.result else {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "request failed")
        }
        return result
    }

    public func resolveZoneID(domain: String, apiToken: String) async throws -> String? {
        let escaped = domain.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? domain
        let zones = try await get("/zones?name=\(escaped)&status=active", apiToken: apiToken, as: [CFZone].self)
        return zones.first(where: { $0.name == domain })?.id
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter CloudflareClientTests`
Expected: PASS — all three `resolveZoneID`/unauthorized tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/HTTPCloudflareClient.swift Tests/AnglesiteCoreTests/CloudflareClientTests.swift
git commit -m "feat(#406): HTTPCloudflareClient with zone resolution

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Assemble the zone-state snapshot

**Files:**
- Modify: `Sources/AnglesiteCore/HTTPCloudflareClient.swift` (add `zoneState` + decode structs)
- Test: `Tests/AnglesiteCoreTests/CloudflareClientTests.swift`

**Interfaces:**
- Consumes: the `get` helper from Task 2.
- Produces: `func zoneState(zoneID:apiToken:) async throws -> CloudflareZoneState` reading 5 endpoints: `/zones/{id}/dnssec`, `/zones/{id}/settings/ssl`, `/zones/{id}/settings/always_use_https`, `/zones/{id}/settings/security_header`, `/zones/{id}/dns_records?per_page=100`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/CloudflareClientTests.swift`:

```swift
@Test("zoneState assembles DNSSEC, settings, and DNS records")
func zoneStateAssembles() async throws {
    let env = { (r: String) in "{\"success\":true,\"errors\":[],\"messages\":[],\"result\":\(r)}" }
    let routes: [String: (Int, String)] = [
        "/dnssec": (200, env("{\"status\":\"active\"}")),
        "/settings/ssl": (200, env("{\"id\":\"ssl\",\"value\":\"strict\"}")),
        "/settings/always_use_https": (200, env("{\"id\":\"always_use_https\",\"value\":\"on\"}")),
        "/settings/security_header": (200, env("{\"id\":\"security_header\",\"value\":{\"strict_transport_security\":{\"enabled\":true,\"max_age\":31536000,\"include_subdomains\":true,\"preload\":false}}}")),
        "/dns_records": (200, env("[{\"type\":\"CAA\",\"name\":\"example.com\",\"content\":\"0 issue \\\"letsencrypt.org\\\"\"},{\"type\":\"TXT\",\"name\":\"example.com\",\"content\":\"v=spf1 -all\"},{\"type\":\"TXT\",\"name\":\"_dmarc.example.com\",\"content\":\"v=DMARC1; p=reject\"}]")),
    ]
    let client = HTTPCloudflareClient(transport: fakeTransport(routes))
    let s = try await client.zoneState(zoneID: "z", apiToken: "t")
    #expect(s.dnssecActive)
    #expect(s.sslMode == "strict")
    #expect(s.alwaysUseHTTPS)
    #expect(s.hsts == CloudflareZoneState.HSTS(maxAge: 31536000, includeSubdomains: true, preload: false))
    #expect(s.caaRecords == ["0 issue \"letsencrypt.org\""])
    #expect(s.spfRecords == ["v=spf1 -all"])
    #expect(s.dmarcRecords == ["v=DMARC1; p=reject"])
    #expect(s.mxRecords.isEmpty)
}

@Test("HSTS disabled yields nil hsts")
func zoneStateHSTSDisabled() async throws {
    let env = { (r: String) in "{\"success\":true,\"errors\":[],\"messages\":[],\"result\":\(r)}" }
    let routes: [String: (Int, String)] = [
        "/dnssec": (200, env("{\"status\":\"disabled\"}")),
        "/settings/ssl": (200, env("{\"id\":\"ssl\",\"value\":\"full\"}")),
        "/settings/always_use_https": (200, env("{\"id\":\"always_use_https\",\"value\":\"off\"}")),
        "/settings/security_header": (200, env("{\"id\":\"security_header\",\"value\":{\"strict_transport_security\":{\"enabled\":false}}}")),
        "/dns_records": (200, env("[]")),
    ]
    let client = HTTPCloudflareClient(transport: fakeTransport(routes))
    let s = try await client.zoneState(zoneID: "z", apiToken: "t")
    #expect(!s.dnssecActive)
    #expect(s.hsts == nil)
    #expect(s.caaRecords.isEmpty)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter CloudflareClientTests`
Expected: FAIL — `zoneState` is not a member of `HTTPCloudflareClient`.

- [ ] **Step 3: Add decode structs + `zoneState`**

In `Sources/AnglesiteCore/HTTPCloudflareClient.swift`, add these private decode types (after `CFZone`):

```swift
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
```

Then add the method to `HTTPCloudflareClient`:

```swift
    public func zoneState(zoneID: String, apiToken: String) async throws -> CloudflareZoneState {
        let dnssec = try await get("/zones/\(zoneID)/dnssec", apiToken: apiToken, as: CFDNSSEC.self)
        let ssl = try await get("/zones/\(zoneID)/settings/ssl", apiToken: apiToken, as: CFStringSetting.self)
        let https = try await get("/zones/\(zoneID)/settings/always_use_https", apiToken: apiToken, as: CFStringSetting.self)
        let header = try await get("/zones/\(zoneID)/settings/security_header", apiToken: apiToken, as: CFSecurityHeader.self)
        let records = try await get("/zones/\(zoneID)/dns_records?per_page=100", apiToken: apiToken, as: [CFDNSRecord].self)

        let sts = header.value.strict_transport_security
        let hsts: CloudflareZoneState.HSTS? = sts.enabled
            ? .init(maxAge: sts.max_age ?? 0, includeSubdomains: sts.include_subdomains ?? false, preload: sts.preload ?? false)
            : nil

        func contents(ofType t: String) -> [String] {
            records.filter { $0.type.uppercased() == t }.map(\.content)
        }
        let txt = records.filter { $0.type.uppercased() == "TXT" }
        let spf = txt.filter { $0.content.lowercased().hasPrefix("v=spf1") }.map(\.content)
        let dmarc = txt.filter { $0.name.lowercased().hasPrefix("_dmarc.") && $0.content.lowercased().hasPrefix("v=dmarc1") }.map(\.content)

        return CloudflareZoneState(
            dnssecActive: dnssec.status.lowercased() == "active",
            sslMode: ssl.value,
            alwaysUseHTTPS: https.value.lowercased() == "on",
            hsts: hsts,
            caaRecords: contents(ofType: "CAA"),
            mxRecords: contents(ofType: "MX"),
            spfRecords: spf,
            dmarcRecords: dmarc)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter CloudflareClientTests`
Expected: PASS — both `zoneState` tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/HTTPCloudflareClient.swift Tests/AnglesiteCoreTests/CloudflareClientTests.swift
git commit -m "feat(#406): zoneState reads DNSSEC, SSL/HTTPS/HSTS settings, DNS records

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: SecurityAudit evaluator

**Files:**
- Create: `Sources/AnglesiteCore/SecurityAudit.swift`
- Test: `Tests/AnglesiteCoreTests/SecurityAuditTests.swift`

**Interfaces:**
- Consumes: `CloudflareZoneState` (Task 1), `AuditReport.Finding` (existing, `Sources/AnglesiteCore/AuditReport.swift`).
- Produces: `enum SecurityAudit { static func evaluate(_ state: CloudflareZoneState, expectsMail: Bool) -> [AuditReport.Finding] }`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/SecurityAuditTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

struct SecurityAuditTests {
    private func clean() -> CloudflareZoneState {
        CloudflareZoneState(
            dnssecActive: true, sslMode: "strict", alwaysUseHTTPS: true,
            hsts: .init(maxAge: 31_536_000, includeSubdomains: true, preload: false),
            caaRecords: ["0 issue \"letsencrypt.org\""], mxRecords: [],
            spfRecords: ["v=spf1 -all"], dmarcRecords: ["v=DMARC1; p=reject"])
    }

    @Test("a fully hardened non-mail zone yields no findings")
    func cleanZoneNoFindings() {
        #expect(SecurityAudit.evaluate(clean(), expectsMail: false).isEmpty)
    }

    @Test("DNSSEC disabled is a warning")
    func dnssecWarning() {
        var s = clean(); s.dnssecActive = false
        let f = SecurityAudit.evaluate(s, expectsMail: false)
        #expect(f.contains { $0.severity == .warning && $0.title.contains("DNSSEC") })
    }

    @Test("weak SSL mode is critical")
    func sslCritical() {
        var s = clean(); s.sslMode = "flexible"
        let f = SecurityAudit.evaluate(s, expectsMail: false)
        #expect(f.contains { $0.severity == .critical && $0.title.contains("SSL") })
    }

    @Test("missing HSTS and Always-Use-HTTPS each warn")
    func httpsWarnings() {
        var s = clean(); s.hsts = nil; s.alwaysUseHTTPS = false
        let f = SecurityAudit.evaluate(s, expectsMail: false)
        #expect(f.contains { $0.title.contains("HSTS") })
        #expect(f.contains { $0.title.contains("HTTPS") })
    }

    @Test("missing CAA is an info finding")
    func caaInfo() {
        var s = clean(); s.caaRecords = []
        let f = SecurityAudit.evaluate(s, expectsMail: false)
        #expect(f.contains { $0.severity == .info && $0.title.contains("CAA") })
    }

    @Test("non-mail zone without SPF -all / DMARC reject warns on spoofing")
    func emailWarnings() {
        var s = clean(); s.spfRecords = []; s.dmarcRecords = []
        let f = SecurityAudit.evaluate(s, expectsMail: false)
        #expect(f.contains { $0.title.contains("SPF") })
        #expect(f.contains { $0.title.contains("DMARC") })
    }

    @Test("a mail-sending zone is not warned for absent SPF/DMARC by this audit")
    func mailZoneSkipsEmailHardening() {
        var s = clean(); s.spfRecords = []; s.dmarcRecords = []
        let f = SecurityAudit.evaluate(s, expectsMail: true)
        #expect(!f.contains { $0.title.contains("SPF") })
    }

    @Test("every finding is in the security category")
    func allSecurityCategory() {
        var s = clean(); s.dnssecActive = false; s.sslMode = "off"
        #expect(SecurityAudit.evaluate(s, expectsMail: false).allSatisfy { $0.category == .security })
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter SecurityAuditTests`
Expected: FAIL — `SecurityAudit` is not defined.

- [ ] **Step 3: Implement `SecurityAudit`**

Create `Sources/AnglesiteCore/SecurityAudit.swift`:

```swift
import Foundation

/// Pure evaluator: grades a `CloudflareZoneState` into security findings. Read-only,
/// no I/O — it never fixes anything. Findings reuse the shared `AuditReport.Finding`
/// model (`category: .security`).
public enum SecurityAudit {
    public static func evaluate(_ state: CloudflareZoneState, expectsMail: Bool) -> [AuditReport.Finding] {
        var findings: [AuditReport.Finding] = []
        func add(_ severity: AuditReport.Finding.Severity, _ title: String, _ detail: String, _ remediation: String) {
            findings.append(.init(category: .security, severity: severity, title: title,
                                  detail: detail, remediation: remediation, location: nil))
        }

        if !state.dnssecActive {
            add(.warning, "DNSSEC is not active",
                "DNSSEC is disabled, leaving DNS responses unauthenticated.",
                "Enable DNSSEC for the zone and publish the DS record at your registrar.")
        }
        if !["full", "strict"].contains(state.sslMode.lowercased()) {
            add(.critical, "Weak SSL/TLS mode (\(state.sslMode))",
                "SSL mode \"\(state.sslMode)\" allows unencrypted or unauthenticated origin connections.",
                "Set the zone's SSL/TLS mode to Full (strict).")
        }
        if !state.alwaysUseHTTPS {
            add(.warning, "Always Use HTTPS is off",
                "Visitors can reach the site over plaintext HTTP.",
                "Enable Always Use HTTPS so HTTP requests are redirected to HTTPS.")
        }
        if state.hsts == nil {
            add(.warning, "HSTS is not enabled",
                "Without HSTS, browsers may downgrade to HTTP on the first visit.",
                "Enable HTTP Strict Transport Security (max-age ≥ 1 year, includeSubDomains).")
        } else if let h = state.hsts, h.maxAge < 31_536_000 {
            add(.warning, "HSTS max-age is short (\(h.maxAge)s)",
                "An HSTS max-age under one year weakens downgrade protection.",
                "Raise HSTS max-age to at least 31536000 (one year).")
        }
        if state.caaRecords.isEmpty {
            add(.info, "No CAA records",
                "Any certificate authority can issue certificates for this domain.",
                "Add CAA records authorizing only your CA(s) to limit mis-issuance.")
        }
        if !expectsMail {
            if !state.spfRecords.contains(where: { $0.lowercased().contains("-all") }) {
                add(.warning, "No strict SPF record",
                    "A domain that does not send mail should publish SPF \"v=spf1 -all\" to block spoofing.",
                    "Publish a TXT record: v=spf1 -all")
            }
            if !state.dmarcRecords.contains(where: { $0.lowercased().contains("p=reject") }) {
                add(.warning, "No DMARC reject policy",
                    "Without DMARC p=reject, spoofed mail claiming to be from this domain is not blocked.",
                    "Publish _dmarc TXT: v=DMARC1; p=reject")
            }
        }
        return findings
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter SecurityAuditTests`
Expected: PASS — all eight `SecurityAuditTests` pass.

- [ ] **Step 5: Run both new suites + confirm no regressions in AnglesiteCore**

Run: `swift test --package-path . --filter CloudflareClientTests --filter SecurityAuditTests`
Expected: PASS — all new tests green.

Run: `swift test --package-path .`
Expected: PASS — the full `AnglesiteCore` suite still passes (the new files add API only; nothing existing changed). Set `DEVELOPER_DIR` per project memory; if MCP e2e suites fail for lack of `ANGLESITE_PLUGIN_PATH`, that is pre-existing and unrelated — re-run with `--filter CloudflareClientTests --filter SecurityAuditTests` to confirm this plan's suites are green.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/SecurityAudit.swift Tests/AnglesiteCoreTests/SecurityAuditTests.swift
git commit -m "feat(#406): SecurityAudit grades zone state into AuditReport findings

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage** (spec §C2): `CloudflareClient` seam ✅ Tasks 1–3 (read-only; token as parameter; minimal documented scope in Global Constraints). Read methods — DNSSEC ✅, SSL/Always-HTTPS/HSTS ✅, CAA/MX/SPF/DMARC ✅ (Task 3); **Bot Fight Mode + WAF custom-rule listing are explicitly deferred** (Scope section) — a noted gap, not silently dropped. `SecurityAudit` pure + graded findings reusing the `AuditReport` model ✅ Task 4; "never auto-fixes" ✅ (no writes anywhere). The **scorecard UI + drift reporting** is explicitly deferred to a follow-up plan (Scope) — this plan stops at `[AuditReport.Finding]`.

**Placeholder scan:** no TBD/TODO; every code step shows complete code; every run step has an exact command and expected result. The one externally-dependent risk (exact Cloudflare JSON field names) is handled explicitly: fixtures encode the contract and Global Constraints require verifying them against a live response when wiring the UI.

**Type consistency:** `CloudflareReading`, `CloudflareTransport`, `CloudflareError`, `CloudflareZoneState` (+ nested `HSTS`), `HTTPCloudflareClient`, and `SecurityAudit.evaluate(_:expectsMail:)` are used with identical names/signatures across tasks and tests. `AuditReport.Finding`'s initializer (`category/severity/title/detail/remediation/location`) matches the existing type in `Sources/AnglesiteCore/AuditReport.swift`. The `get<T>` helper defined in Task 2 is reused unchanged in Task 3.

# Domain (DNS) Integration Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the plugin's `domain` skill (view/add/delete DNS records, Bluesky + Google verification) to a deterministic Swift App Intent + GUI wizard, per #462.

**Architecture:** A new `DomainOperationsService` protocol in `AnglesiteCore` centralizes Cloudflare token lookup + zone resolution + list/add/delete DNS record calls (mirroring `IntegrationOperationsService`'s role). A thin `DomainModel` (`AnglesiteApp`, `@Observable`) drives a `DomainSheetView`, both modeled directly on the existing `HardenModel`/`HardenSheetView`. Three new `AnglesiteIntents` (`ListDNSRecordsIntent`, `AddDNSRecordIntent`, `DeleteDNSRecordIntent`) consume the same `DomainOperationsService`, giving Siri/Shortcuts parity with the GUI for free.

**Tech Stack:** Swift 6.4, SwiftUI, Swift Testing (`import Testing`, not XCTest), Apple `AppIntents`, Cloudflare v4 REST API.

**Spec:** [`docs/superpowers/specs/2026-07-05-domain-dns-integration-design.md`](../specs/2026-07-05-domain-dns-integration-design.md)

## Global Constraints

- Toolchain: Xcode 27+ / Swift 6.4 — `DEVELOPER_DIR` must point at the Xcode-beta toolchain for `swift test` to work (see project memory: default CommandLineTools swift is too old).
- New test files use Swift Testing (`import Testing`, `@Test`, `#expect`), matching every existing test file touched by this plan — no XCTest.
- `AnglesiteCore` and `AnglesiteIntents` are SwiftPM library targets — verify with `swift test --package-path .`. `AnglesiteApp` is **not** a SwiftPM target (Xcode-only); its tasks are verified with `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`, and (matching `HardenModel`/`HardenSheetView`, which also have no direct unit tests) are not unit-tested directly — their logic is a thin pass-through to the tested `AnglesiteCore` service.
- If working in a fresh worktree and `Anglesite.xcodeproj` doesn't exist yet, run `xcodegen generate` first, and set `ANGLESITE_PLUGIN_SRC` to the sibling `anglesite` checkout before running `scripts/copy-plugin.sh` (needed once for `xcodebuild` to succeed at all).
- Every new/changed public type in `AnglesiteCore`/`AnglesiteIntents` must be `Sendable`.
- Commit after each task with a `feat(#462): ...` or `test(#462): ...` message, per this repo's conventional-commit style.

---

### Task 1: `DNSRecord` read model + `listDNSRecords`/`deleteDNSRecord` on the Cloudflare client seam

**Files:**
- Modify: `Sources/AnglesiteCore/CloudflareReading.swift`
- Modify: `Sources/AnglesiteCore/CloudflareWriting.swift`
- Modify: `Sources/AnglesiteCore/HTTPCloudflareClient.swift`
- Modify: `Tests/AnglesiteCoreTests/HardenExecutorTests.swift:111-181` (mock conformers)
- Test: `Tests/AnglesiteCoreTests/DomainDNSClientTests.swift` (new)

**Interfaces:**
- Produces: `public struct DNSRecord: Sendable, Equatable, Identifiable { let id, type, name, content: String; let ttl: Int; let proxied: Bool }`
- Produces: `CloudflareReading.listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord]`
- Produces: `CloudflareWriting.deleteDNSRecord(zoneID: String, recordID: String, apiToken: String) async throws`
- Consumes (test-only): top-level `fakeTransport(_:)` / `spyTransport(_:spy:)` / `TransportSpy` already defined in `Tests/AnglesiteCoreTests/CloudflareClientTests.swift` (same test target, no import needed).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/DomainDNSClientTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct DomainDNSClientTests {
    private let zoneID = "zone123"
    private let token = "test-token"

    @Test("listDNSRecords decodes id/type/name/content/ttl/proxied")
    func listDecodesFields() async throws {
        let json = """
        {"success":true,"errors":[],"result":[
            {"id":"rec1","type":"TXT","name":"_atproto.example.com","content":"did=did:plc:abc","ttl":1,"proxied":false},
            {"id":"rec2","type":"A","name":"example.com","content":"192.0.2.1","ttl":300,"proxied":true}
        ]}
        """
        let client = HTTPCloudflareClient(transport: fakeTransport(["/dns_records?per_page=100": (200, json)]))
        let records = try await client.listDNSRecords(zoneID: zoneID, apiToken: token)
        #expect(records.count == 2)
        #expect(records[0] == DNSRecord(id: "rec1", type: "TXT", name: "_atproto.example.com", content: "did=did:plc:abc", ttl: 1, proxied: false))
        #expect(records[1] == DNSRecord(id: "rec2", type: "A", name: "example.com", content: "192.0.2.1", ttl: 300, proxied: true))
    }

    @Test("listDNSRecords defaults proxied to false when absent")
    func listDefaultsProxied() async throws {
        let json = """
        {"success":true,"errors":[],"result":[
            {"id":"rec1","type":"MX","name":"example.com","content":"mail.example.com","ttl":3600}
        ]}
        """
        let client = HTTPCloudflareClient(transport: fakeTransport(["/dns_records?per_page=100": (200, json)]))
        let records = try await client.listDNSRecords(zoneID: zoneID, apiToken: token)
        #expect(records.first?.proxied == false)
    }

    @Test("listDNSRecords returns an empty array for a zone with no records")
    func listEmpty() async throws {
        let json = #"{"success":true,"errors":[],"result":[]}"#
        let client = HTTPCloudflareClient(transport: fakeTransport(["/dns_records?per_page=100": (200, json)]))
        let records = try await client.listDNSRecords(zoneID: zoneID, apiToken: token)
        #expect(records.isEmpty)
    }

    @Test("listDNSRecords maps a 401 to .unauthorized")
    func listUnauthorized() async {
        let client = HTTPCloudflareClient(transport: fakeTransport(["/dns_records?per_page=100": (401, "{\"success\":false}")]))
        await #expect(throws: CloudflareError.unauthorized) {
            try await client.listDNSRecords(zoneID: zoneID, apiToken: "bad")
        }
    }

    @Test("deleteDNSRecord sends DELETE to /zones/{id}/dns_records/{recordID}")
    func deleteSendsCorrectRequest() async throws {
        let spy = TransportSpy()
        let client = HTTPCloudflareClient(transport: spyTransport([:], spy: spy))
        try await client.deleteDNSRecord(zoneID: zoneID, recordID: "rec1", apiToken: token)
        let req = try #require(spy.requests.first)
        #expect(req.httpMethod == "DELETE")
        #expect(req.url?.path.hasSuffix("/zones/\(zoneID)/dns_records/rec1") == true)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }

    @Test("deleteDNSRecord maps a 404 to .http(status: 404)")
    func deleteNotFound() async {
        let client = HTTPCloudflareClient(transport: fakeTransport(["/dns_records/rec1": (404, "{\"success\":false}")]))
        await #expect(throws: CloudflareError.http(status: 404)) {
            try await client.deleteDNSRecord(zoneID: zoneID, recordID: "rec1", apiToken: token)
        }
    }

    @Test("deleteDNSRecord maps a 403 to .unauthorized")
    func deleteUnauthorized() async {
        let client = HTTPCloudflareClient(transport: fakeTransport(["/dns_records/rec1": (403, "{\"success\":false}")]))
        await #expect(throws: CloudflareError.unauthorized) {
            try await client.deleteDNSRecord(zoneID: zoneID, recordID: "rec1", apiToken: "bad")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter DomainDNSClientTests`
Expected: FAIL to compile — `listDNSRecords`/`deleteDNSRecord`/`DNSRecord` don't exist yet.

- [ ] **Step 3: Add `DNSRecord` and the protocol methods**

In `Sources/AnglesiteCore/CloudflareReading.swift`, after the `CloudflareError` enum (before the `CloudflareReading` protocol), add:

```swift
/// A single DNS record as returned by the Cloudflare API. Distinct from `DNSRecordPayload`
/// (write-only, no `id`/`proxied`) — this is the read-side shape used to list and display
/// existing records.
public struct DNSRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let type: String
    public let name: String
    public let content: String
    public let ttl: Int
    public let proxied: Bool
    public init(id: String, type: String, name: String, content: String, ttl: Int, proxied: Bool) {
        self.id = id
        self.type = type
        self.name = name
        self.content = content
        self.ttl = ttl
        self.proxied = proxied
    }
}
```

Then change the `CloudflareReading` protocol to:

```swift
public protocol CloudflareReading: Sendable {
    /// Resolve a zone's id from its apex domain, or nil if the token can't see it.
    func resolveZoneID(domain: String, apiToken: String) async throws -> String?
    /// Fetch the security-relevant state for a zone.
    func zoneState(zoneID: String, apiToken: String) async throws -> CloudflareZoneState
    /// Full DNS record listing for a zone — distinct from `zoneState`'s narrow security-relevant
    /// subset (CAA/MX/SPF/DMARC only). Used by the Domain DNS management feature.
    func listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord]
}
```

In `Sources/AnglesiteCore/CloudflareWriting.swift`, add to the `CloudflareWriting` protocol (after `addDNSRecord`):

```swift
    func addDNSRecord(zoneID: String, record: DNSRecordPayload, apiToken: String) async throws
    /// Delete a DNS record by its Cloudflare-assigned record id (from `listDNSRecords`).
    func deleteDNSRecord(zoneID: String, recordID: String, apiToken: String) async throws
```

- [ ] **Step 4: Implement in `HTTPCloudflareClient`**

In `Sources/AnglesiteCore/HTTPCloudflareClient.swift`, add a private decode struct near `CFDNSRecord` (the file already has one used only by `zoneState`'s narrower fields — leave that one as-is, add a new one for the full shape):

```swift
private struct CFFullDNSRecord: Decodable, Sendable {
    let id: String
    let type: String
    let name: String
    let content: String
    let ttl: Int
    let proxied: Bool?
}

/// Body for DELETE requests, which Cloudflare's API doesn't require but tolerates.
private struct CFEmptyBody: Encodable, Sendable {}
```

Add `listDNSRecords` to the `HTTPCloudflareClient` struct (read-only methods section, after `zoneState`):

```swift
    public func listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord] {
        let raw = try await get("/zones/\(zoneID)/dns_records?per_page=100", apiToken: apiToken, as: [CFFullDNSRecord].self)
        return raw.map {
            DNSRecord(id: $0.id, type: $0.type, name: $0.name, content: $0.content,
                      ttl: $0.ttl, proxied: $0.proxied ?? false)
        }
    }
```

Add `deleteDNSRecord` to the `CloudflareWriting` extension (after `addDNSRecord`):

```swift
    public func deleteDNSRecord(zoneID: String, recordID: String, apiToken: String) async throws {
        try await mutate(method: "DELETE", "/zones/\(zoneID)/dns_records/\(recordID)",
                         body: CFEmptyBody(), apiToken: apiToken)
    }
```

- [ ] **Step 5: Update the mock conformers so `HardenExecutorTests` still compiles**

In `Tests/AnglesiteCoreTests/HardenExecutorTests.swift`, add to `MockCloudflareReader` (after `zoneState`):

```swift
    func listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord] { [] }
```

Add to `MockCloudflareWriter` (after `addDNSRecord`):

```swift
    func deleteDNSRecord(zoneID: String, recordID: String, apiToken: String) async throws {
        try record("deleteDNSRecord:\(recordID)")
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --package-path . --filter DomainDNSClientTests`
Expected: PASS (all 7 tests)

Run: `swift test --package-path . --filter HardenExecutorTests`
Expected: PASS (unchanged — confirms the mock updates didn't break existing behavior)

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/CloudflareReading.swift Sources/AnglesiteCore/CloudflareWriting.swift \
        Sources/AnglesiteCore/HTTPCloudflareClient.swift Tests/AnglesiteCoreTests/HardenExecutorTests.swift \
        Tests/AnglesiteCoreTests/DomainDNSClientTests.swift
git commit -m "feat(#462): add listDNSRecords/deleteDNSRecord to the Cloudflare client seam"
```

---

### Task 2: `DNSRecordLabeler` — plain-English purpose labels

**Files:**
- Create: `Sources/AnglesiteCore/DNSRecordLabeler.swift`
- Test: `Tests/AnglesiteCoreTests/DNSRecordLabelerTests.swift`

**Interfaces:**
- Consumes: `DNSRecord` (Task 1).
- Produces: `public enum DNSRecordLabeler { public static func label(for record: DNSRecord) -> String }`

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/DNSRecordLabelerTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

struct DNSRecordLabelerTests {
    private func record(type: String, name: String, content: String = "x") -> DNSRecord {
        DNSRecord(id: "1", type: type, name: name, content: content, ttl: 1, proxied: false)
    }

    @Test("MX records are labeled Email routing")
    func mx() {
        #expect(DNSRecordLabeler.label(for: record(type: "MX", name: "example.com")) == "Email routing")
    }

    @Test("TXT records at _dmarc are labeled Spam prevention (DMARC)")
    func dmarc() {
        let r = record(type: "TXT", name: "_dmarc.example.com", content: "v=DMARC1; p=reject")
        #expect(DNSRecordLabeler.label(for: r) == "Spam prevention (DMARC)")
    }

    @Test("TXT records starting with v=spf1 are labeled Spam prevention (SPF)")
    func spf() {
        let r = record(type: "TXT", name: "example.com", content: "v=spf1 -all")
        #expect(DNSRecordLabeler.label(for: r) == "Spam prevention (SPF)")
    }

    @Test("TXT records at _atproto are labeled Bluesky verification")
    func bluesky() {
        let r = record(type: "TXT", name: "_atproto.example.com", content: "did=did:plc:abc")
        #expect(DNSRecordLabeler.label(for: r) == "Bluesky verification")
    }

    @Test("CNAME records to pages.dev or workers.dev are labeled Website")
    func website() {
        #expect(DNSRecordLabeler.label(for: record(type: "CNAME", name: "www.example.com", content: "foo.pages.dev")) == "Website")
        #expect(DNSRecordLabeler.label(for: record(type: "CNAME", name: "www.example.com", content: "foo.workers.dev")) == "Website")
    }

    @Test("A and AAAA records are labeled Website")
    func aRecords() {
        #expect(DNSRecordLabeler.label(for: record(type: "A", name: "example.com", content: "192.0.2.1")) == "Website")
        #expect(DNSRecordLabeler.label(for: record(type: "AAAA", name: "example.com", content: "::1")) == "Website")
    }

    @Test("unrecognized records fall back to Other")
    func fallback() {
        #expect(DNSRecordLabeler.label(for: record(type: "TXT", name: "random.example.com", content: "hello")) == "Other")
        #expect(DNSRecordLabeler.label(for: record(type: "SRV", name: "_sip._tcp.example.com")) == "Other")
    }

    @Test("label matching is case-insensitive on type and name")
    func caseInsensitive() {
        #expect(DNSRecordLabeler.label(for: record(type: "mx", name: "EXAMPLE.COM")) == "Email routing")
        #expect(DNSRecordLabeler.label(for: record(type: "txt", name: "_ATPROTO.example.com", content: "did=x")) == "Bluesky verification")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter DNSRecordLabelerTests`
Expected: FAIL to compile — `DNSRecordLabeler` doesn't exist yet.

- [ ] **Step 3: Implement `DNSRecordLabeler`**

Create `Sources/AnglesiteCore/DNSRecordLabeler.swift`:

```swift
/// Translates a raw DNS record into the plain-English purpose label shown in the Domain sheet's
/// record list — mirrors the `domain` plugin skill's "translate the output into plain English"
/// step. Order matters: more specific rules (DMARC/SPF/Bluesky) are checked before the generic
/// TXT fallback.
public enum DNSRecordLabeler {
    public static func label(for record: DNSRecord) -> String {
        let type = record.type.uppercased()
        let name = record.name.lowercased()
        let content = record.content.lowercased()

        switch type {
        case "MX":
            return "Email routing"
        case "TXT" where name.hasPrefix("_dmarc.") || name == "_dmarc":
            return "Spam prevention (DMARC)"
        case "TXT" where content.hasPrefix("v=spf1"):
            return "Spam prevention (SPF)"
        case "TXT" where name.hasPrefix("_atproto.") || name == "_atproto":
            return "Bluesky verification"
        case "CNAME" where content.contains(".pages.dev") || content.contains(".workers.dev"):
            return "Website"
        case "A", "AAAA":
            return "Website"
        default:
            return "Other"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter DNSRecordLabelerTests`
Expected: PASS (all 8 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DNSRecordLabeler.swift Tests/AnglesiteCoreTests/DNSRecordLabelerTests.swift
git commit -m "feat(#462): add DNSRecordLabeler for plain-English DNS record purposes"
```

---

### Task 3: `DomainOperationsService` — token lookup + zone resolution + list/add/delete

**Files:**
- Create: `Sources/AnglesiteCore/DomainOperationsService.swift`
- Test: `Tests/AnglesiteCoreTests/DomainOperationsServiceTests.swift`

**Interfaces:**
- Consumes: `CloudflareReading`, `CloudflareWriting`, `DNSRecord`, `DNSRecordPayload`, `CloudflareError`, `KeychainStore.readCloudflareToken() throws -> String?` (Task 1, existing).
- Produces:
  ```swift
  public enum DomainOperationError: Error, Equatable, Sendable {
      case noToken
      case zoneNotFound(domain: String)
      case cloudflare(CloudflareError)
  }
  public protocol DomainOperationsService: Sendable {
      func listRecords(domain: String) async -> Result<[DNSRecord], DomainOperationError>
      func addRecord(domain: String, type: String, name: String, content: String, ttl: Int) async -> Result<Void, DomainOperationError>
      func deleteRecord(domain: String, recordID: String) async -> Result<Void, DomainOperationError>
  }
  public struct DomainOperations: DomainOperationsService {
      public init(reader: any CloudflareReading = HTTPCloudflareClient(),
                   writer: any CloudflareWriting = HTTPCloudflareClient(),
                   tokenProvider: @escaping @Sendable () -> String? = DomainOperations.defaultTokenProvider)
  }
  ```
  Later tasks (`DomainModel`, the three App Intents) depend only on `DomainOperationsService` and `DomainOperationError` — not on `CloudflareReading`/`CloudflareWriting` directly.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/DomainOperationsServiceTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

struct DomainOperationsServiceTests {
    private func service(
        reader: FakeReader = FakeReader(),
        writer: FakeWriter = FakeWriter(),
        token: String? = "tok"
    ) -> DomainOperations {
        DomainOperations(reader: reader, writer: writer, tokenProvider: { token })
    }

    @Test("listRecords resolves the zone then lists its records")
    func listSucceeds() async {
        let reader = FakeReader(zoneID: "z1", records: [
            DNSRecord(id: "r1", type: "MX", name: "example.com", content: "mail.example.com", ttl: 1, proxied: false),
        ])
        let result = await service(reader: reader).listRecords(domain: "example.com")
        guard case .success(let records) = result else { Issue.record("expected success"); return }
        #expect(records.count == 1)
        #expect(reader.resolvedDomain == "example.com")
        #expect(reader.listedZoneID == "z1")
    }

    @Test("listRecords fails with .noToken when no token is available")
    func listNoToken() async {
        let result = await service(token: nil).listRecords(domain: "example.com")
        #expect(result == .failure(.noToken))
    }

    @Test("listRecords fails with .zoneNotFound when the zone can't be resolved")
    func listZoneNotFound() async {
        let reader = FakeReader(zoneID: nil)
        let result = await service(reader: reader).listRecords(domain: "absent.com")
        #expect(result == .failure(.zoneNotFound(domain: "absent.com")))
    }

    @Test("listRecords surfaces a CloudflareError as .cloudflare")
    func listCloudflareError() async {
        let reader = FakeReader(zoneID: "z1", listError: .unauthorized)
        let result = await service(reader: reader).listRecords(domain: "example.com")
        #expect(result == .failure(.cloudflare(.unauthorized)))
    }

    @Test("addRecord resolves the zone then posts the record")
    func addSucceeds() async {
        let reader = FakeReader(zoneID: "z1")
        let writer = FakeWriter()
        let result = await service(reader: reader, writer: writer)
            .addRecord(domain: "example.com", type: "TXT", name: "_atproto", content: "did=abc", ttl: 1)
        #expect(result == .success(()))
        #expect(writer.addedRecords == [DNSRecordPayload(type: "TXT", name: "_atproto", content: "did=abc", ttl: 1)])
    }

    @Test("addRecord fails with .noToken when no token is available")
    func addNoToken() async {
        let result = await service(token: nil).addRecord(domain: "example.com", type: "TXT", name: "n", content: "c", ttl: 1)
        #expect(result == .failure(.noToken))
    }

    @Test("addRecord surfaces a CloudflareError as .cloudflare")
    func addCloudflareError() async {
        let writer = FakeWriter(addError: .api(message: "bad request"))
        let result = await service(reader: FakeReader(zoneID: "z1"), writer: writer)
            .addRecord(domain: "example.com", type: "TXT", name: "n", content: "c", ttl: 1)
        #expect(result == .failure(.cloudflare(.api(message: "bad request"))))
    }

    @Test("deleteRecord resolves the zone then deletes the record")
    func deleteSucceeds() async {
        let reader = FakeReader(zoneID: "z1")
        let writer = FakeWriter()
        let result = await service(reader: reader, writer: writer).deleteRecord(domain: "example.com", recordID: "r1")
        #expect(result == .success(()))
        #expect(writer.deletedRecordIDs == ["r1"])
    }

    @Test("deleteRecord fails with .zoneNotFound when the zone can't be resolved")
    func deleteZoneNotFound() async {
        let result = await service(reader: FakeReader(zoneID: nil)).deleteRecord(domain: "absent.com", recordID: "r1")
        #expect(result == .failure(.zoneNotFound(domain: "absent.com")))
    }
}

// MARK: - Fakes

final class FakeReader: CloudflareReading, @unchecked Sendable {
    private let zoneID: String?
    private let records: [DNSRecord]
    private let listError: CloudflareError?
    private(set) var resolvedDomain: String?
    private(set) var listedZoneID: String?

    init(zoneID: String? = "z1", records: [DNSRecord] = [], listError: CloudflareError? = nil) {
        self.zoneID = zoneID
        self.records = records
        self.listError = listError
    }

    func resolveZoneID(domain: String, apiToken: String) async throws -> String? {
        resolvedDomain = domain
        return zoneID
    }
    func zoneState(zoneID: String, apiToken: String) async throws -> CloudflareZoneState {
        fatalError("not used by DomainOperations")
    }
    func listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord] {
        listedZoneID = zoneID
        if let listError { throw listError }
        return records
    }
}

final class FakeWriter: CloudflareWriting, @unchecked Sendable {
    private let addError: CloudflareError?
    private(set) var addedRecords: [DNSRecordPayload] = []
    private(set) var deletedRecordIDs: [String] = []

    init(addError: CloudflareError? = nil) {
        self.addError = addError
    }

    func enableDNSSEC(zoneID: String, apiToken: String) async throws {}
    func setAlwaysUseHTTPS(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func setHSTS(zoneID: String, maxAge: Int, includeSubdomains: Bool, preload: Bool, apiToken: String) async throws {}
    func addDNSRecord(zoneID: String, record: DNSRecordPayload, apiToken: String) async throws {
        if let addError { throw addError }
        addedRecords.append(record)
    }
    func deleteDNSRecord(zoneID: String, recordID: String, apiToken: String) async throws {
        deletedRecordIDs.append(recordID)
    }
    func setBotFightMode(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func createWAFCustomRule(zoneID: String, rule: WAFRulePayload, apiToken: String) async throws {}
    func setSpeedBrain(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func setECH(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func enableZstandardCompression(zoneID: String, apiToken: String) async throws {}
    func setPageShield(zoneID: String, enabled: Bool, apiToken: String) async throws {}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter DomainOperationsServiceTests`
Expected: FAIL to compile — `DomainOperationsService`/`DomainOperations`/`DomainOperationError` don't exist yet.

- [ ] **Step 3: Implement `DomainOperationsService`**

Create `Sources/AnglesiteCore/DomainOperationsService.swift`:

```swift
import Foundation

/// Errors surfaced by `DomainOperationsService`. `.cloudflare` wraps the underlying
/// `CloudflareError` for callers that want the detailed reason (e.g. to render the same
/// messages `HardenModel` shows for its own Cloudflare calls).
public enum DomainOperationError: Error, Equatable, Sendable {
    case noToken
    case zoneNotFound(domain: String)
    case cloudflare(CloudflareError)
}

/// Domain/DNS operations for a site's Cloudflare-managed zone: list, add, and delete DNS
/// records. Centralizes token lookup and zone resolution so `DomainModel` (GUI) and the
/// `AnglesiteIntents` Domain intents (Siri) share one implementation, mirroring how
/// `IntegrationOperationsService` backs both `IntegrationWizardModel` and `IntegrationIntents`.
public protocol DomainOperationsService: Sendable {
    func listRecords(domain: String) async -> Result<[DNSRecord], DomainOperationError>
    func addRecord(domain: String, type: String, name: String, content: String, ttl: Int) async -> Result<Void, DomainOperationError>
    func deleteRecord(domain: String, recordID: String) async -> Result<Void, DomainOperationError>
}

public struct DomainOperations: DomainOperationsService {
    private let reader: any CloudflareReading
    private let writer: any CloudflareWriting
    private let tokenProvider: @Sendable () -> String?

    public init(
        reader: any CloudflareReading = HTTPCloudflareClient(),
        writer: any CloudflareWriting = HTTPCloudflareClient(),
        tokenProvider: @escaping @Sendable () -> String? = DomainOperations.defaultTokenProvider
    ) {
        self.reader = reader
        self.writer = writer
        self.tokenProvider = tokenProvider
    }

    /// Env var first (matches `HardenModel.apiToken()`), then the Keychain-stored token.
    public static let defaultTokenProvider: @Sendable () -> String? = {
        if let env = ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"], !env.isEmpty {
            return env
        }
        return try? KeychainStore().readCloudflareToken()
    }

    private func resolveZone(domain: String, token: String) async -> Result<String, DomainOperationError> {
        do {
            guard let zoneID = try await reader.resolveZoneID(domain: domain, apiToken: token) else {
                return .failure(.zoneNotFound(domain: domain))
            }
            return .success(zoneID)
        } catch let error as CloudflareError {
            return .failure(.cloudflare(error))
        } catch {
            return .failure(.cloudflare(.malformedResponse))
        }
    }

    public func listRecords(domain: String) async -> Result<[DNSRecord], DomainOperationError> {
        guard let token = tokenProvider() else { return .failure(.noToken) }
        switch await resolveZone(domain: domain, token: token) {
        case .failure(let error):
            return .failure(error)
        case .success(let zoneID):
            do {
                return .success(try await reader.listDNSRecords(zoneID: zoneID, apiToken: token))
            } catch let error as CloudflareError {
                return .failure(.cloudflare(error))
            } catch {
                return .failure(.cloudflare(.malformedResponse))
            }
        }
    }

    public func addRecord(domain: String, type: String, name: String, content: String, ttl: Int) async -> Result<Void, DomainOperationError> {
        guard let token = tokenProvider() else { return .failure(.noToken) }
        switch await resolveZone(domain: domain, token: token) {
        case .failure(let error):
            return .failure(error)
        case .success(let zoneID):
            do {
                let payload = DNSRecordPayload(type: type, name: name, content: content, ttl: ttl)
                try await writer.addDNSRecord(zoneID: zoneID, record: payload, apiToken: token)
                return .success(())
            } catch let error as CloudflareError {
                return .failure(.cloudflare(error))
            } catch {
                return .failure(.cloudflare(.malformedResponse))
            }
        }
    }

    public func deleteRecord(domain: String, recordID: String) async -> Result<Void, DomainOperationError> {
        guard let token = tokenProvider() else { return .failure(.noToken) }
        switch await resolveZone(domain: domain, token: token) {
        case .failure(let error):
            return .failure(error)
        case .success(let zoneID):
            do {
                try await writer.deleteDNSRecord(zoneID: zoneID, recordID: recordID, apiToken: token)
                return .success(())
            } catch let error as CloudflareError {
                return .failure(.cloudflare(error))
            } catch {
                return .failure(.cloudflare(.malformedResponse))
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter DomainOperationsServiceTests`
Expected: PASS (all 9 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DomainOperationsService.swift Tests/AnglesiteCoreTests/DomainOperationsServiceTests.swift
git commit -m "feat(#462): add DomainOperationsService (token lookup + zone resolve + DNS CRUD)"
```

---

### Task 4: `DomainModel` — thin `@Observable` GUI state machine

**Files:**
- Create: `Sources/AnglesiteApp/DomainModel.swift`

**Interfaces:**
- Consumes: `DomainOperationsService`, `DomainOperationError`, `DNSRecord` (Task 3).
- Produces (consumed by Task 5's `DomainSheetView` and Task 6's `SiteWindowModel`/`SiteWindow`):
  ```swift
  @MainActor @Observable final class DomainModel {
      struct Draft: Equatable {
          enum Context: Equatable { case generic, bluesky, google }
          var type: String; var name: String; var content: String; var ttl: Int; var context: Context
          static func empty(context: Context = .generic) -> Draft
      }
      enum Phase: Equatable {
          case idle
          case resolvingZone(domain: String)
          case loaded(records: [DNSRecord], domain: String)
          case addingRecord(draft: Draft, records: [DNSRecord], domain: String)
          case confirmingDelete(record: DNSRecord, records: [DNSRecord], domain: String)
          case applying(domain: String)
          case failed(reason: String)
      }
      private(set) var phase: Phase
      var sheetPresented: Bool
      var domainInput: String
      init(ops: any DomainOperationsService = DomainOperations())
      var isRunning: Bool
      func openSheet()
      func dismissSheet()
      func retryFromFailed()
      func resolveAndLoad()
      func refresh()
      func beginAddRecord(context: Draft.Context)
      func updateDraft(_ draft: Draft)
      func cancelAddRecord()
      func submitAddRecord()
      func beginDelete(_ record: DNSRecord)
      func cancelDelete()
      func confirmDelete()
  }
  ```

No test file for this task — `AnglesiteApp` has no SwiftPM test target (see Global Constraints); this mirrors `HardenModel`, which is also untested directly. Verification is by building the app target (Step 3) since `DomainModel` alone can't drive the sheet without Task 5/6 wiring — a full manual smoke pass happens after Task 6.

- [ ] **Step 1: Write `DomainModel`**

Create `Sources/AnglesiteApp/DomainModel.swift`:

```swift
import SwiftUI
import AnglesiteCore

@MainActor
@Observable
final class DomainModel {
    struct Draft: Equatable {
        enum Context: Equatable {
            case generic, bluesky, google
        }
        var type: String
        var name: String
        var content: String
        var ttl: Int
        var context: Context

        static func empty(context: Context = .generic) -> Draft {
            switch context {
            case .bluesky:
                return Draft(type: "TXT", name: "_atproto", content: "", ttl: 1, context: .bluesky)
            case .generic, .google:
                return Draft(type: "TXT", name: "", content: "", ttl: 1, context: context)
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case resolvingZone(domain: String)
        case loaded(records: [DNSRecord], domain: String)
        case addingRecord(draft: Draft, records: [DNSRecord], domain: String)
        case confirmingDelete(record: DNSRecord, records: [DNSRecord], domain: String)
        case applying(domain: String)
        case failed(reason: String)
    }

    private(set) var phase: Phase = .idle
    var sheetPresented: Bool = false
    var domainInput: String = ""

    private let ops: any DomainOperationsService
    private var inFlight: Task<Void, Never>?

    init(ops: any DomainOperationsService = DomainOperations()) {
        self.ops = ops
    }

    var isRunning: Bool {
        switch phase {
        case .resolvingZone, .applying: return true
        default: return false
        }
    }

    func openSheet() {
        guard !isRunning else { return }
        phase = .idle
        domainInput = ""
        sheetPresented = true
    }

    func dismissSheet() {
        inFlight?.cancel()
        inFlight = nil
        sheetPresented = false
        phase = .idle
    }

    /// Like `openSheet()` but preserves `domainInput` — matches `HardenModel.retryFromFailed()`,
    /// so a failed lookup doesn't force the user to retype the domain.
    func retryFromFailed() {
        guard !isRunning else { return }
        phase = .idle
        sheetPresented = true
    }

    func resolveAndLoad() {
        let domain = domainInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty, !isRunning else { return }
        inFlight?.cancel()
        inFlight = Task { @MainActor [weak self] in
            await self?.runLoad(domain: domain)
        }
    }

    func refresh() {
        guard case .loaded(_, let domain) = phase, !isRunning else { return }
        inFlight?.cancel()
        inFlight = Task { @MainActor [weak self] in
            await self?.runLoad(domain: domain)
        }
    }

    func beginAddRecord(context: Draft.Context = .generic) {
        guard case .loaded(let records, let domain) = phase else { return }
        phase = .addingRecord(draft: .empty(context: context), records: records, domain: domain)
    }

    func updateDraft(_ draft: Draft) {
        guard case .addingRecord(_, let records, let domain) = phase else { return }
        phase = .addingRecord(draft: draft, records: records, domain: domain)
    }

    func cancelAddRecord() {
        guard case .addingRecord(_, let records, let domain) = phase else { return }
        phase = .loaded(records: records, domain: domain)
    }

    func submitAddRecord() {
        guard case .addingRecord(let draft, _, let domain) = phase, !isRunning else { return }
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        inFlight?.cancel()
        inFlight = Task { @MainActor [weak self] in
            await self?.runAdd(draft: draft, domain: domain)
        }
    }

    func beginDelete(_ record: DNSRecord) {
        guard case .loaded(let records, let domain) = phase else { return }
        phase = .confirmingDelete(record: record, records: records, domain: domain)
    }

    func cancelDelete() {
        guard case .confirmingDelete(_, let records, let domain) = phase else { return }
        phase = .loaded(records: records, domain: domain)
    }

    func confirmDelete() {
        guard case .confirmingDelete(let record, _, let domain) = phase, !isRunning else { return }
        inFlight?.cancel()
        inFlight = Task { @MainActor [weak self] in
            await self?.runDelete(record: record, domain: domain)
        }
    }

    // MARK: - Private

    private func runLoad(domain: String) async {
        phase = .resolvingZone(domain: domain)
        switch await ops.listRecords(domain: domain) {
        case .success(let records):
            phase = .loaded(records: records, domain: domain)
        case .failure(let error):
            phase = .failed(reason: message(for: error, domain: domain))
        }
    }

    private func runAdd(draft: Draft, domain: String) async {
        phase = .applying(domain: domain)
        let result = await ops.addRecord(domain: domain, type: draft.type, name: draft.name,
                                         content: draft.content, ttl: draft.ttl)
        switch result {
        case .success:
            await runLoad(domain: domain)
        case .failure(let error):
            phase = .failed(reason: message(for: error, domain: domain))
        }
    }

    private func runDelete(record: DNSRecord, domain: String) async {
        phase = .applying(domain: domain)
        switch await ops.deleteRecord(domain: domain, recordID: record.id) {
        case .success:
            await runLoad(domain: domain)
        case .failure(let error):
            phase = .failed(reason: message(for: error, domain: domain))
        }
    }

    private func message(for error: DomainOperationError, domain: String) -> String {
        switch error {
        case .noToken:
            return "No Cloudflare API token found. Add one in Settings → Credentials."
        case .zoneNotFound(let d):
            return "Zone not found for \"\(d)\". Check the domain and ensure your API token has Zone Read permission."
        case .cloudflare(let cfError):
            switch cfError {
            case .unauthorized:
                return "API token is unauthorized. Check that it has Zone Read and DNS Edit permissions."
            case .http(let status):
                return "Cloudflare API returned HTTP \(status)."
            case .api(let msg):
                return "Cloudflare API error: \(msg)"
            case .malformedResponse:
                return "Unexpected response from Cloudflare API."
            case .zoneNotFound(let d):
                return "Zone not found for \"\(d)\". Check the domain and token permissions."
            }
        }
    }
}
```

- [ ] **Step 2: Verify the file compiles in isolation**

`DomainModel.swift` only imports `SwiftUI` and `AnglesiteCore`, both of which build standalone. Run:

Run: `swift build --package-path . --target AnglesiteCore`
Expected: BUILD SUCCEEDED (confirms `AnglesiteCore` dependencies `DomainModel.swift` needs are intact; the file itself is verified for real in Task 6's `xcodebuild`, once it's referenced from `SiteWindowModel`)

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/DomainModel.swift
git commit -m "feat(#462): add DomainModel (thin GUI state machine over DomainOperationsService)"
```

---

### Task 5: `DomainSheetView` — SwiftUI presentation

**Files:**
- Create: `Sources/AnglesiteApp/DomainSheetView.swift`

**Interfaces:**
- Consumes: `DomainModel`, `DomainModel.Phase`, `DomainModel.Draft`, `DNSRecord`, `DNSRecordLabeler.label(for:)` (Tasks 2, 4).

No test file (same rationale as Task 4). Verified by Task 6's `xcodebuild` build.

- [ ] **Step 1: Write `DomainSheetView`**

Create `Sources/AnglesiteApp/DomainSheetView.swift`:

```swift
import SwiftUI
import AnglesiteCore

struct DomainSheetView: View {
    @Bindable var model: DomainModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 540)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle).font(.headline)
                if let subtitle = headerSubtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
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
            Image(systemName: "globe").font(.title3)
        case .resolvingZone, .applying:
            ProgressView().controlSize(.small)
        case .loaded, .addingRecord, .confirmingDelete:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.title3)
        }
    }

    private var headerTitle: String {
        switch model.phase {
        case .idle:
            return "Manage Domain"
        case .resolvingZone(let domain):
            return "Reading DNS records for \(domain)…"
        case .loaded(let records, let domain):
            return "\(records.count) DNS record\(records.count == 1 ? "" : "s") for \(domain)"
        case .addingRecord(_, _, let domain):
            return "Add a DNS record to \(domain)"
        case .confirmingDelete(_, _, let domain):
            return "Delete this record from \(domain)?"
        case .applying(let domain):
            return "Updating \(domain)…"
        case .failed:
            return "Couldn't read DNS records"
        }
    }

    private var headerSubtitle: String? {
        switch model.phase {
        case .addingRecord(let draft, _, _):
            switch draft.context {
            case .bluesky:
                return "Paste the DID Bluesky showed you (starts with \"did=did:plc:\")."
            case .google:
                return "Paste the exact record Google's verification page gave you."
            case .generic:
                return nil
            }
        default:
            return nil
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            domainInputForm
        case .resolvingZone:
            progressView("Resolving zone and reading DNS records…")
        case .loaded:
            recordList
        case .addingRecord(let draft, _, _):
            addRecordForm(draft)
        case .confirmingDelete(let record, _, _):
            deleteConfirmation(record)
        case .applying:
            progressView("Updating DNS records…")
        case .failed(let reason):
            VStack(spacing: 12) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.largeTitle)
                Text(reason).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func progressView(_ text: String) -> some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var domainInputForm: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "globe").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Enter the domain to manage").font(.headline)
            Text("The domain must be managed in Cloudflare. Your API token needs Zone DNS Read and Edit permissions.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
            TextField("example.com", text: $model.domainInput)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                .onSubmit { model.resolveAndLoad() }
            Spacer()
        }
        .padding(16)
    }

    private var recordList: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.beginAddRecord(context: .bluesky)
                } label: {
                    Label("Add Bluesky verification", systemImage: "at")
                }
                Button {
                    model.beginAddRecord(context: .google)
                } label: {
                    Label("Add Google verification", systemImage: "checkmark.seal")
                }
                Spacer()
                Button {
                    model.beginAddRecord(context: .generic)
                } label: {
                    Label("Add record", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            Divider()
            if case .loaded(let records, _) = model.phase, records.isEmpty {
                VStack(spacing: 8) {
                    Text("No DNS records found.").font(.headline)
                    Text("Add one above to get started.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .loaded(let records, _) = model.phase {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(records) { record in
                            recordRow(record)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func recordRow(_ record: DNSRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DNSRecordLabeler.label(for: record)).font(.callout.weight(.medium))
                Text("\(record.type) \(record.name) → \(record.content)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                model.beginDelete(record)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func addRecordForm(_ draft: DomainModel.Draft) -> some View {
        Form {
            Picker("Type", selection: Binding(
                get: { draft.type },
                set: { var d = draft; d.type = $0; model.updateDraft(d) }
            )) {
                ForEach(["TXT", "CNAME", "A", "AAAA", "MX"], id: \.self) { Text($0).tag($0) }
            }
            TextField("Name", text: Binding(
                get: { draft.name },
                set: { var d = draft; d.name = $0; model.updateDraft(d) }
            ))
            TextField("Content", text: Binding(
                get: { draft.content },
                set: { var d = draft; d.content = $0; model.updateDraft(d) }
            ))
            TextField("TTL", value: Binding(
                get: { draft.ttl },
                set: { var d = draft; d.ttl = $0; model.updateDraft(d) }
            ), format: .number)
        }
        .padding(16)
    }

    private func deleteConfirmation(_ record: DNSRecord) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.largeTitle)
            Text("\(record.type) \(record.name) → \(record.content)")
                .font(.callout.monospaced()).multilineTextAlignment(.center).frame(maxWidth: 420)
            Text("This can't be undone.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            switch model.phase {
            case .idle:
                Button("Load records") { model.resolveAndLoad() }
                    .disabled(model.domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
            case .addingRecord:
                Button("Cancel") { model.cancelAddRecord() }
                Spacer()
                Button("Add") { model.submitAddRecord() }.buttonStyle(.borderedProminent)
            case .confirmingDelete:
                Button("Cancel") { model.cancelDelete() }
                Spacer()
                Button("Delete", role: .destructive) { model.confirmDelete() }
            case .failed:
                Button("Try again") { model.retryFromFailed() }
            default:
                EmptyView()
            }
            if case .addingRecord = model.phase {} else if case .confirmingDelete = model.phase {} else {
                Spacer()
                Button("Close") { model.dismissSheet() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/AnglesiteApp/DomainSheetView.swift
git commit -m "feat(#462): add DomainSheetView (list/add/delete DNS records UI)"
```

---

### Task 6: Wire `DomainModel`/`DomainSheetView` into `SiteWindowModel`/`SiteWindow`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:69`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:332-363`

**Interfaces:**
- Consumes: `DomainModel` (Task 4), `DomainSheetView` (Task 5).

- [ ] **Step 1: Add the `domain` property to `SiteWindowModel`**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, change line 69 from:

```swift
    var harden = HardenModel()
```

to:

```swift
    var harden = HardenModel()
    var domain = DomainModel()
```

- [ ] **Step 2: Add the toolbar button and sheet in `SiteWindow`**

In `Sources/AnglesiteApp/SiteWindow.swift`, after the "Add Integration…" `ToolbarItem` (ends at line 340 with `.visibilityPriority(ToolbarItemVisibilityPriority(lowerThan: .low))`), insert:

```swift
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.domain.openSheet()
                } label: {
                    Label("Domain", systemImage: "globe")
                }
                .help("View and manage this domain's DNS records")
                .disabled(model.domain.isRunning)
            }
            .visibilityPriority(ToolbarItemVisibilityPriority(lowerThan: .low))
```

Then, after the `.sheet(isPresented: $bindableModel.harden.sheetPresented) { HardenSheetView(model: model.harden) }` block (line 361-363), insert:

```swift
        .sheet(isPresented: $bindableModel.domain.sheetPresented) {
            DomainSheetView(model: model.domain)
        }
```

- [ ] **Step 3: Verify the app builds**

If `Anglesite.xcodeproj` doesn't exist in this worktree yet: `xcodegen generate`, then (once, if not already done) `ANGLESITE_PLUGIN_SRC=<path-to-sibling-anglesite-checkout> scripts/copy-plugin.sh`.

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Manual smoke check**

Open `Anglesite.xcodeproj` in Xcode, run the app, open a site, click the new "Domain" toolbar button, and confirm the sheet opens showing the "Enter the domain to manage" form (a live Cloudflare token/zone isn't required to verify this much — it should fail gracefully to the `.failed` phase with a clear message if no token is configured).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#462): wire Domain sheet into the site window toolbar"
```

---

### Task 7: `DomainIntents` — Siri/Shortcuts parity

**Files:**
- Create: `Sources/AnglesiteIntents/DomainIntents.swift`
- Create: `Sources/AnglesiteIntents/DomainOperationsOverride.swift`
- Modify: `Sources/AnglesiteIntents/Bootstrap.swift:60-62`
- Test: `Tests/AnglesiteIntentsTests/DomainIntentsTests.swift`

**Interfaces:**
- Consumes: `DomainOperationsService`, `DomainOperationError`, `DNSRecord` (Task 3).
- Produces: `ListDNSRecordsIntent`, `AddDNSRecordIntent`, `DeleteDNSRecordIntent` (all `AppIntent`), `DomainOperationsOverride.scoped` (test seam mirroring `IntegrationOperationsOverride`), `DomainDialogs` (pure, unit-testable dialog strings).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteIntentsTests/DomainIntentsTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteIntents
import AnglesiteCore

extension AppIntentsTests {
    @Suite("DomainIntents")
    struct DomainIntentsTests {
        @Test("ListDNSRecordsIntent summarizes the domain's records")
        func listSummarizes() async throws {
            let fake = FakeDomainOps(records: [
                DNSRecord(id: "r1", type: "MX", name: "example.com", content: "mail.example.com", ttl: 1, proxied: false),
            ])
            var intent = ListDNSRecordsIntent()
            intent.domain = "example.com"
            let dialog = await DomainOperationsOverride.$scoped.withValue(fake) {
                await intent.performForTesting()
            }
            #expect(dialog.contains("1 DNS record"))
            #expect(dialog.contains("Email routing"))
        }

        @Test("ListDNSRecordsIntent reports zero records in plain English")
        func listEmpty() async throws {
            let fake = FakeDomainOps(records: [])
            var intent = ListDNSRecordsIntent()
            intent.domain = "example.com"
            let dialog = await DomainOperationsOverride.$scoped.withValue(fake) {
                await intent.performForTesting()
            }
            #expect(dialog == "example.com has no DNS records.")
        }

        @Test("ListDNSRecordsIntent surfaces a failure")
        func listFails() async throws {
            let fake = FakeDomainOps(listError: .noToken)
            var intent = ListDNSRecordsIntent()
            intent.domain = "example.com"
            let dialog = await DomainOperationsOverride.$scoped.withValue(fake) {
                await intent.performForTesting()
            }
            #expect(dialog.contains("Couldn't"))
        }

        @Test("AddDNSRecordIntent adds the record and reports success")
        func addSucceeds() async throws {
            let fake = FakeDomainOps()
            var intent = AddDNSRecordIntent()
            intent.domain = "example.com"
            intent.type = "TXT"
            intent.name = "_atproto"
            intent.content = "did=did:plc:abc"
            intent.ttl = 1
            let dialog = await DomainOperationsOverride.$scoped.withValue(fake) {
                await intent.confirmAndApplyForTesting()
            }
            #expect(dialog.contains("Added"))
            #expect(fake.addedRecords.count == 1)
            #expect(fake.addedRecords.first?.name == "_atproto")
        }

        @Test("DeleteDNSRecordIntent deletes the record and reports success")
        func deleteSucceeds() async throws {
            let fake = FakeDomainOps()
            var intent = DeleteDNSRecordIntent()
            intent.domain = "example.com"
            intent.recordID = "r1"
            let dialog = await DomainOperationsOverride.$scoped.withValue(fake) {
                await intent.confirmAndApplyForTesting()
            }
            #expect(dialog.contains("Deleted"))
            #expect(fake.deletedRecordIDs == ["r1"])
        }
    }
}

final class FakeDomainOps: DomainOperationsService, @unchecked Sendable {
    private let records: [DNSRecord]
    private let listError: DomainOperationError?
    private(set) var addedRecords: [(name: String, type: String)] = []
    private(set) var deletedRecordIDs: [String] = []

    init(records: [DNSRecord] = [], listError: DomainOperationError? = nil) {
        self.records = records
        self.listError = listError
    }

    func listRecords(domain: String) async -> Result<[DNSRecord], DomainOperationError> {
        if let listError { return .failure(listError) }
        return .success(records)
    }
    func addRecord(domain: String, type: String, name: String, content: String, ttl: Int) async -> Result<Void, DomainOperationError> {
        addedRecords.append((name: name, type: type))
        return .success(())
    }
    func deleteRecord(domain: String, recordID: String) async -> Result<Void, DomainOperationError> {
        deletedRecordIDs.append(recordID)
        return .success(())
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter DomainIntentsTests`
Expected: FAIL to compile — none of the new types exist yet.

- [ ] **Step 3: Implement the test seam**

Create `Sources/AnglesiteIntents/DomainOperationsOverride.swift`:

```swift
import AnglesiteCore

/// Test-only escape hatch around `@Dependency` resolution of `DomainOperationsService`,
/// mirroring `IntegrationOperationsOverride`. Tests bind this `@TaskLocal` to a fake service
/// before invoking the domain intents; the intents read `DomainOperationsOverride.scoped ?? self.ops`,
/// so production flows through `@Dependency`.
public enum DomainOperationsOverride {
    @TaskLocal public static var scoped: (any DomainOperationsService)?
}
```

- [ ] **Step 4: Implement the intents**

Create `Sources/AnglesiteIntents/DomainIntents.swift`:

```swift
import AppIntents
import AnglesiteCore
import Foundation

// MARK: - Dialog formatting (pure, unit-testable)

public enum DomainDialogs {
    public static func recordsSummary(_ records: [DNSRecord], domain: String) -> String {
        if records.isEmpty { return "\(domain) has no DNS records." }
        let lines = records.map { record in
            "\(DNSRecordLabeler.label(for: record)): \(record.type) \(record.name) → \(record.content)"
        }
        return "\(domain) has \(records.count) DNS record\(records.count == 1 ? "" : "s"):\n" + lines.joined(separator: "\n")
    }
    public static func added(type: String, name: String, domain: String) -> String {
        "Added a \(type) record for \(name) on \(domain)."
    }
    public static func deleted(domain: String) -> String {
        "Deleted the DNS record from \(domain)."
    }
    public static func failed(reason: String, domain: String) -> String {
        "Couldn't finish that on \(domain): \(reason)."
    }
}

private func domainErrorMessage(_ error: DomainOperationError, domain: String) -> String {
    switch error {
    case .noToken:
        return "No Cloudflare API token found."
    case .zoneNotFound(let d):
        return "Zone not found for \"\(d)\"."
    case .cloudflare(let cfError):
        switch cfError {
        case .unauthorized: return "API token is unauthorized."
        case .http(let status): return "Cloudflare API returned HTTP \(status)."
        case .api(let message): return "Cloudflare API error: \(message)"
        case .malformedResponse: return "Unexpected response from Cloudflare API."
        case .zoneNotFound(let d): return "Zone not found for \"\(d)\"."
        }
    }
}

// MARK: - List DNS Records

public struct ListDNSRecordsIntent: AppIntent {
    public static let title: LocalizedStringResource = "List DNS Records"
    public static let description = IntentDescription("List the current DNS records for a domain.")

    @Parameter(title: "Domain") public var domain: String
    @Dependency private var ops: any DomainOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("List DNS records for \(\.$domain)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let svc = DomainOperationsOverride.scoped ?? ops
        let dialog = await run(svc: svc)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }

    private func run(svc: any DomainOperationsService) async -> String {
        switch await svc.listRecords(domain: domain) {
        case .success(let records):
            return DomainDialogs.recordsSummary(records, domain: domain)
        case .failure(let error):
            return DomainDialogs.failed(reason: domainErrorMessage(error, domain: domain), domain: domain)
        }
    }
}

// MARK: - Add DNS Record

public struct AddDNSRecordIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add DNS Record"
    public static let description = IntentDescription(
        "Add a DNS record (TXT, CNAME, A, AAAA, or MX) to a domain."
    )

    @Parameter(title: "Domain") public var domain: String
    @Parameter(title: "Type", description: "TXT, CNAME, A, AAAA, or MX.") public var type: String
    @Parameter(title: "Name") public var name: String
    @Parameter(title: "Content") public var content: String
    @Parameter(title: "TTL", default: 1) public var ttl: Int
    @Dependency private var ops: any DomainOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Add a \(\.$type) record to \(\.$domain)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let svc = DomainOperationsOverride.scoped ?? ops
        if DomainOperationsOverride.scoped == nil {
            try await requestConfirmation(dialog: "Add a \(type) record for \(name) to \(domain)?")
        }
        let dialog = await run(svc: svc)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }

    private func run(svc: any DomainOperationsService) async -> String {
        switch await svc.addRecord(domain: domain, type: type, name: name, content: content, ttl: ttl) {
        case .success:
            return DomainDialogs.added(type: type, name: name, domain: domain)
        case .failure(let error):
            return DomainDialogs.failed(reason: domainErrorMessage(error, domain: domain), domain: domain)
        }
    }
}

// MARK: - Delete DNS Record

public struct DeleteDNSRecordIntent: AppIntent {
    public static let title: LocalizedStringResource = "Delete DNS Record"
    public static let description = IntentDescription(
        "Delete a DNS record from a domain by its record identifier."
    )

    @Parameter(title: "Domain") public var domain: String
    @Parameter(title: "Record ID", description: "From a prior List DNS Records call.") public var recordID: String
    @Dependency private var ops: any DomainOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Delete a DNS record from \(\.$domain)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let svc = DomainOperationsOverride.scoped ?? ops
        if DomainOperationsOverride.scoped == nil {
            try await requestConfirmation(dialog: "Delete this DNS record from \(domain)? This can't be undone.")
        }
        let dialog = await run(svc: svc)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }

    private func run(svc: any DomainOperationsService) async -> String {
        switch await svc.deleteRecord(domain: domain, recordID: recordID) {
        case .success:
            return DomainDialogs.deleted(domain: domain)
        case .failure(let error):
            return DomainDialogs.failed(reason: domainErrorMessage(error, domain: domain), domain: domain)
        }
    }
}

// MARK: - Test-only helpers

extension ListDNSRecordsIntent {
    /// Drives `perform`'s dialog logic directly, bypassing the AppIntents `@Dependency` gate.
    /// Only callable when `DomainOperationsOverride.scoped` is bound.
    func performForTesting() async -> String {
        guard let svc = DomainOperationsOverride.scoped else {
            fatalError("performForTesting requires a bound DomainOperationsOverride.scoped")
        }
        return await run(svc: svc)
    }
}

extension AddDNSRecordIntent {
    /// Drives plan→apply directly, bypassing the AppIntents `requestConfirmation` gate.
    /// Only callable when `DomainOperationsOverride.scoped` is bound.
    func confirmAndApplyForTesting() async -> String {
        guard let svc = DomainOperationsOverride.scoped else {
            fatalError("confirmAndApplyForTesting requires a bound DomainOperationsOverride.scoped")
        }
        return await run(svc: svc)
    }
}

extension DeleteDNSRecordIntent {
    /// Drives plan→apply directly, bypassing the AppIntents `requestConfirmation` gate.
    /// Only callable when `DomainOperationsOverride.scoped` is bound.
    func confirmAndApplyForTesting() async -> String {
        guard let svc = DomainOperationsOverride.scoped else {
            fatalError("confirmAndApplyForTesting requires a bound DomainOperationsOverride.scoped")
        }
        return await run(svc: svc)
    }
}
```

- [ ] **Step 5: Register the service with `AppDependencyManager`**

In `Sources/AnglesiteIntents/Bootstrap.swift`, after the `IntegrationOperationsService` registration block (lines 60-62):

```swift
        AppDependencyManager.shared.add { () -> any IntegrationOperationsService in
            IntegrationOperations.live()
        }
```

insert:

```swift
        AppDependencyManager.shared.add { () -> any DomainOperationsService in
            DomainOperations()
        }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --package-path . --filter DomainIntentsTests`
Expected: PASS (all 5 tests)

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteIntents/DomainIntents.swift Sources/AnglesiteIntents/DomainOperationsOverride.swift \
        Sources/AnglesiteIntents/Bootstrap.swift Tests/AnglesiteIntentsTests/DomainIntentsTests.swift
git commit -m "feat(#462): add ListDNSRecordsIntent/AddDNSRecordIntent/DeleteDNSRecordIntent"
```

---

### Task 8: Register the three intents in `AnglesiteOperations`

**Files:**
- Modify: `Sources/AnglesiteIntents/OperationDescriptor.swift:140-157`
- Modify: `Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift:45-63`

**Interfaces:**
- Consumes: `ListDNSRecordsIntent`, `AddDNSRecordIntent`, `DeleteDNSRecordIntent` (Task 7).

- [ ] **Step 1: Write the failing test change**

In `Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift`, add three entries to the `expected` dictionary (after `"add-comments"`, before the closing `]`):

```swift
                "add-comments": .init(sideEffect: .createsContent, requiresConfirmation: true, isCancellable: false, resultShape: .none),
                "list-dns-records": .init(sideEffect: .readOnly, requiresConfirmation: false, isCancellable: false, resultShape: .none),
                "add-dns-record": .init(sideEffect: .createsContent, requiresConfirmation: true, isCancellable: false, resultShape: .none),
                "delete-dns-record": .init(sideEffect: .modifiesContent, requiresConfirmation: true, isCancellable: false, resultShape: .none),
            ]
```

(This replaces just the `"add-comments"` line and the closing `]` — the other existing entries stay as-is.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --filter OperationDescriptorTests`
Expected: FAIL — `expected.count == AnglesiteOperations.all.count` (14 vs 11), and `try #require(expected[descriptor.operationID], ...)` has no registry entries yet for the 3 new operationIDs (the registry side isn't updated until Step 3, so this same run also fails coverage/anchorSync indirectly once Step 3 lands — run again after Step 3 to confirm green).

- [ ] **Step 3: Add the descriptors**

In `Sources/AnglesiteIntents/OperationDescriptor.swift`, after the `"add-comments"` descriptor (lines 152-157) and before the closing `]` of `all`:

```swift
        OperationDescriptor(
            operationID: "add-comments", displayName: "Add Comments",
            intentTypeName: "AddGiscusIntent", sideEffect: .createsContent,
            requiresConfirmation: true, isCancellable: false,
            resultShape: .none
        ),
        OperationDescriptor(
            operationID: "list-dns-records", displayName: "List DNS Records",
            intentTypeName: "ListDNSRecordsIntent", sideEffect: .readOnly,
            requiresConfirmation: false, isCancellable: false,
            resultShape: .none
        ),
        OperationDescriptor(
            operationID: "add-dns-record", displayName: "Add DNS Record",
            intentTypeName: "AddDNSRecordIntent", sideEffect: .createsContent,
            requiresConfirmation: true, isCancellable: false,
            resultShape: .none
        ),
        OperationDescriptor(
            // `.modifiesContent`: extends the write-reach taxonomy from "site or its repository"
            // to a site's Cloudflare-managed DNS zone state — deleting a record alters standing
            // zone state rather than adding a new artifact the way `add-dns-record` does.
            operationID: "delete-dns-record", displayName: "Delete DNS Record",
            intentTypeName: "DeleteDNSRecordIntent", sideEffect: .modifiesContent,
            requiresConfirmation: true, isCancellable: false,
            resultShape: .none
        ),
    ]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter OperationDescriptorTests`
Expected: PASS (all tests, including `coverage`, `anchorSync`, `uniqueness`, `lookup`, `declaredFields`)

Run: `swift test --package-path .`
Expected: PASS — full `AnglesiteCoreTests` and `AnglesiteIntentsTests` suites green, confirming nothing else regressed across all 8 tasks.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/OperationDescriptor.swift Tests/AnglesiteIntentsTests/OperationDescriptorTests.swift
git commit -m "feat(#462): register DNS intents in the operation descriptor registry"
```

---

## Spec Coverage Check

- View records, plain-English labels → Task 2 (`DNSRecordLabeler`), Task 5 (`recordList`/`recordRow`).
- Add an arbitrary record → Task 3 (`addRecord`), Task 4/5 (`addRecordForm`), Task 7 (`AddDNSRecordIntent`).
- Delete a record with confirmation → Task 3 (`deleteRecord`), Task 4/5 (`confirmingDelete` phase), Task 7 (`DeleteDNSRecordIntent`).
- Bluesky verification prefill → Task 4 (`Draft.empty(context: .bluesky)`), Task 5 (quick-fill button + help text).
- Google verification prefill → Task 4 (`Draft.Context.google`), Task 5 (quick-fill button + help text, type left open).
- Not an `IntegrationDescriptor` — confirmed: no changes to `IntegrationCatalog.swift` anywhere in this plan.
- Error handling matching `HardenModel`'s style → Task 4 (`DomainModel.message(for:domain:)`), Task 7 (`domainErrorMessage`).
- App Intents parity → Task 7, registered in the descriptor registry → Task 8.
- Testing per spec's list → `HTTPCloudflareClientTests`-equivalent (Task 1's `DomainDNSClientTests`), `DomainModelTests`-equivalent (Task 3's `DomainOperationsServiceTests`, since the real branching logic lives there, not in the untested `DomainModel` — documented deviation from the spec's suggested test file name, same coverage intent), `DomainIntentsTests` (Task 7), `DNSRecordLabeler` pure-function tests (Task 2).

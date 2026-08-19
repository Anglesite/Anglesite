# Contacts Allowlist Push Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Push the site's contact allowlist (normalized me-URLs) to the Worker's `SOCIAL_KV` store whenever a contact is added/removed, and unconditionally re-push on every deploy as a consistency backstop.

**Architecture:** A new `ContactsAllowlistKVClient` (Cloudflare KV HTTP client, injectable-transport DI, mirrors `InboxKVClient`) writes a single JSON-array key (`contacts:allowlist`) to the site's already-provisioned `SOCIAL_KV` namespace. A new `ContactsAllowlistSync` orchestrator (mirrors `InboxSubmissionSync`/`MicropubContentSync`'s `*IfConfigured` shape) reads `ContactStore.knownMeURLs()` and pushes the whole set through that client, resolving credentials/namespace id from `SiteConfigStore`/`SecretStore` the same way those sync types do. It's wired into `ContactsModel.add/update/remove` (fire-and-forget, non-blocking) and into `DeployCoordinator.runPostDeploySequencing` (a new best-effort post-deploy step, like the existing webmention/syndication/backfill passes).

**Tech Stack:** Swift 6.4 / Swift Testing, `AnglesiteCore` (SwiftPM), `AnglesiteAppCore` (the `Sources/AnglesiteApp` SwiftPM target).

## Global Constraints

- Read `CONTRIBUTING.md` in this worktree before making any change — it is the source of truth for workflow, and this plan does not repeat it.
- Conventional commits, subject line ≤72 characters, reference `#1567` in each commit subject.
- Every push is best-effort: it must never throw out of a caller, never block a UI action, and never fail a deploy. Failures are logged via `LogCenter`, not surfaced as errors.
- No new Cloudflare resources: reuse the already-provisioned `SOCIAL_KV` namespace (`ProvisionedResources.kvNamespaceID`). Do not touch `SocialWorkerProvisionCommand`, `WorkerComposition`'s provisioning logic, or any `worker/migrations/*.sql` file.
- Do not modify `Resources/Template/worker/worker.ts` — reading/checking the allowlist is epic #963 slice 4, a separate issue.
- `swift test --package-path .` must pass after every task. Because Task 4/5 touch `Sources/AnglesiteApp`, run the full suite locally on the Xcode 27 toolchain before considering the plan done (per `CONTRIBUTING.md` ▸ Testing — CI does not execute `AnglesiteAppTests` at all).
- Follow `docs/testing-macos-app.md` for toolchain setup (`DEVELOPER_DIR`) if `swift test` fails with a stale/broken toolchain error.

---

## File Structure

- **Create** `Sources/AnglesiteCore/ContactsAllowlistKVClient.swift` — the KV HTTP client (one method: `putAllowlist(_:)`).
- **Create** `Tests/AnglesiteCoreTests/ContactsAllowlistKVClientTests.swift`
- **Create** `Sources/AnglesiteCore/CloudflareAccountLookup.swift` — shared "resolve the token's first visible account id" helper, consolidating the three near-identical private copies this task would otherwise create a fourth of.
- **Create** `Tests/AnglesiteCoreTests/CloudflareAccountLookupTests.swift`
- **Create** `Sources/AnglesiteCore/ContactsAllowlistSync.swift` — the orchestrator (`push`, `pushIfConfigured`).
- **Create** `Tests/AnglesiteCoreTests/ContactsAllowlistSyncTests.swift`
- **Modify** `Sources/AnglesiteCore/MicropubContentSync.swift` — delegate to the shared `CloudflareAccountLookup` instead of its own private `resolveAccountID`.
- **Modify** `Sources/AnglesiteCore/ReceivedInteractionSync.swift` — same delegation.
- **Modify** `Sources/AnglesiteCore/OperationProgress.swift` — add the `deployPushingContactsAllowlist` milestone constant.
- **Modify** `Sources/AnglesiteCore/DeployCoordinator.swift` — add a `pushContactsAllowlist` step to `runPostDeploySequencing`.
- **Modify** `Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift` — update 4 existing expectations, add 1 new test.
- **Modify** `Sources/AnglesiteApp/ContactsModel.swift` — inject a `pushAllowlist` closure, call it after `add`/`update`/`remove`.
- **Modify** `Tests/AnglesiteAppTests/ContactsModelTests.swift` — add push-is-attempted coverage.
- **Modify** `Sources/AnglesiteApp/DeployModel.swift` — wire `ContactsAllowlistSync.pushIfConfigured` into the `runPostDeploySequencing` call site.

---

### Task 1: `ContactsAllowlistKVClient`

**Files:**
- Create: `Sources/AnglesiteCore/ContactsAllowlistKVClient.swift`
- Test: `Tests/AnglesiteCoreTests/ContactsAllowlistKVClientTests.swift`

**Interfaces:**
- Consumes: `CloudflareTransport` (`Sources/AnglesiteCore/CloudflareReading.swift:78`), `HTTPCloudflareClient.defaultTransport` (`Sources/AnglesiteCore/HTTPCloudflareClient.swift:181`), `CloudflareError` (`Sources/AnglesiteCore/CloudflareReading.swift:9`, cases `.unauthorized`, `.http(status:)`, `.malformedResponse`).
- Produces: `public struct ContactsAllowlistKVClient: Sendable { init(accountID:namespaceID:apiToken:baseURL:transport:); func putAllowlist(_ meURLs: Set<String>) async throws }` — consumed by Task 2.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/ContactsAllowlistKVClientTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

struct ContactsAllowlistKVClientTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/")!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!
    }

    @Test("putAllowlist PUTs a sorted JSON array to the contacts:allowlist key")
    func putsSortedArray() async throws {
        let captured = CapturedRequest()
        let client = ContactsAllowlistKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                await captured.set(request)
                return (Data(), Self.response(200))
            })

        try await client.putAllowlist(["bob.example", "alice.example"])

        let request = await captured.value
        #expect(request?.httpMethod == "PUT")
        #expect(request?.url?.path.hasSuffix("/values/contacts:allowlist") == true)
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let body = try #require(await captured.body)
        let decoded = try JSONDecoder().decode([String].self, from: body)
        #expect(decoded == ["alice.example", "bob.example"])
    }

    @Test("putAllowlist succeeds with an empty set (last contact removed)")
    func putsEmptySet() async throws {
        let captured = CapturedRequest()
        let client = ContactsAllowlistKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                await captured.set(request)
                return (Data(), Self.response(200))
            })

        try await client.putAllowlist([])

        let body = try #require(await captured.body)
        let decoded = try JSONDecoder().decode([String].self, from: body)
        #expect(decoded.isEmpty)
    }

    @Test("throws unauthorized on a 401/403 response")
    func throwsUnauthorized() async {
        let client = ContactsAllowlistKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "bad",
            transport: { _ in (Data(), Self.response(403)) })
        await #expect(throws: CloudflareError.unauthorized) {
            try await client.putAllowlist(["alice.example"])
        }
    }

    @Test("throws http(status:) on any other non-2xx response")
    func throwsHTTPError() async {
        let client = ContactsAllowlistKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { _ in (Data(), Self.response(500)) })
        await #expect(throws: CloudflareError.http(status: 500)) {
            try await client.putAllowlist(["alice.example"])
        }
    }
}

/// Actor wrapper so the `@Sendable` transport closure can hand a captured `URLRequest`/body back
/// to the test body without a data race. Mirrors `InboxKVClientTests.CapturedRequest`.
private actor CapturedRequest {
    private(set) var value: URLRequest?
    var body: Data? { value?.httpBody }
    func set(_ request: URLRequest) { value = request }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter ContactsAllowlistKVClientTests`
Expected: FAIL to compile — `ContactsAllowlistKVClient` does not exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AnglesiteCore/ContactsAllowlistKVClient.swift
import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cloudflare Workers KV client for the #1567 contacts allowlist push. Writes the site's
/// normalized me-URL set (`ContactStore.knownMeURLs()`) as a single JSON array under
/// `contacts:allowlist` in the already-provisioned `SOCIAL_KV` namespace — the future
/// authenticated-read gate (epic #963 slice 4) reads this key from the Worker side. Follows the
/// same injectable-transport DI pattern as `InboxKVClient`/`HTTPCloudflareClient` — no Keychain
/// coupling, token passed in at init.
public struct ContactsAllowlistKVClient: Sendable {
    private static let key = "contacts:allowlist"

    private let baseURL: String
    private let accountID: String
    private let namespaceID: String
    private let apiToken: String
    private let transport: CloudflareTransport

    public init(
        accountID: String,
        namespaceID: String,
        apiToken: String,
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) {
        self.accountID = accountID
        self.namespaceID = namespaceID
        self.apiToken = apiToken
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Replaces the whole `contacts:allowlist` value with `meURLs`, sorted for a deterministic
    /// request body. Whole-set replace, not an incremental add/remove — the caller
    /// (`ContactsAllowlistSync`) always supplies the complete current set, so this single call
    /// doubles as both "push on change" and "reconcile."
    public func putAllowlist(_ meURLs: Set<String>) async throws {
        let body = try JSONEncoder().encode(meURLs.sorted())
        let valueURLString = "\(baseURL)/accounts/\(accountID)/storage/kv/namespaces/\(namespaceID)/values/\(Self.key)"
        guard let url = URL(string: valueURLString) else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (_, http) = try await transport(request)
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ContactsAllowlistKVClientTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ContactsAllowlistKVClient.swift Tests/AnglesiteCoreTests/ContactsAllowlistKVClientTests.swift
git commit -m "feat(#1567): add ContactsAllowlistKVClient for SOCIAL_KV writes"
```

---

### Task 2: Shared `CloudflareAccountLookup` + `ContactsAllowlistSync`

`ContactsAllowlistSync.pushIfConfigured` needs the same "resolve the token's
first visible Cloudflare account id" lookup that `MicropubContentSync` and
`ReceivedInteractionSync` each already implement as a byte-for-byte-identical
private copy (`private struct CFAccount`/`CFEnvelope` +
`private static func resolveAccountID(apiToken:baseURL:transport:)`). Adding
a fourth private copy would triplicate — extract it once as
`CloudflareAccountLookup` and have all three (plus the new one) delegate to
it, deleting the two existing private copies in the same task.

**Files:**
- Create: `Sources/AnglesiteCore/CloudflareAccountLookup.swift`
- Test: `Tests/AnglesiteCoreTests/CloudflareAccountLookupTests.swift`
- Create: `Sources/AnglesiteCore/ContactsAllowlistSync.swift`
- Test: `Tests/AnglesiteCoreTests/ContactsAllowlistSyncTests.swift`
- Modify: `Sources/AnglesiteCore/MicropubContentSync.swift:288` (call site), `:296-310` (delete private duplicate)
- Modify: `Sources/AnglesiteCore/ReceivedInteractionSync.swift:91` (call site), `:54-71` (delete private duplicate)

**Interfaces:**
- Consumes: `ContactStore` (`Sources/AnglesiteCore/ContactStore.swift:8`, `init(configDirectory:)`, `func knownMeURLs() throws -> Set<String>`); `ContactsAllowlistKVClient` from Task 1; `SiteConfigStore.read(from:fileManager:)` (`Sources/AnglesiteCore/SiteConfigStore.swift:211`); `SiteSettings.provisionedWorkerResources?.kvNamespaceID` (`Sources/AnglesiteCore/WorkerComposition.swift:108`); `CloudflareAPICredentials.resolve(secretStore:)` (`Sources/AnglesiteCore/CloudflareAPICredentials.swift:40`); `SecretStore`, `PlatformSecretStore.make()`; `LogCenter.shared.append(source:stream:text:)`; `CloudflareTransport` (`Sources/AnglesiteCore/CloudflareReading.swift:78`).
- Produces:
  - `enum CloudflareAccountLookup { static func resolveAccountID(apiToken: String, baseURL: String, transport: CloudflareTransport) async -> String? }` (module-internal, no `public`) — consumed by `MicropubContentSync`, `ReceivedInteractionSync`, `ContactsAllowlistSync`, and by Task 5 only indirectly (through `ContactsAllowlistSync`).
  - `public enum ContactsAllowlistSync { static func push(store: ContactStore, client: ContactsAllowlistKVClient) async; static func pushIfConfigured(configDirectory: URL, secretStore: any SecretStore = PlatformSecretStore.make(), baseURL: String = ..., transport: @escaping CloudflareTransport = ...) async }` — consumed by Tasks 4 and 5.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/CloudflareAccountLookupTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

struct CloudflareAccountLookupTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/")!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!
    }

    @Test("resolves the first account id from a successful envelope")
    func resolvesFirstAccountID() async {
        let body = Data("""
        {"success": true, "result": [{"id": "acct1"}, {"id": "acct2"}]}
        """.utf8)
        let accountID = await CloudflareAccountLookup.resolveAccountID(
            apiToken: "token", baseURL: "https://api.cloudflare.com/client/v4",
            transport: { _ in (body, Self.response(200)) })
        #expect(accountID == "acct1")
    }

    @Test("returns nil on a non-2xx response")
    func returnsNilOnHTTPError() async {
        let accountID = await CloudflareAccountLookup.resolveAccountID(
            apiToken: "token", baseURL: "https://api.cloudflare.com/client/v4",
            transport: { _ in (Data(), Self.response(403)) })
        #expect(accountID == nil)
    }

    @Test("returns nil when the envelope reports success: false")
    func returnsNilOnUnsuccessfulEnvelope() async {
        let body = Data("""
        {"success": false, "result": null}
        """.utf8)
        let accountID = await CloudflareAccountLookup.resolveAccountID(
            apiToken: "token", baseURL: "https://api.cloudflare.com/client/v4",
            transport: { _ in (body, Self.response(200)) })
        #expect(accountID == nil)
    }

    @Test("returns nil when the result list is empty")
    func returnsNilOnEmptyResult() async {
        let body = Data("""
        {"success": true, "result": []}
        """.utf8)
        let accountID = await CloudflareAccountLookup.resolveAccountID(
            apiToken: "token", baseURL: "https://api.cloudflare.com/client/v4",
            transport: { _ in (body, Self.response(200)) })
        #expect(accountID == nil)
    }
}
```

```swift
// Tests/AnglesiteCoreTests/ContactsAllowlistSyncTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

struct ContactsAllowlistSyncTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/")!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!
    }

    private static func makeConfigDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("contacts-allowlist-sync-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("push reads the store's known me-URLs and forwards them to the client")
    func pushForwardsKnownMeURLs() async throws {
        let configDir = Self.makeConfigDir()
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }
        let store = ContactStore(configDirectory: configDir)
        try await store.add(Contact(me: URL(string: "https://alice.example")!, displayName: "Alice"))

        let captured = CapturedURLs()
        let client = ContactsAllowlistKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                if let body = request.httpBody, let urls = try? JSONDecoder().decode([String].self, from: body) {
                    await captured.set(urls)
                }
                return (Data(), Self.response(200))
            })

        await ContactsAllowlistSync.push(store: store, client: client)

        #expect(await captured.value == ["alice.example"])
    }

    @Test("push logs and does not throw when the client fails")
    func pushSwallowsClientFailure() async throws {
        let configDir = Self.makeConfigDir()
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }
        let store = ContactStore(configDirectory: configDir)
        let client = ContactsAllowlistKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { _ in (Data(), Self.response(500)) })

        // Must not throw and must not hang — the whole point of `push` is that it's safe to call
        // fire-and-forget from a UI action.
        await ContactsAllowlistSync.push(store: store, client: client)
    }

    @Test("pushIfConfigured no-ops (no network call) when SOCIAL_KV has not been provisioned")
    func noOpsWithoutKVNamespace() async {
        let configDir = Self.makeConfigDir()
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }

        await ContactsAllowlistSync.pushIfConfigured(
            configDirectory: configDir,
            secretStore: FakeSecretStore(token: "unused"),
            transport: { _ in
                Issue.record("transport must not be called with no provisioned SOCIAL_KV namespace")
                struct UnexpectedNetworkCall: Error {}
                throw UnexpectedNetworkCall()
            })
    }

    @Test("pushIfConfigured no-ops (no network call) when no Cloudflare token is available")
    func noOpsWithoutToken() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let configDir = Self.makeConfigDir()
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }
        try await SiteConfigStore(configDirectory: configDir).save(
            SiteSettings(provisionedWorkerResources: .init(kvNamespaceID: "ns1")))

        await ContactsAllowlistSync.pushIfConfigured(
            configDirectory: configDir,
            secretStore: FakeSecretStore(token: nil),
            transport: { _ in
                Issue.record("transport must not be called with no Cloudflare token")
                struct UnexpectedNetworkCall: Error {}
                throw UnexpectedNetworkCall()
            })
    }

    @Test("pushIfConfigured resolves the account id and pushes the current allowlist")
    func resolvesAccountAndPushes() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let configDir = Self.makeConfigDir()
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }
        try await SiteConfigStore(configDirectory: configDir).save(
            SiteSettings(provisionedWorkerResources: .init(kvNamespaceID: "ns1")))
        let store = ContactStore(configDirectory: configDir)
        try await store.add(Contact(me: URL(string: "https://alice.example")!, displayName: "Alice"))

        let accountsBody = Data("""
        {"success": true, "result": [{"id": "acct1"}]}
        """.utf8)
        let seenAuthorization = SeenHeader()
        let capturedPUT = CapturedURLs()

        await ContactsAllowlistSync.pushIfConfigured(
            configDirectory: configDir,
            secretStore: FakeSecretStore(token: "token"),
            transport: { request in
                await seenAuthorization.record(request.value(forHTTPHeaderField: "Authorization"))
                if request.url!.path.hasSuffix("/accounts") { return (accountsBody, Self.response(200)) }
                if request.url!.path.hasSuffix("/values/contacts:allowlist") {
                    if let body = request.httpBody, let urls = try? JSONDecoder().decode([String].self, from: body) {
                        await capturedPUT.set(urls)
                    }
                    return (Data(), Self.response(200))
                }
                return (Data(), Self.response(404))
            })

        #expect(await capturedPUT.value == ["alice.example"])
        #expect(await seenAuthorization.value == "Bearer token")
    }
}

private struct FakeSecretStore: SecretStore {
    let token: String?
    func read(account: String) throws -> String? { account == SecretAccounts.cloudflareToken ? token : nil }
    func write(_ value: String, account: String) throws {}
    func delete(account: String) throws {}
}

private actor CapturedURLs {
    private(set) var value: [String]?
    func set(_ urls: [String]) { value = urls }
}

private actor SeenHeader {
    private(set) var value: String?
    func record(_ value: String?) { self.value = value }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter "CloudflareAccountLookupTests|ContactsAllowlistSyncTests"`
Expected: FAIL to compile — neither `CloudflareAccountLookup` nor `ContactsAllowlistSync` exist yet.

- [ ] **Step 3: Write the implementation**

First, the shared helper:

```swift
// Sources/AnglesiteCore/CloudflareAccountLookup.swift
import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared "resolve the token's first visible Cloudflare account id" lookup (#1567 review) — used
/// by every `*Sync`/`*IfConfigured` orchestrator that needs an account id but has no
/// separately-stored one to key off (unlike #587's `ProvisionedResources.inboxAccountID`). A
/// personal Anglesite deployment has exactly one Cloudflare account per token, so "just take the
/// first account" is always correct. Previously duplicated privately, byte-for-byte, in both
/// `MicropubContentSync` and `ReceivedInteractionSync` — consolidated here so `ContactsAllowlistSync`
/// doesn't add a third copy.
enum CloudflareAccountLookup {
    private struct CFAccount: Decodable, Sendable { let id: String }
    private struct CFEnvelope: Decodable, Sendable { let success: Bool; let result: [CFAccount]? }

    static func resolveAccountID(apiToken: String, baseURL: String, transport: CloudflareTransport) async -> String? {
        guard let url = URL(string: "\(baseURL)/accounts?per_page=1") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        guard let (data, http) = try? await transport(request), (200..<300).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(CFEnvelope.self, from: data), envelope.success
        else { return nil }
        return envelope.result?.first?.id
    }
}
```

Then update the two existing call sites to delegate to it instead of their own private copy.

In `Sources/AnglesiteCore/MicropubContentSync.swift`, change line 288 from:

```swift
        guard let accountID = await Self.resolveAccountID(apiToken: token, baseURL: baseURL, transport: transport)
```

to:

```swift
        guard let accountID = await CloudflareAccountLookup.resolveAccountID(apiToken: token, baseURL: baseURL, transport: transport)
```

and delete lines 296-310 (the private `CFAccount`/`CFEnvelope` structs and `resolveAccountID` — everything between the end of `pullAndCommitIfConfigured` and the enum's closing `}`), so the file ends with:

```swift
        let client = MicropubPostD1Client(
            accountID: accountID, databaseID: databaseID, apiToken: token, baseURL: baseURL, transport: transport)
        return await pullAndCommit(client: client, siteDirectory: siteDirectory, configDirectory: configDirectory)
    }
}
```

In `Sources/AnglesiteCore/ReceivedInteractionSync.swift`, delete lines 54-71 (the private `CFAccount`/`CFEnvelope` structs and the doc-commented `resolveAccountID`, right after `pullAndCommit`'s closing `}` and before the `pullAndCommitIfConfigured` doc comment), and change what is currently line 91 from:

```swift
        guard let accountID = await Self.resolveAccountID(apiToken: token, baseURL: baseURL, transport: transport)
```

to:

```swift
        guard let accountID = await CloudflareAccountLookup.resolveAccountID(apiToken: token, baseURL: baseURL, transport: transport)
```

Then the new orchestrator:

```swift
// Sources/AnglesiteCore/ContactsAllowlistSync.swift
import Foundation

/// Pushes the site's contact allowlist (`ContactStore.knownMeURLs()`) to the Worker's
/// `SOCIAL_KV` store (#1567) — both on a contact add/remove and, as the consistency backstop, on
/// every deploy. Both triggers call the same whole-set-replace `push`, so `Config/contacts.json`
/// is always the authoritative source: there's no diffing, only an unconditional overwrite.
public enum ContactsAllowlistSync {
    /// Reads `store`'s current me-URL set and replaces `client`'s `contacts:allowlist` value with
    /// it. Never throws — a failure (network, auth, provisioning) is logged and otherwise
    /// invisible; the next successful call (the next contact change, or the next deploy) retries
    /// with the current state, so a missed push self-heals rather than needing a retry queue.
    public static func push(store: ContactStore, client: ContactsAllowlistKVClient) async {
        do {
            let meURLs = try await store.knownMeURLs()
            try await client.putAllowlist(meURLs)
        } catch {
            await LogCenter.shared.append(
                source: "ContactsAllowlistSync", stream: .stderr,
                text: "Failed to push contacts allowlist to SOCIAL_KV: \(error). Will retry on the "
                    + "next contact change or deploy.")
        }
    }

    /// Reads the site's `SiteSettings` and Cloudflare API token from `secretStore`; no-ops (no
    /// network call) unless `SOCIAL_KV` has been provisioned
    /// (`provisionedWorkerResources.kvNamespaceID`) and a token is available — i.e. the site has
    /// never been deployed yet. `configDirectory` is the package's `Config/` directory
    /// (`AnglesitePackage.configURL`).
    public static func pushIfConfigured(
        configDirectory: URL,
        secretStore: any SecretStore = PlatformSecretStore.make(),
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) async {
        guard let settings = try? SiteConfigStore.read(from: configDirectory),
              let namespaceID = settings.provisionedWorkerResources?.kvNamespaceID, !namespaceID.isEmpty
        else { return }
        guard let token = try? await CloudflareAPICredentials.resolve(secretStore: secretStore), !token.isEmpty
        else { return }
        guard let accountID = await CloudflareAccountLookup.resolveAccountID(apiToken: token, baseURL: baseURL, transport: transport)
        else { return }

        let store = ContactStore(configDirectory: configDirectory)
        let client = ContactsAllowlistKVClient(
            accountID: accountID, namespaceID: namespaceID, apiToken: token, baseURL: baseURL, transport: transport)
        await push(store: store, client: client)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter "CloudflareAccountLookupTests|ContactsAllowlistSyncTests|MicropubContentSyncTests|ReceivedInteractionSyncTests"`
Expected: PASS — the 4 new `CloudflareAccountLookupTests`, the 5 `ContactsAllowlistSyncTests`, and (unchanged behavior after the refactor) the existing `MicropubContentSyncTests`/`ReceivedInteractionSyncTests` suites all still pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/CloudflareAccountLookup.swift Tests/AnglesiteCoreTests/CloudflareAccountLookupTests.swift \
        Sources/AnglesiteCore/ContactsAllowlistSync.swift Tests/AnglesiteCoreTests/ContactsAllowlistSyncTests.swift \
        Sources/AnglesiteCore/MicropubContentSync.swift Sources/AnglesiteCore/ReceivedInteractionSync.swift
git commit -m "feat(#1567): add ContactsAllowlistSync push orchestrator

Extracts the account-id lookup MicropubContentSync/ReceivedInteractionSync
each duplicated privately into a shared CloudflareAccountLookup, rather than
adding a third copy for the new contacts allowlist push."
```

---

### Task 3: `DeployCoordinator.runPostDeploySequencing` gets a `pushContactsAllowlist` step

**Files:**
- Modify: `Sources/AnglesiteCore/OperationProgress.swift`
- Modify: `Sources/AnglesiteCore/DeployCoordinator.swift:442-483` (`runPostDeploySequencing`)
- Modify: `Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift:625-740`

**Interfaces:**
- Consumes: existing `OperationProgress` shape (`Sources/AnglesiteCore/OperationProgress.swift`).
- Produces: `OperationProgress.deployPushingContactsAllowlist` constant; `DeployCoordinator.runPostDeploySequencing(..., pushContactsAllowlist: () async -> Void = {})` — consumed by Task 5.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift`, immediately after `postDeploySequencingRunsBackfillLast` (after line 728's closing `}`):

```swift
    @Test("pushContactsAllowlist runs last, after backfillActivityPubOutbox, with a milestone immediately before it")
    func postDeploySequencingRunsContactsAllowlistPushLast() async {
        let recorder = CallRecorder()
        await DeployCoordinator.runPostDeploySequencing(
            onMilestone: { progress in recorder.record("milestone:\(progress.phase)") },
            sendWebmentions: { recorder.record("send") },
            publishStandardSite: { recorder.record("standardsite") },
            publishStandardSiteGraph: { recorder.record("standardsitegraph") },
            syndicate: { recorder.record("syndicate") },
            notifySubscribers: { recorder.record("notify") },
            backfillActivityPubOutbox: { recorder.record("backfill") },
            pushContactsAllowlist: { recorder.record("allowlist") }
        )
        #expect(recorder.calls == [
            "milestone:webmentions", "send",
            "milestone:standardSitePublishing", "standardsite",
            "milestone:standardSiteGraphPublishing", "standardsitegraph",
            "milestone:syndicating", "syndicate",
            "milestone:websubPing", "notify",
            "milestone:activityPubBackfill", "backfill",
            "milestone:contactsAllowlistPush", "allowlist",
        ])
    }

    @Test("pushContactsAllowlist defaults to a no-op, so existing call sites without it still compile and run")
    func postDeploySequencingDefaultsContactsAllowlistPushToNoOp() async {
        let recorder = CallRecorder()
        await DeployCoordinator.runPostDeploySequencing(
            onMilestone: { _ in },
            sendWebmentions: { recorder.record("send") },
            syndicate: { recorder.record("syndicate") }
        )
        #expect(recorder.calls == ["send", "syndicate"])
    }
```

Then update the 4 existing tests whose expected `calls` arrays end at `"milestone:activityPubBackfill"` (with no push call, since `pushContactsAllowlist` isn't passed in any of them) to append `"milestone:contactsAllowlistPush"` as the new final element:

In `postDeploySequencingRunsInOrder` (around line 647-654), change:
```swift
        #expect(recorder.calls == [
            "milestone:webmentions", "send",
            "milestone:standardSitePublishing", "standardsite",
            "milestone:standardSiteGraphPublishing", "standardsitegraph",
            "milestone:syndicating", "syndicate",
            "milestone:websubPing", "notify",
            "milestone:activityPubBackfill",
        ])
```
to:
```swift
        #expect(recorder.calls == [
            "milestone:webmentions", "send",
            "milestone:standardSitePublishing", "standardsite",
            "milestone:standardSiteGraphPublishing", "standardsitegraph",
            "milestone:syndicating", "syndicate",
            "milestone:websubPing", "notify",
            "milestone:activityPubBackfill",
            "milestone:contactsAllowlistPush",
        ])
```

In `postDeploySequencingDefaultsStandardSitePassesToNoOp` (around line 680-687), change:
```swift
        #expect(recorder.calls == [
            "milestone:webmentions", "send",
            "milestone:standardSitePublishing",
            "milestone:standardSiteGraphPublishing",
            "milestone:syndicating", "syndicate",
            "milestone:websubPing", "notify",
            "milestone:activityPubBackfill",
        ])
```
to:
```swift
        #expect(recorder.calls == [
            "milestone:webmentions", "send",
            "milestone:standardSitePublishing",
            "milestone:standardSiteGraphPublishing",
            "milestone:syndicating", "syndicate",
            "milestone:websubPing", "notify",
            "milestone:activityPubBackfill",
            "milestone:contactsAllowlistPush",
        ])
```

In `postDeploySequencingDefaultsNotifyToNoOp` (around line 698-705), change:
```swift
        #expect(recorder.calls == [
            "milestone:webmentions", "send",
            "milestone:standardSitePublishing",
            "milestone:standardSiteGraphPublishing",
            "milestone:syndicating", "syndicate",
            "milestone:websubPing",
            "milestone:activityPubBackfill",
        ])
```
to:
```swift
        #expect(recorder.calls == [
            "milestone:webmentions", "send",
            "milestone:standardSitePublishing",
            "milestone:standardSiteGraphPublishing",
            "milestone:syndicating", "syndicate",
            "milestone:websubPing",
            "milestone:activityPubBackfill",
            "milestone:contactsAllowlistPush",
        ])
```

In `postDeploySequencingRunsBackfillLast` (around line 720-727), change:
```swift
        #expect(recorder.calls == [
            "milestone:webmentions", "send",
            "milestone:standardSitePublishing", "standardsite",
            "milestone:standardSiteGraphPublishing", "standardsitegraph",
            "milestone:syndicating", "syndicate",
            "milestone:websubPing", "notify",
            "milestone:activityPubBackfill", "backfill",
        ])
```
to:
```swift
        #expect(recorder.calls == [
            "milestone:webmentions", "send",
            "milestone:standardSitePublishing", "standardsite",
            "milestone:standardSiteGraphPublishing", "standardsitegraph",
            "milestone:syndicating", "syndicate",
            "milestone:websubPing", "notify",
            "milestone:activityPubBackfill", "backfill",
            "milestone:contactsAllowlistPush",
        ])
```

(`postDeploySequencingRunsBothPassesRegardless` and `postDeploySequencingDefaultsBackfillToNoOp` use `onMilestone: { _ in }`, so their expectations don't include milestones or the (unpassed) push call — leave them unchanged.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter DeployCoordinatorTests`
Expected: FAIL — the 4 updated tests fail (actual arrays are missing `"milestone:contactsAllowlistPush"`), and the 2 new tests fail to compile (`pushContactsAllowlist` parameter doesn't exist yet).

- [ ] **Step 3: Write the implementation**

In `Sources/AnglesiteCore/OperationProgress.swift`, immediately after the `deployBackfillingActivityPub` constant (after line 80's closing `)`):

```swift
    /// Post-deploy: pushing the contact allowlist (me-URLs) to the future authenticated-read
    /// gate's backing store (#1567).
    static let deployPushingContactsAllowlist = OperationProgress(
        kind: .deploy, phase: "contactsAllowlistPush", label: "Syncing contacts allowlist…"
    )
```

In `Sources/AnglesiteCore/DeployCoordinator.swift`, change the `runPostDeploySequencing` signature and body:

```swift
    public static func runPostDeploySequencing(
        onMilestone: (OperationProgress) -> Void,
        sendWebmentions: () async -> Void,
        publishStandardSite: () async -> Void = {},
        publishStandardSiteGraph: () async -> Void = {},
        syndicate: () async -> Void,
        notifySubscribers: () async -> Void = {},
        backfillActivityPubOutbox: () async -> Void = {},
        /// Contacts allowlist push (#1567): pushes the site's current known me-URLs to their
        /// remote store. Ordered last — unrelated to every other pass here, and (unlike the
        /// others) it's a reconcile that only needs to run once per deploy, not depend on
        /// anything the earlier passes produced. Best-effort and never throws, like every other
        /// step here. Callers without contacts configured pass a no-op.
        pushContactsAllowlist: () async -> Void = {}
    ) async {
        onMilestone(.deployWebmentions)
        await sendWebmentions()
        onMilestone(.deployStandardSitePublishing)
        await publishStandardSite()
        onMilestone(.deployStandardSiteGraphPublishing)
        await publishStandardSiteGraph()
        onMilestone(.deploySyndicating)
        await syndicate()
        onMilestone(.deployNotifyingSubscribers)
        await notifySubscribers()
        onMilestone(.deployBackfillingActivityPub)
        await backfillActivityPubOutbox()
        onMilestone(.deployPushingContactsAllowlist)
        await pushContactsAllowlist()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter DeployCoordinatorTests`
Expected: PASS (all `runPostDeploySequencing` tests, including the 2 new ones)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/OperationProgress.swift Sources/AnglesiteCore/DeployCoordinator.swift Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift
git commit -m "feat(#1567): add pushContactsAllowlist post-deploy step"
```

---

### Task 4: Wire the push into `ContactsModel`

**Files:**
- Modify: `Sources/AnglesiteApp/ContactsModel.swift`
- Modify: `Tests/AnglesiteAppTests/ContactsModelTests.swift`

**Interfaces:**
- Consumes: `ContactsAllowlistSync.pushIfConfigured(configDirectory:secretStore:baseURL:transport:)` from Task 2; `CurrentSite.configDirectory` (`Sources/AnglesiteApp/CurrentSite.swift:35`).
- Produces: `ContactsModel.init(contactsProvider:pushAllowlist:)` — the `pushAllowlist` parameter is a new injectable seam, `@Sendable (URL) async -> Void`, defaulting to `ContactsAllowlistSync.pushIfConfigured`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteAppTests/ContactsModelTests.swift`, after `manualAddLeavesLinkedActorNil` (after line 144's closing `}`):

```swift
    @Test("add fires a fire-and-forget allowlist push without blocking or throwing")
    func addTriggersAllowlistPush() async throws {
        let recorder = PushRecorder()
        let model = ContactsModel(
            contactsProvider: FakeContactsProvider(result: .success([])),
            pushAllowlist: { url in await recorder.record(url) })
        let site = try Self.makeSite()
        model.configure(site: site)
        await model.reload()

        await model.add(me: URL(string: "https://alice.example")!, displayName: "Alice")
        await recorder.waitForCall()

        #expect(await recorder.calls == [site.configDirectory])
    }

    @Test("update fires a fire-and-forget allowlist push")
    func updateTriggersAllowlistPush() async throws {
        let recorder = PushRecorder()
        let model = ContactsModel(
            contactsProvider: FakeContactsProvider(result: .success([])),
            pushAllowlist: { url in await recorder.record(url) })
        model.configure(site: try Self.makeSite())
        await model.reload()
        await model.add(me: URL(string: "https://alice.example")!, displayName: "Alice")
        await recorder.waitForCall()
        var added = try #require(model.contacts.first)
        added.displayName = "Alice Renamed"

        await model.update(added)
        await recorder.waitForCall(count: 2)

        #expect(await recorder.calls.count == 2)
    }

    @Test("remove fires a fire-and-forget allowlist push")
    func removeTriggersAllowlistPush() async throws {
        let recorder = PushRecorder()
        let model = ContactsModel(
            contactsProvider: FakeContactsProvider(result: .success([])),
            pushAllowlist: { url in await recorder.record(url) })
        model.configure(site: try Self.makeSite())
        await model.reload()
        await model.add(me: URL(string: "https://alice.example")!, displayName: "Alice")
        await recorder.waitForCall()
        let added = try #require(model.contacts.first)

        await model.remove(added)
        await recorder.waitForCall(count: 2)

        #expect(await recorder.calls.count == 2)
    }
```

Add this helper actor at the bottom of the file, alongside the existing `private struct FakeContactsProvider`:

```swift
/// Records `pushAllowlist` invocations from a detached `Task`, and lets a test await the Nth
/// call deterministically instead of racing an unstructured Task with a sleep.
private actor PushRecorder {
    private(set) var calls: [URL] = []
    private var continuations: [(Int, CheckedContinuation<Void, Never>)] = []

    func record(_ url: URL) {
        calls.append(url)
        continuations.removeAll { count, continuation in
            guard calls.count >= count else { return false }
            continuation.resume()
            return true
        }
    }

    func waitForCall(count: Int = 1) async {
        if calls.count >= count { return }
        await withCheckedContinuation { continuation in
            continuations.append((count, continuation))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter ContactsModelTests`
Expected: FAIL to compile — `ContactsModel.init` has no `pushAllowlist` parameter yet.

- [ ] **Step 3: Write the implementation**

In `Sources/AnglesiteApp/ContactsModel.swift`, add a stored property and change `init` (near the top, after the existing `private let contactsProvider: ContactsProviding` on line 38):

```swift
    private let contactsProvider: ContactsProviding
    /// Contacts allowlist push (#1567): fire-and-forget after each successful mutation, never
    /// awaited inline — `add`/`update`/`remove` must return as soon as the local `ContactStore`
    /// write completes, not wait on a network round trip. Injectable so tests can observe calls
    /// without touching the network (mirrors `contactsProvider`'s DI seam); production default
    /// is the real Cloudflare push.
    private let pushAllowlist: @Sendable (URL) async -> Void
    private var configDirectory: URL?

    init(
        contactsProvider: ContactsProviding = SystemContactsProvider(),
        pushAllowlist: @escaping @Sendable (URL) async -> Void = { dir in
            await ContactsAllowlistSync.pushIfConfigured(configDirectory: dir)
        }
    ) {
        self.contactsProvider = contactsProvider
        self.pushAllowlist = pushAllowlist
    }
```

Update `configure(site:)` to record `configDirectory` (add one line inside the existing method body, right after `store = ContactStore(configDirectory: site.configDirectory)`):

```swift
    func configure(site: CurrentSite) {
        store = ContactStore(configDirectory: site.configDirectory)
        configDirectory = site.configDirectory
        contacts = []
        loadState = .idle
        suggestions = []
        scanFailure = nil
        writeFailure = nil
        dismissedSuggestionKeys = []
    }
```

Add a private helper and call it from `add`/`update`/`remove` right after each successful (or failed — the push always fires; the allowlist is a set of me-URLs, not written-vs-not) write. Replace the three methods:

```swift
    func add(me: URL, displayName: String, linkedActor: URL? = nil) async {
        guard let store else { return }
        let contact = Contact(me: me, displayName: displayName, linkedActor: linkedActor)
        do {
            try await store.add(contact)
            writeFailure = nil
        } catch {
            writeFailure = "\(error)"
        }
        await reload()
        firePushAllowlist()
    }

    func update(_ contact: Contact) async {
        guard let store else { return }
        do {
            try await store.update(contact)
            writeFailure = nil
        } catch {
            writeFailure = "\(error)"
        }
        await reload()
        firePushAllowlist()
    }

    func remove(_ contact: Contact) async {
        guard let store else { return }
        do {
            try await store.remove(id: contact.id)
            writeFailure = nil
        } catch {
            writeFailure = "\(error)"
        }
        await reload()
        firePushAllowlist()
    }
```

And add the helper near the bottom of the type, alongside `suggestionKey(_:)`:

```swift
    /// Fires the allowlist push as a detached `Task` so `add`/`update`/`remove` return as soon as
    /// the local write (and reload) finish — the push is best-effort and must never block a UI
    /// action on a network round trip (#1567 design §3/§4). A failed local write still fires this:
    /// `knownMeURLs()` is re-read fresh inside the push, so it always reflects whatever's actually
    /// on disk regardless of whether this particular call succeeded.
    private func firePushAllowlist() {
        guard let configDirectory else { return }
        Task { await pushAllowlist(configDirectory) }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ContactsModelTests`
Expected: PASS (all existing tests plus the 3 new ones)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/ContactsModel.swift Tests/AnglesiteAppTests/ContactsModelTests.swift
git commit -m "feat(#1567): push contacts allowlist after add/update/remove"
```

---

### Task 5: Wire the push into the deploy flow

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift:1033-1080` (the `DeployCoordinator.runPostDeploySequencing` call site inside `runDeploy`'s `.succeeded` case)

**Interfaces:**
- Consumes: `DeployCoordinator.runPostDeploySequencing(..., pushContactsAllowlist:)` from Task 3; `ContactsAllowlistSync.pushIfConfigured(configDirectory:secretStore:)` from Task 2; `self.keychain: any SecretStore` (`Sources/AnglesiteApp/DeployModel.swift:162`); `configDirectory: URL` (the `runDeploy` parameter, already in scope at this call site).
- Produces: nothing new consumed elsewhere — this is the final integration point.

This task has no dedicated new unit test: `runDeploy`'s other post-deploy closures (`onDomainAttach`, `onMarkdownForAgents`, the `runPostDeploySequencing` closures themselves) are not unit-tested at this integration depth either — `DeployModelTests.swift` doesn't exercise them, since a real test would require a fully scripted `DeployCommand`/`SocialWorkerProvisionCommand`/container stack. Correctness here is covered by Task 2's `ContactsAllowlistSyncTests` (the logic being wired) and Task 3's `DeployCoordinatorTests` (the sequencing being wired into) — this task is pure wiring, verified by a successful build and the full test suite still passing.

- [ ] **Step 1: Add the closure**

In `Sources/AnglesiteApp/DeployModel.swift`, inside the `runPostDeploySequencing` call (around line 1033), add a new `pushContactsAllowlist` argument after `backfillActivityPubOutbox`:

```swift
            await DeployCoordinator.runPostDeploySequencing(
                onMilestone: { [weak self] progress in self?.emitPostDeployMilestone(progress, siteID: siteID) },
                sendWebmentions: { [weak self] in
                    guard let self else { return }
                    await self.webmentionCommand.send(
                        siteID: siteID, siteDirectory: siteDirectory, configDirectory: configDirectory, siteBase: url
                    )
                },
                publishStandardSite: { [weak self] in
                    guard let self else { return }
                    await self.standardSitePublishCommand.publish(
                        siteID: siteID, siteDirectory: siteDirectory, configDirectory: configDirectory
                    )
                },
                publishStandardSiteGraph: { [weak self] in
                    guard let self else { return }
                    await self.standardSiteGraphPublishCommand.publish(
                        siteID: siteID, siteDirectory: siteDirectory, configDirectory: configDirectory
                    )
                },
                syndicate: { [weak self] in
                    guard let self else { return }
                    await self.posseCommand.syndicate(
                        siteID: siteID, siteDirectory: siteDirectory, configDirectory: configDirectory, siteBase: url
                    )
                },
                notifySubscribers: { [weak self] in
                    guard let self, websubProvisioned else { return }
                    _ = await self.websubPing.notify(
                        siteURL: siteURL ?? url.absoluteString,
                        source: "websub:\(siteID)"
                    )
                },
                backfillActivityPubOutbox: { [weak self] in
                    guard let self, activitypubProvisioned else { return }
                    _ = await self.activityPubOutboxBackfill.backfill(
                        siteID: siteID,
                        siteDirectory: siteDirectory,
                        configDirectory: configDirectory,
                        siteBase: url,
                        secretStore: self.keychain
                    )
                },
                pushContactsAllowlist: { [weak self] in
                    guard let self else { return }
                    await ContactsAllowlistSync.pushIfConfigured(
                        configDirectory: configDirectory, secretStore: self.keychain
                    )
                }
            )
```

- [ ] **Step 2: Build to verify it compiles**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED (run `xcodegen generate` first if the worktree's `.xcodeproj` predates this change — see `docs/testing-macos-app.md`)

- [ ] **Step 3: Run the full test suite**

Run: `swift test --package-path .`
Expected: PASS — every existing suite plus the new tests from Tasks 1-4. Per `CONTRIBUTING.md`, since this touches `Sources/AnglesiteApp`, run this on the Xcode 27 toolchain locally (`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .` if the default toolchain resolves elsewhere — see `docs/testing-macos-app.md`).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/DeployModel.swift
git commit -m "feat(#1567): push contacts allowlist as a post-deploy step"
```

---

## Done criteria

- `ContactsAllowlistKVClient` and `ContactsAllowlistSync` exist in `AnglesiteCore` with passing tests (Tasks 1-2).
- `DeployCoordinator.runPostDeploySequencing` runs the allowlist push last, behind a milestone, with existing callers unaffected by the new defaulted parameter (Task 3).
- `ContactsModel.add`/`update`/`remove` each fire a non-blocking allowlist push (Task 4).
- A successful deploy re-pushes the allowlist unconditionally as the reconcile backstop (Task 5).
- `swift test --package-path .` passes in full, on the Xcode 27 toolchain.
- No changes to `Resources/Template/worker/worker.ts`, `SocialWorkerProvisionCommand.swift`, `WorkerComposition.swift`'s provisioning logic, or any `worker/migrations/*.sql` file.

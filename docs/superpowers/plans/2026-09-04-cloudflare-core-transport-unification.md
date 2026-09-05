# Cloudflare Core Transport Unification (Phase 1 of #1818) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the shared HTTP primitives duplicated across `HTTPCloudflareClient.swift`'s six protocol conformances into one reusable, directly-testable type; split that 997-line file into one file per conformance on top of it; and migrate the app's Cloudflare stragglers off raw `URLSession` construction onto the codebase's existing closure-based `CloudflareTransport` injection seam.

**Architecture:** A new internal type `CloudflareHTTPCore` in `Sources/AnglesiteCore/` owns the envelope-decode/pagination/auth-header/error-mapping primitives (currently ten `private` methods plus several `private` wire-format structs duplicated by file-scoping inside `HTTPCloudflareClient.swift`). `HTTPCloudflareClient` becomes a thin composition root holding one `CloudflareHTTPCore` instance; each of its six protocol conformances moves to its own file, all calling into the shared core. Two genuinely independent raw-`URLSession` clients (`CloudflareRUMAnalyticsClient`, `CloudflareWebAnalyticsClient`) switch from injecting a concrete `URLSession` to injecting the existing public `CloudflareTransport` closure typealias — but keep their own wire-envelope shapes and `CloudflareWebAnalyticsError` error type, since those genuinely differ from the v4 REST `{success,result,errors}` envelope `CloudflareHTTPCore` decodes. Two more (`CloudflareAPITokenVerifier`, `CloudflareOAuthClient`) already inject a closure but each redeclares an identical `Transport` typealias; these dedupe onto the shared `CloudflareTransport` type directly.

**Tech Stack:** Swift 6.4, SwiftPM (`AnglesiteCore` library target), Swift Testing (`@Test`/`@Suite`), `scripts/swift-test.sh`.

## Global Constraints

- This is **Phase 1 of 3** from the owner-approved plan on issue #1818 (comment 2026-09-04). It lands as its own PR — do not start Phase 2 (App `CloudflareTaskModel` base) or Phase 3 (`ExternalLLMVerifier`) work in this plan; those get their own plans once this one has landed and its final API shape is settled.
- Preserve `CloudflareError` mapping **exactly** as it exists today: HTTP 401/403 → `.unauthorized`; any other non-2xx → `.http(status:)`; a body that fails to decode as the expected shape → `.malformedResponse`; a decoded envelope with `success: false` or a missing `result` → `.api(message: env.errors?.first?.message ?? "<fallback>")`. `Tests/AnglesiteCoreTests/CloudflareClientTests.swift`, `CloudflareWritingTests.swift`, `HTTPCloudflareClientAISearchTests.swift`, and `HTTPCloudflareClientRegistrarTests.swift` assert on this mapping — they must all continue to pass unmodified in behavior (only import/reference changes, if any, are allowed) through every task in this plan.
- The new shared type is named **`CloudflareHTTPCore`** — never `CloudflareTransport`. `CloudflareTransport` is already a **public** closure typealias (`Sources/AnglesiteCore/CloudflareReading.swift:83`, `@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)`) used as the injection seam by a dozen-plus other Core types; reusing that name for the new struct would collide with it in the same module.
- **Correction to the issue text** — do not force `CloudflareRUMAnalyticsClient`/`CloudflareWebAnalyticsClient` through `CloudflareHTTPCore`'s envelope decoder. Their wire shape is `{"result": ...}` with a separate `{"errors": [...]}` shape on failure (no `success` flag, no `result_info` pagination), and their error type is `CloudflareWebAnalyticsError`, not `CloudflareError` — callers `switch`/pattern-match on `CloudflareWebAnalyticsError` cases (`.noAccount`, `.noMatchingSite`, `.missingToken`) that `CloudflareError` has no equivalent for. These two clients only change their *transport injection* (concrete `URLSession` → the `CloudflareTransport` closure), not their envelope decoding or error type.
- **Correction to the issue text** — `CloudflareAccountLookup` (`Sources/AnglesiteCore/CloudflareAccountLookup.swift`) already takes `transport: CloudflareTransport` as a parameter; it is not one of the "stragglers" and needs no change in this plan.
- No back-compat shims. These are internal app types, not a published library — change initializer signatures directly and fix the (few) call sites rather than keeping a deprecated parameter alongside a new one.
- Every task ends with `scripts/swift-test.sh --filter CloudflareTests` (or the specific suite under test) passing, and the final task runs the full `scripts/swift-test.sh` before commit.
- Conventional commit subjects ≤72 characters; reference `#1818` in the subject (see `CONTRIBUTING.md` ▸ "Commits and pull requests" — do **not** use `fix(#1818):`/`close(#1818):` as the commit type since this PR does not close the tracking issue, only its Phase 1; use `refactor(#1818): ...` or similar non-closing type for every commit in this plan).

---

### Task 1: Create `CloudflareHTTPCore` — the shared transport primitives, extracted and directly tested

**Files:**
- Create: `Sources/AnglesiteCore/CloudflareHTTPCore.swift`
- Create: `Tests/AnglesiteCoreTests/CloudflareHTTPCoreTests.swift`

**Interfaces:**
- Produces: `struct CloudflareHTTPCore` (internal, `Sendable`) with `init(baseURL: String, transport: @escaping CloudflareTransport)` and methods: `getEnvelope<T>(_ path: String, apiToken: String, as: T.Type) async throws -> CFEnvelope<T>`, `getEnvelope<T>(url: URL, apiToken: String, as: T.Type) async throws -> CFEnvelope<T>`, `get<T>(_ path: String, apiToken: String, as type: T.Type) async throws -> T`, `get<T>(url: URL, apiToken: String, as type: T.Type) async throws -> T`, `paginated<T>(_ path: String, apiToken: String, as type: T.Type) async throws -> [T]`, `send<Body>(method: String, _ path: String, body: Body, apiToken: String, passthroughStatuses: Set<Int> = []) async throws -> (Data, HTTPURLResponse)`, `fetchRaw(_ path: String, apiToken: String, passthroughStatuses: Set<Int> = []) async throws -> (Data, HTTPURLResponse)`, `mutate<Body>(method: String, _ path: String, body: Body, apiToken: String) async throws`, `post<Body, T>(_ path: String, body: Body, apiToken: String, as type: T.Type) async throws -> T`, `static func decodeEnvelopeResult<T>(from data: Data, as type: T.Type) throws -> T`, `resolveAccountID(apiToken: String) async throws -> String`. Also produces internal (not `private`) wire types: `CFResultInfo`, `CFEnvelope<T>`, `CFEmpty`, `CFAccount` — all moved here verbatim from `HTTPCloudflareClient.swift`'s current top-of-file `private` declarations (lines 9-27, 66) since `resolveAccountID` and every primitive above need to construct/consume them, and later tasks' split-out conformance files need to reference `CFEnvelope`/`CFAccount` too.
- Consumes: nothing new — `CloudflareTransport` (`CloudflareReading.swift:83`), `CloudflareError` (`CloudflareReading.swift:9-27`), both already public in the same module.

This task is purely additive — `HTTPCloudflareClient.swift` is not touched yet, so no existing test can regress.

- [ ] **Step 1: Write the failing tests for `CloudflareHTTPCore`**

Create `Tests/AnglesiteCoreTests/CloudflareHTTPCoreTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("CloudflareHTTPCore")
struct CloudflareHTTPCoreTests {
    private struct Widget: Codable, Sendable, Equatable { let name: String }

    private static func envelopeBody(success: Bool, result: String?, errorMessage: String? = nil, resultInfo: (page: Int, totalPages: Int)? = nil) -> Data {
        var json = "{\"success\": \(success)"
        if let result { json += ", \"result\": \(result)" }
        if let errorMessage { json += ", \"errors\": [{\"message\": \"\(errorMessage)\"}]" }
        if let resultInfo { json += ", \"result_info\": {\"page\": \(resultInfo.page), \"total_pages\": \(resultInfo.totalPages)}" }
        json += "}"
        return Data(json.utf8)
    }

    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/client/v4/widgets")!,
                         statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test("get decodes a successful envelope's result")
    func getDecodesResult() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            return (Self.envelopeBody(success: true, result: "{\"name\": \"gadget\"}"), Self.response(200))
        }
        let widget: Widget = try await core.get("/widgets/1", apiToken: "tok", as: Widget.self)
        #expect(widget == Widget(name: "gadget"))
    }

    @Test("401 surfaces as .unauthorized")
    func unauthorizedMapping() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Data(), Self.response(401))
        }
        await #expect(throws: CloudflareError.unauthorized) {
            _ = try await core.get("/widgets/1", apiToken: "tok", as: Widget.self)
        }
    }

    @Test("a non-2xx, non-401/403 status surfaces as .http(status:)")
    func httpStatusMapping() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Data(), Self.response(500))
        }
        await #expect(throws: CloudflareError.http(status: 500)) {
            _ = try await core.get("/widgets/1", apiToken: "tok", as: Widget.self)
        }
    }

    @Test("an undecodable body surfaces as .malformedResponse")
    func malformedResponseMapping() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Data("not json".utf8), Self.response(200))
        }
        await #expect(throws: CloudflareError.malformedResponse) {
            _ = try await core.get("/widgets/1", apiToken: "tok", as: Widget.self)
        }
    }

    @Test("success:false surfaces as .api with Cloudflare's message")
    func apiFailureMapping() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Self.envelopeBody(success: false, result: nil, errorMessage: "nope"), Self.response(200))
        }
        await #expect(throws: CloudflareError.api(message: "nope")) {
            _ = try await core.get("/widgets/1", apiToken: "tok", as: Widget.self)
        }
    }

    @Test("paginated walks every page until page == total_pages")
    func paginatedWalksAllPages() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { request in
            let onPageTwo = request.url!.absoluteString.contains("page=2")
            let result = onPageTwo ? "[{\"name\": \"b\"}]" : "[{\"name\": \"a\"}]"
            let info = onPageTwo ? (page: 2, totalPages: 2) : (page: 1, totalPages: 2)
            return (Self.envelopeBody(success: true, result: result, resultInfo: info), Self.response(200))
        }
        let widgets: [Widget] = try await core.paginated("/widgets?per_page=1", apiToken: "tok", as: Widget.self)
        #expect(widgets == [Widget(name: "a"), Widget(name: "b")])
    }

    @Test("send passes through an opted-in status instead of throwing")
    func sendPassthroughStatus() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Data("{}".utf8), Self.response(400))
        }
        let (_, http) = try await core.send(method: "POST", "/widgets", body: Widget(name: "x"), apiToken: "tok", passthroughStatuses: [400])
        #expect(http.statusCode == 400)
    }

    @Test("mutate succeeds silently on success:true")
    func mutateSucceeds() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Self.envelopeBody(success: true, result: nil), Self.response(200))
        }
        try await core.mutate(method: "PUT", "/widgets/1", body: Widget(name: "x"), apiToken: "tok")
    }

    @Test("resolveAccountID returns the token's first visible account id")
    func resolveAccountIDSucceeds() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Self.envelopeBody(success: true, result: "[{\"id\": \"acct-1\"}]"), Self.response(200))
        }
        let id = try await core.resolveAccountID(apiToken: "tok")
        #expect(id == "acct-1")
    }

    @Test("resolveAccountID throws .api when no account is visible")
    func resolveAccountIDThrowsWhenNoAccount() async throws {
        let core = CloudflareHTTPCore(baseURL: "https://api.cloudflare.com/client/v4") { _ in
            (Self.envelopeBody(success: true, result: "[]"), Self.response(200))
        }
        await #expect(throws: CloudflareError.self) {
            _ = try await core.resolveAccountID(apiToken: "tok")
        }
    }
}
```

- [ ] **Step 2: Run the new test file to verify it fails to compile (the type doesn't exist yet)**

Run: `scripts/swift-test.sh --filter CloudflareHTTPCoreTests`
Expected: build failure — `cannot find 'CloudflareHTTPCore' in scope`.

- [ ] **Step 3: Create `CloudflareHTTPCore.swift`**

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Pagination metadata returned alongside list results.
struct CFResultInfo: Decodable, Sendable {
    let page: Int
    let total_pages: Int
}

/// Standard Cloudflare v4 response envelope.
struct CFEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let success: Bool
    let result: T?
    struct APIError: Decodable, Sendable {
        let message: String
        /// Cloudflare's numeric error code (e.g. 7028 `missing_sitemap`). Optional because
        /// only paths that branch on a specific code consult it, and older envelope fixtures
        /// omit it.
        let code: Int?
    }
    let errors: [APIError]?
    let result_info: CFResultInfo?
}

/// Placeholder for write responses where we only check `success`.
struct CFEmpty: Decodable, Sendable {}

struct CFAccount: Decodable, Sendable { let id: String }

/// Shared HTTP primitives for the Cloudflare v4 REST API — envelope decode, pagination,
/// auth header, and `CloudflareError` mapping. Extracted from `HTTPCloudflareClient` (#1818)
/// so every conformance file that struct is split into (and any future Cloudflare v4 client)
/// can share one implementation instead of relying on Swift's file-scoped `private` to fake a
/// single translation unit.
struct CloudflareHTTPCore: Sendable {
    private let baseURL: String
    private let transport: CloudflareTransport

    init(baseURL: String, transport: @escaping CloudflareTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// GET `path`, decode `CFEnvelope<T>`, return the whole envelope or throw a mapped error.
    func getEnvelope<T: Decodable & Sendable>(_ path: String, apiToken: String, as: T.Type) async throws -> CFEnvelope<T> {
        guard let url = URL(string: baseURL + path) else { throw CloudflareError.malformedResponse }
        return try await getEnvelope(url: url, apiToken: apiToken, as: T.self)
    }

    /// GET `url`, decode `CFEnvelope<T>`, return the whole envelope or throw a mapped error.
    /// Takes a pre-built `URL` (rather than a path string) so callers with query values that need
    /// real percent-encoding — e.g. free-text search keywords that may contain `&`/`=`/`+` — can
    /// build the request with `URLComponents`/`URLQueryItem` instead of manual string interpolation.
    func getEnvelope<T: Decodable & Sendable>(url: URL, apiToken: String, as: T.Type) async throws -> CFEnvelope<T> {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await transport(request)
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
        let env: CFEnvelope<T>
        do {
            env = try JSONDecoder().decode(CFEnvelope<T>.self, from: data)
        } catch {
            throw CloudflareError.malformedResponse
        }
        guard env.success else {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "request failed")
        }
        return env
    }

    /// GET `path` and return the decoded `result`, or throw `.api` when it is absent.
    func get<T: Decodable & Sendable>(_ path: String, apiToken: String, as type: T.Type) async throws -> T {
        let env = try await getEnvelope(path, apiToken: apiToken, as: type)
        guard let result = env.result else {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "missing result")
        }
        return result
    }

    /// GET `url` and return the decoded `result`, or throw `.api` when it is absent. See
    /// `getEnvelope(url:apiToken:as:)` for why this pre-built-`URL` variant exists.
    func get<T: Decodable & Sendable>(url: URL, apiToken: String, as type: T.Type) async throws -> T {
        let env = try await getEnvelope(url: url, apiToken: apiToken, as: type)
        guard let result = env.result else {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "missing result")
        }
        return result
    }

    /// Fetch every item across pages (Cloudflare caps `per_page` at 100, so a single page
    /// silently truncates a list with more than 100 items). `path` must already include its
    /// own query string (e.g. `...?per_page=100`); `&page=N` is appended per request.
    func paginated<T: Decodable & Sendable>(_ path: String, apiToken: String, as type: T.Type) async throws -> [T] {
        var all: [T] = []
        var page = 1
        while true {
            let env = try await getEnvelope("\(path)&page=\(page)", apiToken: apiToken, as: [T].self)
            all.append(contentsOf: env.result ?? [])
            guard let info = env.result_info, info.page < info.total_pages else { break }
            page += 1
        }
        return all
    }

    /// Builds and sends a `method` request to `path` with an encoded `body`, then maps
    /// 401/403 to ``CloudflareError/unauthorized`` and any other non-2xx status to
    /// ``CloudflareError/http(status:)``. `passthroughStatuses` lets a caller opt specific
    /// statuses out of the `.http` mapping so it can inspect the response body itself (e.g. a
    /// 400 whose error envelope carries an actionable Cloudflare error code).
    func send<Body: Encodable & Sendable>(
        method: String,
        _ path: String,
        body: Body,
        apiToken: String,
        passthroughStatuses: Set<Int> = []
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: baseURL + path) else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, http) = try await transport(request)
        if passthroughStatuses.contains(http.statusCode) { return (data, http) }
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
        return (data, http)
    }

    /// GET `path` with no body, mapping 401/403 to ``CloudflareError/unauthorized`` and any other
    /// non-2xx status to ``CloudflareError/http(status:)`` — the read-side counterpart to `send`,
    /// for endpoints (like URL Scanner) that don't wrap responses in the `{success, result,
    /// errors}` v4 envelope `getEnvelope`/`get` assume, so those helpers don't fit.
    /// `passthroughStatuses` lets a caller opt specific non-2xx statuses out of the `.http`
    /// mapping to inspect the raw response itself (e.g. a 404 that means "not ready yet" rather
    /// than "doesn't exist").
    func fetchRaw(
        _ path: String, apiToken: String, passthroughStatuses: Set<Int> = []
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: baseURL + path) else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await transport(request)
        if passthroughStatuses.contains(http.statusCode) { return (data, http) }
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
        return (data, http)
    }

    func mutate<Body: Encodable & Sendable>(
        method: String,
        _ path: String,
        body: Body,
        apiToken: String
    ) async throws {
        let (data, _) = try await send(method: method, path, body: body, apiToken: apiToken)
        let env: CFEnvelope<CFEmpty>
        do {
            env = try JSONDecoder().decode(CFEnvelope<CFEmpty>.self, from: data)
        } catch {
            throw CloudflareError.malformedResponse
        }
        if !env.success {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "request failed")
        }
    }

    /// POST `path` with `body`, decode `CFEnvelope<T>`, return its `result` — like `get`, but for
    /// POST calls that need the decoded payload back (unlike `mutate`, which only checks success).
    func post<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ path: String, body: Body, apiToken: String, as type: T.Type
    ) async throws -> T {
        let (data, _) = try await send(method: "POST", path, body: body, apiToken: apiToken)
        return try Self.decodeEnvelopeResult(from: data, as: T.self)
    }

    /// Decodes a `CFEnvelope<T>` response body and returns its `result`, mapping an
    /// undecodable body to ``CloudflareError/malformedResponse`` and a `success: false` or
    /// missing `result` to ``CloudflareError/api(message:)``.
    static func decodeEnvelopeResult<T: Decodable & Sendable>(from data: Data, as type: T.Type) throws -> T {
        let env: CFEnvelope<T>
        do {
            env = try JSONDecoder().decode(CFEnvelope<T>.self, from: data)
        } catch {
            throw CloudflareError.malformedResponse
        }
        guard env.success else {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "request failed")
        }
        guard let result = env.result else {
            throw CloudflareError.api(message: env.errors?.first?.message ?? "missing result")
        }
        return result
    }

    /// Resolves the token's first visible account id — every account-scoped Cloudflare v4
    /// endpoint (Registrar, URL Scanner, AI Search, Workers) needs this.
    func resolveAccountID(apiToken: String) async throws -> String {
        let accounts = try await get("/accounts?per_page=1", apiToken: apiToken, as: [CFAccount].self)
        guard let accountID = accounts.first?.id else {
            throw CloudflareError.api(message: "no Cloudflare account visible to this token")
        }
        return accountID
    }
}
```

- [ ] **Step 4: Run the new tests to verify they pass**

Run: `scripts/swift-test.sh --filter CloudflareHTTPCoreTests`
Expected: PASS, all 10 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/CloudflareHTTPCore.swift Tests/AnglesiteCoreTests/CloudflareHTTPCoreTests.swift
git commit -m "refactor(#1818): extract CloudflareHTTPCore transport primitives"
```

---

### Task 2: Rewire `HTTPCloudflareClient` onto `CloudflareHTTPCore` (single file, behavior-preserving)

**Files:**
- Modify: `Sources/AnglesiteCore/HTTPCloudflareClient.swift`

**Interfaces:**
- Consumes: `CloudflareHTTPCore` (Task 1) — `HTTPCloudflareClient` gets a new `private let core: CloudflareHTTPCore` computed in `init` from the same `transport`/`Self.base` it already has.
- Produces: same public API as before (no change to any `public func` signature in this task) — this is purely an internal-implementation swap. Later tasks depend on this file now referencing `core.xxx(...)` instead of `self.xxx(...)`/bare `xxx(...)` for every primitive call, and on the top-of-file `private` wire structs `CFResultInfo`/`CFEnvelope`/`CFEmpty`/`CFAccount` and the ten primitive methods being **deleted** from this file (they now live only in `CloudflareHTTPCore.swift`).

This is a mechanical, behavior-preserving transformation with no new tests of its own — correctness is verified by the existing suite continuing to pass unchanged.

- [ ] **Step 1: Record the baseline**

Run: `scripts/swift-test.sh --filter "CloudflareClientTests|CloudflareWritingTests|HTTPCloudflareClientAISearchTests|HTTPCloudflareClientRegistrarTests"`
Expected: PASS (record the pass count — it must be identical after Step 3).

- [ ] **Step 2: Apply the transformation**

In `Sources/AnglesiteCore/HTTPCloudflareClient.swift`:

1. Delete the now-duplicated top-of-file `private` declarations that moved to `CloudflareHTTPCore.swift`: `CFResultInfo` (lines 9-12), `CFEnvelope<T>` (14-27), `CFEmpty` (30), and `CFAccount` (66). Leave every other top-of-file wire struct (`CFZone`, `CFDNSSEC`, `CFStringSetting`, `CFSecurityHeader`, `CFDNSRecord`, `CFFullDNSRecord`, `CFRegistrar*`, `CFWorkerScript`, `CFWorkerDomain`, `CFAISearchInstance`, `CFURLScanSubmission`, `CFAgentReadiness*`, `CFScanResult`, `CFEmptyBody`, `CFBotManagement`, `CFRuleset*`, `CFPageShield*`) exactly where they are — Task 3 relocates those.
2. In the struct body, replace the stored property and init:
   ```swift
   public struct HTTPCloudflareClient: CloudflareReading {
       private static let base = "https://api.cloudflare.com/client/v4"
       private let core: CloudflareHTTPCore

       /// The transport parameter exists for tests (fake responses, no network); production uses
       /// ``defaultTransport``.
       public init(transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport) {
           self.core = CloudflareHTTPCore(baseURL: Self.base, transport: transport)
       }
   ```
   (`defaultTransport` is unchanged — leave it exactly as-is.)
3. Delete the ten now-duplicated private primitive methods from this file: both `getEnvelope` overloads (188-215), both `get` overloads (218-234), `paginated` (239-249), `send` (410-428), `fetchRaw` (437-450), `mutate` (452-468), and — in the `CloudflareRegistrarReading` extension — `resolveAccountID` (685-691) and `post`/`decodeEnvelopeResult` (703-728).
4. Replace every call site in this file that invoked one of those ten methods (bare `getEnvelope(...)`, `get(...)`, `paginated(...)`, `send(...)`, `fetchRaw(...)`, `mutate(...)`, `resolveAccountID(...)`, `post(...)`, `Self.decodeEnvelopeResult(...)`) with `core.` prefixed calls (`core.getEnvelope(...)`, `core.get(...)`, `core.paginated(...)`, `core.send(...)`, `core.fetchRaw(...)`, `core.mutate(...)`, `core.resolveAccountID(...)`, `core.post(...)`, `CloudflareHTTPCore.decodeEnvelopeResult(...)`). This touches: `allDNSRecords`, `resolveZoneID`, `zoneState` (and its nested `contents`/fan-out calls), `fetchWAFCustomRules`, `settingIsOn`, `zstdEnabled`, `pageShieldState`, `listDNSRecords`, `workerScriptNames` (all in the base `CloudflareReading` section); every method in the `CloudflareWriting` extension that calls `mutate`/`get`; `accountID(apiToken:)`, `searchDomains`, `checkDomainAvailability` (`CloudflareRegistrarReading`); `registerDomain`, `decodeState` (via `send`), `pollRegistrationStatus` (`CloudflareRegistrarWriting`); `submitAgentReadinessScan`, `agentReadinessResult` (`AgentReadinessScanning`, both call `resolveAccountID` → `core.resolveAccountID`); `createAISearchInstance`, `aiSearchInstanceSource` (`AISearchProvisioning`, same). Do not change any method's logic, branching, or the shape of what it returns/throws — only the receiver of these ten calls.

- [ ] **Step 3: Run the baseline suite again**

Run: `scripts/swift-test.sh --filter "CloudflareClientTests|CloudflareWritingTests|HTTPCloudflareClientAISearchTests|HTTPCloudflareClientRegistrarTests"`
Expected: PASS, same test count as Step 1, all green.

- [ ] **Step 4: Full Core suite sanity check**

Run: `scripts/swift-test.sh --filter AnglesiteCoreTests`
Expected: PASS (confirms nothing outside the four Cloudflare test files broke — e.g. nothing else in Core referenced the now-deleted file-private types).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/HTTPCloudflareClient.swift
git commit -m "refactor(#1818): rewire HTTPCloudflareClient onto CloudflareHTTPCore"
```

---

### Task 3: Split `HTTPCloudflareClient.swift` into one file per conformance

**Files:**
- Modify: `Sources/AnglesiteCore/HTTPCloudflareClient.swift` (shrinks to struct decl + init + `defaultTransport` + `CloudflareReading` conformance only)
- Create: `Sources/AnglesiteCore/HTTPCloudflareClient+Writing.swift`
- Create: `Sources/AnglesiteCore/HTTPCloudflareClient+RegistrarReading.swift`
- Create: `Sources/AnglesiteCore/HTTPCloudflareClient+RegistrarWriting.swift`
- Create: `Sources/AnglesiteCore/HTTPCloudflareClient+AgentReadiness.swift`
- Create: `Sources/AnglesiteCore/HTTPCloudflareClient+AISearch.swift`

**Interfaces:**
- Consumes: `CloudflareHTTPCore`'s `core` property is `private` on `HTTPCloudflareClient` today (Task 2) — Swift's `private` is file-scoped, so an `extension HTTPCloudflareClient` in a *different* file cannot see a `private` stored property of the primary declaration. Change `private let core: CloudflareHTTPCore` to `internal let core: CloudflareHTTPCore` (i.e. drop the `private` keyword) in `HTTPCloudflareClient.swift` as the first step of this task, before moving anything — internal keeps it invisible outside the module (unchanged public API) while making it visible to same-module extension files.
- Produces: no change to any public method signature — this is a pure file move. Each new file keeps the exact `// MARK:` comment that already labels its section as the file's own doc comment.

This is a pure code-motion task — verified by build success and the same baseline suite from Task 2 passing unchanged.

- [ ] **Step 1: Make `core` internal**

In `Sources/AnglesiteCore/HTTPCloudflareClient.swift`, change:
```swift
private let core: CloudflareHTTPCore
```
to:
```swift
let core: CloudflareHTTPCore
```

- [ ] **Step 2: Move the `CloudflareWriting` conformance**

Cut lines 471-678 of the current (post-Task-2) `HTTPCloudflareClient.swift` — the `// MARK: - CloudflareWriting conformance` comment and the `extension HTTPCloudflareClient: CloudflareWriting { ... }` block — into a new file `Sources/AnglesiteCore/HTTPCloudflareClient+Writing.swift`, prefixed with the same license-free header the other Core files use (`import Foundation` + the `FoundationNetworking` conditional import block, copied from the top of `HTTPCloudflareClient.swift`). Move `CFEmptyBody` (used exclusively by `deleteDNSRecord`) into this new file — it becomes `private` there, since after this move nothing outside this file uses it.

`createWAFCustomRule`/`enableZstandardCompression` (in this Writing extension) and `fetchWAFCustomRules`/`zstdEnabled` (staying in the base `CloudflareReading` conformance, per Step 7) both use `CFRuleset`/`CFRulesetRule` — this is the one wire type genuinely shared across two of the six split files. **Leave `CFRuleset`/`CFRulesetRule`'s declarations physically in place in the base `HTTPCloudflareClient.swift` file** (do not move them), but **drop the `private` keyword from both** (`private struct CFRuleset` → `struct CFRuleset`, same for `CFRulesetRule` and its nested `Params`/`Algorithm`) so this new Writing file — a separate translation unit — can see them. Without this change the Writing file fails to compile with "cannot find type 'CFRuleset' in scope."

- [ ] **Step 3: Move the `CloudflareRegistrarReading` conformance**

Cut the `// MARK: - CloudflareRegistrarReading conformance` block (the `extension HTTPCloudflareClient: CloudflareRegistrarReading { ... }`, now containing `accountID(apiToken:)`, `searchDomains`, `checkDomainAvailability` after Task 2 removed `resolveAccountID`/`post`/`decodeEnvelopeResult` from it) into `Sources/AnglesiteCore/HTTPCloudflareClient+RegistrarReading.swift`, with the same import header. Move its wire types `CFRegistrarSearchResult`, `CFRegistrarSearchResponse`, `CFRegistrarCheckResult`, `CFRegistrarCheckResponse`, `CFRegistrarCheckRequest` into this file too — they're used only here.

- [ ] **Step 4: Move the `CloudflareRegistrarWriting` conformance**

Cut the `// MARK: - CloudflareRegistrarWriting conformance` block into `Sources/AnglesiteCore/HTTPCloudflareClient+RegistrarWriting.swift`, same import header. Move `CFRegistrarRegisterRequest` and `CFRegistrarRegistrationState` (used only by `registerDomain`/`decodeState`/`pollRegistrationStatus`) into this file.

- [ ] **Step 5: Move the `AgentReadinessScanning` conformance**

Cut the `// MARK: - AgentReadinessScanning conformance` block into `Sources/AnglesiteCore/HTTPCloudflareClient+AgentReadiness.swift`, same import header. Move `CFURLScanSubmission`, `CFAgentReadinessCheck`, `CFAgentReadinessChecks`, `CFAgentReadinessNextLevel`, `CFAgentReadiness`, `CFScanResult` (used only here) into this file. This extension calls `core.resolveAccountID(apiToken:)` and `core.fetchRaw(...)` — both already `internal` on `CloudflareHTTPCore` from Task 1, no further visibility change needed.

- [ ] **Step 6: Move the `AISearchProvisioning` conformance**

Cut the `// MARK: - AISearchProvisioning conformance` block into `Sources/AnglesiteCore/HTTPCloudflareClient+AISearch.swift`, same import header. Move `CFAISearchInstance` (used only here) into this file.

- [ ] **Step 7: Verify what remains in the base file**

After Steps 2-6, `Sources/AnglesiteCore/HTTPCloudflareClient.swift` should contain, in order: the import block; `CFZone`, `CFDNSSEC`, `CFStringSetting`, `CFSecurityHeader`, `CFDNSRecord`, `CFFullDNSRecord`, `CFBotManagement`, `CFRuleset`/`CFRulesetRule`, `CFPageShield`/`CFPageShieldScript`, `CFWorkerScript`, `CFWorkerDomain` (used by `CloudflareWriting`'s `attachWorkersCustomDomain` — leave it here since `CloudflareReading` doesn't reference it, but it's fine either way since both are same-module; leaving it in the base file alongside the other `CFWorker*` type keeps related types together); the `public struct HTTPCloudflareClient: CloudflareReading { ... }` declaration itself with its `core` property, `init`, `defaultTransport`, and every method that was in the base struct body before Task 2's primitive deletions (`allDNSRecords`, `resolveZoneID`, `zoneState`, `fetchWAFCustomRules`, `settingIsOn`, `zstdEnabled`, `pageShieldState`, `listDNSRecords`, `workerScriptNames`). No `// MARK: - Write helpers` comment remains (that section was entirely the ten primitives Task 2 deleted).

- [ ] **Step 8: Build and run the baseline suite**

Run: `scripts/swift-test.sh --filter "CloudflareClientTests|CloudflareWritingTests|HTTPCloudflareClientAISearchTests|HTTPCloudflareClientRegistrarTests"`
Expected: PASS, identical to Task 2's Step 3 count. A compile error here almost always means a wire type was left `private` in a file other than the one now using it, or wasn't moved to the file that needs it — check the specific "cannot find type in scope" error against the moves in Steps 2-6.

- [ ] **Step 9: Full Core suite sanity check**

Run: `scripts/swift-test.sh --filter AnglesiteCoreTests`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add Sources/AnglesiteCore/HTTPCloudflareClient.swift Sources/AnglesiteCore/HTTPCloudflareClient+Writing.swift Sources/AnglesiteCore/HTTPCloudflareClient+RegistrarReading.swift Sources/AnglesiteCore/HTTPCloudflareClient+RegistrarWriting.swift Sources/AnglesiteCore/HTTPCloudflareClient+AgentReadiness.swift Sources/AnglesiteCore/HTTPCloudflareClient+AISearch.swift
git commit -m "refactor(#1818): split HTTPCloudflareClient into one file per conformance"
```

---

### Task 4: Migrate `CloudflareRUMAnalyticsClient` from `URLSession` to `CloudflareTransport` injection

**Files:**
- Modify: `Sources/AnglesiteCore/CloudflareRUMAnalyticsClient.swift`
- Modify: `Tests/AnglesiteCoreTests/CloudflareRUMAnalyticsClientTests.swift`

**Interfaces:**
- Produces: `CloudflareRUMAnalyticsClient.init(baseURL: URL = ..., transport: @escaping CloudflareTransport = CloudflareRUMAnalyticsClient.defaultTransport)` — replaces the current `init(baseURL:urlSession:)`. Error type (`CloudflareWebAnalyticsError`) and every public method signature are unchanged.
- Consumes: `CloudflareTransport` (`CloudflareReading.swift:83`).

`Sources/AnglesiteApp/PlistEditorModel.swift:281` constructs `CloudflareRUMAnalyticsClient()` with no arguments (all defaults) — no call-site change needed there.

- [ ] **Step 1: Write the new transport-injected tests, replacing the `URLProtocol` stub**

Rewrite `Tests/AnglesiteCoreTests/CloudflareRUMAnalyticsClientTests.swift`'s eight `@Test`s (`summary...` cases) to build `CloudflareRUMAnalyticsClient(baseURL: baseURL, transport: { request in ... })` instead of `CloudflareRUMAnalyticsClient(baseURL: baseURL, urlSession: RUMAnalyticsStubURLProtocol.makeSession())`, and delete the `RUMAnalyticsStubURLProtocol` class entirely (no longer needed). Each closure inspects `request` (method/path/body, matching what `RUMAnalyticsStubURLProtocol` previously matched on) and returns `(Data, HTTPURLResponse)` built the same way `CloudflareHTTPCoreTests`' fakes do:

```swift
private static func response(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/client/v4/graphql")!,
                     statusCode: status, httpVersion: nil, headerFields: nil)!
}
```

Read the existing test bodies first (each currently registers canned responses on `RUMAnalyticsStubURLProtocol` keyed by request path — `accounts` vs `graphql`) and translate each one to a closure that inspects `request.url!.path` the same way. Preserve every existing assertion (`totalPageviews`, `totalVisits`, `dailyPageviews`, the two date-format cases, the `.noAccount`/`.api`/`.invalidResponse` error cases, the "real data but unparseable dates" case) — this task must not reduce coverage.

- [ ] **Step 2: Run the rewritten tests to verify they fail (production code not yet changed)**

Run: `scripts/swift-test.sh --filter CloudflareRUMAnalyticsClientTests`
Expected: build failure — `init(baseURL:transport:)` doesn't exist yet.

- [ ] **Step 3: Update `CloudflareRUMAnalyticsClient`**

In `Sources/AnglesiteCore/CloudflareRUMAnalyticsClient.swift`:
```swift
public struct CloudflareRUMAnalyticsClient: CloudflareRUMAnalyticsProviding {
    private let baseURL: URL
    private let transport: CloudflareTransport

    /// Both parameters exist for tests — inject a fake `transport` to exercise the real
    /// request/decode path without network. Production callers take the defaults.
    public init(baseURL: URL = URL(string: "https://api.cloudflare.com/client/v4")!,
                transport: @escaping CloudflareTransport = CloudflareRUMAnalyticsClient.defaultTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public static let defaultTransport: CloudflareTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudflareWebAnalyticsError.invalidResponse }
        return (data, http)
    }
```
Replace the three private helpers' bodies:
```swift
    private func get<T: Decodable>(_ path: String, apiToken: String) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    private func post<T: Decodable>(path: String, apiToken: String, jsonBody: [String: Any]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await transport(request)
        if !(200..<300).contains(response.statusCode) {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data).errors.first?.message)
                ?? "Cloudflare API request failed with HTTP \(response.statusCode)."
            throw CloudflareWebAnalyticsError.api(message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CloudflareWebAnalyticsError.invalidResponse
        }
    }
```
(Only the parameter/receiver changed — `urlSession.data(for:)` returning `(Data, URLResponse)` with a separate `as? HTTPURLResponse` cast becomes `transport(request)` returning `(Data, HTTPURLResponse)` directly, so `send`'s signature drops the optional cast and uses `response.statusCode` directly.) Every other method (`summary`, `parseDate`, the private structs `Envelope`/`ErrorEnvelope`/`APIError`/`Account`/`GraphQLResponse`, the `query` constant) is unchanged.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/swift-test.sh --filter CloudflareRUMAnalyticsClientTests`
Expected: PASS, same test count as before this task.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/CloudflareRUMAnalyticsClient.swift Tests/AnglesiteCoreTests/CloudflareRUMAnalyticsClientTests.swift
git commit -m "refactor(#1818): inject CloudflareTransport into CloudflareRUMAnalyticsClient"
```

---

### Task 5: Migrate `CloudflareWebAnalyticsClient` to `CloudflareTransport` and add missing `siteTag` coverage

**Files:**
- Modify: `Sources/AnglesiteCore/CloudflareWebAnalyticsClient.swift`
- Modify: `Tests/AnglesiteCoreTests/CloudflareWebAnalyticsClientTests.swift`

**Interfaces:**
- Produces: `CloudflareWebAnalyticsClient.init(baseURL: URL = ..., transport: @escaping CloudflareTransport = CloudflareWebAnalyticsClient.defaultTransport)`, replacing `init(baseURL:urlSession:)`. `siteTag(for:apiToken:)` and `matchingSite(for:in:)` signatures unchanged.
- Consumes: `CloudflareTransport`.

`Sources/AnglesiteApp/PlistEditorModel.swift:280` constructs `CloudflareWebAnalyticsClient()` with all defaults — no call-site change needed. Per the survey, today's test file (17 lines) covers only the pure `matchingSite` function — `siteTag(for:apiToken:)`'s HTTP path (the `get`/`accounts`/`webAnalyticsSites` chain, and its `.noAccount`/`.noMatchingSite`/`.api`/`.invalidResponse` error mapping) has **no test at all**. This task adds that missing coverage as part of making the client transport-injectable (the whole point of the injection is to make this path testable).

- [ ] **Step 1: Write the new/expanded tests**

Add to `Tests/AnglesiteCoreTests/CloudflareWebAnalyticsClientTests.swift` (keep the existing `matchingSiteNormalizesHostURLs` test as-is; add these new ones in the same `@Suite`):

```swift
    private static func response(_ status: Int, path: String = "accounts") -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/client/v4/\(path)")!,
                         statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test("siteTag resolves the token's site by normalized host")
    func siteTagResolvesMatchingHost() async throws {
        let client = CloudflareWebAnalyticsClient(transport: { request in
            if request.url!.path.hasSuffix("/accounts") {
                return (Data(#"{"result": [{"id": "acct-1"}]}"#.utf8), Self.response(200))
            }
            return (Data(#"{"result": [{"host": "example.com", "site_tag": "tag-1"}]}"#.utf8), Self.response(200))
        })
        let tag = try await client.siteTag(for: "https://Example.com/", apiToken: "tok")
        #expect(tag == "tag-1")
    }

    @Test("siteTag throws .noAccount when the token has no visible account")
    func siteTagThrowsNoAccount() async throws {
        let client = CloudflareWebAnalyticsClient(transport: { _ in
            (Data(#"{"result": []}"#.utf8), Self.response(200))
        })
        await #expect(throws: CloudflareWebAnalyticsError.noAccount) {
            _ = try await client.siteTag(for: "example.com", apiToken: "tok")
        }
    }

    @Test("siteTag throws .noMatchingSite when no registration matches the host")
    func siteTagThrowsNoMatchingSite() async throws {
        let client = CloudflareWebAnalyticsClient(transport: { request in
            if request.url!.path.hasSuffix("/accounts") {
                return (Data(#"{"result": [{"id": "acct-1"}]}"#.utf8), Self.response(200))
            }
            return (Data(#"{"result": []}"#.utf8), Self.response(200))
        })
        await #expect(throws: CloudflareWebAnalyticsError.noMatchingSite("example.com")) {
            _ = try await client.siteTag(for: "example.com", apiToken: "tok")
        }
    }

    @Test("siteTag surfaces a non-2xx response as .api with Cloudflare's message")
    func siteTagThrowsAPIErrorOnNon2xx() async throws {
        let client = CloudflareWebAnalyticsClient(transport: { _ in
            (Data(#"{"errors": [{"message": "bad token"}]}"#.utf8), Self.response(403))
        })
        await #expect(throws: CloudflareWebAnalyticsError.api("bad token")) {
            _ = try await client.siteTag(for: "example.com", apiToken: "tok")
        }
    }

    @Test("siteTag surfaces an undecodable body as .invalidResponse")
    func siteTagThrowsInvalidResponseOnMalformedBody() async throws {
        let client = CloudflareWebAnalyticsClient(transport: { _ in
            (Data("not json".utf8), Self.response(200))
        })
        await #expect(throws: CloudflareWebAnalyticsError.invalidResponse) {
            _ = try await client.siteTag(for: "example.com", apiToken: "tok")
        }
    }
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `scripts/swift-test.sh --filter CloudflareWebAnalyticsClientTests`
Expected: build failure — `init(transport:)` doesn't exist yet.

- [ ] **Step 3: Update `CloudflareWebAnalyticsClient`**

In `Sources/AnglesiteCore/CloudflareWebAnalyticsClient.swift`, same transformation shape as Task 4 Step 3:
```swift
public struct CloudflareWebAnalyticsClient: CloudflareWebAnalyticsProviding {
    private let baseURL: URL
    private let transport: CloudflareTransport

    /// Both parameters exist for tests — inject a fake `transport` to exercise the real
    /// request/decode path without network. Production callers take the defaults.
    public init(baseURL: URL = URL(string: "https://api.cloudflare.com/client/v4")!,
                transport: @escaping CloudflareTransport = CloudflareWebAnalyticsClient.defaultTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public static let defaultTransport: CloudflareTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudflareWebAnalyticsError.invalidResponse }
        return (data, http)
    }
```
Replace `get`:
```swift
    private func get<T: Decodable>(_ path: String, apiToken: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await transport(request)
        if !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data).errors.first?.message)
                ?? "Cloudflare API request failed with HTTP \(http.statusCode)."
            throw CloudflareWebAnalyticsError.api(message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CloudflareWebAnalyticsError.invalidResponse
        }
    }
```
`siteTag(for:apiToken:)`, `matchingSite(for:in:)`, `accounts(apiToken:)`, `webAnalyticsSites(accountID:apiToken:)`, `normalizeHost`, and every private struct are unchanged.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/swift-test.sh --filter CloudflareWebAnalyticsClientTests`
Expected: PASS, 6 tests (1 existing + 5 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/CloudflareWebAnalyticsClient.swift Tests/AnglesiteCoreTests/CloudflareWebAnalyticsClientTests.swift
git commit -m "refactor(#1818): inject CloudflareTransport into CloudflareWebAnalyticsClient, cover siteTag"
```

---

### Task 6: Dedupe `CloudflareAPITokenVerifier.Transport` and `CloudflareOAuthClient.Transport` onto `CloudflareTransport`

**Files:**
- Modify: `Sources/AnglesiteCore/CloudflareAPITokenVerifier.swift`
- Modify: `Sources/AnglesiteCore/CloudflareOAuthClient.swift`
- Modify: `Tests/AnglesiteCoreTests/CloudflareAPITokenVerifierTests.swift`

**Interfaces:**
- Produces: neither type declares its own `Transport` typealias anymore; both use the shared public `CloudflareTransport` (`CloudflareReading.swift:83`) directly for their `transport` property, `init` parameter, and `defaultTransport` static.
- Consumes: `CloudflareTransport`.

This is a pure rename with no behavior change — a passing build is the correctness signal, on top of the existing test suites for both types.

- [ ] **Step 1: Update `CloudflareAPITokenVerifier`**

In `Sources/AnglesiteCore/CloudflareAPITokenVerifier.swift`:
- Delete line 15: `public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)`.
- Line 18: `private let transport: Transport` → `private let transport: CloudflareTransport`.
- Line 24: `transport: @escaping Transport = CloudflareAPITokenVerifier.defaultTransport` → `transport: @escaping CloudflareTransport = CloudflareAPITokenVerifier.defaultTransport`.
- Line 81: `public static let defaultTransport: Transport = { request in` → `public static let defaultTransport: CloudflareTransport = { request in`.
- Line 10's doc comment ("The HTTP step is injected (`Transport`)...") → "The HTTP step is injected (`CloudflareTransport`)...".

- [ ] **Step 2: Update `CloudflareOAuthClient`**

In `Sources/AnglesiteCore/CloudflareOAuthClient.swift`:
- Delete line 110: `public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)`.
- Line 116: `private let transport: Transport` → `private let transport: CloudflareTransport`.
- Line 129: `transport: @escaping Transport = CloudflareOAuthClient.defaultTransport` → `transport: @escaping CloudflareTransport = CloudflareOAuthClient.defaultTransport`.
- Line 280: `public static let defaultTransport: Transport = { request in` → `public static let defaultTransport: CloudflareTransport = { request in`.
- Lines 105/108 doc comments referencing `` ``CloudflareAPITokenVerifier/Transport`` `` → reference the shared `` ``CloudflareTransport`` `` typealias instead.

- [ ] **Step 3: Update `CloudflareReading.swift`'s doc comment**

Line 82's comment "Injectable HTTP boundary — identical shape to `CloudflareAPITokenVerifier.Transport`." is now stale (that type no longer has its own `Transport`) — change it to: "Injectable HTTP boundary shared by every Cloudflare v4 REST client in this module."

- [ ] **Step 4: Fix the one test-file reference**

In `Tests/AnglesiteCoreTests/CloudflareAPITokenVerifierTests.swift:15`, change the helper's return type from `CloudflareAPITokenVerifier.Transport` to `CloudflareTransport`.

- [ ] **Step 5: Build and run both suites**

Run: `scripts/swift-test.sh --filter "CloudflareAPITokenVerifierTests|CloudflareOAuthClientTests"`
Expected: PASS, same counts as before this task.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/CloudflareAPITokenVerifier.swift Sources/AnglesiteCore/CloudflareOAuthClient.swift Sources/AnglesiteCore/CloudflareReading.swift Tests/AnglesiteCoreTests/CloudflareAPITokenVerifierTests.swift
git commit -m "refactor(#1818): dedupe Transport typealiases onto CloudflareTransport"
```

---

### Task 7: Full verification and PR

**Files:** none (verification only)

- [ ] **Step 1: Run the full local suite**

Run: `scripts/swift-test.sh`
Expected: PASS, no regressions anywhere (App-target tests included, since `PlistEditorModel.swift`'s default-arg call sites into the two migrated clients are exercised transitively by whatever covers `PlistEditorModel`).

- [ ] **Step 2: Build the app target**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Regenerate the docs index if any spec/plan file changed status**

This plan is new under `docs/superpowers/plans/` (plans aren't indexed like `docs/specs/`/`docs/superpowers/specs/` — no action needed here; skip unless a design doc's `Status:` also changed).

- [ ] **Step 4: Open the PR**

Use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan). Body notes this is Phase 1 of 3 from #1818's owner-approved sequencing — **do not close #1818** (Phases 2-3 remain); reference it as `Part of #1818` (not `Closes #1818`), per `CONTRIBUTING.md`'s multi-PR tracking-issue guidance. Mention the two scope corrections from this plan's Global Constraints (RUM/WebAnalytics keep their own envelope+error type; `CloudflareAccountLookup` needed no change) in a Design notes section so the follow-up Phase-2 plan author has the accurate picture instead of the original issue text.


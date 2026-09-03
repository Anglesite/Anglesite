# Worker Catalog Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the app a typed, testable model for the `@dwk/workers` catalog (worker id, name,
description, group, binding rule, resource requirements) plus a resilient fetch-and-cache layer,
so later work (deploy composition, the Workers Settings tab) has a single source of truth for
"what workers exist" that never blocks or crashes on a network failure.

**Architecture:** Two new files in `AnglesiteCore`. `WorkerCatalog.swift` defines the pure data
model (`WorkerDescriptor`) and a stateless JSON parser (`WorkerCatalogReader`), mirroring the
existing `WorkersConformanceReader` shape. `WorkerCatalogFetcher.swift` is a small actor that
fetches the manifest over HTTP, disk-caches the raw bytes on success, and falls back to the last
cached copy (then to an empty catalog) on any failure — modeled on `SiteStore`'s
`applicationSupportDirectory`/atomic-write cache convention and `FreedesignmdCatalog`'s
stub-`URLProtocol` test pattern.

**Tech Stack:** Swift 6.4, Swift Testing (`Testing` module, `@Suite`/`@Test`/`#expect`), Foundation
(`URLSession`, `JSONDecoder`, `PropertyListEncoder`-adjacent atomic file writes).

## Global Constraints

- Every new public type lives in `Sources/AnglesiteCore/` (this is core model/business logic, not
  a view) per this repo's module layout (CLAUDE.md).
- `WorkerCatalogReader.parse` must throw on malformed input (matches `WorkersConformanceReader`'s
  contract) — resilience (never-throw, degrade-to-cache-or-empty) lives one layer up, in
  `WorkerCatalogFetcher.catalog()`, not in the parser.
- `WorkerCatalogFetcher` takes `catalogURL` as a required constructor parameter with **no
  in-app default** — `@dwk/workers` has not published `catalog.json` yet (design doc §10), so
  there is no real URL to hardcode. Wiring a concrete production URL is out of scope for this
  plan; it happens once the monorepo publishes the manifest.
- Tests use Swift Testing (`import Testing`), not XCTest — this matches `WorkersConformanceTests`/
  `FreedesignmdCatalogTests`, the two existing files this plan's tests sit alongside.
- Run `swift build --package-path .` after each task to catch compile errors before running tests.

---

### Task 1: `WorkerDescriptor` data model

**Files:**
- Create: `Sources/AnglesiteCore/WorkerCatalog.swift`
- Test: `Tests/AnglesiteCoreTests/WorkerCatalogTests.swift`

**Interfaces:**
- Produces: `WorkerDescriptor` (`Sendable, Equatable, Codable, Identifiable`) with fields `id: String`,
  `displayName: String`, `description: String`, `group: String`, `binding: WorkerDescriptor.Binding`,
  `resources: WorkerDescriptor.Resources`. Nested `Binding` enum: `.componentTied(componentIDs: [String])`
  or `.settingsActivated`, `Codable` via an explicit `"kind"` discriminator (`"componentTied"` /
  `"settingsActivated"`). Nested `Resources` struct: `needsD1: Bool`, `needsKV: Bool`, `needsR2: Bool`,
  all with a memberwise `public init`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/WorkerCatalogTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WorkerDescriptor")
struct WorkerDescriptorTests {
    @Test("round-trips a componentTied worker through JSONEncoder/JSONDecoder")
    func roundTripsComponentTied() throws {
        let worker = WorkerDescriptor(
            id: "webmention",
            displayName: "Webmentions",
            description: "Receive and verify webmentions for posts",
            group: "social",
            binding: .componentTied(componentIDs: ["webmention-form"]),
            resources: WorkerDescriptor.Resources(needsD1: true, needsKV: true, needsR2: false)
        )

        let data = try JSONEncoder().encode(worker)
        let decoded = try JSONDecoder().decode(WorkerDescriptor.self, from: data)

        #expect(decoded == worker)
        #expect(decoded.binding == .componentTied(componentIDs: ["webmention-form"]))
    }

    @Test("round-trips a settingsActivated worker with no componentIDs")
    func roundTripsSettingsActivated() throws {
        let worker = WorkerDescriptor(
            id: "solid-pod",
            displayName: "Solid Pod",
            description: "Expose a Solid-compatible personal data store for this site",
            group: "storage",
            binding: .settingsActivated,
            resources: WorkerDescriptor.Resources(needsD1: false, needsKV: true, needsR2: true)
        )

        let data = try JSONEncoder().encode(worker)
        let decoded = try JSONDecoder().decode(WorkerDescriptor.self, from: data)

        #expect(decoded == worker)
        #expect(decoded.binding == .settingsActivated)
    }

    @Test("decoding an unknown binding kind throws")
    func unknownBindingKindThrows() {
        let json = """
        { "kind": "somethingElse" }
        """.data(using: .utf8)!

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(WorkerDescriptor.Binding.self, from: json)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter WorkerDescriptorTests`
Expected: FAIL — `WorkerDescriptor` (and `WorkerDescriptor.Binding`/`WorkerDescriptor.Resources`)
do not exist yet, so this fails to compile.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/AnglesiteCore/WorkerCatalog.swift`:

```swift
import Foundation

/// One `@dwk/workers` package as described by the monorepo's published catalog manifest
/// (`catalog.json`). Intentionally generic — this app never hardcodes specific worker names
/// (design doc §3): whatever the manifest lists is what the Workers tab shows and what deploy
/// composition can activate.
public struct WorkerDescriptor: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let displayName: String
    public let description: String
    /// Free-text grouping key the Workers tab sections by (e.g. `"social"`, `"storage"`) — never
    /// enumerated in Swift, since the manifest owns the set of groups.
    public let group: String
    public let binding: Binding
    public let resources: Resources

    public init(
        id: String,
        displayName: String,
        description: String,
        group: String,
        binding: Binding,
        resources: Resources
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.group = group
        self.binding = binding
        self.resources = resources
    }

    /// How a worker becomes active. `componentTied` workers are never manually toggled — their
    /// active state is always recomputed from Site Graph Explorer's `ImpactAnalysis` against
    /// `componentIDs` (design doc §4). `settingsActivated` workers are toggled in the Workers tab.
    public enum Binding: Sendable, Equatable, Codable {
        case componentTied(componentIDs: [String])
        case settingsActivated

        private enum CodingKeys: String, CodingKey {
            case kind
            case componentIDs
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "componentTied":
                let componentIDs = try container.decode([String].self, forKey: .componentIDs)
                self = .componentTied(componentIDs: componentIDs)
            case "settingsActivated":
                self = .settingsActivated
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: container, debugDescription: "unknown binding kind \"\(kind)\"")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .componentTied(let componentIDs):
                try container.encode("componentTied", forKey: .kind)
                try container.encode(componentIDs, forKey: .componentIDs)
            case .settingsActivated:
                try container.encode("settingsActivated", forKey: .kind)
            }
        }
    }

    /// Generalizes `WorkerComposition.Feature`'s hand-maintained `needsD1`/`needsKV`/`needsR2`
    /// switch statements (`WorkerComposition.swift:28-53`) into manifest-driven data.
    public struct Resources: Sendable, Equatable, Codable {
        public let needsD1: Bool
        public let needsKV: Bool
        public let needsR2: Bool

        public init(needsD1: Bool, needsKV: Bool, needsR2: Bool) {
            self.needsD1 = needsD1
            self.needsKV = needsKV
            self.needsR2 = needsR2
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter WorkerDescriptorTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WorkerCatalog.swift Tests/AnglesiteCoreTests/WorkerCatalogTests.swift
git commit -m "feat(workers): add WorkerDescriptor catalog model"
```

---

### Task 2: `WorkerCatalogReader.parse`

**Files:**
- Modify: `Sources/AnglesiteCore/WorkerCatalog.swift`
- Modify: `Tests/AnglesiteCoreTests/WorkerCatalogTests.swift`

**Interfaces:**
- Consumes: `WorkerDescriptor` from Task 1.
- Produces: `WorkerCatalogReader.parse(_ data: Data) throws -> [WorkerDescriptor]` — decodes a
  `{ "workers": [...] }` root object. Throws `DecodingError` on malformed JSON (mirrors
  `WorkersConformanceReader.parse`'s contract — this function does not degrade gracefully; that's
  `WorkerCatalogFetcher`'s job in Task 3).

- [ ] **Step 1: Write the failing test**

Append to `Tests/AnglesiteCoreTests/WorkerCatalogTests.swift`:

```swift
@Suite("WorkerCatalogReader")
struct WorkerCatalogReaderTests {
    private let sampleJSON = """
    {
      "workers": [
        {
          "id": "webmention",
          "displayName": "Webmentions",
          "description": "Receive and verify webmentions for posts",
          "group": "social",
          "binding": { "kind": "componentTied", "componentIDs": ["webmention-form"] },
          "resources": { "needsD1": true, "needsKV": true, "needsR2": false }
        },
        {
          "id": "solid-pod",
          "displayName": "Solid Pod",
          "description": "Expose a Solid-compatible personal data store for this site",
          "group": "storage",
          "binding": { "kind": "settingsActivated" },
          "resources": { "needsD1": false, "needsKV": true, "needsR2": true }
        }
      ]
    }
    """.data(using: .utf8)!

    @Test("parses a two-worker manifest with both binding kinds")
    func parsesTwoWorkers() throws {
        let workers = try WorkerCatalogReader.parse(sampleJSON)
        #expect(workers.count == 2)

        let webmention = try #require(workers.first { $0.id == "webmention" })
        #expect(webmention.group == "social")
        #expect(webmention.binding == .componentTied(componentIDs: ["webmention-form"]))
        #expect(webmention.resources.needsD1)
        #expect(!webmention.resources.needsR2)

        let solidPod = try #require(workers.first { $0.id == "solid-pod" })
        #expect(solidPod.binding == .settingsActivated)
    }

    @Test("throws on malformed JSON")
    func throwsOnMalformedJSON() {
        let json = "{ \"not-workers\": [] }".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try WorkerCatalogReader.parse(json)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter WorkerCatalogReaderTests`
Expected: FAIL — `WorkerCatalogReader` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/AnglesiteCore/WorkerCatalog.swift`:

```swift
/// Parses `catalog.json` (the `@dwk/workers` monorepo's published worker manifest) into
/// `WorkerDescriptor`s. Stateless — call `parse(_:)` directly, mirroring
/// `WorkersConformanceReader`'s shape.
public enum WorkerCatalogReader {
    private struct Root: Decodable {
        let workers: [WorkerDescriptor]
    }

    /// Decodes `data` (UTF-8 JSON matching the `catalog.json` schema) and returns its
    /// `WorkerDescriptor`s. Throws a `DecodingError` if the JSON is malformed.
    public static func parse(_ data: Data) throws -> [WorkerDescriptor] {
        try JSONDecoder().decode(Root.self, from: data).workers
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter WorkerCatalogReaderTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WorkerCatalog.swift Tests/AnglesiteCoreTests/WorkerCatalogTests.swift
git commit -m "feat(workers): add WorkerCatalogReader.parse"
```

---

### Task 3: `WorkerCatalogFetcher` — fetch, cache, degrade

**Files:**
- Create: `Sources/AnglesiteCore/WorkerCatalogFetcher.swift`
- Create: `Tests/AnglesiteCoreTests/WorkerCatalogFetcherTests.swift`

**Interfaces:**
- Consumes: `WorkerDescriptor`, `WorkerCatalogReader.parse(_:)` from Tasks 1–2.
- Produces: `WorkerCatalogFetchError.fetchFailed(String)` (`Error, Sendable, Equatable`);
  `WorkerCatalogFetcher` (`actor`) with
  `init(catalogURL: URL, cacheURL: URL = WorkerCatalogFetcher.defaultCacheURL(), session: URLSession = .shared, fileManager: FileManager = .default)`
  and `func catalog() async -> [WorkerDescriptor]` (never throws — degrades to cache, then to `[]`).
  Also `static func defaultCacheURL(fileManager: FileManager = .default) -> URL`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteCoreTests/WorkerCatalogFetcherTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

/// Stub `URLProtocol` returning a canned status/body for every request, so
/// `WorkerCatalogFetcher` can be exercised without a real network call — mirrors
/// `FreedesignmdCatalogTests`' `FreedesignmdStubURLProtocol`.
private final class WorkerCatalogStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var shouldFailToLoad = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.shouldFailToLoad {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkerCatalogStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// .serialized: tests share WorkerCatalogStubURLProtocol's mutable static status/body/failure
// flag, which would race under Swift Testing's default parallel execution.
@Suite(.serialized) struct WorkerCatalogFetcherTests {
    private let sampleJSON = """
    {
      "workers": [
        {
          "id": "webmention",
          "displayName": "Webmentions",
          "description": "Receive and verify webmentions for posts",
          "group": "social",
          "binding": { "kind": "componentTied", "componentIDs": ["webmention-form"] },
          "resources": { "needsD1": true, "needsKV": true, "needsR2": false }
        }
      ]
    }
    """

    private func tempCacheURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("worker-catalog-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("worker-catalog-cache.json")
    }

    @Test("fetches, parses, and writes the cache file on success")
    func fetchesAndCachesOnSuccess() async throws {
        WorkerCatalogStubURLProtocol.shouldFailToLoad = false
        WorkerCatalogStubURLProtocol.statusCode = 200
        WorkerCatalogStubURLProtocol.body = sampleJSON
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession()
        )

        let workers = await fetcher.catalog()
        #expect(workers.map(\.id) == ["webmention"])
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("falls back to the cached catalog when the fetch fails")
    func fallsBackToCacheOnFetchFailure() async throws {
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(sampleJSON.utf8).write(to: cacheURL)

        WorkerCatalogStubURLProtocol.shouldFailToLoad = true
        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession()
        )

        let workers = await fetcher.catalog()
        #expect(workers.map(\.id) == ["webmention"])
    }

    @Test("returns an empty catalog when the fetch fails and there is no cache")
    func returnsEmptyWhenNoCacheAndFetchFails() async {
        WorkerCatalogStubURLProtocol.shouldFailToLoad = true
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession()
        )

        let workers = await fetcher.catalog()
        #expect(workers.isEmpty)
    }

    @Test("returns an empty catalog on a non-2xx response with no cache")
    func returnsEmptyOnBadStatusWithNoCache() async {
        WorkerCatalogStubURLProtocol.shouldFailToLoad = false
        WorkerCatalogStubURLProtocol.statusCode = 404
        WorkerCatalogStubURLProtocol.body = "not found"
        let cacheURL = tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let fetcher = WorkerCatalogFetcher(
            catalogURL: URL(string: "https://example.invalid/catalog.json")!,
            cacheURL: cacheURL,
            session: WorkerCatalogStubURLProtocol.makeSession()
        )

        let workers = await fetcher.catalog()
        #expect(workers.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter WorkerCatalogFetcherTests`
Expected: FAIL — `WorkerCatalogFetcher`/`WorkerCatalogFetchError` do not exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/AnglesiteCore/WorkerCatalogFetcher.swift`:

```swift
import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum WorkerCatalogFetchError: Error, Sendable, Equatable {
    case fetchFailed(String)
}

/// Fetches, parses, and disk-caches the `@dwk/workers` catalog manifest (`catalog.json`).
/// Network or parse failures degrade to the last successfully cached copy, then to an empty
/// catalog — the Workers Settings tab and deploy composition must never block or crash on a
/// catalog fetch failure (design doc §3).
///
/// - Important: `catalogURL` has no in-app default. As of this writing `@dwk/workers` has not
///   yet published `catalog.json` — callers must supply the real manifest URL once the monorepo
///   publishes one.
public actor WorkerCatalogFetcher {
    private let catalogURL: URL
    private let cacheURL: URL
    private let session: URLSession
    private let fileManager: FileManager

    public init(
        catalogURL: URL,
        cacheURL: URL = WorkerCatalogFetcher.defaultCacheURL(),
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.catalogURL = catalogURL
        self.cacheURL = cacheURL
        self.session = session
        self.fileManager = fileManager
    }

    /// Fetches the latest catalog and caches the raw manifest bytes to disk on success. On any
    /// failure (network error, non-2xx response, malformed JSON), falls back to the last cached
    /// catalog; if there is no cache either, returns an empty catalog. Never throws.
    public func catalog() async -> [WorkerDescriptor] {
        if let fresh = try? await fetchAndCache() {
            return fresh
        }
        return (try? Self.readCache(cacheURL)) ?? []
    }

    private func fetchAndCache() async throws -> [WorkerDescriptor] {
        let (data, response) = try await session.data(from: catalogURL)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw WorkerCatalogFetchError.fetchFailed("bad response from \(catalogURL)")
        }
        let descriptors = try WorkerCatalogReader.parse(data)
        try Self.writeCache(data, to: cacheURL, fileManager: fileManager)
        return descriptors
    }

    private static func readCache(_ url: URL) throws -> [WorkerDescriptor] {
        let data = try Data(contentsOf: url)
        return try WorkerCatalogReader.parse(data)
    }

    private static func writeCache(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    /// `~/Library/Application Support/Anglesite/worker-catalog-cache.json` — mirrors
    /// `SiteStore`'s `defaultPersistenceURL` convention (`SiteStore.swift:323-333`).
    public static func defaultCacheURL(fileManager: FileManager = .default) -> URL {
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Anglesite", isDirectory: true)
            .appendingPathComponent("worker-catalog-cache.json")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter WorkerCatalogFetcherTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Run the full AnglesiteCoreTests suite to confirm no regressions**

Run: `swift test --package-path . --filter AnglesiteCoreTests`
Expected: PASS (all existing tests plus the 9 new ones from this plan)

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/WorkerCatalogFetcher.swift Tests/AnglesiteCoreTests/WorkerCatalogFetcherTests.swift
git commit -m "feat(workers): add WorkerCatalogFetcher with disk-cache fallback"
```

---

## What this plan does not cover

This plan is the first of two implementation plans under sub-issue
[#708](https://github.com/Anglesite/Anglesite-app/issues/708) ("Worker catalog + local
wrangler-dev runtime"). It covers only the catalog data model and fetch/cache layer (design doc
§3). It deliberately does **not** cover:

- Wiring a real production `catalogURL` anywhere in the app (blocked on `@dwk/workers` publishing
  `catalog.json` — design doc §10).
- Migrating `WorkerComposition.Feature` from its closed enum to `[WorkerDescriptor]` (design doc
  §3's "existing code that changes shape" note) — that lands with sub-issue #709's deploy
  integration work, since it's deploy-composition logic, not catalog logic.
- The local `wrangler dev` container runtime (design doc §7) — extending `LocalContainerControl`,
  `LocalContainerSiteRuntime`, and the container images (`Containers/anglesite-dev/Dockerfile`,
  `container/Dockerfile`) to run a worker dev server needs its own plan: it touches a carefully
  reentrancy-guarded actor (`LocalContainerSiteRuntime`'s generation-tracking, see its extensive
  comments on superseded-attempt handling) and requires baking `wrangler` into two Dockerfiles that
  currently only bake Node/git/the MCP sidecar — neither of which this plan's file list touches.
  Write that as a follow-up plan once `LocalContainerControl`'s production conformer
  (`ContainerizationControl` in `AnglesiteContainer`) and the vsock port-allocation path have been
  read in full.

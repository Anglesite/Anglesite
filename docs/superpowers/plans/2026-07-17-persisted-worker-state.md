# Persisted Active-Worker State + Deploy Diff/Removal Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compute each site's effective active worker set on every deploy and fold `SocialWorkerProvisionCommand` into the main Deploy button, so activating/deactivating a catalog worker (Site Graph Explorer usage or a future Settings toggle) actually reaches Cloudflare — closing the gap where that command has no live caller today.

**Architecture:** A new pure `WorkerActivation` type computes the effective active worker-id set (component-tied via `ImpactAnalysis` + settings-activated via new `SiteSettings` fields) and diffs it against the last-deployed set. `DeployModel.runDeploy` and `SiteOperations.deploy` both route every deploy through `SocialWorkerProvisionCommand.provision` (which already degrades to a plain static deploy when its feature list is empty) instead of calling `DeployCommand.deploy` directly, using a captured closure so `DeployCommand`'s existing route-coverage scanning, milestones, and worker-name-conflict handling are preserved unchanged. A new `ContainerCommandRunner` (mirroring the existing `ContainerDeployExecutor`) makes `SocialWorkerProvisionCommand`'s wrangler subcommands actually execute inside the container.

**Tech Stack:** Swift 6.4, Swift Testing (`@Test`/`@Suite`/`#expect`), SwiftPM (`AnglesiteCore`, `AnglesiteApp` targets).

## Global Constraints

- Every `SiteSettings` field must stay `Optional` (`SiteConfigStore.swift:7-11`'s forward-compat rule) — a plist written by an older build must still decode.
- Never delete backing Cloudflare D1/KV/R2 resources on worker deactivation — route/binding teardown only (design doc §6).
- `DeployModel.Phase`'s public shape (`.succeeded`/`.blocked`/`.workerNameConflict`/`.failed`) does not change — only what feeds it does.
- No new UI surface ships in this plan (that's #710) — every task is `AnglesiteCore`/`AnglesiteApp`-model-layer only.
- Follow this repo's existing fake/recorder test patterns (actor-backed recorders with closure-injected seams) rather than introducing a mocking library.
- Design reference: `docs/superpowers/specs/2026-07-17-persisted-worker-state-design.md`. Section numbers below (`§N`) refer to it.

---

## File Structure

**Modify:**
- `Sources/AnglesiteCore/SiteConfigStore.swift` — new `SiteSettings` fields (Task 1)
- `Sources/AnglesiteCore/WorkerComposition.swift` — `ProvisionedResources` gains `Codable` (Task 1)
- `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift` — `.workerNameConflict` result case (Task 3), `knownResources` param (Task 4)
- `Sources/AnglesiteCore/SiteOperations.swift` — `dialog(forSocialWorkerProvision:)` gains the new case (Task 3); `deploy(site:)` routes through `provision` (Task 8)
- `Sources/AnglesiteCore/WorkerCatalogFetcher.swift` — production `catalogURL` constant (Task 6)
- `Sources/AnglesiteApp/DeployModel.swift` — effective-set computation + `provision`-based deploy wiring (Task 7)
- `Sources/AnglesiteApp/SiteWindowModel.swift:74` — thread `contentGraph` into `DeployModel` (Task 7)

**Create:**
- `Sources/AnglesiteCore/WorkerActivation.swift` — Task 2
- `Sources/AnglesiteCore/ContainerCommandRunner.swift` — Task 5
- `Tests/AnglesiteCoreTests/WorkerActivationTests.swift` — Task 2
- `Tests/AnglesiteCoreTests/ContainerCommandRunnerTests.swift` — Task 5

**Test-only modify:**
- `Tests/AnglesiteCoreTests/SiteConfigStoreTests.swift` (Task 1)
- `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift` (Task 1)
- `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift` (Tasks 3, 4)
- `Tests/AnglesiteCoreTests/SiteOperationsTests.swift` (Tasks 3, 8)
- `Tests/AnglesiteCoreTests/WorkerCatalogFetcherTests.swift` (Task 6)
- `Tests/AnglesiteAppTests/DeployModelTests.swift` (Task 7)

---

### Task 1: `SiteSettings` persisted worker fields + `ProvisionedResources` Codable

**Files:**
- Modify: `Sources/AnglesiteCore/WorkerComposition.swift:64-74`
- Modify: `Sources/AnglesiteCore/SiteConfigStore.swift:12-50`
- Test: `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift`
- Test: `Tests/AnglesiteCoreTests/SiteConfigStoreTests.swift`

**Interfaces:**
- Produces: `WorkerComposition.ProvisionedResources: Codable` (was `Sendable, Equatable`); `SiteSettings.activeWorkerIDs: [String]?`, `SiteSettings.lastDeployedWorkerIDs: [String]?`, `SiteSettings.provisionedWorkerResources: WorkerComposition.ProvisionedResources?`.

- [ ] **Step 1: Write the failing `ProvisionedResources` Codable test**

Add to `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift` (append to the file):

```swift
@Test("ProvisionedResources round-trips through JSONEncoder/JSONDecoder")
func provisionedResourcesCodable() throws {
    let resources = WorkerComposition.ProvisionedResources(
        d1DatabaseID: "d1-id", kvNamespaceID: "kv-id", r2BucketName: "media-bucket"
    )
    let data = try JSONEncoder().encode(resources)
    let decoded = try JSONDecoder().decode(WorkerComposition.ProvisionedResources.self, from: data)
    #expect(decoded == resources)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: FAIL — `type 'WorkerComposition.ProvisionedResources' does not conform to protocol 'Decodable'`

- [ ] **Step 3: Make `ProvisionedResources` Codable**

In `Sources/AnglesiteCore/WorkerComposition.swift:64`, change:

```swift
    public struct ProvisionedResources: Sendable, Equatable {
```

to:

```swift
    public struct ProvisionedResources: Sendable, Equatable, Codable {
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: PASS

- [ ] **Step 5: Write the failing `SiteSettings` round-trip test**

Add to `Tests/AnglesiteCoreTests/SiteConfigStoreTests.swift` (append inside the `SiteConfigStoreTests` struct, before the closing `}`):

```swift
    @Test("save then load round-trips the persisted worker-state fields")
    func saveLoadRoundTripsWorkerState() async throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = SiteConfigStore(configDirectory: dir)
        let settings = SiteSettings(
            activeWorkerIDs: ["solid-pod", "webdav"],
            lastDeployedWorkerIDs: ["webmention", "indieauth"],
            provisionedWorkerResources: .init(d1DatabaseID: "d1-id", kvNamespaceID: "kv-id", r2BucketName: nil)
        )
        try await store.save(settings)

        let loaded = try await store.load()
        #expect(loaded.activeWorkerIDs == ["solid-pod", "webdav"])
        #expect(loaded.lastDeployedWorkerIDs == ["webmention", "indieauth"])
        #expect(loaded.provisionedWorkerResources == .init(d1DatabaseID: "d1-id", kvNamespaceID: "kv-id", r2BucketName: nil))
    }

    @Test("an old-format settings.plist missing the worker-state keys still decodes")
    func loadOldFormatWithoutWorkerState() async throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        // Simulates a plist written by a build that predates these fields: only `displayName`.
        let oldFormat = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>displayName</key>
            <string>Old Site</string>
        </dict>
        </plist>
        """
        try oldFormat.write(to: dir.appendingPathComponent("settings.plist"), atomically: true, encoding: .utf8)
        let store = SiteConfigStore(configDirectory: dir)

        let loaded = try await store.load()
        #expect(loaded.displayName == "Old Site")
        #expect(loaded.activeWorkerIDs == nil)
        #expect(loaded.lastDeployedWorkerIDs == nil)
        #expect(loaded.provisionedWorkerResources == nil)
    }
```

- [ ] **Step 6: Run it to verify it fails**

Run: `swift test --package-path . --filter SiteConfigStoreTests`
Expected: FAIL — `value of type 'SiteSettings' has no member 'activeWorkerIDs'` (compile error)

- [ ] **Step 7: Add the three fields to `SiteSettings`**

In `Sources/AnglesiteCore/SiteConfigStore.swift`, replace lines 12-50 (the whole `SiteSettings` struct) with:

```swift
public struct SiteSettings: Sendable, Codable, Equatable {
    /// Owner-facing display name override. `nil` falls back to the package marker's displayName.
    public var displayName: String?

    /// Cloudflare account id owning this site's `INBOX_KV` namespace (#587). `nil` until a
    /// provisioning flow sets it — `InboxSubmissionSync` no-ops without both this and
    /// `inboxCaptureKVNamespaceID`.
    public var inboxCaptureAccountID: String?

    /// The provisioned `INBOX_KV` namespace id for this site (#587). See
    /// `inboxCaptureAccountID`.
    public var inboxCaptureKVNamespaceID: String?

    /// Mastodon server origin used for POSSE, for example `https://mastodon.social`.
    /// The access token is stored separately in the platform secret store.
    public var mastodonBaseURL: String?

    /// Bluesky handle or DID used to create a session for POSSE. The app password is secret-store only.
    public var blueskyIdentifier: String?

    /// Bluesky PDS origin. `nil` uses the public `https://bsky.social` service.
    public var blueskyPDSURL: String?

    /// `@dwk/workers` catalog ids the user has manually toggled on. Component-tied workers are
    /// never stored here — their active state is always recomputed live from Site Graph
    /// Explorer / `ImpactAnalysis` (`WorkerActivation`, #709), so it can't drift from site
    /// content.
    public var activeWorkerIDs: [String]?

    /// The full effective active worker-id set (component-tied + settings-activated) as of the
    /// last successful deploy — the diff baseline `WorkerActivation.removedIDs` reports removals
    /// against (#709).
    public var lastDeployedWorkerIDs: [String]?

    /// Already-provisioned Cloudflare D1/KV/R2 resource ids for this site's composed Worker,
    /// durable across a worker being deactivated and later reactivated — deactivating a worker
    /// drops its binding block from `wrangler.toml`, so this is the source of truth instead of
    /// re-scraping the file (#709).
    public var provisionedWorkerResources: WorkerComposition.ProvisionedResources?

    public init(
        displayName: String? = nil,
        inboxCaptureAccountID: String? = nil,
        inboxCaptureKVNamespaceID: String? = nil,
        mastodonBaseURL: String? = nil,
        blueskyIdentifier: String? = nil,
        blueskyPDSURL: String? = nil,
        activeWorkerIDs: [String]? = nil,
        lastDeployedWorkerIDs: [String]? = nil,
        provisionedWorkerResources: WorkerComposition.ProvisionedResources? = nil
    ) {
        self.displayName = displayName
        self.inboxCaptureAccountID = inboxCaptureAccountID
        self.inboxCaptureKVNamespaceID = inboxCaptureKVNamespaceID
        self.mastodonBaseURL = mastodonBaseURL
        self.blueskyIdentifier = blueskyIdentifier
        self.blueskyPDSURL = blueskyPDSURL
        self.activeWorkerIDs = activeWorkerIDs
        self.lastDeployedWorkerIDs = lastDeployedWorkerIDs
        self.provisionedWorkerResources = provisionedWorkerResources
    }
}
```

- [ ] **Step 8: Run it to verify it passes**

Run: `swift test --package-path . --filter SiteConfigStoreTests`
Expected: PASS (all `SiteConfigStoreTests`, including the two new ones)

- [ ] **Step 9: Commit**

```bash
git add Sources/AnglesiteCore/WorkerComposition.swift Sources/AnglesiteCore/SiteConfigStore.swift \
        Tests/AnglesiteCoreTests/WorkerCompositionTests.swift Tests/AnglesiteCoreTests/SiteConfigStoreTests.swift
git commit -m "feat(workers): persist active/last-deployed worker ids and resources (#709)"
```

---

### Task 2: `WorkerActivation` — effective active set + diff + Feature mapping

**Files:**
- Create: `Sources/AnglesiteCore/WorkerActivation.swift`
- Test: `Tests/AnglesiteCoreTests/WorkerActivationTests.swift`

**Interfaces:**
- Consumes: `SiteSettings.activeWorkerIDs` (Task 1); `WorkerDescriptor`/`WorkerDescriptor.Binding` (`WorkerCatalog.swift:7-84`, existing); `SiteGraphExplorerSnapshot`, `ImpactAnalysis.analyze(snapshot:targetID:)` → `ImpactAnalysis.Report.affectedPages` (existing, `ImpactAnalysis.swift:49,24`); `WorkerComposition.Feature` (existing, `WorkerComposition.swift:12-19`).
- Produces: `WorkerActivation.effectiveActiveIDs(settings:catalog:graph:) -> Set<String>`, `WorkerActivation.removedIDs(previous:next:) -> Set<String>`, `WorkerActivation.mapToFeatures(_:) -> [WorkerComposition.Feature]`. Consumed by Task 7/8.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/WorkerActivationTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WorkerActivation")
struct WorkerActivationTests {
    private func descriptor(
        id: String, group: String = "social", binding: WorkerDescriptor.Binding
    ) -> WorkerDescriptor {
        WorkerDescriptor(
            id: id, displayName: id, description: "d", group: group, binding: binding,
            resources: .init(needsD1: false, needsKV: false, needsR2: false)
        )
    }

    private func pageNode(id: String) -> SiteGraphNode {
        SiteGraphNode(id: id, kind: .page, title: id, detail: nil, filePath: nil, route: "/\(id)")
    }

    private func componentNode(id: String) -> SiteGraphNode {
        SiteGraphNode(id: id, kind: .component, title: id, detail: nil, filePath: nil, route: nil)
    }

    @Test("a component-tied worker is active when its component is used by a page")
    func componentTiedActiveWhenPageUsesIt() {
        let catalog = [descriptor(id: "webmention", binding: .componentTied(componentIDs: ["webmention-form"]))]
        let graph = SiteGraphExplorerSnapshot(
            nodes: [pageNode(id: "page:home"), componentNode(id: "webmention-form")],
            edges: [SiteGraphEdge(sourceID: "page:home", targetID: "webmention-form", kind: .imports)]
        )
        let active = WorkerActivation.effectiveActiveIDs(settings: SiteSettings(), catalog: catalog, graph: graph)
        #expect(active == ["webmention"])
    }

    @Test("a component-tied worker is inactive when its component is unused")
    func componentTiedInactiveWhenUnused() {
        let catalog = [descriptor(id: "webmention", binding: .componentTied(componentIDs: ["webmention-form"]))]
        let graph = SiteGraphExplorerSnapshot(
            nodes: [pageNode(id: "page:home"), componentNode(id: "webmention-form")],
            edges: []
        )
        let active = WorkerActivation.effectiveActiveIDs(settings: SiteSettings(), catalog: catalog, graph: graph)
        #expect(active.isEmpty)
    }

    @Test("a component-tied worker is inactive when the graph is nil (headless deploy)")
    func componentTiedInactiveWhenGraphIsNil() {
        let catalog = [descriptor(id: "webmention", binding: .componentTied(componentIDs: ["webmention-form"]))]
        let active = WorkerActivation.effectiveActiveIDs(settings: SiteSettings(), catalog: catalog, graph: nil)
        #expect(active.isEmpty)
    }

    @Test("a component used only by another (page-unreachable) component does not count")
    func componentTiedRequiresAffectedPageNotJustAnyDependent() {
        let catalog = [descriptor(id: "webmention", binding: .componentTied(componentIDs: ["webmention-form"]))]
        // "wrapper" imports "webmention-form", but nothing imports "wrapper" — no page is affected.
        let graph = SiteGraphExplorerSnapshot(
            nodes: [componentNode(id: "wrapper"), componentNode(id: "webmention-form")],
            edges: [SiteGraphEdge(sourceID: "wrapper", targetID: "webmention-form", kind: .imports)]
        )
        let active = WorkerActivation.effectiveActiveIDs(settings: SiteSettings(), catalog: catalog, graph: graph)
        #expect(active.isEmpty)
    }

    @Test("a settings-activated worker is active when its id is in activeWorkerIDs")
    func settingsActivatedFromSettings() {
        let catalog = [descriptor(id: "solid-pod", group: "storage", binding: .settingsActivated)]
        let settings = SiteSettings(activeWorkerIDs: ["solid-pod"])
        let active = WorkerActivation.effectiveActiveIDs(settings: settings, catalog: catalog, graph: nil)
        #expect(active == ["solid-pod"])
    }

    @Test("a stale activeWorkerIDs entry no longer in the catalog is dropped")
    func staleActiveIDDropped() {
        let catalog = [descriptor(id: "solid-pod", group: "storage", binding: .settingsActivated)]
        let settings = SiteSettings(activeWorkerIDs: ["solid-pod", "retired-worker"])
        let active = WorkerActivation.effectiveActiveIDs(settings: settings, catalog: catalog, graph: nil)
        #expect(active == ["solid-pod"])
    }

    @Test("an activeWorkerIDs entry for a componentTied catalog id does not activate it directly")
    func activeWorkerIDsIgnoredForComponentTiedEntries() {
        // Defensive: activeWorkerIDs should only ever contain settingsActivated ids in practice,
        // but a componentTied id ending up there (e.g. stale data) must not bypass usage detection.
        let catalog = [descriptor(id: "webmention", binding: .componentTied(componentIDs: ["webmention-form"]))]
        let settings = SiteSettings(activeWorkerIDs: ["webmention"])
        let active = WorkerActivation.effectiveActiveIDs(settings: settings, catalog: catalog, graph: nil)
        #expect(active.isEmpty)
    }

    @Test("an empty catalog trusts activeWorkerIDs verbatim rather than deactivating everything")
    func emptyCatalogTrustsActiveWorkerIDs() {
        let settings = SiteSettings(activeWorkerIDs: ["solid-pod", "webdav"])
        let active = WorkerActivation.effectiveActiveIDs(settings: settings, catalog: [], graph: nil)
        #expect(active == ["solid-pod", "webdav"])
    }

    @Test("removedIDs is the previous set minus the next set")
    func removedIDsIsSetDifference() {
        let removed = WorkerActivation.removedIDs(previous: ["webmention", "indieauth"], next: ["indieauth"])
        #expect(removed == ["webmention"])
        #expect(WorkerActivation.removedIDs(previous: ["a"], next: ["a", "b"]).isEmpty)
    }

    @Test("mapToFeatures maps known catalog ids to Feature cases in declaration order")
    func mapToFeaturesKnownIDs() {
        let features = WorkerActivation.mapToFeatures(["websub", "indieauth"])
        #expect(features == [.indieauth, .websub])
    }

    @Test("mapToFeatures silently drops ids with no matching Feature case")
    func mapToFeaturesDropsUnknownIDs() {
        let features = WorkerActivation.mapToFeatures(["indieauth", "solid-pod"])
        #expect(features == [.indieauth])
    }

    @Test("mapToFeatures of an empty set is empty")
    func mapToFeaturesEmpty() {
        #expect(WorkerActivation.mapToFeatures([]).isEmpty)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path . --filter WorkerActivationTests`
Expected: FAIL — `cannot find 'WorkerActivation' in scope`

- [ ] **Step 3: Implement `WorkerActivation`**

Create `Sources/AnglesiteCore/WorkerActivation.swift`:

```swift
import Foundation

/// Computes which `@dwk/workers` catalog workers are active for a site right now, and diffs
/// that against the last-deployed set. Pure — no I/O, no actor isolation — so every input
/// (settings, catalog, graph snapshot) must be gathered by the caller first (#709 design §4).
public enum WorkerActivation {
    /// The effective active worker-id set: component-tied workers with at least one
    /// `ImpactAnalysis`-affected page, unioned with settings-activated workers the user toggled
    /// on. `graph` is `nil` for a headless deploy with no populated `SiteContentGraph` — in that
    /// case component-tied workers contribute nothing (`ImpactAnalysis` "never invents, may
    /// under-report" bias), while `activeWorkerIDs` still applies. If `catalog` is empty (no
    /// successful fetch, no cache — `WorkerCatalogFetcher` already degrades to cache on failure,
    /// so this is a fresh-install-with-no-network edge case), `activeWorkerIDs` is trusted
    /// verbatim instead of being intersected away, so a transient fetch failure can't silently
    /// deactivate every settings-activated worker.
    public static func effectiveActiveIDs(
        settings: SiteSettings,
        catalog: [WorkerDescriptor],
        graph: SiteGraphExplorerSnapshot?
    ) -> Set<String> {
        var active: Set<String> = []

        if let graph {
            for descriptor in catalog {
                guard case .componentTied(let componentIDs) = descriptor.binding else { continue }
                let isUsed = componentIDs.contains { componentID in
                    guard let report = ImpactAnalysis.analyze(snapshot: graph, targetID: componentID) else {
                        return false
                    }
                    return !report.affectedPages.isEmpty
                }
                if isUsed { active.insert(descriptor.id) }
            }
        }

        let requested = Set(settings.activeWorkerIDs ?? [])
        if catalog.isEmpty {
            active.formUnion(requested)
        } else {
            let settingsActivatedIDs = Set(catalog.compactMap { descriptor -> String? in
                guard case .settingsActivated = descriptor.binding else { return nil }
                return descriptor.id
            })
            active.formUnion(requested.intersection(settingsActivatedIDs))
        }

        return active
    }

    /// Worker ids present in `previous` but absent from `next` — used only to log what a deploy
    /// is tearing down (#709 design §7); the removal itself happens by omission from the newly
    /// generated `wrangler.toml`, not a separate API call.
    public static func removedIDs(previous: Set<String>, next: Set<String>) -> Set<String> {
        previous.subtracting(next)
    }

    /// Interim catalog-id → `Feature` shim (#709 design §4/§10): `generateWranglerToml` and
    /// `SocialWorkerProvisionCommand.provision` still take `[WorkerComposition.Feature]`, not
    /// `[WorkerDescriptor]`, until #708 migrates them. An id with no matching `Feature` case (a
    /// future, not-yet-composed catalog worker) is silently dropped — there is nothing else this
    /// call can do with it today. Iterating `Feature.allCases` (rather than mapping `ids`
    /// directly) gives deterministic, declaration-order output for stable `wrangler.toml` diffs.
    public static func mapToFeatures(_ ids: Set<String>) -> [WorkerComposition.Feature] {
        WorkerComposition.Feature.allCases.filter { ids.contains($0.rawValue) }
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --package-path . --filter WorkerActivationTests`
Expected: PASS (all 12 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WorkerActivation.swift Tests/AnglesiteCoreTests/WorkerActivationTests.swift
git commit -m "feat(workers): add WorkerActivation effective-active-set computation (#709)"
```

---

### Task 3: `SocialWorkerProvisionCommand.Result` gains `.workerNameConflict`

**Files:**
- Modify: `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift:13-17,171-183`
- Modify: `Sources/AnglesiteCore/SiteOperations.swift:134-146`
- Test: `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`
- Test: `Tests/AnglesiteCoreTests/SiteOperationsTests.swift`

**Interfaces:**
- Produces: `SocialWorkerProvisionCommand.Result.workerNameConflict(name: String, resources: WorkerComposition.ProvisionedResources)`. Consumed by Task 7 (`DeployModel` maps it to `.workerNameConflict` phase).

**Why:** today `provision`'s internal switch collapses a `DeployCommand.Result.workerNameConflict` from the injected `deployer` into a generic `.failed(reason: "Worker name … already in use …")`. That's harmless while `provision` has no live caller, but Task 7/8 route every deploy through it — silently downgrading `DeployModel`'s dedicated rename-and-retry sheet (#740) to a plain failure toast would be a real regression. Restore parity with `DeployCommand.Result` instead.

- [ ] **Step 1: Write the failing test**

Replace the existing test in `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift` (the one named `workerNameConflictMapsToFailed`, lines 186-203) with:

```swift
    @Test("a worker-name conflict from the deployer is propagated, not collapsed to failed")
    func workerNameConflictPropagates() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([
            ["d1", "create", "my-site-social", "--json"]: .init(stdout: #"{"result":{"uuid":"d1-id"}}"#, stderr: "", exitCode: 0),
            ["kv", "namespace", "create", "my-site-social", "--json"]: .init(stdout: #"{"result":{"id":"kv-id"}}"#, stderr: "", exitCode: 0),
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"]: .init(stdout: "Migrations applied", stderr: "", exitCode: 0),
        ])
        let deployer = DeployRecorder(result: .workerNameConflict(name: "taken-name"))
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, runner: recorder.runner, deployer: deployer.deployer)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site")

        guard case .workerNameConflict(let name, let resources) = result else {
            Issue.record("expected .workerNameConflict, got \(result)"); return
        }
        #expect(name == "taken-name")
        #expect(resources.d1DatabaseID == "d1-id")
        #expect(resources.kvNamespaceID == "kv-id")
    }
```

Also update `Result` usages elsewhere in the same file that exhaustively `switch` or pattern-match — none do (all existing tests use `guard case .succeeded`/`.failed`/`.blocked`, which remain valid since Swift `guard case` isn't exhaustive).

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: FAIL — `type 'SocialWorkerProvisionCommand.Result' has no member 'workerNameConflict'`

- [ ] **Step 3: Add the case and propagate it**

In `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift:13-17`, change:

```swift
    public enum Result: Sendable, Equatable {
        case succeeded(url: URL, resources: WorkerComposition.ProvisionedResources, duration: TimeInterval)
        case blocked(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning], resources: WorkerComposition.ProvisionedResources)
        case failed(reason: String, exitCode: Int32?, resources: WorkerComposition.ProvisionedResources)
    }
```

to:

```swift
    public enum Result: Sendable, Equatable {
        case succeeded(url: URL, resources: WorkerComposition.ProvisionedResources, duration: TimeInterval)
        case blocked(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning], resources: WorkerComposition.ProvisionedResources)
        /// The candidate Worker name is already in use on the connected Cloudflare account and
        /// this site has never deployed before — mirrors `DeployCommand.Result.workerNameConflict`
        /// rather than collapsing it, so callers can drive the same rename-and-retry UX (#740).
        case workerNameConflict(name: String, resources: WorkerComposition.ProvisionedResources)
        case failed(reason: String, exitCode: Int32?, resources: WorkerComposition.ProvisionedResources)
    }
```

Then in `SocialWorkerProvisionCommand.swift:171-183`, change:

```swift
        switch await deployer(token, siteID, siteDirectory) {
        case .succeeded(let url, _):
            return .succeeded(url: url, resources: resources, duration: Date().timeIntervalSince(started))
        case .blocked(let failures, let warnings):
            return .blocked(failures: failures, warnings: warnings, resources: resources)
        case .workerNameConflict(let name):
            return .failed(
                reason: "Worker name \"\(name)\" is already in use on your Cloudflare account — rename it in Anglesite and try again.",
                exitCode: nil, resources: resources)
        case .failed(let reason, let exitCode):
            return .failed(reason: reason, exitCode: exitCode, resources: resources)
        }
```

to:

```swift
        switch await deployer(token, siteID, siteDirectory) {
        case .succeeded(let url, _):
            return .succeeded(url: url, resources: resources, duration: Date().timeIntervalSince(started))
        case .blocked(let failures, let warnings):
            return .blocked(failures: failures, warnings: warnings, resources: resources)
        case .workerNameConflict(let name):
            return .workerNameConflict(name: name, resources: resources)
        case .failed(let reason, let exitCode):
            return .failed(reason: reason, exitCode: exitCode, resources: resources)
        }
```

- [ ] **Step 4: Fix the now-non-exhaustive switch in `SiteOperations.dialog(forSocialWorkerProvision:)`**

In `Sources/AnglesiteCore/SiteOperations.swift:134-146`, change:

```swift
    public static func dialog(forSocialWorkerProvision result: SocialWorkerProvisionCommand.Result) -> String {
        switch result {
        case .succeeded(let url, let resources, _):
            return "Social Worker provisioned at \(url.absoluteString).\(resourceSuffix(resources))"
        case .blocked(let failures, _, let resources):
            let count = failures.count
            let noun = count == 1 ? "issue" : "issues"
            return "Social Worker provisioning blocked by the pre-deploy security scan (\(count) \(noun)).\(resourceSuffix(resources))"
        case .failed(let reason, _, let resources):
            return "Social Worker provisioning failed: \(reason).\(resourceSuffix(resources))"
        }
    }
```

to:

```swift
    public static func dialog(forSocialWorkerProvision result: SocialWorkerProvisionCommand.Result) -> String {
        switch result {
        case .succeeded(let url, let resources, _):
            return "Social Worker provisioned at \(url.absoluteString).\(resourceSuffix(resources))"
        case .blocked(let failures, _, let resources):
            let count = failures.count
            let noun = count == 1 ? "issue" : "issues"
            return "Social Worker provisioning blocked by the pre-deploy security scan (\(count) \(noun)).\(resourceSuffix(resources))"
        case .workerNameConflict(let name, let resources):
            return "Social Worker provisioning blocked: the Worker name \"\(name)\" is already in use on your Cloudflare account. Rename the site's Worker in Anglesite and try again.\(resourceSuffix(resources))"
        case .failed(let reason, _, let resources):
            return "Social Worker provisioning failed: \(reason).\(resourceSuffix(resources))"
        }
    }
```

- [ ] **Step 5: Add a dialog test**

Add to `Tests/AnglesiteCoreTests/SiteOperationsTests.swift` (inside the `SiteOperationsTests` struct):

```swift
    @Test("social worker provisioning worker-name-conflict dialog names the taken Worker")
    func socialWorkerProvisionWorkerNameConflictDialog() {
        let result = SocialWorkerProvisionCommand.Result.workerNameConflict(
            name: "taken-name", resources: .init(d1DatabaseID: "d1")
        )
        let dialog = SiteOperations.dialog(forSocialWorkerProvision: result)
        #expect(dialog.contains("taken-name"))
        #expect(dialog.lowercased().contains("rename"))
        #expect(dialog.contains("Provisioned resources: D1."))
    }
```

- [ ] **Step 6: Run both test suites to verify they pass**

Run: `swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: PASS

Run: `swift test --package-path . --filter SiteOperationsTests`
Expected: PASS

- [ ] **Step 7: Full-package build check for other exhaustive switches**

Run: `swift build --package-path .`
Expected: builds clean — this surfaces any other exhaustive `switch` over `SocialWorkerProvisionCommand.Result` the grep in Step 4 might have missed.

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift Sources/AnglesiteCore/SiteOperations.swift \
        Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift Tests/AnglesiteCoreTests/SiteOperationsTests.swift
git commit -m "fix(workers): propagate worker-name conflicts instead of collapsing to failed (#709)"
```

---

### Task 4: `SocialWorkerProvisionCommand.provision` reuses known resource ids

**Files:**
- Modify: `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift:46-76`
- Test: `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`

**Interfaces:**
- Consumes: `WorkerComposition.ProvisionedResources` (existing).
- Produces: `SocialWorkerProvisionCommand.provision(siteID:siteDirectory:siteName:features:knownResources:)` — new `knownResources: WorkerComposition.ProvisionedResources = .init()` parameter, default preserves today's exact behavior (existing 8 tests in this file must pass unmodified). Consumed by Task 7/8, which pass `settings.provisionedWorkerResources ?? .init()`.

**Why:** `readPersistedResources` regex-scrapes the *current* `wrangler.toml`. Deactivating a worker regenerates the file without that resource's binding block, so the id vanishes from the file. Reactivating later then finds nothing persisted and tries `wrangler … create` again, which fails because the resource still exists under that name. `knownResources` (sourced from `SiteSettings.provisionedWorkerResources`, Task 1) is checked *before* falling back to the file scrape, so a durable record survives a worker being toggled off in between (design doc §6). `readPersistedResources` itself is untouched — it stays a pure file-scrape fallback for sites with no persisted record yet (pre-existing sites), so its own existing test (`persistedResourceParsing`) needs no changes.

- [ ] **Step 1: Write the failing regression test**

Add to `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift` (inside the struct):

```swift
    @Test("knownResources is reused instead of re-scraping wrangler.toml, so a deactivated-then-reactivated worker doesn't recreate its Cloudflare resource")
    func reusesKnownResourcesOverFileScrape() async throws {
        let site = try temporaryDirectory()
        // wrangler.toml on disk reflects the CURRENT (deactivated) feature set — no R2 block, so
        // a file-scrape alone would find no bucket name and try to recreate it.
        let currentToml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            features: [.indieauth],
            resources: .init(d1DatabaseID: "d1-id", kvNamespaceID: "kv-id", r2BucketName: nil)
        )
        try currentToml.write(to: site.appendingPathComponent("wrangler.toml"), atomically: true, encoding: .utf8)

        // knownResources (as persisted in SiteSettings before deactivation) still remembers the bucket.
        let known = WorkerComposition.ProvisionedResources(
            d1DatabaseID: "d1-id", kvNamespaceID: "kv-id", r2BucketName: "my-site-media"
        )
        let recorder = WranglerRecorder([
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"]: .init(stdout: "Migrations applied", stderr: "", exitCode: 0),
        ])
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            runner: recorder.runner,
            deployer: DeployRecorder(result: .succeeded(url: URL(string: "https://my-site.example.workers.dev")!, duration: 1)).deployer
        )

        // Reactivating micropub (needs R2) should reuse the known bucket, not call `r2 bucket create` again.
        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            features: [.indieauth, .micropub], knownResources: known
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.r2BucketName == "my-site-media")
        #expect(await recorder.arguments == [
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"],
        ])
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: FAIL — `incorrect argument label in call (have 'siteID:siteDirectory:siteName:features:knownResources:', expected 'siteID:siteDirectory:siteName:features:')`

- [ ] **Step 3: Add the `knownResources` parameter**

In `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift:46-76`, change the `provision` signature and its first two lines:

```swift
    public func provision(
        siteID: String,
        siteDirectory: URL,
        siteName: String,
        features: [WorkerComposition.Feature] = WorkerComposition.Feature.v2
    ) async -> Result {
```

to:

```swift
    public func provision(
        siteID: String,
        siteDirectory: URL,
        siteName: String,
        features: [WorkerComposition.Feature] = WorkerComposition.Feature.v2,
        /// Resources already known from `SiteSettings.provisionedWorkerResources` (#709), checked
        /// before falling back to `readPersistedResources`'s wrangler.toml scrape. Durable across
        /// a worker being deactivated (which drops its binding block from the file) and later
        /// reactivated — the default (`.init()`, all-nil) makes this call fall through to the
        /// existing file-scrape-only behavior unchanged.
        knownResources: WorkerComposition.ProvisionedResources = .init()
    ) async -> Result {
```

Then find the line (currently `SocialWorkerProvisionCommand.swift:75`):

```swift
        var resources = Self.readPersistedResources(from: siteDirectory)
```

and change it to:

```swift
        var resources = knownResources == .init() ? Self.readPersistedResources(from: siteDirectory) : knownResources
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: PASS (all tests in the file, including the 8 pre-existing ones — confirming the default parameter preserves prior behavior)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift
git commit -m "fix(workers): reuse persisted resource ids across worker deactivate/reactivate (#709)"
```

---

### Task 5: `ContainerCommandRunner`

**Files:**
- Create: `Sources/AnglesiteCore/ContainerCommandRunner.swift`
- Test: `Tests/AnglesiteCoreTests/ContainerCommandRunnerTests.swift`

**Interfaces:**
- Consumes: `LocalContainerControl` (existing, `LocalContainerControl.swift:80-127`); `SocialWorkerProvisionCommand.CommandRunner` (existing typealias: `@Sendable (_ siteDirectory: URL, _ arguments: [String], _ environment: [String: String], _ source: String) async throws -> ProcessSupervisor.RunResult`); `FakeLocalContainerControl` (existing test helper, `Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift`).
- Produces: `ContainerCommandRunner(control:siteID:logCenter:).runner: SocialWorkerProvisionCommand.CommandRunner`. Consumed by Task 7/8.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/ContainerCommandRunnerTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ContainerCommandRunner")
struct ContainerCommandRunnerTests {
    private func fakePassing(exitCode: Int32 = 0, stdout: String = "ok") -> FakeLocalContainerControl {
        FakeLocalContainerControl(
            startResult: .failure(.virtualizationUnavailable),
            execResult: ContainerExecResult(exitCode: exitCode, stdout: stdout, stderr: ""),
            execStdoutLines: []
        )
    }

    @Test("arguments are prefixed with npx wrangler")
    func argvIsPrefixedWithWrangler() async throws {
        let fake = fakePassing()
        let runner = ContainerCommandRunner(control: fake, siteID: "site-abc", logCenter: LogCenter())

        _ = try await runner.runner(
            URL(fileURLWithPath: "/host/irrelevant"),
            ["d1", "create", "my-site-social", "--json"],
            [:],
            "worker-provision:site-abc"
        )

        let calls = await fake.execCalls
        #expect(calls.count == 1)
        #expect(calls[0].argv == ["npx", "wrangler", "d1", "create", "my-site-social", "--json"])
        #expect(calls[0].cwd == "/workspace/site")
    }

    @Test("exit code and stdout are surfaced in the RunResult")
    func surfacesExitCodeAndStdout() async throws {
        let fake = fakePassing(exitCode: 0, stdout: #"{"result":{"uuid":"d1-id"}}"#)
        let runner = ContainerCommandRunner(control: fake, siteID: "site-abc", logCenter: LogCenter())

        let result = try await runner.runner(URL(fileURLWithPath: "/host"), ["d1", "create", "x", "--json"], [:], "src")

        #expect(result.exitCode == 0)
        #expect(result.stdout == #"{"result":{"uuid":"d1-id"}}"#)
    }

    @Test("a non-zero exit code is surfaced, not thrown")
    func nonZeroExitCodeSurfaced() async throws {
        let fake = fakePassing(exitCode: 1, stdout: "already exists")
        let runner = ContainerCommandRunner(control: fake, siteID: "site-abc", logCenter: LogCenter())

        let result = try await runner.runner(URL(fileURLWithPath: "/host"), ["r2", "bucket", "create", "x"], [:], "src")

        #expect(result.exitCode == 1)
        #expect(result.stdout == "already exists")
    }

    @Test("CLOUDFLARE_API_TOKEN is forwarded to the guest environment")
    func forwardsToken() async throws {
        let fake = fakePassing()
        let runner = ContainerCommandRunner(control: fake, siteID: "site-abc", logCenter: LogCenter())

        _ = try await runner.runner(
            URL(fileURLWithPath: "/host"), ["d1", "create", "x", "--json"],
            ["CLOUDFLARE_API_TOKEN": "supersecret", "PATH": "/opt/homebrew/bin"], "src"
        )

        let calls = await fake.execCalls
        #expect(calls[0].env["CLOUDFLARE_API_TOKEN"] == "supersecret")
        #expect(calls[0].env["PATH"] == nil)
    }

    @Test("stdout lines stream to LogCenter under the given source")
    func streamsToLogCenter() async throws {
        let logCenter = LogCenter()
        let fake = FakeLocalContainerControl(
            startResult: .failure(.virtualizationUnavailable),
            execResult: ContainerExecResult(exitCode: 0, stdout: "done", stderr: ""),
            execStdoutLines: ["Creating D1 database 'my-site-social'"]
        )
        let runner = ContainerCommandRunner(control: fake, siteID: "site-abc", logCenter: logCenter)

        _ = try await runner.runner(URL(fileURLWithPath: "/host"), ["d1", "create", "x", "--json"], [:], "worker-provision:site-abc")

        let snapshot = await logCenter.snapshot()
        #expect(snapshot.contains { $0.source == "worker-provision:site-abc" && $0.text == "Creating D1 database 'my-site-social'" })
    }

    @Test("a dead container surfaces a throw, not a hang")
    func deadContainerThrows() async {
        // The shared `FakeLocalContainerControl` (Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift)
        // always succeeds — its `exec` has no way to throw. `ContainerDeployExecutorTests.swift`
        // hits this same limitation and defines a local throwing fake for exactly this case;
        // mirror that pattern here rather than the shared fake.
        let fake = ThrowingFakeLocalContainerControl()
        let runner = ContainerCommandRunner(control: fake, siteID: "site-abc", logCenter: LogCenter())

        await #expect(throws: ThrowingFakeLocalContainerControl.ExecError.self) {
            _ = try await runner.runner(URL(fileURLWithPath: "/host"), ["d1", "create", "x", "--json"], [:], "src")
        }
    }
}

// Mirrors `ContainerDeployExecutorTests.swift`'s private `ThrowingFakeLocalContainerControl` —
// duplicated locally (not shared) because that one is `private` to its own test file.
private actor ThrowingFakeLocalContainerControl: LocalContainerControl {
    enum ExecError: Error { case boom }

    func start(
        siteID: String, sourceRepo: URL, ref: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> LocalContainerSession {
        throw ExecError.boom
    }
    func stop(siteID: String) async throws {}
    func exec(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> ContainerExecResult {
        throw ExecError.boom
    }
    func execInteractive(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> InteractiveExecHandle {
        throw ExecError.boom
    }
}
```

Before this step, read `Tests/AnglesiteCoreTests/FakeLocalContainerControl.swift` once to confirm its `init` parameter names (`startResult:startStdoutLines:execResult:execStdoutLines:execInteractiveStdoutLines:`, all confirmed against the actual file as of this plan's writing) still match — if a later change to that shared fake has added an `execError`-style throwing seam since, use that instead of the local duplicate above.

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path . --filter ContainerCommandRunnerTests`
Expected: FAIL — `cannot find 'ContainerCommandRunner' in scope`

- [ ] **Step 3: Implement `ContainerCommandRunner`**

Create `Sources/AnglesiteCore/ContainerCommandRunner.swift`:

```swift
import Foundation

/// Runs `SocialWorkerProvisionCommand`'s wrangler subcommands (`d1`/`kv`/`r2 create`,
/// `d1 migrations apply`, …) inside a running container via `LocalContainerControl.exec` —
/// the `CommandRunner` counterpart to `ContainerDeployExecutor` (`DeployExecutor.swift:61-168`),
/// which does the same for the three fixed deploy steps. `SocialWorkerProvisionCommand`'s
/// `arguments` are already bare wrangler subcommand argv (e.g. `["d1", "create", name, "--json"]`);
/// this just prefixes `["npx", "wrangler"]` and adapts the result shape.
public struct ContainerCommandRunner: Sendable {
    private let control: any LocalContainerControl
    private let siteID: String
    private let logCenter: LogCenter

    public init(control: any LocalContainerControl, siteID: String, logCenter: LogCenter = .shared) {
        self.control = control
        self.siteID = siteID
        self.logCenter = logCenter
    }

    /// Bind this instance's `run` as a `SocialWorkerProvisionCommand.CommandRunner` closure.
    public var runner: SocialWorkerProvisionCommand.CommandRunner {
        { [self] siteDirectory, arguments, environment, source in
            try await self.run(siteDirectory: siteDirectory, arguments: arguments, environment: environment, source: source)
        }
    }

    // Guest-only allowlist — same rationale as `ContainerDeployExecutor.guestEnvAllowlist`: the
    // host (macOS) environment must never cross into the Linux guest wholesale.
    private static let guestEnvAllowlist: Set<String> = ["CLOUDFLARE_API_TOKEN"]

    private func run(
        siteDirectory: URL,
        arguments: [String],
        environment: [String: String],
        source: String
    ) async throws -> ProcessSupervisor.RunResult {
        let argv = ["npx", "wrangler"] + arguments
        let guestEnvironment = environment.filter { Self.guestEnvAllowlist.contains($0.key) }

        let (lines, continuation) = AsyncStream<(String, LogCenter.Stream)>.makeStream(bufferingPolicy: .unbounded)
        let logCenter = self.logCenter
        let drain = Task.detached(priority: .utility) {
            for await (line, stream) in lines {
                await logCenter.append(source: source, stream: stream, text: line)
            }
        }

        let result: ContainerExecResult
        do {
            result = try await control.exec(
                siteID: siteID,
                argv: argv,
                environment: guestEnvironment,
                workingDirectory: "/workspace/site",
                onOutput: { line, stream in continuation.yield((line, stream)) }
            )
        } catch {
            continuation.finish()
            _ = await drain.value
            throw error
        }
        continuation.finish()
        _ = await drain.value
        return ProcessSupervisor.RunResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }
}
```

Before finalizing, check `ProcessSupervisor.RunResult`'s exact initializer (`Sources/AnglesiteCore/ProcessSupervisor.swift`, or wherever it's declared — grep `struct RunResult`) to confirm the `stdout:stderr:exitCode:` label order and that `exitCode` is `Int32` (matching `ContainerExecResult.exitCode: Int32`, no optional conversion needed) before compiling.

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --package-path . --filter ContainerCommandRunnerTests`
Expected: PASS (all 6 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ContainerCommandRunner.swift Tests/AnglesiteCoreTests/ContainerCommandRunnerTests.swift
git commit -m "feat(workers): add ContainerCommandRunner so provisioning runs in-guest (#709)"
```

---

### Task 6: Production `catalogURL`

**Files:**
- Modify: `Sources/AnglesiteCore/WorkerCatalogFetcher.swift:22-55`
- Test: `Tests/AnglesiteCoreTests/WorkerCatalogFetcherTests.swift`

**Interfaces:**
- Produces: `WorkerCatalogFetcher.productionCatalogURL: URL`. Consumed by Task 7/8.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/WorkerCatalogFetcherTests.swift` (inside the `WorkerCatalogFetcherTests` struct):

```swift
    @Test("productionCatalogURL points at the published davidwkeith/workers catalog.json")
    func productionCatalogURLIsThePublishedManifest() {
        #expect(
            WorkerCatalogFetcher.productionCatalogURL
                == URL(string: "https://raw.githubusercontent.com/davidwkeith/workers/main/catalog.json")!
        )
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path . --filter WorkerCatalogFetcherTests`
Expected: FAIL — `type 'WorkerCatalogFetcher' has no member 'productionCatalogURL'`

- [ ] **Step 3: Add the constant**

In `Sources/AnglesiteCore/WorkerCatalogFetcher.swift`, remove the now-stale doc-comment caveat at lines 22-24 (`- Important: catalogURL has no in-app default...`) and add a static constant just above `defaultCacheURL` (near line 101):

```swift
    /// The published `@dwk/workers` monorepo catalog manifest — verified live 2026-07-17
    /// (davidwkeith/workers#255, merged in davidwkeith/workers#258). Callers still supply
    /// `catalogURL` explicitly at `init`; this is the value production call sites should pass.
    public static let productionCatalogURL = URL(
        string: "https://raw.githubusercontent.com/davidwkeith/workers/main/catalog.json"
    )!
```

Update the type's doc comment (lines 17-24) to drop the "no in-app default" caveat, since one now exists:

```swift
/// Fetches, parses, and disk-caches the `@dwk/workers` catalog manifest (`catalog.json`).
/// Network or parse failures degrade to the last successfully cached copy, then to an empty
/// catalog — the Workers Settings tab and deploy composition must never block or crash on a
/// catalog fetch failure (design doc §3).
public actor WorkerCatalogFetcher {
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --package-path . --filter WorkerCatalogFetcherTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WorkerCatalogFetcher.swift Tests/AnglesiteCoreTests/WorkerCatalogFetcherTests.swift
git commit -m "feat(workers): wire the published production catalog.json URL (#709, #708)"
```

---

### Task 7: Wire `DeployModel.runDeploy` through `WorkerActivation` + `SocialWorkerProvisionCommand`

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift:111-131` (init), `:347-478` (`runDeploy`)
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:74`
- Test: `Tests/AnglesiteAppTests/DeployModelTests.swift`

**Interfaces:**
- Consumes: `WorkerActivation.effectiveActiveIDs`/`.mapToFeatures` (Task 2), `SocialWorkerProvisionCommand` incl. `.workerNameConflict` + `knownResources` (Tasks 3, 4), `ContainerCommandRunner` (Task 5), `WorkerCatalogFetcher.productionCatalogURL` (Task 6), `SiteConfigStore` (existing), `SiteContentGraph.isPopulated(siteID:)`/`.pages(for:)`/`.posts(for:)`/`.images(for:)` (existing), `SiteGraphExplorer.build` (existing, `SiteGraphExplorer.swift:95-102`).
- Produces: `DeployModel(contentGraph:command:workerCatalog:socialWorkerCommandBuilder:...)` — see Step 3 for the exact new init parameters and their test-safe defaults.

**Design note (deviates slightly from spec wording for testability):** the design doc's §5 describes `DeployModel` building a `WorkerCatalogFetcher` and a `SocialWorkerProvisionCommand` directly inside `runDeploy`. To keep `DeployModelTests` free of real network calls and real `SocialWorkerProvisionCommand` construction, this task injects two closures instead: `workerCatalog: @Sendable () async -> [WorkerDescriptor]` (defaults to `{ [] }` — safe/offline; production wiring in `SiteWindowModel` passes the real fetcher) and `socialWorkerRunner: @Sendable (any LocalContainerControl, String) -> SocialWorkerProvisionCommand.CommandRunner` is **not** needed as a separate seam — `ContainerCommandRunner` is constructed inline from the `containerControl` already available in `runDeploy`, mirroring exactly how `activeCommand`'s `ContainerDeployExecutor` is already built inline there. Only `workerCatalog` and `contentGraph` are new stored dependencies.

- [ ] **Step 1: Write the failing test — non-worker sites still deploy exactly as before**

Add to `Tests/AnglesiteAppTests/DeployModelTests.swift` (inside the `DeployModelTests` struct, after the existing tests):

```swift
    @Test("a site with no active workers still deploys through the plain static path")
    func staticSiteDeploysUnaffected() async throws {
        let executor = GatedDeployExecutor()
        await executor.resumeBuild()
        let command = DeployCommand(tokenSource: { "test-token" }, executor: executor)
        let contentGraph = SiteContentGraph()
        let model = DeployModel(
            command: command,
            logCenter: LogCenter(),
            suddenTerminationController: SuddenTerminationController(disable: {}, enable: {}),
            tokenAvailabilityOverride: { true },
            contentGraph: contentGraph,
            workerCatalog: { [] }
        )
        let dir = try temporaryDirectory()

        model.deploy(siteID: "test-site", siteDirectory: dir, configDirectory: dir, currentRoutes: [])
        while model.isRunning { await Task.yield() }

        guard case .succeeded = model.phase else {
            Issue.record("Expected deploy to succeed, got \(model.phase)")
            return
        }
    }

    @Test("a site with a settings-activated worker persists lastDeployedWorkerIDs after a successful deploy")
    func activatingAWorkerPersistsLastDeployedWorkerIDs() async throws {
        let executor = GatedDeployExecutor()
        await executor.resumeBuild()
        let command = DeployCommand(tokenSource: { "test-token" }, executor: executor)
        let contentGraph = SiteContentGraph()
        let catalog = [
            WorkerDescriptor(
                id: "indieauth", displayName: "IndieAuth", description: "d", group: "identity",
                binding: .settingsActivated, resources: .init(needsD1: true, needsKV: false, needsR2: false)
            )
        ]
        let model = DeployModel(
            command: command,
            logCenter: LogCenter(),
            suddenTerminationController: SuddenTerminationController(disable: {}, enable: {}),
            tokenAvailabilityOverride: { true },
            contentGraph: contentGraph,
            workerCatalog: { catalog }
        )
        let dir = try temporaryDirectory()
        let configDir = dir.appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let configStore = SiteConfigStore(configDirectory: configDir)
        try await configStore.save(SiteSettings(activeWorkerIDs: ["indieauth"]))

        model.deploy(siteID: "test-site", siteDirectory: dir, configDirectory: configDir, currentRoutes: [])
        while model.isRunning { await Task.yield() }

        // provision() has no working runner outside a container (Task 5's ContainerCommandRunner
        // requires a real LocalContainerControl) — without containerControl this deploy is
        // expected to fail at the D1-provisioning step, NOT silently skip worker composition.
        guard case .failed = model.phase else {
            Issue.record("Expected a provisioning failure without a container, got \(model.phase)")
            return
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeployModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path . --filter DeployModelTests`
Expected: FAIL — `incorrect argument label in call ... expected 'command:logCenter:...'` (no `contentGraph`/`workerCatalog` params yet)

- [ ] **Step 3: Add the new dependencies to `DeployModel`'s init**

In `Sources/AnglesiteApp/DeployModel.swift`, add two stored properties near `private let logCenter: LogCenter` (line 82):

```swift
    private let contentGraph: SiteContentGraph
    /// Returns the current `@dwk/workers` catalog. Defaults to `{ [] }` (no network, no active
    /// settings-activated workers ever computed) so existing tests that don't inject one keep
    /// deploying exactly as before — production wiring (`SiteWindowModel`) passes a real
    /// `WorkerCatalogFetcher(catalogURL: WorkerCatalogFetcher.productionCatalogURL).catalog`.
    private let workerCatalog: @Sendable () async -> [WorkerDescriptor]
```

and extend the initializer (lines 111-131):

```swift
    init(
        command: DeployCommand = DeployCommand(),
        webmentionCommand: WebmentionSendCommand = WebmentionSendCommand(),
        posseCommand: POSSESyndicationCommand = POSSESyndicationCommand(),
        logCenter: LogCenter = .shared,
        keychain: KeychainStore = KeychainStore(),
        verifier: TokenVerifying = CloudflareAPITokenVerifier(),
        summarizer: any DeployFailureSummarizing = DeploySummarizerFactory.makeDefault(),
        suddenTerminationController: SuddenTerminationController = .shared,
        tokenAvailabilityOverride: (() -> Bool)? = nil,
        contentGraph: SiteContentGraph = SiteContentGraph(),
        workerCatalog: @escaping @Sendable () async -> [WorkerDescriptor] = { [] }
    ) {
        self.command = command
        self.webmentionCommand = webmentionCommand
        self.posseCommand = posseCommand
        self.logCenter = logCenter
        self.keychain = keychain
        self.onboarding = TokenOnboarding(verifier: verifier)
        self.summarizer = summarizer
        self.suddenTerminationController = suddenTerminationController
        self.tokenAvailabilityOverride = tokenAvailabilityOverride
        self.contentGraph = contentGraph
        self.workerCatalog = workerCatalog
    }
```

- [ ] **Step 4: Rewrite `runDeploy`'s dispatch to route through `WorkerActivation` + `SocialWorkerProvisionCommand`**

In `Sources/AnglesiteApp/DeployModel.swift`, replace lines 380-421 (from the `// Select the executor:` comment through `_ = await logTask.value`) with:

```swift
        // Select the executor: in-container when the runtime is a started container;
        // explicit unavailable result otherwise. The token source always comes from the
        // injected `command` so the test-injection path (a fully pre-built
        // `DeployCommand`) continues to work unmodified.
        let activeCommand: DeployCommand
        let containerRunner: SocialWorkerProvisionCommand.CommandRunner?
        if let cc = containerControl {
            activeCommand = DeployCommand(
                tokenSource: command.tokenSource,
                executor: ContainerDeployExecutor(
                    control: cc.control,
                    siteID: cc.siteID,
                    logCenter: logCenter
                )
            )
            containerRunner = ContainerCommandRunner(control: cc.control, siteID: cc.siteID, logCenter: logCenter).runner
        } else {
            activeCommand = command
            containerRunner = nil
        }

        // Effective active worker set (#709 design §4-5): component-tied workers via
        // ImpactAnalysis (only when this site's content graph has actually been scanned — a
        // headless/never-opened site contributes nothing there, matching ImpactAnalysis's own
        // "never invents, may under-report" bias) unioned with settings-activated workers.
        let configStore = SiteConfigStore(configDirectory: configDirectory)
        let settings = (try? await configStore.load()) ?? SiteSettings()
        let catalog = await workerCatalog()
        let snapshot: SiteGraphExplorerSnapshot?
        if await contentGraph.isPopulated(siteID: siteID) {
            snapshot = SiteGraphExplorer.build(
                projectRoot: siteDirectory,
                siteID: siteID,
                pages: await contentGraph.pages(for: siteID),
                posts: await contentGraph.posts(for: siteID),
                images: await contentGraph.images(for: siteID)
            )
        } else {
            snapshot = nil
        }
        let effectiveActiveIDs = WorkerActivation.effectiveActiveIDs(settings: settings, catalog: catalog, graph: snapshot)
        let removedIDs = WorkerActivation.removedIDs(previous: Set(settings.lastDeployedWorkerIDs ?? []), next: effectiveActiveIDs)
        if !removedIDs.isEmpty {
            await logCenter.append(
                source: "deploy:\(siteID)",
                stream: .stdout,
                text: "Deactivating workers: \(removedIDs.sorted().joined(separator: ", "))"
            )
        }
        let features = WorkerActivation.mapToFeatures(effectiveActiveIDs)

        let socialCommand = SocialWorkerProvisionCommand(
            tokenSource: { [weak self] in try await self?.command.tokenSource() },
            runner: containerRunner ?? SocialWorkerProvisionCommand.defaultRunner,
            deployer: { _, deploySiteID, deploySiteDirectory in
                await activeCommand.deploy(
                    siteID: deploySiteID,
                    siteDirectory: deploySiteDirectory,
                    configDirectory: configDirectory,
                    currentRoutes: currentRoutes,
                    onPreflight: { [weak self] outcome in
                        Task { @MainActor in self?.onScanComplete?(outcome) }
                    },
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            self?.currentMilestone = progress.label
                            self?.onMilestone?(siteID, progress)
                        }
                    }
                )
            }
        )

        let provisionResult = await socialCommand.provision(
            siteID: siteID,
            siteDirectory: siteDirectory,
            siteName: SiteSlug.derive(from: siteID),
            features: features,
            knownResources: settings.provisionedWorkerResources ?? .init()
        )

        if case .succeeded(_, let resources, _) = provisionResult {
            var updated = settings
            updated.lastDeployedWorkerIDs = Array(effectiveActiveIDs).sorted()
            updated.provisionedWorkerResources = resources
            try? await configStore.save(updated)
        }

        let result: DeployCommand.Result
        switch provisionResult {
        case .succeeded(let url, _, let duration):
            result = .succeeded(url: url, duration: duration)
        case .blocked(let failures, let warnings, _):
            result = .blocked(failures: failures, warnings: warnings)
        case .workerNameConflict(let name, _):
            result = .workerNameConflict(name: name)
        case .failed(let reason, let exitCode, _):
            result = .failed(reason: reason, exitCode: exitCode)
        }

        subscription.cancel()
        _ = await logTask.value
```

**`siteName` threading.** `SiteSlug.derive(from:)` (`NewSiteDraft.swift:135`) needs the site's *display* name (e.g. `"Blue Bottle Cafe"` → `"blue-bottle-cafe"`), matching what `SiteOperations.provisionSocialWorker` already passes it (`SiteOperations.swift:82`: `SiteSlug.derive(from: site.name)`). `runDeploy` only has `siteID` (an opaque id) in scope today — `SiteWindowModel.deploySite()` (`SiteWindowModel.swift:469-482`) and `performInvisiblePublish` (`SiteWindowModel.swift:1413-1426`) both call `deploy.deploy(...)`/`deploy.deployAutomatically(...)` with a `site: SiteStore.Site` already in scope (`site.name` is right there), so thread a new `siteName: String? = nil` parameter through `deploy`/`deployAutomatically`/`runDeploy`, defaulted to `nil` so every existing test call (which only ever set `siteID` to a placeholder like `"test-site"`) keeps compiling unchanged. Inside `runDeploy`, resolve it with `let workerSiteName = siteName ?? siteID` before calling `SiteSlug.derive(from:)` — a safe fallback for tests/callers that don't pass a real display name, while production always does.

Add `siteName: String? = nil` to `deploy(...)` (`DeployModel.swift:154-160`) and `deployAutomatically(...)` (`DeployModel.swift:187-193`), thread it into their `runDeploy(...)` calls (`DeployModel.swift:174-179`, `200-208`) alongside the existing parameters, and add the same parameter to `runDeploy`'s own signature (`DeployModel.swift:347-355`). Then in `SiteWindowModel.swift:479` change:

```swift
            deploy.deploy(
                siteID: site.id, siteDirectory: site.sourceDirectory,
                configDirectory: site.configDirectory, currentRoutes: currentRoutes,
                containerControl: containerControl)
```

to:

```swift
            deploy.deploy(
                siteID: site.id, siteDirectory: site.sourceDirectory,
                configDirectory: site.configDirectory, currentRoutes: currentRoutes,
                containerControl: containerControl, siteName: site.name)
```

and in `SiteWindowModel.swift:1421-1426` change:

```swift
        return await deploy.deployAutomatically(
            siteID: site.id,
            siteDirectory: site.sourceDirectory,
            configDirectory: site.configDirectory,
            currentRoutes: pageRoutes + postRoutes,
            containerControl: containerControl
        )
```

to:

```swift
        return await deploy.deployAutomatically(
            siteID: site.id,
            siteDirectory: site.sourceDirectory,
            configDirectory: site.configDirectory,
            currentRoutes: pageRoutes + postRoutes,
            containerControl: containerControl,
            siteName: site.name
        )
```

Then, in the `runDeploy` code block above, replace this line:

```swift
        let provisionResult = await socialCommand.provision(
            siteID: siteID,
            siteDirectory: siteDirectory,
            siteName: SiteSlug.derive(from: siteID),
```

with:

```swift
        let provisionResult = await socialCommand.provision(
            siteID: siteID,
            siteDirectory: siteDirectory,
            siteName: SiteSlug.derive(from: siteName ?? siteID),
```

Remove the old lines that duplicated the `DeployCommand.deploy` call (the original `let result = await activeCommand.deploy(...)` block) — it's now fully replaced by the block above.

- [ ] **Step 5: Wire `SiteWindowModel` to pass the real `contentGraph` and catalog fetcher**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, `SiteWindowModel` already stores `contentGraph: SiteContentGraph` from its own `init` (line 45, 178-179, 186). Change line 74 from:

```swift
    var deploy = DeployModel()
```

to a property initialized inside `init` instead of at declaration (since it now depends on `self.contentGraph`). Change the declaration to:

```swift
    var deploy: DeployModel
```

and add this assignment inside `SiteWindowModel.init` (near `self.contentGraph = contentGraph` at line 186):

```swift
        self.deploy = DeployModel(
            contentGraph: contentGraph,
            workerCatalog: { await WorkerCatalogFetcher(catalogURL: WorkerCatalogFetcher.productionCatalogURL).catalog() }
        )
```

Place it after `self.contentGraph = contentGraph` so the closure's capture is unambiguous. If `SiteWindowModel`'s init has other stored-property assignments between lines 178-205 that must happen in a specific order (Swift requires `self` fully initialized before capturing `self` in closures — this closure only captures nothing external, it constructs a fresh `WorkerCatalogFetcher`, so ordering relative to other properties doesn't matter, but it must come after all other `let`/`var` properties are assigned if any earlier code path in `init` reads `self.deploy` before this line — verify no such read exists by searching for `self.deploy` or `deploy.` before line 205 in the same init).

- [ ] **Step 6: Run the DeployModel test suite**

Run: `swift test --package-path . --filter DeployModelTests`
Expected: PASS (all tests, including the two new ones from Step 1 and the pre-existing worker-name-conflict test, which must still pass since `.workerNameConflict` now flows through `SocialWorkerProvisionCommand.Result` before being mapped back — trace: does that pre-existing test inject a `containerControl`? If not, `containerRunner` is `nil` and `SocialWorkerProvisionCommand.defaultRunner` is used, which never calls `deployer` at all for a conflict scenario — re-read the existing `workerNameConflictParksAndPresents` test (`DeployModelTests.swift:85+`) in full before this step to confirm whether it needs `containerControl` injected to reach the `deployer` closure, since `provision()` only calls `deployer` after any D1/KV/R2 steps succeed, and those steps are gated on `features.contains(where: needsD1)` etc. — if the test's site has no active workers (empty `features`), `provision()` skips straight to `deployer` regardless of `containerRunner`, so it should still work; verify this by running the test, not by assumption).

- [ ] **Step 7: Full build check**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: builds clean (this exercises `AnglesiteApp` target code the `swift test` SwiftPM lanes don't necessarily compile identically — per CLAUDE.md, `swift test` alone doesn't cover the hosted app target).

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteApp/DeployModel.swift Sources/AnglesiteApp/SiteWindowModel.swift Tests/AnglesiteAppTests/DeployModelTests.swift
git commit -m "feat(workers): route the main Deploy button through effective-active-set composition (#709)"
```

---

### Task 8: Wire `SiteOperations.deploy` (headless path)

**Files:**
- Modify: `Sources/AnglesiteCore/SiteOperations.swift:40-51`
- Test: `Tests/AnglesiteCoreTests/SiteOperationsTests.swift`

**Interfaces:**
- Consumes: `WorkerActivation` (Task 2), `SocialWorkerProvisionCommand` (Tasks 3-4), `SiteConfigStore` (existing). Deliberately **no** `SiteContentGraph`/catalog dependency — per design doc §8, headless deploy always passes `graph: nil` and, absent a richer catalog source, `catalog: []` (which per `WorkerActivation`'s empty-catalog fallback still honors `activeWorkerIDs` verbatim).
- Produces: `SiteOperations.deploy(site:onProgress:)` now routes through `SocialWorkerProvisionCommand.provision` the same way `DeployModel` does, persisting `lastDeployedWorkerIDs`/`provisionedWorkerResources` on success.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/SiteOperationsTests.swift` (inside the struct):

```swift
    @Test("headless deploy with a settings-activated worker routes through provision and persists lastDeployedWorkerIDs")
    func headlessDeployWithActiveWorkerPersistsState() async throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let site = makeSite(name: "Blue Bottle Cafe", packageURL: package)
        let configStore = SiteConfigStore(configDirectory: site.configDirectory)
        try await configStore.save(SiteSettings(activeWorkerIDs: ["indieauth"]))

        let recorder = SocialWorkerRecorder()
        let ops = SiteOperations(factory: SocialWorkerFactory(recorder: recorder), store: throwawayStore())

        let result = await ops.deploy(site: site)

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        let saved = try await configStore.load()
        #expect(saved.lastDeployedWorkerIDs == ["indieauth"])
    }

    @Test("headless deploy with no activated workers still deploys through the plain static path")
    func headlessDeployWithNoActiveWorkers() async throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let site = makeSite(name: "Blue Bottle Cafe", packageURL: package)
        let recorder = SocialWorkerRecorder()
        let ops = SiteOperations(factory: SocialWorkerFactory(recorder: recorder), store: throwawayStore())

        let result = await ops.deploy(site: site)

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(await recorder.arguments.isEmpty)
    }
```

Before writing this, confirm `SiteStore.Site` exposes `configDirectory` as a computed property (per `CLAUDE.md`'s "`SiteStore.Site` carries `packageURL` + computed `sourceDirectory`/`configDirectory`") by grepping `Sources/AnglesiteCore/SiteStore.swift` for `var configDirectory`.

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path . --filter SiteOperationsTests`
Expected: FAIL — `saved.lastDeployedWorkerIDs` is `nil` (deploy doesn't yet compute/persist the effective set)

- [ ] **Step 3: Rewrite `SiteOperations.deploy`**

In `Sources/AnglesiteCore/SiteOperations.swift:40-51`, change:

```swift
    public func deploy(site: SiteStore.Site, onProgress: ProgressHandler? = nil) async -> DeployCommand.Result {
        do {
            return try await SiteAccess.withScopedAccess(to: site, in: store) { url in
                await factory.deploy().deploy(siteID: site.id, siteDirectory: url, onProgress: onProgress)
            }
        } catch let SiteAccess.AccessError.noGrant(message) {
            return .failed(reason: message, exitCode: nil)
        } catch {
            return .failed(reason: error.localizedDescription, exitCode: nil)
        }
    }
```

to:

```swift
    public func deploy(site: SiteStore.Site, onProgress: ProgressHandler? = nil) async -> DeployCommand.Result {
        do {
            return try await SiteAccess.withScopedAccess(to: site, in: store) { url in
                await self.deployWithWorkerComposition(site: site, siteDirectory: url, onProgress: onProgress)
            }
        } catch let SiteAccess.AccessError.noGrant(message) {
            return .failed(reason: message, exitCode: nil)
        } catch {
            return .failed(reason: error.localizedDescription, exitCode: nil)
        }
    }

    /// Headless-deploy counterpart to `DeployModel.runDeploy`'s worker-composition wiring
    /// (#709 design §5/§8): computes the effective active worker set — settings-activated only,
    /// since this path (App Intents/Shortcuts) has no populated `SiteContentGraph` to derive
    /// component-tied activation from — and routes through `SocialWorkerProvisionCommand.provision`
    /// the same way the main Deploy button does, persisting the result on success.
    ///
    /// `onProgress` fidelity note: `SocialWorkerProvisionCommand.provision` has no milestone hook
    /// of its own (unlike `DeployCommand.deploy`, it's never been wired for one — it had no live
    /// caller before #709), so this emits the same coarse `OperationProgress.deployBuilding` /
    /// `.deployDeploying` milestones `DeployCommand.deploy` would have emitted around the
    /// build/deploy boundary, rather than `DeployCommand`'s finer per-step ones (preflight,
    /// finalizing). `SiteIntents.swift:59` is this path's one real consumer (Siri/Shortcuts
    /// progress) — dropping progress reporting to nothing would regress it; this keeps it coarser
    /// but non-silent without adding an `onProgress` parameter to `SocialWorkerProvisionCommand`
    /// itself, which would ripple into Tasks 3/4's signature and every other call site.
    private func deployWithWorkerComposition(
        site: SiteStore.Site, siteDirectory: URL, onProgress: ProgressHandler?
    ) async -> DeployCommand.Result {
        let configStore = SiteConfigStore(configDirectory: site.configDirectory)
        let settings = (try? await configStore.load()) ?? SiteSettings()
        let effectiveActiveIDs = WorkerActivation.effectiveActiveIDs(settings: settings, catalog: [], graph: nil)
        let features = WorkerActivation.mapToFeatures(effectiveActiveIDs)

        onProgress?(.deployBuilding)
        onProgress?(.deployDeploying)
        let provisionResult = await factory.socialWorkerProvision().provision(
            siteID: site.id,
            siteDirectory: siteDirectory,
            siteName: SiteSlug.derive(from: site.name),
            features: features,
            knownResources: settings.provisionedWorkerResources ?? .init()
        )
        onProgress?(.deployFinalizing)

        if case .succeeded(_, let resources, _) = provisionResult {
            var updated = settings
            updated.lastDeployedWorkerIDs = Array(effectiveActiveIDs).sorted()
            updated.provisionedWorkerResources = resources
            try? await configStore.save(updated)
        }

        switch provisionResult {
        case .succeeded(let url, _, let duration):
            return .succeeded(url: url, duration: duration)
        case .blocked(let failures, let warnings, _):
            return .blocked(failures: failures, warnings: warnings)
        case .workerNameConflict(let name, _):
            return .workerNameConflict(name: name)
        case .failed(let reason, let exitCode, _):
            return .failed(reason: reason, exitCode: exitCode)
        }
    }
```

Add one test proving the fidelity note holds:

```swift
    @Test("headless deploy still reports coarse progress milestones through onProgress")
    func headlessDeployReportsProgress() async throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let site = makeSite(name: "Blue Bottle Cafe", packageURL: package)
        let ops = SiteOperations(factory: SocialWorkerFactory(recorder: SocialWorkerRecorder()), store: throwawayStore())
        let seen = ProgressRecorder()

        _ = await ops.deploy(site: site, onProgress: { progress in Task { await seen.record(progress) } })
        // onProgress fires synchronously inside deployWithWorkerComposition, but the recorder hop
        // above is async — give it a beat to land before asserting.
        while await seen.progresses.count < 2 { await Task.yield() }

        let progresses = await seen.progresses
        #expect(progresses.contains(.deployBuilding))
        #expect(progresses.contains(.deployDeploying))
    }
```

Add the small recorder actor alongside the file's other private test helpers (`SocialWorkerRecorder`, etc.):

```swift
private actor ProgressRecorder {
    private(set) var progresses: [OperationProgress] = []
    func record(_ progress: OperationProgress) { progresses.append(progress) }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --package-path . --filter SiteOperationsTests`
Expected: PASS (all tests, including the two new ones and every pre-existing `deploy(site:)`-adjacent test)

- [ ] **Step 5: Full package test run**

Run: `swift test --package-path .`
Expected: PASS — the complete `AnglesiteSiteModelTests`, `AnglesiteCoreTests`, `AnglesiteBridgeTests` (and `AnglesiteIntentsTests` on Swift 6.4+/Xcode 27) suites all green, confirming nothing else in the package broke.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/SiteOperations.swift Tests/AnglesiteCoreTests/SiteOperationsTests.swift
git commit -m "feat(workers): route headless deploy through effective-active-set composition (#709)"
```

---

## Final Verification

- [ ] Run `swift test --package-path .` — full suite green.
- [ ] Run `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` — app target builds.
- [ ] Re-read `docs/superpowers/specs/2026-07-17-persisted-worker-state-design.md` end to end and confirm every numbered section (§1-§10) has a corresponding task above.
- [ ] `gh issue edit 709 --repo Anglesite/Anglesite-app --remove-label "🛠️ In Progress"` once the PR is open (per `CONTRIBUTING.md`'s claiming convention).

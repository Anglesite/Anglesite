# WorkerComposition.Feature → WorkerDescriptor Migration Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `WorkerComposition.generateWranglerToml` and `SocialWorkerProvisionCommand.provision` from the closed, 7-case `WorkerComposition.Feature` enum to the catalog-driven `WorkerDescriptor` (landed in PR #712), deleting the `WorkerActivation.mapToFeatures` interim shim — the first of #708's two remaining sub-tasks (design doc `docs/superpowers/specs/2026-07-13-workers-local-debugging-design.md` §3).

**Architecture:** `Feature`'s `needsD1`/`needsKV`/`needsR2` switch statements become `WorkerDescriptor.resources.needsD1/needsKV/needsR2` lookups; the one `Feature.indieauth`-specific branch (the `AUTH_DB` binding + IndieAuth secrets comment) becomes an `id == "indieauth"` string check, matching how `WorkerDescriptor`'s own doc comments already describe IndieAuth's binding name as "part of its public composition contract." `WorkerActivation.mapToFeatures(Set<String>) -> [Feature]` is replaced by `WorkerActivation.activeDescriptors(catalog:activeIDs:) -> [WorkerDescriptor]`, mirroring the existing `WorkerRouteClaims.activeClaims(catalog:activeIDs:)` pattern one file over. This also fixes a real (accepted, documented) limitation of the old shim: a catalog worker with no matching `Feature` case used to be silently dropped from composition entirely; post-migration, any catalog-known id composes correctly regardless of whether it existed when `Feature` was written.

**Tech Stack:** Swift 6.4, Swift Testing (`@Suite`/`@Test`/`#expect`), SwiftPM (`AnglesiteCore` + `AnglesiteCoreTests` targets), Xcode/`xcodebuild` for the `AnglesiteApp` target.

## Global Constraints

- No new dependencies — this is an internal refactor of existing `AnglesiteCore`/`AnglesiteApp` types.
- Conventional commits (`refactor(workers): …`), reference `#708` in the subject.
- Every `AnglesiteCoreTests` suite touched must pass via `swift test --package-path .` before moving to the next task.
- `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` must succeed before this plan is considered done (per CONTRIBUTING.md, `swift test` alone doesn't prove the app target links).
- Do not touch `SocialPublishPlan.swift`, `WorkersConformance.swift`, or `WorkerRouteClaims.swift` — confirmed zero coupling to `WorkerComposition.Feature` during research; touching them is out of scope.
- This plan covers only the descriptor migration. The second #708 sub-task (`wrangler dev --local` inside `LocalContainerSiteRuntime`) is a separate, independent plan — do not start it from this one.

---

## File Structure

| File | Change |
|---|---|
| `Sources/AnglesiteCore/WorkerComposition.swift` | Delete `Feature` enum; `generateWranglerToml(features:)` → `generateWranglerToml(workers:)` |
| `Sources/AnglesiteCore/WorkerActivation.swift` | Delete `mapToFeatures`; add `activeDescriptors(catalog:activeIDs:)` |
| `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift` | `provision(features:)` → `provision(workers:)`; `persistConfig(features:)` → `persistConfig(workers:)` |
| `Sources/AnglesiteCore/SiteScaffolder.swift` | One call-site param rename (empty array, trivial) |
| `Sources/AnglesiteCore/SiteOperations.swift` | Replace `mapToFeatures` call with `activeDescriptors`; broaden the existing "no cached catalog" log line to cover resource composition, not just route claims |
| `Sources/AnglesiteApp/DeployModel.swift` | Replace `mapToFeatures` call with `activeDescriptors` |
| `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift` | Migrate every fixture from `Feature` cases to `WorkerDescriptor` fixtures; delete the now-pointless `featureSets()` test |
| `Tests/AnglesiteCoreTests/WorkerActivationTests.swift` | Delete `mapToFeatures*` tests; add `activeDescriptors*` tests |
| `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift` | Migrate fixtures; add explicit `workers:` to tests that relied on the old `.v2` default |

---

## Task 1: AnglesiteCore — migrate types, composition, provisioning, call sites, and tests

**Files:**
- Modify: `Sources/AnglesiteCore/WorkerComposition.swift`
- Modify: `Sources/AnglesiteCore/WorkerActivation.swift`
- Modify: `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift`
- Modify: `Sources/AnglesiteCore/SiteScaffolder.swift:186`
- Modify: `Sources/AnglesiteCore/SiteOperations.swift:75-118`
- Test: `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift`
- Test: `Tests/AnglesiteCoreTests/WorkerActivationTests.swift`
- Test: `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`

**Interfaces:**
- Consumes: `WorkerDescriptor` (id, displayName, description, group, binding, resources: `{needsD1, needsKV, needsR2}`) from `Sources/AnglesiteCore/WorkerCatalog.swift` (already landed, unchanged).
- Produces: `WorkerComposition.generateWranglerToml(siteName:workers:routeClaims:resources:inboxCaptureEnabled:inboxKVNamespaceID:) throws -> String`; `SocialWorkerProvisionCommand.provision(siteID:siteDirectory:siteName:workers:routeClaims:knownResources:) async -> Result`; `WorkerActivation.activeDescriptors(catalog:activeIDs:) -> [WorkerDescriptor]` — Task 2 (`DeployModel.swift`) consumes all three by name.

- [ ] **Step 1: Update `WorkerCompositionTests.swift` to the target `workers:` API (this will not compile yet — that's expected, it defines the contract Step 2 implements)**

Replace the entire file with:

```swift
// Tests/AnglesiteCoreTests/WorkerCompositionTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

private func worker(_ id: String, d1: Bool, kv: Bool, r2: Bool) -> WorkerDescriptor {
    WorkerDescriptor(
        id: id, displayName: id, description: "test fixture", group: "test",
        binding: .settingsActivated, resources: .init(needsD1: d1, needsKV: kv, needsR2: r2)
    )
}

private let webmentionWorker = worker("webmention", d1: true, kv: true, r2: false)
private let indieauthWorker = worker("indieauth", d1: true, kv: true, r2: false)
private let micropubWorker = worker("micropub", d1: true, kv: true, r2: true)
private let websubWorker = worker("websub", d1: true, kv: true, r2: false)
private let v2Workers = [webmentionWorker, indieauthWorker]
private let v3Workers = [webmentionWorker, indieauthWorker, micropubWorker, websubWorker]

@Suite("WorkerComposition")
struct WorkerCompositionTests {
    @Test("generates wrangler.toml with static assets and no social features")
    func staticOnly() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            workers: []
        )
        #expect(toml.contains("name = \"my-site\""))
        #expect(toml.contains("[assets]"))
        #expect(toml.contains("directory = \"dist\""))
        #expect(!toml.contains("[[d1_databases]]"))
    }

    @Test("generates wrangler.toml with webmention + indieauth (D1 + KV yes, R2 no)")
    func withSocialFeatures() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            workers: [webmentionWorker, indieauthWorker]
        )
        #expect(toml.contains("name = \"my-site\""))
        #expect(toml.contains("[assets]"))
        #expect(toml.contains("[[d1_databases]]"))
        #expect(toml.contains("binding = \"DB\""))
        #expect(toml.contains("binding = \"AUTH_DB\""))
        #expect(toml.contains("migrations_dir = \"worker/migrations\""))
        #expect(toml.contains("[[kv_namespaces]]"))
        #expect(toml.contains("binding = \"SOCIAL_KV\""))
        #expect(toml.contains("binding = \"ASSETS\""))
        // No route claims → no run_worker_first at all (#746): unclaimed paths stay asset-first,
        // and the worker still receives its endpoints via Cloudflare's asset-miss fallback.
        #expect(!toml.contains("run_worker_first"))
        #expect(toml.contains("# Secrets required for IndieAuth (set with `wrangler secret put <NAME>`):"))
        #expect(toml.contains("# TOKEN_SIGNING_KEY, INDIEAUTH_OWNER_PASSWORD"))
        #expect(!toml.contains("[secrets]"))
        #expect(toml.contains("[observability]"))
        #expect(!toml.contains("[[r2_buckets]]"))
    }

    @Test("generates wrangler.toml with V-2 workers (D1 yes, R2 no — micropub is V-3)")
    func v2Features() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            workers: v2Workers
        )
        #expect(toml.contains("[[d1_databases]]"))
        #expect(toml.contains("[[kv_namespaces]]"))
        #expect(!toml.contains("[[r2_buckets]]"))
    }

    @Test("generates wrangler.toml with V-3 workers (D1 + R2 — micropub needs media)")
    func v3Features() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            workers: v3Workers
        )
        #expect(toml.contains("[[d1_databases]]"))
        #expect(toml.contains("[[kv_namespaces]]"))
        #expect(toml.contains("[[r2_buckets]]"))
        #expect(toml.contains("binding = \"MEDIA\""))
    }

    @Test("writes provisioned Cloudflare resource ids into wrangler.toml")
    func provisionedResources() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            workers: v3Workers,
            resources: .init(d1DatabaseID: "d1-id", kvNamespaceID: "kv-id", r2BucketName: "custom-media")
        )

        #expect(toml.contains("database_id = \"d1-id\""))
        #expect(toml.contains("id = \"kv-id\""))
        #expect(toml.contains("bucket_name = \"custom-media\""))
    }

    @Test("rejects site names containing TOML-unsafe characters")
    func rejectsInvalidSiteName() {
        #expect(throws: WorkerComposition.ConfigError.self) {
            try WorkerComposition.generateWranglerToml(
                siteName: "my\"site\ninjected",
                workers: []
            )
        }
    }

    @Test("inboxCaptureEnabled adds an INBOX_KV binding and uncomments main even with no @dwk/* workers")
    func inboxCaptureAddsKVBinding() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site", workers: [], inboxCaptureEnabled: true)
        #expect(toml.contains("main = \"worker/worker.ts\""))
        #expect(toml.contains("binding = \"INBOX_KV\""))
        #expect(toml.contains("id = \"\"  # filled by provisioning"))
    }

    @Test("inboxCaptureEnabled fills the provisioned namespace id when given")
    func inboxCaptureFillsProvisionedID() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site", workers: [], inboxCaptureEnabled: true, inboxKVNamespaceID: "abc123")
        #expect(toml.contains("id = \"abc123\""))
    }

    @Test("inboxCaptureEnabled false omits the INBOX_KV binding")
    func inboxCaptureDisabledOmitsBinding() throws {
        let toml = try WorkerComposition.generateWranglerToml(siteName: "my-site", workers: [])
        #expect(!toml.contains("INBOX_KV"))
        #expect(!toml.contains("main ="))
    }

    @Test("route claims emit deterministic, sorted, deduplicated run_worker_first entries")
    func selectiveRunWorkerFirst() throws {
        let claims = [
            WorkerRouteClaim(path: "/token", match: .exact, methods: ["POST"], handler: "indieauth"),
            WorkerRouteClaim(path: "/authorize", match: .exact, methods: ["GET", "POST"], handler: "indieauth"),
            WorkerRouteClaim(path: "/authorize", match: .exact, methods: ["GET", "POST"], handler: "indieauth"),
            WorkerRouteClaim(
                path: "/.well-known/acme-challenge", match: .prefix, methods: ["GET"], handler: "acme",
                specificationURL: URL(string: "https://www.rfc-editor.org/rfc/rfc8555")),
        ]
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site", workers: [indieauthWorker], routeClaims: claims)
        #expect(toml.contains(
            #"run_worker_first = ["/.well-known/acme-challenge", "/.well-known/acme-challenge/*", "/authorize", "/token"]"#
        ))
        // Regeneration is byte-stable regardless of claim order.
        let regenerated = try WorkerComposition.generateWranglerToml(
            siteName: "my-site", workers: [indieauthWorker], routeClaims: claims.reversed())
        #expect(toml == regenerated)
    }

    @Test("run_worker_first is omitted entirely when there are no active dynamic routes")
    func omitsRunWorkerFirstWithoutClaims() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site", workers: [webmentionWorker, indieauthWorker])
        #expect(!toml.contains("run_worker_first"))
        #expect(toml.contains("binding = \"ASSETS\""))
    }

    @Test("inbox capture claims /inbox as a worker-first route")
    func inboxCaptureClaimsRoute() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site", workers: [], inboxCaptureEnabled: true)
        #expect(toml.contains(#"run_worker_first = ["/inbox"]"#))
    }

    @Test("static-only sites emit no run_worker_first")
    func staticOnlyOmitsRunWorkerFirst() throws {
        let toml = try WorkerComposition.generateWranglerToml(siteName: "my-site", workers: [])
        #expect(!toml.contains("run_worker_first"))
    }

    @Test("an unvalidated route claim path is refused, not interpolated into TOML")
    func rejectsInvalidRouteClaim() {
        let hostile = WorkerRouteClaim(
            path: "/a\"]\ninjected = true", match: .exact, methods: ["GET"], handler: "x")
        #expect(throws: WorkerComposition.ConfigError.self) {
            try WorkerComposition.generateWranglerToml(
                siteName: "my-site", workers: [indieauthWorker], routeClaims: [hostile])
        }
    }

    @Test("composition runs full claim validation, not just path syntax")
    func rejectsSemanticallyInvalidRouteClaim() {
        // Valid path, invalid methods (HEAD without paired GET) — only full validation catches it.
        let headOnly = WorkerRouteClaim(
            path: "/status", match: .exact, methods: ["HEAD"], handler: "x")
        #expect(throws: WorkerComposition.ConfigError.self) {
            try WorkerComposition.generateWranglerToml(
                siteName: "my-site", workers: [indieauthWorker], routeClaims: [headOnly])
        }
    }

    @Test("ProvisionedResources round-trips through JSONEncoder/JSONDecoder")
    func provisionedResourcesCodable() throws {
        let resources = WorkerComposition.ProvisionedResources(
            d1DatabaseID: "d1-id", kvNamespaceID: "kv-id", r2BucketName: "media-bucket"
        )
        let data = try JSONEncoder().encode(resources)
        let decoded = try JSONDecoder().decode(WorkerComposition.ProvisionedResources.self, from: data)
        #expect(decoded == resources)
    }
}
```

Note: the old `featureSets()` test (asserting `Feature.v2.contains(.webmention)` etc.) is deleted — it tested `Feature`'s own static data, which no longer exists. Phase-list correctness (which npm packages belong to V-2/V-3/V-4) is still covered by `WorkersConformanceTests.swift`'s `v2Gate`/`v3Gate` tests against `WorkersConformanceStatus.phaseRequirements`, which was always npm-package-name-keyed and untouched by this migration.

- [ ] **Step 2: Run the test target to confirm it fails to compile (expected — `WorkerComposition.generateWranglerToml` doesn't have a `workers:` parameter yet)**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: **build error** — `extra argument 'workers' in call` / `incorrect argument label in call (have 'workers:', expected 'features:')`.

- [ ] **Step 3: Migrate `WorkerComposition.swift` — delete `Feature`, retarget `generateWranglerToml` to `[WorkerDescriptor]`**

Delete lines 11-54 (the entire `public enum Feature: String, CaseIterable, Sendable { ... }` block, including its three computed properties and the `v2`/`v3`/`v4` static arrays).

Replace the `generateWranglerToml` function (originally lines 106-229) with:

```swift
    /// Generates a wrangler.toml for a site with the given workers enabled.
    ///
    /// - Parameters:
    ///   - siteName: The Worker name (used as the Cloudflare Workers project name).
    ///     Must match `[A-Za-z0-9_-]+`.
    ///   - workers: The effective active `@dwk/workers` catalog descriptors. Empty = static-only
    ///     deploy.
    ///   - routeClaims: The effective active dynamic-route claims (#746), already validated by
    ///     `WorkerRouteClaims.activeClaims`. Emitted as selective `[assets].run_worker_first`
    ///     patterns so *only* claimed routes bypass asset-first serving — a static asset can no
    ///     longer shadow an active dynamic route, while every unclaimed path keeps Cloudflare's
    ///     asset-first fallback. Omitted entirely when there are no active dynamic routes.
    /// - Returns: A complete wrangler.toml string.
    /// - Throws: ``ConfigError/invalidSiteName(_:)`` if `siteName` contains
    ///   characters outside `[A-Za-z0-9_-]`, or ``ConfigError/invalidRouteClaim(path:reason:)``
    ///   for a claim that never passed `WorkerRouteClaims` validation.
    public static func generateWranglerToml(
        siteName: String,
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim] = [],
        resources: ProvisionedResources = .init(),
        inboxCaptureEnabled: Bool = false,
        inboxKVNamespaceID: String? = nil
    ) throws -> String {
        guard isValidSiteName(siteName) else {
            throw ConfigError.invalidSiteName(siteName)
        }
        var effectiveClaims = routeClaims
        if inboxCaptureEnabled {
            effectiveClaims.append(inboxCaptureRouteClaim)
        }
        // Full single-claim validation (not just path syntax), so a future caller that skips
        // `WorkerRouteClaims.activeClaims` still can't emit an invalid claim into TOML. Cross-
        // claim overlap detection remains `activeClaims`'s job — it needs owner attribution
        // this signature doesn't carry.
        for claim in effectiveClaims {
            do {
                try WorkerRouteClaims.validate(claim, owner: "composition")
            } catch {
                throw ConfigError.invalidRouteClaim(path: claim.path, reason: "\(error)")
            }
        }
        // @dwk/indieauth's binding name is part of its public composition contract (see the
        // AUTH_DB block below) — the one place composition keys off a specific catalog id rather
        // than generic resource flags.
        let hasIndieauth = workers.contains(where: { $0.id == "indieauth" })

        var lines: [String] = []
        lines.append("name = \"\(siteName)\"")
        lines.append("compatibility_date = \"2026-07-15\"")
        lines.append("compatibility_flags = [\"nodejs_compat\"]")

        let hasSocialFeatures = !workers.isEmpty
        if hasSocialFeatures || inboxCaptureEnabled {
            lines.append("main = \"worker/worker.ts\"")
        }
        lines.append("")
        lines.append("[assets]")
        lines.append("directory = \"dist\"")
        if hasSocialFeatures || inboxCaptureEnabled {
            lines.append("binding = \"ASSETS\"")
            let patterns = WorkerRouteClaims.runWorkerFirstPatterns(effectiveClaims)
            if !patterns.isEmpty {
                let list = patterns.map { "\"\($0)\"" }.joined(separator: ", ")
                lines.append("run_worker_first = [\(list)]")
            }
        }

        if workers.contains(where: { $0.resources.needsD1 }) {
            lines.append("")
            lines.append("[[d1_databases]]")
            lines.append("binding = \"DB\"")
            lines.append("database_name = \"\(siteName)-social\"")
            if let id = resources.d1DatabaseID, !id.isEmpty {
                lines.append("database_id = \"\(id)\"")
            } else {
                lines.append("database_id = \"\"  # filled by provisioning")
            }
        }

        // Keep the generic DB binding above for the other @dwk packages, while binding the same
        // per-site D1 database under AUTH_DB for authorization codes and issued-token state.
        if hasIndieauth {
            lines.append("")
            lines.append("[[d1_databases]]")
            lines.append("binding = \"AUTH_DB\"")
            lines.append("database_name = \"\(siteName)-social\"")
            lines.append("migrations_dir = \"worker/migrations\"")
            if let id = resources.d1DatabaseID, !id.isEmpty {
                lines.append("database_id = \"\(id)\"")
            } else {
                lines.append("database_id = \"\"  # filled by provisioning")
            }
        }

        if workers.contains(where: { $0.resources.needsKV }) {
            lines.append("")
            lines.append("[[kv_namespaces]]")
            lines.append("binding = \"SOCIAL_KV\"")
            if let id = resources.kvNamespaceID, !id.isEmpty {
                lines.append("id = \"\(id)\"")
            } else {
                lines.append("id = \"\"  # filled by provisioning")
            }
        }

        if workers.contains(where: { $0.resources.needsR2 }) {
            lines.append("")
            lines.append("[[r2_buckets]]")
            lines.append("binding = \"MEDIA\"")
            lines.append("bucket_name = \"\(resources.r2BucketName ?? "\(siteName)-media")\"")
        }

        if inboxCaptureEnabled {
            lines.append("")
            lines.append("[[kv_namespaces]]")
            lines.append("binding = \"INBOX_KV\"")
            if let id = inboxKVNamespaceID, !id.isEmpty {
                lines.append("id = \"\(id)\"")
            } else {
                lines.append("id = \"\"  # filled by provisioning")
            }
        }

        if hasIndieauth {
            lines.append("")
            // Wrangler has no schema for declaring required secrets in wrangler.toml — secrets are
            // set with `wrangler secret put <NAME>` and are never read back out of this file. Emit
            // this as a comment (not a `[secrets]` table) so it can't be mistaken for a config key
            // wrangler validates or fail on.
            lines.append("# Secrets required for IndieAuth (set with `wrangler secret put <NAME>`):")
            lines.append("# TOKEN_SIGNING_KEY, INDIEAUTH_OWNER_PASSWORD")
        }

        if hasSocialFeatures || inboxCaptureEnabled {
            lines.append("")
            lines.append("[observability]")
            lines.append("enabled = true")
            lines.append("head_sampling_rate = 1")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }
```

- [ ] **Step 4: Run the test target to confirm `WorkerCompositionTests` now passes**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: PASS (16 tests, `featureSets` no longer present).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WorkerComposition.swift Tests/AnglesiteCoreTests/WorkerCompositionTests.swift
git commit -m "refactor(workers): migrate generateWranglerToml from Feature enum to WorkerDescriptor (#708)"
```

- [ ] **Step 6: Update `WorkerActivationTests.swift` to the target `activeDescriptors` API (will not compile yet)**

In `Tests/AnglesiteCoreTests/WorkerActivationTests.swift`, replace lines 105-120 (the three `mapToFeatures*` tests) with:

```swift
    @Test("activeDescriptors resolves known ids against the catalog")
    func activeDescriptorsKnownIDs() {
        let webmention = descriptor(id: "webmention", binding: .settingsActivated)
        let indieauth = descriptor(id: "indieauth", binding: .settingsActivated)
        let resolved = WorkerActivation.activeDescriptors(
            catalog: [webmention, indieauth], activeIDs: ["indieauth", "webmention"])
        #expect(Set(resolved.map(\.id)) == ["indieauth", "webmention"])
    }

    @Test("activeDescriptors drops ids with no matching catalog entry")
    func activeDescriptorsDropsUnknownIDs() {
        let indieauth = descriptor(id: "indieauth", binding: .settingsActivated)
        let resolved = WorkerActivation.activeDescriptors(
            catalog: [indieauth], activeIDs: ["indieauth", "solid-pod"])
        #expect(resolved.map(\.id) == ["indieauth"])
    }

    @Test("activeDescriptors of an empty id set is empty")
    func activeDescriptorsEmpty() {
        let indieauth = descriptor(id: "indieauth", binding: .settingsActivated)
        #expect(WorkerActivation.activeDescriptors(catalog: [indieauth], activeIDs: []).isEmpty)
    }
```

(This reuses the file's existing private `descriptor(id:group:binding:)` helper at lines 7-14 — no new helper needed.)

- [ ] **Step 7: Run the test target to confirm it fails to compile**

Run: `swift test --package-path . --filter WorkerActivationTests`
Expected: **build error** — `type 'WorkerActivation' has no member 'activeDescriptors'`.

- [ ] **Step 8: Migrate `WorkerActivation.swift` — delete `mapToFeatures`, add `activeDescriptors`**

In `Sources/AnglesiteCore/WorkerActivation.swift`, replace lines 57-65 (the `mapToFeatures` function and its doc comment) with:

```swift
    /// The effective active worker set as full `WorkerDescriptor`s, resolved by id against
    /// `catalog` — what `WorkerComposition.generateWranglerToml` and
    /// `SocialWorkerProvisionCommand.provision` need now that composition is descriptor-driven
    /// (#708). An id present in `activeIDs` but absent from `catalog` (a stale id, or a catalog
    /// fetch that hasn't happened yet) is silently dropped — there is no descriptor data to
    /// compose it with. Mirrors `WorkerRouteClaims.activeClaims(catalog:activeIDs:)`'s shape.
    public static func activeDescriptors(catalog: [WorkerDescriptor], activeIDs: Set<String>) -> [WorkerDescriptor] {
        catalog.filter { activeIDs.contains($0.id) }
    }
```

- [ ] **Step 9: Run the test target to confirm `WorkerActivationTests` now passes**

Run: `swift test --package-path . --filter WorkerActivationTests`
Expected: PASS (10 tests: 7 existing `effectiveActiveIDs`/`removedIDs` tests + 3 new `activeDescriptors` tests).

- [ ] **Step 10: Commit**

```bash
git add Sources/AnglesiteCore/WorkerActivation.swift Tests/AnglesiteCoreTests/WorkerActivationTests.swift
git commit -m "refactor(workers): replace WorkerActivation.mapToFeatures shim with activeDescriptors (#708)"
```

- [ ] **Step 11: Update `SocialWorkerProvisionCommandTests.swift` to the target `workers:` API (will not compile yet)**

In `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`, add these fixtures immediately after the `import` lines (before `@Suite("SocialWorkerProvisionCommand")`):

```swift
private func worker(_ id: String, d1: Bool, kv: Bool, r2: Bool) -> WorkerDescriptor {
    WorkerDescriptor(
        id: id, displayName: id, description: "test fixture", group: "test",
        binding: .settingsActivated, resources: .init(needsD1: d1, needsKV: kv, needsR2: r2)
    )
}

private let webmentionWorker = worker("webmention", d1: true, kv: true, r2: false)
private let indieauthWorker = worker("indieauth", d1: true, kv: true, r2: false)
private let micropubWorker = worker("micropub", d1: true, kv: true, r2: true)
private let websubWorker = worker("websub", d1: true, kv: true, r2: false)
private let v2Workers = [webmentionWorker, indieauthWorker]
private let v3Workers = [webmentionWorker, indieauthWorker, micropubWorker, websubWorker]
```

Then apply these exact edits (every other test in the file is unaffected and stays as-is):

1. `provisionsV2Worker` — the call `await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site")` becomes `await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: v2Workers)`. (The old default value was `WorkerComposition.Feature.v2`; the new default is `[]`, so this test — which asserts D1+KV get created — must pass workers explicitly now.)

2. `provisionsR2ForMicropub` — `features: WorkerComposition.Feature.v3` becomes `workers: v3Workers`.

3. `missingToken` — **unchanged**. It returns before `workers` is ever read, so the default value doesn't affect its assertions.

4. `reusesPersistedResources` — both occurrences of `features: WorkerComposition.Feature.v3` (the fixture-TOML `generateWranglerToml` call, and the `command.provision` call) become `workers: v3Workers`.

5. `partialFailureReportsResources` — the call `await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site")` becomes `await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: v2Workers)` (this test exercises the D1-succeeds/KV-fails path, which needs `needsD1`/`needsKV` true — the old `.v2` default provided that implicitly).

6. `deployFailureReportsResources` — same change as #5: add `workers: v2Workers` to the `command.provision` call.

7. `workerNameConflictPropagates` — same change as #5: add `workers: v2Workers`.

8. `migrationFailureStopsDeploy` — same change as #5: add `workers: v2Workers` (this test also needs the IndieAuth migration step to run, which requires an `indieauth`-id worker — `v2Workers` includes it).

9. `resourceIDExtraction`, `persistedResourceParsing` — **unchanged**. Neither calls `provision` or `generateWranglerToml`.

10. `reusesKnownResourcesOverFileScrape` — the fixture-TOML call `features: [.indieauth]` becomes `workers: [indieauthWorker]`; the `command.provision(..., features: [.indieauth, .micropub], knownResources: known)` call becomes `command.provision(..., workers: [indieauthWorker, micropubWorker], knownResources: known)`.

11. `asDeployCommandResultMapsSucceeded`, `asDeployCommandResultMapsBlocked`, `asDeployCommandResultMapsWorkerNameConflict`, `asDeployCommandResultMapsFailed` — **unchanged**. None call `provision` or `generateWranglerToml`.

- [ ] **Step 12: Run the test target to confirm it fails to compile**

Run: `swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: **build error** — `incorrect argument label in call (have 'features:', expected 'workers:')` at the still-unmigrated call sites, plus the same error surfacing from `WorkerComposition.generateWranglerToml`'s already-migrated signature.

- [ ] **Step 13: Migrate `SocialWorkerProvisionCommand.swift`**

In `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift`:

Change the `provision` signature (originally lines 50-65) — replace:

```swift
        features: [WorkerComposition.Feature] = WorkerComposition.Feature.v2,
```

with:

```swift
        workers: [WorkerDescriptor] = [],
```

Replace every `features` reference in the `provision` body (originally lines 91, 112, 118, 139, 145, 159, 165, 172, 228, 238) as follows:

- `if features.contains(where: { $0.needsD1 }) {` → `if workers.contains(where: { $0.resources.needsD1 }) {`
- `if features.contains(where: { $0.needsKV }) {` → `if workers.contains(where: { $0.resources.needsKV }) {`
- `if features.contains(where: { $0.needsR2 }) {` → `if workers.contains(where: { $0.resources.needsR2 }) {`
- every `persistConfig(siteDirectory: siteDirectory, siteName: siteName, features: features, routeClaims: routeClaims, resources: resources)` call (there are 4: after the D1 block, after the KV block, after the R2 block, and the unconditional one before the IndieAuth migration step) → `persistConfig(siteDirectory: siteDirectory, siteName: siteName, workers: workers, routeClaims: routeClaims, resources: resources)`
- `if features.contains(.indieauth) {` (guarding the `d1 migrations apply AUTH_DB` step) → `if workers.contains(where: { $0.id == "indieauth" }) {`

Change `persistConfig`'s signature (originally lines 225-231) — replace:

```swift
    private func persistConfig(
        siteDirectory: URL,
        siteName: String,
        features: [WorkerComposition.Feature],
        routeClaims: [WorkerRouteClaim],
        resources: WorkerComposition.ProvisionedResources
    ) -> Result? {
```

with:

```swift
    private func persistConfig(
        siteDirectory: URL,
        siteName: String,
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim],
        resources: WorkerComposition.ProvisionedResources
    ) -> Result? {
```

And inside `persistConfig`'s body, the `WorkerComposition.generateWranglerToml(siteName: siteName, features: features, routeClaims: routeClaims, resources: resources)` call becomes `WorkerComposition.generateWranglerToml(siteName: siteName, workers: workers, routeClaims: routeClaims, resources: resources)`.

- [ ] **Step 14: Migrate `SiteScaffolder.swift:186`**

In `Sources/AnglesiteCore/SiteScaffolder.swift`, change:

```swift
        let toml = try WorkerComposition.generateWranglerToml(siteName: siteName, features: [])
```

to:

```swift
        let toml = try WorkerComposition.generateWranglerToml(siteName: siteName, workers: [])
```

- [ ] **Step 15: Migrate `SiteOperations.swift`**

In `Sources/AnglesiteCore/SiteOperations.swift`, in `deployWithWorkerComposition`, replace lines 75-92:

```swift
        let effectiveActiveIDs = WorkerActivation.effectiveActiveIDs(settings: settings, catalog: [], graph: nil)
        let features = WorkerActivation.mapToFeatures(effectiveActiveIDs)

        // Dynamic-route claims (#746): this path has no catalog fetcher wired (matching the
        // `catalog: []` activation choice above), but the on-disk cache from a previous GUI fetch
        // still lets active workers keep their `run_worker_first` routes — otherwise a headless
        // deploy would silently regenerate wrangler.toml without them. Validation failures refuse
        // the deploy before any Cloudflare call, mirroring `DeployModel.runDeploy`.
        let cachedCatalog = WorkerCatalogFetcher.cachedCatalog()
        if cachedCatalog.isEmpty && !effectiveActiveIDs.isEmpty {
            // The shadowing-protection gap this leaves (an active worker's routes deploy without
            // their run_worker_first entries) must be visible in the debug pane, not silent.
            await LogCenter.shared.append(
                source: "deploy:\(site.id)",
                stream: .stderr,
                text: "no cached worker catalog — deploying active workers (\(effectiveActiveIDs.sorted().joined(separator: ", "))) without route claims; run_worker_first will be omitted until a catalog fetch succeeds"
            )
        }
```

with:

```swift
        let effectiveActiveIDs = WorkerActivation.effectiveActiveIDs(settings: settings, catalog: [], graph: nil)

        // Dynamic-route claims (#746) and resource composition (#708) both need real descriptor
        // data, which the `catalog: []` activation call above deliberately doesn't have (matching
        // the effectiveActiveIDs "settings-activated only" comment above). The on-disk cache from
        // a previous GUI fetch is the only source of that data on this headless path.
        let cachedCatalog = WorkerCatalogFetcher.cachedCatalog()
        let workers = WorkerActivation.activeDescriptors(catalog: cachedCatalog, activeIDs: effectiveActiveIDs)
        if cachedCatalog.isEmpty && !effectiveActiveIDs.isEmpty {
            // The gap this leaves (an active worker deploys with no D1/KV/R2 bindings and no
            // run_worker_first entries — there's no catalog data to resolve its active id against)
            // must be visible in the debug pane, not silent.
            await LogCenter.shared.append(
                source: "deploy:\(site.id)",
                stream: .stderr,
                text: "no cached worker catalog — deploying active workers (\(effectiveActiveIDs.sorted().joined(separator: ", "))) with no resource bindings or route claims; wrangler.toml will be static-only until a catalog fetch succeeds"
            )
        }
```

Then in the same function, change the `provision` call (originally lines 111-118):

```swift
        let provisionResult = await factory.socialWorkerProvision().provision(
            siteID: site.id,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            features: features,
            routeClaims: routeClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init()
        )
```

to:

```swift
        let provisionResult = await factory.socialWorkerProvision().provision(
            siteID: site.id,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            workers: workers,
            routeClaims: routeClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init()
        )
```

- [ ] **Step 16: Run the full `AnglesiteCore` test target**

Run: `swift test --package-path .`
Expected: PASS — all `AnglesiteCoreTests`, `AnglesiteSiteModelTests`, `AnglesiteBridgeTests`, and (on Swift 6.4+/Xcode 27) `AnglesiteIntentsTests` suites green, no build errors.

- [ ] **Step 17: Commit**

```bash
git add Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift Sources/AnglesiteCore/SiteScaffolder.swift Sources/AnglesiteCore/SiteOperations.swift Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift
git commit -m "refactor(workers): migrate SocialWorkerProvisionCommand and its callers to WorkerDescriptor (#708)"
```

---

## Task 2: AnglesiteApp — migrate `DeployModel.swift`

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift:450,506`

**Interfaces:**
- Consumes: `WorkerActivation.activeDescriptors(catalog:activeIDs:) -> [WorkerDescriptor]` and `SocialWorkerProvisionCommand.provision(workers:)` from Task 1.
- Produces: nothing new — this is the last caller of the old `mapToFeatures`/`features:` shape.

- [ ] **Step 1: Migrate the two call sites**

In `Sources/AnglesiteApp/DeployModel.swift`, in `runDeploy`, change line 450:

```swift
        let features = WorkerActivation.mapToFeatures(effectiveActiveIDs)
```

to:

```swift
        let workers = WorkerActivation.activeDescriptors(catalog: catalog, activeIDs: effectiveActiveIDs)
```

(`catalog` here is the `[WorkerDescriptor]` fetched two lines earlier at `let catalog = await workerCatalog()` — the same catalog already used for `effectiveActiveIDs` and `routeClaims`, so this needs no new fetch.)

Then change the `provision` call (originally lines 502-509):

```swift
        let provisionResult = await socialCommand.provision(
            siteID: siteID,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            features: features,
            routeClaims: routeClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init()
        )
```

to:

```swift
        let provisionResult = await socialCommand.provision(
            siteID: siteID,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            workers: workers,
            routeClaims: routeClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init()
        )
```

- [ ] **Step 2: Build the app target**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`. If `Anglesite.xcodeproj` doesn't exist yet in this worktree, run `xcodegen generate` first (per this repo's worktree setup — the project file is gitignored).

- [ ] **Step 3: Confirm no remaining references to the deleted API**

Run: `grep -rn "WorkerComposition.Feature\|WorkerActivation.mapToFeatures" Sources/ Tests/`
Expected: no output (empty). If anything matches, it's a missed call site — go back and migrate it before continuing.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/DeployModel.swift
git commit -m "refactor(workers): migrate DeployModel to WorkerDescriptor-based composition (#708)"
```

---

## Task 3: Full verification and PR

- [ ] **Step 1: Run the complete test suite one more time from a clean state**

Run: `swift test --package-path .`
Expected: PASS, zero failures.

- [ ] **Step 2: Run the full app build one more time**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Review the diff for stray debug output or leftover TODOs**

Run: `git diff main --stat` and `git log main.. --oneline` to review the commit sequence, then `git diff main -- Sources/ Tests/` to eyeball the full diff.
Expected: only the files listed in Tasks 1-2's File Structure table are touched; no `.xcodeproj` changes (it's gitignored); no stray `print`/`FIXME` left behind.

- [ ] **Step 4: Open the PR**

```bash
git push -u origin HEAD
gh pr create --title "refactor(workers): migrate WorkerComposition to WorkerDescriptor (#708)" --body "$(cat <<'EOF'
## Summary
- Migrates `WorkerComposition.generateWranglerToml` and `SocialWorkerProvisionCommand.provision` from the closed `WorkerComposition.Feature` enum to catalog-driven `WorkerDescriptor`, per #708's remaining prerequisites (design doc §3).
- Deletes the `WorkerActivation.mapToFeatures` interim shim (#709 design §4/§10), replacing it with `activeDescriptors(catalog:activeIDs:)`, mirroring the existing `WorkerRouteClaims.activeClaims` pattern.
- Fixes a documented limitation of the old shim: a catalog worker with no matching `Feature` case used to be silently dropped from composition; any catalog-known id now composes correctly.
- First of #708's two remaining sub-tasks. The `wrangler dev --local` local-runtime sub-task is a separate follow-up PR.

## Test plan
- [x] `swift test --package-path .` — all AnglesiteCore suites pass
- [x] `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` — app target builds
- [ ] No paired sidecar PR needed — this is app-internal composition logic, not an MCP schema change
EOF
)"
```

- [ ] **Step 5: Remove the in-progress claim on #708**

Do NOT close #708 — the local-runtime sub-task is still open. Leave the `🛠️ In Progress` label in place until that follow-up PR opens too, or remove it now and re-add when starting the follow-up (either is fine; the PR itself is the up-to-date signal per CONTRIBUTING.md once it exists).

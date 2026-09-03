# Webmention Receive (#359) — Provisioning, Discovery, Conformance Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the Swift/template side of #359 (Webmention receive) that PR #887 deliberately deferred: Cloudflare Queue + D1-inbox-binding + `SITE_URL` provisioning (with an explicit paid-plan opt-in), a provisioning-gated `<link rel="webmention">` discovery tag, and an advisory (non-blocking) surface for `WorkersConformanceStatus.gateStatus(.v3)`.

**Architecture:** `@dwk/webmention`'s receiver is already composed into `worker/worker.ts` (PR #887) behind three optional bindings — `WEBMENTION_QUEUE`, `WEBMENTION_INBOX` (D1), `SITE_URL`. This plan makes `WorkerComposition.generateWranglerToml` emit those three bindings (special-cased on the catalog id `"webmention"`, exactly mirroring how `indieauthWorkerID`/`AUTH_DB` is special-cased today — *not* a new generic `WorkerDescriptor.Resources` flag, since that would require a paired schema change in the external `davidwkeith/workers` catalog repo per `CONTRIBUTING.md`'s catalog-coordination rule), makes `SocialWorkerProvisionCommand` create the Cloudflare Queue (gated on an explicit per-site opt-in acknowledgment, since Queues require the Workers **Paid** plan), and wires that opt-in into `DeployModel`'s existing park-and-retry sheet pattern (the same mechanism `workerNameConflict` already uses — no new UI infrastructure invented). Discovery reuses the already-established `.site-config` + `readConfig()` gating mechanism (`SiteConfigFile.upsert`/`WebsiteAnalyticsAsset`). Conformance wiring is a new `WorkersConformanceFetcher` (mirrors `WorkerCatalogFetcher` exactly) plus an advisory debug-pane log line — **not** a hard activation gate, because the real `conformance/status.json` (verified live against `davidwkeith/workers` during planning) currently reports `@dwk/webmention`/`@dwk/micropub`/`@dwk/websub` all `"pending"`, so a hard gate would immediately break the receiver PR #887 already shipped.

**Tech Stack:** Swift 6.4 (SwiftPM `AnglesiteCore`/`AnglesiteApp` targets, Swift Testing), Astro/TypeScript template (`Resources/Template/`), Cloudflare `wrangler.toml`.

## Global Constraints

- Swift package tests: `swift test --package-path .` from the repo root. Fresh worktree: run `xcodegen generate` before any `xcodebuild` (not needed for `swift test`).
- Follow `CONTRIBUTING.md`: conventional commits, subject ≤72 chars, PR body uses `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary / Paired PR check / Test plan).
- **Do not** add a new field to `WorkerDescriptor.Resources` (`needsD1`/`needsKV`/`needsR2`) — that schema is owned by the external `davidwkeith/workers` catalog repo. Special-case on `WorkerComposition.webmentionWorkerID` instead, exactly like `indieauthWorkerID`/`AUTH_DB`.
- **Do not** gate worker activation/deploy on `WorkersConformanceStatus.gateStatus(.v3)`. It's advisory only (see Task 11) — the real status.json shows V-3 packages `"pending"` today, and #887's receiver is meant to be usable now.
- Area 2 (D1→git canonicality snapshot, `ReceivedInteraction`) is explicitly **out of scope** for this plan — deferred to #362 (see Task 12, which only leaves a documentation trail).
- The webmention.rocks *receiver*-side conformance suite cannot be automated in this repo (it requires an interactive session-token flow against a publicly deployed receiver, exactly like the existing sender-side `WebmentionRocksLiveTests.swift` already documents for POST-acceptance) — do not attempt to write a live receiver test. Task 11 documents this instead.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/AnglesiteCore/WorkerComposition.swift` | Emit `WEBMENTION_INBOX` D1 binding, `[[queues.*]]` blocks, `SITE_URL` var, `webmentionWorkerID` constant, `queueName` provisioned-resource field |
| `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift` | Fixture rename (id collision fix) + new TOML-emission tests |
| `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift` | Create the Cloudflare Queue; new `.webmentionPaidPlanConfirmationNeeded` result case; thread `siteURL`/`acknowledgesPaidPlan` through `provision`/`persistConfig` |
| `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift` | Queue-creation + paid-plan-gate tests |
| `Sources/AnglesiteCore/SiteConfigStore.swift` | New `SiteSettings.webmentionReceivePaidPlanAcknowledged` field |
| `Sources/AnglesiteCore/DeployCoordinator.swift` | New `resolveSiteURL(siteDirectory:)` helper (mirrors `resolveWorkerSiteName`) |
| `Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift` | Tests for `resolveSiteURL` |
| `Sources/AnglesiteApp/DeployModel.swift` | New `Phase.webmentionPaidPlanConfirmationNeeded`, `webmentionPaidPlanConfirmationPresented`, `acknowledgeWebmentionPaidPlanAndRetry()`, `cancelWebmentionPaidPlanConfirmation()`; wire `siteURL`/`acknowledgesPaidPlan` into the `provision` call |
| `Sources/AnglesiteApp/WebmentionPaidPlanConfirmationSheetView.swift` | New sheet view (mirrors `WorkerNameConflictSheetView`) |
| `Sources/AnglesiteApp/SiteWindow.swift` | Wire the new sheet |
| `Resources/Template/src/layouts/BaseLayout.astro` | Gated `<link rel="webmention" href="/webmention">` |
| `Resources/Template/src/layouts/BaseLayout.test.ts` (or nearest existing layout test) | Test the gated link — see Task 9 for exact existing test file to extend |
| `Sources/AnglesiteCore/WorkersConformanceFetcher.swift` | New — mirrors `WorkerCatalogFetcher`, fetches/caches `conformance/status.json` |
| `Tests/AnglesiteCoreTests/WorkersConformanceFetcherTests.swift` | New fetcher tests |
| `Sources/AnglesiteCore/WorkerActivation.swift` | New `conformanceAdvisory(...)` pure helper |
| `Tests/AnglesiteCoreTests/WorkerActivationTests.swift` | Advisory tests |

---

### Task 1: Fix the `"webmention"` id collision in `WorkerCompositionTests` fixtures

The existing test suite uses a fixture literally named `worker("webmention", d1: true, kv: true, r2: false)` purely to exercise the *generic* `needsD1`/`needsKV` composition path (see `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift:13-18`). Task 2 special-cases the real catalog id `"webmention"` the same way `indieauthWorkerID` is special-cased — so before adding that logic, rename this fixture so the two concerns don't collide and silently change already-passing tests' expected output.

**Files:**
- Modify: `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift:1-18`

**Interfaces:**
- Produces: `genericD1KVWorker` (renamed from `webmentionWorker`), `v2Workers`/`v3Workers` now reference it.

- [ ] **Step 1: Rename the fixture and its id**

Edit the top of `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift`:

```swift
private let genericD1KVWorker = worker("generic-d1kv-fixture", d1: true, kv: true, r2: false)
private let indieauthWorker = worker("indieauth", d1: true, kv: true, r2: false)
private let micropubWorker = worker("micropub", d1: true, kv: true, r2: true)
private let websubWorker = worker("websub", d1: true, kv: true, r2: false)
private let v2Workers = [genericD1KVWorker, indieauthWorker]
private let v3Workers = [genericD1KVWorker, indieauthWorker, micropubWorker, websubWorker]
```

Then replace every remaining use of `webmentionWorker` in the file (in `withSocialFeatures()` and `omitsRunWorkerFirstWithoutClaims()`) with `genericD1KVWorker`.

- [ ] **Step 2: Run the suite to confirm nothing broke**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: PASS (all existing assertions still hold — this step only renames an identifier, it changes no behavior).

- [ ] **Step 3: Commit**

```bash
git add Tests/AnglesiteCoreTests/WorkerCompositionTests.swift
git commit -m "test(worker-composition): decouple generic D1/KV fixture from the real webmention id"
```

---

### Task 2: Emit the `WEBMENTION_INBOX` D1 binding

Mirrors the existing `AUTH_DB` block exactly (`Sources/AnglesiteCore/WorkerComposition.swift:135-146`): same physical D1 database (`resources.d1DatabaseID`), a second binding name so `@dwk/webmention`'s `createD1Inbox` gets its own binding without a second database.

**Files:**
- Modify: `Sources/AnglesiteCore/WorkerComposition.swift`
- Test: `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift`

**Interfaces:**
- Produces: `WorkerComposition.webmentionWorkerID: String` (public constant, `"webmention"`)

- [ ] **Step 1: Write the failing test**

Add to `WorkerCompositionTests.swift`:

```swift
private let webmentionWorker = worker(WorkerComposition.webmentionWorkerID, d1: false, kv: false, r2: false)

@Test("webmention receive adds a WEBMENTION_INBOX D1 binding on the shared database")
func webmentionAddsInboxBinding() throws {
    let toml = try WorkerComposition.generateWranglerToml(
        siteName: "my-site",
        workers: [webmentionWorker],
        resources: .init(d1DatabaseID: "d1-id")
    )
    #expect(toml.contains("binding = \"WEBMENTION_INBOX\""))
    #expect(toml.contains("database_id = \"d1-id\""))
}

@Test("no webmention worker means no WEBMENTION_INBOX binding")
func noWebmentionOmitsInboxBinding() throws {
    let toml = try WorkerComposition.generateWranglerToml(siteName: "my-site", workers: [indieauthWorker])
    #expect(!toml.contains("WEBMENTION_INBOX"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: FAIL — `WorkerComposition.webmentionWorkerID` doesn't exist yet, and no `WEBMENTION_INBOX` is emitted.

- [ ] **Step 3: Implement**

In `Sources/AnglesiteCore/WorkerComposition.swift`, add the constant next to `indieauthWorkerID` (after line 25):

```swift
    /// `@dwk/webmention`'s catalog id — like `indieauthWorkerID`, composition keys off this
    /// directly for the receiver's three bespoke bindings (`WEBMENTION_INBOX`, the Queue,
    /// `SITE_URL`), since those binding names are part of `@dwk/webmention`'s public composition
    /// contract, not something a generic `resources` flag can express without a paired schema
    /// change in the external `davidwkeith/workers` catalog repo.
    public static let webmentionWorkerID = "webmention"
```

Compute `hasWebmentionReceive` next to `hasIndieauth` (near line 98):

```swift
        let hasIndieauth = workers.contains(where: { $0.id == indieauthWorkerID })
        let hasWebmentionReceive = workers.contains(where: { $0.id == webmentionWorkerID })
```

Add the D1 binding block immediately after the existing `hasIndieauth` AUTH_DB block (after line 146, before the KV block):

```swift
        // Same shared per-site D1 database as DB/AUTH_DB, bound a third time under
        // WEBMENTION_INBOX — @dwk/webmention's createD1Inbox creates its own `webmentions`
        // table on first use, so no separate database or migration is needed here.
        if hasWebmentionReceive {
            lines.append("")
            lines.append("[[d1_databases]]")
            lines.append("binding = \"WEBMENTION_INBOX\"")
            lines.append("database_name = \"\(siteName)-social\"")
            if let id = resources.d1DatabaseID, !id.isEmpty {
                lines.append("database_id = \"\(id)\"")
            } else {
                lines.append("database_id = \"\"  # filled by provisioning")
            }
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WorkerComposition.swift Tests/AnglesiteCoreTests/WorkerCompositionTests.swift
git commit -m "feat(worker-composition): emit WEBMENTION_INBOX D1 binding for #359"
```

---

### Task 3: Emit the Cloudflare Queue producer/consumer blocks

Adds `queueName` to `ProvisionedResources` (mirrors `r2BucketName`'s "deterministic name, not an id" shape — Cloudflare's `wrangler.toml` queue blocks reference queues by name, not id).

**Files:**
- Modify: `Sources/AnglesiteCore/WorkerComposition.swift`
- Test: `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift`

**Interfaces:**
- Consumes: `webmentionWorkerID`, `hasWebmentionReceive` (Task 2)
- Produces: `WorkerComposition.ProvisionedResources.queueName: String?`

- [ ] **Step 1: Write the failing test**

```swift
@Test("webmention receive adds queue producer/consumer blocks")
func webmentionAddsQueueBlocks() throws {
    let toml = try WorkerComposition.generateWranglerToml(
        siteName: "my-site",
        workers: [webmentionWorker],
        resources: .init(queueName: "my-site-webmention")
    )
    #expect(toml.contains("[[queues.producers]]"))
    #expect(toml.contains("[[queues.consumers]]"))
    #expect(toml.contains("queue = \"my-site-webmention\""))
    #expect(toml.contains("binding = \"WEBMENTION_QUEUE\""))
}

@Test("webmention queue name defaults to a deterministic placeholder before provisioning")
func webmentionQueueDefaultsUnprovisioned() throws {
    let toml = try WorkerComposition.generateWranglerToml(siteName: "my-site", workers: [webmentionWorker])
    #expect(toml.contains("queue = \"my-site-webmention\""))
}

@Test("ProvisionedResources.queueName round-trips through JSONEncoder/JSONDecoder")
func provisionedResourcesQueueNameCodable() throws {
    let resources = WorkerComposition.ProvisionedResources(queueName: "my-site-webmention")
    let data = try JSONEncoder().encode(resources)
    let decoded = try JSONDecoder().decode(WorkerComposition.ProvisionedResources.self, from: data)
    #expect(decoded == resources)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: FAIL — `ProvisionedResources` has no `queueName` member, no `[[queues.*]]` emitted.

- [ ] **Step 3: Implement**

Add `queueName` to `ProvisionedResources` (`Sources/AnglesiteCore/WorkerComposition.swift:41-51`):

```swift
    public struct ProvisionedResources: Sendable, Equatable, Codable {
        public var d1DatabaseID: String?
        public var kvNamespaceID: String?
        public var r2BucketName: String?
        /// The Cloudflare Queue name backing `@dwk/webmention`'s async verify step. Like
        /// `r2BucketName`, this is a deterministic name (`\(siteName)-webmention`), not an id —
        /// wrangler.toml's `[[queues.*]]` blocks reference queues by name.
        public var queueName: String?

        public init(
            d1DatabaseID: String? = nil, kvNamespaceID: String? = nil, r2BucketName: String? = nil,
            queueName: String? = nil
        ) {
            self.d1DatabaseID = d1DatabaseID
            self.kvNamespaceID = kvNamespaceID
            self.r2BucketName = r2BucketName
            self.queueName = queueName
        }
    }
```

Emit the queue blocks — insert right after the WEBMENTION_INBOX block added in Task 2:

```swift
        if hasWebmentionReceive {
            lines.append("")
            let queueName = resources.queueName ?? "\(siteName)-webmention"
            lines.append("[[queues.producers]]")
            lines.append("queue = \"\(queueName)\"")
            lines.append("binding = \"WEBMENTION_QUEUE\"")
            lines.append("")
            lines.append("[[queues.consumers]]")
            lines.append("queue = \"\(queueName)\"")
            lines.append("max_batch_size = 10")
            lines.append("max_batch_timeout = 30")
            lines.append("max_retries = 3")
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WorkerComposition.swift Tests/AnglesiteCoreTests/WorkerCompositionTests.swift
git commit -m "feat(worker-composition): emit Cloudflare Queue blocks for webmention receive"
```

---

### Task 4: Emit the `SITE_URL` var

**Files:**
- Modify: `Sources/AnglesiteCore/WorkerComposition.swift`
- Test: `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift`

**Interfaces:**
- Consumes: `hasWebmentionReceive` (Task 2)
- Produces: `generateWranglerToml(..., siteURL: String? = nil)` new parameter

- [ ] **Step 1: Write the failing test**

```swift
@Test("webmention receive with a known site URL emits a SITE_URL var")
func webmentionEmitsSiteURL() throws {
    let toml = try WorkerComposition.generateWranglerToml(
        siteName: "my-site", workers: [webmentionWorker], siteURL: "https://my-site.example")
    #expect(toml.contains("[vars]"))
    #expect(toml.contains("SITE_URL = \"https://my-site.example\""))
}

@Test("webmention receive with no known site URL omits the vars block")
func webmentionOmitsSiteURLWhenUnknown() throws {
    let toml = try WorkerComposition.generateWranglerToml(siteName: "my-site", workers: [webmentionWorker])
    #expect(!toml.contains("[vars]"))
    #expect(!toml.contains("SITE_URL"))
}

@Test("siteURL is ignored when webmention receive isn't active")
func siteURLIgnoredWithoutWebmention() throws {
    let toml = try WorkerComposition.generateWranglerToml(
        siteName: "my-site", workers: [indieauthWorker], siteURL: "https://my-site.example")
    #expect(!toml.contains("SITE_URL"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: FAIL — no `siteURL` parameter exists.

- [ ] **Step 3: Implement**

Add the parameter to `generateWranglerToml`'s signature (`Sources/AnglesiteCore/WorkerComposition.swift:69-76`):

```swift
    public static func generateWranglerToml(
        siteName: String,
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim] = [],
        resources: ProvisionedResources = .init(),
        inboxCaptureEnabled: Bool = false,
        inboxKVNamespaceID: String? = nil,
        siteURL: String? = nil
    ) throws -> String {
```

Emit the `[vars]` block — insert after the Queue blocks from Task 3, before the `hasIndieauth` secrets-comment block:

```swift
        if hasWebmentionReceive, let siteURL, !siteURL.isEmpty {
            lines.append("")
            lines.append("[vars]")
            lines.append("SITE_URL = \"\(siteURL)\"")
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WorkerComposition.swift Tests/AnglesiteCoreTests/WorkerCompositionTests.swift
git commit -m "feat(worker-composition): emit SITE_URL var for webmention receive"
```

---

### Task 5: `SiteSettings.webmentionReceivePaidPlanAcknowledged`

A per-site, persisted opt-in flag — Cloudflare Queues require the Workers **Paid** plan, and the Queue must never be created without the user explicitly acknowledging that first (per the chosen "explicit opt-in confirmation" UX, no pre-flight API call before acknowledgment).

**Files:**
- Modify: `Sources/AnglesiteCore/SiteConfigStore.swift`
- Test: `Tests/AnglesiteCoreTests/SiteConfigStoreTests.swift` (find the existing file; if it doesn't exist, check for wherever `SiteSettings` round-trip tests live — likely alongside `inboxCaptureAccountID`'s own test)

**Interfaces:**
- Produces: `SiteSettings.webmentionReceivePaidPlanAcknowledged: Bool?`

- [ ] **Step 1: Find the existing `SiteSettings` round-trip test**

Run: `grep -rn "inboxCaptureAccountID" Tests/AnglesiteCoreTests/*.swift`

Add a sibling test in whichever file that finds (mirror its exact shape) asserting the new field round-trips through `PropertyListEncoder`/`PropertyListDecoder`:

```swift
@Test("webmentionReceivePaidPlanAcknowledged round-trips through PropertyListEncoder/Decoder")
func webmentionPaidPlanFlagRoundTrips() throws {
    let settings = SiteSettings(webmentionReceivePaidPlanAcknowledged: true)
    let data = try PropertyListEncoder().encode(settings)
    let decoded = try PropertyListDecoder().decode(SiteSettings.self, from: data)
    #expect(decoded.webmentionReceivePaidPlanAcknowledged == true)
}

@Test("a settings.plist written before this field existed still decodes (forward-compat)")
func decodesOldPlistWithoutPaidPlanField() throws {
    let old = SiteSettings(displayName: "My Site")
    let data = try PropertyListEncoder().encode(old)
    let decoded = try PropertyListDecoder().decode(SiteSettings.self, from: data)
    #expect(decoded.webmentionReceivePaidPlanAcknowledged == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter SiteConfigStoreTests` (adjust `--filter` to whatever suite name Step 1 found)
Expected: FAIL — no such member.

- [ ] **Step 3: Implement**

In `Sources/AnglesiteCore/SiteConfigStore.swift`, add the field (after `provisionedWorkerResources`, following the file's existing "add fields as features need them" convention):

```swift
    /// Explicit opt-in: the user has acknowledged that enabling inbound Webmention requires the
    /// Cloudflare Workers **Paid** plan (Cloudflare Queues aren't available on Free). `nil`/`false`
    /// means `SocialWorkerProvisionCommand.provision` must not attempt to create the Queue —
    /// see `DeployModel.webmentionPaidPlanConfirmationPresented`.
    public var webmentionReceivePaidPlanAcknowledged: Bool?
```

Add it to `init` (both the parameter list and the assignment), after `provisionedWorkerResources`:

```swift
        provisionedWorkerResources: WorkerComposition.ProvisionedResources? = nil,
        webmentionReceivePaidPlanAcknowledged: Bool? = nil
    ) {
        // ...existing assignments...
        self.provisionedWorkerResources = provisionedWorkerResources
        self.webmentionReceivePaidPlanAcknowledged = webmentionReceivePaidPlanAcknowledged
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter SiteConfigStoreTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteConfigStore.swift Tests/AnglesiteCoreTests/*.swift
git commit -m "feat(site-settings): add webmentionReceivePaidPlanAcknowledged opt-in flag"
```

---

### Task 6: `SocialWorkerProvisionCommand` — Queue creation gated on the opt-in

**Files:**
- Modify: `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift`
- Test: `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`

**Interfaces:**
- Consumes: `WorkerComposition.webmentionWorkerID`, `ProvisionedResources.queueName`, `generateWranglerToml(..., siteURL:)` (Tasks 2-4)
- Produces: `SocialWorkerProvisionCommand.Result.webmentionPaidPlanConfirmationNeeded(resources:)`; `provision(..., siteURL: String? = nil, acknowledgesPaidPlan: Bool = false)`

- [ ] **Step 1: Read the existing D1/KV/R2 provisioning test pattern**

Run: `grep -n "func test\|@Test" Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift | head -30`

Mirror whichever test's mock-runner setup already exists for D1/KV/R2 creation (it injects a `CommandRunner` closure returning canned `ProcessSupervisor.RunResult`s per `wrangler` subcommand). Write these new tests in that same style:

```swift
@Test("webmention worker without paid-plan acknowledgment returns webmentionPaidPlanConfirmationNeeded, no wrangler call")
func webmentionWithoutAcknowledgmentBlocksBeforeAnyCall() async throws {
    var calledArguments: [[String]] = []
    let command = SocialWorkerProvisionCommand(
        tokenSource: { "tok" },
        runner: { _, arguments, _, _ in
            calledArguments.append(arguments)
            return .init(stdout: "", stderr: "unexpected call", exitCode: 1)
        },
        deployer: { _, _, _ in .succeeded(url: URL(string: "https://example.com")!, duration: 0) }
    )
    let webmention = WorkerDescriptor(
        id: "webmention", displayName: "Webmentions", description: "test", group: "social",
        binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

    let result = await command.provision(
        siteID: "site-1", siteDirectory: tempSiteDirectory(), siteName: "my-site",
        workers: [webmention], acknowledgesPaidPlan: false)

    guard case .webmentionPaidPlanConfirmationNeeded = result else {
        Issue.record("expected .webmentionPaidPlanConfirmationNeeded, got \(result)")
        return
    }
    #expect(calledArguments.isEmpty, "must not call wrangler before the user acknowledges the paid-plan requirement")
}

@Test("webmention worker with acknowledgment creates the queue")
func webmentionWithAcknowledgmentCreatesQueue() async throws {
    var calledArguments: [[String]] = []
    let command = SocialWorkerProvisionCommand(
        tokenSource: { "tok" },
        runner: { _, arguments, _, _ in
            calledArguments.append(arguments)
            if arguments.first == "queues" {
                return .init(stdout: #"{"result":{"queue_name":"my-site-webmention"}}"#, stderr: "", exitCode: 0)
            }
            return .init(stdout: "", stderr: "", exitCode: 0)
        },
        deployer: { _, _, _ in .succeeded(url: URL(string: "https://example.com")!, duration: 0) }
    )
    let webmention = WorkerDescriptor(
        id: "webmention", displayName: "Webmentions", description: "test", group: "social",
        binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

    let result = await command.provision(
        siteID: "site-1", siteDirectory: tempSiteDirectory(), siteName: "my-site",
        workers: [webmention], acknowledgesPaidPlan: true)

    guard case .succeeded(_, let resources, _) = result else {
        Issue.record("expected .succeeded, got \(result)")
        return
    }
    #expect(resources.queueName == "my-site-webmention")
    #expect(calledArguments.contains(["queues", "create", "my-site-webmention", "--json"]))
}

@Test("an already-provisioned queue is not re-created")
func alreadyProvisionedQueueSkipsCreation() async throws {
    var calledArguments: [[String]] = []
    let command = SocialWorkerProvisionCommand(
        tokenSource: { "tok" },
        runner: { _, arguments, _, _ in
            calledArguments.append(arguments)
            return .init(stdout: "", stderr: "", exitCode: 0)
        },
        deployer: { _, _, _ in .succeeded(url: URL(string: "https://example.com")!, duration: 0) }
    )
    let webmention = WorkerDescriptor(
        id: "webmention", displayName: "Webmentions", description: "test", group: "social",
        binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

    let result = await command.provision(
        siteID: "site-1", siteDirectory: tempSiteDirectory(), siteName: "my-site",
        workers: [webmention], acknowledgesPaidPlan: true,
        knownResources: .init(queueName: "my-site-webmention"))

    guard case .succeeded = result else {
        Issue.record("expected .succeeded, got \(result)")
        return
    }
    #expect(!calledArguments.contains(where: { $0.first == "queues" }))
}
```

(If `tempSiteDirectory()` isn't already a helper in this test file, check how the existing D1/KV/R2 tests get a `siteDirectory: URL` — reuse that exact helper instead of inventing a new one.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: FAIL — `Result.webmentionPaidPlanConfirmationNeeded` and the new `provision` parameters don't exist.

- [ ] **Step 3: Implement**

Add the new result case (`Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift:13-21`):

```swift
    public enum Result: Sendable, Equatable {
        case succeeded(url: URL, resources: WorkerComposition.ProvisionedResources, duration: TimeInterval)
        case blocked(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning], resources: WorkerComposition.ProvisionedResources)
        case workerNameConflict(name: String, resources: WorkerComposition.ProvisionedResources)
        /// Webmention receive is active but the site hasn't explicitly acknowledged that
        /// Cloudflare Queues require the Workers Paid plan (#359). Returned *before* any
        /// wrangler call — `DeployModel` parks the deploy and presents a confirmation sheet;
        /// retrying with `acknowledgesPaidPlan: true` proceeds to create the Queue.
        case webmentionPaidPlanConfirmationNeeded(resources: WorkerComposition.ProvisionedResources)
        case failed(reason: String, exitCode: Int32?, resources: WorkerComposition.ProvisionedResources)
    }
```

Add the two new parameters to `provision` (`Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift:50-65`):

```swift
    public func provision(
        siteID: String,
        siteDirectory: URL,
        siteName: String,
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim] = [],
        knownResources: WorkerComposition.ProvisionedResources = .init(),
        /// The site's best-known public URL (`.site-config`'s `DOMAIN`/`SITE_DOMAIN`/`SITE_URL`,
        /// via `DeployCoordinator.resolveSiteURL`), threaded into `WorkerComposition`'s `SITE_URL`
        /// var. `nil` on a first-ever deploy before any host is known — the composed Worker
        /// degrades gracefully (worker.ts no-ops the queue consumer without it).
        siteURL: String? = nil,
        /// Explicit per-deploy opt-in that the user has acknowledged inbound Webmention requires
        /// the Cloudflare Workers Paid plan (#359) — `DeployModel` sets this from
        /// `SiteSettings.webmentionReceivePaidPlanAcknowledged` plus the in-flight confirmation
        /// sheet's "Enable & retry" action. Ignored unless a `webmention` worker is active.
        acknowledgesPaidPlan: Bool = false
    ) async -> Result {
```

Right after the existing R2 block (after line 163, before the final unconditional `persistConfig` call at line 165), add the Queue creation step, gated on the acknowledgment — this is the "no pre-flight API call before acknowledgment" check, so it must come *before* any `runWrangler` call for the queue:

```swift
        let hasWebmentionReceive = workers.contains(where: { $0.id == WorkerComposition.webmentionWorkerID })
        if hasWebmentionReceive, resources.queueName == nil {
            guard acknowledgesPaidPlan else {
                return .webmentionPaidPlanConfirmationNeeded(resources: resources)
            }
            let name = "\(siteName)-webmention"
            let result = await runWrangler(
                siteDirectory: siteDirectory,
                arguments: ["queues", "create", name, "--json"],
                environment: environment,
                source: source,
                resources: resources
            )
            switch result {
            case .success:
                resources.queueName = name
            case .failure(let failure):
                return failure
            }
            if let failure = persistConfig(
                siteDirectory: siteDirectory, siteName: siteName, workers: workers,
                routeClaims: routeClaims, resources: resources, siteURL: siteURL
            ) {
                return failure
            }
        }
```

Update every existing `persistConfig(...)` call site in this file (there are four: after the D1 block, after the KV block, after the R2 block, and the final unconditional one) to also pass `siteURL: siteURL` — and update `persistConfig`'s own signature and its call into `WorkerComposition.generateWranglerToml`:

```swift
    private func persistConfig(
        siteDirectory: URL,
        siteName: String,
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim],
        resources: WorkerComposition.ProvisionedResources,
        siteURL: String? = nil
    ) -> Result? {
        do {
            let toml = try WorkerComposition.generateWranglerToml(
                siteName: siteName,
                workers: workers,
                routeClaims: routeClaims,
                resources: resources,
                siteURL: siteURL
            )
            try toml.write(
                to: siteDirectory.appendingPathComponent("wrangler.toml"),
                atomically: true,
                encoding: .utf8
            )
            return nil
        } catch {
            return .failed(reason: "couldn't write wrangler.toml: \(error)", exitCode: nil, resources: resources)
        }
    }
```

(Every call site — `persistConfig(siteDirectory: siteDirectory, siteName: siteName, workers: workers, routeClaims: routeClaims, resources: resources)` — becomes `persistConfig(siteDirectory: siteDirectory, siteName: siteName, workers: workers, routeClaims: routeClaims, resources: resources, siteURL: siteURL)`.)

Finally, extend `readPersistedResources` so a queue created on a previous deploy is recognized without re-scraping (mirrors the existing `database_id`/`id`/`bucket_name` scrape at `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift:255-265`) — add a `queue = "..."` scrape:

```swift
    static func readPersistedResources(from siteDirectory: URL) -> WorkerComposition.ProvisionedResources {
        let url = siteDirectory.appendingPathComponent("wrangler.toml")
        guard let toml = try? String(contentsOf: url, encoding: .utf8) else {
            return .init()
        }
        return .init(
            d1DatabaseID: extractTomlString(named: "database_id", from: toml),
            kvNamespaceID: extractTomlString(named: "id", from: toml),
            r2BucketName: extractTomlString(named: "bucket_name", from: toml),
            queueName: extractTomlString(named: "queue", from: toml)
        )
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: PASS. Also run the full suite once to catch any missed call site: `swift test --package-path . --filter AnglesiteCoreTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift
git commit -m "feat(provisioning): create the webmention Queue behind an explicit paid-plan opt-in"
```

---

### Task 7: `DeployCoordinator.resolveSiteURL`

**Files:**
- Modify: `Sources/AnglesiteCore/DeployCoordinator.swift`
- Test: `Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift` (find via `grep -rln resolveWorkerSiteName Tests/`)

**Interfaces:**
- Produces: `DeployCoordinator.resolveSiteURL(siteDirectory: URL) -> String?`

- [ ] **Step 1: Write the failing test**

Find the existing test file covering `resolveWorkerSiteName` (`grep -rln resolveWorkerSiteName Tests/AnglesiteCoreTests/`) and add sibling tests in the same style:

```swift
@Test("resolveSiteURL prefers DOMAIN over everything else")
func resolveSiteURLPrefersDomain() throws {
    let dir = try makeTempSiteDirectory()  // reuse whatever helper resolveWorkerSiteName's tests use
    try "DOMAIN=example.com\nSITE_URL=https://my-site.workers.dev\n".write(
        to: dir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
    #expect(DeployCoordinator.resolveSiteURL(siteDirectory: dir) == "https://example.com")
}

@Test("resolveSiteURL falls back to the persisted SITE_URL when no custom domain is set")
func resolveSiteURLFallsBackToSiteURL() throws {
    let dir = try makeTempSiteDirectory()
    try "SITE_URL=https://my-site.workers.dev\n".write(
        to: dir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
    #expect(DeployCoordinator.resolveSiteURL(siteDirectory: dir) == "https://my-site.workers.dev")
}

@Test("resolveSiteURL returns nil before any deploy has ever persisted a host")
func resolveSiteURLNilBeforeFirstDeploy() throws {
    let dir = try makeTempSiteDirectory()
    #expect(DeployCoordinator.resolveSiteURL(siteDirectory: dir) == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter DeployCoordinatorTests`
Expected: FAIL — no such function.

- [ ] **Step 3: Implement**

Add to `Sources/AnglesiteCore/DeployCoordinator.swift`, right after `resolveWorkerSiteName`:

```swift
    /// The site's best-known public URL for `WorkerComposition`'s `SITE_URL` var (#359): a
    /// custom domain (`DOMAIN`/`SITE_DOMAIN`, `WebsiteAnalyticsAsset.bestHost`'s own precedence)
    /// wins, given a scheme since those keys store a bare host; otherwise the workers.dev host
    /// `DeployCommand.persistSiteURL` writes after the site's first successful deploy. `nil`
    /// before any deploy has ever run and no custom domain is configured — the composed Worker
    /// degrades gracefully without it (worker.ts's queue consumer no-ops).
    public static func resolveSiteURL(siteDirectory: URL) -> String? {
        let config = (try? WebsiteAnalyticsAsset.loadConfig(siteDirectory: siteDirectory)) ?? ""
        if let domain = WebsiteAnalyticsAsset.configValue("DOMAIN", in: config)
            ?? WebsiteAnalyticsAsset.configValue("SITE_DOMAIN", in: config) {
            let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "https://\(trimmed)"
        }
        return WebsiteAnalyticsAsset.configValue("SITE_URL", in: config)
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter DeployCoordinatorTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeployCoordinator.swift Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift
git commit -m "feat(deploy): resolve the site's public URL for webmention's SITE_URL var"
```

---

### Task 8: Wire the paid-plan confirmation into `DeployModel`

Mirrors the existing `workerNameConflict` park-and-retry flow exactly (`Sources/AnglesiteApp/DeployModel.swift`) — same `pendingDeploy` tuple, same presented-`Bool`-plus-sheet shape, same "retry re-dispatches `deploy(...)`" mechanism.

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift`

**Interfaces:**
- Consumes: `SocialWorkerProvisionCommand.Result.webmentionPaidPlanConfirmationNeeded`, `DeployCoordinator.resolveSiteURL`, `SiteSettings.webmentionReceivePaidPlanAcknowledged`
- Produces: `DeployModel.Phase.webmentionPaidPlanConfirmationNeeded`, `webmentionPaidPlanConfirmationPresented: Bool`, `acknowledgeWebmentionPaidPlanAndRetry() async`, `cancelWebmentionPaidPlanConfirmation()`

This task has no isolated unit test of its own — `DeployModel` is an app-target `@MainActor` view model that (per this repo's CLAUDE.md build notes) can't run under `swift test` on CI. Its correctness is verified by Task 8's own manual QA pass (Step 4) plus the fact that `SocialWorkerProvisionCommand`/`DeployCoordinator` — the logic it calls — are already covered by Tasks 6-7's tests.

- [ ] **Step 1: Add the new `Phase` case and presented flag**

In `Sources/AnglesiteApp/DeployModel.swift`, extend `Phase` (line 21-28):

```swift
    enum Phase: Equatable {
        case idle
        case running(siteID: String, since: Date)
        case succeeded(url: URL, duration: TimeInterval)
        case failed(reason: String, exitCode: Int32?)
        case blocked(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning])
        case workerNameConflict(name: String)
        case webmentionPaidPlanConfirmationNeeded
    }
```

Add the presented flag next to `workerNameConflictPresented` (after line 61):

```swift
    /// Bound to a `.sheet` in `SiteWindow` for the `.webmentionPaidPlanConfirmationNeeded`
    /// outcome — inbound Webmention needs a Cloudflare Queue, which requires the Workers Paid
    /// plan. Reuses `pendingDeploy` to park and retry, same as the token-prompt and
    /// worker-name-conflict flows.
    var webmentionPaidPlanConfirmationPresented: Bool = false
```

- [ ] **Step 2: Add the retry/cancel functions**

Add right after `cancelWorkerNameConflictPrompt()` (after line 346):

```swift
    /// Called by the paid-plan confirmation sheet's "Enable & retry" button. Persists the
    /// acknowledgment into `SiteSettings` (so future deploys never re-prompt) and retries the
    /// parked deploy — `runDeploy` re-reads settings and passes `acknowledgesPaidPlan: true`
    /// into `SocialWorkerProvisionCommand.provision`, which then creates the Queue.
    func acknowledgeWebmentionPaidPlanAndRetry() async {
        guard let pending = pendingDeploy else { return }
        let configStore = SiteConfigStore(configDirectory: pending.configDirectory)
        var settings = (try? await configStore.load()) ?? SiteSettings()
        settings.webmentionReceivePaidPlanAcknowledged = true
        try? await configStore.save(settings)
        pendingDeploy = nil
        // Deliberately NOT clearing webmentionPaidPlanConfirmationPresented here — mirrors
        // renameWorkerAndRetry's identical reasoning: the sheet stays open while the retried
        // deploy runs, and runDeploy's terminal cases dismiss it once the outcome is known.
        deploy(
            siteID: pending.siteID, siteDirectory: pending.siteDirectory,
            configDirectory: pending.configDirectory, currentRoutes: pending.currentRoutes,
            containerControlProvider: pending.containerControlProvider, siteName: pending.siteName)
    }

    func cancelWebmentionPaidPlanConfirmation() {
        pendingDeploy = nil
        webmentionPaidPlanConfirmationPresented = false
    }
```

- [ ] **Step 3: Wire `runDeploy` — resolve `siteURL`/`acknowledgesPaidPlan`, pass them to `provision`, and handle the new result**

In `runDeploy`, find where `settings` is loaded (`let settings = (try? await configStore.load()) ?? SiteSettings()`, near where `workerCatalog`/`activationPlan` are computed) and where `socialCommand.provision(...)` is called. Resolve the two new inputs right before the `provision` call:

```swift
        let siteURL = DeployCoordinator.resolveSiteURL(siteDirectory: siteDirectory)
        let acknowledgesPaidPlan = settings.webmentionReceivePaidPlanAcknowledged ?? false
```

Update the `provision` call to pass them:

```swift
        let provisionResult = await socialCommand.provision(
            siteID: siteID,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            workers: workers,
            routeClaims: routeClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init(),
            siteURL: siteURL,
            acknowledgesPaidPlan: acknowledgesPaidPlan
        )
```

Immediately after that call (before the existing `if case .succeeded(_, let resources, _) = provisionResult` block), intercept the new case and return early — mirroring the shape of the route-claim-validation early return earlier in the same function:

```swift
        if case .webmentionPaidPlanConfirmationNeeded = provisionResult {
            pendingDeploy = (siteID, siteDirectory, configDirectory, currentRoutes, containerControlProvider, siteName)
            subscription.cancel()
            _ = await logTask.value
            currentMilestone = nil
            workerNameConflictPresented = false
            transition(siteID: siteID, to: .webmentionPaidPlanConfirmationNeeded)
            drawerPresented = false
            webmentionPaidPlanConfirmationPresented = presentation == .foreground
            return .failed(
                reason: "Inbound Webmention requires the Cloudflare Workers Paid plan — confirm to continue",
                exitCode: nil)
        }
```

Finally, add a case to `deployAutomatically`'s result-mapping switch (near the existing `.workerNameConflict` case around line 247-248) — the background/invisible-publish path has no sheet to present, so it just surfaces this as a deferred/failed reason:

Actually — `deployAutomatically` maps `DeployCommand.Result`, and this new interception returns a bare `.failed(reason:...)` directly from `runDeploy` before `result` is ever computed via `provisionResult.asDeployCommandResult`, so `deployAutomatically`'s existing `case .failed(let reason, _): return .failed(reason: reason)` arm already handles it correctly with no additional change needed. Confirm this by reading `deployAutomatically`'s switch (`Sources/AnglesiteApp/DeployModel.swift:242-251`) — no edit required there.

- [ ] **Step 4: Manual QA pass**

Build the app (`xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` — run `xcodegen generate` first in this worktree), open a test site, toggle on the `webmention` worker (via whatever currently sets `SiteSettings.activeWorkerIDs` — if no UI exists yet for this, set it directly via a debug script or `SiteConfigStore` call), and deploy. Confirm:
1. The deploy stops with the paid-plan confirmation sheet, and no `wrangler queues create` call happens (check the debug log pane for absence of a `queues` log line).
2. Clicking "Enable & retry" persists the acknowledgment and the deploy proceeds to create the Queue.
3. A second deploy on the same site does not re-prompt.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/DeployModel.swift
git commit -m "feat(deploy): park and confirm the webmention paid-plan opt-in before provisioning"
```

---

### Task 9: The confirmation sheet view

**Files:**
- Create: `Sources/AnglesiteApp/WebmentionPaidPlanConfirmationSheetView.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (near line 520, where `.sheet(isPresented: $bindableModel.deploy.workerNameConflictPresented)` is wired)

**Interfaces:**
- Consumes: `DeployModel.webmentionPaidPlanConfirmationPresented`, `.acknowledgeWebmentionPaidPlanAndRetry()`, `.cancelWebmentionPaidPlanConfirmation()`

- [ ] **Step 1: Create the sheet view**

```swift
import SwiftUI
import AnglesiteCore

/// Sheet shown when a deploy needs to provision the Cloudflare Queue that inbound Webmention's
/// async verification step relies on — Queues require the Workers **Paid** plan, so the app
/// asks for an explicit one-time acknowledgment before ever calling `wrangler queues create`
/// (#359). Mirrors `WorkerNameConflictSheetView`'s park-and-retry shape.
struct WebmentionPaidPlanConfirmationSheetView: View {
    let model: DeployModel
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Inbound Webmention requires the Workers Paid plan")
                    .font(.headline)
                Text("Receiving webmentions verifies each one asynchronously using a Cloudflare Queue, which isn't available on the Workers Free plan. Continuing will create a Queue on your connected Cloudflare account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Enable & retry") {
                    Task { await model.acknowledgeWebmentionPaidPlanAndRetry() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

#Preview {
    WebmentionPaidPlanConfirmationSheetView(model: DeployModel(), onCancel: {})
}
```

- [ ] **Step 2: Wire the sheet in `SiteWindow`**

Find the existing `.sheet(isPresented: $bindableModel.deploy.workerNameConflictPresented) { ... }` block (`Sources/AnglesiteApp/SiteWindow.swift:520-525`) and add a sibling `.sheet` modifier immediately after it:

```swift
        .sheet(isPresented: $bindableModel.deploy.webmentionPaidPlanConfirmationPresented) {
            WebmentionPaidPlanConfirmationSheetView(model: model.deploy) {
                model.deploy.cancelWebmentionPaidPlanConfirmation()
            }
        }
```

- [ ] **Step 3: Build**

Run (after `xcodegen generate` if the worktree's `.xcodeproj` predates this file):
`xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: build succeeds, no missing-file or unresolved-symbol errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/WebmentionPaidPlanConfirmationSheetView.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(deploy): add the webmention paid-plan confirmation sheet"
```

---

### Task 10: Discovery — provisioning-gated `<link rel="webmention">`

Follows the exact `.site-config` + `readConfig()` gating mechanism already established for `.site-config`-driven template output (`Resources/Template/scripts/config.ts`), and worker.ts's own doc comment (lines 361-364) which already states the intended design is a *gated* advertisement, not an unconditional one like IndieAuth's.

**Files:**
- Modify: `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift` (`persistConfig`)
- Modify: `Resources/Template/src/layouts/BaseLayout.astro`
- Test: find the existing Astro/Vitest test covering `BaseLayout.astro` or the `.site-config`-gated integration pattern (check `Resources/Template/src/layouts/` and `Resources/Template/scripts/` for a `.test.ts` sibling; if `BaseLayout.astro` has no direct test, check `IntegrationCatalog`'s own template-injection tests in `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift` for the closest existing pattern and mirror its style for a new focused test)

- [ ] **Step 1: Write the failing test for the `.site-config` write**

In `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`, add (reusing Task 6's `webmention` fixture and helper):

```swift
@Test("webmention receive writes WEBMENTION_RECEIVE_ENABLED into .site-config")
func webmentionWritesReceiveEnabledFlag() async throws {
    let siteDirectory = tempSiteDirectory()
    let command = SocialWorkerProvisionCommand(
        tokenSource: { "tok" },
        runner: { _, arguments, _, _ in
            if arguments.first == "queues" {
                return .init(stdout: #"{"result":{"queue_name":"my-site-webmention"}}"#, stderr: "", exitCode: 0)
            }
            return .init(stdout: "", stderr: "", exitCode: 0)
        },
        deployer: { _, _, _ in .succeeded(url: URL(string: "https://example.com")!, duration: 0) }
    )
    let webmention = WorkerDescriptor(
        id: "webmention", displayName: "Webmentions", description: "test", group: "social",
        binding: .settingsActivated, resources: .init(needsD1: false, needsKV: false, needsR2: false))

    _ = await command.provision(
        siteID: "site-1", siteDirectory: siteDirectory, siteName: "my-site",
        workers: [webmention], acknowledgesPaidPlan: true)

    let config = try String(contentsOf: siteDirectory.appendingPathComponent(".site-config"), encoding: .utf8)
    #expect(SiteConfigFile.value(forKey: "WEBMENTION_RECEIVE_ENABLED", in: config) == "true")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: FAIL — `.site-config` is never written today.

- [ ] **Step 3: Implement the `.site-config` write**

In `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift`'s `persistConfig` (extended in Task 6), add the `.site-config` write after the existing `wrangler.toml` write:

```swift
    private func persistConfig(
        siteDirectory: URL,
        siteName: String,
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim],
        resources: WorkerComposition.ProvisionedResources,
        siteURL: String? = nil
    ) -> Result? {
        do {
            let toml = try WorkerComposition.generateWranglerToml(
                siteName: siteName,
                workers: workers,
                routeClaims: routeClaims,
                resources: resources,
                siteURL: siteURL
            )
            try toml.write(
                to: siteDirectory.appendingPathComponent("wrangler.toml"),
                atomically: true,
                encoding: .utf8
            )
            let hasWebmentionReceive = workers.contains(where: { $0.id == WorkerComposition.webmentionWorkerID })
            if hasWebmentionReceive {
                let configURL = siteDirectory.appendingPathComponent(".site-config")
                let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
                let updated = SiteConfigFile.upsert([("WEBMENTION_RECEIVE_ENABLED", "true")], into: existing)
                if updated != existing {
                    try updated.write(to: configURL, atomically: true, encoding: .utf8)
                }
            }
            return nil
        } catch {
            return .failed(reason: "couldn't write wrangler.toml: \(error)", exitCode: nil, resources: resources)
        }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: PASS

- [ ] **Step 5: Add the gated link to `BaseLayout.astro`**

In `Resources/Template/src/layouts/BaseLayout.astro`, add the import and gated link. First add the frontmatter import (near the top, alongside `Hcard`):

```astro
---
import "../styles/global.css";
import Hcard from "../components/Hcard.astro";
import { readConfig } from "../../scripts/config";
// anglesite:imports — integration component imports are injected here on setup

interface Props {
  title: string;
  description?: string;
}

const { title, description } = Astro.props;
---
```

Then add the gated link right after the existing `indieauth-metadata` link (before `<slot name="head" />`):

```astro
    <link rel="indieauth-metadata" href="/.well-known/oauth-authorization-server" />
    {readConfig("WEBMENTION_RECEIVE_ENABLED") === "true" && (
      <link rel="webmention" href="/webmention" />
    )}
    <slot name="head" />
```

- [ ] **Step 6: Write and run an Astro-side test**

Check `Resources/Template/scripts/config.test.ts` (or the nearest existing test for `readConfig`-gated template output) for the exact test-harness pattern used to render an `.astro` component with a given `.site-config`. If no direct precedent renders `BaseLayout.astro` itself, add a focused unit test of the config-read logic instead (matching whatever the codebase already does to test conditional head injection) verifying: with `WEBMENTION_RECEIVE_ENABLED=true` in a fixture `.site-config`, `readConfig("WEBMENTION_RECEIVE_ENABLED")` returns `"true"`; without it, `undefined`.

Run: `cd Resources/Template && npm test`
Expected: PASS

- [ ] **Step 7: Run the full template build**

Run: `cd Resources/Template && npm run build`
Expected: PASS — confirms the new import doesn't break `astro check`/`astro build`.

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift Resources/Template/src/layouts/BaseLayout.astro
git commit -m "feat(template): advertise the webmention receive endpoint once provisioned"
```

---

### Task 11: `WorkersConformanceFetcher` + advisory (non-blocking) log

Mirrors `WorkerCatalogFetcher` exactly. **Does not gate activation** — see Global Constraints for why (the real `conformance/status.json` currently reports V-3 packages `"pending"`, and gating would break the already-shipped #887 receiver).

**Files:**
- Create: `Sources/AnglesiteCore/WorkersConformanceFetcher.swift`
- Test: Create `Tests/AnglesiteCoreTests/WorkersConformanceFetcherTests.swift`
- Modify: `Sources/AnglesiteCore/WorkerActivation.swift`
- Test: `Tests/AnglesiteCoreTests/WorkerActivationTests.swift` (find via `grep -rln missingDescriptorWarning Tests/`)
- Modify: `Sources/AnglesiteApp/DeployModel.swift` (one log line, next to the existing `missingDescriptorWarning` log)

**Interfaces:**
- Produces: `WorkersConformanceFetcher.status() async -> WorkersConformanceStatus`, `WorkersConformanceFetcher.productionStatusURL: URL`, `WorkerActivation.conformanceAdvisory(activeIDs: Set<String>, conformance: WorkersConformanceStatus) -> String?`

- [ ] **Step 1: Write the failing fetcher test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WorkersConformanceFetcher")
struct WorkersConformanceFetcherTests {
    private static let sampleJSON = """
    {
      "packages": {
        "@dwk/webmention": {
          "standard": "Webmention",
          "suites": { "webmention.rocks/receiver": { "status": "pending" } },
          "integration": { "status": "passing" }
        }
      }
    }
    """.data(using: .utf8)!

    @Test("fetches and caches on success")
    func fetchesAndCaches() async throws {
        let tempCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("conformance-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempCache) }

        let fetcher = WorkersConformanceFetcher(
            statusURL: URL(string: "https://example.com/status.json")!,
            cacheURL: tempCache,
            session: .shared
        )
        // No live network in this test — verify the pure parse path instead, mirroring
        // WorkerCatalogFetcherTests' own no-network-mock style if one exists (check via
        // `grep -n "class.*URLProtocol\|MockURLProtocol" Tests/AnglesiteCoreTests/WorkerCatalogFetcherTests.swift`
        // and reuse the same mock transport helper here instead of `.shared`).
        let status = try WorkersConformanceReader.parse(Self.sampleJSON)
        #expect(status.packages["@dwk/webmention"]?.integrationStatus == "passing")
    }

    @Test("falls back to an empty status on total failure")
    func fallsBackToEmpty() async throws {
        let fetcher = WorkersConformanceFetcher(
            statusURL: URL(string: "https://127.0.0.1:1/does-not-exist")!,
            cacheURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("conformance-cache-missing-\(UUID().uuidString).json")
        )
        let status = await fetcher.status()
        #expect(status.packages.isEmpty)
    }
}
```

(Step 1's first test is intentionally light — its real job is documented in the comment: find whatever mock-transport pattern `WorkerCatalogFetcherTests.swift` already uses for a deterministic non-network fetch test, and mirror it exactly here instead of guessing at a new one.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path . --filter WorkersConformanceFetcherTests`
Expected: FAIL — `WorkersConformanceFetcher` doesn't exist.

- [ ] **Step 3: Implement the fetcher**

Create `Sources/AnglesiteCore/WorkersConformanceFetcher.swift` by copying `WorkerCatalogFetcher.swift`'s structure verbatim and substituting the parse/URL specifics:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(OSLog)
import OSLog
#endif

public enum WorkersConformanceFetchError: Error, Sendable, Equatable {
    case fetchFailed(String)
}

/// Fetches, parses, and disk-caches `conformance/status.json` from the `@dwk/workers` monorepo.
/// Network or parse failures degrade to the last successfully cached copy, then to an empty
/// status — this is advisory-only (see `WorkerActivation.conformanceAdvisory`), so a fetch
/// failure must never block a deploy, mirroring `WorkerCatalogFetcher`'s own degradation
/// contract.
public actor WorkersConformanceFetcher {
    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "io.dwk.anglesite", category: "WorkersConformanceFetcher")
    #endif

    private static func logDegradation(_ message: String) {
        #if canImport(OSLog)
        logger.error("\(message, privacy: .public)")
        #else
        FileHandle.standardError.write(Data("[WorkersConformanceFetcher] \(message)\n".utf8))
        #endif
    }

    private let statusURL: URL
    private let cacheURL: URL
    private let session: URLSession
    private let fileManager: FileManager

    public init(
        statusURL: URL,
        cacheURL: URL = WorkersConformanceFetcher.defaultCacheURL(),
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.statusURL = statusURL
        self.cacheURL = cacheURL
        self.session = session
        self.fileManager = fileManager
    }

    public func status() async -> WorkersConformanceStatus {
        do {
            return try await fetchAndCache()
        } catch {
            Self.logDegradation("status fetch failed, falling back to cache: \(error)")
        }
        do {
            return try Self.readCache(cacheURL)
        } catch {
            Self.logDegradation("status cache read failed, falling back to empty status: \(error)")
            return WorkersConformanceStatus(packages: [:])
        }
    }

    private func fetchAndCache() async throws -> WorkersConformanceStatus {
        let (data, response) = try await session.data(from: statusURL)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw WorkersConformanceFetchError.fetchFailed("bad response from \(statusURL)")
        }
        let status = try WorkersConformanceReader.parse(data)
        do {
            try Self.writeCache(data, to: cacheURL, fileManager: fileManager)
        } catch {
            Self.logDegradation("status cache write failed (serving fresh data anyway): \(error)")
        }
        return status
    }

    private static func readCache(_ url: URL) throws -> WorkersConformanceStatus {
        let data = try Data(contentsOf: url)
        return try WorkersConformanceReader.parse(data)
    }

    private static func writeCache(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    /// Verified live against `davidwkeith/workers` during #359 planning (2026-07-21).
    public static let productionStatusURL = URL(
        string: "https://raw.githubusercontent.com/davidwkeith/workers/main/conformance/status.json"
    )!

    /// `~/Library/Application Support/Anglesite/worker-conformance-cache.json`.
    public static func defaultCacheURL(fileManager: FileManager = .default) -> URL {
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.portableHomeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Anglesite", isDirectory: true)
            .appendingPathComponent("worker-conformance-cache.json")
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path . --filter WorkersConformanceFetcherTests`
Expected: PASS

- [ ] **Step 5: Write the failing advisory test**

In `Tests/AnglesiteCoreTests/WorkerActivationTests.swift`:

```swift
@Test("conformanceAdvisory reports blocked packages for an active phase-gated worker")
func advisoryReportsBlockedPackages() {
    let status = try! WorkersConformanceReader.parse("""
    { "packages": { "@dwk/webmention": { "standard": "Webmention", "suites": {}, "integration": { "status": "pending" } } } }
    """.data(using: .utf8)!)
    let advisory = WorkerActivation.conformanceAdvisory(activeIDs: ["webmention"], conformance: status)
    #expect(advisory != nil)
    #expect(advisory!.contains("@dwk/webmention"))
}

@Test("conformanceAdvisory is nil when nothing phase-gated is active")
func advisoryNilWithoutRelevantWorkers() {
    let status = WorkersConformanceStatus(packages: [:])
    #expect(WorkerActivation.conformanceAdvisory(activeIDs: ["solid-pod"], conformance: status) == nil)
}
```

- [ ] **Step 6: Run to verify it fails**

Run: `swift test --package-path . --filter WorkerActivationTests`
Expected: FAIL — no such function.

- [ ] **Step 7: Implement the advisory**

Add to `Sources/AnglesiteCore/WorkerActivation.swift`, after `missingDescriptorWarning`:

```swift
    /// Advisory-only (#359): reports which required `@dwk/*` packages for an active worker's
    /// gated phase aren't release-ready yet, per `WorkersConformanceStatus.gateStatus`. Never
    /// blocks activation or deploy — `conformance/status.json` reporting a package `"pending"`
    /// is expected during active development (verified live 2026-07-21: V-3's packages are all
    /// `"pending"` even though #887's webmention receiver already ships and works). This exists
    /// purely so the debug pane surfaces "you're running ahead of conformance certification"
    /// rather than the app silently having no opinion. `nil` when nothing to report.
    public static func conformanceAdvisory(
        activeIDs: Set<String>, conformance: WorkersConformanceStatus
    ) -> String? {
        var messages: [String] = []
        for phase in [WorkersConformanceStatus.Phase.v2, .v3, .v4] {
            let required = WorkersConformanceStatus.phaseRequirements[phase] ?? []
            // Only advise about a phase if one of its required packages corresponds to an
            // active worker id — npm package names are "@dwk/<id>", matching WorkerDescriptor.id.
            let relevantActive = required.contains { activeIDs.contains(String($0.dropFirst("@dwk/".count))) }
            guard relevantActive else { continue }
            let gate = conformance.gateStatus(for: phase)
            guard !gate.isUnblocked else { continue }
            messages.append("conformance: \(gate.blocked.joined(separator: ", ")) not yet release-ready for this phase")
        }
        return messages.isEmpty ? nil : messages.joined(separator: "; ")
    }
```

- [ ] **Step 8: Run to verify it passes**

Run: `swift test --package-path . --filter WorkerActivationTests`
Expected: PASS

- [ ] **Step 9: Wire one log line into `DeployModel.runDeploy`**

Right next to the existing `missingDescriptorWarning` log call in `runDeploy` (`Sources/AnglesiteApp/DeployModel.swift`, near where `activationPlan.unresolvedIDs` is logged), add:

```swift
        let conformanceStatus = await WorkersConformanceFetcher(
            statusURL: WorkersConformanceFetcher.productionStatusURL
        ).status()
        if let advisory = WorkerActivation.conformanceAdvisory(
            activeIDs: effectiveActiveIDs, conformance: conformanceStatus
        ) {
            await logCenter.append(source: "deploy:\(siteID)", stream: .stdout, text: advisory)
        }
```

- [ ] **Step 10: Manual QA pass**

Deploy a site with `webmention` active. Confirm the debug log pane shows the advisory line (given the real status.json's current "pending" state) and — critically — that the deploy still succeeds (this is advisory, not blocking).

- [ ] **Step 11: Commit**

```bash
git add Sources/AnglesiteCore/WorkersConformanceFetcher.swift Tests/AnglesiteCoreTests/WorkersConformanceFetcherTests.swift Sources/AnglesiteCore/WorkerActivation.swift Tests/AnglesiteCoreTests/WorkerActivationTests.swift Sources/AnglesiteApp/DeployModel.swift
git commit -m "feat(conformance): surface WorkersConformanceStatus.gateStatus(.v3) as an advisory"
```

---

### Task 12: Leave a clear trail for the deferred canonicality snapshot (#362)

No code — this task exists so #362's implementer doesn't waste time before discovering the same D1-schema gap this plan's research surfaced (`@dwk/webmention`'s `createD1Inbox` stores only `{source, target, verifiedAt, rsvp?}`, not enough to populate a `ReceivedInteraction`).

- [ ] **Step 1: Comment on #362 with the finding**

Ask the user for explicit go-ahead before posting (per this repo's action-confirmation norms for public GitHub content), then run:

```bash
gh issue comment 362 --body "Investigated as part of #359's continuation (2026-07-21): \`@dwk/webmention\`'s \`createD1Inbox\` (dist/inbox.d.ts) stores only \`{source, target, verifiedAt, rsvp?}\` — no \`id\`, \`author\`, \`content\`, or \`interactionType\`. Populating \`ReceivedInteraction\` (Sources/AnglesiteCore/ReceivedInteraction.swift) needs microformats2 author/content enrichment that doesn't exist anywhere yet; \`verify.ts\`'s own doc comment says mf2 extraction is intentionally out of scope for the library. This issue's snapshot step likely needs either an enrichment pass added to \`@dwk/webmention\` (or a sibling package) before the D1→git sync can produce real records, or an explicit decision to snapshot degraded/anonymous stubs. Filed here rather than attempted under #359 to avoid shipping placeholder data."
```

- [ ] **Step 2: Update #359 to reflect the final scope**

Ask the user for go-ahead, then:

```bash
gh issue comment 359 --body "Provisioning (Queue + WEBMENTION_INBOX + SITE_URL, paid-plan opt-in), discovery (gated <link rel=\"webmention\">), and an advisory (non-blocking) WorkersConformanceStatus.gateStatus(.v3) surface have landed. Canonicality snapshot is deferred to #362 (see comment there) — the current @dwk/webmention D1 schema doesn't carry enough data to populate ReceivedInteraction. Conformance gating is deliberately advisory, not a hard block: conformance/status.json currently reports @dwk/webmention/@dwk/micropub/@dwk/websub all \"pending\", and a hard gate would have broken the already-shipped #887 receiver."
gh issue edit 359 --remove-label "🛠️ In Progress"
```

---

## Final verification

- [ ] Run the full Swift suite: `swift test --package-path .` — expect all green (including the pre-existing suites, confirming no regression).
- [ ] Run the template suite: `cd Resources/Template && npm run lint && npm run typecheck && npm test && npm run build`.
- [ ] `xcodegen generate` then `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` — confirm the app target builds with the new sheet view wired in.
- [ ] Re-read `CONTRIBUTING.md` ▸ "Commits and pull requests" immediately before opening the PR — use the exact `.github/PULL_REQUEST_TEMPLATE.md` headings (Summary / Paired PR check / Test plan), note this PR is self-contained (no paired sidecar-repo change — it only consumes the already-published `@dwk/webmention@0.1.0-beta.3`).

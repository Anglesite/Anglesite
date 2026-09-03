# Worker-name collision check at first deploy Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect a Worker-name collision against the connected Cloudflare account before a site's first deploy, and block with a rename-and-retry prompt instead of letting `wrangler deploy` silently take over an unrelated Worker.

**Architecture:** `DeployCommand` gains a pre-spawn check (right after the existing token gate) that lists the Cloudflare account's Worker script names and compares against `.site-config`'s `CF_PROJECT_NAME`, but only when `.site-config` has no `CF_WORKER_DEPLOYED` marker (i.e. this is the site's first deploy). A collision returns a new `Result.workerNameConflict(name:)` case. `DeployModel` parks the deploy (reusing its existing `pendingDeploy` field) and presents a new sheet; submitting a new name rewrites `wrangler.toml`'s `name` line and `.site-config`'s `CF_PROJECT_NAME` in place (no full regenerate, so provisioned social-feature config survives), then retries.

**Tech Stack:** Swift 6.4, Swift Testing (`@Test`/`#expect`), SwiftUI. No new dependencies.

## Global Constraints

- Design source of truth: [`docs/superpowers/specs/2026-07-16-worker-name-collision-check-design.md`](../specs/2026-07-16-worker-name-collision-check-design.md) — re-read it if a task here seems ambiguous.
- `swift test --package-path .` needs `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` in this environment (the default CommandLineTools `swift` is too old) — every test command below is prefixed with it. Drop the prefix if your environment's default toolchain is already Swift 6.4+.
- Conventional commits, referencing #740 in the subject, per `CONTRIBUTING.md`.
- No new third-party dependencies — everything here uses Foundation + existing in-repo seams (`CloudflareReading`, `SiteConfigFile`, `WorkerComposition`).
- A Cloudflare API failure during the collision check must never block a deploy that would otherwise succeed (fail open) — this invariant is load-bearing for every task that touches `checkWorkerNameConflict`.
- Every task's commit must leave the package building — a task that only adds a case to a public, non-frozen enum without updating every existing exhaustive `switch` over it is not done (this is why Task 3 below bundles the new `Result` case with the two switches it would otherwise break).

---

### Task 1: `CloudflareReading.workerScriptNames` + `HTTPCloudflareClient` implementation

**Files:**
- Modify: `Sources/AnglesiteCore/CloudflareReading.swift`
- Modify: `Sources/AnglesiteCore/HTTPCloudflareClient.swift`
- Modify: `Tests/AnglesiteCoreTests/DomainOperationsServiceTests.swift:107-132` (`FakeReader` — add stub conformance)
- Modify: `Tests/AnglesiteCoreTests/HardenExecutorTests.swift:111-130` (`MockCloudflareReader` — add stub conformance)
- Test: `Tests/AnglesiteCoreTests/CloudflareClientTests.swift`

**Interfaces:**
- Produces: `CloudflareReading.workerScriptNames(apiToken: String) async throws -> [String]` — every Worker script name visible to the token's first account. Throws `CloudflareError.api` (via `get`) if the token has no visible account, or any other `CloudflareError` case the existing `get`/`paginated` helpers already throw.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/CloudflareClientTests.swift` (after the existing `unauthorizedMaps` test, before its closing brace context — append as new top-level `@Test` functions in the same file):

```swift
@Test("workerScriptNames returns every script id across the account's first page")
func workerScriptNamesReturnsIds() async throws {
    let accountsJSON = #"{"success":true,"errors":[],"messages":[],"result":[{"id":"acct123"}]}"#
    let scriptsJSON = """
    {"success":true,"errors":[],"messages":[],"result":[{"id":"my-site"},{"id":"other-site"}],
     "result_info":{"page":1,"total_pages":1}}
    """
    let client = HTTPCloudflareClient(transport: fakeTransport([
        "/accounts?per_page=1": (200, accountsJSON),
        "/workers/scripts?per_page=100": (200, scriptsJSON),
    ]))
    let names = try await client.workerScriptNames(apiToken: "t")
    #expect(names == ["my-site", "other-site"])
}

@Test("workerScriptNames pages through more than 100 scripts")
func workerScriptNamesPaginates() async throws {
    let accountsJSON = #"{"success":true,"errors":[],"messages":[],"result":[{"id":"acct123"}]}"#
    let page1 = """
    {"success":true,"errors":[],"messages":[],"result":[{"id":"page1-site"}],
     "result_info":{"page":1,"total_pages":2}}
    """
    let page2 = """
    {"success":true,"errors":[],"messages":[],"result":[{"id":"page2-site"}],
     "result_info":{"page":2,"total_pages":2}}
    """
    let client = HTTPCloudflareClient(transport: { request in
        let url = request.url!.absoluteString
        let (status, body): (Int, String)
        if url.contains("/accounts?per_page=1") {
            (status, body) = (200, accountsJSON)
        } else if url.contains("page=2") {
            (status, body) = (200, page2)
        } else if url.contains("/workers/scripts?per_page=100") {
            (status, body) = (200, page1)
        } else {
            (status, body) = (404, "{\"success\":false}")
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), resp)
    })
    let names = try await client.workerScriptNames(apiToken: "t")
    #expect(names == ["page1-site", "page2-site"])
}

@Test("workerScriptNames throws when the token has no visible account")
func workerScriptNamesNoAccount() async {
    let emptyAccountsJSON = #"{"success":true,"errors":[],"messages":[],"result":[]}"#
    let client = HTTPCloudflareClient(transport: fakeTransport([
        "/accounts?per_page=1": (200, emptyAccountsJSON),
    ]))
    await #expect(throws: CloudflareError.self) {
        _ = try await client.workerScriptNames(apiToken: "t")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (compile error — method doesn't exist yet)**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter CloudflareClientTests`
Expected: FAIL — build error, `value of type 'HTTPCloudflareClient' has no member 'workerScriptNames'`.

- [ ] **Step 3: Add the protocol method**

In `Sources/AnglesiteCore/CloudflareReading.swift`, add to the `CloudflareReading` protocol (after `listDNSRecords`, before the closing `}` at line 47):

```swift
    /// Every Worker script name (the `id` field) visible to the token's first account. Used to
    /// detect a Worker-name collision before a site's first deploy (#740).
    func workerScriptNames(apiToken: String) async throws -> [String]
```

- [ ] **Step 4: Implement it in `HTTPCloudflareClient`**

In `Sources/AnglesiteCore/HTTPCloudflareClient.swift`, add a private decode struct near the other private structs (after `private struct CFFullDNSRecord`, around line 58):

```swift
private struct CFAccount: Decodable, Sendable { let id: String }
private struct CFWorkerScript: Decodable, Sendable { let id: String }
```

Then add the method to the `HTTPCloudflareClient` struct, after `listDNSRecords` (after line 268, before `// MARK: - Write helpers`):

```swift
    public func workerScriptNames(apiToken: String) async throws -> [String] {
        let accounts = try await get("/accounts?per_page=1", apiToken: apiToken, as: [CFAccount].self)
        guard let accountID = accounts.first?.id else {
            throw CloudflareError.api(message: "no Cloudflare account visible to this token")
        }
        let scripts = try await paginated(
            "/accounts/\(accountID)/workers/scripts?per_page=100", apiToken: apiToken, as: CFWorkerScript.self)
        return scripts.map(\.id)
    }
```

- [ ] **Step 5: Add stub conformance to the two existing test fakes**

In `Tests/AnglesiteCoreTests/DomainOperationsServiceTests.swift`, inside `final class FakeReader: CloudflareReading` (after the existing `listDNSRecords` method, around line 130):

```swift
    func workerScriptNames(apiToken: String) async throws -> [String] { [] }
```

In `Tests/AnglesiteCoreTests/HardenExecutorTests.swift`, inside `final class MockCloudflareReader: CloudflareReading` (after the existing `listDNSRecords` method, around line 130):

```swift
    func workerScriptNames(apiToken: String) async throws -> [String] { [] }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter CloudflareClientTests`
Expected: PASS (all 3 new tests, plus the existing ones in the file).

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DomainOperationsServiceTests`
Expected: PASS (confirms `FakeReader` still compiles/conforms).

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter HardenExecutorTests`
Expected: PASS (confirms `MockCloudflareReader` still compiles/conforms).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/CloudflareReading.swift Sources/AnglesiteCore/HTTPCloudflareClient.swift \
        Tests/AnglesiteCoreTests/CloudflareClientTests.swift \
        Tests/AnglesiteCoreTests/DomainOperationsServiceTests.swift \
        Tests/AnglesiteCoreTests/HardenExecutorTests.swift
git commit -m "feat(deploy): add CloudflareReading.workerScriptNames (#740)"
```

---

### Task 2: `DeployCommand` persists a `CF_WORKER_DEPLOYED` marker on success

**Files:**
- Modify: `Sources/AnglesiteCore/DeployCommand.swift`
- Test: `Tests/AnglesiteCoreTests/DeployCommandTests.swift`

**Interfaces:**
- Produces: `DeployCommand.persistWorkerDeployed(siteDirectory: URL)` — a `static func`, same visibility (`static`, not `public`) as the existing `persistSiteURL`, called from `deploy(...)`'s success path.
- Consumes: `WebsiteAnalyticsAsset.configRelativePath` (`.site-config`), `SiteConfigFile.upsert(_:into:)`, `SiteConfigFile.value(forKey:in:)` — all already exist.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/DeployCommandTests.swift`, in a new `// MARK: Worker-name collision (#740)` section (place it after the existing `// MARK: Wrangler failure surfacing` tests, i.e. after the `ignoresURLsBeforeAnchor` test around line 330):

```swift
    // MARK: Worker-name collision (#740)

    /// A fresh, empty subdirectory under the system temp dir — distinct from the shared `tmpDir`
    /// (which is the temp root itself, used elsewhere only as a `cd`-able path) because these
    /// tests write real `.site-config` contents that must not leak between test runs.
    private func makeSiteDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("A successful deploy writes CF_WORKER_DEPLOYED=true to .site-config")
    func successfulDeployMarksWorkerDeployed() async {
        let siteDir = makeSiteDirectory()
        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Published x (0.1 sec)\n  https://x.workers.dev")
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: exec)
        let result = await cmd.deploy(siteID: "s", siteDirectory: siteDir)
        guard case .succeeded = result else { Issue.record("expected .succeeded, got \(result)"); return }
        let config = (try? String(contentsOf: siteDir.appendingPathComponent(".site-config"), encoding: .utf8)) ?? ""
        #expect(SiteConfigFile.value(forKey: "CF_WORKER_DEPLOYED", in: config) == "true")
    }

    @Test("CF_WORKER_DEPLOYED is written even for a .transfer-domain site (where SITE_URL is not)")
    func workerDeployedMarkerNotConfoundedByCustomDomain() async {
        let siteDir = makeSiteDirectory()
        let configURL = siteDir.appendingPathComponent(".site-config")
        try? "DOMAIN=example.com\n".write(to: configURL, atomically: true, encoding: .utf8)
        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Published x (0.1 sec)\n  https://x.workers.dev")
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: exec)
        let result = await cmd.deploy(siteID: "s", siteDirectory: siteDir)
        guard case .succeeded = result else { Issue.record("expected .succeeded, got \(result)"); return }
        let config = try! String(contentsOf: configURL, encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "SITE_URL", in: config) == nil, "SITE_URL is skipped when DOMAIN is set")
        #expect(SiteConfigFile.value(forKey: "CF_WORKER_DEPLOYED", in: config) == "true", "but CF_WORKER_DEPLOYED must still be written")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DeployCommandTests`
Expected: FAIL — both new tests fail their `CF_WORKER_DEPLOYED` assertion (`nil` vs `"true"`), since nothing writes that key yet.

- [ ] **Step 3: Implement `persistWorkerDeployed` and call it on success**

In `Sources/AnglesiteCore/DeployCommand.swift`, add a new static method right after `persistSiteURL` (after line 262):

```swift
    /// Marks this site as having successfully deployed at least once, via `.site-config`'s
    /// `CF_WORKER_DEPLOYED` — the signal `checkWorkerNameConflict` uses to skip the collision
    /// check on every deploy after the first (#740). Written unconditionally, unlike
    /// `persistSiteURL` (which skips when a custom domain is already configured) — deploy
    /// history isn't confounded by domain choice. Best-effort, matching `persistSiteURL`.
    static func persistWorkerDeployed(siteDirectory: URL) {
        let configURL = siteDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard SiteConfigFile.value(forKey: "CF_WORKER_DEPLOYED", in: config) == nil else { return }
        let updated = SiteConfigFile.upsert([("CF_WORKER_DEPLOYED", "true")], into: config)
        try? updated.write(to: configURL, atomically: true, encoding: .utf8)
    }
```

Then call it right after `Self.persistSiteURL(url, siteDirectory: siteDirectory)` in the success branch (line 197):

```swift
                Self.persistSiteURL(url, siteDirectory: siteDirectory)
                Self.persistWorkerDeployed(siteDirectory: siteDirectory)
                return .succeeded(url: url, duration: duration)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DeployCommandTests`
Expected: PASS (all tests in the file, including the two new ones and all pre-existing ones — none of the existing tests write a `.site-config` file, so they're unaffected).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DeployCommand.swift Tests/AnglesiteCoreTests/DeployCommandTests.swift
git commit -m "feat(deploy): persist CF_WORKER_DEPLOYED marker on successful deploy (#740)"
```

---

### Task 3: `DeployCommand.Result.workerNameConflict`, the collision gate, and the two switches it breaks

This task bundles three things into one commit-worthy unit because they are not independently buildable: adding a case to a public `Result` enum without updating every existing exhaustive `switch` over it leaves the package in a state that will not compile (see this plan's Global Constraints).

**Files:**
- Modify: `Sources/AnglesiteCore/DeployCommand.swift`
- Modify: `Sources/AnglesiteCore/SiteOperations.swift:97-107`
- Modify: `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift:170-177`
- Test: `Tests/AnglesiteCoreTests/DeployCommandTests.swift`
- Test: `Tests/AnglesiteCoreTests/SiteOperationsTests.swift`
- Test: `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`

**Interfaces:**
- Consumes: `CloudflareReading.workerScriptNames` (Task 1), `SiteConfigFile.value(forKey:in:)`.
- Produces: `DeployCommand.Result.workerNameConflict(name: String)`; `DeployCommand.WorkerScriptNamesSource` typealias (`@Sendable (_ apiToken: String) async throws -> [String]`); `DeployCommand.init(tokenSource:workerScriptNamesSource:executor:)` (new middle parameter, defaulted — existing call sites using only `tokenSource:`/`executor:` labels are unaffected); `DeployCommand.defaultWorkerScriptNames: WorkerScriptNamesSource`. Also updates `SiteOperations.dialog(forDeploy:)` and `SocialWorkerProvisionCommand`'s `switch await deployer(...)` mapping to handle the new case.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/DeployCommandTests.swift`, in the `// MARK: Worker-name collision (#740)` section added in Task 2 (append after `workerDeployedMarkerNotConfoundedByCustomDomain`):

```swift
    /// Writes `.site-config` with the given `CF_PROJECT_NAME` and, if `deployedBefore`, a
    /// `CF_WORKER_DEPLOYED=true` marker — the two inputs `checkWorkerNameConflict` reads.
    private func makeSiteDirectory(projectName: String?, deployedBefore: Bool) -> URL {
        let dir = makeSiteDirectory()
        var lines: [String] = []
        if let projectName { lines.append("CF_PROJECT_NAME=\(projectName)") }
        if deployedBefore { lines.append("CF_WORKER_DEPLOYED=true") }
        if !lines.isEmpty {
            try? (lines.joined(separator: "\n") + "\n")
                .write(to: dir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test("First deploy with a name that already exists remotely returns .workerNameConflict before any step runs")
    func firstDeployNameTakenReturnsConflict() async {
        let siteDir = makeSiteDirectory(projectName: "taken-name", deployedBefore: false)
        let exec = FakeExecutor().onRun(.build, { Issue.record("build must not run on a worker-name conflict") })
        let cmd = DeployCommand(
            tokenSource: { "tok" },
            workerScriptNamesSource: { _ in ["taken-name", "other-site"] },
            executor: exec
        )
        let result = await cmd.deploy(siteID: "s", siteDirectory: siteDir)
        guard case .workerNameConflict(let name) = result else {
            Issue.record("expected .workerNameConflict, got \(result)"); return
        }
        #expect(name == "taken-name")
        #expect(!exec.ran(.build))
    }

    @Test("First deploy with a name that's free proceeds to build")
    func firstDeployNameFreeProceeds() async {
        let siteDir = makeSiteDirectory(projectName: "my-new-site", deployedBefore: false)
        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Published x (0.1 sec)\n  https://x.workers.dev")
        let cmd = DeployCommand(
            tokenSource: { "tok" },
            workerScriptNamesSource: { _ in ["some-other-site"] },
            executor: exec
        )
        let result = await cmd.deploy(siteID: "s", siteDirectory: siteDir)
        guard case .succeeded = result else { Issue.record("expected .succeeded, got \(result)"); return }
        #expect(exec.ran(.build))
    }

    @Test("No CF_PROJECT_NAME in .site-config skips the check entirely (fail open)")
    func noProjectNameSkipsCheck() async {
        let siteDir = makeSiteDirectory(projectName: nil, deployedBefore: false)
        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Published x (0.1 sec)\n  https://x.workers.dev")
        let cmd = DeployCommand(
            tokenSource: { "tok" },
            workerScriptNamesSource: { _ in Issue.record("must not be called when CF_PROJECT_NAME is absent"); return [] },
            executor: exec
        )
        let result = await cmd.deploy(siteID: "s", siteDirectory: siteDir)
        guard case .succeeded = result else { Issue.record("expected .succeeded, got \(result)"); return }
    }

    @Test("CF_WORKER_DEPLOYED already set skips the check regardless of remote state (no regression on redeploys)")
    func alreadyDeployedSkipsCheck() async {
        let siteDir = makeSiteDirectory(projectName: "my-site", deployedBefore: true)
        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Published x (0.1 sec)\n  https://x.workers.dev")
        let cmd = DeployCommand(
            tokenSource: { "tok" },
            // Even though the name is "taken" by this same call, a redeploy must not be blocked.
            workerScriptNamesSource: { _ in ["my-site"] },
            executor: exec
        )
        let result = await cmd.deploy(siteID: "s", siteDirectory: siteDir)
        guard case .succeeded = result else { Issue.record("expected .succeeded, got \(result)"); return }
    }

    @Test("A thrown error from workerScriptNamesSource fails open and proceeds to build")
    func availabilityCheckErrorFailsOpen() async {
        let siteDir = makeSiteDirectory(projectName: "my-new-site", deployedBefore: false)
        let exec = FakeExecutor()
            .set(.build, exitCode: 0, output: "")
            .set(.preflight, exitCode: 0, output: scanJSON(ok: true))
            .set(.wrangler, exitCode: 0, output: "Published x (0.1 sec)\n  https://x.workers.dev")
        let cmd = DeployCommand(
            tokenSource: { "tok" },
            workerScriptNamesSource: { _ in throw CloudflareError.http(status: 500) },
            executor: exec
        )
        let result = await cmd.deploy(siteID: "s", siteDirectory: siteDir)
        guard case .succeeded = result else { Issue.record("expected .succeeded (fail open), got \(result)"); return }
    }
```

Add to `Tests/AnglesiteCoreTests/SiteOperationsTests.swift`, right after the existing `deployFailureDialog` test (after line 131):

```swift
    @Test("deploy worker-name-conflict dialog names the taken Worker and asks for a rename")
    func deployWorkerNameConflictDialog() {
        let dialog = SiteOperations.dialog(forDeploy: .workerNameConflict(name: "taken-name"))
        #expect(dialog.contains("taken-name"))
        #expect(dialog.lowercased().contains("rename"))
    }
```

Add to `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`, following the exact pattern `provisionsV2Worker` (lines 7-41) already uses for its `WranglerRecorder`/`DeployRecorder` setup and its `private func temporaryDirectory() throws -> URL` helper (line 240) — add as its own new `@Test` inside `struct SocialWorkerProvisionCommandTests`, e.g. right after `deployFailureReportsResources`:

```swift
    @Test("a worker-name conflict from the deployer maps to a failed provisioning result")
    func workerNameConflictMapsToFailed() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([
            ["d1", "create", "my-site-social", "--json"]: .init(stdout: #"{"result":{"uuid":"d1-id"}}"#, stderr: "", exitCode: 0),
            ["kv", "namespace", "create", "my-site-social", "--json"]: .init(stdout: #"{"result":{"id":"kv-id"}}"#, stderr: "", exitCode: 0),
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"]: .init(stdout: "Migrations applied", stderr: "", exitCode: 0),
        ])
        let deployer = DeployRecorder(result: .workerNameConflict(name: "taken-name"))
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, runner: recorder.runner, deployer: deployer.deployer)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site")

        guard case .failed(let reason, _, _) = result else {
            Issue.record("expected .failed, got \(result)"); return
        }
        #expect(reason.contains("taken-name"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DeployCommandTests`
Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteOperationsTests`
Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: all three FAIL with the same underlying build error — `type 'DeployCommand.Result' has no member 'workerNameConflict'` — since none of the tests above can compile until Step 3 adds the case.

- [ ] **Step 3: Add the `Result` case, typealias, init parameter, and gating logic**

In `Sources/AnglesiteCore/DeployCommand.swift`, add the new case to `Result` (after `blocked`, before `failed`, around line 32):

```swift
        /// The candidate Worker name (`.site-config`'s `CF_PROJECT_NAME`) already exists on the
        /// connected Cloudflare account, and this site has never deployed before
        /// (`CF_WORKER_DEPLOYED` is not yet set in `.site-config`) — refusing to silently let
        /// `wrangler deploy` take over an unrelated (or stale) Worker. Carries the taken name for
        /// the UI's rename prompt (#740).
        case workerNameConflict(name: String)
```

Add the typealias after `PreflightObserver` (after line 58):

```swift
    /// Returns the account's existing Worker script names for the given token. Production
    /// callers use `DeployCommand.defaultWorkerScriptNames` (`HTTPCloudflareClient`); tests
    /// inject a fake list or a throwing closure.
    public typealias WorkerScriptNamesSource = @Sendable (_ apiToken: String) async throws -> [String]
```

Update the stored property and init (replace lines 60-69):

```swift
    public nonisolated let tokenSource: TokenSource
    private let workerScriptNamesSource: WorkerScriptNamesSource
    private let executor: any DeployExecutor

    public init(
        tokenSource: @escaping TokenSource = DeployCommand.keychainTokenSource,
        workerScriptNamesSource: @escaping WorkerScriptNamesSource = DeployCommand.defaultWorkerScriptNames,
        executor: any DeployExecutor = HostDeployExecutor()
    ) {
        self.tokenSource = tokenSource
        self.workerScriptNamesSource = workerScriptNamesSource
        self.executor = executor
    }
```

Insert the gate in `deploy(...)`, right after the existing token guard (after line 98, before the `baseEnvironment` comment):

```swift
        if let conflict = await Self.checkWorkerNameConflict(
            siteDirectory: siteDirectory, apiToken: token, workerScriptNamesSource: workerScriptNamesSource
        ) {
            return conflict
        }
```

Add the static helper near `persistWorkerDeployed` (after it, still before `// MARK: Host environment curation`):

```swift
    /// Checks whether `.site-config`'s `CF_PROJECT_NAME` collides with an existing Worker on the
    /// connected Cloudflare account, but only on a site's first deploy (`CF_WORKER_DEPLOYED` not
    /// yet set). Returns `.workerNameConflict` on a confirmed collision, or `nil` when the check
    /// doesn't apply (redeploy, no candidate name) or can't be confirmed — a Cloudflare API
    /// failure here must never block a deploy that would otherwise succeed (fail open).
    static func checkWorkerNameConflict(
        siteDirectory: URL,
        apiToken: String,
        workerScriptNamesSource: WorkerScriptNamesSource
    ) async -> Result? {
        let configURL = siteDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard SiteConfigFile.value(forKey: "CF_WORKER_DEPLOYED", in: config) == nil,
              let candidateName = SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config)
        else { return nil }
        guard let names = try? await workerScriptNamesSource(apiToken) else { return nil }
        guard names.contains(candidateName) else { return nil }
        return .workerNameConflict(name: candidateName)
    }
```

Add the default seam next to `keychainTokenSource` (after line 332, before `defaultPreflight`):

```swift
    /// Default `WorkerScriptNamesSource` for production: the account's Worker script names via
    /// `HTTPCloudflareClient`.
    public static let defaultWorkerScriptNames: WorkerScriptNamesSource = { apiToken in
        try await HTTPCloudflareClient().workerScriptNames(apiToken: apiToken)
    }
```

- [ ] **Step 4: Fix the two switches this case breaks**

In `Sources/AnglesiteCore/SiteOperations.swift`, update `dialog(forDeploy:)` (lines 97-107):

```swift
    public static func dialog(forDeploy result: DeployCommand.Result) -> String {
        switch result {
        case .succeeded(let url, _):
            return "Deployed to \(url.absoluteString)."
        case .blocked(let failures, _):
            let count = failures.count
            let noun = count == 1 ? "issue" : "issues"
            return "Deploy blocked by the pre-deploy security scan (\(count) \(noun)). Resolve these in Anglesite first."
        case .workerNameConflict(let name):
            return "Deploy blocked: the Worker name \"\(name)\" is already in use on your Cloudflare account. Rename the site's Worker in Anglesite and try again."
        case .failed(let reason, _):
            return "Deploy failed: \(reason)"
        }
    }
```

In `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift`, update the `switch await deployer(...)` block (lines 170-177):

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

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DeployCommandTests`
Expected: PASS (all tests in the file, including this task's five new ones).

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SiteOperationsTests`
Expected: PASS.

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/DeployCommand.swift Sources/AnglesiteCore/SiteOperations.swift \
        Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift \
        Tests/AnglesiteCoreTests/DeployCommandTests.swift Tests/AnglesiteCoreTests/SiteOperationsTests.swift \
        Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift
git commit -m "feat(deploy): add DeployCommand.Result.workerNameConflict and the collision gate (#740)"
```

---

### Task 4: `WorkerNameRename` — the rename-apply helper

**Files:**
- Create: `Sources/AnglesiteCore/WorkerNameRename.swift`
- Test: `Tests/AnglesiteCoreTests/WorkerNameRenameTests.swift`

**Interfaces:**
- Consumes: `WorkerComposition.isValidSiteName(_:)` (internal, same module), `SiteConfigFile.upsert(_:into:)`, `WebsiteAnalyticsAsset.configRelativePath`.
- Produces: `WorkerNameRename.apply(newName: String, siteDirectory: URL, fileManager: FileManager = .default) throws` and `WorkerNameRename.RenameError` (`.invalidName(String)`, `.wranglerConfigMissing`, `.nameLineNotFound`) — both `public`, consumed by `DeployModel` in Task 6.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/WorkerNameRenameTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct WorkerNameRenameTests {
    private func makeSiteDirectory(wranglerToml: String, siteConfig: String = "") -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! wranglerToml.write(to: dir.appendingPathComponent("wrangler.toml"), atomically: true, encoding: .utf8)
        if !siteConfig.isEmpty {
            try! siteConfig.write(to: dir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test("Rewrites only the name line, leaving the rest of wrangler.toml untouched")
    func rewritesNameLineOnly() throws {
        let toml = """
        name = "old-name"
        compatibility_date = "2026-07-15"
        compatibility_flags = ["nodejs_compat"]

        [assets]
        directory = "dist"
        """
        let dir = makeSiteDirectory(wranglerToml: toml, siteConfig: "CF_PROJECT_NAME=old-name\nSITE_NAME=My Site\n")

        try WorkerNameRename.apply(newName: "new-name", siteDirectory: dir)

        let updatedToml = try String(contentsOf: dir.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(updatedToml.contains(#"name = "new-name""#))
        #expect(updatedToml.contains(#"compatibility_date = "2026-07-15""#))
        #expect(updatedToml.contains("[assets]"))
    }

    @Test("Updates CF_PROJECT_NAME in .site-config without disturbing other keys")
    func updatesSiteConfig() throws {
        let dir = makeSiteDirectory(
            wranglerToml: #"name = "old-name""#,
            siteConfig: "CF_PROJECT_NAME=old-name\nSITE_NAME=My Site\n"
        )

        try WorkerNameRename.apply(newName: "new-name", siteDirectory: dir)

        let config = try String(contentsOf: dir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config) == "new-name")
        #expect(SiteConfigFile.value(forKey: "SITE_NAME", in: config) == "My Site")
    }

    @Test("Rejects an invalid name before touching any file")
    func rejectsInvalidName() throws {
        let dir = makeSiteDirectory(wranglerToml: #"name = "old-name""#, siteConfig: "CF_PROJECT_NAME=old-name\n")

        #expect(throws: WorkerNameRename.RenameError.invalidName("bad name!")) {
            try WorkerNameRename.apply(newName: "bad name!", siteDirectory: dir)
        }

        let toml = try String(contentsOf: dir.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains(#"name = "old-name""#), "wrangler.toml must be untouched on rejection")
    }

    @Test("Throws .wranglerConfigMissing when there's no wrangler.toml")
    func missingWranglerConfig() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        #expect(throws: WorkerNameRename.RenameError.wranglerConfigMissing) {
            try WorkerNameRename.apply(newName: "new-name", siteDirectory: dir)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter WorkerNameRenameTests`
Expected: FAIL — build error, no such type `WorkerNameRename`.

- [ ] **Step 3: Implement `WorkerNameRename`**

Create `Sources/AnglesiteCore/WorkerNameRename.swift`:

```swift
import Foundation

/// Applies a Worker-name change to an already-scaffolded site's `wrangler.toml` and
/// `.site-config`, after a Worker-name collision is detected at first deploy (#740).
///
/// Only the `name = "..."` line in `wrangler.toml` is rewritten — not a full regenerate via
/// `WorkerComposition.generateWranglerToml` — because there is no reader that reconstructs the
/// `[Feature]` list or provisioned D1/KV resource IDs from an already-written file, and a full
/// regenerate would silently drop any social-feature config a user provisioned (via
/// `SocialWorkerProvisionCommand`) before their first deploy.
public enum WorkerNameRename {
    public enum RenameError: Error, Equatable, Sendable {
        case invalidName(String)
        case wranglerConfigMissing
        case nameLineNotFound
    }

    /// Rewrites `wrangler.toml`'s `name = "..."` line and `.site-config`'s `CF_PROJECT_NAME` to
    /// `newName`. Throws `.invalidName` before touching any file if `newName` doesn't match
    /// `WorkerComposition`'s `[A-Za-z0-9_-]+` constraint, so a rejected name never gets partially
    /// written.
    public static func apply(newName: String, siteDirectory: URL, fileManager: FileManager = .default) throws {
        guard WorkerComposition.isValidSiteName(newName) else {
            throw RenameError.invalidName(newName)
        }

        let wranglerURL = siteDirectory.appendingPathComponent("wrangler.toml")
        guard fileManager.fileExists(atPath: wranglerURL.path) else {
            throw RenameError.wranglerConfigMissing
        }
        let toml = try String(contentsOf: wranglerURL, encoding: .utf8)
        var lines = toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let nameLineIndex = lines.firstIndex(where: { $0.hasPrefix("name = \"") }) else {
            throw RenameError.nameLineNotFound
        }
        lines[nameLineIndex] = "name = \"\(newName)\""
        try lines.joined(separator: "\n").write(to: wranglerURL, atomically: true, encoding: .utf8)

        let configURL = siteDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updated = SiteConfigFile.upsert([("CF_PROJECT_NAME", newName)], into: config)
        try updated.write(to: configURL, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter WorkerNameRenameTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WorkerNameRename.swift Tests/AnglesiteCoreTests/WorkerNameRenameTests.swift
git commit -m "feat(deploy): add WorkerNameRename helper for the collision rename flow (#740)"
```

---

### Task 5: `DeployModel` — `.workerNameConflict` phase and result routing

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift`
- Test: `Tests/AnglesiteAppTests/DeployModelTests.swift`

**Interfaces:**
- Consumes: `DeployCommand.Result.workerNameConflict(name:)` (Task 3).
- Produces: `DeployModel.Phase.workerNameConflict(name: String)`; `DeployModel.workerNameConflictPresented: Bool` (observable, bound to a `.sheet` in Task 7); reuses the existing `pendingDeploy` field (no type change).

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteAppTests/DeployModelTests.swift`, as a new `@Test` inside `struct DeployModelTests` (after `suddenTerminationLeaseBracketsDeploy`):

```swift
    @Test("A worker-name conflict parks the deploy and presents the conflict sheet")
    func workerNameConflictParksAndPresents() async {
        let executor = GatedDeployExecutor()
        // Never reached — the conflict short-circuits before the build step — but present so a
        // regression that skips the gate doesn't hang the test on the gated continuation.
        await executor.resumeBuild()
        let command = DeployCommand(
            tokenSource: { "test-token" },
            workerScriptNamesSource: { _ in ["my-site"] },
            executor: executor
        )
        let model = DeployModel(command: command, logCenter: LogCenter(), tokenAvailabilityOverride: { true })
        let siteDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: siteDir, withIntermediateDirectories: true)
        try! "CF_PROJECT_NAME=my-site\n".write(to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)

        model.deploy(siteID: "s", siteDirectory: siteDir, configDirectory: siteDir, currentRoutes: [])
        while model.isRunning { await Task.yield() }

        guard case .workerNameConflict(let name) = model.phase else {
            Issue.record("expected .workerNameConflict, got \(model.phase)"); return
        }
        #expect(name == "my-site")
        #expect(model.workerNameConflictPresented)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DeployModelTests`
Expected: FAIL — build error: `DeployModel.Phase` has no `.workerNameConflict` case and no `workerNameConflictPresented` property yet (`DeployCommand.init`'s `workerScriptNamesSource:` parameter already exists from Task 3).

- [ ] **Step 3: Add the `Phase` case, presented flag, and result routing**

In `Sources/AnglesiteApp/DeployModel.swift`, add the case to `Phase` (after `blocked`, around line 19):

```swift
        case workerNameConflict(name: String)
```

Add the presented flag near `blockedPresented` (after line 37):

```swift
    /// Bound to a `.sheet` in `SiteWindow` for the `.workerNameConflict` outcome — the Worker
    /// name is already taken on the connected Cloudflare account and this is the site's first
    /// deploy. Reuses `pendingDeploy` (below) to park and retry, same as the token-prompt flow.
    var workerNameConflictPresented: Bool = false
    /// Set when a rename attempt itself fails (invalid name, or no parked deploy). Cleared on
    /// every fresh presentation and on a successful rename-and-retry.
    private(set) var workerNameConflictError: String?
```

Update the doc comment on `pendingDeploy` to reflect the second consumer (it's currently just above the property, around line 86-88):

```swift
    /// Site to retry once the user takes the action a parked deploy is waiting on — either
    /// pasting a Cloudflare token (`verifyAndSaveToken`) or renaming a taken Worker name
    /// (`renameWorkerAndRetry`). `nil` outside both prompt flows. Carries the container control
    /// (if any) so the parked-then-retried deploy uses the same executor as the original dispatch.
```

Add the new case to `runDeploy`'s result switch (after the `.blocked` case, before the closing `}` of the switch — after line 411):

```swift
        case .workerNameConflict(let name):
            pendingDeploy = (siteID, siteDirectory, configDirectory, currentRoutes, containerControl)
            transition(siteID: siteID, to: .workerNameConflict(name: name))
            drawerPresented = false
            workerNameConflictError = nil
            workerNameConflictPresented = presentation == .foreground
```

Add the new case to `deployAutomatically`'s result switch (after `.blocked`, before `.failed`, around line 205):

```swift
        case .workerNameConflict(let name):
            return .failed(reason: "Worker name \"\(name)\" is already in use on your Cloudflare account — rename it in the app and deploy again.")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DeployModelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/DeployModel.swift Tests/AnglesiteAppTests/DeployModelTests.swift
git commit -m "feat(deploy): route DeployCommand.Result.workerNameConflict through DeployModel (#740)"
```

---

### Task 6: `DeployModel` — rename-and-retry / cancel methods

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift`
- Test: `Tests/AnglesiteAppTests/DeployModelTests.swift`

**Interfaces:**
- Consumes: `WorkerNameRename.apply(newName:siteDirectory:)` (Task 4).
- Produces: `DeployModel.renameWorkerAndRetry(_ newName: String) async`; `DeployModel.cancelWorkerNameConflictPrompt()` — both consumed by `WorkerNameConflictSheetView` in Task 7.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteAppTests/DeployModelTests.swift`, after `workerNameConflictParksAndPresents`:

```swift
    @Test("Renaming and retrying rewrites wrangler.toml/.site-config and re-deploys under the new name")
    func renameAndRetrySucceedsUnderNewName() async {
        let executor = GatedDeployExecutor()
        await executor.resumeBuild()
        let command = DeployCommand(
            tokenSource: { "test-token" },
            // "my-site" is taken; "my-site-2" (what the sheet will submit) is free.
            workerScriptNamesSource: { _ in ["my-site"] },
            executor: executor
        )
        let model = DeployModel(command: command, logCenter: LogCenter(), tokenAvailabilityOverride: { true })
        let siteDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: siteDir, withIntermediateDirectories: true)
        try! #"name = "my-site""#.write(to: siteDir.appendingPathComponent("wrangler.toml"), atomically: true, encoding: .utf8)
        try! "CF_PROJECT_NAME=my-site\n".write(to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)

        model.deploy(siteID: "s", siteDirectory: siteDir, configDirectory: siteDir, currentRoutes: [])
        while model.isRunning { await Task.yield() }
        guard case .workerNameConflict = model.phase else {
            Issue.record("expected .workerNameConflict before renaming, got \(model.phase)"); return
        }

        await model.renameWorkerAndRetry("my-site-2")
        while model.isRunning { await Task.yield() }

        guard case .succeeded = model.phase else {
            Issue.record("expected .succeeded after rename-and-retry, got \(model.phase)"); return
        }
        #expect(!model.workerNameConflictPresented)
        let toml = try! String(contentsOf: siteDir.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains(#"name = "my-site-2""#))
    }

    @Test("Cancelling the conflict prompt clears the parked deploy and dismisses the sheet")
    func cancelClearsPendingDeploy() async {
        let executor = GatedDeployExecutor()
        await executor.resumeBuild()
        let command = DeployCommand(
            tokenSource: { "test-token" },
            workerScriptNamesSource: { _ in ["my-site"] },
            executor: executor
        )
        let model = DeployModel(command: command, logCenter: LogCenter(), tokenAvailabilityOverride: { true })
        let siteDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: siteDir, withIntermediateDirectories: true)
        try! "CF_PROJECT_NAME=my-site\n".write(to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)

        model.deploy(siteID: "s", siteDirectory: siteDir, configDirectory: siteDir, currentRoutes: [])
        while model.isRunning { await Task.yield() }

        model.cancelWorkerNameConflictPrompt()

        #expect(!model.workerNameConflictPresented)
        // A subsequent rename attempt with nothing parked must fail gracefully, not crash.
        await model.renameWorkerAndRetry("anything")
        #expect(!model.isRunning)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DeployModelTests`
Expected: FAIL — build error, no `renameWorkerAndRetry`/`cancelWorkerNameConflictPrompt` methods yet.

- [ ] **Step 3: Implement the two methods**

In `Sources/AnglesiteApp/DeployModel.swift`, add after `cancelTokenPrompt()` (after line 257):

```swift
    /// Called by the worker-name-conflict sheet's "Rename & retry" button. Applies the rename to
    /// `wrangler.toml`/`.site-config` via `WorkerNameRename.apply`, then retries the parked
    /// deploy — which re-runs the collision check against the new name and loops back to this
    /// same sheet if it's also taken.
    func renameWorkerAndRetry(_ newName: String) async {
        guard let pending = pendingDeploy else {
            workerNameConflictError = "No deploy is waiting — close this and click Deploy again."
            return
        }
        do {
            try WorkerNameRename.apply(newName: newName, siteDirectory: pending.siteDirectory)
        } catch {
            workerNameConflictError = "Couldn't rename the Worker: \(error)"
            return
        }
        pendingDeploy = nil
        workerNameConflictPresented = false
        workerNameConflictError = nil
        deploy(
            siteID: pending.siteID, siteDirectory: pending.siteDirectory,
            configDirectory: pending.configDirectory, currentRoutes: pending.currentRoutes,
            containerControl: pending.containerControl)
    }

    func cancelWorkerNameConflictPrompt() {
        pendingDeploy = nil
        workerNameConflictPresented = false
        workerNameConflictError = nil
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DeployModelTests`
Expected: PASS (all `DeployModelTests`, including Task 5's test).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/DeployModel.swift Tests/AnglesiteAppTests/DeployModelTests.swift
git commit -m "feat(deploy): add DeployModel.renameWorkerAndRetry/cancelWorkerNameConflictPrompt (#740)"
```

---

### Task 7: The rename sheet UI and its wiring into `SiteWindow`

**Files:**
- Create: `Sources/AnglesiteApp/WorkerNameConflictSheetView.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:491-502`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift:1450-1480`

**Interfaces:**
- Consumes: `DeployModel.workerNameConflictPresented`, `DeployModel.workerNameConflictError`, `DeployModel.renameWorkerAndRetry(_:)`, `DeployModel.cancelWorkerNameConflictPrompt()` (Tasks 5–6), `DeployModel.Phase.workerNameConflict(name:)` (Task 5).

This task is SwiftUI-only (mirrors `CloudflareTokenPromptView`, which has no dedicated test file in this codebase) — verified by building the app target and a manual smoke check, not a Swift Testing suite.

- [ ] **Step 1: Create the sheet view**

Create `Sources/AnglesiteApp/WorkerNameConflictSheetView.swift`:

```swift
import SwiftUI
import AnglesiteCore

/// Sheet shown when `DeployCommand` detects that this site's Worker name already exists on the
/// connected Cloudflare account, and this site has never deployed before (#740) — refusing to
/// silently let `wrangler deploy` take over an unrelated (or stale) Worker. Offers a text field
/// to pick a different name, prefilled with a `<name>-2` suggestion, then retries the deploy.
struct WorkerNameConflictSheetView: View {
    let model: DeployModel
    let takenName: String
    let onCancel: () -> Void

    @State private var newName: String = ""
    @FocusState private var fieldFocused: Bool

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedName.isEmpty && trimmedName != takenName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Worker name already in use")
                    .font(.headline)
                Text("“\(takenName)” already exists on your connected Cloudflare account. Choose a different name to deploy this site under.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Worker name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { submit() }

            if let error = model.workerNameConflictError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename & retry") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            newName = "\(takenName)-2"
            fieldFocused = true
        }
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await model.renameWorkerAndRetry(trimmedName) }
    }
}

#Preview {
    WorkerNameConflictSheetView(model: DeployModel(), takenName: "my-site", onCancel: {})
}
```

- [ ] **Step 2: Wire the sheet into `SiteWindow`**

In `Sources/AnglesiteApp/SiteWindow.swift`, add a new `.sheet` modifier right after the existing `tokenPromptPresented` one (after line 502):

```swift
        .sheet(isPresented: $bindableModel.deploy.workerNameConflictPresented) {
            if case .workerNameConflict(let name) = model.deploy.phase {
                WorkerNameConflictSheetView(model: model.deploy, takenName: name) {
                    model.deploy.cancelWorkerNameConflictPrompt()
                }
            }
        }
```

- [ ] **Step 3: Handle the new `Phase` case in `SiteWindowModel`'s dock/notification switch**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, the `deploy.onPhaseTransition` closure's `switch phase` (around lines 1452-1479) is exhaustive over `DeployModel.Phase` and will now fail to compile. Add a case after `.blocked` (after line 1479, before the closing `}` of the switch):

```swift
            case .workerNameConflict(let name):
                // The sheet (SiteWindow) carries the actionable rename UI; the Dock tile and a
                // completion notice both clear/fire the same way a plain failure would — there's
                // no separate "conflict" notification affordance.
                DockProgressController.shared.clear(token: dockToken)
                Self.postNotice(siteID: siteID) { siteName in
                    CompletionNoticeBuilder.deploy(
                        siteName: siteName, siteID: siteID,
                        outcome: .failed(reason: "Worker name \"\(name)\" is already in use — rename it to continue.")
                    )
                }
```

- [ ] **Step 4: Build the app target to verify everything compiles**

Run: `xcodegen generate` (only if `Anglesite.xcodeproj` is missing or stale in this worktree)
Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual smoke check**

Launch the app (`open Anglesite.xcodeproj`, run the `Anglesite` scheme), scaffold a new site, and deploy it twice under the same site name from two different local `.anglesite` packages sharing one Cloudflare account (or, faster: manually set `.site-config`'s `CF_PROJECT_NAME` to a Worker name you know already exists on your connected account, and confirm `CF_WORKER_DEPLOYED` is absent) — confirm:
- The rename sheet appears with the taken name.
- Submitting a new name rewrites `wrangler.toml`'s `name` line and `.site-config`'s `CF_PROJECT_NAME`, and the deploy proceeds.
- Cancelling closes the sheet with no changes to either file.

- [ ] **Step 6: Run the full test suite one more time**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: PASS — every `AnglesiteCoreTests`, `AnglesiteAppTests` (and other) target passes, confirming nothing in this plan regressed an unrelated suite.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/WorkerNameConflictSheetView.swift Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/SiteWindowModel.swift
git commit -m "feat(deploy): add the Worker-name conflict rename sheet and wire it into SiteWindow (#740)"
```

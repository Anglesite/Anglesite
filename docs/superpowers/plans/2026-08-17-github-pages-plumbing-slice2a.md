# GitHub Pages Plumbing (Slice 2a) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the executor/config/API-client plumbing a future `GitHubPagesDeployTarget` needs — a new `DeployStep.githubPagesPublish` case, an `HTTPGitHubClient.enablePages` method, and a new `anglesite.json` `githubPages` section — with zero behavior change (nothing calls any of it yet).

**Architecture:** `dist/` only ever exists inside the container guest's filesystem (`/workspace/site/dist`), never synced to the host, so a GitHub Pages publish step must run in-guest too, exactly like Cloudflare's `.wrangler` step does. This plan extends `DeployStep`/`ContainerDeployExecutor`/`HostDeployExecutor` with a new case that force-pushes `dist/` as a single fresh commit to a dedicated public GitHub repo (read from a new `anglesite.json` section), adds the GitHub API method to enable Pages on that repo, and leaves both fully unwired — no `DeployTarget` conformer calls them yet.

**Tech Stack:** Swift 6.4, Swift Testing (`@Test`/`#expect`), SwiftPM (`swift test --package-path .`).

## Global Constraints

- Zero behavior change: nothing in this slice is called by any existing code path. Every currently-passing test must keep passing unchanged in behavior (only compile-time fixups for the new `DeployStep` case are expected).
- Publish mechanism: each deploy does a **fresh, force-pushed commit** to the dedicated repo's `main` branch — `git init` a throwaway repo directly in `dist/`, one commit, force-push. No incremental history.
- The GitHub token for this step is never a shell argument and never logged — it crosses the host→guest boundary only via an environment variable (`GITHUB_PAGES_TOKEN`), mirroring `CLOUDFLARE_API_TOKEN`.
- Owner and repo values (read from `anglesite.json`, potentially attacker/owner-controlled content) are passed to the guest shell script only as **positional parameters** (`$1`/`$2`), never spliced into script text — mirroring `.bundleUpload`'s injection-safety pattern for `CF_SOURCE_BUCKET`.
- Commit subject ≤ 72 characters; reference `#1015`; conventional-commit format (`feat(#1015): …`).
- Run `swift test --package-path .` before considering any task done.

---

### Task 1: Add `githubPages` to `anglesite.json` (`DomainConfig`)

**Files:**
- Modify: `Sources/AnglesiteCore/DomainConfig.swift:15-47` (properties + init), `Sources/AnglesiteCore/DomainConfig.swift:159-178` (add the `GitHubPages` struct, after `Email`), `Sources/AnglesiteCore/DomainConfig.swift:180-206` (Codable conformance)
- Test: `Tests/AnglesiteCoreTests/DomainConfigStoreTests.swift:22-53`

**Interfaces:**
- Produces: `DomainConfig.githubPages: GitHubPages?`; `DomainConfig.GitHubPages` — `public struct GitHubPages: Codable, Equatable, Sendable { public var owner: String?; public var repo: String? }`. Round-tripped by `DomainConfigStore` like every other field. Not consumed by anything until Task 2.

- [ ] **Step 1: Update the failing-first test — add `githubPages` to the comprehensive round-trip test**

In `Tests/AnglesiteCoreTests/DomainConfigStoreTests.swift`, change the `saveLoadRoundTrips` test (lines 22-53) so the constructed `DomainConfig` also sets `githubPages`:

```swift
    @Test("save then load round-trips a fully populated config")
    func saveLoadRoundTrips() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DomainConfigStore(sourceDirectory: dir)
        let config = DomainConfig(
            version: 1,
            domain: .init(
                hostname: "example.com", choice: "transfer", attach: true,
                registrar: "Example Registrar, LLC", expiresAt: "2027-08-13T04:00:00Z"),
            dns: .init(managedRecords: [
                .init(type: "MX", name: "@", content: "mx01.mail.icloud.com", priority: 10, purpose: "email:icloud"),
            ]),
            edge: .init(
                dnssec: true,
                alwaysUseHTTPS: true,
                hsts: .init(maxAge: 31536000, includeSubdomains: true, preload: false),
                cloudflare: .init(botFightMode: true, wafRules: [
                    .init(description: "Block bad bots", expression: "cf.client.bot", action: "block"),
                ])
            ),
            email: .init(provider: "icloud", dmarcReportEmail: "postmaster@example.com"),
            workers: .init(active: ["webmention-receive", "micropub"]),
            deployTarget: "cloudflare",
            githubPages: .init(owner: "example-owner", repo: "example-site-pages")
        )
        try store.save(config)
        let fileURL = dir.appendingPathComponent("anglesite.json")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try store.load() == config)
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(contents.hasSuffix("\n"), "anglesite.json should end with a trailing newline")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --filter DomainConfigStoreTests/saveLoadRoundTrips`
Expected: FAIL — `DomainConfig(... githubPages: .init(...))` doesn't compile yet (`extra argument 'githubPages' in call`, and `GitHubPages` doesn't exist).

- [ ] **Step 3: Add the `GitHubPages` struct, the `githubPages` property, and the memberwise init parameter**

In `Sources/AnglesiteCore/DomainConfig.swift`, replace lines 15-47 (the properties + init):

```swift
public struct DomainConfig: Equatable, Sendable {
    /// The schema version. Always written; tolerated as absent on read (defaults to `1`) so a
    /// file hand-authored before this field existed still loads.
    public var version: Int
    public var domain: Domain?
    public var dns: DNS?
    public var edge: Edge?
    public var email: Email?
    public var workers: Workers?
    /// The publish destination this site uses (#1015) — an open string (not a closed `enum`),
    /// matching `Domain.choice`'s precedent, so an unrecognized future value degrades gracefully
    /// for a reader that predates it. `nil` means "cloudflare," the only target that exists today
    /// — nothing reads this field to select a `DeployTarget` conformer yet (that's a later
    /// slice); it exists so that slice needs no schema migration when it lands.
    public var deployTarget: String?
    /// The dedicated public repo a `GitHubPagesDeployTarget` publishes built output to (#1015
    /// slice 2a) — always a separate repo from wherever `Source/` itself might be backed up, so
    /// choosing GitHub Pages never forces the site's source history public. `nil` until a
    /// GitHub Pages deploy target has created (or been pointed at) one.
    public var githubPages: GitHubPages?

    public init(
        version: Int = 1,
        domain: Domain? = nil,
        dns: DNS? = nil,
        edge: Edge? = nil,
        email: Email? = nil,
        workers: Workers? = nil,
        deployTarget: String? = nil,
        githubPages: GitHubPages? = nil
    ) {
        self.version = version
        self.domain = domain
        self.dns = dns
        self.edge = edge
        self.email = email
        self.workers = workers
        self.deployTarget = deployTarget
        self.githubPages = githubPages
    }
```

- [ ] **Step 4: Add the `GitHubPages` struct definition**

In the same file, add this new struct after the closing brace of `Email` (after line 167, before the `Workers` struct at line 169):

```swift
    /// The dedicated public repo backing a GitHub Pages deploy target (#1015 slice 2a). Never the
    /// same repo as any `Source/` backup — see the field-level doc comment on `DomainConfig
    /// .githubPages` above for why.
    public struct GitHubPages: Codable, Equatable, Sendable {
        public var owner: String?
        public var repo: String?

        public init(owner: String? = nil, repo: String? = nil) {
            self.owner = owner
            self.repo = repo
        }
    }
```

- [ ] **Step 5: Add `githubPages` to the manual `Codable` conformance**

In the same file, replace the `Codable` extension (now at approximately lines 190-217 after Steps 3-4's insertions — locate it by its `CodingKeys` enum):

```swift
extension DomainConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, domain, dns, edge, email, workers, deployTarget, githubPages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        domain = try container.decodeIfPresent(Domain.self, forKey: .domain)
        dns = try container.decodeIfPresent(DNS.self, forKey: .dns)
        edge = try container.decodeIfPresent(Edge.self, forKey: .edge)
        email = try container.decodeIfPresent(Email.self, forKey: .email)
        workers = try container.decodeIfPresent(Workers.self, forKey: .workers)
        deployTarget = try container.decodeIfPresent(String.self, forKey: .deployTarget)
        githubPages = try container.decodeIfPresent(GitHubPages.self, forKey: .githubPages)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(domain, forKey: .domain)
        try container.encodeIfPresent(dns, forKey: .dns)
        try container.encodeIfPresent(edge, forKey: .edge)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(workers, forKey: .workers)
        try container.encodeIfPresent(deployTarget, forKey: .deployTarget)
        try container.encodeIfPresent(githubPages, forKey: .githubPages)
    }
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `swift test --package-path . --filter DomainConfigStoreTests`
Expected: PASS (all `DomainConfigStoreTests` cases, including `saveLoadRoundTrips`).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/DomainConfig.swift Tests/AnglesiteCoreTests/DomainConfigStoreTests.swift
git commit -m "feat(#1015): add githubPages field to anglesite.json"
```

---

### Task 2: Add `DeployStep.githubPagesPublish` and wire it through both executors

**Files:**
- Modify: `Sources/AnglesiteCore/DeployExecutor.swift:6-18` (`DeployStep`), `:348-352` (`guestEnvAllowlist`), `:371-399` (`ContainerDeployExecutor.guestArgv`, plus a new private helper), `:533-544` (`HostDeployExecutor.defaultResolver`)
- Modify (compile fixups — exhaustive `switch`/`case` over `DeployStep`): `Tests/AnglesiteCoreTests/DeployCommandTests.swift:40-47` (`FakeExecutor.key`), `:979-992` (`hostExecutorParity`), `:1011-1024` (`hostExecutorPassesToken`), `:1059-1072` (`cancellationTerminatesWrangler`); `Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift:22-35` (`BlockingPreflightExecutor`); `Tests/AnglesiteAppTests/DeployModelTests.swift:7-33` (`GatedDeployExecutor`)
- Modify: `Tests/AnglesiteCoreTests/DeployExecutorTests.swift:121-133` (`defaultResolverUnavailable`)
- Modify: `Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift:71-72` (insert new tests between the existing argv-mapping section and the cwd section)

**Interfaces:**
- Consumes: `DomainConfig.githubPages` / `DomainConfigStore` (Task 1).
- Produces: `DeployStep.githubPagesPublish` — a new case on the existing public enum. No other type changes; every consumer of `DeployStep` just needs one more `case` arm.

This task is one atomic change: Swift's exhaustiveness checking means adding a case to `DeployStep` breaks compilation everywhere the enum is switched over, until every site is updated. Steps 1-3 add the case and its real implementation; Step 4 deliberately confirms the resulting build breakage (that breakage **is** this task's "red" — a statically-typed exhaustive enum has no way to fail one test at a time here); Step 5 fixes every other broken site; Step 6 confirms the package builds; Steps 7-9 add and run the new tests that actually exercise the new step's behavior.

- [ ] **Step 1: Add the `DeployStep` case**

In `Sources/AnglesiteCore/DeployExecutor.swift`, replace the `DeployStep` enum (lines 6-18):

```swift
public enum DeployStep: Sendable {
    /// `npm run build` — produces `dist/`.
    case build
    /// `npx tsx scripts/pre-deploy-check.ts --json` — the bundled plugin's security scan.
    case preflight
    /// `wrangler deploy` — publishes the built site to Cloudflare Workers.
    case wrangler
    /// Tars `Source/` and uploads it to the site's configured R2 bucket via `wrangler r2 object
    /// put` — the code side of a future Worker-triggered bake (#799, spec §C.4). Only reached
    /// when `.site-config`'s `CF_SOURCE_BUCKET` is set; `DeployCommand.deploy` skips this step
    /// entirely otherwise (today, for every site — no provisioning flow writes that key yet).
    case bundleUpload
    /// Force-pushes the built `dist/` to the site's dedicated GitHub Pages repo (#1015 slice 2a),
    /// declared in `Source/anglesite.json`'s `githubPages` section. Only meaningful for
    /// `ContainerDeployExecutor` — `dist/` lives in the guest's filesystem, never synced to the
    /// host, so this step (like `.wrangler`) must run in-guest. Not yet reached by any
    /// `DeployTarget` — the conformer that calls it is a later slice.
    case githubPagesPublish
}
```

- [ ] **Step 2: Add the guest argv case, its owner/repo helper, and the token env allowlist entry**

In the same file, add `"GITHUB_PAGES_TOKEN"` to `guestEnvAllowlist` (line 348):

```swift
    private static let guestEnvAllowlist: Set<String> = ["CLOUDFLARE_API_TOKEN", "GITHUB_PAGES_TOKEN"]
```

Then, in `guestArgv(for:siteDirectory:)` (the `switch step` starting at line 371), add a new case after `.bundleUpload`'s:

```swift
        case .githubPagesPublish:
            guard let (owner, repo) = githubPagesRepo(siteDirectory: siteDirectory) else {
                return ["sh", "-c", "echo 'GitHub Pages repo is not configured in anglesite.json' >&2; exit 1"]
            }
            // Fresh, force-pushed commit each deploy (#1015 slice 2a design decision) — no
            // incremental history, matching how the ecosystem's gh-pages tool and
            // peaceiris/actions-gh-pages both work by default. `owner`/`repo` come from
            // anglesite.json — attacker/owner-controlled content that must never be spliced into
            // shell script text. Instead of interpolating them, the script references them only
            // via `$1`/`$2`, POSITIONAL shell parameters, the same injection-safety pattern
            // `.bundleUpload` uses for CF_SOURCE_BUCKET above. The token crosses the host→guest
            // boundary only via `$GITHUB_PAGES_TOKEN` (an environment variable, never a shell
            // argument, never logged) — see `guestEnvAllowlist`.
            return [
                "sh", "-c",
                "cd dist && git init -q && git checkout -q -b main && git add -A && " +
                "git -c user.email=deploy@anglesite.app -c user.name=Anglesite commit -q -m Deploy && " +
                "git push -q --force \"https://x-access-token:$GITHUB_PAGES_TOKEN@github.com/$1/$2.git\" HEAD:main",
                "sh", owner, repo
            ]
```

Then add this private helper near `bundleUploadBucket(siteDirectory:)` (after its closing brace, around line 408):

```swift
    /// Reads `Source/anglesite.json`'s `githubPages.owner`/`.repo` from the HOST `siteDirectory`
    /// (the guest's copy is a clone of the same repo, so the value is identical) — `nil` when
    /// either is unset, mirroring `bundleUploadBucket`'s "not configured" precedent. Unlike
    /// `.bundleUpload` (where "not configured" means `DeployCommand.deploy` skips the step
    /// entirely before it ever reaches the executor), a `.githubPagesPublish` step that's reached
    /// with no configured repo is a real misconfiguration — the caller above returns a script
    /// that fails loudly instead of silently pushing to a malformed URL.
    private static func githubPagesRepo(siteDirectory: URL) -> (owner: String, repo: String)? {
        guard let config = try? DomainConfigStore(sourceDirectory: siteDirectory).load(),
              let owner = config.githubPages?.owner, !owner.isEmpty,
              let repo = config.githubPages?.repo, !repo.isEmpty
        else { return nil }
        return (owner, repo)
    }
```

- [ ] **Step 3: Add the `HostDeployExecutor` resolver arm**

In the same file, in `HostDeployExecutor.defaultResolver` (the `switch step` starting at line 533), add a new case after `.bundleUpload`'s:

```swift
        case .githubPagesPublish:
            return { _ in .unavailable(reason: HostNodeRetirement.reason("GitHub Pages publish")) }
```

- [ ] **Step 4: Confirm the build now fails everywhere `DeployStep` is switched over exhaustively**

Run: `swift build --package-path . --target AnglesiteCore`
Expected: FAIL. The compiler reports non-exhaustive `switch` errors (missing case `.githubPagesPublish`) at:
- `Tests/AnglesiteCoreTests/DeployCommandTests.swift:40` (`FakeExecutor.key`)
- `Tests/AnglesiteCoreTests/DeployCommandTests.swift:979` (`hostExecutorParity`'s inline resolver)
- `Tests/AnglesiteCoreTests/DeployCommandTests.swift:1011` (`hostExecutorPassesToken`'s inline resolver)
- `Tests/AnglesiteCoreTests/DeployCommandTests.swift:1059` (`cancellationTerminatesWrangler`'s inline resolver)
- `Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift:23` (`BlockingPreflightExecutor.run`)
- `Tests/AnglesiteAppTests/DeployModelTests.swift:16` (`GatedDeployExecutor.run`)

(`swift build --target AnglesiteCore` alone won't compile the `Tests/` targets — run `swift build --package-path . --build-tests` or simply proceed to `swift test --package-path .` to see all six errors at once; either way, expect a non-zero exit before Step 5.)

- [ ] **Step 5: Fix every other exhaustive `switch`/`case` over `DeployStep`**

In `Tests/AnglesiteCoreTests/DeployCommandTests.swift`, `FakeExecutor.key(_:)` (lines 40-47), add a case after `.bundleUpload`'s:

```swift
        private func key(_ step: DeployStep) -> String {
            switch step {
            case .build: return "build"
            case .preflight: return "preflight"
            case .wrangler: return "wrangler"
            case .bundleUpload: return "bundleUpload"
            case .githubPagesPublish: return "githubPagesPublish"
            }
        }
```

In the same file, three more tests each have an inline `resolveCommand` closure with an exhaustive `switch step`. Add a `case .githubPagesPublish: return .unavailable(reason: "not exercised in this test")` arm to each, immediately after that closure's existing `case .bundleUpload` arm.

`hostExecutorParity` (around line 979) — its closure becomes:

```swift
            resolveCommand: { step in
                { _ in
                    switch step {
                    case .build:
                        return .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo building; exit 0"])
                    case .preflight:
                        return .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"echo '{"version":1,"ok":true,"failures":[],"warnings":[]}'; exit 0"#])
                    case .wrangler:
                        return .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo 'Published angle-app (1.23 sec)'; echo '  https://angle-app.example.workers.dev'; exit 0"])
                    case .bundleUpload:
                        return .unavailable(reason: "not exercised in this test")
                    case .githubPagesPublish:
                        return .unavailable(reason: "not exercised in this test")
                    }
                }
            }
```

`hostExecutorPassesToken` (around line 1011) — its closure becomes:

```swift
            resolveCommand: { step in
                { _ in
                    switch step {
                    case .build:
                        return .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
                    case .preflight:
                        return .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"echo '{"version":1,"ok":true,"failures":[],"warnings":[]}'"#])
                    case .wrangler:
                        return .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo \"TOKEN=$CLOUDFLARE_API_TOKEN\"; echo 'Published x (0.1 sec)'; echo '  https://x.workers.dev'"])
                    case .bundleUpload:
                        return .unavailable(reason: "not exercised in this test")
                    case .githubPagesPublish:
                        return .unavailable(reason: "not exercised in this test")
                    }
                }
            }
```

`cancellationTerminatesWrangler` (around line 1059) — its closure becomes:

```swift
            resolveCommand: { step in
                { _ in
                    switch step {
                    case .build:
                        return .run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
                    case .preflight:
                        return .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"echo '{"version":1,"ok":true,"failures":[],"warnings":[]}'"#])
                    case .wrangler:
                        return .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap 'echo __SIGTERM__; exit 143' TERM; echo __STARTED__; sleep 20; echo __COMPLETED__"])
                    case .bundleUpload:
                        return .unavailable(reason: "not exercised in this test")
                    case .githubPagesPublish:
                        return .unavailable(reason: "not exercised in this test")
                    }
                }
            }
```

In `Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift`, `BlockingPreflightExecutor.run` (lines 22-35), add a case after `.bundleUpload`'s:

```swift
private struct BlockingPreflightExecutor: DeployExecutor {
    func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult {
        switch step {
        case .build:
            return DeployStepResult(exitCode: 0, output: "")
        case .preflight:
            return DeployStepResult(exitCode: 0, output: #"{"version":1,"ok":false,"failures":[],"warnings":[]}"#)
        case .wrangler:
            return DeployStepResult(exitCode: 0, output: "")
        case .bundleUpload:
            return DeployStepResult(exitCode: 0, output: "")
        case .githubPagesPublish:
            return DeployStepResult(exitCode: 0, output: "")
        }
    }
}
```

In `Tests/AnglesiteAppTests/DeployModelTests.swift`, `GatedDeployExecutor.run` (lines 10-33), add a case after `.bundleUpload`'s:

```swift
    func run(
        step: DeployStep,
        siteDirectory: URL,
        environment: [String: String],
        source: String
    ) async -> DeployStepResult {
        switch step {
        case .build:
            await withCheckedContinuation { buildContinuation = $0 }
            return DeployStepResult(exitCode: 0, output: "")
        case .preflight:
            return DeployStepResult(
                exitCode: 0,
                output: #"{"version":1,"ok":true,"failures":[],"warnings":[]}"#
            )
        case .wrangler:
            return DeployStepResult(
                exitCode: 0,
                output: "Published test (0.1 sec)\n  https://test.example.workers.dev"
            )
        case .bundleUpload:
            return DeployStepResult(exitCode: 0, output: "")
        case .githubPagesPublish:
            return DeployStepResult(exitCode: 0, output: "")
        }
    }
```

- [ ] **Step 6: Confirm the package builds cleanly**

Run: `swift build --package-path . --target AnglesiteCore`
Expected: SUCCEED.

Run: `swift test --package-path . --filter DeployCommandTests --filter DeployCommandProgressTests`
Expected: every pre-existing test in both suites still PASSes (same behavior as before — these edits only restore exhaustiveness, they don't change what any existing test observes).

- [ ] **Step 7: Add the new `.githubPagesPublish` argv/injection/token tests**

In `Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift`, insert this new section between the end of the existing `preflightArgv` test (line 71, the closing `}`) and the `// MARK: - cwd is always /workspace/site` comment (line 73):

```swift

    // MARK: - .githubPagesPublish argv (#1015 slice 2a)

    /// A fresh host site directory with `anglesite.json` declaring the given GitHub Pages
    /// owner/repo — mirrors `DeployCommandTests`'s `makeSiteDirectory(...)` helpers for the
    /// Cloudflare-specific config it reads the same way.
    private func makeSiteDirectory(githubPagesOwner owner: String, repo: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = DomainConfig()
        config.githubPages = .init(owner: owner, repo: repo)
        try DomainConfigStore(sourceDirectory: dir).save(config)
        return dir
    }

    @Test("ContainerDeployExecutor maps .githubPagesPublish to a git-push argv naming the configured owner/repo")
    func githubPagesPublishArgvNamesConfiguredRepo() throws {
        let siteDir = try makeSiteDirectory(githubPagesOwner: "acme", repo: "my-site-pages")
        defer { try? FileManager.default.removeItem(at: siteDir) }

        let argv = ContainerDeployExecutorTestHook.guestArgv(for: .githubPagesPublish, siteDirectory: siteDir)
        // Owner and repo must be separate positional argv elements (passed as `$1`/`$2` to `sh
        // -c`), not interpolated into the script text — that's what makes it injection-safe (see
        // the adjoining injection test).
        #expect(argv.contains("acme"))
        #expect(argv.contains("my-site-pages"))
        #expect(argv.contains { $0.contains("git push") })
        #expect(argv.contains { $0.contains("$GITHUB_PAGES_TOKEN") })
    }

    @Test("ContainerDeployExecutor's .githubPagesPublish argv fails loudly when anglesite.json has no githubPages section")
    func githubPagesPublishArgvFailsWithoutConfig() throws {
        let siteDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: siteDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: siteDir) }

        let argv = ContainerDeployExecutorTestHook.guestArgv(for: .githubPagesPublish, siteDirectory: siteDir)
        #expect(argv.contains { $0.contains("exit 1") })
    }

    @Test(
        """
        ContainerDeployExecutor's .githubPagesPublish argv passes owner/repo as positional shell \
        parameters, so shell metacharacters in either cannot execute as commands
        """
    )
    func githubPagesPublishArgvIsSafeAgainstShellInjection() throws {
        // anglesite.json's githubPages section is app-written today, but nothing about guestArgv
        // itself validates its contents — this proves a malformed repo name can't break out of
        // the intended git invocation when the produced argv is actually executed by `sh`, not
        // just that the argv strings "look" quoted. Mirrors DeployCommandTests's
        // bundleUploadArgvIsSafeAgainstShellInjectionInBucketName exactly.
        let markerFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-pages-pwned-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: markerFile) }
        #expect(!FileManager.default.fileExists(atPath: markerFile.path))

        let payload = "evil-repo'; touch \(markerFile.path); echo '"
        let siteDir = try makeSiteDirectory(githubPagesOwner: "acme", repo: payload)
        defer { try? FileManager.default.removeItem(at: siteDir) }
        try FileManager.default.createDirectory(
            at: siteDir.appendingPathComponent("dist"), withIntermediateDirectories: true)

        let argv = ContainerDeployExecutorTestHook.guestArgv(for: .githubPagesPublish, siteDirectory: siteDir)
        #expect(argv.contains(payload))

        // Stub `git` on PATH so the script doesn't need a real repo or network — the point is
        // only to observe whether the shell executes the injected `touch`, not whether git itself
        // succeeds. Mirrors the bundle-upload injection test's `tar`/`npx` stubbing.
        let binDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("github-pages-injection-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: binDir) }
        let gitStub = binDir.appendingPathComponent("git")
        try "#!/bin/sh\nexit 0\n".write(to: gitStub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gitStub.path)

        // argv is ["sh", "-c", script, "sh", owner, repo] — feed it to a real `sh` exactly as
        // ContainerDeployExecutor would hand it to the guest's exec call.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = Array(argv.dropFirst())
        process.currentDirectoryURL = siteDir
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = binDir.path + ":" + (environment["PATH"] ?? "")
        environment["GITHUB_PAGES_TOKEN"] = "test-token"
        process.environment = environment
        try process.run()
        process.waitUntilExit()

        #expect(
            !FileManager.default.fileExists(atPath: markerFile.path),
            "shell metacharacters in the GitHub Pages repo name executed as commands — injection is not blocked")
    }

    @Test("githubPagesPublish forwards GITHUB_PAGES_TOKEN in env, and nothing else")
    func githubPagesPublishForwardsToken() async {
        let fake = fakePassing()
        let executor = makeExecutor(fake: fake)
        _ = await executor.run(
            step: .githubPagesPublish,
            siteDirectory: URL(fileURLWithPath: "/host/irrelevant"),
            environment: [
                "GITHUB_PAGES_TOKEN": "supersecret",
                "CLOUDFLARE_API_TOKEN": "should-not-leak",
                "PATH": "/opt/homebrew/bin:/usr/bin"
            ],
            source: "deploy:site-abc"
        )
        let env = await fake.execCalls[0].env
        #expect(env["GITHUB_PAGES_TOKEN"] == "supersecret")
        #expect(env["CLOUDFLARE_API_TOKEN"] == nil)
        #expect(env["PATH"] == nil)
    }
```

- [ ] **Step 8: Add the `HostDeployExecutor` unavailability assertion**

In `Tests/AnglesiteCoreTests/DeployExecutorTests.swift`, extend `defaultResolverUnavailable` (lines 121-133) with one more assertion, right after the existing `.wrangler` one:

```swift
    @Test("HostDeployExecutor defaults fail every step explicitly after host Node retirement")
    func defaultResolverUnavailable() async {
        let dir = tmpDir

        #expect(HostDeployExecutor.defaultResolver(.build)(dir) == .unavailable(reason: "site build must run in the container runtime; host Node has been retired"))
        #expect(HostDeployExecutor.defaultResolver(.preflight)(dir) == .unavailable(reason: "pre-deploy check must run in the container runtime; host Node has been retired"))
        #expect(HostDeployExecutor.defaultResolver(.wrangler)(dir) == .unavailable(reason: "wrangler deploy must run in the container runtime; host Node has been retired"))
        #expect(HostDeployExecutor.defaultResolver(.githubPagesPublish)(dir) == .unavailable(reason: "GitHub Pages publish must run in the container runtime; host Node has been retired"))

        let executor = HostDeployExecutor(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let result = await executor.run(step: .preflight, siteDirectory: dir, environment: [:], source: "test:default")
        #expect(result.exitCode == nil)
        #expect(result.output == "pre-deploy check must run in the container runtime; host Node has been retired")
    }
```

- [ ] **Step 9: Run the new and touched tests, then the full suite**

Run: `swift test --package-path . --filter ContainerDeployExecutorTests --filter DeployExecutorTests`
Expected: PASS, including all five new tests from Step 7 and the extended assertion from Step 8.

Run: `swift test --package-path .`
Expected: every test in every target PASSes (the six fixed-up exhaustive switches changed no observable behavior; the new tests exercise genuinely new code).

- [ ] **Step 10: Commit**

```bash
git add Sources/AnglesiteCore/DeployExecutor.swift \
  Tests/AnglesiteCoreTests/DeployCommandTests.swift Tests/AnglesiteCoreTests/DeployCommandProgressTests.swift \
  Tests/AnglesiteCoreTests/DeployExecutorTests.swift Tests/AnglesiteCoreTests/ContainerDeployExecutorTests.swift \
  Tests/AnglesiteAppTests/DeployModelTests.swift
git commit -m "feat(#1015): add DeployStep.githubPagesPublish"
```

---

### Task 3: Add `HTTPGitHubClient.enablePages`

**Files:**
- Modify: `Sources/AnglesiteCore/HTTPGitHubClient.swift:176-195` (add `PagesConfigBody` alongside the other private request/response structs), and add the method itself after `createRepo` (after line 83, before `repoRequest`)
- Test: `Tests/AnglesiteCoreTests/HTTPGitHubClientTests.swift` (extend — add a new section after the existing `createRepo`-adjacent tests, e.g. after line 118's `sendsExpectedRequest`)

**Interfaces:**
- Consumes: `HTTPGitHubClient`'s existing `transport`, `GitHubRepoAPIError`, `GitHubErrorResponse` (unchanged).
- Produces: `public func enablePages(owner: String, repo: String, token: String) async throws` — `POST /repos/{owner}/{repo}/pages`, `build_type: "legacy"`, `source: {branch: "main", path: "/"}`. Error mapping matches `createRepo` exactly: transport failure → `.network`; 401/403 → `.unauthorized(status:)`; 422 → `.api(message:)` (decoded from the response body); any other non-2xx → `.http(status:)`. Not yet called by anything — `GitHubPagesDeployTarget` (slice 2b) decides when/how to call it, including how to treat a repo that already has Pages configured.

- [ ] **Step 1: Write the failing tests**

In `Tests/AnglesiteCoreTests/HTTPGitHubClientTests.swift`, add this new section after `sendsExpectedRequest` (after its closing `}` around line 103, before `private actor CapturedRequest`):

```swift

    // MARK: - enablePages (#1015 slice 2a)

    @Test("enablePages POSTs the legacy build type with the branch/path source")
    func enablePagesSendsExpectedRequest() async throws {
        let box = RequestBox()
        let client = HTTPGitHubClient(transport: Self.recordingTransport(status: 201, json: "{}", into: box))
        try await client.enablePages(owner: "acme", repo: "site-pages", token: "tok")
        let request = await box.last
        #expect(request?.url?.path == "/repos/acme/site-pages/pages")
        #expect(request?.httpMethod == "POST")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try #require(request?.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["build_type"] as? String == "legacy")
        let source = try #require(decoded["source"] as? [String: Any])
        #expect(source["branch"] as? String == "main")
        #expect(source["path"] as? String == "/")
    }

    @Test("a successful enablePages call returns normally")
    func enablePagesSucceeds() async throws {
        let client = HTTPGitHubClient(transport: Self.transport(status: 201, json: "{}"))
        try await client.enablePages(owner: "acme", repo: "site-pages", token: "tok")
    }

    @Test("a 401 on enablePages maps to .unauthorized")
    func enablePagesUnauthorized() async {
        let client = HTTPGitHubClient(transport: Self.transport(status: 401, json: #"{"message":"Bad credentials"}"#))
        await #expect(throws: GitHubRepoAPIError.unauthorized(status: 401)) {
            try await client.enablePages(owner: "acme", repo: "site-pages", token: "bad")
        }
    }

    @Test("a 403 on enablePages maps to .unauthorized")
    func enablePagesForbidden() async {
        let client = HTTPGitHubClient(transport: Self.transport(status: 403, json: #"{"message":"Must have admin rights"}"#))
        await #expect(throws: GitHubRepoAPIError.unauthorized(status: 403)) {
            try await client.enablePages(owner: "acme", repo: "site-pages", token: "scoped-wrong")
        }
    }

    @Test("a 422 on enablePages surfaces as .api with the message")
    func enablePagesValidationError() async {
        let client = HTTPGitHubClient(transport: Self.transport(
            status: 422, json: #"{"message":"Pages is not available for this repository"}"#))
        await #expect(throws: GitHubRepoAPIError.api(message: "Pages is not available for this repository")) {
            try await client.enablePages(owner: "acme", repo: "site-pages", token: "tok")
        }
    }

    @Test("an unexpected status on enablePages maps to .http(status:)")
    func enablePagesUnexpectedStatus() async {
        let client = HTTPGitHubClient(transport: Self.transport(status: 503, json: "{}"))
        await #expect(throws: GitHubRepoAPIError.http(status: 503)) {
            try await client.enablePages(owner: "acme", repo: "site-pages", token: "tok")
        }
    }

    @Test("a transport failure on enablePages maps to .network")
    func enablePagesNetworkFailure() async {
        let client = HTTPGitHubClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: GitHubRepoAPIError.network) {
            try await client.enablePages(owner: "acme", repo: "site-pages", token: "tok")
        }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter HTTPGitHubClientTests`
Expected: FAIL to compile — `enablePages` doesn't exist on `HTTPGitHubClient` yet.

- [ ] **Step 3: Add the `PagesConfigBody` request struct**

In `Sources/AnglesiteCore/HTTPGitHubClient.swift`, add this new private struct after `CreateRepoBody` (after line 180, before `CreatedRepoResponse`):

```swift
    private struct PagesConfigBody: Encodable {
        let buildType: String
        let source: Source
        struct Source: Encodable { let branch: String; let path: String }
        enum CodingKeys: String, CodingKey { case buildType = "build_type", source }
    }
```

- [ ] **Step 4: Add the `enablePages` method**

In the same file, add this method after `createRepo` (after its closing `}` at line 83, before `repoRequest`):

```swift
    /// `POST /repos/{owner}/{repo}/pages` — enables GitHub Pages, publishing from `main` at the
    /// repo root via the "legacy" (deploy-from-branch) build type, no GitHub Actions involved.
    /// Error mapping matches ``createRepo(name:isPrivate:token:)`` exactly. Callers decide how to
    /// handle a repo that already has Pages configured (#1015 slice 2b) — this method makes no
    /// assumption about GitHub's response to a repeat call.
    public func enablePages(owner: String, repo: String, token: String) async throws {
        guard let url = URL(string: Self.base + "/repos/\(owner)/\(repo)/pages") else {
            throw GitHubRepoAPIError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            PagesConfigBody(buildType: "legacy", source: .init(branch: "main", path: "/")))

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            throw GitHubRepoAPIError.network
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw GitHubRepoAPIError.unauthorized(status: http.statusCode)
        }
        if http.statusCode == 422 {
            let envelope = try? JSONDecoder().decode(GitHubErrorResponse.self, from: data)
            throw GitHubRepoAPIError.api(message: envelope?.message ?? "request failed")
        }
        guard (200..<300).contains(http.statusCode) else { throw GitHubRepoAPIError.http(status: http.statusCode) }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path . --filter HTTPGitHubClientTests`
Expected: PASS — all `HTTPGitHubClientTests` cases, including the six new `enablePages` tests.

- [ ] **Step 6: Run the full suite**

Run: `swift test --package-path .`
Expected: every test in every target PASSes.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/HTTPGitHubClient.swift Tests/AnglesiteCoreTests/HTTPGitHubClientTests.swift
git commit -m "feat(#1015): add HTTPGitHubClient.enablePages"
```

---

## Notes for the executing agent

- **This slice adds capability; it wires nothing.** No production code calls `.githubPagesPublish`, `enablePages`, or reads `githubPages` outside its own round-trip test. `GitHubPagesDeployTarget` (slice 2b) is what actually invokes all three; don't add it here.
- **Don't touch** `DeployCommand.swift`, `DeployTarget.swift`, `CloudflareDeployTarget.swift` — this slice is purely additive to the executor/config/client layer beneath them.
- Task 1 must land before Task 2 (Task 2's `guestArgv` case reads `DomainConfig.githubPages`). Task 3 has no dependency on either and could run in parallel with Task 2 if using subagent-driven development with independent worktrees — but per this plan's own task list it's written to run after, for narrative simplicity.
- If `swift build`/`swift test` hangs with no output, a stale SwiftPM process may be holding the `.build` lock (`pgrep -fl swift-test`) — see AGENTS.md ▸ Build.

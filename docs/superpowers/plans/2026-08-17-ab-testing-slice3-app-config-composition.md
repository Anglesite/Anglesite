# A/B slice 3: app config model + wrangler composition — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Swift app a `DomainConfig.Experiments` model that mirrors the template's already-shipped `anglesite.json` schema, teach `WorkerComposition.generateWranglerToml` to compose a Worker for a running experiment (third enabler, `run_worker_first`, its own `EXPERIMENTS_DB` D1 binding), and make `SocialWorkerProvisionCommand.provision` provision that shared D1 database on a static-only site's first running experiment.

**Architecture:** Pure additive plumbing on top of two already-shipped things: the template-side `experiments` schema (slice 1, #1513, merged) and the existing `@dwk/workers` composition machinery (`WorkerComposition`/`WorkerRouteClaims`/`SocialWorkerProvisionCommand`). Every new `experiments` parameter defaults to `[]`/absent, so this slice changes wrangler.toml output and D1 provisioning **only** for a site that actually declares a `status: "running"` experiment — every existing test and every site without experiments is byte-for-byte unaffected. No new UI; slice 5 (#1270 design doc §10) builds the surface that actually flips `status` to `"running"`. This slice only makes sure that once something does (a hand edit today; the app later), the ordinary deploy path picks it up correctly.

**Tech Stack:** Swift 6.4, Swift Testing (`@Suite`/`@Test`/`#expect`), the existing `AnglesiteCore` module.

## Global Constraints

- Every new/changed Swift file lives under `Sources/AnglesiteCore/` or `Sources/AnglesiteApp/` — no new Xcode target, no new dependency.
- Field names and types in `DomainConfig.Experiments` must mirror `Resources/Template/scripts/anglesite-config.ts`'s `AnglesiteExperiment`/`AnglesiteExperimentVariant`/`AnglesiteExperimentGoal`/`AnglesiteExperimentsConfig` **field-for-field** (already shipped in slice 1, #1513) — do not invent new field names.
- `status`/`goal.kind` are open `String`, never a closed `enum` — matches `DomainConfig.Domain.choice`'s precedent so a hand-authored or future value degrades gracefully on decode instead of failing the whole document.
- The D1 binding name is `EXPERIMENTS_DB` and the shared database is `"\(siteName)-social"` — both already fixed by slice 1 (`Resources/Template/worker/worker.ts`'s `EXPERIMENTS_DB?: D1Database` and `Resources/Template/worker/migrations/0002_experiments.sql`'s own comment: *"SocialWorkerProvisionCommand (Swift, slice 3) applies migrations before deploying"*). Do not rename either.
- Run `swift test --package-path .` after every task in this plan — CI's `macos-26` runner will catch build breaks, but the `AnglesiteApp`-target edits in Task 5 only get exercised by a local Xcode-27 `swift test` per this repo's CONTRIBUTING.md note on `AnglesiteAppTests`/`AnglesiteIntentsTests` coverage.
- Commit subjects ≤72 characters, conventional-commit format, referencing `#1515`.

## Amendment (decided mid-execution, supersedes Task 2 Step 3 and Task 3's test literals)

Both the Task 2 and Task 3 implementers independently hit the same real bug: the design doc's own
example `anglesite.json` (§2) uses trailing-slash paths throughout (`"page": "/x/homepage-hero/b/"`,
goal `"path": "/contact/thanks/"`) — matching Astro's directory-style routes — but
`experimentPathProblem`, specified below as reusing `pathProblem`'s character rules unchanged
(only permitting the bare root `/`), rejects any trailing slash as "doubled or trailing slashes."
As originally specified, a real experiment configured exactly like the design doc's own example
would fail `wrangler.toml` generation. Decided (owner, 2026-08-17): `experimentPathProblem` must
**also** permit exactly one trailing slash on a non-root path — still rejecting doubled/internal
empty segments, traversal, encoding, and every other `pathProblem` rule unchanged. This supersedes
Task 2 Step 3's `pathSyntaxProblem` body (below) and reverts the trailing-slash literals both
implementers had defensively stripped from their tests back to the design doc's own paths.

Corrected `pathSyntaxProblem` (replaces Task 2 Step 3's version verbatim — same function, one
added block right after the segment split, before the empty-segment check):

```swift
    private static func pathSyntaxProblem(_ path: String, allowRoot: Bool) -> String? {
        if path.isEmpty { return "empty path" }
        if !path.hasPrefix("/") { return "path must be absolute (start with \"/\")" }
        if path == "/" {
            return allowRoot ? nil : "the origin root cannot be claimed"
        }
        if path.count > maxPathLength { return "path exceeds \(maxPathLength) characters" }
        if path.contains("%") { return "percent-encoding is not allowed in route claims" }
        if let bad = path.unicodeScalars.first(where: { !allowedPathScalars.contains($0) }) {
            return "disallowed character \(String(reflecting: Character(bad)))"
        }
        var segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        // An experiment path may end in exactly one trailing slash — Astro's directory-style
        // routes (design doc §2's own example: "/x/homepage-hero/b/", "/contact/thanks/") — but a
        // route claim (an API endpoint, allowRoot == false) never permits one. Dropping at most
        // one trailing empty segment here still leaves a genuine doubled slash ("/a//") or an
        // internal empty segment ("/a//b") caught by the check below, since those leave more than
        // one empty segment (or one not at the end) behind.
        if allowRoot, segments.count > 1, segments.last?.isEmpty == true {
            segments.removeLast()
        }
        if segments.contains(where: \.isEmpty) {
            return "empty path segment (no doubled or trailing slashes)"
        }
        if segments.contains(where: { $0 == "." || $0 == ".." }) {
            return "path traversal segment"
        }
        if path == "/.well-known" { return "the bare /.well-known directory cannot be claimed" }
        return nil
    }
```

`pathProblem`'s own behavior is unaffected (`allowRoot: false` never enters the new branch — same
guarantee Task 2's original reviewer already verified for every other rule). Task 2's doc comment
on `experimentPathProblem` should be updated to describe both permitted differences, not just the
root. Task 2's and Task 3's test literals that were changed away from the design doc's trailing-
slash paths (`/x/homepage-hero/b/`, `/contact/thanks/`) should be reverted to match the design doc
again, plus one new test confirming `experimentPathProblem` still rejects a doubled trailing slash
(`"/a//"`) and an internal empty segment (`"/a//b"`).

---

## File Structure

| File | Change |
|---|---|
| `Sources/AnglesiteCore/DomainConfig.swift` | Add `experiments: Experiments?` field + nested `Experiments`/`Experiment`/`Variant`/`Goal` structs + `Codable` extension updates. |
| `Sources/AnglesiteCore/WorkerRouteClaims.swift` | Refactor `pathProblem` into a shared `pathSyntaxProblem(_:allowRoot:)`; add `experimentPathProblem(_:)`. |
| `Sources/AnglesiteCore/WorkerComposition.swift` | `generateWranglerToml` gains an `experiments` parameter: third-enabler gating, `run_worker_first` emission (page + pageview-goal path + beacon endpoint), `EXPERIMENTS_DB` D1 block, collision validation. |
| `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift` | `provision`/`persistConfig` gain an `experiments` parameter: extends the D1-create gate, applies the `EXPERIMENTS_DB` migration. |
| `Sources/AnglesiteCore/DeployCoordinator.swift` | New `resolveRunningExperiments(sourceDirectory:)` static helper. |
| `Sources/AnglesiteCore/SiteOperations.swift` | `deployWithWorkerComposition` reads and threads running experiments into `provision`. |
| `Sources/AnglesiteApp/DeployModel.swift` | `runDeploy` reads and threads running experiments into `provision`. |
| `Tests/AnglesiteCoreTests/DomainConfigStoreTests.swift` | Round-trip + unknown-key-preservation tests for `experiments`. |
| `Tests/AnglesiteCoreTests/WorkerRouteClaimsTests.swift` | `experimentPathProblem` tests. |
| `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift` | Composition snapshot tests for a running/draft experiment, beacon endpoint, collision. |
| `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift` | D1-provisioning + migration tests for a static-only site with a running experiment. |
| `Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift` | `resolveRunningExperiments` tests. |

---

### Task 1: `DomainConfig.Experiments` model

**Files:**
- Modify: `Sources/AnglesiteCore/DomainConfig.swift`
- Test: `Tests/AnglesiteCoreTests/DomainConfigStoreTests.swift`

**Interfaces:**
- Produces: `DomainConfig.experiments: DomainConfig.Experiments?`; `DomainConfig.Experiments { active: [Experiment]? }`; `DomainConfig.Experiments.Experiment { id: String, name: String, page: String, variant: Variant, split: Double, goal: Goal, status: String, startedAt: String? }`; `DomainConfig.Experiments.Experiment.Variant { id: String, name: String, page: String }`; `DomainConfig.Experiments.Experiment.Goal { kind: String, path: String?, depth: Int?, selector: String? }`. All four new types are `Codable, Equatable, Sendable`. Later tasks (3, 4, 5) consume `DomainConfig.Experiments.Experiment` directly as their array element type.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/DomainConfigStoreTests.swift`, after the existing `saveLoadRoundTrips` test:

```swift
    @Test("save then load round-trips a config with experiments")
    func saveLoadRoundTripsExperiments() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DomainConfigStore(sourceDirectory: dir)
        let config = DomainConfig(
            experiments: .init(active: [
                .init(
                    id: "homepage-hero",
                    name: "Homepage headline",
                    page: "/",
                    variant: .init(id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/"),
                    split: 0.5,
                    goal: .init(kind: "pageview", path: "/contact/thanks/"),
                    status: "running",
                    startedAt: "2026-08-16"
                ),
            ])
        )
        try store.save(config)
        #expect(try store.load() == config)
    }

    @Test("save preserves an unrecognized key nested inside the experiments section")
    func savePreservesUnknownNestedExperimentsKey() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("anglesite.json")
        try #"{"version":1,"experiments":{"active":[],"futureField":"x"}}"#.write(
            to: fileURL, atomically: true, encoding: .utf8
        )
        let store = DomainConfigStore(sourceDirectory: dir)
        try store.save(DomainConfig(experiments: .init(active: [])))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let experiments = raw?["experiments"] as? [String: Any]
        #expect(experiments?["futureField"] as? String == "x")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter DomainConfigStoreTests`
Expected: build fails — `DomainConfig` has no member `experiments` / no initializer with `experiments:`.

- [ ] **Step 3: Add the `experiments` field and nested types**

In `Sources/AnglesiteCore/DomainConfig.swift`, add the field and init parameter (after `workers`):

```swift
    public var domain: Domain?
    public var dns: DNS?
    public var edge: Edge?
    public var email: Email?
    public var workers: Workers?
    public var experiments: Experiments?

    public init(
        version: Int = 1,
        domain: Domain? = nil,
        dns: DNS? = nil,
        edge: Edge? = nil,
        email: Email? = nil,
        workers: Workers? = nil,
        experiments: Experiments? = nil
    ) {
        self.version = version
        self.domain = domain
        self.dns = dns
        self.edge = edge
        self.email = email
        self.workers = workers
        self.experiments = experiments
    }
```

Add the nested `Experiments` struct after the existing `Workers` struct (still inside `DomainConfig`'s body, before its closing `}`):

```swift
    /// The site's A/B experiments (#1270 design doc §2) — git-canonical *declared intent*: what
    /// the deployed site serves. Live tallies and concluded-experiment outcomes are never
    /// declared here (they live in D1 and `Config/experiment-history.json` respectively); see the
    /// design doc's "Why git-canonical" section.
    public struct Experiments: Codable, Equatable, Sendable {
        /// v1 supports one active experiment at a time (pre-deploy-gate enforced, not here); the
        /// array leaves room to relax that later without a schema break.
        public var active: [Experiment]?

        public init(active: [Experiment]? = nil) {
            self.active = active
        }

        /// One declared experiment: a control page, a built variant page, a goal, and a
        /// lifecycle status. Mirrors the template's `AnglesiteExperiment` TypeScript interface
        /// (`Resources/Template/scripts/anglesite-config.ts`) field-for-field.
        public struct Experiment: Codable, Equatable, Sendable {
            /// Stable, `[A-Za-z0-9-]+` — the cookie name and D1 key.
            public var id: String
            /// Owner-facing display name.
            public var name: String
            /// The route under test; the control serves it as-is.
            public var page: String
            public var variant: Variant
            /// Control's traffic share; the app always writes `0.5`.
            public var split: Double
            public var goal: Goal
            /// `"draft" | "running"` — kept as an open string, not a closed `enum`, matching
            /// ``DomainConfig/Domain/choice`` so an unrecognized future status degrades
            /// gracefully instead of failing the whole document to decode.
            public var status: String
            /// ISO date the experiment started, driving the 30-day rule of thumb. `nil` while
            /// `status` is `"draft"`.
            public var startedAt: String?

            public init(
                id: String, name: String, page: String, variant: Variant, split: Double,
                goal: Goal, status: String, startedAt: String? = nil
            ) {
                self.id = id
                self.name = name
                self.page = page
                self.variant = variant
                self.split = split
                self.goal = goal
                self.status = status
                self.startedAt = startedAt
            }

            public struct Variant: Codable, Equatable, Sendable {
                public var id: String
                public var name: String
                /// The variant's built route.
                public var page: String

                public init(id: String, name: String, page: String) {
                    self.id = id
                    self.name = name
                    self.page = page
                }
            }

            /// `"pageview" | "route" | "scroll" | "visible"` — kept as an open `kind` string for
            /// the same forward-compatibility reason as ``status``.
            public struct Goal: Codable, Equatable, Sendable {
                public var kind: String
                /// Required for `"pageview"`/`"route"` goals.
                public var path: String?
                /// Required for `"scroll"` goals: 1-100, percent of page scrolled.
                public var depth: Int?
                /// Required for `"visible"` goals: CSS selector of the observed element.
                public var selector: String?

                public init(kind: String, path: String? = nil, depth: Int? = nil, selector: String? = nil) {
                    self.kind = kind
                    self.path = path
                    self.depth = depth
                    self.selector = selector
                }
            }
        }
    }
```

Update the hand-rolled `Codable` extension at the bottom of the file:

```swift
extension DomainConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, domain, dns, edge, email, workers, experiments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        domain = try container.decodeIfPresent(Domain.self, forKey: .domain)
        dns = try container.decodeIfPresent(DNS.self, forKey: .dns)
        edge = try container.decodeIfPresent(Edge.self, forKey: .edge)
        email = try container.decodeIfPresent(Email.self, forKey: .email)
        workers = try container.decodeIfPresent(Workers.self, forKey: .workers)
        experiments = try container.decodeIfPresent(Experiments.self, forKey: .experiments)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(domain, forKey: .domain)
        try container.encodeIfPresent(dns, forKey: .dns)
        try container.encodeIfPresent(edge, forKey: .edge)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(workers, forKey: .workers)
        try container.encodeIfPresent(experiments, forKey: .experiments)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter DomainConfigStoreTests`
Expected: PASS (all `DomainConfigStoreTests`, including the two new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DomainConfig.swift Tests/AnglesiteCoreTests/DomainConfigStoreTests.swift
git commit -m "feat(#1515): add DomainConfig.Experiments model"
```

---

### Task 2: `WorkerRouteClaims.experimentPathProblem`

**Files:**
- Modify: `Sources/AnglesiteCore/WorkerRouteClaims.swift`
- Test: `Tests/AnglesiteCoreTests/WorkerRouteClaimsTests.swift`

**Interfaces:**
- Consumes: nothing new (pure refactor + addition, no dependency on Task 1).
- Produces: `WorkerRouteClaims.experimentPathProblem(_ path: String) -> String?` — same character/traversal/length rules as `pathProblem(_:)`, but returns `nil` for the bare root `"/"` instead of rejecting it. Task 3 calls this directly.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/WorkerRouteClaimsTests.swift` (a new `// MARK:` section; place it near the existing path-validation tests):

```swift
    // MARK: experimentPathProblem (#1515)

    @Test("experimentPathProblem permits the bare root, unlike pathProblem")
    func experimentPathProblemPermitsRoot() {
        #expect(WorkerRouteClaims.pathProblem("/") != nil)
        #expect(WorkerRouteClaims.experimentPathProblem("/") == nil)
    }

    @Test("experimentPathProblem rejects the same malformed/traversal/encoded paths as pathProblem", arguments: [
        "",
        "webfinger",
        "/.well-known",
        "/a//b",
        "/a/b/",
        "/a/../b",
        "/a/./b",
        "/a%2Fb",
        "/a b",
    ])
    func experimentPathProblemRejectsMalformed(_ path: String) {
        #expect(WorkerRouteClaims.experimentPathProblem(path) != nil)
    }

    @Test("experimentPathProblem accepts an ordinary well-formed path")
    func experimentPathProblemAcceptsOrdinaryPath() {
        #expect(WorkerRouteClaims.experimentPathProblem("/x/homepage-hero/b/") == nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter WorkerRouteClaimsTests`
Expected: build fails — `WorkerRouteClaims` has no member `experimentPathProblem`.

- [ ] **Step 3: Refactor `pathProblem` and add `experimentPathProblem`**

In `Sources/AnglesiteCore/WorkerRouteClaims.swift`, replace the existing `pathProblem` function with:

```swift
    /// Returns why `path` is not a valid route-claim path, or `nil` if it is valid.
    static func pathProblem(_ path: String) -> String? {
        pathSyntaxProblem(path, allowRoot: false)
    }

    /// Same character-class, traversal, and length rules as ``pathProblem(_:)``, but permits the
    /// bare root `/` — an A/B experiment's tested page may legitimately be the site's homepage
    /// (#1270 design doc §3), unlike a `@dwk/workers` catalog route claim, which
    /// ``pathProblem(_:)`` deliberately refuses to let claim `/` at all.
    static func experimentPathProblem(_ path: String) -> String? {
        pathSyntaxProblem(path, allowRoot: true)
    }

    /// Shared character/traversal/length validation behind ``pathProblem(_:)`` and
    /// ``experimentPathProblem(_:)`` — the two differ only in whether the bare root `/` is
    /// itself acceptable.
    private static func pathSyntaxProblem(_ path: String, allowRoot: Bool) -> String? {
        if path.isEmpty { return "empty path" }
        if !path.hasPrefix("/") { return "path must be absolute (start with \"/\")" }
        if path == "/" {
            return allowRoot ? nil : "the origin root cannot be claimed"
        }
        if path.count > maxPathLength { return "path exceeds \(maxPathLength) characters" }
        if path.contains("%") { return "percent-encoding is not allowed in route claims" }
        if let bad = path.unicodeScalars.first(where: { !allowedPathScalars.contains($0) }) {
            return "disallowed character \(String(reflecting: Character(bad)))"
        }
        // Leading "/" dropped; keep empty subsequences so "//" and a trailing "/" both surface
        // as empty segments.
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        if segments.contains(where: \.isEmpty) {
            return "empty path segment (no doubled or trailing slashes)"
        }
        if segments.contains(where: { $0 == "." || $0 == ".." }) {
            return "path traversal segment"
        }
        // RFC 8615: `/.well-known/` itself has no representation — the bare directory is never
        // claimable, exactly or (which would swallow the whole namespace) as a prefix.
        if path == "/.well-known" { return "the bare /.well-known directory cannot be claimed" }
        return nil
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter WorkerRouteClaimsTests`
Expected: PASS (all `WorkerRouteClaimsTests`, including the three new ones — the refactor is behavior-preserving for `pathProblem` itself, so every pre-existing test in this file must still pass unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WorkerRouteClaims.swift Tests/AnglesiteCoreTests/WorkerRouteClaimsTests.swift
git commit -m "feat(#1515): add WorkerRouteClaims.experimentPathProblem"
```

---

### Task 3: `WorkerComposition.generateWranglerToml` learns experiments

**Files:**
- Modify: `Sources/AnglesiteCore/WorkerComposition.swift`
- Test: `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift`

**Interfaces:**
- Consumes: `DomainConfig.Experiments.Experiment` (Task 1); `WorkerRouteClaims.experimentPathProblem(_:)` (Task 2).
- Produces: `WorkerComposition.generateWranglerToml(..., experiments: [DomainConfig.Experiments.Experiment] = [])` — new trailing parameter. Task 4 threads a caller-supplied array straight through to this parameter.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/WorkerCompositionTests.swift`, a private helper near the top (alongside the existing `worker(_:d1:kv:r2:)` helper) and new tests in a new `// MARK:` section:

```swift
private func runningExperiment(
    id: String = "homepage-hero",
    page: String = "/",
    goalKind: String = "pageview",
    goalPath: String? = "/contact/thanks/",
    status: String = "running"
) -> DomainConfig.Experiments.Experiment {
    .init(
        id: id, name: "Homepage headline", page: page,
        variant: .init(id: "b", name: "Fresh eggs headline", page: "/x/\(id)/b/"),
        split: 0.5,
        goal: .init(kind: goalKind, path: goalPath),
        status: status
    )
}
```

```swift
    // MARK: experiments (#1515)

    @Test("a running experiment on a static-only site composes a Worker for exactly its paths")
    func runningExperimentComposesWorker() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            workers: [],
            experiments: [runningExperiment()]
        )
        #expect(toml.contains("main = \"worker/worker.ts\""))
        #expect(toml.contains("binding = \"ASSETS\""))
        #expect(toml.contains(#"run_worker_first = ["/", "/contact/thanks/"]"#))
        #expect(toml.contains("[[d1_databases]]"))
        #expect(toml.contains("binding = \"EXPERIMENTS_DB\""))
        #expect(toml.contains("migrations_dir = \"worker/migrations\""))
        #expect(toml.contains("[observability]"))
    }

    @Test("a draft experiment composes nothing")
    func draftExperimentComposesNothing() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            workers: [],
            experiments: [runningExperiment(status: "draft")]
        )
        #expect(!toml.contains("main ="))
        #expect(!toml.contains("[[d1_databases]]"))
        #expect(!toml.contains("run_worker_first"))
    }

    @Test("a client-side goal adds the shared beacon endpoint to run_worker_first")
    func clientSideGoalAddsBeaconEndpoint() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            workers: [],
            experiments: [runningExperiment(goalKind: "scroll", goalPath: nil)]
        )
        #expect(toml.contains(#"run_worker_first = ["/", "/x/goal"]"#))
    }

    @Test("an experiment path colliding with an active route claim throws")
    func experimentPathCollisionThrows() {
        let claim = WorkerRouteClaim(path: "/micropub", match: .exact, methods: ["POST"], handler: "micropub")
        #expect(throws: (any Error).self) {
            try WorkerComposition.generateWranglerToml(
                siteName: "my-site",
                workers: [],
                routeClaims: [claim],
                experiments: [runningExperiment(page: "/micropub")]
            )
        }
    }

    @Test("an experiment page of \"/\" is accepted even though a catalog route claim could never claim it")
    func experimentPageRootAccepted() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site", workers: [], experiments: [runningExperiment(page: "/")]
        )
        #expect(toml.contains("run_worker_first"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: build fails — `generateWranglerToml` has no parameter `experiments`.

- [ ] **Step 3: Implement**

In `Sources/AnglesiteCore/WorkerComposition.swift`:

1. Add `experiments: [DomainConfig.Experiments.Experiment] = []` as a new trailing parameter of `generateWranglerToml` (after `apUsername: String? = nil`), and add a doc-comment bullet after the existing `apUsername` bullet:

```swift
    ///   - experiments: The site's declared experiments (`DomainConfig.Experiments.active`,
    ///     #1270 slice 3) — only entries with `status == "running"` contribute anything. A
    ///     running experiment is Worker composition's third enabler (alongside
    ///     `hasSocialFeatures` and `inboxCaptureEnabled`): its tested `page`, a `"pageview"`
    ///     goal's `path`, and — when any running experiment observes a `"scroll"`/`"visible"`
    ///     goal — the shared `/x/goal` beacon endpoint all join `[assets].run_worker_first`,
    ///     validated via `WorkerRouteClaims.experimentPathProblem(_:)` (which, unlike
    ///     `pathProblem`, permits the bare root `/`) and checked for collisions against
    ///     `routeClaims`/the inbox-capture claim. A running experiment also emits its own
    ///     `[[d1_databases]]` block bound to `EXPERIMENTS_DB` on the same shared
    ///     `"\(siteName)-social"` database. Defaults to `[]` (no experiments).
```

2. Right after the existing route-claim validation loop (immediately before the `let hasIndieauth = ...` line), insert:

```swift
        // #1270 slice 3: a running experiment's tested page, its pageview-goal path, and (when a
        // running experiment observes a client-side goal) the shared beacon endpoint all bypass
        // asset-first serving too, so bucketing/goal-recording can never be shadowed by a static
        // file at that path. Draft experiments (not yet started) contribute nothing here — only
        // a "running" status reaches composition (design doc §3/§5); the pre-deploy gate is the
        // one place that validates a draft experiment's own path/goal completeness.
        let runningExperiments = experiments.filter { $0.status == "running" }
        let hasRunningExperiment = !runningExperiments.isEmpty
        var experimentRoutes: [(id: String, path: String)] = []
        for experiment in runningExperiments {
            if let problem = WorkerRouteClaims.experimentPathProblem(experiment.page) {
                throw ConfigError.invalidRouteClaim(
                    path: experiment.page, reason: "experiment \"\(experiment.id)\": \(problem)")
            }
            experimentRoutes.append((id: experiment.id, path: experiment.page))
            if experiment.goal.kind == "pageview", let goalPath = experiment.goal.path {
                if let problem = WorkerRouteClaims.experimentPathProblem(goalPath) {
                    throw ConfigError.invalidRouteClaim(
                        path: goalPath, reason: "experiment \"\(experiment.id)\" goal: \(problem)")
                }
                experimentRoutes.append((id: experiment.id, path: goalPath))
            }
        }
        // The shared client-side goal beacon endpoint (#1270 design doc §4) — one path serves
        // every running experiment's scroll/visibility goal, so it's added at most once.
        let hasClientSideGoal = runningExperiments.contains { $0.goal.kind == "scroll" || $0.goal.kind == "visible" }
        if hasClientSideGoal {
            experimentRoutes.append((id: "*", path: "/x/goal"))
        }
        // An experiment path can't sit on a claimed worker route (design doc §3: "an experiment
        // can't sit on /micropub") — checked against the same effective claim set (catalog routes
        // plus inbox-capture) already validated above.
        for route in experimentRoutes {
            let collides = effectiveClaims.contains { claim in
                claim.path == route.path
                    || (claim.match == .prefix && route.path.hasPrefix(claim.path + "/"))
            }
            if collides {
                throw ConfigError.invalidRouteClaim(
                    path: route.path,
                    reason: "experiment \"\(route.id)\" collides with an existing worker route claim")
            }
        }
```

3. Replace:

```swift
        let hasSocialFeatures = !workers.isEmpty
        if hasSocialFeatures || inboxCaptureEnabled {
            lines.append("main = \"worker/worker.ts\"")
        }
```

with:

```swift
        let hasSocialFeatures = !workers.isEmpty
        // #1270 slice 3: a running experiment is the third enabler of Worker composition,
        // alongside an active catalog worker and inbox capture — a static-only site's first
        // running experiment gets a Worker for exactly its paths and nothing else (design §3).
        let composesWorker = hasSocialFeatures || inboxCaptureEnabled || hasRunningExperiment
        if composesWorker {
            lines.append("main = \"worker/worker.ts\"")
        }
```

4. Replace:

```swift
        if hasSocialFeatures || inboxCaptureEnabled {
            lines.append("binding = \"ASSETS\"")
            let patterns = WorkerRouteClaims.runWorkerFirstPatterns(effectiveClaims)
            if !patterns.isEmpty {
                let list = patterns.map { "\"\($0)\"" }.joined(separator: ", ")
                lines.append("run_worker_first = [\(list)]")
            }
        }
```

with:

```swift
        if composesWorker {
            lines.append("binding = \"ASSETS\"")
            var patterns = Set(WorkerRouteClaims.runWorkerFirstPatterns(effectiveClaims))
            patterns.formUnion(experimentRoutes.map(\.path))
            if !patterns.isEmpty {
                let list = patterns.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
                lines.append("run_worker_first = [\(list)]")
            }
        }
```

5. Right after the existing `DB` binding block (the `if workers.contains(where: { $0.resources.needsD1 }) { ... }` block that emits `binding = "DB"`), insert:

```swift
        // The shared per-site D1 database, bound a fifth time under EXPERIMENTS_DB — the binding
        // name and migration file (`worker/migrations/0002_experiments.sql`) are already fixed by
        // slice 1. Unlike DB/AUTH_DB/WEBMENTION_INBOX/MICROPUB_DB, this one carries its own
        // migrations_dir so a static-only site with no indieauth worker (and therefore no AUTH_DB
        // migrations-apply call) still gets the experiments schema applied.
        if hasRunningExperiment {
            lines.append("")
            lines.append("[[d1_databases]]")
            lines.append("binding = \"EXPERIMENTS_DB\"")
            lines.append("database_name = \"\(siteName)-social\"")
            lines.append("migrations_dir = \"worker/migrations\"")
            if let id = resources.d1DatabaseID, !id.isEmpty {
                lines.append("database_id = \"\(id)\"")
            } else {
                lines.append("database_id = \"\"  # filled by provisioning")
            }
        }
```

6. Replace the `[observability]` gate:

```swift
        if hasSocialFeatures || inboxCaptureEnabled {
            lines.append("")
            lines.append("[observability]")
```

with:

```swift
        if composesWorker {
            lines.append("")
            lines.append("[observability]")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter WorkerCompositionTests`
Expected: PASS (all `WorkerCompositionTests`, including the five new ones — every pre-existing test must also still pass, since `experiments` defaults to `[]` and `composesWorker` reduces to the old `hasSocialFeatures || inboxCaptureEnabled` whenever `hasRunningExperiment` is `false`).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WorkerComposition.swift Tests/AnglesiteCoreTests/WorkerCompositionTests.swift
git commit -m "feat(#1515): compose a Worker for a running experiment"
```

---

### Task 4: `SocialWorkerProvisionCommand.provision` provisions D1 for a running experiment

**Files:**
- Modify: `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift`
- Test: `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`

**Interfaces:**
- Consumes: `DomainConfig.Experiments.Experiment` (Task 1); `WorkerComposition.generateWranglerToml(..., experiments:)` (Task 3).
- Produces: `SocialWorkerProvisionCommand.provision(..., experiments: [DomainConfig.Experiments.Experiment] = [])` — new trailing parameter. Task 5 threads a caller-resolved array into this parameter at both of `provision`'s two composition-driven call sites (`SiteOperations.swift`, `DeployModel.swift`).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift`, near the other D1-provisioning tests:

```swift
    @Test("a running experiment on a static-only site (no active workers) provisions D1 and applies its migration")
    func runningExperimentProvisionsD1() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([
            ["d1", "create", "my-site-social", "--json"]: .init(stdout: #"{"result":{"uuid":"d1-id"}}"#, stderr: "", exitCode: 0),
            ["d1", "migrations", "apply", "EXPERIMENTS_DB", "--remote"]: .init(stdout: "Migrations applied", stderr: "", exitCode: 0),
        ])
        let deployer = DeployRecorder(result: .succeeded(url: URL(string: "https://my-site.example.workers.dev")!, duration: 1))
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, runner: recorder.runner, deployer: deployer.deployer)
        let experiment = DomainConfig.Experiments.Experiment(
            id: "homepage-hero", name: "Homepage headline", page: "/",
            variant: .init(id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/"),
            split: 0.5, goal: .init(kind: "pageview", path: "/contact/thanks/"), status: "running"
        )

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            workers: [], experiments: [experiment]
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.d1DatabaseID == "d1-id")
        #expect(await recorder.arguments == [
            ["d1", "create", "my-site-social", "--json"],
            ["d1", "migrations", "apply", "EXPERIMENTS_DB", "--remote"],
        ])
        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("binding = \"EXPERIMENTS_DB\""))
        #expect(toml.contains("database_id = \"d1-id\""))
        #expect(toml.contains(#"run_worker_first = ["/", "/contact/thanks/"]"#))
    }

    @Test("no running experiment never invokes the EXPERIMENTS_DB migration")
    func noRunningExperimentSkipsMigration() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([:])
        let deployer = DeployRecorder(result: .succeeded(url: URL(string: "https://my-site.example.workers.dev")!, duration: 1))
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, runner: recorder.runner, deployer: deployer.deployer)

        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site", workers: []
        )

        guard case .succeeded = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(await recorder.arguments.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: build fails — `provision` has no parameter `experiments`.

- [ ] **Step 3: Implement**

In `Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift`:

1. Add a new trailing parameter to `provision(...)`, after `moderators: [String]? = nil` (the last parameter, right before the closing `) async -> Result {`):

```swift
        moderators: [String]? = nil,
        /// The site's currently-declared experiments (`DomainConfig.Experiments.active`, #1270
        /// slice 3) — forwarded to `WorkerComposition.generateWranglerToml` unchanged. Only
        /// entries with `status == "running"` do anything: they extend the D1-provisioning gate
        /// below (so a static-only site's first running experiment still gets the shared
        /// `"\(siteName)-social"` database) and get their `EXPERIMENTS_DB` migration applied
        /// after `wrangler.toml` carries a concrete database id, mirroring the IndieAuth
        /// `AUTH_DB` migration below.
        experiments: [DomainConfig.Experiments.Experiment] = []
    ) async -> Result {
```

2. Right after `let started = Date()`, add:

```swift
        let hasRunningExperiment = experiments.contains(where: { $0.status == "running" })
```

3. Extend the D1-create gate — replace:

```swift
        if workers.contains(where: { $0.resources.needsD1 }) {
```

with:

```swift
        if workers.contains(where: { $0.resources.needsD1 }) || hasRunningExperiment {
```

(leave the rest of that `if` block's body unchanged for now — its `persistConfig` call is handled by the mechanical edit in step 5 below).

4. Thread `experiments` through `persistConfig`'s own signature and its call to `generateWranglerToml`. Replace:

```swift
    private func persistConfig(
        siteDirectory: URL,
        siteName: String,
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim],
        resources: WorkerComposition.ProvisionedResources,
        siteURL: String? = nil,
        displayName: String? = nil,
        apUsername: String? = nil,
        inboxCaptureEnabled: Bool = false,
        activityPubActorType: String? = nil,
        moderators: [String]? = nil
    ) -> Result? {
        do {
            let toml = try WorkerComposition.generateWranglerToml(
                siteName: siteName,
                workers: workers,
                routeClaims: routeClaims,
                resources: resources,
                inboxCaptureEnabled: inboxCaptureEnabled,
                inboxKVNamespaceID: resources.inboxKVNamespaceID,
                siteURL: siteURL,
                displayName: displayName,
                activityPubActorType: activityPubActorType,
                moderators: moderators,
                apUsername: apUsername
            )
```

with:

```swift
    private func persistConfig(
        siteDirectory: URL,
        siteName: String,
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim],
        resources: WorkerComposition.ProvisionedResources,
        siteURL: String? = nil,
        displayName: String? = nil,
        apUsername: String? = nil,
        inboxCaptureEnabled: Bool = false,
        activityPubActorType: String? = nil,
        moderators: [String]? = nil,
        experiments: [DomainConfig.Experiments.Experiment] = []
    ) -> Result? {
        do {
            let toml = try WorkerComposition.generateWranglerToml(
                siteName: siteName,
                workers: workers,
                routeClaims: routeClaims,
                resources: resources,
                inboxCaptureEnabled: inboxCaptureEnabled,
                inboxKVNamespaceID: resources.inboxKVNamespaceID,
                siteURL: siteURL,
                displayName: displayName,
                activityPubActorType: activityPubActorType,
                moderators: moderators,
                apUsername: apUsername,
                experiments: experiments
            )
```

5. Thread `experiments: experiments` into every call site of `persistConfig` inside `provision(...)`. There are three distinct literal call shapes repeated across the ten call sites — apply each edit with `replace_all: true`, and verify the match count first:

Run `grep -c 'persistConfig(siteDirectory: siteDirectory, siteName: siteName, workers: workers, routeClaims: routeClaims, resources: resources, siteURL: siteURL, displayName: displayName, apUsername: apUsername, inboxCaptureEnabled: inboxCaptureEnabled, activityPubActorType: activityPubActorType, moderators: moderators)' Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift` — expect `6`.

Replace all 6 occurrences of:
```swift
persistConfig(siteDirectory: siteDirectory, siteName: siteName, workers: workers, routeClaims: routeClaims, resources: resources, siteURL: siteURL, displayName: displayName, apUsername: apUsername, inboxCaptureEnabled: inboxCaptureEnabled, activityPubActorType: activityPubActorType, moderators: moderators)
```
with:
```swift
persistConfig(siteDirectory: siteDirectory, siteName: siteName, workers: workers, routeClaims: routeClaims, resources: resources, siteURL: siteURL, displayName: displayName, apUsername: apUsername, inboxCaptureEnabled: inboxCaptureEnabled, activityPubActorType: activityPubActorType, moderators: moderators, experiments: experiments)
```

Replace the 1 occurrence (inside the `inboxCaptureEnabled` block, which omits `apUsername`) of:
```swift
persistConfig(siteDirectory: siteDirectory, siteName: siteName, workers: workers, routeClaims: routeClaims, resources: resources, siteURL: siteURL, displayName: displayName, inboxCaptureEnabled: inboxCaptureEnabled, activityPubActorType: activityPubActorType, moderators: moderators)
```
with:
```swift
persistConfig(siteDirectory: siteDirectory, siteName: siteName, workers: workers, routeClaims: routeClaims, resources: resources, siteURL: siteURL, displayName: displayName, inboxCaptureEnabled: inboxCaptureEnabled, activityPubActorType: activityPubActorType, moderators: moderators, experiments: experiments)
```

Replace all 3 occurrences (the multi-line calls inside the webmention/websub/microsub queue-creation blocks) of:
```swift
            if let failure = persistConfig(
                siteDirectory: siteDirectory, siteName: siteName, workers: workers,
                routeClaims: routeClaims, resources: resources, siteURL: siteURL, displayName: displayName,
                apUsername: apUsername,
                inboxCaptureEnabled: inboxCaptureEnabled,
                activityPubActorType: activityPubActorType, moderators: moderators
            ) {
```
with:
```swift
            if let failure = persistConfig(
                siteDirectory: siteDirectory, siteName: siteName, workers: workers,
                routeClaims: routeClaims, resources: resources, siteURL: siteURL, displayName: displayName,
                apUsername: apUsername,
                inboxCaptureEnabled: inboxCaptureEnabled,
                activityPubActorType: activityPubActorType, moderators: moderators,
                experiments: experiments
            ) {
```

After editing, run `grep -c 'experiments: experiments' Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift` — expect `10` (the 10 `persistConfig` call sites; the `provision`→`persistConfig` parameter itself is not counted since it's declared, not referenced, as `experiments: experiments`... actually it will also match textually if any doc comment repeats it, so treat `10` as a floor, not an exact requirement — visually confirm all 10 call sites via `grep -n 'persistConfig('` instead if the count looks off).

6. Add the `EXPERIMENTS_DB` migration-apply step. Insert it right after the existing IndieAuth migration block:

```swift
        if workers.contains(where: { $0.id == WorkerComposition.indieauthWorkerID }) {
            let result = await runWrangler(
                siteDirectory: siteDirectory,
                arguments: ["d1", "migrations", "apply", "AUTH_DB", "--remote"],
                environment: environment,
                source: source,
                resources: resources
            )
            if case .failure(let failure) = result {
                return failure
            }
        }
```

insert immediately after it (still before `switch await deployer(...)`):

```swift
        // #1270 slice 3: mirrors the IndieAuth AUTH_DB migration above — applies once
        // wrangler.toml has a concrete database id (either from the D1 gate above, in this same
        // run, or already known from a prior run) and before publishing code that can record
        // experiment events.
        if hasRunningExperiment {
            let result = await runWrangler(
                siteDirectory: siteDirectory,
                arguments: ["d1", "migrations", "apply", "EXPERIMENTS_DB", "--remote"],
                environment: environment,
                source: source,
                resources: resources
            )
            if case .failure(let failure) = result {
                return failure
            }
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter SocialWorkerProvisionCommandTests`
Expected: PASS (all tests in the file, including the two new ones — every pre-existing test must also still pass unchanged, since `experiments` defaults to `[]` everywhere).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SocialWorkerProvisionCommand.swift Tests/AnglesiteCoreTests/SocialWorkerProvisionCommandTests.swift
git commit -m "feat(#1515): provision D1 for a static site's running experiment"
```

---

### Task 5: Wire running experiments into the two deploy call sites

**Files:**
- Modify: `Sources/AnglesiteCore/DeployCoordinator.swift`
- Modify: `Sources/AnglesiteCore/SiteOperations.swift`
- Modify: `Sources/AnglesiteApp/DeployModel.swift`
- Test: `Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift`

**Interfaces:**
- Consumes: `DomainConfig.Experiments.Experiment` (Task 1); `SocialWorkerProvisionCommand.provision(..., experiments:)` (Task 4).
- Produces: `DeployCoordinator.resolveRunningExperiments(sourceDirectory: URL) -> [DomainConfig.Experiments.Experiment]`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift`, near the existing `resolveIsHostedCommunity` tests (reuse the file's existing `temporaryDirectory()` helper):

```swift
    // MARK: - resolveRunningExperiments (#1515)

    @Test("resolveRunningExperiments returns only status == running entries")
    func resolveRunningExperimentsFiltersStatus() throws {
        let dir = try temporaryDirectory()
        let store = DomainConfigStore(sourceDirectory: dir)
        try store.save(DomainConfig(experiments: .init(active: [
            .init(
                id: "draft-one", name: "Draft", page: "/about",
                variant: .init(id: "b", name: "B", page: "/x/draft-one/b/"),
                split: 0.5, goal: .init(kind: "pageview", path: "/thanks/"), status: "draft"
            ),
            .init(
                id: "homepage-hero", name: "Homepage headline", page: "/",
                variant: .init(id: "b", name: "Fresh eggs headline", page: "/x/homepage-hero/b/"),
                split: 0.5, goal: .init(kind: "pageview", path: "/contact/thanks/"), status: "running"
            ),
        ])))
        let result = DeployCoordinator.resolveRunningExperiments(sourceDirectory: dir)
        #expect(result.map(\.id) == ["homepage-hero"])
    }

    @Test("resolveRunningExperiments is empty with no anglesite.json at all")
    func resolveRunningExperimentsEmptyByDefault() throws {
        let dir = try temporaryDirectory()
        #expect(DeployCoordinator.resolveRunningExperiments(sourceDirectory: dir).isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter DeployCoordinatorTests`
Expected: build fails — `DeployCoordinator` has no member `resolveRunningExperiments`.

- [ ] **Step 3: Add `resolveRunningExperiments`**

In `Sources/AnglesiteCore/DeployCoordinator.swift`, add near `resolveIsHostedCommunity`:

```swift
    /// The site's currently-declared running experiment(s) (`Source/anglesite.json`'s
    /// `experiments.active`, filtered to `status == "running"` — #1270 slice 3). Threaded into
    /// `SocialWorkerProvisionCommand.provision`/`WorkerComposition.generateWranglerToml` so a
    /// static-only site's first running experiment provisions the shared `{siteName}-social` D1
    /// database and composes a Worker for exactly its paths on the very next ordinary deploy —
    /// mirrors `resolveIsHostedCommunity`'s "read the declared config, default to the inert case
    /// on any failure" shape.
    public static func resolveRunningExperiments(sourceDirectory: URL) -> [DomainConfig.Experiments.Experiment] {
        let domainConfig = (try? DomainConfigStore(sourceDirectory: sourceDirectory).load()) ?? DomainConfig()
        return (domainConfig.experiments?.active ?? []).filter { $0.status == "running" }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter DeployCoordinatorTests`
Expected: PASS (all tests in the file, including the two new ones).

- [ ] **Step 5: Wire into `SiteOperations.deployWithWorkerComposition`**

In `Sources/AnglesiteCore/SiteOperations.swift`, replace:

```swift
        let provisionResult = await factory.socialWorkerProvision().provision(
            siteID: site.id,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            workers: workers,
            routeClaims: routeClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init(),
            // #934: this headless path (App Intents/Shortcuts/Siri) now sees the same active
            // dynamic /.well-known/ claims the GUI Deploy button already threads via
            // `DeployModel.runDeploy`'s custom deployer closure, so #744's collision check blocks
            // identically regardless of trigger.
            wellKnownDynamicClaims: WorkerRouteClaims.wellKnownClaims(routeClaims),
            activityPubActorType: isHostedCommunity ? "Group" : nil,
            moderators: isHostedCommunity ? settings.moderators : nil
        )
```

with:

```swift
        // #1515: mirrors DeployModel.runDeploy's identical resolveRunningExperiments read, so
        // this headless path (App Intents/Shortcuts/Siri) provisions a running experiment's D1
        // database identically regardless of trigger.
        let runningExperiments = DeployCoordinator.resolveRunningExperiments(sourceDirectory: siteDirectory)
        let provisionResult = await factory.socialWorkerProvision().provision(
            siteID: site.id,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            workers: workers,
            routeClaims: routeClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init(),
            // #934: this headless path (App Intents/Shortcuts/Siri) now sees the same active
            // dynamic /.well-known/ claims the GUI Deploy button already threads via
            // `DeployModel.runDeploy`'s custom deployer closure, so #744's collision check blocks
            // identically regardless of trigger.
            wellKnownDynamicClaims: WorkerRouteClaims.wellKnownClaims(routeClaims),
            activityPubActorType: isHostedCommunity ? "Group" : nil,
            moderators: isHostedCommunity ? settings.moderators : nil,
            experiments: runningExperiments
        )
```

- [ ] **Step 6: Wire into `DeployModel.runDeploy`**

In `Sources/AnglesiteApp/DeployModel.swift`, replace:

```swift
        let provisionResult = await socialCommand.provision(
            siteID: siteID,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            workers: workers,
            routeClaims: routeClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init(),
            siteURL: siteURL,
            displayName: settings.displayName,
            apUsername: apUsername,
            acknowledgesPaidPlan: acknowledgesPaidPlan,
            inboxCaptureEnabled: settings.inboxCaptureEnabled ?? false,
            activityPubActorType: isHostedCommunity ? "Group" : nil,
            moderators: isHostedCommunity ? settings.moderators : nil
        )
```

with:

```swift
        // #1515: a running experiment (declared in Source/anglesite.json, today only by a hand
        // edit or a future slice-5 UI) provisions its D1 database and composes into the Worker on
        // the very next ordinary deploy — mirrors resolveIsHostedCommunity's declared-config read
        // just above.
        let runningExperiments = DeployCoordinator.resolveRunningExperiments(sourceDirectory: siteDirectory)
        let provisionResult = await socialCommand.provision(
            siteID: siteID,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            workers: workers,
            routeClaims: routeClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init(),
            siteURL: siteURL,
            displayName: settings.displayName,
            apUsername: apUsername,
            acknowledgesPaidPlan: acknowledgesPaidPlan,
            inboxCaptureEnabled: settings.inboxCaptureEnabled ?? false,
            activityPubActorType: isHostedCommunity ? "Group" : nil,
            moderators: isHostedCommunity ? settings.moderators : nil,
            experiments: runningExperiments
        )
```

- [ ] **Step 7: Run the full test suite and build the app target**

Run: `swift test --package-path .`
Expected: PASS, no regressions.

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: build succeeds (this is the only way `DeployModel.swift`'s edit gets compiled outside a hosted Xcode-27 `swift test`; see this repo's CONTRIBUTING.md note that CI never executes `AnglesiteAppTests`).

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/DeployCoordinator.swift Sources/AnglesiteCore/SiteOperations.swift Sources/AnglesiteApp/DeployModel.swift Tests/AnglesiteCoreTests/DeployCoordinatorTests.swift
git commit -m "feat(#1515): provision a running experiment on every deploy"
```

---

## Self-Review

**Spec coverage** (against the issue #1515 body and design doc §10 slice 3):
- "`DomainConfig.Experiments` + store write-through" → Task 1 (model) + Task 1's tests confirm `DomainConfigStore`'s existing generic JSON-merge already handles the new section with no store code changes needed (verified by the round-trip and unknown-key tests).
- "`generateWranglerToml` learns experiments — `run_worker_first` emission including root and the beacon endpoint, experiments as the third enabler of Worker composition, collision validation against `WorkerRouteClaims`" → Task 3, exactly.
- "D1 provisioning on first start for static-only sites (reusing `{site}-social`, owner decision §12)" → Task 4 (the provisioning/migration machinery) + Task 5 (wiring the two real call sites so an ordinary deploy actually reaches that machinery once `anglesite.json` declares a running experiment).

**Placeholder scan:** no TBD/TODO, no "similar to Task N," every code step is a complete, pasteable snippet.

**Type consistency:** `DomainConfig.Experiments.Experiment` (Task 1) is the exact type used as the array element in `WorkerComposition.generateWranglerToml`'s `experiments` parameter (Task 3), `SocialWorkerProvisionCommand.provision`'s `experiments` parameter (Task 4), and `DeployCoordinator.resolveRunningExperiments`'s return type (Task 5) — no drift between tasks.

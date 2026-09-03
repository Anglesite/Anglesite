# Repo Bootstrap Implementation Plan (#68)

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a one-tap "Publish to GitHub" action that creates a private GitHub repo and pushes a site's `Source/` to it, so container runtimes (#66/#69) can hydrate by `git clone`.

**Architecture:** A new `AnglesiteCore` actor `RepoBootstrap` owns the git-side preflight (detect remote, init, commit) and orchestrates a `RepoProvider` for the create-remote-and-push step. The only provider today is `GHRepoProvider` (shells out to `gh`). The protocol seam keeps a future REST/token provider (MAS/iOS, #71) drop-in. The git remote (`origin`) is the source of truth for published state — no new persisted field. A thin `@MainActor @Observable PublishModel` drives a `PublishSheet` + a toolbar action in `SiteWindow`, gated `#if !ANGLESITE_MAS`.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27), Swift Testing (`import Testing`), `ProcessSupervisor` for subprocess spawning, `gh` + `git` CLIs, `GitHubAuthFlow`/`GitHubAuthSheetView` for the device-code auth flow.

## Global Constraints

- **ES/Swift idioms:** match surrounding code — actors for mutable lifecycle state, injected closures as test seams (`CommandRunner` pattern from `SiteScaffolder`).
- **Process spawning is centralized:** never call `Process()` directly; route through `ProcessSupervisor`. The runner seam type is `@Sendable (_ executable: URL, _ args: [String], _ cwd: URL?) async throws -> ProcessSupervisor.RunResult` (identical to `SiteScaffolder.CommandRunner`).
- **CLI invocation:** spawn `git`/`gh` as `URL(fileURLWithPath: "/usr/bin/env")` with the tool name as the first argument (mirrors `GitHubAuthFlow`), so `PATH` is respected.
- **Platform gating:** all UI that touches `gh` is wrapped `#if !ANGLESITE_MAS` (matches `GitHubAuthSheetView`). `AnglesiteCore` types are NOT gated (the `#if` is a no-op there).
- **Default repo visibility:** private.
- **Source of truth:** git `origin`. No new field in `Config/settings.plist`.
- **Test toolchain:** `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` before any SwiftPM command; run `xcrun swift test --filter <Suite>`. The default CommandLineTools toolchain is broken/too old.
- **Tests:** Swift Testing (`@Test`/`#expect`) in `Tests/AnglesiteCoreTests/`. Logic must live in `AnglesiteCore` (app-target/UI code is not run on CI).
- **Commit style:** conventional commits, scope `(#68)`, trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: `RemoteRepo` value type + remote-URL parsing

**Files:**
- Create: `Sources/AnglesiteCore/RepoBootstrapTypes.swift`
- Test: `Tests/AnglesiteCoreTests/RemoteRepoTests.swift`

**Interfaces:**
- Produces: `public struct RemoteRepo: Sendable, Equatable { let url: URL; let owner: String; let name: String }` with `static func parse(remoteURL: String) -> RemoteRepo?`; `public struct RepoBootstrapError: Error, Equatable, Sendable { let reason: String }`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct RemoteRepoTests {
    @Test func parsesHTTPSRemote() {
        let repo = RemoteRepo.parse(remoteURL: "https://github.com/acme/my-site.git\n")
        #expect(repo == RemoteRepo(url: URL(string: "https://github.com/acme/my-site")!, owner: "acme", name: "my-site"))
    }

    @Test func parsesSSHRemote() {
        let repo = RemoteRepo.parse(remoteURL: "git@github.com:acme/my-site.git")
        #expect(repo?.owner == "acme")
        #expect(repo?.name == "my-site")
        #expect(repo?.url == URL(string: "https://github.com/acme/my-site"))
    }

    @Test func stripsDotGitAndWhitespace() {
        let repo = RemoteRepo.parse(remoteURL: "  https://github.com/acme/site  ")
        #expect(repo?.name == "site")
    }

    @Test func rejectsGarbage() {
        #expect(RemoteRepo.parse(remoteURL: "") == nil)
        #expect(RemoteRepo.parse(remoteURL: "not-a-url") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer && xcrun swift test --filter RemoteRepoTests`
Expected: FAIL — `RemoteRepo` / `parse` not found (compile error).

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// A site's GitHub remote, derived from `origin`. Source of truth for "is this site published?".
public struct RemoteRepo: Sendable, Equatable {
    public let url: URL      // browser URL, e.g. https://github.com/owner/name
    public let owner: String
    public let name: String

    public init(url: URL, owner: String, name: String) {
        self.url = url
        self.owner = owner
        self.name = name
    }

    /// Parse a git remote URL (https or scp-like ssh) into owner/name + a browser URL.
    /// Returns nil for empty/unparseable input.
    public static func parse(remoteURL raw: String) -> RemoteRepo? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var owner = "", name = ""
        if trimmed.hasPrefix("git@") || (!trimmed.contains("://") && trimmed.contains(":")) {
            // scp-like: git@github.com:owner/name.git
            guard let colon = trimmed.firstIndex(of: ":") else { return nil }
            let path = trimmed[trimmed.index(after: colon)...].split(separator: "/")
            guard path.count >= 2 else { return nil }
            owner = String(path[path.count - 2])
            name = String(path[path.count - 1])
        } else if let u = URL(string: trimmed), u.host != nil {
            let comps = u.path.split(separator: "/")
            guard comps.count >= 2 else { return nil }
            owner = String(comps[comps.count - 2])
            name = String(comps[comps.count - 1])
        } else {
            return nil
        }

        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard !owner.isEmpty, !name.isEmpty, let browse = URL(string: "https://github.com/\(owner)/\(name)") else {
            return nil
        }
        return RemoteRepo(url: browse, owner: owner, name: name)
    }
}

/// User-facing failure from the bootstrap pipeline.
public struct RepoBootstrapError: Error, Equatable, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer && xcrun swift test --filter RemoteRepoTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/RepoBootstrapTypes.swift Tests/AnglesiteCoreTests/RemoteRepoTests.swift
git commit -m "$(printf 'feat(#68): RemoteRepo value type + remote-URL parsing\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: `RepoProvider` protocol + `GHRepoProvider`

**Files:**
- Modify: `Sources/AnglesiteCore/RepoBootstrapTypes.swift` (append protocol + gh impl)
- Test: `Tests/AnglesiteCoreTests/GHRepoProviderTests.swift`

**Interfaces:**
- Consumes: `RemoteRepo`, `RepoBootstrapError` (Task 1), `ProcessSupervisor.RunResult`.
- Produces:
  - `public typealias RepoCommandRunner = @Sendable (_ executable: URL, _ args: [String], _ cwd: URL?) async throws -> ProcessSupervisor.RunResult`
  - `public protocol RepoProvider: Sendable { func isAuthenticated() async -> Bool; func createAndPush(name: String, isPrivate: Bool, source: URL) async throws -> RemoteRepo }`
  - `public struct GHRepoProvider: RepoProvider { init(run: @escaping RepoCommandRunner) }`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct GHRepoProviderTests {
    /// Fake runner: matches on the first two args, returns a scripted RunResult.
    private func runner(_ table: [(match: [String], result: ProcessSupervisor.RunResult)]) -> RepoCommandRunner {
        { _, args, _ in
            for entry in table where Array(args.prefix(entry.match.count)) == entry.match {
                return entry.result
            }
            return ProcessSupervisor.RunResult(stdout: "", stderr: "no match for \(args)", exitCode: 127)
        }
    }
    private func ok(_ out: String = "") -> ProcessSupervisor.RunResult { .init(stdout: out, stderr: "", exitCode: 0) }
    private func fail(_ err: String, _ code: Int32 = 1) -> ProcessSupervisor.RunResult { .init(stdout: "", stderr: err, exitCode: code) }

    @Test func isAuthenticatedReflectsGhAuthStatus() async {
        let authed = GHRepoProvider(run: runner([(["gh", "auth"], ok())]))
        let notAuthed = GHRepoProvider(run: runner([(["gh", "auth"], fail("not logged in"))]))
        #expect(await authed.isAuthenticated() == true)
        #expect(await notAuthed.isAuthenticated() == false)
    }

    @Test func createAndPushReadsBackOrigin() async throws {
        let provider = GHRepoProvider(run: runner([
            (["gh", "repo", "create"], ok("https://github.com/acme/site\n")),
            (["git", "remote", "get-url"], ok("https://github.com/acme/site.git\n")),
        ]))
        let repo = try await provider.createAndPush(name: "site", isPrivate: true, source: URL(fileURLWithPath: "/tmp/s"))
        #expect(repo.owner == "acme")
        #expect(repo.name == "site")
    }

    @Test func createAndPushThrowsOnGhFailure() async {
        let provider = GHRepoProvider(run: runner([
            (["gh", "repo", "create"], fail("GraphQL: Name already exists on this account")),
        ]))
        await #expect(throws: RepoBootstrapError.self) {
            try await provider.createAndPush(name: "site", isPrivate: true, source: URL(fileURLWithPath: "/tmp/s"))
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer && xcrun swift test --filter GHRepoProviderTests`
Expected: FAIL — `RepoProvider`/`GHRepoProvider` not found.

- [ ] **Step 3: Write minimal implementation** (append to `RepoBootstrapTypes.swift`)

```swift
/// Run a subprocess and capture its output. Production: `ProcessSupervisor.shared.run`.
public typealias RepoCommandRunner = @Sendable (_ executable: URL, _ args: [String], _ cwd: URL?) async throws -> ProcessSupervisor.RunResult

/// Creates the remote repository and pushes to it. The part that differs between `gh` (DevID)
/// and a future REST/token impl (#71). Git-side preflight lives in `RepoBootstrap`, not here.
public protocol RepoProvider: Sendable {
    /// True if the provider has usable credentials (no interactive prompt needed).
    func isAuthenticated() async -> Bool
    /// Create the remote repo, wire `origin` in `source`, and push. Throws `RepoBootstrapError`.
    func createAndPush(name: String, isPrivate: Bool, source: URL) async throws -> RemoteRepo
}

/// GitHub provider backed by the `gh` CLI. Reuses `gh`'s credential store (per CLAUDE.md the app
/// does not own GitHub creds). DevID only — the UI that drives it is `#if !ANGLESITE_MAS`.
public struct GHRepoProvider: RepoProvider {
    private let run: RepoCommandRunner
    private let env = URL(fileURLWithPath: "/usr/bin/env")

    public init(run: @escaping RepoCommandRunner) { self.run = run }

    public func isAuthenticated() async -> Bool {
        guard let r = try? await run(env, ["gh", "auth", "status"], nil) else { return false }
        return r.exitCode == 0
    }

    public func createAndPush(name: String, isPrivate: Bool, source: URL) async throws -> RemoteRepo {
        let visibility = isPrivate ? "--private" : "--public"
        let create = try await run(env,
            ["gh", "repo", "create", name, visibility, "--source", source.path, "--remote", "origin", "--push"],
            source)
        guard create.exitCode == 0 else {
            throw RepoBootstrapError(reason: Self.firstLine(create.stderr) ?? "Couldn't create the GitHub repository.")
        }
        // origin is now set; read it back as the source of truth rather than parsing gh's output.
        let originRead = try await run(env, ["git", "remote", "get-url", "origin"], source)
        guard originRead.exitCode == 0, let repo = RemoteRepo.parse(remoteURL: originRead.stdout) else {
            throw RepoBootstrapError(reason: "Repository created, but couldn't read its origin URL.")
        }
        return repo
    }

    private static func firstLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).map(String.init).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer && xcrun swift test --filter GHRepoProviderTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/RepoBootstrapTypes.swift Tests/AnglesiteCoreTests/GHRepoProviderTests.swift
git commit -m "$(printf 'feat(#68): RepoProvider seam + gh-backed GHRepoProvider\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 3: `RepoBootstrap.remote(of:)` + git preflight

**Files:**
- Create: `Sources/AnglesiteCore/RepoBootstrap.swift`
- Test: `Tests/AnglesiteCoreTests/RepoBootstrapTests.swift`

**Interfaces:**
- Consumes: `RemoteRepo`, `RepoBootstrapError`, `RepoCommandRunner`, `RepoProvider` (Tasks 1–2).
- Produces:
  - `public actor RepoBootstrap { init(provider: RepoProvider, run: @escaping RepoCommandRunner) }`
  - `public func remote(of source: URL) async -> RemoteRepo?`
  - `func ensureCommittable(source: URL, emit: @Sendable (Event) -> Void) async throws` (internal — exercised here via a thin `@testable` wrapper)
  - `public enum Step: Sendable, Equatable { case checkingRemote, initializing, committing, creatingRepo, pushing }`
  - `public enum Event: Sendable, Equatable { case progress(step: Step, message: String); case needsAuth; case published(RemoteRepo); case failed(reason: String) }`

> **Note (refinement vs spec):** the spec sketched `.needsAuth(verificationURL:userCode:)`. The device-code prompt actually originates inside `GitHubAuthFlow` when the UI presents `GitHubAuthSheetView`, not inside `RepoBootstrap`. So `Event.needsAuth` carries no payload — it signals the model to present the auth sheet, then retry. This matches the design's "reuse `GitHubAuthSheetView`" intent.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct RepoBootstrapTests {
    actor CallLog { var calls: [[String]] = []; func add(_ a: [String]) { calls.append(a) } }

    /// Fake runner that records every invocation and returns scripted results by arg-prefix.
    private func runner(_ log: CallLog, _ table: [(match: [String], result: ProcessSupervisor.RunResult)]) -> RepoCommandRunner {
        { _, args, _ in
            await log.add(args)
            for entry in table where Array(args.prefix(entry.match.count)) == entry.match { return entry.result }
            return ProcessSupervisor.RunResult(stdout: "", stderr: "", exitCode: 1)
        }
    }
    private func ok(_ o: String = "") -> ProcessSupervisor.RunResult { .init(stdout: o, stderr: "", exitCode: 0) }
    private func fail(_ c: Int32 = 1) -> ProcessSupervisor.RunResult { .init(stdout: "", stderr: "", exitCode: c) }

    struct StubProvider: RepoProvider {
        let authed: Bool
        let result: Result<RemoteRepo, RepoBootstrapError>
        func isAuthenticated() async -> Bool { authed }
        func createAndPush(name: String, isPrivate: Bool, source: URL) async throws -> RemoteRepo {
            try result.get()
        }
    }
    private func repo() -> RemoteRepo { .init(url: URL(string: "https://github.com/acme/site")!, owner: "acme", name: "site") }

    @Test func remoteReturnsParsedRepoWhenOriginSet() async {
        let log = CallLog()
        let b = RepoBootstrap(
            provider: StubProvider(authed: true, result: .success(repo())),
            run: runner(log, [(["git", "remote", "get-url"], ok("https://github.com/acme/site.git"))]))
        #expect(await b.remote(of: URL(fileURLWithPath: "/tmp/s"))?.owner == "acme")
    }

    @Test func remoteReturnsNilWhenNoOrigin() async {
        let log = CallLog()
        let b = RepoBootstrap(
            provider: StubProvider(authed: true, result: .success(repo())),
            run: runner(log, [(["git", "remote", "get-url"], fail())]))
        #expect(await b.remote(of: URL(fileURLWithPath: "/tmp/s")) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer && xcrun swift test --filter RepoBootstrapTests`
Expected: FAIL — `RepoBootstrap` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// One-tap "Publish to GitHub". Owns the git-side preflight (detect remote, init, commit) and
/// delegates the create-remote-and-push step to a `RepoProvider`. See #68 / the design doc.
///
/// The git `origin` is the source of truth for published state — `remote(of:)` reads it; nothing
/// is persisted app-side. Every `git`/`gh` invocation goes through the injected `RepoCommandRunner`
/// (production: `ProcessSupervisor.shared.run`), so tests drive the flow without spawning anything.
public actor RepoBootstrap {
    public enum Step: Sendable, Equatable { case checkingRemote, initializing, committing, creatingRepo, pushing }

    public enum Event: Sendable, Equatable {
        case progress(step: Step, message: String)
        /// Provider has no credentials. The UI presents `GitHubAuthSheetView`, then retries `publish`.
        case needsAuth
        case published(RemoteRepo)
        case failed(reason: String)
    }

    private let provider: RepoProvider
    private let run: RepoCommandRunner
    private let env = URL(fileURLWithPath: "/usr/bin/env")

    public init(provider: RepoProvider, run: @escaping RepoCommandRunner) {
        self.provider = provider
        self.run = run
    }

    /// Reads `origin`; nil if there's no remote or `source` isn't a git repo.
    public func remote(of source: URL) async -> RemoteRepo? {
        guard let r = try? await run(env, ["git", "remote", "get-url", "origin"], source),
              r.exitCode == 0 else { return nil }
        return RemoteRepo.parse(remoteURL: r.stdout)
    }

    /// `git init` if needed, then commit if there are no commits or a dirty tree. Throws on git error.
    func ensureCommittable(source: URL, emit: @Sendable (Event) -> Void) async throws {
        let inside = try? await run(env, ["git", "rev-parse", "--is-inside-work-tree"], source)
        if inside?.exitCode != 0 {
            emit(.progress(step: .initializing, message: "Initializing git repository…"))
            let initR = try await run(env, ["git", "init"], source)
            guard initR.exitCode == 0 else { throw RepoBootstrapError(reason: "git init failed.\n\(initR.stderr)") }
        }

        let head = try? await run(env, ["git", "rev-parse", "HEAD"], source)
        let status = try await run(env, ["git", "status", "--porcelain"], source)
        let noCommits = head?.exitCode != 0
        let dirty = !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard noCommits || dirty else { return }

        emit(.progress(step: .committing, message: "Committing your site…"))
        let add = try await run(env, ["git", "add", "-A"], source)
        guard add.exitCode == 0 else { throw RepoBootstrapError(reason: "git add failed.\n\(add.stderr)") }
        let commit = try await run(env, ["git", "commit", "-m", "Initial commit"], source)
        guard commit.exitCode == 0 else { throw RepoBootstrapError(reason: "git commit failed.\n\(commit.stderr)") }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer && xcrun swift test --filter RepoBootstrapTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/RepoBootstrap.swift Tests/AnglesiteCoreTests/RepoBootstrapTests.swift
git commit -m "$(printf 'feat(#68): RepoBootstrap.remote(of:) + git preflight\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 4: `RepoBootstrap.publish(...)` orchestration + production factory

**Files:**
- Modify: `Sources/AnglesiteCore/RepoBootstrap.swift` (add `publish`, `live`)
- Modify: `Tests/AnglesiteCoreTests/RepoBootstrapTests.swift` (add orchestration tests)

**Interfaces:**
- Consumes: everything from Task 3, plus `ProcessSupervisor`, `LogCenter`.
- Produces:
  - `public nonisolated func publish(source: URL, repoName: String, isPrivate: Bool) -> AsyncStream<Event>`
  - `public static func live(supervisor: ProcessSupervisor = .shared) -> RepoBootstrap`

- [ ] **Step 1: Write the failing tests** (append inside `RepoBootstrapTests`)

```swift
    /// Drain a publish stream into an array.
    private func collect(_ stream: AsyncStream<RepoBootstrap.Event>) async -> [RepoBootstrap.Event] {
        var out: [RepoBootstrap.Event] = []
        for await e in stream { out.append(e) }
        return out
    }

    @Test func publishShortCircuitsWhenAlreadyPublished() async {
        let log = CallLog()
        let b = RepoBootstrap(
            provider: StubProvider(authed: true, result: .success(repo())),
            run: runner(log, [(["git", "remote", "get-url"], ok("https://github.com/acme/site.git"))]))
        let events = await collect(b.publish(source: URL(fileURLWithPath: "/tmp/s"), repoName: "site", isPrivate: true))
        #expect(events.last == .published(repo()))
        // No git init / commit attempted.
        #expect(await !log.calls.contains(["git", "init"]))
    }

    @Test func publishEmitsNeedsAuthWhenNotAuthenticated() async {
        let log = CallLog()
        let b = RepoBootstrap(
            provider: StubProvider(authed: false, result: .success(repo())),
            run: runner(log, [(["git", "remote", "get-url"], fail())]))   // no origin
        let events = await collect(b.publish(source: URL(fileURLWithPath: "/tmp/s"), repoName: "site", isPrivate: true))
        #expect(events.contains(.needsAuth))
        #expect(events.last == .needsAuth)
    }

    @Test func publishInitsCommitsThenPublishes() async {
        let log = CallLog()
        let b = RepoBootstrap(
            provider: StubProvider(authed: true, result: .success(repo())),
            run: runner(log, [
                (["git", "remote", "get-url"], fail()),                 // no origin → proceed
                (["git", "rev-parse", "--is-inside-work-tree"], fail()), // not a repo → init
                (["git", "init"], ok()),
                (["git", "rev-parse", "HEAD"], fail()),                  // no commits → commit
                (["git", "status"], ok(" M file")),
                (["git", "add"], ok()),
                (["git", "commit"], ok()),
            ]))
        let events = await collect(b.publish(source: URL(fileURLWithPath: "/tmp/s"), repoName: "site", isPrivate: true))
        #expect(events.last == .published(repo()))
        #expect(await log.calls.contains(["git", "init"]))
        #expect(await log.calls.contains(["git", "commit", "-m", "Initial commit"]))
    }

    @Test func publishSurfacesProviderError() async {
        let log = CallLog()
        let b = RepoBootstrap(
            provider: StubProvider(authed: true, result: .failure(RepoBootstrapError(reason: "Name already exists"))),
            run: runner(log, [
                (["git", "remote", "get-url"], fail()),
                (["git", "rev-parse", "--is-inside-work-tree"], ok()),   // already a repo
                (["git", "rev-parse", "HEAD"], ok("abc123")),            // has commits
                (["git", "status"], ok("")),                             // clean
            ]))
        let events = await collect(b.publish(source: URL(fileURLWithPath: "/tmp/s"), repoName: "site", isPrivate: true))
        #expect(events.last == .failed(reason: "Name already exists"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer && xcrun swift test --filter RepoBootstrapTests`
Expected: FAIL — `publish` not found.

- [ ] **Step 3: Write minimal implementation** (add to `RepoBootstrap`)

```swift
    /// Detect → (auth) → ensure committable → create + push. Streams progress; settles to
    /// `.published` / `.needsAuth` / `.failed`. Idempotent: an already-published site yields
    /// `.published(existing)` with no side effects.
    public nonisolated func publish(source: URL, repoName: String, isPrivate: Bool) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                let emit: @Sendable (Event) -> Void = { continuation.yield($0) }

                emit(.progress(step: .checkingRemote, message: "Checking for an existing remote…"))
                if let existing = await self.remote(of: source) {
                    emit(.published(existing)); continuation.finish(); return
                }

                if await self.provider.isAuthenticated() == false {
                    emit(.needsAuth); continuation.finish(); return
                }

                do {
                    try await self.ensureCommittable(source: source, emit: emit)
                    emit(.progress(step: .creatingRepo, message: "Creating private repository on GitHub…"))
                    let created = try await self.provider.createAndPush(name: repoName, isPrivate: isPrivate, source: source)
                    emit(.progress(step: .pushing, message: "Pushed to \(created.url.absoluteString)"))
                    emit(.published(created))
                } catch let err as RepoBootstrapError {
                    emit(.failed(reason: err.reason))
                } catch {
                    emit(.failed(reason: "\(error)"))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Production wiring: `git`/`gh` run through `ProcessSupervisor.shared.run` (mirrors how
    /// `SiteScaffolder` shells out for one-shot commands; output is captured into the surfaced
    /// reason rather than streamed, since these are short-lived).
    public static func live(supervisor: ProcessSupervisor = .shared) -> RepoBootstrap {
        let runner: RepoCommandRunner = { executable, args, cwd in
            try await supervisor.run(executable: executable, arguments: args, currentDirectoryURL: cwd)
        }
        return RepoBootstrap(provider: GHRepoProvider(run: runner), run: runner)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer && xcrun swift test --filter RepoBootstrapTests`
Expected: PASS (6 tests total in the suite).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/RepoBootstrap.swift Tests/AnglesiteCoreTests/RepoBootstrapTests.swift
git commit -m "$(printf 'feat(#68): RepoBootstrap.publish orchestration + live factory\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 5: `PublishModel` (app target)

**Files:**
- Create: `Sources/AnglesiteApp/PublishModel.swift`

**Interfaces:**
- Consumes: `RepoBootstrap`, `RemoteRepo`, `RepoBootstrap.Event` (Tasks 3–4).
- Produces (consumed by Task 6):
  - `@MainActor @Observable final class PublishModel`
  - `enum Phase: Equatable { case idle; case running(milestone: String); case needsAuth; case published(RemoteRepo); case failed(reason: String) }`
  - `private(set) var phase: Phase`
  - `var sheetPresented: Bool`
  - `var authSheetPresented: Bool`
  - `private(set) var existingRemote: RemoteRepo?`
  - `var isRunning: Bool { if case .running = phase { true } else { false } }`
  - `func refreshRemote(source: URL)`
  - `func publish(source: URL, repoName: String)`
  - `func authCompleted(source: URL, repoName: String)`  // retry after auth sheet success
  - `func dismiss()`

> No unit test: this is `@MainActor` app-target glue with all branching in `RepoBootstrap` (which is fully tested). App-target/UI code is not run on CI per CLAUDE.md. Verified manually in Task 6.

- [ ] **Step 1: Create the model**

```swift
import SwiftUI
import AnglesiteCore

/// SwiftUI-facing wrapper around `RepoBootstrap`. Drives one publish at a time, mirrors the
/// `DeployModel` shape (a `Phase`, an `isRunning` flag, a sheet-presentation flag). All decision
/// logic lives in `RepoBootstrap`; this only maps events to view state.
@MainActor
@Observable
final class PublishModel {
    enum Phase: Equatable {
        case idle
        case running(milestone: String)
        case needsAuth
        case published(RemoteRepo)
        case failed(reason: String)
    }

    private(set) var phase: Phase = .idle
    /// Remote read on window open; drives the toolbar label (Publish vs View on GitHub).
    private(set) var existingRemote: RemoteRepo?

    /// Bound to the progress/result sheet in `SiteWindow`.
    var sheetPresented: Bool = false
    /// Bound to `GitHubAuthSheetView` when the provider needs `gh auth login`.
    var authSheetPresented: Bool = false

    var isRunning: Bool { if case .running = phase { return true }; return false }

    private let bootstrap: RepoBootstrap
    private var inFlight: Task<Void, Never>?

    init(bootstrap: RepoBootstrap = .live()) { self.bootstrap = bootstrap }

    /// Cheap read of `origin` to decide the toolbar label. Safe to call on window open.
    func refreshRemote(source: URL) {
        Task { self.existingRemote = await bootstrap.remote(of: source) }
    }

    func publish(source: URL, repoName: String) {
        guard !isRunning else { return }
        phase = .running(milestone: "Starting…")
        sheetPresented = true
        inFlight?.cancel()
        inFlight = Task { await self.consume(bootstrap.publish(source: source, repoName: repoName, isPrivate: true), source: source) }
    }

    /// Re-run publish after the user finishes `gh auth login` in the auth sheet.
    func authCompleted(source: URL, repoName: String) {
        authSheetPresented = false
        publish(source: source, repoName: repoName)
    }

    func dismiss() { sheetPresented = false }

    private func consume(_ stream: AsyncStream<RepoBootstrap.Event>, source: URL) async {
        for await event in stream {
            switch event {
            case .progress(_, let message): phase = .running(milestone: message)
            case .needsAuth:
                phase = .needsAuth
                authSheetPresented = true
                sheetPresented = false
            case .published(let repo):
                phase = .published(repo)
                existingRemote = repo
            case .failed(let reason):
                phase = .failed(reason: reason)
            }
        }
    }
}
```

- [ ] **Step 2: Build the app target to verify it compiles**

Run: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer && xcrun xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.
(If `Anglesite.xcodeproj` is missing, run `xcodegen generate` first — and in a worktree run `scripts/copy-plugin.sh` once to populate `Resources/plugin`; set `ANGLESITE_PLUGIN_SRC` to the real plugin checkout.)

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/PublishModel.swift
git commit -m "$(printf 'feat(#68): PublishModel — SwiftUI wrapper over RepoBootstrap\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 6: `PublishSheet` + `SiteWindow` toolbar wiring

**Files:**
- Create: `Sources/AnglesiteApp/PublishSheet.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (add `@State publish`, toolbar item, sheets, `refreshRemote` on appear)

**Interfaces:**
- Consumes: `PublishModel` (Task 5), `GitHubAuthSheetView` (existing), `site.sourceDirectory`, `site.name`, `site.id`.

> No unit test (UI in app target). Verified by build + manual smoke (Step 4).

- [ ] **Step 1: Create the sheet**

```swift
#if !ANGLESITE_MAS
import SwiftUI
import AnglesiteCore

/// Progress + result for "Publish to GitHub". The auth sub-flow is a separate sheet
/// (`GitHubAuthSheetView`) presented by `SiteWindow` when the model enters `.needsAuth`.
struct PublishSheet: View {
    @Bindable var model: PublishModel
    let siteName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Publish “\(siteName)” to GitHub").font(.headline)
            content
            Divider()
            HStack {
                Spacer()
                Button("Done") { model.dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isRunning)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .needsAuth:
            ProgressView().controlSize(.small)
        case .running(let milestone):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(milestone).foregroundStyle(.secondary) }
        case .published(let repo):
            VStack(alignment: .leading, spacing: 8) {
                Label("Published to GitHub", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Link(repo.url.absoluteString, destination: repo.url)
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn’t publish", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif
```

- [ ] **Step 2: Wire into `SiteWindow`**

Add the model near the other `@State` models (`SiteWindow.swift:54`, beside `@State private var deploy = DeployModel()`):

```swift
#if !ANGLESITE_MAS
    @State private var publish = PublishModel()
#endif
```

Add a toolbar item inside the `.toolbar { … }` block (place it just before the Deploy `ToolbarItem` at `SiteWindow.swift:278`, so Deploy stays the trailing primary action):

```swift
#if !ANGLESITE_MAS
            // Publish to GitHub — create+push a remote, or open it if one already exists (#68).
            ToolbarItem(placement: .primaryAction) {
                if let remote = publish.existingRemote {
                    Button {
                        NSWorkspace.shared.open(remote.url)
                    } label: {
                        Label("View on GitHub", systemImage: "arrow.up.forward.square")
                    }
                    .help("Open this site’s GitHub repository")
                } else {
                    Button {
                        publish.publish(source: site.sourceDirectory, repoName: site.name)
                    } label: {
                        Label("Publish to GitHub", systemImage: "square.and.arrow.up.on.square")
                    }
                    .disabled(publish.isRunning || !site.isValid)
                    .help(site.isValid ? "Create a private GitHub repo and push this site" : "Site is missing required files")
                }
            }
            .visibilityPriority(.low)
#endif
```

Add the sheets next to the existing `.sheet(isPresented: $deploy.…)` modifiers (after `SiteWindow.swift:315`):

```swift
#if !ANGLESITE_MAS
        .sheet(isPresented: $publish.sheetPresented) {
            PublishSheet(model: publish, siteName: site.name)
        }
        .sheet(isPresented: $publish.authSheetPresented) {
            GitHubAuthSheetView { result in
                switch result {
                case .authenticated:
                    publish.authCompleted(source: site.sourceDirectory, repoName: site.name)
                case .failed, .cancelled:
                    publish.authSheetPresented = false
                }
            }
        }
#endif
```

Refresh the remote when the window appears. Find the view's existing `.task` / `.onAppear` on the root container (search `SiteWindow.swift` for `.task {` or `.onAppear`); add inside it:

```swift
#if !ANGLESITE_MAS
            publish.refreshRemote(source: site.sourceDirectory)
#endif
```

If there is no existing `.onAppear`/`.task` on the root view, add:

```swift
        .onAppear {
            #if !ANGLESITE_MAS
            publish.refreshRemote(source: site.sourceDirectory)
            #endif
        }
```

- [ ] **Step 3: Build both targets**

Run:
```
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -3
xcrun xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -3
```
Expected: both `** BUILD SUCCEEDED **`. (The MAS build proves the `#if !ANGLESITE_MAS` gating compiles cleanly with the Publish UI excluded.)

- [ ] **Step 4: Manual smoke (DevID)**

1. Launch `Anglesite`, open a site with no remote → toolbar shows **Publish to GitHub**.
2. Click it. If `gh` isn't authed, the auth sheet appears; complete it → publish retries.
3. On success: sheet shows the repo URL; toolbar collapses to **View on GitHub**.
4. Verify on GitHub the repo exists (private) and `git -C <Source> remote get-url origin` returns it.
5. Reopen the window → toolbar shows **View on GitHub** immediately (remote read on appear).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/PublishSheet.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "$(printf 'feat(#68): Publish to GitHub toolbar action + sheet in SiteWindow\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Final verification

- [ ] Run the full `AnglesiteCore` suite: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer && xcrun swift test --filter 'RemoteRepoTests|GHRepoProviderTests|RepoBootstrapTests'` → all pass.
- [ ] Both Xcode schemes build.
- [ ] Manual smoke (Task 6 Step 4) passes.
- [ ] Update issue #68 checklist; note #66/#69 can now call `RepoBootstrap.remote(of:)`/`.publish(...)` for hydration remediation.

## Self-review notes

- **Spec coverage:** detect-no-remote (Task 3 `remote(of:)`), one-tap create+push with init/commit (Tasks 2–4, 6), explicit trigger (Task 6 toolbar), private default (`isPrivate: true` in `PublishModel.publish`), `RepoProvider` seam for MAS/iOS (Task 2), git-as-source-of-truth (no persisted field; `refreshRemote`), surface-the-error collision handling (Task 4 `publishSurfacesProviderError`). The "remediation when a runtime can't hydrate" surface is intentionally deferred (no runtime exists) but the API it will call (`publish`/`remote`) ships here.
- **Refinement vs spec:** `Event.needsAuth` carries no payload (device prompt originates in `GitHubAuthFlow`); documented in Task 3.
- **Type consistency:** `RepoCommandRunner` signature is identical everywhere; `RemoteRepo`/`RepoBootstrapError`/`RepoProvider`/`Step`/`Event` names match across tasks.

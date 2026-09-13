import Testing
import Foundation
@testable import AnglesiteCore

/// Drives `RepoBootstrap`'s preflight (`remote(of:)`, `ensureCommittable`) against real temp git
/// repos rather than a mocked `RepoCommandRunner` — on Darwin those methods run in-process via
/// SwiftGit2 (#654) and no longer consult `run` at all. Mirrors the real-repo fixture pattern
/// established by `NativeContentOperationsTests` for the same reason (#649/#640). `git` subprocess
/// calls below are purely test-fixture setup (init/config/remote/seed-commit), not exercising the
/// code under test — off-Darwin, where `RepoBootstrap` itself still uses subprocess git, that
/// distinction disappears but the fixtures remain valid.
@Suite struct RepoBootstrapTests {
    @Test func bootstrapErrorUsesItsReasonAsTheUserFacingDescription() {
        let error = RepoBootstrapError(reason: "No git identity configured.")
        #expect(error.localizedDescription == "No git identity configured.")
    }

    struct StubProvider: RepoProvider {
        let authed: Bool
        let result: Result<RemoteRepo, RepoBootstrapError>
        func isAuthenticated() async -> Bool { authed }
        func createAndPush(name: String, isPrivate: Bool, source: URL) async throws -> RemoteRepo {
            try result.get()
        }
    }

    /// Provider that records the `name` passed to `createAndPush` so tests can assert it was slugified.
    actor CapturingProvider: RepoProvider {
        var capturedName: String?
        let result: Result<RemoteRepo, RepoBootstrapError>
        init(result: Result<RemoteRepo, RepoBootstrapError>) { self.result = result }
        func isAuthenticated() async -> Bool { true }
        func createAndPush(name: String, isPrivate: Bool, source: URL) async throws -> RemoteRepo {
            capturedName = name
            return try result.get()
        }
    }

    private func repo() -> RemoteRepo { .init(url: URL(string: "https://github.com/acme/site")!, owner: "acme", name: "site") }

    /// Drain a publish stream into an array.
    private func collect(_ stream: AsyncStream<RepoBootstrap.Event>) async -> [RepoBootstrap.Event] {
        var out: [RepoBootstrap.Event] = []
        for await e in stream { out.append(e) }
        return out
    }

    /// `RepoBootstrap`'s initializer still takes a `RepoCommandRunner` (shared with `GHRepoProvider`
    /// and the off-Darwin preflight fallback), but the Darwin preflight under test here never calls
    /// it — a runner that always fails makes that assumption loud if it ever stops holding.
    private func unusedRunner() -> RepoCommandRunner {
        { _, _, _ in ProcessSupervisor.RunResult(stdout: "", stderr: "", exitCode: 1) }
    }

    /// A fresh temp directory, optionally already a git repo (with local identity configured so
    /// `defaultSignature()` resolves deterministically), optionally with a seed commit and/or an
    /// `origin` remote. `initialized: false` leaves a plain directory — the "not yet a repo, needs
    /// `git init`" fixture.
    private func makeSourceDir(
        initialized: Bool, commit: Bool = false, remoteURL: String? = nil
    ) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard initialized else { return dir }

        let git = URL(fileURLWithPath: "/usr/bin/git")
        func run(_ args: [String]) async throws {
            _ = try await ProcessSupervisor.shared.run(source: "test", executable: git, arguments: args, currentDirectoryURL: dir)
        }
        try await run(["init"])
        try await run(["config", "user.email", "t@t.io"])
        try await run(["config", "user.name", "t"])
        // Isolate from the developer's ambient global excludesFile (e.g. `~/.gitignore`
        // containing `.env`, common on real dev machines) the same way user.email/user.name
        // are pinned above — otherwise a repo-local `.env` that also matches the *global*
        // ignore rules is classified "ignored" rather than "untracked" by both real git and
        // libgit2, so it never reaches `git status`/`repo.status(...)` and the dotenv-secret
        // guard under test never sees it.
        try await run(["config", "core.excludesFile", "/dev/null"])
        if let remoteURL { try await run(["remote", "add", "origin", remoteURL]) }
        if commit {
            try "seed".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try await run(["add", "-A"])
            try await run(["commit", "-m", "seed"])
        }
        return dir
    }

    @Test func publishShortCircuitsWhenAlreadyPublished() async throws {
        let source = try await makeSourceDir(initialized: true, commit: true, remoteURL: "https://github.com/acme/site.git")
        let b = RepoBootstrap(provider: StubProvider(authed: true, result: .success(repo())), run: unusedRunner())
        let events = await collect(b.publish(source: source, repoName: "site", isPrivate: true))
        #expect(events.last == .published(repo()))
        // Short-circuits before even checking auth — .needsAuth must never appear.
        #expect(!events.contains(.needsAuth))
    }

    @Test func publishEmitsNeedsAuthWhenNotAuthenticated() async throws {
        let source = try await makeSourceDir(initialized: true, commit: true)   // no origin
        let b = RepoBootstrap(provider: StubProvider(authed: false, result: .success(repo())), run: unusedRunner())
        let events = await collect(b.publish(source: source, repoName: "site", isPrivate: true))
        #expect(events.contains(.needsAuth))
        #expect(events.last == .needsAuth)
    }

    @Test func publishInitializesRepoWhenNotYetOne() async throws {
        // Not yet a repo — `ensureCommittable` must `Repository.create` (git init's SwiftGit2
        // equivalent) before attempting to commit. Deliberately does NOT assert `.published`/that
        // the commit itself succeeds: `defaultSignature()` resolves against the ambient git
        // config (global/system), which a fresh temp directory with no prior `git config` has no
        // control over — on a CI runner with no ambient user.name/user.email this legitimately
        // fails with `.failed(reason: "No git identity configured…")`, same as real `git commit`
        // would. The commit step itself (staging + committing once identity IS configured) is
        // exercised deterministically by every other test here via `makeSourceDir`, which sets
        // local identity explicitly — that logic doesn't care whether the `Repository` handle
        // came from `.create` (this path) or `.at` (an already-existing repo), so this test only
        // needs to prove the init half actually ran.
        let source = try await makeSourceDir(initialized: false)
        try "hello".write(to: source.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        let b = RepoBootstrap(provider: StubProvider(authed: true, result: .success(repo())), run: unusedRunner())
        let events = await collect(b.publish(source: source, repoName: "site", isPrivate: true))
        #expect(events.contains(.progress(step: .initializing, message: "Initializing git repository…")))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent(".git").path))
    }

    @Test func publishCommitsFirstCommitThenPublishes() async throws {
        // Complements `publishInitializesRepoWhenNotYetOne`: a repo that already exists (local
        // identity configured deterministically by `makeSourceDir`, unlike ambient config) but has
        // no commits yet must still stage and commit before publishing.
        let source = try await makeSourceDir(initialized: true)   // no commit — first commit is due
        try "hello".write(to: source.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        let b = RepoBootstrap(provider: StubProvider(authed: true, result: .success(repo())), run: unusedRunner())
        let events = await collect(b.publish(source: source, repoName: "site", isPrivate: true))
        #expect(events.last == .published(repo()))
        #expect(events.contains(.progress(step: .committing, message: "Committing your site…")))
        // Never took the init path — the repo was already there.
        #expect(!events.contains(.progress(step: .initializing, message: "Initializing git repository…")))
    }

    @Test func scaffoldCommitPreservesConfiguredIdentity() async throws {
        let source = try await makeSourceDir(initialized: true)
        try "hello".write(to: source.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)

        let bootstrap = RepoBootstrap(
            provider: StubProvider(authed: true, result: .success(repo())),
            run: unusedRunner()
        )
        try await bootstrap.commitAll(source: source)

        let result = try await ProcessSupervisor.shared.run(
            source: "test",
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["log", "-1", "--format=%an <%ae>"],
            currentDirectoryURL: source
        )
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "t <t@t.io>")
    }

    @Test func publishSurfacesProviderError() async throws {
        let source = try await makeSourceDir(initialized: true, commit: true)   // clean, has commits
        let b = RepoBootstrap(
            provider: StubProvider(authed: true, result: .failure(RepoBootstrapError(reason: "Name already exists"))),
            run: unusedRunner())
        let events = await collect(b.publish(source: source, repoName: "site", isPrivate: true))
        #expect(events.last == .failed(reason: "Name already exists"))
    }

    @Test func remoteReturnsParsedRepoWhenOriginSet() async throws {
        let source = try await makeSourceDir(initialized: true, remoteURL: "https://github.com/acme/site.git")
        let b = RepoBootstrap(provider: StubProvider(authed: true, result: .success(repo())), run: unusedRunner())
        #expect(await b.remote(of: source)?.owner == "acme")
    }

    @Test func remoteReturnsNilWhenNoOrigin() async throws {
        let source = try await makeSourceDir(initialized: true)
        let b = RepoBootstrap(provider: StubProvider(authed: true, result: .success(repo())), run: unusedRunner())
        #expect(await b.remote(of: source) == nil)
    }

    @Test func remoteReturnsNilOutsideAGitRepo() async throws {
        let source = try await makeSourceDir(initialized: false)
        let b = RepoBootstrap(provider: StubProvider(authed: true, result: .success(repo())), run: unusedRunner())
        #expect(await b.remote(of: source) == nil)
    }

    @Test func publishSlugifiesDisplayName() async throws {
        // Display names with spaces/punctuation must be slugified before reaching the provider.
        let source = try await makeSourceDir(initialized: true, commit: true)
        let capturing = CapturingProvider(result: .success(repo()))
        let b = RepoBootstrap(provider: capturing, run: unusedRunner())
        _ = await collect(b.publish(source: source, repoName: "My Cool Site!", isPrivate: true))
        #expect(await capturing.capturedName == "my-cool-site")
    }

    @Test func publishRefusesWhenDotenvWouldBeCommitted() async throws {
        // A dirty tree containing a .env file must abort before staging — never create the repo.
        let source = try await makeSourceDir(initialized: true, commit: true)
        try "SECRET=1".write(to: source.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "page".write(to: source.appendingPathComponent("page.astro"), atomically: true, encoding: .utf8)
        let capturing = CapturingProvider(result: .success(repo()))
        let b = RepoBootstrap(provider: capturing, run: unusedRunner())
        let events = await collect(b.publish(source: source, repoName: "site", isPrivate: true))
        if case .failed(let reason) = events.last {
            #expect(reason.contains(".env"))
        } else {
            Issue.record("expected .failed, got \(String(describing: events.last))")
        }
        #expect(await capturing.capturedName == nil)   // never created the repo

        // Nothing was staged — the .env file is still untracked, not sitting in the index.
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let status = try await ProcessSupervisor.shared.run(
            source: "test",
            executable: git, arguments: ["status", "--porcelain"], currentDirectoryURL: source)
        #expect(status.stdout.contains("?? .env"))
    }

    @Test func publishRefusesWhenNestedDotenvWouldBeCommitted() async throws {
        // .env.local nested in a subdirectory must be caught the same way as a top-level .env.
        let source = try await makeSourceDir(initialized: true, commit: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("config"), withIntermediateDirectories: true)
        try "SECRET=1".write(to: source.appendingPathComponent("config/.env.local"), atomically: true, encoding: .utf8)
        let b = RepoBootstrap(
            provider: StubProvider(authed: true, result: .success(repo())), run: unusedRunner())
        let events = await collect(b.publish(source: source, repoName: "site", isPrivate: true))
        if case .failed(let reason) = events.last {
            #expect(reason.contains(".env.local"))
        } else {
            Issue.record("expected .failed, got \(String(describing: events.last))")
        }
    }

    @Test func publishStagesAndCommitsFilesInNewSubdirectories() async throws {
        // A new, non-secret file nested in a brand-new directory must still get staged and
        // committed — the same recursion gap that hid nested .env secrets would otherwise also
        // silently drop ordinary nested content from the "add -A" equivalent.
        let source = try await makeSourceDir(initialized: true, commit: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("src/pages"), withIntermediateDirectories: true)
        try "hello".write(to: source.appendingPathComponent("src/pages/about.md"), atomically: true, encoding: .utf8)
        let b = RepoBootstrap(
            provider: StubProvider(authed: true, result: .success(repo())), run: unusedRunner())
        let events = await collect(b.publish(source: source, repoName: "site", isPrivate: true))
        #expect(events.last == .published(repo()))

        let git = URL(fileURLWithPath: "/usr/bin/git")
        let show = try await ProcessSupervisor.shared.run(
            source: "test",
            executable: git, arguments: ["show", "--stat", "HEAD"], currentDirectoryURL: source)
        #expect(show.stdout.contains("src/pages/about.md"))
    }

    @Test func publishStagesAndCommitsADeletedFile() async throws {
        // A file removed from the working tree since the last commit must be staged for removal
        // (repo.remove(path:)) and the deletion committed — the "git rm" half of "add -A", with no
        // coverage before this test (review finding on PR #663).
        let source = try await makeSourceDir(initialized: true, commit: true)   // seeds README.md
        try FileManager.default.removeItem(at: source.appendingPathComponent("README.md"))
        let b = RepoBootstrap(
            provider: StubProvider(authed: true, result: .success(repo())), run: unusedRunner())
        let events = await collect(b.publish(source: source, repoName: "site", isPrivate: true))
        #expect(events.last == .published(repo()))

        let git = URL(fileURLWithPath: "/usr/bin/git")
        let status = try await ProcessSupervisor.shared.run(
            source: "test",
            executable: git, arguments: ["status", "--porcelain"], currentDirectoryURL: source)
        #expect(status.stdout.isEmpty)   // deletion was committed, not left dangling
        let show = try await ProcessSupervisor.shared.run(
            source: "test",
            executable: git, arguments: ["show", "--stat", "HEAD"], currentDirectoryURL: source)
        #expect(show.stdout.contains("README.md"))
    }

    @Test func publishRefusesOnATrulyEmptyDirectory() async throws {
        // git-init'd (or about-to-be), nothing to stage, no commits — must fail loudly rather than
        // silently create a content-less root commit and a real, empty GitHub repo (review finding
        // on PR #663; matches the old subprocess `git commit`'s "nothing to commit" refusal).
        let source = try await makeSourceDir(initialized: true)   // configured identity, no files, no commit
        let b = RepoBootstrap(
            provider: StubProvider(authed: true, result: .success(repo())), run: unusedRunner())
        let events = await collect(b.publish(source: source, repoName: "site", isPrivate: true))
        if case .failed(let reason) = events.last {
            #expect(reason.contains("Nothing to commit"))
        } else {
            Issue.record("expected .failed, got \(String(describing: events.last))")
        }
    }
}

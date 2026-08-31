import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for deploy-target selection (#1682, #1015 slice 3) — the mapping from the persisted
/// `DomainConfig.deployTarget` string to a `DeployTarget` conformer, and `DeployCommand`'s use of
/// that mapping as its production default. The conformers' own behavior is covered by
/// `GitHubPagesDeployTargetTests`/`DeployCommandTests`; these tests only assert *which* conformer
/// a given site resolves to, and that a resolved target is the one `deploy` actually publishes
/// through.
struct DeployTargetSelectionTests {
    /// A fresh temp site directory per test, so `DomainConfigStore` reads/writes don't collide
    /// across tests and each test starts with no `anglesite.json`.
    private func makeSiteDirectory() throws -> URL {
        let siteDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeployTargetSelectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: siteDirectory, withIntermediateDirectories: true)
        return siteDirectory
    }

    private func writeDeployTarget(_ value: String?, to siteDirectory: URL) throws {
        var config = DomainConfig()
        config.deployTarget = value
        try DomainConfigStore(sourceDirectory: siteDirectory).save(config)
    }

    /// A `DeployExecutor` that records every step it ran and answers each with a canned result —
    /// enough to drive build → preflight → the target's own publish step without a subprocess.
    private final class FakeExecutor: DeployExecutor, @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [DeployStep] = []

        func ran(_ step: DeployStep) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return steps.contains { "\($0)" == "\(step)" }
        }

        func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult {
            lock.lock()
            steps.append(step)
            lock.unlock()
            switch step {
            case .preflight:
                return DeployStepResult(exitCode: 0, output: #"{"version":1,"ok":true,"failures":[],"warnings":[]}"#)
            case .wrangler:
                return DeployStepResult(exitCode: 0, output: "Published x (0.1 sec)\n  https://x.workers.dev")
            default:
                return DeployStepResult(exitCode: 0, output: "")
            }
        }
    }

    // MARK: Identifier → conformer

    @Test("the GitHub Pages identifier selects the GitHub Pages conformer")
    func githubPagesIdentifierSelectsItsConformer() {
        #expect(DeployTargetSelection.target(forID: GitHubPagesDeployTarget.id) is GitHubPagesDeployTarget)
    }

    @Test("nil, the Cloudflare identifier, and an unrecognized value all select Cloudflare")
    func unrecognizedIdentifiersSelectCloudflare() {
        #expect(DeployTargetSelection.target(forID: nil) is CloudflareDeployTarget)
        #expect(DeployTargetSelection.target(forID: CloudflareDeployTarget.id) is CloudflareDeployTarget)
        #expect(DeployTargetSelection.target(forID: "netlify-from-a-future-app-version") is CloudflareDeployTarget)
        #expect(DeployTargetSelection.target(forID: "") is CloudflareDeployTarget)
    }

    // MARK: Canonical identifier

    @Test("canonicalID normalizes every unrecognized declaration to Cloudflare")
    func canonicalIDNormalizesUnrecognizedDeclarations() {
        #expect(DeployTargetSelection.canonicalID(forDeclared: GitHubPagesDeployTarget.id) == GitHubPagesDeployTarget.id)
        #expect(DeployTargetSelection.canonicalID(forDeclared: CloudflareDeployTarget.id) == CloudflareDeployTarget.id)
        #expect(DeployTargetSelection.canonicalID(forDeclared: nil) == CloudflareDeployTarget.id)
        #expect(DeployTargetSelection.canonicalID(forDeclared: "") == CloudflareDeployTarget.id)
        #expect(DeployTargetSelection.canonicalID(forDeclared: "netlify-from-a-future-app-version") == CloudflareDeployTarget.id)
    }

    /// The picker reads `canonicalID(forDeclared:)` and the deploy path reads `target(forID:)`; if
    /// those two ever disagreed, Settings could show a host the site wouldn't really deploy to.
    /// Pinning the agreement here is what lets a third conformer be added by touching one switch.
    @Test("canonicalID and target(forID:) name the same conformer for every declaration")
    func canonicalIDAgreesWithTargetSelection() {
        let declarations: [String?] = [
            nil, "", CloudflareDeployTarget.id, GitHubPagesDeployTarget.id,
            "netlify-from-a-future-app-version", "GitHubPages", " githubPages "
        ]
        for declared in declarations {
            let canonical = DeployTargetSelection.canonicalID(forDeclared: declared)
            #expect(
                DeployTargetSelection.selectableIDs.contains(canonical),
                "canonicalID must only ever return an offerable identifier, got \(canonical)")
            #expect(
                type(of: DeployTargetSelection.target(forID: declared))
                    == type(of: DeployTargetSelection.target(forID: canonical)),
                "\(declared ?? "nil") canonicalizes to \(canonical) but selects a different conformer")
        }
    }

    // MARK: Site directory → conformer

    @Test("a site declaring githubPages in anglesite.json resolves to the GitHub Pages conformer")
    func siteDeclaringGitHubPagesResolvesToItsConformer() throws {
        let siteDirectory = try makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        try writeDeployTarget(GitHubPagesDeployTarget.id, to: siteDirectory)
        #expect(DeployTargetSelection.target(sourceDirectory: siteDirectory) is GitHubPagesDeployTarget)
    }

    @Test("a site with no anglesite.json at all resolves to Cloudflare")
    func siteWithNoDeclarationResolvesToCloudflare() throws {
        let siteDirectory = try makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        #expect(DeployTargetSelection.target(sourceDirectory: siteDirectory) is CloudflareDeployTarget)
    }

    @Test("a site declaring an unrecognized target resolves to Cloudflare")
    func siteDeclaringUnknownTargetResolvesToCloudflare() throws {
        let siteDirectory = try makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        try writeDeployTarget("some-host-this-app-predates", to: siteDirectory)
        #expect(DeployTargetSelection.target(sourceDirectory: siteDirectory) is CloudflareDeployTarget)
    }

    // MARK: DeployCommand wiring

    @Test("DeployCommand's production default resolves the target from the site's own declaration")
    func deployCommandDefaultResolverReadsTheSiteDeclaration() throws {
        let githubPagesSite = try makeSiteDirectory()
        let cloudflareSite = try makeSiteDirectory()
        defer {
            try? FileManager.default.removeItem(at: githubPagesSite)
            try? FileManager.default.removeItem(at: cloudflareSite)
        }
        try writeDeployTarget(GitHubPagesDeployTarget.id, to: githubPagesSite)
        let command = DeployCommand()
        #expect(command.target(for: githubPagesSite) is GitHubPagesDeployTarget)
        #expect(command.target(for: cloudflareSite) is CloudflareDeployTarget)
    }

    @Test("an explicitly injected target still wins for every site directory")
    func injectedTargetPinsEveryDirectory() throws {
        let siteDirectory = try makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        try writeDeployTarget(GitHubPagesDeployTarget.id, to: siteDirectory)
        let command = DeployCommand(target: CloudflareDeployTarget(tokenSource: { "tok" }))
        #expect(
            command.target(for: siteDirectory) is CloudflareDeployTarget,
            "a caller that pinned a target (SocialWorkerProvisionCommand's Cloudflare-only deploy, and every test) must not be re-resolved out from under it")
    }

    /// The seam `DeployModel.runDeploy` uses to freeze one attempt's selection: it resolves the
    /// site's target once, then pins it so the Cloudflare-only closures it builds and `deploy()`'s
    /// own authorize-then-publish pair can't be resolved against different reads of a file the
    /// owner can edit mid-deploy.
    @Test("pinning(target:) freezes the selection while keeping the command's executor")
    func pinningFreezesTheSelection() async throws {
        let siteDirectory = try makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        try writeDeployTarget(GitHubPagesDeployTarget.id, to: siteDirectory)
        let executor = FakeExecutor()
        let command = DeployCommand(executor: executor)
            .pinning(target: CloudflareDeployTarget(tokenSource: { "cf-token" }))

        #expect(command.target(for: siteDirectory) is CloudflareDeployTarget)
        // The injected executor survived the copy — a `pinning` that dropped it would silently
        // fall back to `HostDeployExecutor` and try to spawn a real subprocess here.
        let result = await command.deploy(siteID: "s", siteDirectory: siteDirectory)
        guard case .succeeded = result else {
            Issue.record("expected .succeeded, got \(result)"); return
        }
        #expect(executor.ran(.wrangler))
        #expect(!executor.ran(.githubPagesPublish))
    }

    // MARK: End-to-end through deploy()

    @Test("a githubPages site publishes through the GitHub Pages target, never through wrangler")
    func githubPagesSitePublishesThroughItsTarget() async throws {
        let siteDirectory = try makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        // Both the target choice and an already-provisioned Pages repo are declared, so `publish`
        // reuses the declared repo instead of calling the GitHub API to create one.
        var config = DomainConfig()
        config.deployTarget = GitHubPagesDeployTarget.id
        config.githubPages = DomainConfig.GitHubPages(owner: "acme", repo: "acme-pages")
        try DomainConfigStore(sourceDirectory: siteDirectory).save(config)

        let executor = FakeExecutor()
        let command = DeployCommand(
            targetResolver: { directory -> any DeployTarget in
                // The production shape, with the one seam a test can't use as-is (the Keychain
                // token source) replaced by a literal.
                if DeployTargetSelection.target(sourceDirectory: directory) is GitHubPagesDeployTarget {
                    return GitHubPagesDeployTarget(tokenSource: { "gh-token" })
                }
                return CloudflareDeployTarget(tokenSource: { "cf-token" })
            },
            executor: executor)

        let result = await command.deploy(siteID: "s", siteDirectory: siteDirectory)
        guard case .succeeded(let url, _) = result else {
            Issue.record("expected .succeeded, got \(result)"); return
        }
        #expect(url == URL(string: "https://acme.github.io/acme-pages/")!)
        #expect(executor.ran(.githubPagesPublish))
        #expect(!executor.ran(.wrangler), "a GitHub Pages site must never reach the Cloudflare publish step")
    }

    @Test("a site with no declaration still publishes through Cloudflare, unchanged")
    func undeclaredSiteStillPublishesThroughCloudflare() async throws {
        let siteDirectory = try makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        let executor = FakeExecutor()
        let command = DeployCommand(
            targetResolver: { directory -> any DeployTarget in
                if DeployTargetSelection.target(sourceDirectory: directory) is GitHubPagesDeployTarget {
                    return GitHubPagesDeployTarget(tokenSource: { "gh-token" })
                }
                return CloudflareDeployTarget(tokenSource: { "cf-token" })
            },
            executor: executor)

        let result = await command.deploy(siteID: "s", siteDirectory: siteDirectory)
        guard case .succeeded = result else {
            Issue.record("expected .succeeded, got \(result)"); return
        }
        #expect(executor.ran(.wrangler))
        #expect(!executor.ran(.githubPagesPublish))
    }
}

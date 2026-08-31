import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteAppCore

/// A `DeployExecutor` that records which steps ran and answers each with a canned success, so a
/// full `DeployModel.deploy` can run without a subprocess.
private final class RecordingDeployExecutor: DeployExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []

    func ran(_ step: DeployStep) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return steps.contains("\(step)")
    }

    func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult {
        lock.lock(); steps.append("\(step)"); lock.unlock()
        switch step {
        case .preflight:
            return DeployStepResult(exitCode: 0, output: #"{"version":1,"ok":true,"failures":[],"warnings":[]}"#)
        case .wrangler:
            return DeployStepResult(exitCode: 0, output: "Published s (0.1 sec)\n  https://s.workers.dev")
        default:
            return DeployStepResult(exitCode: 0, output: "")
        }
    }
}

/// `DeployModel`'s side of deploy-target selection (#1682): the per-site resolution reaching the
/// `command.target(for:) as? CloudflareDeployTarget` downcast that feeds
/// `SocialWorkerProvisionCommand`'s two Cloudflare-only closures.
///
/// `.timeLimit`: matching `DeployModelTests`' own trait — see #1349 for why a wedged test in this
/// target must fail rather than hang.
@Suite("DeployModel deploy target (#1682)", .timeLimit(.minutes(1)))
@MainActor
struct DeployModelDeployTargetTests {
    private func makeSiteDirectory(deployTarget: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeployModelDeployTargetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A license is already recorded, so the first-publish license gate (#999) doesn't block
        // this test before it reaches what it actually exercises.
        try LicensingStore(sourceDirectory: directory).save(LicensingPolicy(licenseChosen: true))
        if let deployTarget {
            DomainConfigStore.update(sourceDirectory: directory) { $0.deployTarget = deployTarget }
        }
        return directory
    }

    @Test("a GitHub Pages site degrades to a reported failure, never a crash, on the Cloudflare-only closures")
    func githubPagesSiteDegradesSafely() async throws {
        let executor = RecordingDeployExecutor()
        // The production resolver's shape, with the Keychain token source replaced by a literal.
        let command = DeployCommand(
            targetResolver: { directory -> any DeployTarget in
                if DeployTargetSelection.target(sourceDirectory: directory) is GitHubPagesDeployTarget {
                    return GitHubPagesDeployTarget(tokenSource: { "gh-token" })
                }
                return CloudflareDeployTarget(tokenSource: { "cf-token" })
            },
            executor: executor)
        let model = DeployModel(command: command, logCenter: LogCenter(), tokenAvailabilityOverride: { true })
        let directory = try makeSiteDirectory(deployTarget: GitHubPagesDeployTarget.id)

        model.deploy(siteID: "s", siteDirectory: directory, configDirectory: directory, currentRoutes: [])
        while model.isRunning { await Task.yield() }

        // `SocialWorkerProvisionCommand` is a Cloudflare Workers concept end to end, so with a
        // GitHub Pages target its injected `tokenSource`/`workerScriptNamesSource` closures return
        // `nil`/`[]` and it reports a missing Cloudflare token — the deploy stops, but nothing
        // traps and the failure is surfaced through the model's normal terminal phase. Making
        // that stop legible to the owner (and unreachable through the Workers UI at all) is
        // #1683's capability gating; this test pins the safe-degrade contract in the meantime.
        guard case .failed(let reason, _) = model.phase else {
            Issue.record("expected a reported .failed phase, got \(model.phase)"); return
        }
        #expect(reason.contains("CLOUDFLARE_API_TOKEN"))
        #expect(!executor.ran(.wrangler), "a GitHub Pages site must never reach the Cloudflare publish step")
    }

    @Test("a site with no declaration still deploys through Cloudflare, unchanged")
    func undeclaredSiteStillDeploysThroughCloudflare() async throws {
        let executor = RecordingDeployExecutor()
        let command = DeployCommand(
            targetResolver: { directory -> any DeployTarget in
                if DeployTargetSelection.target(sourceDirectory: directory) is GitHubPagesDeployTarget {
                    return GitHubPagesDeployTarget(tokenSource: { "gh-token" })
                }
                return CloudflareDeployTarget(tokenSource: { "cf-token" })
            },
            executor: executor)
        let model = DeployModel(command: command, logCenter: LogCenter(), tokenAvailabilityOverride: { true })
        let directory = try makeSiteDirectory(deployTarget: nil)

        model.deploy(siteID: "s", siteDirectory: directory, configDirectory: directory, currentRoutes: [])
        while model.isRunning { await Task.yield() }

        #expect(executor.ran(.wrangler))
        #expect(!executor.ran(.githubPagesPublish))
    }

    /// A deploy attempt must resolve its target exactly once (#1682 review). `runDeploy` reads the
    /// target up front to build `SocialWorkerProvisionCommand`'s Cloudflare-only closures, and
    /// `DeployCommand.deploy` reads it again for its own authorize-then-publish pair — with
    /// several `await`s in between and a production resolver that re-reads `anglesite.json` from
    /// disk every time. If those stayed two independent reads, an owner flipping Website Settings
    /// ▸ Publishing mid-deploy could have the two halves of one attempt disagree about where the
    /// site publishes.
    ///
    /// The resolver here rewrites the declaration on its *first* call, so a second read would
    /// necessarily come back as GitHub Pages: reaching the Cloudflare publish step (and only one
    /// resolution) is the proof that the attempt is pinned to a single target.
    @Test("a deploy attempt resolves its target once, even if the declaration changes mid-deploy")
    func targetIsResolvedOncePerAttempt() async throws {
        let executor = RecordingDeployExecutor()
        let resolutions = Counter()
        let directory = try makeSiteDirectory(deployTarget: nil)
        let command = DeployCommand(
            targetResolver: { resolvedDirectory -> any DeployTarget in
                let target = DeployTargetSelection.target(sourceDirectory: resolvedDirectory)
                if resolutions.increment() == 1 {
                    // Stands in for the owner switching the Publishing picker while this attempt
                    // is in flight — the picker writes through immediately, with no in-flight guard.
                    DomainConfigStore.update(sourceDirectory: resolvedDirectory) {
                        $0.deployTarget = GitHubPagesDeployTarget.id
                    }
                }
                if target is GitHubPagesDeployTarget { return GitHubPagesDeployTarget(tokenSource: { "gh-token" }) }
                return CloudflareDeployTarget(tokenSource: { "cf-token" })
            },
            executor: executor)
        let model = DeployModel(command: command, logCenter: LogCenter(), tokenAvailabilityOverride: { true })

        model.deploy(siteID: "s", siteDirectory: directory, configDirectory: directory, currentRoutes: [])
        while model.isRunning { await Task.yield() }

        #expect(resolutions.value == 1, "the attempt re-read the declaration \(resolutions.value) times")
        #expect(executor.ran(.wrangler), "the attempt must publish through the target it started with")
        #expect(!executor.ran(.githubPagesPublish))
    }
}

/// A thread-safe call counter — the resolver runs off the MainActor, so a plain `var` capture
/// wouldn't compile under strict concurrency.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// - Returns: the call ordinal, 1 for the first call.
    @discardableResult func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

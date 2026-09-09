import Testing
import Foundation
@testable import AnglesiteCore

/// #1958 (owner decision D5): `DeployCommand.deploy` verifies the app-owned script set against
/// the app's own copy before anything else runs — a tampered gate blocks (and is restored and
/// committed), a restored one deploys, an untouched one is unaffected. The same spine serves the
/// GUI and the headless App Intents path, so one set of tests covers both.
struct DeployCommandGateTests {
    /// A host-style executor: runs steps "at" the site directory, so it has no runtime copy of
    /// its own and the host verification is the whole gate.
    private final class FakeExecutor: DeployExecutor, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var steps: [String] = []
        func reportOwnedPathClaims() async -> [RuntimeOwnedPathClaim] { [] }
        func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult {
            lock.withLock {
                switch step {
                case .build: steps.append("build"); return DeployStepResult(exitCode: 0, output: "")
                case .preflight:
                    steps.append("preflight")
                    return DeployStepResult(exitCode: 0, output: #"{"version":1,"ok":true,"failures":[],"warnings":[]}"#)
                case .wrangler:
                    steps.append("wrangler")
                    return DeployStepResult(exitCode: 0, output: "Published x (0.1 sec)\n  https://x.workers.dev")
                default: steps.append("other"); return DeployStepResult(exitCode: 0, output: "")
                }
            }
        }
        func ran(_ step: String) -> Bool { lock.withLock { steps.contains(step) } }
    }

    /// A container-style executor: the same steps, plus a runtime copy of its own whose digests
    /// are scripted and whose restores are recorded.
    private final class RuntimeFakeExecutor: DeployExecutor, AppOwnedScriptsRuntimeVerifying, @unchecked Sendable {
        private let lock = NSLock()
        private let inner = FakeExecutor()
        private var digests: [String: String?]
        private(set) var restored: [String] = []
        init(digests: [String: String?]) { self.digests = digests }
        func reportOwnedPathClaims() async -> [RuntimeOwnedPathClaim] { [] }
        func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult {
            await inner.run(step: step, siteDirectory: siteDirectory, environment: environment, source: source)
        }
        func ran(_ step: String) -> Bool { inner.ran(step) }
        func digestAppOwnedScripts(relativePaths: [String], source: String) async -> AppOwnedScriptsGate.RuntimeCopy.Digests {
            lock.withLock {
                var out: [String: String?] = [:]
                for path in relativePaths { out[path] = digests[path] ?? nil }
                return .digests(out)
            }
        }
        func restoreAppOwnedScripts(_ pins: [AppOwnedScriptsGate.Pin], source: String) async -> Bool {
            lock.withLock {
                for pin in pins {
                    restored.append(pin.relativePath)
                    digests[pin.relativePath] = pin.sha256
                }
                return true
            }
        }
    }

    private func writeFile(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A template + a site whose app-owned files match it exactly. The site is a real git repo
    /// with a seed commit and a pinned identity, so the restore's commit can be observed.
    private func makeFixture() async throws -> (site: URL, template: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deploy-gate-\(UUID().uuidString)", isDirectory: true)
        let site = root.appendingPathComponent("Source", isDirectory: true)
        let template = root.appendingPathComponent("Template", isDirectory: true)
        for relativePath in ["scripts/pre-deploy-check.ts", "src/lib/rsl.ts"] {
            try writeFile("app copy of \(relativePath)", to: template.appendingPathComponent(relativePath))
            try writeFile("app copy of \(relativePath)", to: site.appendingPathComponent(relativePath))
        }
        let git = URL(fileURLWithPath: "/usr/bin/git")
        for args in [["init", "-q"], ["config", "user.email", "t@t.io"], ["config", "user.name", "t"],
                     ["add", "-A"], ["commit", "-q", "-m", "seed"]] {
            _ = try await ProcessSupervisor.shared.run(executable: git, arguments: args, currentDirectoryURL: site)
        }
        return (site, template, root)
    }

    private func git(_ args: [String], in site: URL) async throws -> String {
        let result = try await ProcessSupervisor.shared.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: args, currentDirectoryURL: site)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func command(executor: any DeployExecutor, template: URL) -> DeployCommand {
        DeployCommand(
            target: CloudflareDeployTarget(tokenSource: { "tok" }), executor: executor,
            templateDirectory: { template })
    }

    private final class Observer: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var outcome: PreDeployCheck.Outcome?
        func record(_ o: PreDeployCheck.Outcome) { lock.lock(); outcome = o; lock.unlock() }
    }

    @Test("an untouched app-owned script set deploys normally")
    func untouchedScriptsDeploy() async throws {
        let (site, template, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let exec = FakeExecutor()
        let result = await command(executor: exec, template: template).deploy(siteID: "s", siteDirectory: site)
        guard case .succeeded = result else { Issue.record("expected .succeeded, got \(result)"); return }
        #expect(exec.ran("build") && exec.ran("preflight") && exec.ran("wrangler"))
        #expect(try await git(["log", "-1", "--format=%s"], in: site) == "seed")
    }

    @Test("a tampered gate script blocks before the build, is restored, and the restore is committed")
    func tamperedGateBlocksAndRestores() async throws {
        let (site, template, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile("export {} // scan disabled", to: site.appendingPathComponent("scripts/pre-deploy-check.ts"))
        let exec = FakeExecutor()
        let observer = Observer()

        let result = await command(executor: exec, template: template).deploy(
            siteID: "s", siteDirectory: site, onPreflight: { outcome in observer.record(outcome) })

        guard case .blocked(let failures, let warnings) = result else {
            Issue.record("expected .blocked, got \(result)"); return
        }
        #expect(warnings.isEmpty)
        #expect(failures.count == 1)
        #expect(failures.first?.category == .appOwnedScriptRestored)
        #expect(failures.first?.message == "Anglesite's safety check on this site had been changed. It has been restored.")
        #expect(!exec.ran("build") && !exec.ran("preflight") && !exec.ran("wrangler"),
                "a changed gate must refuse before spending time on a build, and never run the changed scan")
        // Restored on disk…
        let content = try String(contentsOf: site.appendingPathComponent("scripts/pre-deploy-check.ts"), encoding: .utf8)
        #expect(content == "app copy of scripts/pre-deploy-check.ts")
        // …and committed, so the owner's history records it and the guest clone can fast-forward.
        #expect(try await git(["log", "-1", "--format=%s"], in: site) == AppOwnedScriptsGate.commitMessage)
        #expect(try await git(["status", "--porcelain"], in: site) == "")
        // The observer saw the same outcome the sheet will render.
        if case .blocked(let f, _) = observer.outcome {
            #expect(f.first?.category == .appOwnedScriptRestored)
        } else {
            Issue.record("expected the preflight observer to see the gate block, got \(String(describing: observer.outcome))")
        }
    }

    @Test("the deploy after a restore proceeds")
    func restoredGateDeploysNextTime() async throws {
        let (site, template, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile("tampered", to: site.appendingPathComponent("src/lib/rsl.ts"))
        let first = FakeExecutor()
        guard case .blocked = await command(executor: first, template: template).deploy(siteID: "s", siteDirectory: site) else {
            Issue.record("first attempt should block"); return
        }
        let second = FakeExecutor()
        let result = await command(executor: second, template: template).deploy(siteID: "s", siteDirectory: site)
        guard case .succeeded = result else { Issue.record("expected .succeeded after restore, got \(result)"); return }
        #expect(second.ran("wrangler"))
    }

    @Test("a missing app template is logged as unverifiable and the deploy proceeds")
    func missingTemplateIsUnverifiable() async throws {
        let (site, _, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let exec = FakeExecutor()
        let cmd = DeployCommand(
            target: CloudflareDeployTarget(tokenSource: { "tok" }), executor: exec, templateDirectory: { nil })
        let result = await cmd.deploy(siteID: "s", siteDirectory: site)
        guard case .succeeded = result else { Issue.record("expected .succeeded, got \(result)"); return }
    }

    @Test("pinning(target:) keeps the gate's template seam")
    func pinningKeepsTemplateSeam() async throws {
        let (site, template, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile("tampered", to: site.appendingPathComponent("scripts/pre-deploy-check.ts"))
        let exec = FakeExecutor()
        let base = command(executor: exec, template: template)
        let pinned = base.pinning(target: base.target(for: site))
        guard case .blocked = await pinned.deploy(siteID: "s", siteDirectory: site) else {
            Issue.record("the pinned command must verify against the same template"); return
        }
    }

    @Test("a container executor's own copy is verified too: an in-guest edit blocks and is restored there")
    func runtimeCopyIsVerified() async throws {
        let (site, template, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pins = AppOwnedScriptsGate.pins(templateDirectory: template)
        var digests: [String: String?] = Dictionary(uniqueKeysWithValues: pins.map { ($0.relativePath, Optional($0.sha256)) })
        digests["scripts/pre-deploy-check.ts"] = PortableSHA256.hexDigest(of: Data("disabled in the guest".utf8))
        let exec = RuntimeFakeExecutor(digests: digests)

        let first = await command(executor: exec, template: template).deploy(siteID: "s", siteDirectory: site)
        guard case .blocked(let failures, _) = first else { Issue.record("expected .blocked, got \(first)"); return }
        #expect(failures.first?.category == .appOwnedScriptRestored)
        #expect(!exec.ran("build"))
        #expect(exec.restored == ["scripts/pre-deploy-check.ts"])
        // The host was intact all along — nothing to commit there.
        #expect(try await git(["log", "-1", "--format=%s"], in: site) == "seed")

        // With the guest copy restored, the next attempt goes through.
        let second = await command(executor: exec, template: template).deploy(siteID: "s", siteDirectory: site)
        guard case .succeeded = second else { Issue.record("expected .succeeded after the guest restore, got \(second)"); return }
    }

    @Test("a container executor that cannot report its copy fails the deploy closed, without a restore")
    func runtimeCopyUnreadableFailsClosed() async throws {
        final class Unreadable: DeployExecutor, AppOwnedScriptsRuntimeVerifying, @unchecked Sendable {
            let inner = FakeExecutor()
            func reportOwnedPathClaims() async -> [RuntimeOwnedPathClaim] { [] }
            func run(step: DeployStep, siteDirectory: URL, environment: [String: String], source: String) async -> DeployStepResult {
                await inner.run(step: step, siteDirectory: siteDirectory, environment: environment, source: source)
            }
            func digestAppOwnedScripts(relativePaths: [String], source: String) async -> AppOwnedScriptsGate.RuntimeCopy.Digests {
                .failed(reason: "no container")
            }
            func restoreAppOwnedScripts(_ pins: [AppOwnedScriptsGate.Pin], source: String) async -> Bool {
                Issue.record("must not restore a copy it couldn't read"); return false
            }
        }
        let (site, template, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let exec = Unreadable()
        let result = await command(executor: exec, template: template).deploy(siteID: "s", siteDirectory: site)
        guard case .failed(let reason, let exitCode) = result else { Issue.record("expected .failed, got \(result)"); return }
        #expect(exitCode == nil)
        #expect(reason.contains("couldn't confirm this site's safety check"))
        #expect(!exec.inner.ran("build"))
    }
}

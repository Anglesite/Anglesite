import Testing
import Foundation
@testable import AnglesiteCore

/// A gate that always passes — the seam every `BackupCommand`/`RepoBootstrap` test that isn't
/// about the gate itself injects, since production offers no "no gate" value (#1959).
extension SourcePublishGate {
    static let passing = SourcePublishGate(
        templateDirectory: { nil },
        runtime: { _ in Runtime(scriptsCopy: nil, scan: { _ in .passed(warnings: []) }) },
        logCenter: LogCenter(), gitCommitBatch: { _, _, _ in nil })

    /// A gate whose scan is canned; integrity still runs against `template` (or is unverifiable
    /// when `nil`).
    static func canned(_ outcome: PreDeployCheck.Outcome, template: URL? = nil) -> SourcePublishGate {
        SourcePublishGate(
            templateDirectory: { template },
            runtime: { _ in Runtime(scriptsCopy: nil, scan: { _ in outcome }) },
            logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "sha" })
    }
}

/// #1959 (owner decision D5): every push of `Source/` off-device that isn't a deploy runs behind
/// the same two-part gate — app-owned script integrity (#1958), then the source-scan subset of
/// the pre-deploy check — and a refusal has no override.
@Suite struct SourcePublishGateTests {
    private func tmpDirs() -> (source: URL, template: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spg-\(UUID().uuidString)")
        let source = root.appendingPathComponent("Source")
        let template = root.appendingPathComponent("Template")
        for d in [source, template] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        return (source, template)
    }

    private func writeFile(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func intactFixture() throws -> (source: URL, template: URL) {
        let (source, template) = tmpDirs()
        try writeFile("gate", to: template.appendingPathComponent("scripts/pre-deploy-check.ts"))
        try writeFile("gate", to: source.appendingPathComponent("scripts/pre-deploy-check.ts"))
        return (source, template)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        func hit() { lock.lock(); calls += 1; lock.unlock() }
    }

    @Test func aPassingScanPassesWithItsWarnings() async throws {
        let (source, template) = try intactFixture()
        let warning = PreDeployCheck.ScanWarning(category: .other, message: "fyi")
        let gate = SourcePublishGate.canned(.passed(warnings: [warning]), template: template)
        let outcome = await gate.check(siteID: "s", sourceDirectory: source, configDirectory: nil, source: "test")
        #expect(outcome == .passed(warnings: [warning]))
    }

    @Test func aBlockedScanBlocksWithTheScansFindings() async throws {
        let (source, template) = try intactFixture()
        let failure = PreDeployCheck.ScanFailure(category: .exposedToken, message: "Possible AWS key exposed", file: "src/content/x.md")
        let gate = SourcePublishGate.canned(.blocked(failures: [failure], warnings: []), template: template)
        let outcome = await gate.check(siteID: "s", sourceDirectory: source, configDirectory: nil, source: "test")
        #expect(outcome == .blocked(failures: [failure], warnings: []))
    }

    @Test func aScanThatCannotRunRefusesThePushInsteadOfPassing() async throws {
        let (source, template) = try intactFixture()
        let logCenter = LogCenter()
        let gate = SourcePublishGate(
            templateDirectory: { template },
            runtime: { _ in .init(scriptsCopy: nil, scan: { _ in .error(reason: "no tsx") }) },
            logCenter: logCenter, gitCommitBatch: { _, _, _ in "sha" })
        let outcome = await gate.check(siteID: "s", sourceDirectory: source, configDirectory: nil, source: "test")
        guard case .error(let reason) = outcome else { Issue.record("expected .error, got \(outcome)"); return }
        #expect(reason.contains("couldn't run its safety check"))
        let lines = await logCenter.snapshot()
        #expect(lines.contains { $0.text.contains("no tsx") })
    }

    @Test func aTamperedGateScriptBlocksBeforeTheScanEverRunsAndIsRestored() async throws {
        // The integrity half runs first: the scan is the site's own script, so it's only worth
        // running once that script is known to be the app's.
        let (source, template) = try intactFixture()
        try writeFile("export {} // disabled", to: source.appendingPathComponent("scripts/pre-deploy-check.ts"))
        let scans = Counter()
        let gate = SourcePublishGate(
            templateDirectory: { template },
            runtime: { _ in .init(scriptsCopy: nil, scan: { _ in scans.hit(); return .passed(warnings: []) }) },
            logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "sha" })

        let outcome = await gate.check(siteID: "s", sourceDirectory: source, configDirectory: nil, source: "test")

        guard case .blocked(let failures, _) = outcome else { Issue.record("expected .blocked, got \(outcome)"); return }
        #expect(failures.first?.category == .appOwnedScriptRestored)
        #expect(scans.calls == 0, "a changed gate script must never be executed")
        let restored = try String(contentsOf: source.appendingPathComponent("scripts/pre-deploy-check.ts"), encoding: .utf8)
        #expect(restored == "gate")
    }

    @Test func theRuntimesOwnCopyOfTheGateScriptIsVerifiedBeforeTheScan() async throws {
        // An in-guest edit never reaches the host repo; the runtime copy is what would run.
        let (source, template) = try intactFixture()
        let scans = Counter()
        let restores = Counter()
        let runtimeCopy = AppOwnedScriptsGate.RuntimeCopy(
            digests: { _ in .digests(["scripts/pre-deploy-check.ts": PortableSHA256.hexDigest(of: Data("disabled".utf8))]) },
            restore: { _ in restores.hit(); return true })
        let gate = SourcePublishGate(
            templateDirectory: { template },
            runtime: { _ in .init(scriptsCopy: runtimeCopy, scan: { _ in scans.hit(); return .passed(warnings: []) }) },
            logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "sha" })

        let outcome = await gate.check(siteID: "s", sourceDirectory: source, configDirectory: nil, source: "test")

        guard case .blocked(let failures, _) = outcome else { Issue.record("expected .blocked, got \(outcome)"); return }
        #expect(failures.first?.category == .appOwnedScriptRestored)
        #expect(restores.calls == 1)
        #expect(scans.calls == 0)
    }

    @Test func aRuntimeCopyThatCannotBeReadIsAnErrorNotAPass() async throws {
        let (source, template) = try intactFixture()
        let runtimeCopy = AppOwnedScriptsGate.RuntimeCopy(
            digests: { _ in .failed(reason: "exec failed") }, restore: { _ in true })
        let gate = SourcePublishGate(
            templateDirectory: { template },
            runtime: { _ in .init(scriptsCopy: runtimeCopy, scan: { _ in .passed(warnings: []) }) },
            logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "sha" })
        let outcome = await gate.check(siteID: "s", sourceDirectory: source, configDirectory: nil, source: "test")
        guard case .error(let reason) = outcome else { Issue.record("expected .error, got \(outcome)"); return }
        #expect(reason.contains("couldn't confirm this site's safety check"))
    }

    @Test func theLiveGateRefusesASiteWithNoRegisteredRuntime() async throws {
        let (source, template) = try intactFixture()
        let registry = SourcePublishGateRegistry()
        let gate = SourcePublishGate(
            templateDirectory: { template }, runtime: SourcePublishGate.registryProvider(registry),
            logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "sha" })
        let outcome = await gate.check(siteID: "unopened", sourceDirectory: source, configDirectory: nil, source: "test")
        guard case .error(let reason) = outcome else { Issue.record("expected .error, got \(outcome)"); return }
        #expect(reason.contains("open the site in Anglesite"))
    }

    @Test func theLiveGateRoutesToTheRegisteredRuntimeAndRefusesAgainOnceItIsGone() async throws {
        let (source, template) = try intactFixture()
        let registry = SourcePublishGateRegistry()
        let scans = Counter()
        registry.register({
            SourcePublishGate.Runtime(scriptsCopy: nil, scan: { _ in scans.hit(); return .passed(warnings: []) })
        }, for: "opened")
        let gate = SourcePublishGate(
            templateDirectory: { template }, runtime: SourcePublishGate.registryProvider(registry),
            logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "sha" })

        #expect(await gate.check(siteID: "opened", sourceDirectory: source, configDirectory: nil, source: "test") == .passed(warnings: []))
        #expect(scans.calls == 1)

        registry.unregister(siteID: "opened")
        guard case .error = await gate.check(siteID: "opened", sourceDirectory: source, configDirectory: nil, source: "test") else {
            Issue.record("an unregistered site must be refused again"); return
        }
    }

    @Test func aRegisteredProviderWithNoRuntimeYetIsRefusedAsStillBooting() async throws {
        let (source, template) = try intactFixture()
        let registry = SourcePublishGateRegistry()
        registry.register({ nil }, for: "booting")
        let gate = SourcePublishGate(
            templateDirectory: { template }, runtime: SourcePublishGate.registryProvider(registry),
            logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "sha" })
        guard case .error(let reason) = await gate.check(siteID: "booting", sourceDirectory: source, configDirectory: nil, source: "test") else {
            Issue.record("a runtime that isn't up yet must refuse"); return
        }
        #expect(reason.contains("wait for its preview to start"))
    }
}

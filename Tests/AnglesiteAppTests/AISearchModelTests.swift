import Foundation
import Testing
import AnglesiteCore
import AnglesiteTestSupport
@testable import AnglesiteAppCore

private final class StubProvisioner: AISearchProvisioning, @unchecked Sendable {
    func createAISearchInstance(domain: String, instanceID: String, apiToken: String) async throws -> AISearchInstance {
        AISearchInstance(id: "inst1", name: instanceID)
    }
    func aiSearchInstanceSource(instanceID: String, apiToken: String) async throws -> String { "" }
}

private final class FailingProvisioner: AISearchProvisioning, @unchecked Sendable {
    private let error: any Error
    init(throwing error: any Error) { self.error = error }
    func createAISearchInstance(domain: String, instanceID: String, apiToken: String) async throws -> AISearchInstance {
        throw error
    }
    func aiSearchInstanceSource(instanceID: String, apiToken: String) async throws -> String { "" }
}

/// Every test passes one of these explicitly — the model's production default is a live
/// HTTP preflight, and a unit test must never reach the network.
private final class StubPreflight: SitemapPreflighting, @unchecked Sendable {
    private let result: SitemapPreflightResult
    private(set) var checkedDomains: [String] = []
    init(_ result: SitemapPreflightResult) { self.result = result }
    func checkSitemap(domain: String) async -> SitemapPreflightResult {
        checkedDomains.append(domain)
        return result
    }
}

/// Spins until its surrounding task is cancelled, then answers `.indeterminate` — the live
/// preflight's exact behavior when cancellation hits mid-request (its catch-all can't tell a
/// cancelled URLSession call from a timeout). Lets a test hold the model mid-preflight.
private final class HangUntilCancelledPreflight: SitemapPreflighting, @unchecked Sendable {
    private(set) var started = false
    func checkSitemap(domain: String) async -> SitemapPreflightResult {
        started = true
        while !Task.isCancelled { await Task.yield() }
        return .indeterminate
    }
}

/// A `CloudflareReading` whose `resolveZoneID` calls suspend until the test explicitly resolves
/// them — mirrors `HardenModelTests.ControllableReader`/`DomainModelTests.ControllableATProtoDIDTransport`,
/// used to exercise a run still in flight when the sheet is dismissed/reopened out from under it (#1479).
private actor ControllableReader: CloudflareReading {
    private var continuations: [(domain: String, continuation: CheckedContinuation<String?, any Error>)] = []
    private let state: CloudflareZoneState

    init(state: CloudflareZoneState = StubCloudflareReader.defaultState) {
        self.state = state
    }

    func resolveZoneID(domain: String, apiToken: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append((domain, continuation))
        }
    }
    func zoneState(zoneID: String, domain: String, apiToken: String) async throws -> CloudflareZoneState { state }
    func listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord] { [] }
    func workerScriptNames(apiToken: String) async throws -> [String] { [] }

    func resolve(callIndex index: Int, zoneID: String?) {
        continuations[index].continuation.resume(returning: zoneID)
    }
    func callCount() -> Int { continuations.count }
}

// `.timeLimit`: see #1349/#1355/#1366 — a wedged test (e.g. a yield-poll waiting on a
// `ControllableReader` call that never comes) must fail as an unambiguous time-limit violation
// instead of hanging the whole `AnglesiteAppTests` run indefinitely.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AISearchModelTests {
    /// Per-instance scratch service, matching `HardenModelTests`' rationale: every test here
    /// claims `CLOUDFLARE_API_TOKEN` via `CloudflareAPITokenTestEnvironment`, so a fallback to
    /// the real keychain should never happen, but a scratch service keeps
    /// `CloudflareAPICredentials.resolve()`'s legacy-token read from touching the developer's
    /// actual login keychain if it ever does.
    private let keychain = KeychainStore(service: "io.dwk.anglesite.tests.aiSearchModel." + UUID().uuidString)

    private func tempSourceDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    @Test("checkPolicyAndResolveZone ignores blank domain input")
    func ignoresBlankDomain() throws {
        let model = AISearchModel(reader: StubCloudflareReader(), writer: StubCloudflareWriter(), provisioner: StubProvisioner(), preflight: StubPreflight(.reachable), keychain: keychain)
        model.domainInput = "   "
        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())
        #expect(model.phase == .idle)
    }

    @MainActor
    @Test("checkPolicyAndResolveZone reaches awaitingCostConfirmation when no licensing.json exists")
    func noPolicyFilePassesThrough() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let model = AISearchModel(reader: StubCloudflareReader(zoneID: "z1"), writer: StubCloudflareWriter(), provisioner: StubProvisioner(), preflight: StubPreflight(.reachable), keychain: keychain)
        model.domainInput = "Example.com"

        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())
        // Regression coverage mirroring HardenModelTests: phase must flip out of `.idle`
        // synchronously, before the Task's `await apiToken()` hop even starts, so `isRunning`
        // can't under-report while a token resolves.
        #expect(model.isRunning)
        while model.isRunning { await Task.yield() }

        #expect(model.phase == .awaitingCostConfirmation(domain: "example.com", zoneID: "z1"))
    }

    @MainActor
    @Test("checkPolicyAndResolveZone blocks when licensing.json says aiInput = no")
    func policyBlocks() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let dir = try tempSourceDirectory()
        var policy = LicensingPolicy()
        policy.usage.aiInput = .no
        try LicensingStore(sourceDirectory: dir).save(policy)

        let model = AISearchModel(reader: StubCloudflareReader(), writer: StubCloudflareWriter(), provisioner: StubProvisioner(), preflight: StubPreflight(.reachable), keychain: keychain)
        model.domainInput = "example.com"
        model.checkPolicyAndResolveZone(sourceDirectory: dir)
        while model.isRunning { await Task.yield() }

        guard case .blockedByPolicy = model.phase else {
            Issue.record("expected .blockedByPolicy, got \(model.phase)")
            return
        }
    }

    @MainActor
    @Test("confirmCost provisions and reaches succeeded")
    func confirmCostProvisions() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let model = AISearchModel(reader: StubCloudflareReader(zoneID: "z1"), writer: StubCloudflareWriter(), provisioner: StubProvisioner(), preflight: StubPreflight(.reachable), keychain: keychain)
        model.domainInput = "example.com"
        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())
        while model.isRunning { await Task.yield() }

        model.confirmCost()
        #expect(model.isRunning)
        while model.isRunning { await Task.yield() }

        guard case .succeeded(let result) = model.phase else {
            Issue.record("expected .succeeded, got \(model.phase)")
            return
        }
        #expect(result.instance.id == "inst1")
    }

    @MainActor
    @Test("confirmCost maps missingSitemap (Cloudflare 7028) to deploy-first guidance")
    func missingSitemapNamesDeployFirstFix() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let model = AISearchModel(
            reader: StubCloudflareReader(zoneID: "z1"), writer: StubCloudflareWriter(),
            provisioner: FailingProvisioner(throwing: AISearchProvisionError.missingSitemap),
            preflight: StubPreflight(.reachable), keychain: keychain)
        model.domainInput = "example.com"
        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())
        while model.isRunning { await Task.yield() }

        model.confirmCost()
        while model.isRunning { await Task.yield() }

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        // The owner-facing fix, not a raw API code or bare HTTP status (#1486).
        #expect(reason.localizedCaseInsensitiveContains("publish"))
        #expect(reason.localizedCaseInsensitiveContains("sitemap"))
        #expect(!reason.contains("7028"))
        #expect(!reason.contains("HTTP 400"))
    }

    @MainActor
    @Test("an unreachable sitemap short-circuits with deploy-first guidance before cost confirmation")
    func unreachableSitemapShortCircuitsBeforeCostStep() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let preflight = StubPreflight(.unreachable)
        let model = AISearchModel(
            reader: StubCloudflareReader(zoneID: "z1"), writer: StubCloudflareWriter(), provisioner: StubProvisioner(),
            preflight: preflight, keychain: keychain)
        model.domainInput = "example.com"
        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())
        while model.isRunning { await Task.yield() }

        #expect(preflight.checkedDomains == ["example.com"])
        guard case .failed(let reason) = model.phase else {
            Issue.record("expected .failed before cost confirmation, got \(model.phase)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("publish"))
        #expect(reason.localizedCaseInsensitiveContains("sitemap"))
    }

    @MainActor
    @Test("an indeterminate preflight (transport failure) doesn't block the flow")
    func indeterminatePreflightProceeds() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let model = AISearchModel(
            reader: StubCloudflareReader(zoneID: "z1"), writer: StubCloudflareWriter(), provisioner: StubProvisioner(),
            preflight: StubPreflight(.indeterminate), keychain: keychain)
        model.domainInput = "example.com"
        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())
        while model.isRunning { await Task.yield() }

        #expect(model.phase == .awaitingCostConfirmation(domain: "example.com", zoneID: "z1"))
    }

    @MainActor
    @Test("a policy block wins over the preflight — the sitemap is never probed")
    func policyBlockSkipsPreflight() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let dir = try tempSourceDirectory()
        var policy = LicensingPolicy()
        policy.usage.aiInput = .no
        try LicensingStore(sourceDirectory: dir).save(policy)

        let preflight = StubPreflight(.unreachable)
        let model = AISearchModel(
            reader: StubCloudflareReader(zoneID: "z1"), writer: StubCloudflareWriter(), provisioner: StubProvisioner(),
            preflight: preflight, keychain: keychain)
        model.domainInput = "example.com"
        model.checkPolicyAndResolveZone(sourceDirectory: dir)
        while model.isRunning { await Task.yield() }

        guard case .blockedByPolicy = model.phase else {
            Issue.record("expected .blockedByPolicy, got \(model.phase)")
            return
        }
        #expect(preflight.checkedDomains.isEmpty)
    }

    @MainActor
    @Test("a task cancelled mid-preflight never writes a stale phase (dismiss stays dismissed)")
    func cancelledMidPreflightWritesNothing() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let preflight = HangUntilCancelledPreflight()
        let model = AISearchModel(
            reader: StubCloudflareReader(zoneID: "z1"), writer: StubCloudflareWriter(), provisioner: StubProvisioner(),
            preflight: preflight, keychain: keychain)
        model.domainInput = "example.com"
        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())

        // Hold until the task is genuinely awaiting the preflight, then cancel via dismiss.
        while !preflight.started { await Task.yield() }
        model.dismissSheet()
        #expect(model.phase == .idle)

        // Give the cancelled task every chance to (wrongly) finish its fall-through write:
        // the preflight answers `.indeterminate` on cancellation, so without the isCancelled
        // guard the stale task would land `.awaitingCostConfirmation` here.
        for _ in 0..<50 { await Task.yield() }
        #expect(model.phase == .idle)
    }

    /// Regression coverage for #1479: `dismissSheet()` only sets `inFlight`'s cancellation flag —
    /// the abandoned task keeps running across its network awaits. Without the `Task.isCancelled`
    /// guard on every `phase` write in the async runner, a stale completion after dismissal would
    /// clobber the `.idle` reset with a result the user never asked for in this session.
    @MainActor
    @Test("dismissing the sheet mid-resolve does not let a stale completion clobber the reset phase")
    func dismissDuringResolveDoesNotClobberResetState() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let reader = ControllableReader()
        let model = AISearchModel(
            reader: reader, writer: StubCloudflareWriter(), provisioner: StubProvisioner(),
            preflight: StubPreflight(.reachable), keychain: keychain)
        model.domainInput = "example.com"

        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())
        // Let the spawned `Task` actually start and suspend inside `reader.resolveZoneID`, so
        // dismissal below races a run that's genuinely still in flight.
        while await reader.callCount() == 0 { await Task.yield() }
        #expect(model.phase == .resolvingZone(domain: "example.com"))

        model.dismissSheet()
        #expect(model.phase == .idle)

        // The in-flight lookup finally resolves *after* dismissal cancelled its `Task` — the
        // result must not land and clobber the `.idle` reset (the bug this test guards).
        await reader.resolve(callIndex: 0, zoneID: "z1")
        for _ in 0..<5 { await Task.yield() }

        #expect(model.phase == .idle)
    }

    /// Regression coverage for #1479's second acceptance criterion: a stale run's completion must
    /// not overwrite a newer run's phase, even when the newer run was started before the older one
    /// finally resolves.
    @MainActor
    @Test("a newer run's phase survives a stale older run resolving after it")
    func newerRunSurvivesStaleOlderRunCompleting() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let reader = ControllableReader()
        let model = AISearchModel(
            reader: reader, writer: StubCloudflareWriter(), provisioner: StubProvisioner(),
            preflight: StubPreflight(.reachable), keychain: keychain)
        model.domainInput = "stale.example"

        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())
        while await reader.callCount() == 0 { await Task.yield() }

        model.dismissSheet()
        model.domainInput = "fresh.example"
        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())
        while await reader.callCount() == 1 { await Task.yield() }
        #expect(model.phase == .resolvingZone(domain: "fresh.example"))

        // The stale first lookup resolves after the second run has already started — it must not
        // overwrite the second run's phase.
        await reader.resolve(callIndex: 0, zoneID: "stale-zone")
        for _ in 0..<5 { await Task.yield() }
        #expect(model.phase == .resolvingZone(domain: "fresh.example"))

        await reader.resolve(callIndex: 1, zoneID: "fresh-zone")
        while model.isRunning { await Task.yield() }

        #expect(model.phase == .awaitingCostConfirmation(domain: "fresh.example", zoneID: "fresh-zone"))
    }
}

import Foundation
import Testing
import AnglesiteCore
import AnglesiteTestSupport
@testable import AnglesiteAppCore

/// A `CloudflareReading` whose `resolveZoneID` calls suspend until the test explicitly resolves
/// them — mirrors `DomainModelTests.ControllableATProtoDIDTransport`, used to exercise a run
/// still in flight when the sheet is dismissed/reopened out from under it (#1479).
private actor ControllableReader: CloudflareReading {
    private var continuations: [(domain: String, continuation: CheckedContinuation<String?, any Error>)] = []
    private let state: CloudflareZoneState

    init(state: CloudflareZoneState = StubCloudflareReader.cleanState) {
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
struct HardenModelTests {
    /// A per-case scratch service, matching `DomainConfigAuditModelTests`' rationale: every test
    /// here claims `CLOUDFLARE_API_TOKEN` via `CloudflareAPITokenTestEnvironment`, so a fallback
    /// to the real keychain should never happen, but a scratch service keeps
    /// `CloudflareAPICredentials.resolve()`'s legacy-token read from touching the developer's
    /// actual login keychain if it ever does.
    private let keychain = KeychainStore(service: "io.dwk.anglesite.tests.hardenModel." + UUID().uuidString)

    /// Regression coverage for the #1289 review fix: `resolveAndPlan()`/`apply()` now flip `phase`
    /// out of `.idle`/`.preview` synchronously, before the `Task` (and its `await apiToken()` hop)
    /// starts — pins that `isRunning` is observably true immediately, matching
    /// `DomainConfigAuditModel`'s equivalent contract.
    @MainActor
    @Test("resolveAndPlan() flips isRunning synchronously, before the token resolves")
    func resolveAndPlanFlipsRunningSynchronously() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let model = HardenModel(reader: StubCloudflareReader(), writer: StubCloudflareWriter(), keychain: keychain)
        model.domainInput = "example.com"

        model.resolveAndPlan()
        #expect(model.isRunning)
        while model.isRunning { await Task.yield() }

        guard case .preview(let plan, let domain, let zoneID) = model.phase else {
            Issue.record("expected .preview, got \(model.phase)")
            return
        }
        #expect(domain == "example.com")
        #expect(zoneID == "z1")
        #expect(!plan.isEmpty)
    }

    /// Regression coverage for the #1289 review fix: previously `apply()`'s only guard was
    /// `case .preview = phase`, with no `isRunning` check, and `phase` didn't flip to `.applying`
    /// until after `await apiToken()` resolved. A second `apply()` call landing while the first
    /// was still resolving its token passed the same guard, cancelled `inFlight`, and silently
    /// restarted. Now that `phase` flips to `.applying` synchronously inside `apply()` itself
    /// (before the `Task` starts), a second call arriving after the first must see phase already
    /// out of `.preview` and no-op.
    @MainActor
    @Test("a second apply() call after the first has started is a no-op, not a silent restart")
    func secondApplyCallIsANoOp() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let model = HardenModel(reader: StubCloudflareReader(), writer: StubCloudflareWriter(), keychain: keychain)
        model.domainInput = "example.com"
        model.resolveAndPlan()
        while model.isRunning { await Task.yield() }
        guard case .preview(let plan, _, _) = model.phase, !plan.isEmpty else {
            Issue.record("expected a non-empty .preview phase before exercising apply(), got \(model.phase)")
            return
        }

        model.apply()
        #expect(model.isRunning)
        // This second call must observe phase already flipped to `.applying` (not `.preview`), so
        // its own `guard case .preview = phase` rejects it — no second `inFlight` Task, no restart.
        model.apply()
        while model.isRunning { await Task.yield() }

        guard case .succeeded(let result) = model.phase else {
            Issue.record("expected .succeeded, got \(model.phase)")
            return
        }
        #expect(result.appliedCount == plan.items.count)
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
        let model = HardenModel(reader: reader, writer: StubCloudflareWriter(), keychain: keychain)
        model.domainInput = "example.com"

        model.resolveAndPlan()
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
        let model = HardenModel(reader: reader, writer: StubCloudflareWriter(), keychain: keychain)
        model.domainInput = "stale.example"

        model.resolveAndPlan()
        while await reader.callCount() == 0 { await Task.yield() }

        model.dismissSheet()
        model.domainInput = "fresh.example"
        model.resolveAndPlan()
        while await reader.callCount() == 1 { await Task.yield() }
        #expect(model.phase == .resolvingZone(domain: "fresh.example"))

        // The stale first lookup resolves after the second run has already started — it must not
        // overwrite the second run's phase.
        await reader.resolve(callIndex: 0, zoneID: "stale-zone")
        for _ in 0..<5 { await Task.yield() }
        #expect(model.phase == .resolvingZone(domain: "fresh.example"))

        await reader.resolve(callIndex: 1, zoneID: "fresh-zone")
        while model.isRunning { await Task.yield() }

        guard case .preview(_, let domain, let zoneID) = model.phase else {
            Issue.record("expected .preview, got \(model.phase)")
            return
        }
        #expect(domain == "fresh.example")
        #expect(zoneID == "fresh-zone")
    }
}

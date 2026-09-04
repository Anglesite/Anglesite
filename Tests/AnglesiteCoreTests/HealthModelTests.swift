import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@MainActor
struct HealthModelTests {
    // MARK: - Initial state

    @Test("initial state is unknown")
    func initialStateIsUnknown() {
        let model = HealthModel(runner: GateRunner())
        #expect(model.badgeState == .unknown)
        #expect(model.lastCheckedAt == nil)
        #expect(model.lastOutcome == nil)
        #expect(model.lastFailure == nil)
        #expect(!model.isRunning)
    }

    // MARK: - recheck transitions

    @Test("recheck sets isRunning, then clears it")
    func recheckSetsIsRunningThenClears() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        #expect(model.isRunning)
        await Task.yield()  // let the @MainActor task start and register its continuation
        await runner.respond(with: .success(.passed(warnings: [])))
        await task.value
        #expect(!model.isRunning)
    }

    @Test("recheck with a passing scan and no warnings sets clean")
    func recheckPassingScanNoWarningsSetsClean() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .success(.passed(warnings: [])))
        await task.value
        #expect(model.badgeState == .clean)
        #expect(model.lastCheckedAt != nil)
        #expect(model.lastFailure == nil)
    }

    @Test("recheck with a passing scan and warnings sets warnings")
    func recheckPassingScanWithWarningsSetsWarnings() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .success(.passed(warnings: [sampleWarning])))
        await task.value
        #expect(model.badgeState == .warnings)
    }

    @Test("recheck with a blocked scan sets failures")
    func recheckBlockedScanSetsFailures() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .success(.blocked(failures: [sampleFailure], warnings: [])))
        await task.value
        #expect(model.badgeState == .failures)
    }

    @Test("recheck with an error outcome sets failures")
    func recheckErrorOutcomeSetsFailures() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .success(.error(reason: "missing dist/")))
        await task.value
        #expect(model.badgeState == .failures)
        #expect(model.lastOutcome != nil) // .error is still surfaced via lastOutcome
    }

    @Test("recheck where the runner throws a build failure sets failures with the reason")
    func recheckRunnerThrowsBuildFailureSetsFailuresWithReason() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .failure(HealthRunnerError.build("npm run build exited 1")))
        await task.value
        #expect(model.badgeState == .failures)
        #expect(model.lastFailure == .buildFailed("npm run build exited 1"))
    }

    @Test("recheck where the runner throws a scan failure sets failures with the reason")
    func recheckRunnerThrowsScanFailureSetsFailuresWithReason() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .failure(HealthRunnerError.scan("script crashed")))
        await task.value
        #expect(model.badgeState == .failures)
        #expect(model.lastFailure == .scanFailed("script crashed"))
    }

    @Test("a generic error maps to scanFailed")
    func genericErrorMapsToScanFailed() async {
        struct OddError: Error {}
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .failure(OddError()))
        await task.value
        guard case .scanFailed = model.lastFailure else {
            Issue.record("expected .scanFailed, got \(String(describing: model.lastFailure))")
            return
        }
    }

    // MARK: - recheck cancellation

    @Test("recheck while running cancels the prior task; only the latest lands")
    func recheckWhileRunningCancelsPriorTaskOnlyLatestLands() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)

        // Kick off two recheck calls. We must pin the registration ORDER so `respondOldestPending`
        // (FIFO) targets the right task: wait for the first call to register before starting the
        // second (which cancels the first), then wait for the second to register. Without this the
        // task-start order is unspecified and the cancellation can land on the latest call,
        // leaving badgeState `.unknown` (the flake).
        let first = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await runner.waitForPending(1)                                   // first registered
        let second = model.recheck(siteID: "s", siteDirectory: tmpURL)   // cancels first
        await runner.waitForPending(2)                                   // second registered

        // Cancellation propagates to the gated runner via CancellationError; respond
        // to the second call with a blocked outcome.
        await runner.respondOldestPending(with: .failure(CancellationError()))     // first
        await runner.respondOldestPending(with: .success(.blocked(failures: [sampleFailure], warnings: []))) // second

        await first.value
        await second.value
        #expect(model.badgeState == .failures)
    }

    // MARK: - ingestDeployOutcome

    @Test("ingestDeployOutcome with a passed outcome sets clean")
    func ingestDeployOutcomePassedSetsClean() {
        let model = HealthModel(runner: GateRunner())
        model.ingestDeployOutcome(.passed(warnings: []))
        #expect(model.badgeState == .clean)
        #expect(model.lastCheckedAt != nil)
    }

    @Test("ingestDeployOutcome with warnings sets warnings")
    func ingestDeployOutcomeWarningsSetsWarnings() {
        let model = HealthModel(runner: GateRunner())
        model.ingestDeployOutcome(.passed(warnings: [sampleWarning]))
        #expect(model.badgeState == .warnings)
    }

    @Test("ingestDeployOutcome with a blocked outcome sets failures")
    func ingestDeployOutcomeBlockedSetsFailures() {
        let model = HealthModel(runner: GateRunner())
        model.ingestDeployOutcome(.blocked(failures: [sampleFailure], warnings: []))
        #expect(model.badgeState == .failures)
    }

    @Test("ingestDeployOutcome clears a prior failure")
    func ingestDeployOutcomeClearsPriorFailure() async {
        let runner = GateRunner()
        let model = HealthModel(runner: runner)
        let task = model.recheck(siteID: "s", siteDirectory: tmpURL)
        await Task.yield()
        await runner.respond(with: .failure(HealthRunnerError.build("boom")))
        await task.value
        #expect(model.badgeState == .failures)
        #expect(model.lastFailure != nil)

        model.ingestDeployOutcome(.passed(warnings: []))
        #expect(model.badgeState == .clean)
        #expect(model.lastFailure == nil)
    }

    // MARK: - Fixtures

    private var tmpURL: URL { URL(fileURLWithPath: "/tmp/health-test") }

    private var sampleFailure: PreDeployCheck.ScanFailure {
        .init(category: .exposedToken, message: "token in src", file: "src/x.astro", remediation: "remove it")
    }

    private var sampleWarning: PreDeployCheck.ScanWarning {
        .init(category: .missingOgImage, message: "no og image", remediation: "add one")
    }
}

/// Gated mock runner: `run(...)` suspends until `respond(...)` is called. Both
/// `respond` variants poll-await for a pending entry — `HealthModel.recheck`
/// spawns the runner call inside a `Task`, so when the test method on MainActor
/// calls `respond` immediately after, the task body hasn't yet reached the
/// `runner.run` call. Without the wait the test races (precondition fires when
/// `pending` is empty); with it the test is deterministic.
final class GateRunner: HealthCheckRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<PreDeployCheck.Outcome, Error>] = []

    func run(siteID: String, siteDirectory: URL) async throws -> PreDeployCheck.Outcome {
        try await withCheckedThrowingContinuation { cont in
            lock.lock(); pending.append(cont); lock.unlock()
        }
    }

    /// Respond to the single in-flight call. Awaits if pending is still empty
    /// (the task body hasn't reached `run` yet); fatals if more than one is queued.
    func respond(with result: Result<PreDeployCheck.Outcome, Error>) async {
        let cont = await dequeueOldest()
        lock.withLock {
            precondition(pending.isEmpty, "expected exactly one pending call, found \(pending.count + 1)")
        }
        deliver(cont, result)
    }

    /// Respond to the oldest in-flight call (FIFO). Used by the cancellation test
    /// which queues two calls before resolving either.
    func respondOldestPending(with result: Result<PreDeployCheck.Outcome, Error>) async {
        let cont = await dequeueOldest()
        deliver(cont, result)
    }

    /// Number of in-flight `run` calls currently suspended. Lets the cancellation test wait for a
    /// known registration order before responding (see `waitForPending`).
    var pendingCount: Int { lock.withLock { pending.count } }

    /// Await until at least `count` `run` calls have registered their continuations. Makes the
    /// cancellation test deterministic: without it the order in which the two back-to-back recheck
    /// tasks reach `run` is unspecified, so `respondOldestPending` could deliver the cancellation
    /// to the wrong task and leave the latest result unset (flaky `.unknown`).
    func waitForPending(_ count: Int) async {
        try? await waitUntil("at least \(count) pending call(s) to register") { pendingCount >= count }
    }

    private func dequeueOldest() async -> CheckedContinuation<PreDeployCheck.Outcome, Error> {
        try? await waitUntil("a pending call to register") { pendingCount > 0 }
        return lock.withLock { pending.removeFirst() }
    }

    private func deliver(_ cont: CheckedContinuation<PreDeployCheck.Outcome, Error>, _ result: Result<PreDeployCheck.Outcome, Error>) {
        switch result {
        case .success(let outcome): cont.resume(returning: outcome)
        case .failure(let error): cont.resume(throwing: error)
        }
    }
}

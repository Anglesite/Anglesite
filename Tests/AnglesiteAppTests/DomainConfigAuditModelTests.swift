import Foundation
import Testing
import AnglesiteCore
import AnglesiteTestSupport
@testable import AnglesiteAppCore

/// A `CloudflareReading` whose `resolveZoneID` calls suspend until the test explicitly resolves
/// them — mirrors `HardenModelTests`/`AISearchModelTests`' `ControllableReader`, used to exercise
/// a run still in flight when the sheet is dismissed/reopened out from under it (#1506).
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

/// `.timeLimit`: see #1349 — the full `AnglesiteAppTests` target has hung indefinitely under
/// local machine contention (many concurrent `swift test` runs oversubscribing the cooperative
/// thread pool), with this suite one of the observed stall points. A wedged test now fails as an
/// unambiguous time-limit violation instead of hanging the whole run forever.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DomainConfigAuditModelTests {
    /// A per-case scratch service (see `KeychainStore`'s own doc comment) so these tests never
    /// touch the developer's real login keychain — every test that claims `CLOUDFLARE_API_TOKEN`
    /// via `CloudflareAPITokenTestEnvironment` should never fall through to the keychain at all,
    /// but a scratch service keeps the model's `try? keychain.readCloudflareToken()` call from
    /// racing a concurrent keychain read/prompt in another worktree if it ever does.
    private let keychain = KeychainStore(service: "io.dwk.anglesite.tests.domainConfigAudit." + UUID().uuidString)

    private func tempSite(declaring config: DomainConfig? = nil) throws -> (CurrentSite, () -> Void) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        if let config {
            try DomainConfigStore(sourceDirectory: tmp).save(config)
        }
        let site = CurrentSite(id: "s1", packageURL: tmp, sourceDirectory: tmp)
        return (site, { try? FileManager.default.removeItem(at: tmp) })
    }

    @MainActor
    @Test("runAudit() surfaces a clear error when no domain is declared")
    func runAuditNoDomainDeclared() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let (site, cleanup) = try tempSite()
        defer { cleanup() }
        let model = DomainConfigAuditModel(reader: StubCloudflareReader(), writer: StubCloudflareWriter(), keychain: keychain)
        model.configure(site: site)

        model.runAudit()
        while model.isRunning { await Task.yield() }

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(reason.contains("domain"))
    }

    @MainActor
    @Test("runAudit() surfaces a clear error when the zone isn't found")
    func runAuditZoneNotFound() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let declared = DomainConfig(domain: .init(hostname: "example.com"))
        let (site, cleanup) = try tempSite(declaring: declared)
        defer { cleanup() }
        let model = DomainConfigAuditModel(reader: StubCloudflareReader(zoneID: nil), writer: StubCloudflareWriter(), keychain: keychain)
        model.configure(site: site)

        model.runAudit()
        while model.isRunning { await Task.yield() }

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(reason.contains("example.com"))
    }

    /// Regression coverage for the #1211 restructuring: the token check moved from a synchronous
    /// pre-`Task` guard into the async task body, since resolving via `CloudflareAPICredentials`
    /// needs an `await` hop. `phase` must still flip to `.auditing` synchronously (so `isRunning`
    /// is observably true) before the in-task token check can land on `.failed` — this pins both
    /// halves of that contract, not just the eventual outcome.
    @MainActor
    @Test("runAudit() surfaces the no-token failure after isRunning has already flipped true")
    func runAuditNoTokenAvailable() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let declared = DomainConfig(domain: .init(hostname: "example.com"))
        let (site, cleanup) = try tempSite(declaring: declared)
        defer { cleanup() }
        let model = DomainConfigAuditModel(reader: StubCloudflareReader(), writer: StubCloudflareWriter(), keychain: InMemorySecretStore())
        model.configure(site: site)

        model.runAudit()
        #expect(model.isRunning)
        while model.isRunning { await Task.yield() }

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(reason.contains("token"))
    }

    /// Same regression coverage as ``runAuditNoTokenAvailable()``, for `reconcile()`'s identical
    /// restructuring.
    @MainActor
    @Test("reconcile() surfaces the no-token failure after isRunning has already flipped true")
    func reconcileNoTokenAvailable() async throws {
        let record = DomainConfig.DNSRecord(
            type: "TXT", name: "_atproto", content: "did=did:plc:abc", purpose: "verification:bluesky")
        let declared = DomainConfig(domain: .init(hostname: "example.com"), dns: .init(managedRecords: [record]))
        let (site, cleanup) = try tempSite(declaring: declared)
        defer { cleanup() }
        // Token available for the audit step, so phase reaches `.results` with a non-empty plan —
        // reconcile()'s own guard requires that starting phase. Claimed explicitly via the shared
        // coordinator (#1211 review) rather than relying on ambient/leaked env state.
        let model = DomainConfigAuditModel(reader: StubCloudflareReader(zoneID: "z1"), writer: StubCloudflareWriter(), keychain: InMemorySecretStore())
        model.configure(site: site)
        let auditToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        model.runAudit()
        while model.isRunning { await Task.yield() }
        auditToken.release()
        guard case .results = model.phase else {
            Issue.record("expected .results before exercising reconcile()'s no-token path, got \(model.phase)")
            return
        }

        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }

        model.reconcile()
        #expect(model.isRunning)
        while model.isRunning { await Task.yield() }

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(reason.contains("token"))
    }

    @MainActor
    @Test("runAudit() computes findings against the declared config and resolved zone")
    func runAuditComputesFindings() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let record = DomainConfig.DNSRecord(
            type: "TXT", name: "_atproto", content: "did=did:plc:abc", purpose: "verification:bluesky")
        let declared = DomainConfig(domain: .init(hostname: "example.com"), dns: .init(managedRecords: [record]))
        let (site, cleanup) = try tempSite(declaring: declared)
        defer { cleanup() }
        let reader = StubCloudflareReader(zoneID: "z1", state: StubCloudflareReader.cleanState, records: [])
        let model = DomainConfigAuditModel(reader: reader, writer: StubCloudflareWriter(), keychain: keychain)
        model.configure(site: site)

        model.runAudit()
        while model.isRunning { await Task.yield() }

        guard case .results(let findings, let plan, let domain, let zoneID) = model.phase else {
            Issue.record("expected .results, got \(model.phase)")
            return
        }
        #expect(reader.resolvedDomain == "example.com")
        #expect(domain == "example.com")
        #expect(zoneID == "z1")
        #expect(findings.count == 1)
        #expect(plan.items == [.createManagedRecord(record)])
    }

    @MainActor
    @Test("reconcile() delegates to DomainConfigReconciler and reports the applied plan")
    func reconcileAppliesPlan() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let record = DomainConfig.DNSRecord(
            type: "TXT", name: "_atproto", content: "did=did:plc:abc", purpose: "verification:bluesky")
        let declared = DomainConfig(domain: .init(hostname: "example.com"), dns: .init(managedRecords: [record]))
        let (site, cleanup) = try tempSite(declaring: declared)
        defer { cleanup() }
        let writer = StubCloudflareWriter()
        let model = DomainConfigAuditModel(reader: StubCloudflareReader(zoneID: "z1"), writer: writer, keychain: keychain)
        model.configure(site: site)

        model.runAudit()
        while model.isRunning { await Task.yield() }

        model.reconcile()
        while model.isRunning { await Task.yield() }

        guard case .succeeded(let result) = model.phase else {
            Issue.record("expected .succeeded, got \(model.phase)")
            return
        }
        #expect(result.appliedCount == 1)
        #expect(writer.addedRecords.first?.content == "did=did:plc:abc")
    }

    @MainActor
    @Test("openSheet() resets phase")
    func openSheetResets() {
        // No CloudflareAPITokenTestEnvironment claim needed: openSheet() never calls apiToken().
        let model = DomainConfigAuditModel(reader: StubCloudflareReader(), writer: StubCloudflareWriter(), keychain: keychain)
        model.openSheet()
        #expect(model.sheetPresented == true)
        #expect(model.phase == .idle)
    }

    @MainActor
    @Test("dismissSheet() clears the presented flag")
    func dismissSheetClearsPresented() {
        // No CloudflareAPITokenTestEnvironment claim needed: neither method calls apiToken().
        let model = DomainConfigAuditModel(reader: StubCloudflareReader(), writer: StubCloudflareWriter(), keychain: keychain)
        model.openSheet()
        model.dismissSheet()
        #expect(model.sheetPresented == false)
    }

    /// Regression coverage for #1506 (mirroring #1479's fix for `HardenModel`/`AISearchModel`):
    /// `dismissSheet()` only sets `inFlight`'s cancellation flag — the abandoned task keeps
    /// running across its network awaits. Without the `Task.isCancelled` guard on every `phase`
    /// write in the async runner, a stale completion after dismissal would clobber the `.idle`
    /// reset with a result the user never asked for in this session.
    @MainActor
    @Test("dismissing the sheet mid-audit does not let a stale completion clobber the reset phase")
    func dismissDuringAuditDoesNotClobberResetState() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let reader = ControllableReader()
        let declared = DomainConfig(domain: .init(hostname: "example.com"))
        let (site, cleanup) = try tempSite(declaring: declared)
        defer { cleanup() }
        let model = DomainConfigAuditModel(reader: reader, writer: StubCloudflareWriter(), keychain: keychain)
        model.configure(site: site)

        model.runAudit()
        // Let the spawned `Task` actually start and suspend inside `reader.resolveZoneID`, so
        // dismissal below races a run that's genuinely still in flight.
        while await reader.callCount() == 0 { await Task.yield() }
        #expect(model.phase == .auditing(domain: "example.com"))

        model.dismissSheet()
        #expect(model.phase == .idle)

        // The in-flight lookup finally resolves *after* dismissal cancelled its `Task` — the
        // result must not land and clobber the `.idle` reset (the bug this test guards).
        await reader.resolve(callIndex: 0, zoneID: "z1")
        for _ in 0..<5 { await Task.yield() }

        #expect(model.phase == .idle)
    }

    /// Regression coverage for #1506's second acceptance criterion: a stale run's completion
    /// must not overwrite a newer run's phase, even when the newer run was started before the
    /// older one finally resolves.
    @MainActor
    @Test("a newer run's phase survives a stale older run resolving after it")
    func newerRunSurvivesStaleOlderRunCompleting() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let reader = ControllableReader()
        let model = DomainConfigAuditModel(reader: reader, writer: StubCloudflareWriter(), keychain: keychain)

        let staleDeclared = DomainConfig(domain: .init(hostname: "stale.example"))
        let (staleSite, staleCleanup) = try tempSite(declaring: staleDeclared)
        defer { staleCleanup() }
        model.configure(site: staleSite)
        model.runAudit()
        while await reader.callCount() == 0 { await Task.yield() }

        model.dismissSheet()

        let freshDeclared = DomainConfig(domain: .init(hostname: "fresh.example"))
        let (freshSite, freshCleanup) = try tempSite(declaring: freshDeclared)
        defer { freshCleanup() }
        model.configure(site: freshSite)
        model.runAudit()
        while await reader.callCount() == 1 { await Task.yield() }
        #expect(model.phase == .auditing(domain: "fresh.example"))

        // The stale first lookup resolves after the second run has already started — it must not
        // overwrite the second run's phase.
        await reader.resolve(callIndex: 0, zoneID: "stale-zone")
        for _ in 0..<5 { await Task.yield() }
        #expect(model.phase == .auditing(domain: "fresh.example"))

        await reader.resolve(callIndex: 1, zoneID: "fresh-zone")
        while model.isRunning { await Task.yield() }

        guard case .results(_, _, let domain, let zoneID) = model.phase else {
            Issue.record("expected .results, got \(model.phase)")
            return
        }
        #expect(domain == "fresh.example")
        #expect(zoneID == "fresh-zone")
    }
}

import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteAppCore

private final class StubReader: CloudflareReading, @unchecked Sendable {
    private let zoneID: String?
    private let state: CloudflareZoneState
    init(zoneID: String? = "z1", state: CloudflareZoneState = StubReader.defaultState) {
        self.zoneID = zoneID
        self.state = state
    }
    static let defaultState = CloudflareZoneState(
        dnssecActive: false, sslMode: "flexible", alwaysUseHTTPS: false, hsts: nil,
        caaRecords: [], mxRecords: [], spfRecords: [], dmarcRecords: [])
    func resolveZoneID(domain: String, apiToken: String) async throws -> String? { zoneID }
    func zoneState(zoneID: String, domain: String, apiToken: String) async throws -> CloudflareZoneState { state }
    func listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord] { [] }
    func workerScriptNames(apiToken: String) async throws -> [String] { [] }
}

private final class StubWriter: CloudflareWriting, @unchecked Sendable {
    func enableDNSSEC(zoneID: String, apiToken: String) async throws {}
    func setAlwaysUseHTTPS(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func setHSTS(zoneID: String, maxAge: Int, includeSubdomains: Bool, preload: Bool, apiToken: String) async throws {}
    func addDNSRecord(zoneID: String, record: DNSRecordPayload, apiToken: String) async throws {}
    func deleteDNSRecord(zoneID: String, recordID: String, apiToken: String) async throws {}
    func setBotFightMode(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func createWAFCustomRule(zoneID: String, rule: WAFRulePayload, apiToken: String) async throws {}
    func setSpeedBrain(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func setECH(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func enableZstandardCompression(zoneID: String, apiToken: String) async throws {}
    func setPageShield(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func enableOnionRouting(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func attachWorkersCustomDomain(hostname: String, workerScriptName: String, apiToken: String) async throws -> CustomDomainAttachResult { .attached }
    func setMarkdownForAgents(hostname: String, enabled: Bool, apiToken: String) async throws -> Bool { true }
}

private final class StubProvisioner: AISearchProvisioning, @unchecked Sendable {
    func createAISearchInstance(domain: String, instanceID: String, apiToken: String) async throws -> AISearchInstance {
        AISearchInstance(id: "inst1", name: instanceID)
    }
}

private final class FailingProvisioner: AISearchProvisioning, @unchecked Sendable {
    private let error: any Error
    init(throwing error: any Error) { self.error = error }
    func createAISearchInstance(domain: String, instanceID: String, apiToken: String) async throws -> AISearchInstance {
        throw error
    }
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

@Suite(.serialized)
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
        let model = AISearchModel(reader: StubReader(), writer: StubWriter(), provisioner: StubProvisioner(), preflight: StubPreflight(.reachable), keychain: keychain)
        model.domainInput = "   "
        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())
        #expect(model.phase == .idle)
    }

    @MainActor
    @Test("checkPolicyAndResolveZone reaches awaitingCostConfirmation when no licensing.json exists")
    func noPolicyFilePassesThrough() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let model = AISearchModel(reader: StubReader(zoneID: "z1"), writer: StubWriter(), provisioner: StubProvisioner(), preflight: StubPreflight(.reachable), keychain: keychain)
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

        let model = AISearchModel(reader: StubReader(), writer: StubWriter(), provisioner: StubProvisioner(), preflight: StubPreflight(.reachable), keychain: keychain)
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
        let model = AISearchModel(reader: StubReader(zoneID: "z1"), writer: StubWriter(), provisioner: StubProvisioner(), preflight: StubPreflight(.reachable), keychain: keychain)
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
            reader: StubReader(zoneID: "z1"), writer: StubWriter(),
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
        #expect(reason.localizedCaseInsensitiveContains("deploy"))
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
            reader: StubReader(zoneID: "z1"), writer: StubWriter(), provisioner: StubProvisioner(),
            preflight: preflight, keychain: keychain)
        model.domainInput = "example.com"
        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())
        while model.isRunning { await Task.yield() }

        #expect(preflight.checkedDomains == ["example.com"])
        guard case .failed(let reason) = model.phase else {
            Issue.record("expected .failed before cost confirmation, got \(model.phase)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("deploy"))
        #expect(reason.localizedCaseInsensitiveContains("sitemap"))
    }

    @MainActor
    @Test("an indeterminate preflight (transport failure) doesn't block the flow")
    func indeterminatePreflightProceeds() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let model = AISearchModel(
            reader: StubReader(zoneID: "z1"), writer: StubWriter(), provisioner: StubProvisioner(),
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
            reader: StubReader(zoneID: "z1"), writer: StubWriter(), provisioner: StubProvisioner(),
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
            reader: StubReader(zoneID: "z1"), writer: StubWriter(), provisioner: StubProvisioner(),
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
}

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
        caaRecords: [], mxRecords: [], spfRecords: [], dmarcRecords: [], botFightMode: false)
    static func state(botFightMode: Bool) -> CloudflareZoneState {
        CloudflareZoneState(
            dnssecActive: false, sslMode: "flexible", alwaysUseHTTPS: false, hsts: nil,
            caaRecords: [], mxRecords: [], spfRecords: [], dmarcRecords: [], botFightMode: botFightMode)
    }
    func resolveZoneID(domain: String, apiToken: String) async throws -> String? { zoneID }
    func zoneState(zoneID: String, domain: String, apiToken: String) async throws -> CloudflareZoneState { state }
    func listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord] { [] }
    func workerScriptNames(apiToken: String) async throws -> [String] { [] }
}

private final class StubWriter: CloudflareWriting, @unchecked Sendable {
    private(set) var setBotFightModeCalls: [(zoneID: String, enabled: Bool)] = []
    func enableDNSSEC(zoneID: String, apiToken: String) async throws {}
    func setAlwaysUseHTTPS(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func setHSTS(zoneID: String, maxAge: Int, includeSubdomains: Bool, preload: Bool, apiToken: String) async throws {}
    func addDNSRecord(zoneID: String, record: DNSRecordPayload, apiToken: String) async throws {}
    func deleteDNSRecord(zoneID: String, recordID: String, apiToken: String) async throws {}
    func setBotFightMode(zoneID: String, enabled: Bool, apiToken: String) async throws {
        setBotFightModeCalls.append((zoneID, enabled))
    }
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
        let model = AISearchModel(reader: StubReader(), writer: StubWriter(), provisioner: StubProvisioner(), keychain: keychain)
        model.domainInput = "   "
        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())
        #expect(model.phase == .idle)
    }

    @MainActor
    @Test("checkPolicyAndResolveZone reaches awaitingCostConfirmation when Bot Fight Mode is off")
    func noPolicyFilePassesThrough() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let model = AISearchModel(reader: StubReader(zoneID: "z1"), writer: StubWriter(), provisioner: StubProvisioner(), keychain: keychain)
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
    @Test("checkPolicyAndResolveZone reaches awaitingBotFightModeDecision when Bot Fight Mode is on")
    func botFightModeOnReachesDecisionPhase() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let reader = StubReader(zoneID: "z1", state: StubReader.state(botFightMode: true))
        let model = AISearchModel(reader: reader, writer: StubWriter(), provisioner: StubProvisioner(), keychain: keychain)
        model.domainInput = "Example.com"

        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())
        while model.isRunning { await Task.yield() }

        #expect(model.phase == .awaitingBotFightModeDecision(domain: "example.com", zoneID: "z1"))
    }

    @MainActor
    @Test("disableBotFightMode calls the writer and reaches awaitingCostConfirmation")
    func disableBotFightModeCallsWriterAndProceeds() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let reader = StubReader(zoneID: "z1", state: StubReader.state(botFightMode: true))
        let writer = StubWriter()
        let model = AISearchModel(reader: reader, writer: writer, provisioner: StubProvisioner(), keychain: keychain)
        model.domainInput = "example.com"
        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())
        while model.isRunning { await Task.yield() }
        guard case .awaitingBotFightModeDecision = model.phase else {
            Issue.record("expected .awaitingBotFightModeDecision, got \(model.phase)")
            return
        }

        model.disableBotFightMode()
        #expect(model.isRunning)
        while model.isRunning { await Task.yield() }

        #expect(model.phase == .awaitingCostConfirmation(domain: "example.com", zoneID: "z1"))
        #expect(writer.setBotFightModeCalls.count == 1)
        #expect(writer.setBotFightModeCalls.first?.zoneID == "z1")
        #expect(writer.setBotFightModeCalls.first?.enabled == false)
        #expect(model.keptBotFightModeOn == false)
    }

    @MainActor
    @Test("keepBotFightMode proceeds without calling the writer and provisioning still succeeds")
    func keepBotFightModeProceedsAndProvisionsSucceed() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let reader = StubReader(zoneID: "z1", state: StubReader.state(botFightMode: true))
        let writer = StubWriter()
        let model = AISearchModel(reader: reader, writer: writer, provisioner: StubProvisioner(), keychain: keychain)
        model.domainInput = "example.com"
        model.checkPolicyAndResolveZone(sourceDirectory: try tempSourceDirectory())
        while model.isRunning { await Task.yield() }

        model.keepBotFightMode()
        #expect(model.phase == .awaitingCostConfirmation(domain: "example.com", zoneID: "z1"))
        #expect(model.keptBotFightModeOn == true)
        #expect(writer.setBotFightModeCalls.isEmpty)

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
    @Test("checkPolicyAndResolveZone blocks when licensing.json says aiInput = no")
    func policyBlocks() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimSet()
        defer { cfToken.release() }
        let dir = try tempSourceDirectory()
        var policy = LicensingPolicy()
        policy.usage.aiInput = .no
        try LicensingStore(sourceDirectory: dir).save(policy)

        let model = AISearchModel(reader: StubReader(), writer: StubWriter(), provisioner: StubProvisioner(), keychain: keychain)
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
        let model = AISearchModel(reader: StubReader(zoneID: "z1"), writer: StubWriter(), provisioner: StubProvisioner(), keychain: keychain)
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
}

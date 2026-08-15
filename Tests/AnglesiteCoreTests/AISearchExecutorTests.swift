import Testing
import Foundation
@testable import AnglesiteCore

private final class StubProvisioner: AISearchProvisioning, @unchecked Sendable {
    private(set) var lastDomain: String?
    private(set) var lastInstanceID: String?
    var errorToThrow: CloudflareError?

    func createAISearchInstance(domain: String, instanceID: String, apiToken: String) async throws -> AISearchInstance {
        if let errorToThrow { throw errorToThrow }
        lastDomain = domain
        lastInstanceID = instanceID
        return AISearchInstance(id: "inst1", name: instanceID)
    }
}

private final class StubReader: CloudflareReading, @unchecked Sendable {
    private let state: CloudflareZoneState
    init(state: CloudflareZoneState) { self.state = state }
    func resolveZoneID(domain: String, apiToken: String) async throws -> String? { "z1" }
    func zoneState(zoneID: String, domain: String, apiToken: String) async throws -> CloudflareZoneState { state }
    func listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord] { [] }
    func workerScriptNames(apiToken: String) async throws -> [String] { [] }
}

private final class StubWriter: CloudflareWriting, @unchecked Sendable {
    private(set) var createdRules: [WAFRulePayload] = []
    var errorToThrow: CloudflareError?
    func enableDNSSEC(zoneID: String, apiToken: String) async throws {}
    func setAlwaysUseHTTPS(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func setHSTS(zoneID: String, maxAge: Int, includeSubdomains: Bool, preload: Bool, apiToken: String) async throws {}
    func addDNSRecord(zoneID: String, record: DNSRecordPayload, apiToken: String) async throws {}
    func deleteDNSRecord(zoneID: String, recordID: String, apiToken: String) async throws {}
    func setBotFightMode(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func createWAFCustomRule(zoneID: String, rule: WAFRulePayload, apiToken: String) async throws {
        if let errorToThrow { throw errorToThrow }
        createdRules.append(rule)
    }
    func setSpeedBrain(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func setECH(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func enableZstandardCompression(zoneID: String, apiToken: String) async throws {}
    func setPageShield(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func enableOnionRouting(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    func attachWorkersCustomDomain(hostname: String, workerScriptName: String, apiToken: String) async throws -> CustomDomainAttachResult { .attached }
    func setMarkdownForAgents(hostname: String, enabled: Bool, apiToken: String) async throws -> Bool { true }
}

private final class FailingReader: CloudflareReading, @unchecked Sendable {
    func resolveZoneID(domain: String, apiToken: String) async throws -> String? { "z1" }
    func zoneState(zoneID: String, domain: String, apiToken: String) async throws -> CloudflareZoneState {
        throw CloudflareError.http(status: 500)
    }
    func listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord] { [] }
    func workerScriptNames(apiToken: String) async throws -> [String] { [] }
}

private func zoneState(botFightMode: Bool) -> CloudflareZoneState {
    CloudflareZoneState(
        dnssecActive: true, sslMode: "strict", alwaysUseHTTPS: true, hsts: nil,
        caaRecords: [], mxRecords: [], spfRecords: [], dmarcRecords: [], botFightMode: botFightMode)
}

struct AISearchExecutorTests {
    @Test("policyBlockReason is nil when aiInput is unset")
    func policyAllowsUnset() {
        #expect(AISearchExecutor.policyBlockReason(for: LicensingPolicy()) == nil)
    }

    @Test("policyBlockReason is nil when aiInput is yes")
    func policyAllowsYes() {
        var policy = LicensingPolicy()
        policy.usage.aiInput = .yes
        #expect(AISearchExecutor.policyBlockReason(for: policy) == nil)
    }

    @Test("policyBlockReason is non-nil when aiInput is no")
    func policyBlocksNo() {
        var policy = LicensingPolicy()
        policy.usage.aiInput = .no
        #expect(AISearchExecutor.policyBlockReason(for: policy) != nil)
    }

    @Test("provision adds a WAF skip rule when Bot Fight Mode is on")
    func provisionAddsWAFRuleWhenBotFightModeOn() async throws {
        let writer = StubWriter()
        let executor = AISearchExecutor(reader: StubReader(state: zoneState(botFightMode: true)), writer: writer, provisioner: StubProvisioner())
        let result = try await executor.provision(zoneID: "z1", domain: "Example.com", apiToken: "t")
        #expect(result.wafSkipRuleAdded == true)
        #expect(result.wafSkipRuleWarning == nil)
        #expect(writer.createdRules.count == 1)
        #expect(writer.createdRules.first?.action == "skip")
        #expect(writer.createdRules.first?.actionParameters?.products == ["botFight"])
    }

    @Test("provision skips the WAF rule when Bot Fight Mode is off")
    func provisionSkipsWAFRuleWhenBotFightModeOff() async throws {
        let writer = StubWriter()
        let executor = AISearchExecutor(reader: StubReader(state: zoneState(botFightMode: false)), writer: writer, provisioner: StubProvisioner())
        let result = try await executor.provision(zoneID: "z1", domain: "example.com", apiToken: "t")
        #expect(result.wafSkipRuleAdded == false)
        #expect(result.wafSkipRuleWarning == nil)
        #expect(writer.createdRules.isEmpty)
    }

    @Test("provision degrades to a warning when the WAF skip-rule write fails")
    func provisionDegradesGracefullyWhenWAFRuleWriteFails() async throws {
        let writer = StubWriter()
        writer.errorToThrow = .http(status: 429) // e.g. free-plan 5-rule quota exceeded
        let executor = AISearchExecutor(reader: StubReader(state: zoneState(botFightMode: true)), writer: writer, provisioner: StubProvisioner())
        let result = try await executor.provision(zoneID: "z1", domain: "example.com", apiToken: "t")
        #expect(result.wafSkipRuleAdded == false)
        #expect(result.wafSkipRuleWarning != nil)
        #expect(writer.createdRules.isEmpty)
        // The instance itself must still be reported as provisioned — the caller shouldn't see
        // a thrown error for a step that happened after the instance already existed.
        #expect(result.instance.id == "inst1")
    }

    @Test("provision degrades to a warning when the zone-state read fails")
    func provisionDegradesGracefullyWhenZoneStateReadFails() async throws {
        let executor = AISearchExecutor(reader: FailingReader(), writer: StubWriter(), provisioner: StubProvisioner())
        let result = try await executor.provision(zoneID: "z1", domain: "example.com", apiToken: "t")
        #expect(result.wafSkipRuleAdded == false)
        #expect(result.wafSkipRuleWarning != nil)
    }

    @Test("provision derives the instance namespace from the lowercased, dot-free domain")
    func provisionDerivesNamespace() async throws {
        let provisioner = StubProvisioner()
        let executor = AISearchExecutor(reader: StubReader(state: zoneState(botFightMode: false)), writer: StubWriter(), provisioner: provisioner)
        _ = try await executor.provision(zoneID: "z1", domain: "Example.com", apiToken: "t")
        #expect(provisioner.lastInstanceID == "example-com")
    }

    @Test("provision surfaces the provisioner's thrown error")
    func provisionPropagatesProvisionerError() async throws {
        let provisioner = StubProvisioner()
        provisioner.errorToThrow = .unauthorized
        let executor = AISearchExecutor(reader: StubReader(state: zoneState(botFightMode: false)), writer: StubWriter(), provisioner: provisioner)
        await #expect(throws: CloudflareError.unauthorized) {
            try await executor.provision(zoneID: "z1", domain: "example.com", apiToken: "t")
        }
    }
}

import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport

private final class StubProvisioner: AISearchProvisioning, @unchecked Sendable {
    private(set) var lastDomain: String?
    private(set) var lastInstanceID: String?
    var errorToThrow: (any Error)?
    /// The `source` `aiSearchInstanceSource` reports for the existing instance — only consulted
    /// by `AISearchExecutor.provision` after an `.instanceAlreadyExists` create error.
    var existingInstanceSource = ""

    func createAISearchInstance(domain: String, instanceID: String, apiToken: String) async throws -> AISearchInstance {
        if let errorToThrow { throw errorToThrow }
        lastDomain = domain
        lastInstanceID = instanceID
        return AISearchInstance(id: "inst1", name: instanceID)
    }

    func aiSearchInstanceSource(instanceID: String, apiToken: String) async throws -> String {
        existingInstanceSource
    }
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
        let writer = StubCloudflareWriter()
        let executor = AISearchExecutor(reader: StubCloudflareReader(state: zoneState(botFightMode: true)), writer: writer, provisioner: StubProvisioner())
        let result = try await executor.provision(zoneID: "z1", domain: "Example.com", apiToken: "t")
        #expect(result.wafSkipRuleAdded == true)
        #expect(result.wafSkipRuleWarning == nil)
        #expect(writer.createdRules.count == 1)
        #expect(writer.createdRules.first?.action == "skip")
        #expect(writer.createdRules.first?.actionParameters?.products == ["botFight"])
    }

    @Test("provision skips the WAF rule when Bot Fight Mode is off")
    func provisionSkipsWAFRuleWhenBotFightModeOff() async throws {
        let writer = StubCloudflareWriter()
        let executor = AISearchExecutor(reader: StubCloudflareReader(state: zoneState(botFightMode: false)), writer: writer, provisioner: StubProvisioner())
        let result = try await executor.provision(zoneID: "z1", domain: "example.com", apiToken: "t")
        #expect(result.wafSkipRuleAdded == false)
        #expect(result.wafSkipRuleWarning == nil)
        #expect(writer.createdRules.isEmpty)
    }

    @Test("provision degrades to a warning when the WAF skip-rule write fails")
    func provisionDegradesGracefullyWhenWAFRuleWriteFails() async throws {
        let writer = StubCloudflareWriter()
        writer.errorToThrow = .http(status: 429) // e.g. free-plan 5-rule quota exceeded
        let executor = AISearchExecutor(reader: StubCloudflareReader(state: zoneState(botFightMode: true)), writer: writer, provisioner: StubProvisioner())
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
        let executor = AISearchExecutor(reader: FailingReader(), writer: StubCloudflareWriter(), provisioner: StubProvisioner())
        let result = try await executor.provision(zoneID: "z1", domain: "example.com", apiToken: "t")
        #expect(result.wafSkipRuleAdded == false)
        #expect(result.wafSkipRuleWarning != nil)
    }

    @Test("provision derives the instance namespace from the lowercased, dot-free domain")
    func provisionDerivesNamespace() async throws {
        let provisioner = StubProvisioner()
        let executor = AISearchExecutor(reader: StubCloudflareReader(state: zoneState(botFightMode: false)), writer: StubCloudflareWriter(), provisioner: provisioner)
        _ = try await executor.provision(zoneID: "z1", domain: "Example.com", apiToken: "t")
        #expect(provisioner.lastInstanceID == "example-com")
    }

    @Test("provision surfaces the provisioner's thrown error")
    func provisionPropagatesProvisionerError() async throws {
        let provisioner = StubProvisioner()
        provisioner.errorToThrow = CloudflareError.unauthorized
        let executor = AISearchExecutor(reader: StubCloudflareReader(state: zoneState(botFightMode: false)), writer: StubCloudflareWriter(), provisioner: provisioner)
        await #expect(throws: CloudflareError.unauthorized) {
            try await executor.provision(zoneID: "z1", domain: "example.com", apiToken: "t")
        }
    }

    @Test("provision treats an already-exists create error as success when the existing instance's source matches the domain (#1478)")
    func provisionIsReRunnableAfterInstanceAlreadyExists() async throws {
        let provisioner = StubProvisioner()
        provisioner.errorToThrow = AISearchProvisionError.instanceAlreadyExists
        provisioner.existingInstanceSource = "Example.com"
        let executor = AISearchExecutor(reader: StubCloudflareReader(state: zoneState(botFightMode: false)), writer: StubCloudflareWriter(), provisioner: provisioner)
        let result = try await executor.provision(zoneID: "z1", domain: "Example.com", apiToken: "t")
        #expect(result.instance.id == "example-com")
        #expect(result.instance.name == "example-com")
    }

    @Test("provision fails with instanceIDCollision when the existing instance's source is a different domain (#1478 review)")
    func provisionFailsOnNamespaceCollisionWithADifferentDomain() async throws {
        let provisioner = StubProvisioner()
        provisioner.errorToThrow = AISearchProvisionError.instanceAlreadyExists
        provisioner.existingInstanceSource = "a-b.com"
        let executor = AISearchExecutor(reader: StubCloudflareReader(state: zoneState(botFightMode: false)), writer: StubCloudflareWriter(), provisioner: provisioner)
        await #expect(throws: AISearchProvisionError.instanceIDCollision) {
            // "a.b.com" and "a-b.com" both normalize to instance id "a-b-com".
            try await executor.provision(zoneID: "z1", domain: "a.b.com", apiToken: "t")
        }
    }
}

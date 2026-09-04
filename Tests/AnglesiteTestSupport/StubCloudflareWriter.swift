import Foundation
import AnglesiteCore

/// A recording `CloudflareWriting` stand-in — the superset of the five `StubWriter` copies this
/// replaces (`DomainConfigAuditModelTests`, `AISearchModelTests`, `OnionRoutingModelTests`,
/// `HardenModelTests`, `AISearchExecutorTests`). Every write is a no-op by default; the handful
/// that tests actually assert on (`addDNSRecord`, `createWAFCustomRule`, `enableOnionRouting`)
/// record their arguments, and `errorToThrow` — when set — is thrown by whichever of those a
/// given test is exercising.
public final class StubCloudflareWriter: CloudflareWriting, @unchecked Sendable {
    public private(set) var addedRecords: [DNSRecordPayload] = []
    public private(set) var createdRules: [WAFRulePayload] = []
    public private(set) var lastOnionRoutingZoneID: String?
    public private(set) var lastOnionRoutingEnabled: Bool?
    public var errorToThrow: CloudflareError?

    public init() {}

    public func enableDNSSEC(zoneID: String, apiToken: String) async throws {}
    public func setAlwaysUseHTTPS(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    public func setHSTS(zoneID: String, maxAge: Int, includeSubdomains: Bool, preload: Bool, apiToken: String) async throws {}
    public func addDNSRecord(zoneID: String, record: DNSRecordPayload, apiToken: String) async throws {
        addedRecords.append(record)
    }
    public func deleteDNSRecord(zoneID: String, recordID: String, apiToken: String) async throws {}
    public func setBotFightMode(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    public func createWAFCustomRule(zoneID: String, rule: WAFRulePayload, apiToken: String) async throws {
        if let errorToThrow { throw errorToThrow }
        createdRules.append(rule)
    }
    public func setSpeedBrain(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    public func setECH(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    public func enableZstandardCompression(zoneID: String, apiToken: String) async throws {}
    public func setPageShield(zoneID: String, enabled: Bool, apiToken: String) async throws {}
    public func enableOnionRouting(zoneID: String, enabled: Bool, apiToken: String) async throws {
        if let errorToThrow { throw errorToThrow }
        lastOnionRoutingZoneID = zoneID
        lastOnionRoutingEnabled = enabled
    }
    public func attachWorkersCustomDomain(hostname: String, workerScriptName: String, apiToken: String) async throws -> CustomDomainAttachResult {
        .attached
    }
    public func setMarkdownForAgents(hostname: String, enabled: Bool, apiToken: String) async throws -> Bool { true }
}

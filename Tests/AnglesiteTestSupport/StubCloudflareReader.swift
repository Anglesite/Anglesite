import Foundation
import AnglesiteCore

/// A configurable `CloudflareReading` stand-in — the superset of the six `StubReader` copies
/// this replaces (`DomainConfigAuditModelTests`, `PlistEditorModelBotPreferenceSyncTests`,
/// `AISearchModelTests`, `OnionRoutingModelTests`, `HardenModelTests`, `AISearchExecutorTests`):
/// `zoneID`/`state`/`records` are all injectable, and every call is recorded for tests that need
/// to assert on it (`resolvedDomain`, `listedZoneID`).
public final class StubCloudflareReader: CloudflareReading, @unchecked Sendable {
    private let zoneID: String?
    private let state: CloudflareZoneState
    private let records: [DNSRecord]
    public private(set) var resolvedDomain: String?
    public private(set) var listedZoneID: String?

    /// A fully hardened zone: DNSSEC on, strict SSL, HTTPS enforced.
    public static let cleanState = CloudflareZoneState(
        dnssecActive: true, sslMode: "strict", alwaysUseHTTPS: true,
        hsts: nil, caaRecords: [], mxRecords: [], spfRecords: [], dmarcRecords: [])
    /// An unhardened zone: DNSSEC off, flexible SSL, HTTPS not enforced.
    public static let defaultState = CloudflareZoneState(
        dnssecActive: false, sslMode: "flexible", alwaysUseHTTPS: false, hsts: nil,
        caaRecords: [], mxRecords: [], spfRecords: [], dmarcRecords: [])

    public init(zoneID: String? = "z1", state: CloudflareZoneState = StubCloudflareReader.cleanState, records: [DNSRecord] = []) {
        self.zoneID = zoneID
        self.state = state
        self.records = records
    }

    public func resolveZoneID(domain: String, apiToken: String) async throws -> String? {
        resolvedDomain = domain
        return zoneID
    }
    public func zoneState(zoneID: String, domain: String, apiToken: String) async throws -> CloudflareZoneState { state }
    public func listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord] {
        listedZoneID = zoneID
        return records
    }
    public func workerScriptNames(apiToken: String) async throws -> [String] { [] }
}

import Testing
import Foundation
@testable import AnglesiteAppCore
@testable import AnglesiteCore

private final class StubReader: CloudflareReading, @unchecked Sendable {
    private let zoneID: String?
    init(zoneID: String?) { self.zoneID = zoneID }
    func resolveZoneID(domain: String, apiToken: String) async throws -> String? { zoneID }
    func zoneState(zoneID: String, domain: String, apiToken: String) async throws -> CloudflareZoneState {
        CloudflareZoneState(
            dnssecActive: false, sslMode: "strict", alwaysUseHTTPS: false,
            hsts: nil, caaRecords: [], mxRecords: [], spfRecords: [], dmarcRecords: [])
    }
    func listDNSRecords(zoneID: String, apiToken: String) async throws -> [DNSRecord] { [] }
    func workerScriptNames(apiToken: String) async throws -> [String] { [] }
}

@Suite("PlistEditorModel Bot Preference Sync zone gating (#1628)")
@MainActor
struct PlistEditorModelBotPreferenceSyncTests {
    private static let emptyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """

    private func makeModel(
        licensingJSON: String? = nil,
        domain: String? = "example.com",
        token: String? = "test-token",
        zoneID: String? = "z1",
        flagEnabled: Bool = true
    ) throws -> PlistEditorModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlistEditorModelBotPreferenceSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plistURL = dir.appendingPathComponent("Info.plist")
        try Self.emptyPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        if let domain {
            try "DOMAIN=\(domain)\n".write(
                to: dir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        }
        if let licensingJSON {
            let dataDir = dir.appendingPathComponent("src/data", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            try licensingJSON.write(
                to: dataDir.appendingPathComponent("licensing.json"), atomically: true, encoding: .utf8)
        }
        let keychain = KeychainStore(service: "io.dwk.anglesite.test-\(UUID().uuidString)")
        if let token { try keychain.writeCloudflareToken(token) }
        let suiteName = "test-anglesite-\(UUID().uuidString)"
        let appSettings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        appSettings.botPreferenceSyncUIEnabled = flagEnabled
        let file = FileRef(url: plistURL, group: .metadata, name: "Info.plist")
        return PlistEditorModel(
            file: file, websiteTitle: "Test Site", sourceDirectory: dir,
            keychain: keychain,
            reader: StubReader(zoneID: zoneID),
            appSettings: appSettings)
    }

    @Test("flag off: never resolves a zone, even with a domain and token")
    func flagOffNeverResolves() async throws {
        let model = try makeModel(flagEnabled: false)
        await model.load()
        #expect(model.botPreferenceSyncZoneID == nil)
    }

    @Test("flag on, zone resolves, pristine usage: preselects cloudflare without marking the tab dirty")
    func pristineUsagePreselectsCloudflare() async throws {
        let model = try makeModel()
        await model.load()
        #expect(model.botPreferenceSyncZoneID == "z1")
        #expect(model.licensingPolicy.usage.botBlocklistManagedBy == .cloudflare)
        #expect(model.isLicensingDirty == false)
    }

    @Test("flag on, zone resolves, an expressed preference: never overridden")
    func expressedPreferenceIsUnchanged() async throws {
        let model = try makeModel(licensingJSON: #"{"usage":{"blockAICrawlers":false,"aiTrain":"no"}}"#)
        await model.load()
        #expect(model.botPreferenceSyncZoneID == "z1")
        #expect(model.licensingPolicy.usage.botBlocklistManagedBy == .anglesite)
    }

    @Test("flag on, no zone resolves: stays anglesite-managed and hides the option")
    func noZoneResolved() async throws {
        let model = try makeModel(zoneID: nil)
        await model.load()
        #expect(model.botPreferenceSyncZoneID == nil)
        #expect(model.licensingPolicy.usage.botBlocklistManagedBy == .anglesite)
    }

    /// Final-review finding (#1628): a site can be persisted as Cloudflare-managed while its
    /// zone doesn't currently resolve — the flag was turned back off and on, the token rotated,
    /// or Cloudflare was briefly unreachable. This never happens by the preselection algorithm
    /// alone (that only ever *sets* `.cloudflare` when a zone resolves, never clears it), but it
    /// is exactly what an already-Cloudflare-managed `licensing.json` produces once the zone
    /// stops resolving. `ContentLicensingTab` must key its mode branch on
    /// `botBlocklistManagedBy` alone in this state — never on `botPreferenceSyncZoneID` — or it
    /// falls through to the "Refuse AI crawlers" toggle whose effect the build (`edge-artifacts.ts`,
    /// gated purely on the persisted `botBlocklistManagedBy`) silently ignores. This test proves
    /// the state combination itself is reachable and unambiguous at the model layer, so the
    /// view's `if model.licensingPolicy.usage.botBlocklistManagedBy == .cloudflare` branch
    /// (zone-independent) is provably correct by inspection.
    @Test("flag on, persisted cloudflare mode, zone no longer resolves: mode is preserved, not silently reverted")
    func persistedCloudflareModeSurvivesUnresolvedZone() async throws {
        let model = try makeModel(
            licensingJSON: #"{"usage":{"botBlocklistManagedBy":"cloudflare","blockAICrawlers":true,"aiInput":"no","aiTrain":"no"}}"#,
            zoneID: nil)
        await model.load()
        #expect(model.botPreferenceSyncZoneID == nil)
        #expect(model.licensingPolicy.usage.botBlocklistManagedBy == .cloudflare)
    }

    @Test("flag on, no domain configured: never attempts resolution")
    func noDomainConfigured() async throws {
        let model = try makeModel(domain: nil)
        await model.load()
        #expect(model.botPreferenceSyncZoneID == nil)
    }

    @Test("flag on, no Cloudflare token: never attempts resolution")
    func noToken() async throws {
        let model = try makeModel(token: nil)
        await model.load()
        #expect(model.botPreferenceSyncZoneID == nil)
    }
}

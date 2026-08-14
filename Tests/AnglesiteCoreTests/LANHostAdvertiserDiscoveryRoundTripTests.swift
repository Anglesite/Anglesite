#if canImport(Network)
import Network
import Testing
@testable import AnglesiteCore

/// Round-trip guard between `LANHostAdvertiser`'s TXT record and
/// `NWBonjourLANHostDiscovery`'s decoding of it. This is the only automated check against the
/// advertiser and the browser drifting on TXT key names — an `NWTXTRecord` can be built and
/// decoded entirely in-process, with no real Bonjour advertising/browsing required (#858
/// final-review Important #6).
@Suite("LANHostAdvertiser <-> NWBonjourLANHostDiscovery TXT round trip")
struct LANHostAdvertiserDiscoveryRoundTripTests {
    /// Builds a TXT record the same way `LANHostAdvertiser.start` does, key-for-key.
    private func advertiserTXTRecord(
        site: String = "my-blog", previewPort: Int = 4321, mcpPort: Int = 4399,
        hostname: String = "Davids-Mac-mini.local"
    ) -> NWTXTRecord {
        var txtRecord = NWTXTRecord()
        txtRecord.setEntry(.string(site), for: "site")
        txtRecord.setEntry(.string(String(previewPort)), for: "previewPort")
        txtRecord.setEntry(.string(String(mcpPort)), for: "mcpPort")
        txtRecord.setEntry(.string(hostname), for: "hostname")
        return txtRecord
    }

    @Test("decodeKnownEntries round-trips every key LANHostAdvertiser writes")
    func decodesAllAdvertiserKeys() {
        let decoded = NWBonjourLANHostDiscovery.decodeKnownEntries(from: advertiserTXTRecord())
        #expect(decoded == [
            "site": "my-blog", "previewPort": "4321", "mcpPort": "4399",
            "hostname": "Davids-Mac-mini.local",
        ])
    }

    @Test("the decoded dict still builds a valid DiscoveredLANHost")
    func decodedDictBuildsDiscoveredLANHost() {
        let decoded = NWBonjourLANHostDiscovery.decodeKnownEntries(from: advertiserTXTRecord())
        let host = DiscoveredLANHost(txtRecord: decoded, dnsName: "ignored.local", ipAddress: "192.168.1.42")
        #expect(host == DiscoveredLANHost(
            siteName: "my-blog", dnsName: "ignored.local", ipAddress: "192.168.1.42",
            previewPort: 4321, mcpPort: 4399))
    }

    @Test("resolvedDNSName prefers the advertiser's hostname entry over synthesis")
    func resolvedDNSNamePrefersHostnameEntry() {
        let decoded = NWBonjourLANHostDiscovery.decodeKnownEntries(
            from: advertiserTXTRecord(hostname: "Davids-Mac-mini.local"))
        // The Bonjour *instance* name (`name` below) is the device display name — spaced and
        // apostrophe'd — which is exactly the value `resolvedDNSName` must NOT fall back to here.
        let dnsName = NWBonjourLANHostDiscovery.resolvedDNSName(
            from: decoded, name: "David's Mac mini", domain: "local")
        #expect(dnsName == "Davids-Mac-mini.local")
    }

    @Test("resolvedDNSName falls back to instance-name synthesis when hostname is absent")
    func resolvedDNSNameFallsBackWithoutHostnameKey() {
        // Simulates a TXT record from an advertiser that predates the `hostname` key.
        let dnsName = NWBonjourLANHostDiscovery.resolvedDNSName(
            from: ["site": "my-blog", "previewPort": "4321", "mcpPort": "4399"],
            name: "my-blog", domain: "")
        #expect(dnsName == "my-blog.local")
    }
}
#endif

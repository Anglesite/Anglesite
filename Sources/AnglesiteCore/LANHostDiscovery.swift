import Foundation

/// A LAN host discovered via Bonjour, advertising itself as `_anglesite-lan._tcp`
/// (see `LANHostAdvertiser`). Carries everything `AdvancedSettingsView`'s "Find on local
/// network" button needs to either auto-populate or list a candidate.
public struct DiscoveredLANHost: Sendable, Equatable {
    /// The `--site` basename the host was launched with, e.g. `my-blog`. Disambiguates multiple
    /// `anglesite-lan-host` instances advertising on the same network.
    public let siteName: String
    /// The resolved Bonjour hostname, e.g. `mac-studio.local`.
    public let dnsName: String
    /// The resolved IP address as a string, e.g. `192.168.1.42`.
    public let ipAddress: String
    /// The host's `astro dev` preview port, from the TXT record.
    public let previewPort: Int
    /// The host's MCP sidecar port, from the TXT record.
    public let mcpPort: Int

    public init(siteName: String, dnsName: String, ipAddress: String, previewPort: Int, mcpPort: Int) {
        self.siteName = siteName
        self.dnsName = dnsName
        self.ipAddress = ipAddress
        self.previewPort = previewPort
        self.mcpPort = mcpPort
    }
}

extension DiscoveredLANHost {
    /// Decodes a Bonjour TXT record (`site`, `previewPort`, `mcpPort` keys — written by
    /// `LANHostAdvertiser`) into a `DiscoveredLANHost`. Returns `nil` when any key is missing or
    /// a port fails to parse as an `Int`, so a malformed or foreign TXT record is dropped rather
    /// than crashing or producing a garbage entry.
    public init?(txtRecord: [String: String], dnsName: String, ipAddress: String) {
        guard let siteName = txtRecord["site"],
              let previewPortString = txtRecord["previewPort"], let previewPort = Int(previewPortString),
              let mcpPortString = txtRecord["mcpPort"], let mcpPort = Int(mcpPortString) else {
            return nil
        }
        self.init(siteName: siteName, dnsName: dnsName, ipAddress: ipAddress,
                  previewPort: previewPort, mcpPort: mcpPort)
    }
}

/// What `AdvancedSettingsView` should do with the hosts a scan found — the pure "0/1/N" rule
/// issue #858 specifies. Plain data in, plain data out: no `Network` import, no timing, no view.
public enum LANHostSelection: Equatable {
    /// No hosts found (or none still visible by the time the scan window closed).
    case empty
    /// Exactly one host found — fill in host/ports without further user interaction.
    case autoPopulate(DiscoveredLANHost)
    /// More than one host found — show a picker; hosts are in discovery order.
    case chooseFrom([DiscoveredLANHost])
}

/// Implements the rule from issue #858: one server found → auto-populate; more than one →
/// present a list; none → empty state.
public func selectLANHost(from hosts: [DiscoveredLANHost]) -> LANHostSelection {
    switch hosts.count {
    case 0: return .empty
    case 1: return .autoPopulate(hosts[0])
    default: return .chooseFrom(hosts)
    }
}

/// Discovers `anglesite-lan-host` instances on the local network. Mirrors `ConnectivityMonitoring`
/// (`Platform/ConnectivityMonitoring.swift`): a platform-agnostic protocol, with the concrete
/// `Network`-framework implementation kept in a separate file so `AdvancedSettingsView` and this
/// file never need to import `Network` themselves.
public protocol LANHostDiscovering: Sendable {
    /// Begins browsing, delivering the accumulated set of currently-visible hosts to `onUpdate`
    /// every time the browse results change. Callbacks may arrive on an arbitrary queue.
    func start(onUpdate: @escaping @Sendable ([DiscoveredLANHost]) -> Void)
    /// Stops browsing; no further callbacks are delivered after it returns. Idempotent.
    func stop()
}

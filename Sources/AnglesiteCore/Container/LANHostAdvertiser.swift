#if canImport(Network)
import Network
import Foundation

/// Advertises an `anglesite-lan-host` instance on the local network via Bonjour so
/// `NWBonjourLANHostDiscovery` can find it. The listener never accepts real connections — it
/// exists only to carry the Bonjour record. The real preview/MCP ports (already bound by the
/// astro-dev/mcp-sidecar child processes `AnglesiteLANHost` launches) live in the TXT record
/// instead of the listener's own port.
public final class LANHostAdvertiser: @unchecked Sendable {
    public static let serviceType = "_anglesite-lan._tcp"

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "io.dwk.anglesite.lan-advertiser")

    public init() {}

    /// Starts advertising with a TXT record carrying `site`, `previewPort`, `mcpPort`, and
    /// `hostname` — the keys `DiscoveredLANHost.init(txtRecord:dnsName:ipAddress:)` and
    /// `NWBonjourLANHostDiscovery` decode. `hostname` carries `ProcessInfo.hostName` (the actual
    /// resolvable mDNS hostname, e.g. `"Davids-Mac-mini.local"`) rather than relying on the
    /// browsing side synthesizing a name from this listener's Bonjour *instance* name, which
    /// defaults to the device's display name and can contain spaces/apostrophes that make it
    /// unusable as a URL host (#858 final-review Critical #3).
    ///
    /// A failure to create the underlying listener (e.g. no network interfaces), or an async
    /// `.failed` listener state once started, leaves the host simply undiscoverable rather than
    /// crashing the standing process — typing the host manually still works — but is printed so
    /// it's visible in this foreground dev tool's own output rather than silently swallowed.
    public func start(site: String, previewPort: Int, mcpPort: Int) {
        var txtRecord = NWTXTRecord()
        txtRecord.setEntry(.string(site), for: "site")
        txtRecord.setEntry(.string(String(previewPort)), for: "previewPort")
        txtRecord.setEntry(.string(String(mcpPort)), for: "mcpPort")
        txtRecord.setEntry(.string(ProcessInfo.processInfo.hostName), for: "hostname")

        guard let listener = try? NWListener(using: .tcp) else {
            print("anglesite-lan-host: failed to create Bonjour listener; LAN discovery unavailable")
            return
        }
        listener.service = NWListener.Service(type: Self.serviceType, txtRecord: txtRecord)
        listener.newConnectionHandler = { connection in connection.cancel() }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("anglesite-lan-host: Bonjour advertising ready (\(Self.serviceType))")
            case .failed(let error):
                print("anglesite-lan-host: Bonjour advertising failed: \(error)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Stops advertising. Idempotent.
    public func stop() {
        listener?.cancel()
        listener = nil
    }
}
#endif

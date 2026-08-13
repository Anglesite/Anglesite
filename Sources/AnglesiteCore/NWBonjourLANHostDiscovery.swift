#if canImport(Network)
import Network
import Foundation

/// Production `LANHostDiscovering` backed by `Network.framework`'s `NWBrowser`, browsing for
/// `_anglesite-lan._tcp` (advertised by `LANHostAdvertiser`). Resolves each result to a DNS name
/// + IP address and decodes its TXT record via `DiscoveredLANHost.init(txtRecord:dnsName:ipAddress:)`,
/// dropping any result that fails to decode.
public final class NWBonjourLANHostDiscovery: LANHostDiscovering, @unchecked Sendable {
    public static let serviceType = "_anglesite-lan._tcp"

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "io.dwk.anglesite.lan-discovery")
    private let lock = NSLock()
    private var running = false

    public init() {}

    public func start(onUpdate: @escaping @Sendable ([DiscoveredLANHost]) -> Void) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

        // `.bonjourWithTXTRecord` (not plain `.bonjour`) is required so each browse result's
        // `.metadata` actually carries the resolved `NWTXTRecord` — with plain `.bonjour`,
        // `.metadata` stays `.none` and every result would be dropped in `resolveAll`.
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: Self.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.resolveAll(results, onUpdate: onUpdate)
        }
        browser.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()
        browser?.cancel()
        browser = nil
    }

    /// Resolves every current browse result to a `DiscoveredLANHost` (dropping ones that fail),
    /// then delivers the whole accumulated set at once — the coordinator (Task 5) only ever needs
    /// "what's visible right now," not incremental diffs.
    private func resolveAll(_ results: Set<NWBrowser.Result>, onUpdate: @escaping @Sendable ([DiscoveredLANHost]) -> Void) {
        var hosts: [DiscoveredLANHost] = []
        let group = DispatchGroup()
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint,
                  case .bonjour(let txtRecord) = result.metadata else { continue }
            group.enter()
            resolve(name: name, type: type, domain: domain, txtRecord: txtRecord) { host in
                if let host { hosts.append(host) }
                group.leave()
            }
        }
        group.notify(queue: queue) { onUpdate(hosts) }
    }

    /// Opens a short-lived connection to the service endpoint purely to resolve its concrete
    /// host/IP (a Bonjour service endpoint doesn't carry a resolved address until connected).
    private func resolve(
        name: String, type: String, domain: String, txtRecord: NWTXTRecord,
        completion: @escaping (DiscoveredLANHost?) -> Void
    ) {
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready:
                var ipAddress = ""
                if case .hostPort(let host, _) = connection?.currentPath?.remoteEndpoint {
                    ipAddress = "\(host)"
                }
                let dnsName = domain.isEmpty ? "\(name).local" : "\(name).\(domain)"
                let dict = Self.decodeKnownEntries(from: txtRecord)
                let host = DiscoveredLANHost(txtRecord: dict, dnsName: dnsName, ipAddress: ipAddress)
                connection?.cancel()
                completion(host)
            case .failed, .cancelled:
                completion(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Reads only the three keys `LANHostAdvertiser` writes — avoids depending on `NWTXTRecord`'s
    /// full enumeration API surface for keys this feature never uses.
    private static func decodeKnownEntries(from txtRecord: NWTXTRecord) -> [String: String] {
        var dict: [String: String] = [:]
        for key in ["site", "previewPort", "mcpPort"] {
            if case .string(let value)? = txtRecord.getEntry(for: key) {
                dict[key] = value
            }
        }
        return dict
    }
}

/// Compile-time factory for the platform's LAN-host discovery implementation, keeping the `#if`
/// selection here rather than at each call site — mirrors `PlatformConnectivityMonitor`.
public enum PlatformLANHostDiscovery {
    public static func make() -> any LANHostDiscovering {
        NWBonjourLANHostDiscovery()
    }
}
#else
/// Platforms without `Network.framework` report no hosts — "Find on local network" is inert
/// there rather than crashing or hanging indefinitely.
public final class UnavailableLANHostDiscovery: LANHostDiscovering, @unchecked Sendable {
    public init() {}
    public func start(onUpdate: @escaping @Sendable ([DiscoveredLANHost]) -> Void) { onUpdate([]) }
    public func stop() {}
}

public enum PlatformLANHostDiscovery {
    public static func make() -> any LANHostDiscovering {
        UnavailableLANHostDiscovery()
    }
}
#endif

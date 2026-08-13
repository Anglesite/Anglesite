#if canImport(Network)
import Network
import Foundation

/// Production `LANHostDiscovering` backed by `Network.framework`'s `NWBrowser`, browsing for
/// `_anglesite-lan._tcp` (advertised by `LANHostAdvertiser`). Resolves each result to a DNS name
/// + IP address and decodes its TXT record via `DiscoveredLANHost.init(txtRecord:dnsName:ipAddress:)`,
/// dropping any result that fails to decode.
public final class NWBonjourLANHostDiscovery: LANHostDiscovering, @unchecked Sendable {
    public static let serviceType = "_anglesite-lan._tcp"

    /// How long `resolve` waits for a browsed endpoint to reach `.ready`/`.failed`/`.cancelled`
    /// before giving up on it. Without this, an endpoint that's browsable but not connectable
    /// (e.g. stale mDNS cache) parks its `NWConnection` in `.waiting` forever, which never calls
    /// `group.leave()` in `resolveAll` — silently dropping the *entire* batch, including healthy
    /// hosts, from `group.notify`.
    private static let resolveTimeout: TimeInterval = 2

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "io.dwk.anglesite.lan-discovery")
    private let lock = NSLock()
    private var running = false
    // Keyed by `ObjectIdentifier` rather than held in a `Set<NWConnection>` — `NWConnection`
    // doesn't conform to `Hashable`. Without this, nothing retains the connections `resolve`
    // creates: `resolve` only holds one locally as a `let`, and its own state-update handler
    // captures it `[weak connection]`, so ARC would deallocate it the moment `resolve` returns,
    // before it could ever reach `.ready`.
    private var pendingConnections: [ObjectIdentifier: NWConnection] = [:]

    public init() {}

    public func start(onUpdate: @escaping @Sendable ([DiscoveredLANHost]) -> Void) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true

        // `.bonjourWithTXTRecord` (not plain `.bonjour`) is required so each browse result's
        // `.metadata` actually carries the resolved `NWTXTRecord` — with plain `.bonjour`,
        // `.metadata` stays `.none` and every result would be dropped in `resolveAll`.
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: Self.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        // `self.browser` is written here, still under `lock`, so `stop()` can never observe a
        // window where `running` is true but `browser` is still nil (which would make its
        // `browser?.cancel()` a no-op against a browser `start()` is about to hand off below).
        self.browser = browser
        lock.unlock()

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.resolveAll(results, onUpdate: onUpdate)
        }
        browser.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        // Read-and-clear `browser` under the same lock that guards its write in `start()`, so
        // there's no unsynchronized access to the property from two call sites.
        let browser = self.browser
        self.browser = nil
        // Also drain any in-flight resolutions so their sockets don't linger past `stop()`.
        // Cancelling them still runs their state-update handlers (asynchronously, off this
        // lock), but `resolveAll`'s `group.notify` gates delivery on `running`, so this can't
        // resurrect a callback after `stop()` returns.
        let connections = Array(pendingConnections.values)
        pendingConnections.removeAll()
        lock.unlock()
        browser?.cancel()
        connections.forEach { $0.cancel() }
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
        group.notify(queue: queue) {
            // A `browseResultsChangedHandler` firing just before `stop()` runs can still have
            // this `group.notify` complete afterward — `NWBrowser.cancel()`/`NWConnection.cancel()`
            // are asynchronous, they don't abort in-flight `resolve` completions. Gate delivery on
            // `running` so `stop()`'s "no further callbacks after it returns" contract holds even
            // for work that was already in flight when it was called.
            self.lock.lock()
            let isRunning = self.running
            self.lock.unlock()
            guard isRunning else { return }
            onUpdate(hosts)
        }
    }

    /// Opens a short-lived connection to the service endpoint purely to resolve its concrete
    /// host/IP (a Bonjour service endpoint doesn't carry a resolved address until connected).
    ///
    /// `completion` is guaranteed to be called exactly once, and within `resolveTimeout` seconds.
    /// This matters because `resolveAll` pairs every `resolve` call with a `DispatchGroup.enter()`
    /// and calls `group.leave()` unconditionally from `completion` — a double call would over-leave
    /// the group (libdispatch traps), and a call that never arrives would leave the group waiting
    /// forever, silently dropping the whole batch (see `resolveTimeout`'s doc comment).
    private func resolve(
        name: String, type: String, domain: String, txtRecord: NWTXTRecord,
        completion: @escaping (DiscoveredLANHost?) -> Void
    ) {
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let connectionID = ObjectIdentifier(connection)

        lock.lock()
        pendingConnections[connectionID] = connection
        lock.unlock()

        // One-shot guard: `.ready` below calls `finish(host)` and then `connection.cancel()` —
        // but `cancel()` is asynchronous and delivers a *subsequent* `.cancelled` state to this
        // SAME `stateUpdateHandler`, which would otherwise fall into `.failed, .cancelled` and
        // call `finish(nil)` a second time. Both the state-update handler and the timeout below
        // run on `queue` (a serial queue), so this plain `Bool` needs no separate lock.
        var didComplete = false
        let finish: (DiscoveredLANHost?) -> Void = { [weak self] host in
            guard !didComplete else { return }
            didComplete = true
            if let self {
                self.lock.lock()
                self.pendingConnections.removeValue(forKey: connectionID)
                self.lock.unlock()
            }
            completion(host)
        }

        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready:
                var ipAddress = ""
                if case .hostPort(let host, _) = connection?.currentPath?.remoteEndpoint {
                    ipAddress = "\(host)"
                }
                let dict = Self.decodeKnownEntries(from: txtRecord)
                let dnsName = Self.resolvedDNSName(from: dict, name: name, domain: domain)
                let host = DiscoveredLANHost(txtRecord: dict, dnsName: dnsName, ipAddress: ipAddress)
                finish(host)
                connection?.cancel()
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + Self.resolveTimeout) {
            finish(nil)
            connection.cancel()
        }
    }

    /// The TXT record's `hostname` entry (written by `LANHostAdvertiser` from
    /// `ProcessInfo.processInfo.hostName`, the actual resolvable mDNS hostname) when present;
    /// otherwise falls back to synthesizing one from the Bonjour *instance* name, for backward
    /// compatibility with any other advertiser of this service type that predates the `hostname`
    /// key. The instance name is normally the device's display name (e.g. "David's Mac mini"),
    /// which can contain spaces/apostrophes and isn't a usable URL host — see #858 final-review
    /// Critical #3.
    static func resolvedDNSName(from txtDict: [String: String], name: String, domain: String) -> String {
        if let hostname = txtDict["hostname"], !hostname.isEmpty {
            return hostname
        }
        return domain.isEmpty ? "\(name).local" : "\(name).\(domain)"
    }

    /// Reads the known keys `LANHostAdvertiser` writes — avoids depending on `NWTXTRecord`'s full
    /// enumeration API surface for keys this feature never uses. `hostname` is optional (older
    /// advertisers may not write it); the other three are required by
    /// `DiscoveredLANHost.init(txtRecord:dnsName:ipAddress:)`.
    static func decodeKnownEntries(from txtRecord: NWTXTRecord) -> [String: String] {
        var dict: [String: String] = [:]
        for key in ["site", "previewPort", "mcpPort", "hostname"] {
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

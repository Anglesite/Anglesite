import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What probing one off-site link learned (#2027). Three-valued for the same reason as
/// ``SitemapPreflightResult``: a probe that couldn't get a definitive answer must never be
/// reported as a dead link — the broken-link audit's external check is advisory (#2001).
public enum LinkReachability: Sendable, Equatable {
    /// An HTTP 2xx came back, possibly after following redirects.
    case reachable
    /// The server definitively said the page is gone (404/410) — the only statuses that can't
    /// be the probe itself being rejected.
    case unreachable
    /// Anything that isn't a definitive answer: no HTTP response (timeout, DNS failure, TLS
    /// error, …), an ambiguous status (403 bot challenge, 429, 5xx, …), or a URL the run's time
    /// budget or a cancellation left unprobed.
    case indeterminate
}

/// Probes whether off-site URLs still resolve, for the opt-in external half of the broken-link
/// audit (#2001). Seam-shaped like ``SitemapPreflighting``: tests stub it.
public protocol ExternalLinkProbing: Sendable {
    /// Probes every URL in `urls`. Never throws — every failure folds into a
    /// ``LinkReachability`` case — and the result has an entry for **every** input URL
    /// (duplicates collapse to one), so a caller never has to tell "missing" from "couldn't tell".
    func probe(_ urls: [URL]) async -> [URL: LinkReachability]
}

/// Live implementation, mirroring ``HTTPSitemapPreflight``: `HEAD` each URL, falling back to a
/// one-byte ranged `GET` on 405/501, following redirects (the transport's `URLSession` default).
/// Polite by construction: at most ``defaultMaxConcurrent`` requests in flight, each with a
/// ``defaultRequestTimeout``, and the whole call bounded by ``defaultTotalBudget`` of wall clock
/// — past that, in-flight requests are cancelled and everything unresolved is `.indeterminate`.
/// No User-Agent is set: a bot challenge is `.indeterminate` by design, not something to evade.
public struct HTTPExternalLinkProbe: ExternalLinkProbing {
    /// Most requests in flight at once.
    public static let defaultMaxConcurrent = 6
    /// Per-request timeout; the HEAD and any GET fallback each get the full interval.
    public static let defaultRequestTimeout: TimeInterval = 10
    /// Wall-clock bound on one ``probe(_:)`` call, so an opt-in audit grows by about a minute at most.
    public static let defaultTotalBudget: Duration = .seconds(60)

    private let transport: CloudflareTransport
    private let maxConcurrent: Int
    private let requestTimeout: TimeInterval
    private let totalBudget: Duration

    /// The transport parameter exists for tests (fake responses, no network); production uses
    /// ``defaultTransport``. Reuses the ``CloudflareTransport`` seam shape even though this probe
    /// never talks to Cloudflare — it's the package's standard injectable HTTP boundary.
    public init(transport: @escaping CloudflareTransport = HTTPExternalLinkProbe.defaultTransport) {
        self.init(
            transport: transport,
            maxConcurrent: Self.defaultMaxConcurrent,
            requestTimeout: Self.defaultRequestTimeout,
            totalBudget: Self.defaultTotalBudget)
    }

    /// Tests shrink the budget so budget-expiry cases run in milliseconds.
    init(transport: @escaping CloudflareTransport, maxConcurrent: Int, requestTimeout: TimeInterval, totalBudget: Duration) {
        self.transport = transport
        self.maxConcurrent = max(1, maxConcurrent)
        self.requestTimeout = requestTimeout
        self.totalBudget = totalBudget
    }

    /// Production transport: a plain shared-`URLSession` request, mirroring
    /// ``HTTPSitemapPreflight/defaultTransport``.
    public static let defaultTransport: CloudflareTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func probe(_ urls: [URL]) async -> [URL: LinkReachability] {
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return [:] }

        // Race the probing window against the budget; whichever finishes first cancels the
        // other. The window always drains its own children, so it returns what resolved even
        // when cancelled — by the budget or by the caller.
        let budget = totalBudget
        var resolved: [URL: LinkReachability] = [:]
        await withTaskGroup(of: [URL: LinkReachability]?.self) { race in
            race.addTask { await self.probeWindow(unique) }
            race.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            // The first finisher is either the window's map (it won) or the timer's `nil`.
            if case let .some(.some(finished)) = await race.next() { resolved = finished }
            race.cancelAll()
            for await partial in race {
                if let partial { resolved = partial }
            }
        }
        var result = Dictionary(uniqueKeysWithValues: unique.map { ($0, LinkReachability.indeterminate) })
        for (url, reachability) in resolved { result[url] = reachability }
        return result
    }

    /// Keeps up to `maxConcurrent` probes running, starting the next URL as each completes, and
    /// stops starting new ones once cancelled. Returns every result it got.
    private func probeWindow(_ urls: [URL]) async -> [URL: LinkReachability] {
        await withTaskGroup(of: (URL, LinkReachability).self) { group in
            var pending = urls.makeIterator()
            for _ in 0..<maxConcurrent {
                guard let url = pending.next() else { break }
                group.addTask { (url, await self.probeOne(url)) }
            }
            var results: [URL: LinkReachability] = [:]
            while let (url, reachability) = await group.next() {
                results[url] = reachability
                if let next = pending.next() {
                    // No-op once cancelled: remaining URLs stay unprobed and read `.indeterminate`.
                    group.addTaskUnlessCancelled { (next, await self.probeOne(next)) }
                }
            }
            return results
        }
    }

    private func probeOne(_ url: URL) async -> LinkReachability {
        var head = URLRequest(url: url, timeoutInterval: requestTimeout)
        head.httpMethod = "HEAD"
        do {
            let (_, http) = try await transport(head)
            if http.statusCode == 405 || http.statusCode == 501 {
                // Host doesn't do HEAD — ask again with the cheapest possible GET.
                try Task.checkCancellation()
                var get = URLRequest(url: url, timeoutInterval: requestTimeout)
                get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                let (_, getHTTP) = try await transport(get)
                return Self.reachability(forStatus: getHTTP.statusCode)
            }
            return Self.reachability(forStatus: http.statusCode)
        } catch {
            return .indeterminate
        }
    }

    /// Same conservative rule as ``HTTPSitemapPreflight``: only 404/410 are definitive "gone".
    static func reachability(forStatus status: Int) -> LinkReachability {
        switch status {
        case 200..<300: return .reachable
        case 404, 410: return .unreachable
        default: return .indeterminate
        }
    }
}

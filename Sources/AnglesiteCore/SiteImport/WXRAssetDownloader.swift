import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// (AnglesiteCore is in the Linux portable target set — see LinkMetadataFetcher.swift).
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads the remote images a WXR import's post/page content references (#1636).
///
/// Every other rung's images already have their bytes on disk because a live crawl fetched them
/// during capture — WXR is a one-shot file with no crawl, so nothing has fetched anything yet.
/// This writes raw bytes to disk and returns ``CapturedAsset`` records in exactly the shape
/// ``AssetLocalizer/localize(markdown:imageURLs:itemSlug:snapshot:snapshotDirectory:siteDirectory:)``
/// already consumes, so format-sniffing/size-cap validation stays in that one place instead of
/// being duplicated here — this only fetches and writes.
public struct WXRAssetDownloader: Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            // Ephemeral: no cookies, no credentials, no cache — a one-off fetch of images
            // referenced by an imported file, not a browsing session.
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
    }

    /// Downloads every URL in `imageURLs` into `directory`, skipping exact duplicates.
    ///
    /// Refuses any URL whose scheme isn't `http`/`https`, or whose host is a literal
    /// loopback/private/link-local address or `localhost`. A WXR file is a local, owner-picked
    /// artifact rather than something crawled from an untrusted remote site, but a tampered one
    /// could still reference an internal address to probe the machine's own network — and unlike
    /// the (not yet built) live-crawl rungs, there's no earlier network-gating step here to have
    /// already caught that. This is a narrower check than the crawl-stage design's planned
    /// DNS-resolution-based guard (`scripts/embeds/net-guard.ts`'s Swift port) — it only rejects
    /// the address appearing as a literal IP in the URL itself, not a hostname that *resolves* to
    /// one — which is why it belongs here rather than claiming to replace that guard.
    ///
    /// - Parameters:
    ///   - imageURLs: The image URLs to fetch, in any order; duplicates are downloaded once.
    ///   - directory: Where to write each successfully downloaded file — created if missing.
    /// - Returns: One ``CapturedAsset`` per successful download (`relativePath` is relative to
    ///   `directory`), and one ``ImportProblem`` per URL that was refused or failed to download.
    public func download(imageURLs: [String], into directory: URL) async
        -> (assets: [CapturedAsset], problems: [ImportProblem]) {
        var assets: [CapturedAsset] = []
        var problems: [ImportProblem] = []
        var seen: Set<String> = []
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (index, url) in imageURLs.enumerated() {
            guard seen.insert(url).inserted else { continue }

            guard let parsed = URL(string: url), Self.isSafe(parsed) else {
                problems.append(ImportProblem(sourceURL: url,
                                              message: "Image URL was refused (unsafe scheme or address)"))
                continue
            }

            do {
                let (data, response) = try await session.data(for: URLRequest(url: parsed))
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    problems.append(ImportProblem(sourceURL: url, message: "Image download failed"))
                    continue
                }
                let relativePath = "image-\(index).bin"
                try data.write(to: directory.appendingPathComponent(relativePath))
                assets.append(CapturedAsset(sourceURL: url, relativePath: relativePath))
            } catch {
                problems.append(ImportProblem(sourceURL: url,
                                              message: "Image download failed: \(error.localizedDescription)"))
            }
        }

        return (assets, problems)
    }

    /// `true` when `url` is safe to fetch: `http`/`https` scheme, and a host that isn't
    /// `localhost` or a literal loopback/private/link-local IPv4 or IPv6 address.
    static func isSafe(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return !isPrivateOrLoopbackLiteral(host)
    }

    private static func isPrivateOrLoopbackLiteral(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" { return true }

        let octets = lowered.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            if octets[0] == 127 { return true }                            // 127.0.0.0/8 loopback
            if octets[0] == 10 { return true }                             // 10.0.0.0/8
            if octets[0] == 192 && octets[1] == 168 { return true }        // 192.168.0.0/16
            if octets[0] == 172 && (16...31).contains(octets[1]) { return true } // 172.16.0.0/12
            if octets[0] == 169 && octets[1] == 254 { return true }        // 169.254.0.0/16 link-local
            if octets[0] == 0 { return true }                              // 0.0.0.0/8
            return false
        }

        if lowered == "::1" { return true }                                // IPv6 loopback
        if lowered.hasPrefix("fe80:") { return true }                      // IPv6 link-local
        if lowered.hasPrefix("fc") || lowered.hasPrefix("fd") { return true } // IPv6 unique local
        return false
    }
}

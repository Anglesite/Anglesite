import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// (AnglesiteCore is in the Linux portable target set).
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a metadata fetch failed — surfaced as a quiet inline note in the compose sheet, never a
/// blocking error (spec §6: capture always proceeds with the bare URL).
public struct LinkMetadataFetchError: Error, Sendable, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Fetches a web page and scrapes ``LinkMetadata`` out of its head via ``LinkMetadataParser``.
/// Host-side URLSession (the app sandbox already holds `com.apple.security.network.client`) so
/// capture works with no site runtime running — the launcher flow's requirement (spec §3.1).
/// Stateless, so a `Sendable` struct; `session` is injectable for `URLProtocol`-stubbed tests.
public struct LinkMetadataFetcher: Sendable {
    /// Read cap: link metadata lives in the document head; bounding what we hand the parser
    /// keeps memory flat on hostile or enormous pages.
    public static let maximumBodyBytes = 2 * 1024 * 1024

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            // Ephemeral: no cookies, no credentials, no cache — this is a metadata peek at an
            // arbitrary URL, not a browsing session.
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: config)
        }
    }

    public func fetch(url: URL) async throws -> LinkMetadata {
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LinkMetadataFetchError(reason: "Not an HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw LinkMetadataFetchError(reason: "The page responded with HTTP \(http.statusCode)")
        }
        if let mime = http.mimeType, !mime.localizedCaseInsensitiveContains("html") {
            throw LinkMetadataFetchError(reason: "That link isn't a web page (\(mime))")
        }
        let html = Self.decode(data.prefix(Self.maximumBodyBytes), textEncodingName: http.textEncodingName)
        return LinkMetadataParser.parse(html: html)
    }

    /// Decode using the response's declared charset when it names one, else UTF-8, else lossy
    /// UTF-8 — a wrong-charset decode still yields scannable ASCII `<meta>` markup.
    static func decode(_ data: Data, textEncodingName: String?) -> String {
        // The IANA charset-name lookup is CoreFoundation, Darwin-only (this repo treats CF as
        // non-portable throughout). Off-Darwin the UTF-8 fallback below still yields scannable
        // ASCII `<meta>` markup for any ASCII-compatible page encoding.
        #if canImport(Darwin)
        if let name = textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let decoded = String(data: data, encoding: encoding) { return decoded }
            }
        }
        #endif
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

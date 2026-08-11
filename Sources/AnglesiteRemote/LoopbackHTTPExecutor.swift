import Foundation
import os.log
import AnglesiteP2P

/// Replays a bridged HTTP request against a real base URL (the container's `previewURL`) via
/// `URLSession`. The production `HTTPExecutor` for P1+ — `DirectoryHTTPExecutor` (P0) stays
/// test-only infra.
public struct LoopbackHTTPExecutor: HTTPExecutor {
    private static let logger = os.Logger(subsystem: "io.dwk.anglesite.remote", category: "LoopbackHTTPExecutor")

    private let baseURL: URL
    private let urlSession: URLSession

    /// - Parameters:
    ///   - baseURL: The container's loopback preview endpoint (`LocalContainerSession.previewURL`).
    ///   - urlSession: Injectable for tests.
    public init(baseURL: URL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    /// Executes an HTTP request against a real server via URLSession, forwarding the full request
    /// (method, headers, body) and returning the response head and streamed body. Unlike P0's
    /// `DirectoryHTTPExecutor` (filesystem-backed), this conformer uses a live URLSession for
    /// production container preview serving.
    public func execute(_ request: BridgeRequestHead, body: Data?) async throws
        -> (head: BridgeResponseHead, body: AsyncThrowingStream<Data, Error>) {
        // `request.path` is peer-supplied and unvalidated at every layer above this (decoded
        // straight off the wire in `AnglesiteP2P/P2PFraming`, passed through untouched by
        // `FetchBridge`). `URL(string:relativeTo:)` below performs full RFC 3986 reference
        // resolution, which — unlike the plain string splice this comment used to describe —
        // also honors network-path references (`//evil.example/x`, host becomes `evil.example`)
        // and absolute references (`http://evil.example/x`, `baseURL` ignored entirely). Left
        // unchecked, a peer can redirect this host-side helper's request to an arbitrary
        // scheme/host/port (SSRF into localhost services and the LAN) with attacker-chosen
        // method/headers/body, and get the response back over the bridge. A legitimate
        // same-origin request target is always a plain absolute-path reference: a single leading
        // `/` and nothing that could be mistaken for a scheme or authority.
        guard request.path.hasPrefix("/"), !request.path.hasPrefix("//") else {
            Self.report("rejected unsafe bridged request path \(request.path)")
            throw URLError(.badURL)
        }

        // `request.path` arrives ALREADY percent-encoded — it's the raw request target off the
        // wire, the same contract P0's `DirectoryHTTPExecutor` relies on when it calls
        // `removingPercentEncoding` on this field. So it must be spliced onto `baseURL` verbatim:
        // routing it through `appendingPathComponent`/`URLComponents.query` re-encodes the `%`
        // itself, turning `/img/My%20Photo.jpg` into a request for `/img/My%2520Photo.jpg` and
        // 404ing every filename with a space or non-ASCII character. `URL(string:relativeTo:)`
        // does RFC 3986 reference resolution without re-encoding what's already encoded — and,
        // unlike `URLComponents.percentEncodedPath`, returns `nil` on a malformed target instead
        // of trapping, so a bad request from the peer can't take the helper down. The leading-`/`
        // guard above ensures this resolution can only ever stay within `baseURL`'s origin.
        guard let url = URL(string: request.path, relativeTo: baseURL)?.absoluteURL else {
            Self.report("unroutable bridged request path \(request.path)")
            throw URLError(.badURL)
        }

        // Create the URLRequest.
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method

        // Copy all headers verbatim.
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // Set the request body if provided. A plain `Data` body rather than an `InputStream`:
        // `URLProtocol` converts it to a stream on its own anyway, and `Data` is replayable
        // (a consumed stream is not) should URLSession ever retry the request.
        if let body {
            urlRequest.httpBody = body
        }

        // Execute the request.
        let responseData: Data
        let urlResponse: URLResponse
        do {
            (responseData, urlResponse) = try await urlSession.data(for: urlRequest)
        } catch {
            // `String(describing:)`, not `localizedDescription`: the latter flattens a plain Swift
            // error enum into an opaque "error 1", and even a `URLError` reads better raw here.
            Self.report("\(request.method) \(request.path) failed: \(String(describing: error))")
            throw error
        }

        // Extract the HTTP response.
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            Self.report("\(request.method) \(request.path): non-HTTP response")
            throw URLError(.badServerResponse)
        }

        // Build the response head.
        let responseHead = BridgeResponseHead(
            status: httpResponse.statusCode,
            headers: flattenHeaders(httpResponse.allHeaderFields)
        )

        // Return the response head and body as a single-element stream.
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(responseData)
            continuation.finish()
        }

        return (head: responseHead, body: stream)
    }

    /// Reports a bridge-level failure to **both** the system log and this process's stderr.
    /// Logs are sacred (CLAUDE.md): `os.Logger` alone never reaches the helper's stderr
    /// transcript, which is what `ProcessOutputCapture`, the E2E suite, and an operator
    /// debugging a live session actually read.
    private static func report(_ message: String) {
        logger.error("LoopbackHTTPExecutor: \(message, privacy: .public)")
        FileHandle.standardError.write(Data("LoopbackHTTPExecutor: \(message)\n".utf8))
    }

    /// Flattens HTTPURLResponse.allHeaderFields (which may have NSString keys) to [String: String].
    private func flattenHeaders(_ allHeaderFields: [AnyHashable: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in allHeaderFields {
            if let keyStr = key as? String, let valueStr = value as? String {
                result[keyStr] = valueStr
            }
        }
        return result
    }
}

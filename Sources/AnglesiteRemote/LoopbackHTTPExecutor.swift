import Foundation
import AnglesiteP2P

/// Replays a bridged HTTP request against a real base URL (the container's `previewURL`) via
/// `URLSession`. The production `HTTPExecutor` for P1+ — `DirectoryHTTPExecutor` (P0) stays
/// test-only infra.
public struct LoopbackHTTPExecutor: HTTPExecutor {
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
        // Parse the path to separate path and query string.
        let (path, query) = parsePath(request.path)

        // Build the full URL from baseURL + path + query.
        var urlComponents = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)
        if let query, !query.isEmpty {
            urlComponents?.query = query
        }

        guard let url = urlComponents?.url else {
            throw URLError(.badURL)
        }

        // Create the URLRequest.
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method

        // Copy all headers verbatim.
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // Set the request body if provided.
        if let body {
            urlRequest.httpBodyStream = InputStream(data: body)
        }

        // Execute the request.
        let (responseData, urlResponse) = try await urlSession.data(for: urlRequest)

        // Extract the HTTP response.
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
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

    /// Parses the path to separate the path component from the query string.
    /// For example, "/blog/?draft=1" becomes ("/blog/", "draft=1").
    private func parsePath(_ path: String) -> (path: String, query: String?) {
        if let questionMarkIndex = path.firstIndex(of: "?") {
            let pathPart = String(path[..<questionMarkIndex])
            let queryPart = String(path[path.index(after: questionMarkIndex)...])
            return (pathPart, queryPart)
        }
        return (path, nil)
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

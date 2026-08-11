import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `MCPTransport` over MCP Streamable HTTP (2026-07-28, stateless). Each `send` POSTs one
/// self-contained JSON-RPC message to the `/mcp` endpoint; the response (single
/// `application/json` object, or one-or-more messages over a request-scoped `text/event-stream`)
/// is decoded and funneled into `inbound()`. There is no session: no `Mcp-Session-Id` is ever
/// sent or stored. Each POST carries the `Mcp-Method` (and, for named calls, `Mcp-Name`) headers
/// the spec requires so gateways can route without reading the body.
public actor HTTPTransport: MCPTransport {
    /// Transport-level failures. Distinguishes "the server is unreachable/not serving" (retryable
    /// once the runtime is back — e.g. a container mid-restart) from plain HTTP rejections.
    public enum HTTPError: Error, Sendable, Equatable {
        /// The server answered with a status other than 200/202/404.
        case http(status: Int)
        /// A 400 whose JSON-RPC error body reads as a pre-2026-07-28 (sessionful) MCP server
        /// rejecting a client that never sends `initialize` — see `staleSidecarDetail(in:)`.
        /// The stateless protocol this client speaks has no concept of sessions or `initialize`,
        /// so a rejection naming either almost certainly means the sidecar the container is
        /// running predates v1.9.0 (#1277) rather than a genuine protocol violation. Distinguished
        /// from the generic `.http(status: 400)` so `MCPClient` can log an actionable diagnostic
        /// instead of a bare status code — `scripts/lib/stage-dev-image-context.sh` refuses to
        /// stage a too-old sidecar into a *new* image build, but this is the safety net for an
        /// image that was already vendored before that guard existed.
        case staleSidecarProtocol(detail: String)
        /// The connection failed or the server returned 404 — the endpoint isn't serving (the
        /// case name predates the stateless protocol, which has no sessions; it now just means
        /// "server unavailable, retry once the runtime is back up").
        case sessionLost
        /// The response wasn't an HTTP response at all.
        case badResponse
    }

    private let endpoint: URL
    private let protocolVersion: String
    private let urlSession: URLSession
    private let bearerToken: SessionToken?

    private let stream: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation

    /// Creates a transport for one `/mcp` endpoint. `bearerToken` is sent as an `Authorization`
    /// header on every request — the remote-sandbox path requires it, the local container path
    /// doesn't. `protocolVersion` is replayed verbatim in the `MCP-Protocol-Version` header;
    /// `urlSession` is injectable for tests.
    public init(
        endpoint: URL,
        bearerToken: SessionToken? = nil,
        protocolVersion: String = MCPClient.protocolVersion,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.protocolVersion = protocolVersion
        self.urlSession = urlSession
        (self.stream, self.continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .unbounded)
    }

    /// No-op: Streamable HTTP has no persistent connection to establish — the first `send` does
    /// the work. Exists only to satisfy `MCPTransport`.
    public func open() async throws { /* no persistent connection; first send does the work */ }

    /// POSTs one JSON-RPC message and funnels the decoded response into ``inbound()`` rather than
    /// returning it — matching `MCPTransport`'s stream shape, so `MCPClient`'s request/response
    /// correlation works identically over stdio and HTTP. SSE responses are read incrementally and
    /// only until the first complete event (see the buffering note in the body); a 202 means a
    /// notification was accepted and yields nothing.
    ///
    /// - Throws: ``HTTPError/sessionLost`` on connection failure or 404 (session id cleared),
    ///   ``HTTPError/http(status:)`` for other non-success statuses, ``HTTPError/badResponse``
    ///   for a non-HTTP response.
    public func send(_ message: JSONValue) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        // 2026-07-28: the RPC method (and, for named calls like tools/call, the target name)
        // ride as headers so gateways/rate-limiters can decide without parsing the body.
        if case .object(let obj) = message, case .string(let method)? = obj["method"] {
            request.setValue(method, forHTTPHeaderField: "Mcp-Method")
            if case .object(let params)? = obj["params"], case .string(let name)? = params["name"] {
                request.setValue(name, forHTTPHeaderField: "Mcp-Name")
            }
        }
        if let bearerToken { request.setValue("Bearer \(bearerToken.value)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message.rawValue, options: [])

        // Must not fully buffer a `text/event-stream` response: URLSession treats it as an
        // indefinite stream on a keep-alive connection, so reading the whole body (`data(for:)`)
        // never completes (it waits for the socket to close, which doesn't happen) — it hangs.
        // Both platform paths below read incrementally and return after the first complete SSE
        // event (the response to this request) without waiting for the stream to end.
        #if canImport(Darwin)
        // `bytes(for:)` gives an incremental AsyncSequence of the response body.
        let asyncBytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (asyncBytes, response) = try await urlSession.bytes(for: request)
        } catch {
            throw HTTPError.sessionLost
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }
        #else
        // `FoundationNetworking` has no `bytes(for:)`/`AsyncBytes`; ``HTTPStreamingRunner``
        // gets the same incremental behavior via `URLSessionDataDelegate`.
        let runner = HTTPStreamingRunner()
        let response: URLResponse
        do {
            response = try await runner.start(request, configuration: urlSession.configuration)
        } catch {
            throw HTTPError.sessionLost
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }
        #endif

        switch http.statusCode {
        case 202:
            return  // notification accepted; no response body
        case 404:
            throw HTTPError.sessionLost
        case 200:
            break
        case 400:
            var body = Data()
            #if canImport(Darwin)
            for try await byte in asyncBytes { body.append(byte) }
            #else
            for try await chunk in runner.bodyStream { body.append(chunk) }
            #endif
            if let detail = Self.staleSidecarDetail(in: body) {
                throw HTTPError.staleSidecarProtocol(detail: detail)
            }
            throw HTTPError.http(status: 400)
        default:
            throw HTTPError.http(status: http.statusCode)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            // Parse SSE line-by-line; emit the first complete event's data payload and return.
            // (One POSTed request yields exactly one response message on its request-scoped stream.)
            var dataLines: [String] = []
            #if canImport(Darwin)
            for try await line in asyncBytes.lines {
                if case .complete(let value) = accumulateSSELine(line, into: &dataLines) {
                    if let value { continuation.yield(value) }
                    return
                }
            }
            #else
            for try await line in runner.lines() {
                if case .complete(let value) = accumulateSSELine(line, into: &dataLines) {
                    if let value { continuation.yield(value) }
                    return
                }
            }
            #endif
            // Stream ended without a trailing blank line — flush whatever accumulated.
            if !dataLines.isEmpty, let value = decode(dataLines.joined(separator: "\n")) {
                continuation.yield(value)
            }
        } else {
            // application/json (or other): accumulate the bounded body and decode one message.
            var data = Data()
            #if canImport(Darwin)
            for try await byte in asyncBytes { data.append(byte) }
            #else
            for try await chunk in runner.bodyStream { data.append(chunk) }
            #endif
            if !data.isEmpty, let value = decodeData(data) { continuation.yield(value) }
        }
    }

    /// One line of SSE parsing shared by both platform read loops: accumulates `data:` payload
    /// lines, and on a blank line (event terminator) reports the decoded event so the caller can
    /// yield it and stop reading (one POSTed request yields exactly one response message).
    /// `event:`/`id:`/`retry:`/comment lines are ignored.
    private enum SSELineResult {
        case continueReading
        case complete(JSONValue?)
    }

    private func accumulateSSELine(_ line: String, into dataLines: inout [String]) -> SSELineResult {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return .continueReading }
            return .complete(decode(dataLines.joined(separator: "\n")))
        }
        if line.hasPrefix("data:") {
            let v = line.dropFirst("data:".count)
            dataLines.append(v.hasPrefix(" ") ? String(v.dropFirst()) : String(v))
        }
        return .continueReading
    }

    /// The single stream of decoded server messages, fed by ``send(_:)``. `nonisolated` (the
    /// stream and continuation are `let`s created at init) so the consumer can subscribe before
    /// the first request without an actor hop.
    public nonisolated func inbound() -> AsyncStream<JSONValue> { stream }

    /// Finishes ``inbound()``. Stateless: there is no session to tear down server-side.
    public func close() async {
        continuation.finish()
    }

    private func decode(_ payload: String) -> JSONValue? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return decodeData(data)
    }

    private func decodeData(_ data: Data) -> JSONValue? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return JSONValue.from(raw)
    }

    /// Heuristic for distinguishing a stale-sidecar 400 from a genuine one. This client's
    /// stateless protocol never sends `initialize` and has no session concept, so it cannot
    /// itself trigger a rejection that talks about either — a JSON-RPC error message mentioning
    /// "session"/"initialize" on a 400 is a reliable (version-independent) signal that the
    /// server on the other end is still running the old sessionful transport, without needing to
    /// match its exact wording (which varies across SDK versions). Returns the extracted message
    /// when the heuristic matches, `nil` otherwise — callers fall back to plain `.http(status:)`.
    private static func staleSidecarDetail(in body: Data) -> String? {
        guard let raw = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = raw["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return nil }
        let lowered = message.lowercased()
        guard lowered.contains("session") || lowered.contains("initializ") else { return nil }
        return message
    }
}

import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `MCPTransport` over the *standard* MCP Streamable HTTP handshake (sessionful): the
/// `initialize` response's `Mcp-Session-Id` header is captured and replayed on every later
/// request. This is the dialect real MCP HTTP servers speak (e.g. `mcp-proxy`, and through it
/// `safaridriver --mcp`) — a sibling of ``HTTPTransport``'s bespoke *stateless* dialect built for
/// this app's own container sidecar, not a replacement for it. See
/// docs/superpowers/specs/2026-09-04-safari-mcp-transport-spike.md.
///
/// Unlike ``HTTPTransport``, this transport never sends an `MCP-Protocol-Version` header — the
/// spike found that header triggers a 400 ("modern header ... legacy handshake") against
/// `mcp-proxy`'s tested dialect; the negotiated version instead comes back in the `initialize`
/// response body, which ``SafariMCPBridgeClient`` reads itself.
public actor SessionfulHTTPTransport: MCPTransport {
    /// Transport-level failures.
    public enum HTTPError: Error, Sendable, Equatable {
        /// The server answered with a status other than 200/202/404.
        case http(status: Int)
        /// The connection failed, or the server returned 404 (no such endpoint/session).
        case connectionFailed
        /// The response wasn't an HTTP response at all.
        case badResponse
    }

    private let endpoint: URL
    private let urlSession: URLSession
    private var sessionID: String?

    private let stream: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation

    /// Creates a transport for one sessionful `/mcp` endpoint. `urlSession` is injectable for tests.
    public init(endpoint: URL, urlSession: URLSession = .shared) {
        self.endpoint = endpoint
        self.urlSession = urlSession
        (self.stream, self.continuation) = AsyncStream<JSONValue>.makeStream(bufferingPolicy: .unbounded)
    }

    /// No-op: like `HTTPTransport`, Streamable HTTP has no persistent connection to establish —
    /// the first `send` does the work.
    public func open() async throws { /* no persistent connection; first send does the work */ }

    /// POSTs one JSON-RPC message. Captures a fresh `Mcp-Session-Id` from the response whenever
    /// the server sends one (in practice, only the `initialize` response does) and replays
    /// whatever session id is currently held on every request thereafter. Mirrors
    /// `HTTPTransport.send(_:)`'s incremental-read/SSE-parsing approach — see that type's doc
    /// comment for why a `text/event-stream` response must not be fully buffered.
    public func send(_ message: JSONValue) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message.rawValue, options: [])

        #if canImport(Darwin)
        let asyncBytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (asyncBytes, response) = try await urlSession.bytes(for: request)
        } catch {
            throw HTTPError.connectionFailed
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }
        #else
        let runner = HTTPStreamingRunner()
        let response: URLResponse
        do {
            response = try await runner.start(request, configuration: urlSession.configuration)
        } catch {
            throw HTTPError.connectionFailed
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }
        #endif

        if let newSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = newSessionID
        }

        switch http.statusCode {
        case 202:
            return  // notification accepted; no response body
        case 404:
            throw HTTPError.connectionFailed
        case 200:
            break
        default:
            throw HTTPError.http(status: http.statusCode)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
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
            if !dataLines.isEmpty, let value = decode(dataLines.joined(separator: "\n")) {
                continuation.yield(value)
            }
        } else {
            var data = Data()
            #if canImport(Darwin)
            for try await byte in asyncBytes { data.append(byte) }
            #else
            for try await chunk in runner.bodyStream { data.append(chunk) }
            #endif
            if !data.isEmpty, let value = decodeData(data) { continuation.yield(value) }
        }
    }

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

    /// The single stream of decoded server messages, fed by ``send(_:)``.
    public nonisolated func inbound() -> AsyncStream<JSONValue> { stream }

    /// Finishes ``inbound()``. No explicit session-termination `DELETE` is sent — the bridge
    /// process is short-lived and user-owned; adding one is tracked as a possible follow-up, not
    /// required by #1910's acceptance criteria.
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
}

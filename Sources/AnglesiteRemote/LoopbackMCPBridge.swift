import Foundation
import OSLog
import AnglesiteCore

/// Wraps a raw `HTTPTransport` pointed at the container's MCP endpoint and exposes it as an
/// `MCPChannelResponder.Handler` — a blind, faithful passthrough (not `MCPClient`'s structured
/// call API, which parses specific methods; this bridge must forward *any* JSON-RPC message the
/// phone sends, unmodified). Safe because `MCPChannelResponder.run()` processes inbound `mcp`
/// frames one at a time (single sequential `for await` loop, no concurrent child tasks) — so
/// exactly one request is ever in flight through this bridge's `HTTPTransport`, and "send, then
/// read the next inbound value" is safe without id-correlation of its own.
///
/// That same sequential loop is why every failure path here has to produce a *reply*: a `nil`
/// return means "notification, no reply" to `MCPChannelResponder`, so returning `nil` for a
/// genuine failure would leave the phone-side caller waiting on that request id forever, and the
/// responder's strictly-sequential loop would never reach the next frame. Requests therefore
/// always come back with either the server's response or a synthesized JSON-RPC error carrying
/// the original id.
public actor LoopbackMCPBridge {
    private static let logger = Logger(subsystem: "io.dwk.anglesite", category: "LoopbackMCPBridge")

    /// JSON-RPC error code used for every bridge-level failure (send failed, no response,
    /// response timed out). -32000 is the first code in JSON-RPC 2.0's reserved
    /// implementation-defined server-error range, which is what a transport-level fault is.
    private static let bridgeErrorCode = -32000

    /// How long to wait for the transport to surface a response after a successful `send`.
    ///
    /// A handful of seconds is generous: `HTTPTransport.send` does the entire HTTP round trip
    /// (itself bounded by `URLSession`'s own timeouts) and yields the decoded response into
    /// `inbound()` *before* it returns, so by the time this bridge reads the iterator the value is
    /// either already buffered or will never arrive at all. The bound exists purely for that
    /// second case — an empty or undecodable response body makes `send` yield nothing, and the
    /// unbounded read that used to follow it hung forever, wedging the whole `mcp` channel.
    public static let defaultResponseTimeout: Duration = .seconds(5)

    private let transport: HTTPTransport
    private let responseTimeout: Duration
    private nonisolated(unsafe) var inboundIterator: AsyncStream<JSONValue>.AsyncIterator

    /// - Parameters:
    ///   - mcpURL: The container's loopback MCP endpoint (`LocalContainerSession.mcpURL`).
    ///   - urlSession: Injectable for tests.
    ///   - responseTimeout: How long a request waits for its response before this bridge
    ///     synthesizes a JSON-RPC error. Injectable so tests can bound themselves tightly.
    public init(
        mcpURL: URL,
        urlSession: URLSession = .shared,
        responseTimeout: Duration = LoopbackMCPBridge.defaultResponseTimeout
    ) {
        self.transport = HTTPTransport(endpoint: mcpURL, urlSession: urlSession)
        self.responseTimeout = responseTimeout
        self.inboundIterator = transport.inbound().makeAsyncIterator()
    }

    /// Conforms to `MCPChannelResponder.Handler`'s shape; pass `bridge.handle` directly to
    /// `MCPChannelResponder.init(connection:handler:)`.
    ///
    /// - Parameter message: A JSON-RPC message (request, notification, or response).
    /// - Returns: `nil` only for notifications (no `"id"` key), which have no response by
    ///   definition. For requests: the server's response, or — if the send failed or no response
    ///   materialized within `responseTimeout` — a synthesized JSON-RPC error object carrying the
    ///   original request's id, so the caller fails fast instead of hanging.
    public func handle(_ message: JSONValue) async -> JSONValue? {
        // A notification is a message with no "id" key. Anything else is a request that owes the
        // caller exactly one reply, whatever happens below.
        let requestID: JSONValue?
        if case .object(let obj) = message {
            requestID = obj["id"]
        } else {
            requestID = nil
        }
        let isNotification = requestID == nil

        // Send the message via the transport.
        do {
            try await transport.send(message)
        } catch {
            // `String(describing:)`, not `localizedDescription`: the latter renders a plain Swift
            // error enum (e.g. `HTTPTransport.HTTPError.sessionLost`) as an opaque "error 1".
            let detail = "send failed: \(String(describing: error))"
            Self.report(detail)
            // A failed *notification* still has no reply to give; a failed request must not come
            // back as `nil`, which the responder would read as "notification, send nothing".
            return isNotification ? nil : Self.errorResponse(id: requestID, message: detail)
        }

        // For notifications, return nil immediately (no response expected).
        if isNotification {
            return nil
        }

        switch await readResponse() {
        case .value(let response):
            return response
        case .ended:
            let detail = "no response from transport"
            Self.report(detail)
            return Self.errorResponse(id: requestID, message: detail)
        case .timedOut:
            let detail = "timed out after \(responseTimeout) waiting for the container's MCP response"
            Self.report(detail)
            return Self.errorResponse(id: requestID, message: detail)
        }
    }

    private enum ReadOutcome: Sendable {
        case value(JSONValue)
        case ended
        case timedOut
    }

    /// Reads the next inbound value, bounded by `responseTimeout`.
    ///
    /// Losing the race cancels the read, which terminates `HTTPTransport.inbound()` — so once a
    /// request times out, every later one resolves as `.ended` and gets its own error reply.
    /// That is deliberate: after a lost response the stream's implicit request/response ordering
    /// can no longer be trusted, and answering later requests with an earlier one's response
    /// would be worse than failing them. Either way the phone gets an error per request instead
    /// of silence, and the responder's loop keeps draining frames.
    private func readResponse() async -> ReadOutcome {
        let timeout = responseTimeout
        return await withTaskGroup(of: ReadOutcome.self) { group in
            group.addTask { [self] in
                if let value = await self.nextInbound() { return .value(value) }
                return .ended
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .ended
            group.cancelAll()
            return first
        }
    }

    private func nextInbound() async -> JSONValue? {
        await inboundIterator.next()
    }

    /// Builds `{"jsonrpc": "2.0", "id": <original id>, "error": {"code": …, "message": …}}`.
    /// `id` is replayed verbatim (JSON-RPC allows string or number ids) so the caller's own
    /// correlation table finds it; `null` when the id was somehow absent, per the spec's rule for
    /// errors on unidentifiable requests.
    private static func errorResponse(id: JSONValue?, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id ?? .null,
            "error": .object([
                "code": .int(bridgeErrorCode),
                "message": .string(message),
            ]),
        ])
    }

    /// Reports a bridge-level failure to **both** the system log and this process's stderr.
    /// Logs are sacred (CLAUDE.md): `os.Logger` alone never reaches the helper's stderr
    /// transcript, which is what `ProcessOutputCapture`, the E2E suite, and an operator
    /// debugging a live session actually read.
    private static func report(_ message: String) {
        logger.error("LoopbackMCPBridge: \(message, privacy: .public)")
        FileHandle.standardError.write(Data("LoopbackMCPBridge: \(message)\n".utf8))
    }
}

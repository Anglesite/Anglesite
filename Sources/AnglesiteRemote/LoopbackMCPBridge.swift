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
public actor LoopbackMCPBridge {
    private static let logger = Logger(subsystem: "io.dwk.anglesite", category: "LoopbackMCPBridge")

    private let transport: HTTPTransport
    private nonisolated(unsafe) var inboundIterator: AsyncStream<JSONValue>.AsyncIterator

    /// - Parameter mcpURL: The container's loopback MCP endpoint (`LocalContainerSession.mcpURL`).
    public init(mcpURL: URL, urlSession: URLSession = .shared) {
        self.transport = HTTPTransport(endpoint: mcpURL, urlSession: urlSession)
        self.inboundIterator = transport.inbound().makeAsyncIterator()
    }

    /// Conforms to `MCPChannelResponder.Handler`'s shape; pass `bridge.handle` directly to
    /// `MCPChannelResponder.init(connection:handler:)`.
    ///
    /// - Parameter message: A JSON-RPC message (request, notification, or response).
    /// - Returns: The server's response for requests (non-nil), or `nil` for notifications
    ///   (no `"id"` key) which have no response by definition.
    public func handle(_ message: JSONValue) async -> JSONValue? {
        // Check if this is a notification (no "id" key)
        let isNotification: Bool
        if case .object(let obj) = message {
            isNotification = obj["id"] == nil
        } else {
            isNotification = false
        }

        // Send the message via the transport
        do {
            try await transport.send(message)
        } catch {
            Self.logger.error("LoopbackMCPBridge send failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // For notifications, return nil immediately (no response expected)
        if isNotification {
            return nil
        }

        // For requests, await the next inbound value from the transport
        guard let response = await inboundIterator.next() else {
            Self.logger.error("LoopbackMCPBridge: no response from transport iterator")
            return nil
        }

        return response
    }
}

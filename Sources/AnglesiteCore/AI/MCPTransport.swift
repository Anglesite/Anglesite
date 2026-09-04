import Foundation

/// A duplex channel for MCP JSON-RPC messages. `MCPClient` owns all id-correlation, timeout, and
/// ready-probe logic and delegates raw message send/receive to a transport. The shape mirrors stdio's
/// model — a write side plus one inbound stream of decoded messages — so HTTP and stdio share the
/// same client code path.
///
/// Conformers own mutable connection state, so each is an `actor`.
public protocol MCPTransport: Sendable {
    /// Establish the connection. After this returns, `inbound()` is live. Idempotent transports may
    /// no-op (HTTP has no persistent connection to open).
    func open() async throws
    /// Send one framed JSON-RPC message (request or notification).
    func send(_ message: JSONValue) async throws
    /// Inbound JSON-RPC messages: responses (correlated by id downstream) plus server notifications.
    /// Call once; returns the single backing stream.
    func inbound() -> AsyncStream<JSONValue>
    /// Tear down the connection and finish the inbound stream.
    func close() async
}

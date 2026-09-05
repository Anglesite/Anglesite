import Foundation

/// A duplex channel for ACP (Agent Client Protocol) JSON-RPC messages. Mirrors `MCPTransport`'s
/// shape exactly — `ACPClient` owns id-correlation, the handshake, and session/notification
/// routing, and delegates raw message send/receive to a transport, so an in-container stdio agent
/// and a remote HTTP agent share the same client code path.
public protocol ACPTransport: Sendable {
    func open() async throws
    func send(_ message: JSONValue) async throws
    func inbound() -> AsyncStream<JSONValue>
    func close() async
}

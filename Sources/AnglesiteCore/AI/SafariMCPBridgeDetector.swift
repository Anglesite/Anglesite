import Foundation
// URLSession lives in FoundationNetworking on non-Darwin platforms (swift-corelibs-foundation);
// this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The result of one reachability probe against a configured loopback port.
public struct SafariMCPBridgeStatus: Sendable, Equatable {
    /// Whether a Safari MCP bridge answered the handshake.
    public enum State: Sendable, Equatable {
        /// The port answered a real `initialize` handshake; carries the server's advertised name
        /// (e.g. "Safari") for display.
        case reachable(serverName: String)
        /// No bridge answered — absent, still starting, or a bridge speaking a different dialect.
        case unreachable
    }
    public let state: State
    public let port: Int
}

/// Detects whether a Safari MCP bridge (a user-launched `mcp-proxy`-style stdio→HTTP bridge
/// wrapping `safaridriver --mcp`, per
/// docs/superpowers/specs/2026-09-04-safari-mcp-transport-spike.md) is reachable at a loopback
/// port — by attempting the real sessionful handshake, never by checking for a `safaridriver`
/// process or binary path: the app has no visibility into what the user has running beyond the
/// socket, and never spawns the bridge itself (owner's 2026-09-04 sandboxing decision).
public actor SafariMCPBridgeDetector {
    /// The port Settings suggests in its example bridge command, and probes when the user hasn't
    /// configured one — arbitrary, but matches the transport spike's own worked example.
    public static let defaultPort = 8931

    private let urlSession: URLSession
    private let logCenter: LogCenter

    public init(urlSession: URLSession = .shared, logCenter: LogCenter = .shared) {
        self.urlSession = urlSession
        self.logCenter = logCenter
    }

    /// Attempts the sessionful `initialize` handshake against `http://127.0.0.1:<port>/mcp` and
    /// reports whether it succeeded. Always tears the client down before returning; a failure of
    /// any kind (connection refused, timeout, malformed handshake) reports `.unreachable` rather
    /// than throwing — this is a status check, not an operation that can fail the caller.
    public func checkReachability(
        port: Int,
        timeout: TimeInterval = NetworkTimeouts.safariMCPBridgeProbe
    ) async -> SafariMCPBridgeStatus {
        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            return SafariMCPBridgeStatus(state: .unreachable, port: port)
        }
        let client = SafariMCPBridgeClient(endpoint: url, urlSession: urlSession, logCenter: logCenter)
        do {
            let info = try await client.connect(timeout: timeout)
            await client.close()
            return SafariMCPBridgeStatus(state: .reachable(serverName: info.name), port: port)
        } catch {
            await client.close()
            return SafariMCPBridgeStatus(state: .unreachable, port: port)
        }
    }
}

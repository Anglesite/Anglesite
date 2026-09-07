import Testing
import Foundation
import Darwin
@testable import AnglesiteCore
import AnglesiteTestSupport

/// Live round-trip against a real `mcp-proxy`-wrapped `safaridriver --mcp` session, mirroring the
/// curl transcripts in docs/superpowers/specs/2026-09-04-safari-mcp-transport-spike.md. Opt-in
/// only (`ANGLESITE_SAFARI_MCP_E2E=1`): requires Safari Technology Preview's remote-automation
/// toggle already granted, `safaridriver` on PATH, and network access for `npx` to fetch
/// `mcp-proxy` — none of which hold in CI or most sandboxes. Skips cleanly otherwise.
@Suite(.serialized)
struct SafariMCPBridgeE2ETests {
    @Test(
        "initialize -> tools/list round-trips against a live bridge",
        .enabled(
            if: SafariMCPBridgeE2EPrerequisites.met,
            "requires ANGLESITE_SAFARI_MCP_E2E=1, safaridriver on PATH, and network access for npx to fetch mcp-proxy"
        )
    )
    func liveRoundTrip() async throws {
        let port = try Self.freePort()
        let supervisor = ProcessSupervisor()
        let logCenter = LogCenter()
        let handle = try await supervisor.launch(
            source: "safari-mcp-e2e",
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["npx", "-y", "mcp-proxy", "--port", String(port), "--host", "127.0.0.1", "--", "safaridriver", "--mcp"],
            environment: [:],
            currentDirectoryURL: nil,
            restartPolicy: .never,
            attachStdin: false,
            onRespawn: nil,
            logCenter: logCenter
        )
        defer { Task { await supervisor.terminate(handle, timeout: 2) } }

        let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        var connectedInfo: SafariMCPBridgeClient.ServerInfo?
        var client: SafariMCPBridgeClient?

        // mcp-proxy fetched fresh via `npx -y` can take a while to install on first run, so the
        // budget here is generous like the sibling plugin e2e test's own 60s readyBudget.
        let readyBudget: TimeInterval = 60
        try await E2EServer.awaitReady(handle: handle, supervisor: supervisor, logCenter: logCenter, timeout: readyBudget) {
            let deadline = Date().addingTimeInterval(readyBudget - 5)
            while true {
                let c = SafariMCPBridgeClient(endpoint: endpoint)
                do {
                    connectedInfo = try await c.connect(timeout: 2)
                    client = c
                    return
                } catch {
                    await c.close()
                    guard Date() < deadline else { throw error }
                    try await Task.sleep(nanoseconds: 500_000_000)  // sleep-is-subject: real E2E/subprocess retry backoff
                }
            }
        }
        defer { Task { await client?.close() } }

        let info = try #require(connectedInfo)
        #expect(info.name.lowercased().contains("safari"))
        let tools = try await #require(client).listTools()
        #expect(!tools.isEmpty)
    }

    // NB: do not interpolate `errno` into these messages — see the identical note in
    // `MCPClientHTTPEndToEndTests.freePort()` (macOS-27-SDK-only symbol, absent on the macOS-15 CI
    // runner, breaks `dlopen`). Moot in practice here since this whole suite is gated off CI, but
    // kept consistent with that file's convention.
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FreePortError("socket() failed") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { throw FreePortError("bind() failed") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

/// A genuine failure while reserving a loopback port — distinct from a missing-prerequisite skip.
private struct FreePortError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Gate for `SafariMCPBridgeE2ETests`: opt-in env var plus `safaridriver` actually present.
/// Deliberately does NOT check for `npx`/Node — `npx -y` fetching `mcp-proxy` over the network is
/// itself part of what this test needs to succeed, so a missing `npx` should surface as this
/// test's own failure (a clear "command not found" from the spawned process), not a silent skip.
enum SafariMCPBridgeE2EPrerequisites {
    static var met: Bool {
        ProcessInfo.processInfo.environment["ANGLESITE_SAFARI_MCP_E2E"] == "1"
            && FileManager.default.isExecutableFile(atPath: "/usr/bin/safaridriver")
    }
}

import Testing
import Foundation
import Darwin
@testable import AnglesiteCore
import AnglesiteTestSupport

/// End-to-end: spawn the real plugin MCP server in HTTP mode on a free port, then drive the real
/// `MCPClient.connect(httpEndpoint:)` against it. Asserts `tools/list` includes `list_annotations`
/// and that calling it on an empty project returns `[]`.
///
/// Skipped (via the `.enabled(if:)` trait) when the sibling plugin checkout / its node_modules /
/// Node aren't present. Resolve the plugin via `ANGLESITE_PLUGIN_PATH` (default `../anglesite`);
/// resolve Node via `NODE_BINARY`, common paths, or `~/.nvm/versions/node/*/bin/node`.
@Suite(.serialized)  // serial subprocess spawns — see MCPClientTests rationale (CI-flakiness fix)
struct MCPClientHTTPEndToEndTests {
    @Test(
        "HTTP end-to-end: connect, list tools, call list_annotations",
        .enabled(
            if: E2EPrerequisites.prerequisitesMet,
            "requires the sibling Anglesite plugin checkout with a complete install (ANGLESITE_PLUGIN_PATH, or ../anglesite — run `npm install` in the plugin so sharp is present) and a Node ≥22 binary"
        )
    )
    func httpEndToEnd() async throws {
        let pluginRoot = try #require(E2EPrerequisites.locateSiblingPlugin())
        let node = try #require(E2EPrerequisites.locateNode())
        let serverPath = pluginRoot.appendingPathComponent("server/index.mjs")
        let port = try Self.freePort()

        let projectRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp-http-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        let supervisor = ProcessSupervisor()
        let logCenter = LogCenter()
        let handle = try await supervisor.launch(
            source: "mcp-http-e2e",
            executable: node,
            arguments: [serverPath.path],
            environment: [
                "ANGLESITE_MCP_TRANSPORT": "http",
                "ANGLESITE_MCP_HOST": "127.0.0.1",
                "ANGLESITE_MCP_PORT": String(port),
                "ANGLESITE_PROJECT_ROOT": projectRoot.path,
            ],
            currentDirectoryURL: nil,
            restartPolicy: .never,
            attachStdin: false,
            onRespawn: nil,
            logCenter: logCenter
        )
        defer { Task { await supervisor.terminate(handle, timeout: 2) } }

        let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let client = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())

        // Wait for the server to accept the MCP handshake, but abort the instant the spawned process
        // dies — `awaitReady` then throws with the server's stderr instead of letting this spin the
        // whole budget and report an opaque `.sessionLost`. A healthy cold start connects in well
        // under a second; the generous budget only covers a genuinely slow start.
        let readyBudget: TimeInterval = 60
        try await E2EServer.awaitReady(
            handle: handle,
            supervisor: supervisor,
            logCenter: logCenter,
            timeout: readyBudget
        ) {
            // Retry the handshake until it succeeds. The inner deadline (< the outer budget) surfaces
            // the real connect error if the server is up but never completes the handshake; a crashed
            // server is caught by `awaitReady`'s death detection, not this loop. Derived from the
            // outer budget so the two stay in sync if it's ever bumped.
            let deadline = Date().addingTimeInterval(readyBudget - 5)
            while true {
                do { try await client.connect(httpEndpoint: endpoint); return }
                catch {
                    guard Date() < deadline else { throw error }
                    try await Task.sleep(nanoseconds: 200_000_000) // sleep-is-subject: real E2E retry against a real subprocess server
                }
            }
        }
        defer { Task { await client.stop() } }

        let tools = try await client.listTools()
        #expect(tools.contains { $0.name == "list_annotations" })

        let result = try await client.callTool(name: "list_annotations", arguments: .object([:]))
        #expect(result.isError == false)
        #expect(result.content.first?.text == "[]")
    }

    // MARK: free-port probing
    // (plugin / Node prerequisites live in `E2EPrerequisites`, shared with AppliesEditEndToEndTests)

    // NB: do not interpolate `errno` into these messages. Reading `errno` links
    // `libswift_DarwinFoundation1.dylib` (the macOS-27 SDK vends it through that overlay), which
    // is absent on the macOS-15 CI runner — the whole test bundle then fails to `dlopen`. The bare
    // syscall name is enough; socket()/bind() failing here is vanishingly rare.
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
/// Surfaced through the test's `throws` channel so Swift Testing records it as an issue.
private struct FreePortError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

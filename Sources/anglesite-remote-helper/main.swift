import Foundation
import AnglesiteCore
import AnglesiteContainer
import AnglesiteP2P
import AnglesiteRemote
#if canImport(ServiceManagement)
import ServiceManagement
#endif

// Anywhere runtime (#1208 P1) helper entry point: `anglesite-remote-helper session <signal-dir>
// <site-root>` accepts one P2P session over file signaling (matching P0's `anglesite-p2p-demo
// host` invocation shape), boots/reuses the site's container, and bridges the fetch, MCP, and
// control-heartbeat channels until the connection closes or the process receives SIGTERM.
//
// Site discovery is deliberately out of scope here: P1 does not solve cross-sandbox site
// discovery (see the plan's Global Constraint), so this entry point takes the site's `Source/`
// directory directly as a CLI argument, matching how P0's own `anglesite-p2p-demo` took
// `<site-root>` as an argument rather than solving discovery. `RemoteSiteResolver` (Task 6) is
// for the real production flow — resolving a siteID sent over CloudKit signaling — and is not
// wired in here.

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

#if canImport(ServiceManagement)
try? SMAppServiceLoginItem().register()
#endif

let args = CommandLine.arguments
guard args.count == 4, args[1] == "session" else {
    die("usage: anglesite-remote-helper session <signal-dir> <site-root>")
}
let signalDir = URL(fileURLWithPath: args[2], isDirectory: true)
let siteRoot = URL(fileURLWithPath: args[3], isDirectory: true)
let siteID = siteRoot.lastPathComponent

// Production wiring of RemoteSessionRegistry at a *shared* (App Group) location is blocked on an
// owner-side provisioning-portal change (see the plan's Task 2/5 manual note); until then this
// falls back to a helper-local temp directory, which degrades "one owner per site" to "one owner
// per site among helper-only sessions" — an accepted, explicitly-logged P1 limitation.
let registryDir = FileManager.default.temporaryDirectory.appendingPathComponent("anglesite-remote-sessions")
try? FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
let containerSession = RemoteContainerSession(
    control: ContainerizationControl(),
    registry: RemoteSessionRegistry(directory: registryDir))

let session: LocalContainerSession
do {
    session = try await containerSession.ensureRunning(
        siteID: siteID, sourceRepo: siteRoot, ref: "HEAD",
        onOutput: { line, stream in FileHandle.standardError.write(Data(("[\(stream)] " + line + "\n").utf8)) })
} catch {
    die("container boot failed: \(error)")
}

let peer: WebRTCPeer
do {
    peer = try await WebRTCPeer.connect(
        role: .answerer, signaling: FileSignalingChannel(directory: signalDir, sender: "helper"))
} catch {
    await containerSession.tearDown(siteID: siteID)
    die("P2P connect failed: \(error)")
}

let httpBridge = FetchBridgeServer(connection: peer, executor: LoopbackHTTPExecutor(baseURL: session.previewURL))
let mcpBridge = LoopbackMCPBridge(mcpURL: session.mcpURL)
let mcpResponder = MCPChannelResponder(connection: peer, handler: { message in await mcpBridge.handle(message) })
let heartbeat = ControlHeartbeat(connection: peer, interval: .seconds(10), missLimit: 6, onMiss: { count in
    if count >= 6 { FileHandle.standardError.write(Data("control link presumed dead\n".utf8)) }
})

signal(SIGTERM) { _ in exit(0) }

async let httpTask: Void = httpBridge.run()
async let mcpTask: Void = mcpResponder.run()
async let heartbeatTask: Void = heartbeat.run()
_ = await (httpTask, mcpTask, heartbeatTask)

await containerSession.tearDown(siteID: siteID)

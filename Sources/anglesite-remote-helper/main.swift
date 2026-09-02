import Foundation
import AppKit
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
//
// Anywhere runtime (#1208 P2) helper entry point. P2 adds the NSApplication run loop this file
// never had in P1 — a real gap: the design spec's own rationale for the helper being "a real
// (faceless) app rather than a bare LaunchAgent" is "specifically so it can receive CloudKit
// push" (design spec §Architecture 2), but `registerForRemoteNotifications()` cannot be called
// without an NSApplication event loop, which this file did not run until now.
//
// `NSApplication.shared.run()` never returns on its own — the old top-level "fall off the end of
// main.swift" exit path is replaced by explicit `exit(0)`/`exit(1)` calls inside `runSession()`,
// matching what `die(_:)` and the SIGTERM handler already did.

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

@MainActor
final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await runSession() }
    }
}

func runSession() async {
    #if canImport(ServiceManagement)
    do {
        try SMAppServiceLoginItem().register()
    } catch {
        FileHandle.standardError.write(Data("login item registration failed: \(error)\n".utf8))
    }
    #endif

    let args = CommandLine.arguments
    guard args.count == 4, args[1] == "session" else {
        die("usage: anglesite-remote-helper session <signal-dir> <site-root>")
    }
    let signalDir = URL(fileURLWithPath: args[2], isDirectory: true)
    let siteRoot = URL(fileURLWithPath: args[3], isDirectory: true)
    // NOT `siteRoot.lastPathComponent`: `<site-root>` is a site's `Source/` git repo, so that is
    // the literal string "Source" for every site on the machine — and this key names both the
    // registry claim file and the container's on-disk boot artifacts. See `RemoteSiteIdentity`.
    let siteID = RemoteSiteIdentity.siteID(forSourceDirectory: siteRoot)

    // Production wiring of RemoteSessionRegistry at a *shared* (App Group) location is blocked on
    // an owner-side provisioning-portal change (see the plan's Task 2/5 manual note); until then
    // this falls back to a helper-local temp directory, which degrades "one owner per site" to
    // "one owner per site among helper-only sessions" — an accepted, explicitly-logged P1
    // limitation.
    let registryDir = FileManager.default.temporaryDirectory.appendingPathComponent("anglesite-remote-sessions")
    do {
        try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
    } catch {
        FileHandle.standardError.write(Data("registry directory creation failed: \(error)\n".utf8))
    }
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

    // Lifecycle markers on stderr, alongside the guest's own `[stdout]`/`[stderr]` lines. Logs are
    // sacred (CLAUDE.md), and until now this process reported nothing about its *own* state — the
    // guest chatter stops after boot and a session waiting for a peer looked identical to a hung
    // one. `HelperContainerE2ETests` also uses the first marker as its sync point: it waits for it
    // before offering, so the client never trickles ICE into a directory nobody is polling yet.
    FileHandle.standardError.write(Data(
        "remote-helper: container ready (preview \(session.previewURL), mcp \(session.mcpURL)); waiting for peer\n".utf8))

    let peer: WebRTCPeer
    do {
        peer = try await WebRTCPeer.connect(
            role: .answerer, signaling: FileSignalingChannel(directory: signalDir, sender: "helper"))
    } catch {
        await containerSession.tearDown(siteID: siteID)
        die("P2P connect failed: \(error)")
    }
    FileHandle.standardError.write(Data("remote-helper: peer connected; bridging\n".utf8))

    let httpBridge = FetchBridgeServer(connection: peer, executor: LoopbackHTTPExecutor(baseURL: session.previewURL))
    let mcpBridge = LoopbackMCPBridge(mcpURL: session.mcpURL)
    let mcpResponder = MCPChannelResponder(connection: peer, handler: { message in await mcpBridge.handle(message) })
    let heartbeat = ControlHeartbeat(connection: peer, interval: .seconds(10), missLimit: 6, onMiss: { count in
        if count >= 6 { FileHandle.standardError.write(Data("control link presumed dead\n".utf8)) }
    })

    // A raw C `signal()` handler can't safely call async Swift code (tearDown/peer.close() are
    // actor-isolated), so route SIGTERM through a DispatchSourceSignal instead: it delivers on a
    // normal GCD queue, which is a safe place to kick off a `Task` that closes the peer (letting
    // the `async let`s below unwind naturally) and tears the container session down before
    // exiting. `signal(SIGTERM, ...)` first blocks the default disposition (immediate
    // termination) so the dispatch source is the only thing that actually observes the signal.
    // The source itself must be retained for the process lifetime — GCD sources stop firing if
    // deallocated — hence the `let` scoped to this long-lived `async` function (which doesn't
    // return until teardown) rather than a throwaway local.
    //
    // A non-capturing closure handler is used instead of `SIG_IGN` deliberately, matching
    // `ProcessSupervisor.swift`'s own `ignoreSIGPIPE` precedent: the Swift-vended `Darwin.SIG_IGN`
    // constant is exported from the `libswift_DarwinFoundation3` overlay, which some of this
    // repo's CI images don't ship — referencing it can make a binary fail to load ("Library not
    // loaded: libswift_DarwinFoundation3.dylib"). The closure form avoids adding *this file's own*
    // reference to that symbol. Note this target still ends up linking the dylib regardless, via
    // `AnglesiteContainer`'s `apple/containerization` dependency (`ContainerizationOS/
    // AsyncSignalHandler.swift` references `SIG_IGN` directly) — a pre-existing characteristic
    // already shared by `AnglesiteContainerProbe`, not something this file can avoid on its own.
    signal(SIGTERM, { _ in })
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource.setEventHandler {
        Task {
            await peer.close()
            await containerSession.tearDown(siteID: siteID)
            exit(0)
        }
    }
    sigtermSource.resume()

    async let httpTask: Void = httpBridge.run()
    async let mcpTask: Void = mcpResponder.run()
    async let heartbeatTask: Void = heartbeat.run()
    _ = await (httpTask, mcpTask, heartbeatTask)

    await containerSession.tearDown(siteID: siteID)
    exit(0)
}

let delegate = HelperAppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()

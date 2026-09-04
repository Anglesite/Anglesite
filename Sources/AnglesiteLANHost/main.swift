import Foundation
import AnglesiteCore

// `anglesite-lan-host` — the Mac-Studio-side standing process for #601 §2: runs one site's
// Astro dev server + MCP sidecar bound to a LAN interface so a UTM guest VM's `LANControlClient`
// (Sources/AnglesiteCore/Container/LANControlClient.swift) can reach them directly over bridged/shared
// networking, without a container. One site per instance for v1 — run one `anglesite-lan-host`
// per site you want reachable (docs/specs/2026-07-09-lan-site-runtime-design.md, open question 1).
//
// Usage:
//   anglesite-lan-host serve --site <path-to-.anglesite-package-or-project> \
//     [--bind 0.0.0.0] [--preview-port 4321] [--mcp-port 4399] \
//     [--plugin-path <path-to-sibling-anglesite-checkout>] [--token <bearer-token>]

@main
struct AnglesiteLANHost {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "serve" else {
            printUsage()
            exit(2)
        }
        do {
            try await runServe(Array(args.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("anglesite-lan-host: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func printUsage() {
        FileHandle.standardError.write(Data("""
        usage: anglesite-lan-host serve --site <path> [--bind 0.0.0.0] \
        [--preview-port 4321] [--mcp-port 4399] [--plugin-path <path>] [--token <token>]\n
        """.utf8))
    }

    private static func runServe(_ args: [String]) async throws {
        var site: String?
        var bind = "0.0.0.0"
        var previewPort = LANRuntimeConfiguration.defaultPreviewPort
        var mcpPort = LANRuntimeConfiguration.defaultMCPPort
        var pluginPath: String?
        var token: String?

        var iterator = args.makeIterator()
        while let flag = iterator.next() {
            switch flag {
            case "--site": site = iterator.next()
            case "--bind": bind = iterator.next() ?? bind
            case "--preview-port": previewPort = iterator.next().flatMap(Int.init) ?? previewPort
            case "--mcp-port": mcpPort = iterator.next().flatMap(Int.init) ?? mcpPort
            case "--plugin-path": pluginPath = iterator.next()
            case "--token": token = iterator.next()
            default:
                FileHandle.standardError.write(Data("anglesite-lan-host: unknown flag \(flag)\n".utf8))
            }
        }
        guard let site else {
            printUsage()
            exit(2)
        }

        let siteDirectory = try LANHostServer.resolveSiteDirectory(sitePath: site)
        let pluginServerPath = try LANHostServer.resolvePluginServerPath(explicit: pluginPath)

        print("anglesite-lan-host: serving \(siteDirectory.path) on \(bind) "
            + "(preview :\(previewPort), mcp :\(mcpPort))")

        let logTask = Task { await streamLogs() }
        defer { logTask.cancel() }

        try await installDependenciesIfNeeded(siteDirectory: siteDirectory)

        let supervisor = ProcessSupervisor.shared
        _ = try await supervisor.launch(
            source: "astro-dev",
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["npx"] + LANHostServer.astroDevArguments(bindHost: bind, previewPort: previewPort),
            currentDirectoryURL: siteDirectory,
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 2))

        // Merge the sidecar's overrides over the inherited environment rather than passing them
        // alone — Foundation's `Process.environment` setter *replaces* the child's environment
        // when non-nil, so a bare partial dict would strip PATH/HOME and the `node` subprocess
        // spawned via `/usr/bin/env` would fail to resolve `node` on a typical Mac.
        var sidecarEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in LANHostServer.mcpSidecarEnvironment(
            bindHost: bind, mcpPort: mcpPort, projectRoot: siteDirectory, bearerToken: token) {
            sidecarEnvironment[key] = value
        }

        _ = try await supervisor.launch(
            source: "mcp-sidecar",
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", pluginServerPath.appendingPathComponent("index.mjs", isDirectory: false).path],
            environment: sidecarEnvironment,
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 2))

        #if canImport(Network)
        let advertiser = LANHostAdvertiser()
        advertiser.start(site: siteDirectory.lastPathComponent, previewPort: previewPort, mcpPort: mcpPort)
        defer { advertiser.stop() }
        #endif

        await waitForShutdownSignal()
        await supervisor.shutdownAll()
    }

    private static func installDependenciesIfNeeded(siteDirectory: URL) async throws {
        let nodeModules = siteDirectory.appendingPathComponent("node_modules", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: nodeModules.path) else { return }
        print("anglesite-lan-host: installing dependencies in \(siteDirectory.path)…")
        let result = try await ProcessSupervisor.shared.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["npm", "install"],
            currentDirectoryURL: siteDirectory)
        if !result.stdout.isEmpty { await LogCenter.shared.append(source: "npm-install", stream: .stdout, text: result.stdout) }
        if !result.stderr.isEmpty { await LogCenter.shared.append(source: "npm-install", stream: .stderr, text: result.stderr) }
    }

    private static func streamLogs() async {
        let subscription = await LogCenter.shared.subscribe()
        for await line in subscription.stream {
            print("[\(line.source)/\(line.stream)] \(line.text)")
        }
    }

    // Retained for the process's lifetime: a `DispatchSourceSignal` isn't kept alive by the
    // dispatch runtime once `.resume()` is called, so a local variable with no other strong
    // reference is eligible for ARC deallocation as soon as `waitForShutdownSignal`'s setup
    // closure returns — before either source could plausibly fire — which would silently
    // reintroduce the "process doesn't respond to kill/Ctrl-C" bug these sources exist to fix.
    @MainActor private static var sigintSource: DispatchSourceSignal?
    @MainActor private static var sigtermSource: DispatchSourceSignal?

    // Isolated to match the two properties above — both sources are scheduled on `.main` anyway.
    @MainActor private static func waitForShutdownSignal() async {
        await withCheckedContinuation { continuation in
            // Use a no-op handler instead of SIG_IGN to avoid pulling in libswift_DarwinFoundation3
            // (which some macOS runners don't ship), making the process fail to load at dyld time.
            signal(SIGINT, { _ in })
            let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigint.setEventHandler { continuation.resume() }
            sigintSource = sigint
            sigint.resume()

            // Also handle SIGTERM (the default signal from `kill`/launchd) the same way, so a
            // standing background process still runs `supervisor.shutdownAll()` instead of
            // dying immediately via the default disposition and orphaning the astro/node
            // children still holding the preview/MCP ports.
            signal(SIGTERM, { _ in })
            let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            sigterm.setEventHandler { continuation.resume() }
            sigtermSource = sigterm
            sigterm.resume()
        }
    }
}

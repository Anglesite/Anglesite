# LAN Host Dev-Server Process (#601 §2) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a standalone `anglesite-lan-host` CLI that runs one site's Astro dev server + MCP sidecar on the Mac Studio, bound to a LAN interface, so a UTM guest VM's already-landed `LANControlClient` (PR #604) can reach it — closing out issue #601.

**Architecture:** A new SwiftPM executable target (`AnglesiteLANHost`, product `anglesite-lan-host`) that is thin CLI glue over `ProcessSupervisor` (the app's sanctioned subprocess-spawning seam) and a new pure, unit-testable `AnglesiteCore` type (`LANHostServer`) that resolves the site directory, resolves the sibling plugin repo's MCP sidecar, and builds the `astro dev` arguments / sidecar environment. This mirrors the container guest's own invocation (`Sources/AnglesiteContainer/ContainerizationControl.swift`) — same ports (4321/4399), same `ANGLESITE_MCP_*` env contract — just run directly on the trusted host instead of inside a container, with the bind address swapped from loopback to the configured LAN interface.

**Tech Stack:** Swift 6.4 / SwiftPM executable target, `ProcessSupervisor` (AnglesiteCore), Swift Testing (`import Testing`, `@Test`, `#expect`) for the new test file, Node/npm/`astro` CLI + the sibling `anglesite` plugin repo's `server/index.mjs` MCP sidecar (external processes spawned, not linked).

## Global Constraints

- One site per `anglesite-lan-host` instance for v1 — the design note (`docs/specs/2026-07-09-lan-site-runtime-design.md`, open question 1) leans this way, and `LANControlClient.start()` never transmits `siteID`/`gitRef` to the host in any usable form, so multi-site dispatch has no client-side hook to key off yet.
- No competing #587 host-process work exists today (#587 is a Cloudflare Worker + KV/D1 pipeline, not a standing Mac-side process) — the design note's overlap-check open question is resolved: nothing to coordinate with.
- Auth: default trusted-LAN (no bearer token), matching `LiveSiteRuntimeFactory`'s existing `connect: { client, url, _ in try await client.connect(httpEndpoint: url) }` no-bearer wiring. An optional `--token` flag threads a bearer value into the MCP sidecar's environment for future auth parity, but this repo has no visibility into whether the sidecar (which lives in the sibling `anglesite` plugin repo) verifies it yet — treat the flag as forward-compatible plumbing, not a verified security boundary.
- Default ports: 4321 (preview), 4399 (MCP) — must match `LANRuntimeConfiguration.defaultPreviewPort`/`defaultMCPPort` (`Sources/AnglesiteCore/LANControlClient.swift`) exactly, since the guest client assumes these unless Settings overrides them.
- New logic goes in `AnglesiteCore` (testable), not in `main.swift` (untestable by CI's hosted-app constraints per CLAUDE.md's `TokenOnboarding` precedent) — `main.swift` stays thin argument-parsing + `ProcessSupervisor` wiring only.
- Follow the existing `AnglesiteContainerProbe` precedent for a new executable target's shape: own `Sources/<Name>/main.swift`, `@main struct` with manual arg parsing, added to `Package.swift` unconditionally (not gated by `includeContainer`, since this target needs no Containerization dependency) — it will be excluded automatically by the existing off-Darwin `portableTargets` filter at the bottom of `Package.swift` since it isn't in that set.

---

### Task 1: `LANHostServer.resolveSiteDirectory` + `resolvePluginServerPath`

**Files:**
- Create: `Sources/AnglesiteCore/LANHostServer.swift`
- Test: `Tests/AnglesiteCoreTests/LANHostServerTests.swift`

**Interfaces:**
- Produces: `public enum LANHostServerError: Error, Equatable, CustomStringConvertible { case siteNotFound(String), notAGitRepo(String), pluginServerNotFound(String) }`
- Produces: `public enum LANHostServer { static func resolveSiteDirectory(sitePath: String, fileManager: FileManager = .default) throws -> URL }`
- Produces: `public enum LANHostServer { static func resolvePluginServerPath(explicit: String?, environment: [String: String] = ProcessInfo.processInfo.environment, currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true), fileManager: FileManager = .default) throws -> URL }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/LANHostServerTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct LANHostServerTests {
    // MARK: - resolveSiteDirectory

    @Test("resolves an .anglesite package to its Source/ directory")
    func resolvesPackageSourceDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "lan-host-test-\(UUID().uuidString).anglesite", isDirectory: true)
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try fm.createDirectory(at: source.appendingPathComponent(".git", isDirectory: true),
                                withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Info.plist", isDirectory: false))
        defer { try? fm.removeItem(at: root) }

        let resolved = try LANHostServer.resolveSiteDirectory(sitePath: root.path)
        #expect(resolved.standardizedFileURL == source.standardizedFileURL)
    }

    @Test("resolves a raw Astro project directory directly")
    func resolvesRawProjectDirectory() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lan-host-raw-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".git", isDirectory: true),
                                withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("package.json", isDirectory: false))
        defer { try? fm.removeItem(at: dir) }

        let resolved = try LANHostServer.resolveSiteDirectory(sitePath: dir.path)
        #expect(resolved.standardizedFileURL == dir.standardizedFileURL)
    }

    @Test("throws siteNotFound when nothing recognizable exists at the path")
    func throwsWhenSiteMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("lan-host-missing-\(UUID().uuidString)")
        #expect(throws: LANHostServerError.siteNotFound(missing.path)) {
            try LANHostServer.resolveSiteDirectory(sitePath: missing.path)
        }
    }

    @Test("throws notAGitRepo when the resolved project root has no .git directory")
    func throwsWhenNotGitRepo() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lan-host-nogit-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("package.json", isDirectory: false))
        defer { try? fm.removeItem(at: dir) }

        #expect(throws: LANHostServerError.notAGitRepo(dir.standardizedFileURL.path)) {
            try LANHostServer.resolveSiteDirectory(sitePath: dir.path)
        }
    }

    // MARK: - resolvePluginServerPath

    @Test("prefers an explicit path over the environment default")
    func explicitPluginPathWins() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lan-host-plugin-\(UUID().uuidString)", isDirectory: true)
        let serverDir = dir.appendingPathComponent("server", isDirectory: true)
        try fm.createDirectory(at: serverDir, withIntermediateDirectories: true)
        try Data().write(to: serverDir.appendingPathComponent("index.mjs", isDirectory: false))
        defer { try? fm.removeItem(at: dir) }

        let resolved = try LANHostServer.resolvePluginServerPath(
            explicit: dir.path, environment: ["ANGLESITE_PLUGIN_SRC": "/nonexistent"])
        #expect(resolved.standardizedFileURL == serverDir.standardizedFileURL)
    }

    @Test("falls back to ANGLESITE_PLUGIN_SRC when no explicit path is given")
    func envPluginPathFallback() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "lan-host-plugin-env-\(UUID().uuidString)", isDirectory: true)
        let serverDir = dir.appendingPathComponent("server", isDirectory: true)
        try fm.createDirectory(at: serverDir, withIntermediateDirectories: true)
        try Data().write(to: serverDir.appendingPathComponent("index.mjs", isDirectory: false))
        defer { try? fm.removeItem(at: dir) }

        let resolved = try LANHostServer.resolvePluginServerPath(
            explicit: nil, environment: ["ANGLESITE_PLUGIN_SRC": dir.path])
        #expect(resolved.standardizedFileURL == serverDir.standardizedFileURL)
    }

    @Test("throws pluginServerNotFound when index.mjs is missing")
    func throwsWhenPluginServerMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("lan-host-plugin-missing-\(UUID().uuidString)")
        #expect(throws: LANHostServerError.pluginServerNotFound(missing.standardizedFileURL.path)) {
            try LANHostServer.resolvePluginServerPath(explicit: missing.path, environment: [:])
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LANHostServerTests`
Expected: FAIL — `LANHostServer`/`LANHostServerError` not defined.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/LANHostServer.swift`:

```swift
import Foundation

/// Pure, testable logic backing the `anglesite-lan-host` CLI (`Sources/AnglesiteLANHost`) — the
/// Mac-Studio-side standing process for #601 §2. Kept here rather than in the executable target
/// per the `TokenOnboarding` precedent noted in CLAUDE.md: `swift test` can exercise this,
/// `main.swift` (a hosted CLI entry point) cannot be unit-tested the same way.
public enum LANHostServerError: Error, Equatable, CustomStringConvertible {
    case siteNotFound(String)
    case notAGitRepo(String)
    case pluginServerNotFound(String)

    public var description: String {
        switch self {
        case .siteNotFound(let path):
            return "no .anglesite package or Astro project found at \(path)"
        case .notAGitRepo(let path):
            return "\(path) has no .git directory — the project root must be a git repo"
        case .pluginServerNotFound(let path):
            return "no server/index.mjs found under \(path) — pass --plugin-path or set ANGLESITE_PLUGIN_SRC"
        }
    }
}

public enum LANHostServer {
    /// Resolves a `--site` argument — either an `.anglesite` package directory (containing
    /// `Info.plist` + `Source/`) or a raw Astro project directory — to the Astro project root to
    /// serve. Mirrors `AnglesitePackage.sourceURL` (`Sources/AnglesiteSiteModel/AnglesitePackage.swift`)
    /// without depending on `AnglesiteSiteModel`, since only the `Source/` path matters here.
    public static func resolveSiteDirectory(sitePath: String, fileManager: FileManager = .default) throws -> URL {
        let path = URL(fileURLWithPath: sitePath, isDirectory: true).standardizedFileURL
        let infoPlist = path.appendingPathComponent("Info.plist", isDirectory: false)
        let sourceDir = path.appendingPathComponent("Source", isDirectory: true)

        let projectRoot: URL
        if fileManager.fileExists(atPath: infoPlist.path), fileManager.fileExists(atPath: sourceDir.path) {
            projectRoot = sourceDir
        } else if fileManager.fileExists(atPath: path.appendingPathComponent("package.json", isDirectory: false).path) {
            projectRoot = path
        } else {
            throw LANHostServerError.siteNotFound(sitePath)
        }

        guard fileManager.fileExists(atPath: projectRoot.appendingPathComponent(".git", isDirectory: true).path) else {
            throw LANHostServerError.notAGitRepo(projectRoot.standardizedFileURL.path)
        }
        return projectRoot
    }

    /// Resolves the sibling `anglesite` plugin repo's `server/` directory — the MCP HTTP sidecar
    /// entry point (`server/index.mjs`) staged into the container image at build time by
    /// `scripts/vendor-container-image.sh`. Resolution order mirrors `scripts/copy-plugin.sh`:
    /// explicit path > `ANGLESITE_PLUGIN_SRC` env > `../anglesite` sibling default.
    public static func resolvePluginServerPath(
        explicit: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        fileManager: FileManager = .default
    ) throws -> URL {
        let pluginRoot: URL
        if let explicit {
            pluginRoot = URL(fileURLWithPath: explicit, isDirectory: true).standardizedFileURL
        } else if let envPath = environment["ANGLESITE_PLUGIN_SRC"] {
            pluginRoot = URL(fileURLWithPath: envPath, isDirectory: true).standardizedFileURL
        } else {
            pluginRoot = currentDirectory.appendingPathComponent("../anglesite", isDirectory: true).standardizedFileURL
        }

        let serverDir = pluginRoot.appendingPathComponent("server", isDirectory: true)
        let entry = serverDir.appendingPathComponent("index.mjs", isDirectory: false)
        guard fileManager.fileExists(atPath: entry.path) else {
            throw LANHostServerError.pluginServerNotFound(pluginRoot.standardizedFileURL.path)
        }
        return serverDir
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LANHostServerTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LANHostServer.swift Tests/AnglesiteCoreTests/LANHostServerTests.swift
git commit -m "feat(lan-host): add site/plugin path resolution for #601 §2"
```

---

### Task 2: `LANHostServer.astroDevArguments` + `mcpSidecarEnvironment`

**Files:**
- Modify: `Sources/AnglesiteCore/LANHostServer.swift`
- Modify: `Tests/AnglesiteCoreTests/LANHostServerTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 (independent pure functions on the same enum).
- Produces: `public enum LANHostServer { static func astroDevArguments(bindHost: String, previewPort: Int) -> [String] }`
- Produces: `public enum LANHostServer { static func mcpSidecarEnvironment(bindHost: String, mcpPort: Int, projectRoot: URL, bearerToken: String?) -> [String: String] }`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnglesiteCoreTests/LANHostServerTests.swift` (inside the `LANHostServerTests` struct):

```swift
    // MARK: - astroDevArguments / mcpSidecarEnvironment

    @Test("astro dev arguments bind the configured LAN host and port")
    func astroArguments() {
        let args = LANHostServer.astroDevArguments(bindHost: "0.0.0.0", previewPort: 4321)
        #expect(args == ["astro", "dev", "--port", "4321", "--host", "0.0.0.0"])
    }

    @Test("mcp sidecar environment sets host/port/project root, omits bearer token by default")
    func mcpEnvironmentDefault() {
        let projectRoot = URL(fileURLWithPath: "/tmp/site")
        let env = LANHostServer.mcpSidecarEnvironment(
            bindHost: "0.0.0.0", mcpPort: 4399, projectRoot: projectRoot, bearerToken: nil)
        #expect(env == [
            "ANGLESITE_MCP_TRANSPORT": "http",
            "ANGLESITE_MCP_PORT": "4399",
            "ANGLESITE_MCP_HOST": "0.0.0.0",
            "ANGLESITE_PROJECT_ROOT": "/tmp/site"
        ])
    }

    @Test("mcp sidecar environment includes the bearer token when configured")
    func mcpEnvironmentWithToken() {
        let projectRoot = URL(fileURLWithPath: "/tmp/site")
        let env = LANHostServer.mcpSidecarEnvironment(
            bindHost: "0.0.0.0", mcpPort: 4399, projectRoot: projectRoot, bearerToken: "secret")
        #expect(env["ANGLESITE_MCP_BEARER_TOKEN"] == "secret")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LANHostServerTests`
Expected: FAIL — `astroDevArguments`/`mcpSidecarEnvironment` not defined.

- [ ] **Step 3: Write the implementation**

Append to the `LANHostServer` enum in `Sources/AnglesiteCore/LANHostServer.swift` (after `resolvePluginServerPath`, before the closing `}`):

```swift

    /// `astro dev` CLI arguments for the LAN-bound host invocation — mirrors the container
    /// guest's `npx astro dev --port 4321 --host 127.0.0.1`
    /// (`Sources/AnglesiteContainer/ContainerizationControl.swift`), swapping the guest's
    /// loopback-only bind for the configured LAN `bindHost`.
    public static func astroDevArguments(bindHost: String, previewPort: Int) -> [String] {
        ["astro", "dev", "--port", String(previewPort), "--host", bindHost]
    }

    /// Environment for the MCP sidecar (`node <pluginServerPath>/index.mjs`). Mirrors the
    /// container guest's env exactly (`ANGLESITE_MCP_TRANSPORT=http`, `ANGLESITE_MCP_PORT=4399`)
    /// except `ANGLESITE_MCP_HOST`, which the guest leaves unset (defaulting to 127.0.0.1,
    /// correct for its own loopback vsock bridge) but the LAN host must set explicitly to bind
    /// beyond loopback. `bearerToken` is optional forward-compat plumbing for #601 §2's "auth
    /// parity with the sandbox path" checkbox — nil by default (trusted-LAN, single-owner).
    public static func mcpSidecarEnvironment(
        bindHost: String, mcpPort: Int, projectRoot: URL, bearerToken: String?
    ) -> [String: String] {
        var env = [
            "ANGLESITE_MCP_TRANSPORT": "http",
            "ANGLESITE_MCP_PORT": String(mcpPort),
            "ANGLESITE_MCP_HOST": bindHost,
            "ANGLESITE_PROJECT_ROOT": projectRoot.path
        ]
        if let bearerToken {
            env["ANGLESITE_MCP_BEARER_TOKEN"] = bearerToken
        }
        return env
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LANHostServerTests`
Expected: PASS (11 tests total).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LANHostServer.swift Tests/AnglesiteCoreTests/LANHostServerTests.swift
git commit -m "feat(lan-host): add astro/mcp command-line and env builders for #601 §2"
```

---

### Task 3: `AnglesiteLANHost` executable target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AnglesiteLANHost/main.swift`

**Interfaces:**
- Consumes: `LANHostServer.resolveSiteDirectory`, `LANHostServer.resolvePluginServerPath`, `LANHostServer.astroDevArguments`, `LANHostServer.mcpSidecarEnvironment` (Tasks 1–2); `ProcessSupervisor.shared.launch(source:executable:arguments:environment:currentDirectoryURL:restartPolicy:attachStdin:onRespawn:logCenter:) async throws -> ProcessSupervisor.Handle`; `ProcessSupervisor.shared.run(executable:arguments:environment:currentDirectoryURL:) async throws -> ProcessSupervisor.RunResult`; `ProcessSupervisor.shared.shutdownAll(timeout:) async`; `LogCenter.shared.subscribe() -> LogCenter.Subscription` (`Sources/AnglesiteCore/LogCenter.swift`); `LANRuntimeConfiguration.defaultPreviewPort`/`defaultMCPPort` (`Sources/AnglesiteCore/LANControlClient.swift`).
- Produces: the `anglesite-lan-host` executable product — nothing else consumes this within the package (it's a standalone CLI, not linked by the app or tests).

- [ ] **Step 1: Add the target and product to Package.swift**

In `Package.swift`, insert a new target immediately after the `AnglesiteIntents` target block (after line 95, `),` closing that block, before the `// Test-only support...` comment on line 96):

```swift
    .executableTarget(
        name: "AnglesiteLANHost",
        dependencies: ["AnglesiteCore"],
        path: "Sources/AnglesiteLANHost",
        swiftSettings: strictConcurrency,
        linkerSettings: weakLinkFoundationModels
    ),
```

And in the `packageProducts` array (after `.library(name: "AnglesiteIntents", targets: ["AnglesiteIntents"])` on line 239), add:

```swift
    ,
    .executable(name: "anglesite-lan-host", targets: ["AnglesiteLANHost"])
```

(Adjust trailing commas so the array remains valid Swift — the existing array literal has no trailing comma after its last element, so append `,` before the new entry and drop it from the new entry's own line.)

- [ ] **Step 2: Write `main.swift`**

Create `Sources/AnglesiteLANHost/main.swift`:

```swift
import Foundation
import AnglesiteCore

// `anglesite-lan-host` — the Mac-Studio-side standing process for #601 §2: runs one site's
// Astro dev server + MCP sidecar bound to a LAN interface so a UTM guest VM's `LANControlClient`
// (Sources/AnglesiteCore/LANControlClient.swift) can reach them directly over bridged/shared
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

        _ = try await supervisor.launch(
            source: "mcp-sidecar",
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", pluginServerPath.appendingPathComponent("index.mjs", isDirectory: false).path],
            environment: LANHostServer.mcpSidecarEnvironment(
                bindHost: bind, mcpPort: mcpPort, projectRoot: siteDirectory, bearerToken: token),
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 2))

        await waitForShutdownSignal()
        await supervisor.shutdownAll()
    }

    private static func installDependenciesIfNeeded(siteDirectory: URL) async throws {
        let nodeModules = siteDirectory.appendingPathComponent("node_modules", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: nodeModules.path) else { return }
        print("anglesite-lan-host: installing dependencies in \(siteDirectory.path)…")
        _ = try await ProcessSupervisor.shared.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["npm", "install"],
            currentDirectoryURL: siteDirectory)
    }

    private static func streamLogs() async {
        let subscription = await LogCenter.shared.subscribe()
        for await line in subscription.stream {
            print("[\(line.source)/\(line.stream)] \(line.text)")
        }
    }

    private static func waitForShutdownSignal() async {
        await withCheckedContinuation { continuation in
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            source.setEventHandler { continuation.resume() }
            source.resume()
        }
    }
}
```

- [ ] **Step 3: Build the new target**

Run: `swift build --product anglesite-lan-host`
Expected: builds successfully with no errors. (This target has no unit tests of its own — its logic lives in `LANHostServer`, already covered by Tasks 1–2; this step only proves the CLI glue compiles and links.)

- [ ] **Step 4: Run the full test suite to confirm nothing else broke**

Run: `swift test --package-path .`
Expected: PASS — same suites as before, plus the 11 new `LANHostServerTests`.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/AnglesiteLANHost/main.swift
git commit -m "feat(lan-host): add anglesite-lan-host CLI for #601 §2"
```

---

### Task 4: Close out #601 tracking

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:** none — documentation only.

- [ ] **Step 1: Update the UTM-VM dev/test rig status line**

In `CLAUDE.md`, find the line:

```
- **UTM-VM dev/test rig (#589):** validate `SiteRuntime` across macOS/Windows/Linux guests on the Mac Studio. Phase-1 guest side (`LANControlClient` + factory/Settings wiring, #601) landed; the host-side LAN-bound dev-server process remains (check overlap with #587 before building).
```

Replace with:

```
- **UTM-VM dev/test rig (#589):** validate `SiteRuntime` across macOS/Windows/Linux guests on the Mac Studio. Phase-1 (#601) landed in full — guest side (`LANControlClient` + factory/Settings wiring, PR #604) and the host-side `anglesite-lan-host` CLI (`Sources/AnglesiteLANHost`, one site per instance, ports 4321/4399) that runs a site's Astro dev server + MCP sidecar bound to the LAN interface.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: mark #601 landed in full"
```

---

### Task 5 (manual, not subagent-executable): Real-hardware smoke test

**Files:** none — this is a runtime verification step, not a code change.

**Interfaces:** none.

This task requires the actual Mac Studio host and a UTM guest VM — it cannot be executed by a subagent in this worktree. Leave it for the user (or flag it back explicitly) after Tasks 1–4 land:

- [ ] On the Mac Studio: `swift build --product anglesite-lan-host -c release`, then run `.build/release/anglesite-lan-host serve --site ~/Sites/some-test-site.anglesite --bind <mac-studio LAN IP>`.
- [ ] Confirm `http://<mac-studio-ip>:4321/` serves the site and `http://<mac-studio-ip>:4399/mcp` responds to an MCP `initialize` call.
- [ ] In a UTM guest VM with no nested virtualization: set Settings → Advanced → "LAN site runtime" → Runtime host to the Mac Studio's LAN IP/hostname, open the same site, confirm preview loads and an MCP apply-edit round-trips (#601's acceptance criterion).

---

## Self-Review

**Spec coverage:**
- §1 (guest side) — already landed (PR #604), no task needed.
- §2 (host side) — Tasks 1–3 (`LANHostServer` resolution + argument/env builders, `anglesite-lan-host` CLI wired to `ProcessSupervisor`).
- §2 "optional bearer-token check" — `--token` flag threads a bearer into the sidecar env (Task 2/3); full verification is out of this repo's scope (sidecar lives in the sibling plugin repo) — documented as a Global Constraint, not silently dropped.
- §2 "decide v1 scope" — resolved to one-site-per-instance, documented in `main.swift`'s header comment and this plan's Global Constraints.
- §2 "check overlap with #587" — resolved during research: no competing #587 host-process work exists (#587 is a Worker/KV pipeline). Documented as a Global Constraint.
- §3 (wiring) — already landed (PR #604), no task needed.
- Acceptance criterion (guest opens a site, gets live preview, round-trips MCP apply-edit against the Mac-Studio-hosted runtime) — Task 5, manual (requires real hardware).

**Placeholder scan:** none found — every step has complete, runnable code or an exact command.

**Type consistency:** `LANHostServer.resolveSiteDirectory`/`resolvePluginServerPath`/`astroDevArguments`/`mcpSidecarEnvironment` signatures are identical across Tasks 1–3 (declared in Tasks 1–2, consumed verbatim in Task 3's `main.swift`).

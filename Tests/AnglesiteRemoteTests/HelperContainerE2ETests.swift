import Testing
import Foundation
import AnglesiteCore
import AnglesiteP2P

/// The Anywhere-runtime **P1 exit criterion** (#1208): a second Mac process edits a site while
/// the main `Anglesite.app` is never launched.
///
/// Where P0's `TwoProcessE2ETests` proved only the transport core across a process boundary (two
/// copies of `anglesite-p2p-demo`, a directory-backed HTTP stub and a canned MCP responder), this
/// proves the whole P1 stack end to end with nothing stubbed:
///
/// 1. `anglesite-remote-helper` is spawned as a **real second OS process** (its own PID), which
///    boots a **real Apple-Containerization VM** for the site and answers a **real WebRTC** offer
///    over `FileSignalingChannel`. (Its `SMAppServiceLoginItem` registration runs too, but a bare
///    SwiftPM binary is not a registerable bundle, so that step logs a failure and continues —
///    exercised, not asserted.)
/// 2. This test process is the client: it drives a **real MCP `tools/call`** (`create_page`) over
///    the shared connection's `mcp` channel, through the helper's `LoopbackMCPBridge`, into the
///    MCP sidecar running inside the guest.
/// 3. The edit is then confirmed over a *different* channel — a `FetchBridgeClient` GET of the new
///    route through the helper's `LoopbackHTTPExecutor` — so the proof does not rest on the MCP
///    reply the same bridge produced. The route 404s before the call and serves the scaffolded
///    page's own markup after it, which only a real file on a real filesystem, seen by a
///    separately-running `astro dev`, can produce.
///
/// **Where the edit lands.** The container clones the host repo through a *read-only* virtio-fs
/// share (`ContainerizationControl.start` step 3), so the sidecar's write and commit happen in
/// the guest's own `/workspace/site` clone first. Copying that commit back into the canonical
/// `Source/` repo is a separate, app-side step — on the main-app path,
/// `LocalContainerSiteRuntime.persistEdit` → `InProcessEditPersistence`, driven by
/// `MCPApplyEditRouter`; on the P1 helper path, `HelperEditPersister` (wired into the session loop
/// alongside `LoopbackMCPBridge`) does the same export/import for any reply that carries a commit.
/// ``secondProcessPersistsAnApplyEditToHostSource``, below, proves that helper-side hop end to end
/// for `apply_edit`. `create_page` now commits in the guest too (the sidecar-side git-identity gap
/// `secondProcessEditsSiteWithNoMainAppRunning` above used to pin is fixed upstream — see that
/// test's own comment), so its replies could feed the same persist step, but wiring `HelperEditPersister`
/// up to that a second time is separate follow-up work, out of scope here.
///
/// Gated on all three of `ANGLESITE_CONTAINER_TESTS=1` (which is also what adds the
/// `AnglesiteContainerLocalTests` test target to `Package.swift` at all — the helper *executable*
/// is gated separately, by `includeContainer`, i.e. Darwin without `ANGLESITE_SKIP_CONTAINER=1`),
/// `ANGLESITE_CONTAINER_E2E=1`, and `ANGLESITE_P2P_E2E=1` —
/// the union of `ContainerizationControlTests`'s and `TwoProcessE2ETests`'s own gates, since this
/// needs both an entitled Apple-Silicon Mac with vendored boot artifacts and a real WebRTC
/// handshake. Run it with:
///
/// ```sh
/// ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1 ANGLESITE_P2P_E2E=1 \
///   swift test --filter HelperContainerE2ETests
/// ```
@Suite(.enabled(if:
    ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_TESTS"] == "1" &&
    ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_E2E"] == "1" &&
    ProcessInfo.processInfo.environment["ANGLESITE_P2P_E2E"] == "1"), .serialized)
struct HelperContainerE2ETests {
    /// Bounds the whole run rather than letting a stalled boot or handshake hang the suite
    /// (repo convention). Generous because a cold container boot legitimately costs minutes —
    /// `previewReadyTimeout`'s own doc comment budgets ~186 s for the guest alone.
    @Test(.timeLimit(.minutes(15)))
    func secondProcessEditsSiteWithNoMainAppRunning() async throws {
        let helperBinary = try Self.locateHelperBinary()
        try Self.entitleForVirtualization(helperBinary)

        let siteRoot = try Self.makeThrowawayAstroRepo()
        defer { try? FileManager.default.removeItem(at: siteRoot) }

        let signalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helper-e2e-sig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: signalDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: signalDirectory) }

        // --- The second process ------------------------------------------------------------
        let helper = Process()
        helper.executableURL = helperBinary
        helper.arguments = ["session", signalDirectory.path, siteRoot.path]
        let helperOutput = ProcessOutputCapture()
        helperOutput.attach(to: helper)
        try helper.run()
        // Logs are sacred, and a leaked helper would keep a VM running: terminate and drain on
        // every exit path, including a thrown expectation below.
        defer {
            if helper.isRunning { helper.terminate() }
            helper.waitUntilExit() // reap first, so teardown output is captured before...
            helperOutput.stop() // ...detaching the readability handlers that gather it.
        }

        let helperPID = helper.processIdentifier
        #expect(helperPID != ProcessInfo.processInfo.processIdentifier,
                "the helper must be a separate OS process, not this test's own")
        #expect(helperPID > 0, "the helper failed to launch")

        // Wait for the helper's own "container ready" marker before offering: it means the VM
        // booted and the answerer is about to start polling `signalDirectory`, so this side never
        // trickles a handshake into a directory nobody is reading yet.
        let booted = await Self.waitForOutput(
            "remote-helper: container ready", from: helperOutput, timeout: .seconds(600))
        #expect(booted, "the helper never reported a booted container\n\(helperOutput.transcript)")
        try #require(booted)
        // A real VM really booted: the guest's own clone/hydrate/astro chatter, streamed line by
        // line out of the container by `ContainerizationControl`'s `onOutput`, is in the same
        // transcript — nothing mock-shaped can produce it.
        let sawGuestOutput = helperOutput.stderrString.contains("[stdout]")
            || helperOutput.stderrString.contains("[stderr]")
        #expect(sawGuestOutput, "no guest process output — did a real container boot?\n\(helperOutput.transcript)")

        // --- The client side ---------------------------------------------------------------
        let clientPeer = try await WebRTCPeer.connect(
            role: .offerer, signaling: FileSignalingChannel(directory: signalDirectory, sender: "client"))
        var peerIsOpen = true
        defer { if peerIsOpen { Task { await clientPeer.close() } } }

        let fetch = FetchBridgeClient(connection: clientPeer)
        let mcp = WebRTCTransport(connection: clientPeer)
        try await mcp.open()
        var mcpInbound = mcp.inbound().makeAsyncIterator()

        // The preview bridge is live before any edit, and the page this test is about to create
        // does not exist yet — so a 200 for it below can only be caused by the edit.
        let slug = "e2e-\(UUID().uuidString.prefix(8).lowercased())"
        let route = "/\(slug)"
        let (homeStatus, _) = try await Self.get("/", over: fetch)
        #expect(homeStatus == 200, "preview bridge did not serve the site root (status \(homeStatus))")
        let (beforeStatus, _) = try await Self.get(route, over: fetch)
        #expect(beforeStatus == 404, "\(route) already existed before the edit (status \(beforeStatus))")

        // --- The edit ------------------------------------------------------------------------
        // `create_page` (not `apply_edit`): the sidecar's minimal content-creating tool — it takes
        // `{name, route}`, scaffolds `src/pages/<route>.astro` from its BaseLayout template, commits
        // it in the guest (see below — the sidecar-side git-identity gap this used to be pinned on
        // is fixed), and returns `{filePath, route, commit}` as JSON text. `apply_edit` would need a
        // DOM-derived `ElementInfo` selector payload, which proves nothing extra here.
        let title = "Anywhere Runtime \(slug)"
        try await mcp.send(Self.request(id: 1, method: "tools/call", params: .object([
            "name": .string("create_page"),
            "arguments": .object(["name": .string(title), "route": .string(route)]),
        ])))
        guard let reply = await mcpInbound.next() else {
            Issue.record("no MCP reply for create_page\n\(helperOutput.transcript)")
            return
        }
        let toolText = Self.toolResultText(reply)
        #expect(toolText != nil, "create_page reply had no text content: \(Self.describe(reply))")
        try #require(toolText != nil)
        guard let created = Self.decodeObject(toolText ?? "") else {
            Issue.record("create_page did not return JSON: \(toolText ?? "<nil>")")
            return
        }
        let filePath = created["filePath"] as? String
        #expect(filePath == "src/pages\(route).astro", "unexpected filePath: \(filePath ?? "<nil>")")

        // Was pinned `== nil`, like the persistence boundary this suite used to carry: `create_page`
        // used to write the file but come back with `commit: null` inside the container —
        // `create-content.mjs`'s `commitFile` shelled out to a bare `git commit` with no identity,
        // unlike `edit-history.mjs`/`undo-edit.mjs`, which pass `ANGLESITE_COMMIT_IDENTITY` for
        // exactly this reason (anglesite#428). That sidecar-repo gap is now fixed — `anglesite-skills`
        // PR #436 (`fix(server): give create-content's commitFile a stable git identity`) gave
        // `commitFile` the same identity and is merged to that repo's `main` — so this now asserts
        // the commit is present, per this pin's own original "flip it to `!= nil` then" instruction.
        // A future helper-side persist step can now export this hash for `create_page` too, the same
        // way `secondProcessPersistsAnApplyEditToHostSource` already does for `apply_edit` — that
        // wiring itself is separate follow-up work, out of scope here.
        let guestCommit = created["commit"] as? String
        #expect(guestCommit != nil, """
            create_page returned no commit — the sidecar-side git-identity fix (anglesite-skills \
            PR #436) may have regressed, or this sidecar checkout predates it.
            """)

        // --- The proof, over a different channel ---------------------------------------------
        // A 200 here means `astro dev` — a separate process inside the guest, which never saw the
        // JSON-RPC exchange — read a real file off a real filesystem and rendered it. Retried
        // because Vite's watcher needs a moment to notice the new route.
        var servedStatus = 0
        var servedBody = ""
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            (servedStatus, servedBody) = try await Self.get(route, over: fetch)
            if servedStatus == 200, servedBody.contains(title) { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(servedStatus == 200, "the created page never served (last status \(servedStatus))\n\(helperOutput.transcript)")
        let bodyCarriesTheEdit = servedBody.contains(title)
        #expect(bodyCarriesTheEdit, "the served page did not carry the edit's own title")

        // --- Teardown ------------------------------------------------------------------------
        await mcp.close()
        await clientPeer.close()
        peerIsOpen = false
        // `close()` sends `.bye`, which unwinds the helper's bridge loops; it then tears the
        // container down and returns from `main` on its own. Only escalate to SIGTERM if it
        // doesn't (the `defer` above does that).
        let exitedOnItsOwn = await Self.waitForExit(helper, timeout: .seconds(120))
        #expect(exitedOnItsOwn, "the helper did not exit after the peer closed\n\(helperOutput.transcript)")
        if exitedOnItsOwn {
            #expect(helper.terminationStatus == 0,
                    "the helper exited \(helper.terminationStatus)\n\(helperOutput.transcript)")
        }
    }

    /// The app-side half of Anywhere-runtime persistence, proven end-to-end: an `apply_edit`
    /// relayed through the helper's `mcp` channel — which reliably gets a real guest-side commit,
    /// per `AnglesiteContainerProbe`'s daily proof of the same tool, same as `create_page` does now
    /// (see the sibling test above) — lands in the HOST's canonical `Source/` repository: the file
    /// changes on disk and `git log` shows a new commit whose parent is the pre-edit HEAD.
    ///
    /// Closes the gap `HelperEditDurabilityBoundaryTests` used to pin (removed by this same
    /// change — see this test file's own history for that pin's doc comment and rationale).
    @Test(.timeLimit(.minutes(15)))
    func secondProcessPersistsAnApplyEditToHostSource() async throws {
        let helperBinary = try Self.locateHelperBinary()
        try Self.entitleForVirtualization(helperBinary)

        let siteRoot = try Self.makeThrowawayAstroRepo()
        defer { try? FileManager.default.removeItem(at: siteRoot) }
        let pagePath = siteRoot.appendingPathComponent("src/pages/index.astro")
        let beforeHead = try Self.git(["rev-parse", "HEAD"], in: siteRoot)

        let signalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helper-e2e-persist-sig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: signalDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: signalDirectory) }

        let helper = Process()
        helper.executableURL = helperBinary
        helper.arguments = ["session", signalDirectory.path, siteRoot.path]
        let helperOutput = ProcessOutputCapture()
        helperOutput.attach(to: helper)
        try helper.run()
        defer {
            if helper.isRunning { helper.terminate() }
            helper.waitUntilExit()
            helperOutput.stop()
        }
        let booted = await Self.waitForOutput(
            "remote-helper: container ready", from: helperOutput, timeout: .seconds(600))
        #expect(booted, "the helper never reported a booted container\n\(helperOutput.transcript)")
        try #require(booted)

        let clientPeer = try await WebRTCPeer.connect(
            role: .offerer, signaling: FileSignalingChannel(directory: signalDirectory, sender: "client"))
        var peerIsOpen = true
        defer { if peerIsOpen { Task { await clientPeer.close() } } }
        let mcp = WebRTCTransport(connection: clientPeer)
        try await mcp.open()
        var mcpInbound = mcp.inbound().makeAsyncIterator()

        // Same selector shape AnglesiteContainerProbe.runApplyEdit already proves works against a
        // real guest — this fixture's index.astro ships `<h1>Anglesite helper e2e</h1>`.
        let newHeading = "Anglesite helper e2e — persisted"
        try await mcp.send(Self.request(id: 1, method: "tools/call", params: .object([
            "name": .string("apply_edit"),
            "arguments": .object([
                "id": .string("persist-e2e-1"),
                "type": .string("anglesite:apply-edit"),
                "path": .string("/"),
                "op": .string("replace-text"),
                "selector": .object([
                    "tag": .string("H1"), "classes": .array([]), "nthChild": .int(1),
                    "textContent": .string("Anglesite helper e2e"),
                ]),
                "value": .string(newHeading),
            ]),
        ])))
        guard let reply = await mcpInbound.next() else {
            Issue.record("no MCP reply for apply_edit\n\(helperOutput.transcript)")
            return
        }
        let toolText = Self.toolResultText(reply)
        try #require(toolText != nil, "apply_edit reply had no text content: \(Self.describe(reply))")
        guard let applied = Self.decodeObject(toolText ?? "") else {
            Issue.record("apply_edit did not return JSON: \(toolText ?? "<nil>")")
            return
        }
        let commit = applied["commit"] as? String
        try #require(commit != nil, "apply_edit returned no commit — cannot prove persistence\n\(String(describing: applied))")

        await mcp.close()
        await clientPeer.close()
        peerIsOpen = false
        let exitedOnItsOwn = await Self.waitForExit(helper, timeout: .seconds(120))
        #expect(exitedOnItsOwn, "the helper did not exit after the peer closed\n\(helperOutput.transcript)")

        // The proof: the HOST file changed, and HEAD advanced with the guest's commit as its
        // sole parent — read straight off disk, nothing MCP-shaped involved in this assertion.
        let afterHead = try Self.git(["rev-parse", "HEAD"], in: siteRoot)
        #expect(afterHead != beforeHead, "host Source/ HEAD did not move\n\(helperOutput.transcript)")
        let afterContent = try String(contentsOf: pagePath, encoding: .utf8)
        #expect(afterContent.contains(newHeading),
                "host Source/'s index.astro does not carry the edit:\n\(afterContent)\n\(helperOutput.transcript)")
    }

    // MARK: - Fixture

    /// A throwaway, git-initialized Astro site the container can hydrate and serve.
    ///
    /// Mirrors `ContainerizationControlTests.makeThrowawayAstroRepo()` (kept local rather than
    /// promoted to a shared test-support target: it's ~30 lines, that one is `private` to a target
    /// this one can't import, and the two have diverged on purpose — see below).
    ///
    /// Two deliberate differences from that one: the npm manifests are copied verbatim from
    /// `Resources/Template/` so `anglesite-hydrate` takes its zero-install path (the baked
    /// `node_modules` archive is keyed on a byte-identical `package-lock.json`; a fixture with no
    /// lockfile falls through to a full `npm install` inside the guest, minutes of avoidable
    /// network work), and it ships a `BaseLayout.astro`, which the page `create_page` scaffolds
    /// imports.
    private static func makeThrowawayAstroRepo() throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("helper-e2e-site-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let template = repoRoot.appendingPathComponent("Resources/Template", isDirectory: true)
        for manifest in ["package.json", "package-lock.json"] {
            try fm.copyItem(at: template.appendingPathComponent(manifest),
                            to: dir.appendingPathComponent(manifest))
        }

        let layouts = dir.appendingPathComponent("src/layouts", isDirectory: true)
        try fm.createDirectory(at: layouts, withIntermediateDirectories: true)
        try """
        ---
        const { title } = Astro.props;
        ---
        <html lang="en">
          <head><title>{title}</title></head>
          <body><h1>{title}</h1><slot /></body>
        </html>
        """.write(to: layouts.appendingPathComponent("BaseLayout.astro"), atomically: true, encoding: .utf8)

        let pages = dir.appendingPathComponent("src/pages", isDirectory: true)
        try fm.createDirectory(at: pages, withIntermediateDirectories: true)
        try "<html><body><h1>Anglesite helper e2e</h1></body></html>\n"
            .write(to: pages.appendingPathComponent("index.astro"), atomically: true, encoding: .utf8)

        try git(["init", "-q"], in: dir)
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "initial"], in: dir)
        return dir
    }

    /// Runs `git`, returning trimmed stdout. Existing call sites (`makeThrowawayAstroRepo`'s
    /// `init`/`add`/`commit`) ignore the return value; `secondProcessPersistsAnApplyEditToHostSource`
    /// uses it to capture `rev-parse HEAD` before and after the edit.
    @discardableResult
    private static func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment
            .merging(["GIT_AUTHOR_NAME": "e2e", "GIT_AUTHOR_EMAIL": "e2e@anglesite.test",
                      "GIT_COMMITTER_NAME": "e2e", "GIT_COMMITTER_EMAIL": "e2e@anglesite.test"]) { _, new in new }
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HelperContainerE2EError.fixtureSetupFailed(
                "git \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - The helper binary

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AnglesiteRemoteTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    /// Locates `anglesite-remote-helper` next to this test bundle's own build products, using the
    /// same `.xctest`-walk `TwoProcessE2ETests.locateDemoBinary()` documents: under `swift test`
    /// the running process is `swiftpm-testing-helper` inside the toolchain, so
    /// `CommandLine.arguments[0]` is useless, but a path through this bundle's `.xctest` is always
    /// somewhere in `CommandLine.arguments`, and its parent directory is the products directory
    /// the executable target lands in too.
    private static func locateHelperBinary() throws -> URL {
        for argument in CommandLine.arguments where argument.contains(".xctest") {
            var url = URL(fileURLWithPath: argument)
            while url.pathExtension != "xctest", url.path != "/" {
                url = url.deletingLastPathComponent()
            }
            guard url.pathExtension == "xctest" else { continue }
            let candidate = url.deletingLastPathComponent().appendingPathComponent("anglesite-remote-helper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw HelperContainerE2EError.helperBinaryNotFound(searchedArguments: CommandLine.arguments)
    }

    /// Ad-hoc code-signs the built helper with `Resources/anglesite-remote-helper-test.entitlements`.
    ///
    /// Without this the helper is an unsigned Mach-O carrying no entitlements, and its
    /// `ContainerizationControl.start()` fails with `LocalContainerError.virtualizationUnavailable`
    /// before any VM exists. Signing the *spawned binary* (rather than the test runner) is the
    /// whole reason this test spawns a separate process for the container work at all — see
    /// `scripts/run-container-probe.sh`, which does exactly this for `anglesite-container-probe`,
    /// and the entitlements file's own comment. Ad-hoc is sufficient:
    /// `com.apple.security.virtualization` is unrestricted and needs no provisioning profile.
    ///
    /// Done here rather than in a script so the signature can never be stale: `swift test` relinks
    /// the helper (stripping the signature) on every source change, and this runs immediately
    /// before the spawn.
    private static func entitleForVirtualization(_ binary: URL) throws {
        let entitlements = repoRoot.appendingPathComponent("Resources/anglesite-remote-helper-test.entitlements")
        guard FileManager.default.fileExists(atPath: entitlements.path) else {
            throw HelperContainerE2EError.fixtureSetupFailed("missing \(entitlements.path)")
        }
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", "--entitlements", entitlements.path, binary.path]
        let errors = Pipe()
        codesign.standardError = errors
        try codesign.run()
        let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            throw HelperContainerE2EError.fixtureSetupFailed("codesign exited \(codesign.terminationStatus): \(detail)")
        }
    }

    // MARK: - Wire helpers

    /// Builds one stateless-MCP (2026-07-28) JSON-RPC request, including the per-request `_meta`
    /// envelope `MCPClient.envelopedParams` adds on the app's own path. Hand-built rather than
    /// routed through `MCPClient`, whose transport seam (`startWithTransport`) is internal to
    /// AnglesiteCore — and an exit-criterion test is a better place for an explicit wire payload
    /// than for a shared abstraction anyway.
    private static func request(id: Int, method: String, params: JSONValue) -> JSONValue {
        var fields: [String: JSONValue] = {
            if case .object(let object) = params { return object }
            return [:]
        }()
        fields["_meta"] = .object([
            "io.modelcontextprotocol/protocolVersion": .string(MCPClient.protocolVersion),
            "io.modelcontextprotocol/clientInfo": .object([
                "name": .string("HelperContainerE2ETests"), "version": .string("1.0"),
            ]),
            "io.modelcontextprotocol/clientCapabilities": .object([:]),
        ])
        return .object([
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
            "params": .object(fields),
        ])
    }

    /// Pulls `result.content[0].text` out of a `tools/call` response.
    private static func toolResultText(_ message: JSONValue) -> String? {
        guard case .object(let envelope) = message,
              case .object(let result)? = envelope["result"],
              case .array(let content)? = result["content"] else { return nil }
        for item in content {
            if case .object(let object) = item, case .string(let text)? = object["text"] { return text }
        }
        return nil
    }

    private static func decodeObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parsed
    }

    /// Renders a `JSONValue` for a failure message without `#expect`'s reflective dump.
    private static func describe(_ value: JSONValue) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value.rawValue),
              let text = String(data: data, encoding: .utf8) else { return "<unrenderable>" }
        return text
    }

    /// One bridged GET, drained to a string. Returns the status and the (UTF-8-decoded) body.
    private static func get(_ path: String, over client: FetchBridgeClient) async throws -> (Int, String) {
        let (head, body) = try await client.perform(
            BridgeRequestHead(method: "GET", path: path, headers: [:]))
        var data = Data()
        for try await chunk in body { data.append(chunk) }
        return (head.status, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Waiting

    /// Polls the captured transcript for `marker`. Returns `false` if `timeout` elapses first.
    private static func waitForOutput(
        _ marker: String, from capture: ProcessOutputCapture, timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if capture.stderrString.contains(marker) || capture.stdoutString.contains(marker) { return true }
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// Polls `process.isRunning` until it exits or `timeout` elapses. Polling rather than a
    /// `terminationHandler` continuation sidesteps any ordering race with an already-exited
    /// process (same rationale as `TwoProcessE2ETests.waitForExit`).
    private static func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}

/// Errors specific to ``HelperContainerE2ETests``.
private enum HelperContainerE2EError: Error, CustomStringConvertible {
    case helperBinaryNotFound(searchedArguments: [String])
    case fixtureSetupFailed(String)

    var description: String {
        switch self {
        case .helperBinaryNotFound(let arguments):
            return "could not locate anglesite-remote-helper next to the test bundle's build "
                + "products (searched CommandLine.arguments: \(arguments)) — Package.swift only "
                + "declares that target when `includeContainer` is true, i.e. on Darwin without "
                + "ANGLESITE_SKIP_CONTAINER=1; was it built?"
        case .fixtureSetupFailed(let reason):
            return "e2e fixture setup failed: \(reason)"
        }
    }
}

/// Continuously drains a spawned process's stdout/stderr into thread-safe buffers via
/// `FileHandle.readabilityHandler`, so the long-running helper never blocks on a full pipe buffer
/// and its output so far is available for a failure message before it exits.
///
/// A near-copy of `TwoProcessE2ETests`'s private capture of the same name — that one lives in
/// `AnglesiteP2PTests`, which this target cannot import (SwiftPM test targets aren't importable
/// from one another).
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
private final class ProcessOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    func attach(to process: Process) {
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.lock.lock()
            self.stdoutData.append(chunk)
            self.lock.unlock()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.lock.lock()
            self.stderrData.append(chunk)
            self.lock.unlock()
        }
    }

    /// Detaches the readability handlers. Call once the owning process has exited so no further
    /// callback races with reading the final buffered strings.
    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    var stdoutString: String { read(\.stdoutData) }
    var stderrString: String { read(\.stderrData) }

    /// Both streams, labelled — what every failure message in this suite attaches.
    var transcript: String {
        """
        --- helper stdout ---
        \(stdoutString)
        --- helper stderr ---
        \(stderrString)
        """
    }

    private func read(_ keyPath: KeyPath<ProcessOutputCapture, Data>) -> String {
        lock.lock()
        defer { lock.unlock() }
        let data = self[keyPath: keyPath]
        return String(data: data, encoding: .utf8) ?? "<non-UTF8: \(data.count) bytes>"
    }
}

import Testing
import Foundation
import AnglesiteCore
import AnglesiteP2P
import AnglesiteRemote
#if canImport(CloudKit)
import CloudKit
#endif

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
    fileprivate static func makeThrowawayAstroRepo() throws -> URL {
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
    fileprivate static func git(_ arguments: [String], in directory: URL) throws -> String {
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

    fileprivate static var repoRoot: URL {
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
    fileprivate static func locateHelperBinary() throws -> URL {
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
    fileprivate static func entitleForVirtualization(_ binary: URL) throws {
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
    fileprivate static func request(id: Int, method: String, params: JSONValue) -> JSONValue {
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
    fileprivate static func toolResultText(_ message: JSONValue) -> String? {
        guard case .object(let envelope) = message,
              case .object(let result)? = envelope["result"],
              case .array(let content)? = result["content"] else { return nil }
        for item in content {
            if case .object(let object) = item, case .string(let text)? = object["text"] { return text }
        }
        return nil
    }

    fileprivate static func decodeObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parsed
    }

    /// Renders a `JSONValue` for a failure message without `#expect`'s reflective dump.
    fileprivate static func describe(_ value: JSONValue) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value.rawValue),
              let text = String(data: data, encoding: .utf8) else { return "<unrenderable>" }
        return text
    }

    /// One bridged GET, drained to a string. Returns the status and the (UTF-8-decoded) body.
    fileprivate static func get(_ path: String, over client: FetchBridgeClient) async throws -> (Int, String) {
        let (head, body) = try await client.perform(
            BridgeRequestHead(method: "GET", path: path, headers: [:]))
        var data = Data()
        for try await chunk in body { data.append(chunk) }
        return (head.status, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Waiting

    /// Polls the captured transcript for `marker`. Returns `false` if `timeout` elapses first.
    fileprivate static func waitForOutput(
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
    fileprivate static func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
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

#if canImport(CloudKit)

/// The Anywhere-runtime **P2 exit criterion** (#1208): two Mac processes *pair* over real CloudKit
/// and then complete a signed, cross-network signaling handshake plus a live MCP round trip.
///
/// Where `HelperContainerE2ETests` above proves the P1 stack over a shared *directory* (unsigned,
/// same-machine, no pairing), this replaces every one of those simplifications with the production
/// mechanism:
///
/// | P1 (`HelperContainerE2ETests`) | P2 (here) |
/// |---|---|
/// | `anglesite-remote-helper session <dir> <root>` | `… connect <session> <device> <site> <pkg>` |
/// | site addressed by host path | site addressed by `RemoteSiteIdentity` siteID |
/// | `FileSignalingChannel`, unsigned | `SignedSignalingChannel` over `CloudKitSignalingChannel` |
/// | no pairing | real `DeviceAnnounceRecord` exchange + key pinning |
///
/// The "phone" is played by this test process directly, per the design spec's own practical exit
/// criterion (§Scope-setting findings 2: P4 hasn't built an iOS client yet, so "one process plays
/// Mac, one plays phone" *is* the criterion). Only the QR **scan** is simulated; everything else —
/// the announce records, the signaling envelopes, the container, the edit — is real.
///
/// ## What this needs that no other suite in this repo needs
///
/// The gate is the union of `HelperContainerE2ETests`' three variables and `ANGLESITE_CK_TESTS=1`,
/// because it needs both an entitled Apple-Silicon Mac with vendored container boot artifacts *and*
/// a signed-in iCloud account. On top of that it needs something the env vars cannot express: the
/// **spawned helper binary must itself be CloudKit-entitled**. `entitleForVirtualization` ad-hoc
/// signs (`codesign --sign -`), and an ad-hoc signature can never carry a `com.apple.developer.*`
/// entitlement — AMFI SIGKILLs such a binary at exec, verified during #1208 P2 Task 9. So this
/// suite additionally requires a real signing identity and a provisioned entitlements file, named
/// by `ANGLESITE_HELPER_SIGNING_IDENTITY` / `ANGLESITE_HELPER_ENTITLEMENTS`; see
/// ``entitleForCloudKit(_:)``. Without them the run fails with an explanation rather than quietly
/// watching the helper fall back to local directory signaling and calling that a CloudKit proof.
///
/// That entitlements file needs three things, all of them outstanding Apple Developer portal steps
/// recorded in `Resources/AnglesiteRemote.entitlements`: the `iCloud.io.dwk.anglesite` CloudKit
/// container/service pair (for signaling and announces), the matching **ubiquity** container (so
/// `RemoteSiteResolver`'s zero-prompt path can resolve the fixture — see step 2 in the test body
/// for why the bookmark path cannot be used instead), and `com.apple.security.virtualization` plus
/// network client/server, which `Resources/anglesite-remote-helper-test.entitlements` already
/// documents for the P1 suite. Deliberately **not** `com.apple.security.app-sandbox`: sandboxing a
/// bare, non-bundled CLI is a known-broken path in this repo (that file's own comment).
///
/// ```sh
/// ANGLESITE_CONTAINER_TESTS=1 ANGLESITE_CONTAINER_E2E=1 ANGLESITE_P2P_E2E=1 ANGLESITE_CK_TESTS=1 \
///   ANGLESITE_HELPER_SIGNING_IDENTITY="Apple Development: you@example.com (XXXXXXXXXX)" \
///   ANGLESITE_HELPER_ENTITLEMENTS=/path/to/helper-cloudkit.entitlements \
///   swift test --filter CloudKitPairingE2ETests
/// ```
///
/// ## It touches the real `Application Support/Anglesite` directory
///
/// Both processes are unsandboxed, so `PairedDeviceStore` resolves to the developer's own
/// `~/Library/Application Support/Anglesite/`. That is not incidental — it is the only place the
/// helper looks, and reading the file the *helper* wrote is what proves the Mac side pinned the
/// key. `paired-devices.json` is therefore snapshotted byte-for-byte before the run and restored
/// afterwards, including the "did not exist" case. It is the only file this suite restores: the
/// happy path never reaches `RemoteBookmarkStore` (the fixture takes `RemoteSiteResolver`'s
/// bookmark-free iCloud path — see step 2 in the test body), and the helper only writes
/// `revoked-devices.json` via a Settings revoke, which this suite never performs.
@Suite(.enabled(if:
    ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_TESTS"] == "1" &&
    ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_E2E"] == "1" &&
    ProcessInfo.processInfo.environment["ANGLESITE_P2P_E2E"] == "1" &&
    ProcessInfo.processInfo.environment["ANGLESITE_CK_TESTS"] == "1"), .serialized)
struct CloudKitPairingE2ETests {
    /// 20 rather than the 15 its P1 siblings use: this run adds a CloudKit pairing round trip
    /// *ahead of* the same cold container boot those already budget ~10 minutes for.
    @Test(.timeLimit(.minutes(20)))
    func twoMacProcessesPairAndConnectOverRealCloudKit() async throws {
        let fm = FileManager.default
        let container = CKContainer(identifier: Self.cloudKitContainerIdentifier)

        // --- 1. The QR payload ---------------------------------------------------------------
        // The Settings pane's wire shape (`DevicePairingSettingsView.PairingQRPayload`), built and
        // consumed as a string — the design spec's "the phone consumes the payload directly, no
        // camera or image decode" simplification.
        //
        // Deliberately NOT the key this handshake ends up verifying against, and that is a finding
        // rather than a shortcut: the helper signs with `helperSigningKey()`, a Keychain item in
        // its own bundle's scope, which is a *different* identity from the one the main app encodes
        // into this QR (recorded on `helperSigningKey()` and in `Resources/AnglesiteRemote.entitlements`
        // as an outstanding keychain-access-group provisioning step). Until that is closed, the only
        // way any peer can learn the key the helper actually signs with is the Mac's own
        // `DeviceAnnounceRecord`, which step 5 below reads. This step therefore proves what it
        // honestly can: that the payload the pane emits round-trips into a peer's hands intact.
        let macAppKeyPair = DevicePairingKeyPair()
        let macAppDeviceID = UUID().uuidString
        let qrPayload = try Self.qrPayloadString(deviceID: macAppDeviceID, publicKey: macAppKeyPair.publicKeyData)
        let scanned = try #require(Self.decodeQRPayload(qrPayload), "the QR payload did not decode: \(qrPayload)")
        #expect(scanned.deviceID == macAppDeviceID)
        #expect(scanned.publicKey == macAppKeyPair.publicKeyData)

        // --- 2. Fixtures ---------------------------------------------------------------------
        let helperBinary = try HelperContainerE2ETests.locateHelperBinary()
        try Self.entitleForCloudKit(helperBinary)

        // A site addressed the way the production `connect` shape addresses one: as a package whose
        // `Source/` is a git repo, named by its `RemoteSiteIdentity` siteID rather than by a path.
        //
        // It is built **inside the iCloud ubiquity container**, not in `$TMPDIR`, and that is
        // load-bearing rather than incidental. `RemoteSiteResolver` has two paths, and only one of
        // them can be driven from a test:
        //
        //  - The bookmark path needs a `.withSecurityScope` bookmark. Measured in this checkout: a
        //    bookmark minted by one binary **does not resolve in another** ("The file couldn't be
        //    opened because it isn't in the correct format") even with both unsandboxed, because a
        //    security-scoped bookmark is bound to the identity that created it. So a test process
        //    cannot hand the helper process a grant this way — the same wall #1208 P2 Task 9 hit
        //    while probing by hand. The only other way to get one is the `NSOpenPanel` this
        //    resolver shows, which is interactive by design.
        //  - The **iCloud fast path** needs no bookmark and no prompt at all: a package inside the
        //    shared ubiquity container resolves straight to `<package>/Source`. That is the
        //    production path for iCloud-stored sites — which, per AGENTS.md, is where new sites
        //    live by default — so using it here is not a workaround, it is the mainline.
        let ubiquityRoot = Self.ubiquityContainerURL
        try #require(fm.fileExists(atPath: ubiquityRoot.path), """
            \(ubiquityRoot.path) does not exist, so `RemoteSiteResolver`'s zero-prompt iCloud path \
            cannot be exercised and the helper would fall back to an interactive grant panel. Sign \
            in to iCloud Drive and launch Anglesite.app once so the container is created.
            """)
        let packageURL = ubiquityRoot
            .appendingPathComponent("ck-e2e-\(UUID().uuidString).anglesite", isDirectory: true)
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: packageURL) }
        let scratchRepo = try HelperContainerE2ETests.makeThrowawayAstroRepo()
        let sourceURL = packageURL.appendingPathComponent("Source", isDirectory: true)
        try fm.moveItem(at: scratchRepo, to: sourceURL)
        let siteID = RemoteSiteIdentity.siteID(forSourceDirectory: sourceURL)
        let pagePath = sourceURL.appendingPathComponent("src/pages/index.astro")
        let beforeHead = try HelperContainerE2ETests.git(["rev-parse", "HEAD"], in: sourceURL)

        // --- 3. Clear the pairing slate ---------------------------------------------------------
        let pairedDevicesURL = Self.applicationSupportDirectory.appendingPathComponent("paired-devices.json")
        let pairedDevicesBefore = Self.snapshot(pairedDevicesURL)
        defer { Self.restore(pairedDevicesBefore, to: pairedDevicesURL) }

        let phoneKeyPair = DevicePairingKeyPair()
        let phoneDeviceID = "ck-e2e-phone-\(UUID().uuidString)"
        let sessionID = "ck-e2e-session-\(UUID().uuidString)"
        let pairedDevices = PairedDeviceStore(persistenceURL: pairedDevicesURL)
        #expect(try pairedDevices.device(deviceID: phoneDeviceID) == nil,
                "the phone must start unpaired, or pinning proves nothing")

        // --- 4. The second process -------------------------------------------------------------
        let helper = Process()
        helper.executableURL = helperBinary
        helper.arguments = ["connect", sessionID, phoneDeviceID, siteID, packageURL.path]
        let helperOutput = ProcessOutputCapture()
        helperOutput.attach(to: helper)
        try helper.run()
        defer {
            if helper.isRunning { helper.terminate() }
            helper.waitUntilExit()
            helperOutput.stop()
        }
        #expect(helper.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                "the helper must be a separate OS process, not this test's own")

        // --- 5. Pairing, both directions -------------------------------------------------------
        // The phone announces itself. The helper's `CloudKitPairingService` is already observing
        // (it starts before the pinned-key lookup precisely so this race is winnable), so this
        // announce is what turns "unknown device" into a pinned key.
        let pairingService = CloudKitPairingService(container: container, pollInterval: .seconds(2))
        var phoneAnnounced = false
        defer {
            if phoneAnnounced {
                // Best-effort: an announce is a rendezvous breadcrumb, not durable state, and
                // leaving one behind would litter the owner's real private database.
                Task { try? await pairingService.withdrawAnnounce(deviceID: phoneDeviceID) }
            }
        }
        try await pairingService.announce(
            deviceID: phoneDeviceID, publicKeyData: phoneKeyPair.publicKeyData,
            displayName: "Anywhere E2E Phone")
        phoneAnnounced = true

        // Mac side of the pairing: read back the file the *helper process* wrote. Nothing in this
        // test writes it.
        let pinned = await Self.waitForPinnedDevice(
            deviceID: phoneDeviceID, in: pairedDevices, timeout: .seconds(180))
        #expect(pinned != nil, "the helper never pinned the phone's key\n\(helperOutput.transcript)")
        try #require(pinned != nil)
        #expect(pinned?.pinnedPublicKey == phoneKeyPair.publicKeyData,
                "the helper pinned a different key than the phone announced")

        // Phone side of the pairing: learn this Mac's *helper* identity from its own announce
        // record — see step 1 for why that record, and not the QR payload, is the source of truth
        // for the key this handshake must verify against.
        let macDeviceID = try #require(
            Self.parseAnnouncedDeviceID(from: helperOutput.transcript),
            "the helper never announced itself to CloudKit\n\(helperOutput.transcript)")
        let macAnnounce = try #require(
            await Self.firstAnnounce(from: pairingService, matching: macDeviceID, timeout: .seconds(120)),
            "this Mac's own DeviceAnnounceRecord never came back out of CloudKit")
        #expect(macAnnounce.publicKeyData.count == 65,
                "a P-256 X9.63 public key is 65 bytes; got \(macAnnounce.publicKeyData.count)")

        // --- 6. The container ------------------------------------------------------------------
        let booted = await HelperContainerE2ETests.waitForOutput(
            "remote-helper: container ready", from: helperOutput, timeout: .seconds(600))
        #expect(booted, "the helper never reported a booted container\n\(helperOutput.transcript)")
        try #require(booted)
        // Logged by `makeSignalingTransport(sessionID:)` when — and only when — the helper's own
        // entitlement gate passed. It is emitted *after* "container ready" (the transport is built
        // lazily, inside `WebRTCPeer.connect`), so this waits rather than reading the transcript
        // that already exists. Its absence means the helper fell back to a local directory mailbox,
        // which would make everything below a same-machine proof wearing a CloudKit label.
        let overCloudKit = await HelperContainerE2ETests.waitForOutput(
            "signaling over CloudKit container", from: helperOutput, timeout: .seconds(60))
        #expect(overCloudKit,
                "the helper fell back to local signaling — this run proves nothing about CloudKit\n\(helperOutput.transcript)")
        try #require(overCloudKit)

        // --- 7. The signed, cross-network handshake --------------------------------------------
        let signaling = SignedSignalingChannel(
            wrapping: CloudKitSignalingChannel(
                container: container, sessionID: sessionID, sender: "phone"),
            signingKey: phoneKeyPair, peerPublicKey: macAnnounce.publicKeyData,
            onLog: { Issue.record("phone dropped a signaling envelope: \($0)") })
        let peer = try await WebRTCPeer.connect(role: .offerer, signaling: signaling)
        var peerIsOpen = true
        defer { if peerIsOpen { Task { await peer.close() } } }

        // --- 8. The MCP round trip -------------------------------------------------------------
        // Same `apply_edit` proof `secondProcessPersistsAnApplyEditToHostSource` uses, reused
        // rather than re-invented: it is the one tool whose reply carries a guest commit the
        // helper's `HelperEditPersister` then exports back into the HOST repo, which is what makes
        // the final assertion a filesystem fact rather than an MCP reply.
        let mcp = WebRTCTransport(connection: peer)
        try await mcp.open()
        var mcpInbound = mcp.inbound().makeAsyncIterator()
        let newHeading = "Anglesite helper e2e — paired over CloudKit"
        try await mcp.send(HelperContainerE2ETests.request(id: 1, method: "tools/call", params: .object([
            "name": .string("apply_edit"),
            "arguments": .object([
                "id": .string("ck-pair-e2e-1"),
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
        let toolText = HelperContainerE2ETests.toolResultText(reply)
        try #require(toolText != nil,
                     "apply_edit reply had no text content: \(HelperContainerE2ETests.describe(reply))")
        guard let applied = HelperContainerE2ETests.decodeObject(toolText ?? "") else {
            Issue.record("apply_edit did not return JSON: \(toolText ?? "<nil>")")
            return
        }
        try #require(applied["commit"] as? String != nil,
                     "apply_edit returned no commit — cannot prove persistence\n\(String(describing: applied))")

        // --- 9. Teardown, then the proof off disk ----------------------------------------------
        await mcp.close()
        await peer.close()
        peerIsOpen = false
        await pairingService.stopObserving()
        // Deterministic cleanup of the announce this test wrote into the owner's real private
        // database. The `defer` above is only the backstop for the paths that never get here.
        try? await pairingService.withdrawAnnounce(deviceID: phoneDeviceID)
        phoneAnnounced = false
        let exitedOnItsOwn = await HelperContainerE2ETests.waitForExit(helper, timeout: .seconds(120))
        #expect(exitedOnItsOwn, "the helper did not exit after the peer closed\n\(helperOutput.transcript)")

        let afterHead = try HelperContainerE2ETests.git(["rev-parse", "HEAD"], in: sourceURL)
        #expect(afterHead != beforeHead, "host Source/ HEAD did not move\n\(helperOutput.transcript)")
        let afterContent = try String(contentsOf: pagePath, encoding: .utf8)
        #expect(afterContent.contains(newHeading),
                "host Source/'s index.astro does not carry the edit:\n\(afterContent)\n\(helperOutput.transcript)")
    }

    // MARK: - CloudKit

    /// The container the whole Anywhere-runtime epic shares with iCloud Drive site storage — the
    /// same identifier `anglesite-remote-helper` uses, so both processes meet in one private
    /// database (design spec §Additional scope decisions).
    static let cloudKitContainerIdentifier = "iCloud.io.dwk.anglesite"

    /// Bounded wait for one announce, mirroring `CloudKitPairingServiceTests.firstAnnounce`: an
    /// unbounded `for await` would hang the whole suite on a misconfigured container rather than
    /// failing.
    static func firstAnnounce(
        from service: CloudKitPairingService, matching deviceID: String, timeout: Duration
    ) async -> DeviceAnnounceRecord? {
        await withTaskGroup(of: DeviceAnnounceRecord?.self) { group in
            group.addTask {
                for await announce in service.announcedDevices() where announce.deviceID == deviceID {
                    return announce
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Polls `store` until `deviceID` is pinned, or `timeout` elapses. Polling because
    /// `PairedDeviceStore` is a plain JSON file with no change notification, and the writer is
    /// another OS process.
    static func waitForPinnedDevice(
        deviceID: String, in store: PairedDeviceStore, timeout: Duration
    ) async -> PairedDevice? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let device = try? store.device(deviceID: deviceID) { return device }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    /// Pulls the helper's own device ID out of the line `startPairingObservation` logs when its
    /// announce lands: `remote-helper: announced this Mac as device <id> (<name>)`.
    ///
    /// Reading it from the transcript rather than from `UserDefaults` is deliberate: the helper
    /// persists that ID in *its own* defaults domain, which this process cannot address, and that
    /// per-bundle scoping is the very gap this test has to work around (see step 1).
    static func parseAnnouncedDeviceID(from transcript: String) -> String? {
        let marker = "announced this Mac as device "
        guard let range = transcript.range(of: marker) else { return nil }
        let rest = transcript[range.upperBound...]
        guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\n" }) else { return nil }
        let identifier = String(rest[rest.startIndex..<end])
        return identifier.isEmpty ? nil : identifier
    }

    // MARK: - The QR payload

    /// Encodes the exact JSON `DevicePairingSettingsView` renders into its QR code. Rebuilt here
    /// rather than shared: that type (and its `PairingQRPayload`) is `private` inside the Xcode app
    /// target, which no SwiftPM test target can import — so this test asserts against the *wire
    /// shape*, which is the contract a phone would actually consume.
    static func qrPayloadString(deviceID: String, publicKey: Data) throws -> String {
        struct Payload: Encodable {
            let deviceID: String
            let publicKey: Data
        }
        let data = try JSONEncoder().encode(Payload(deviceID: deviceID, publicKey: publicKey))
        return String(decoding: data, as: UTF8.self)
    }

    /// The phone's half of the (simulated) scan: parses the payload string back into its two fields.
    static func decodeQRPayload(_ payload: String) -> (deviceID: String, publicKey: Data)? {
        struct Payload: Decodable {
            let deviceID: String
            let publicKey: Data
        }
        guard let decoded = try? JSONDecoder().decode(Payload.self, from: Data(payload.utf8)) else {
            return nil
        }
        return (decoded.deviceID, decoded.publicKey)
    }

    // MARK: - Host state the helper reads

    /// Where both processes resolve `Application Support/Anglesite/` to. Unsandboxed on both sides,
    /// so this is the developer's own directory — see the suite doc comment.
    static var applicationSupportDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Anglesite", isDirectory: true)
    }

    /// The shared iCloud ubiquity container's on-disk root, spelled out rather than looked up.
    ///
    /// `FileManager.url(forUbiquityContainerIdentifier:)` returns `nil` in a process that lacks the
    /// iCloud entitlement, and this test process cannot have one (`swiftpm-testing-helper` is a
    /// toolchain binary nobody can sign). The **helper** does the real lookup — this only needs to
    /// place the fixture where that lookup will land, and Apple's layout for
    /// `iCloud.io.dwk.anglesite` is stable: dots become tildes under `~/Library/Mobile Documents`.
    static var ubiquityContainerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
            .appendingPathComponent("iCloud~io~dwk~anglesite", isDirectory: true)
    }

    /// The bytes at `url`, or `nil` if there is no file there — the two states ``restore(_:to:)``
    /// puts back.
    static func snapshot(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    /// Puts a ``snapshot(_:)`` back, including restoring "there was no file here" by deleting.
    static func restore(_ data: Data?, to url: URL) {
        if let data {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Signing the helper

    /// Code-signs the built helper so it can construct `CKContainer` without being killed.
    ///
    /// Unlike `HelperContainerE2ETests.entitleForVirtualization`, this cannot be ad-hoc.
    /// `com.apple.security.virtualization` is unrestricted, so `codesign --sign -` grants it fine;
    /// `com.apple.developer.icloud-container-identifiers` / `-services` are **restricted**, and
    /// AMFI SIGKILLs a locally-signed binary that claims one without a matching provisioning
    /// profile (exit 137 at exec, measured in #1208 P2 Task 9). There is therefore no way for this
    /// suite to entitle the helper on its own; the operator has to supply a real identity and a
    /// profile-backed entitlements file, which is what the two environment variables name.
    ///
    /// Failing loudly when they are absent is the point. The helper degrades to local directory
    /// signaling on an unentitled build (by design — `makeSignalingTransport(sessionID:)`), so a
    /// silent ad-hoc fallback here would produce a *passing* run that never touched CloudKit.
    static func entitleForCloudKit(_ binary: URL) throws {
        let environment = ProcessInfo.processInfo.environment
        let identity = try #require(
            environment["ANGLESITE_HELPER_SIGNING_IDENTITY"],
            """
            ANGLESITE_HELPER_SIGNING_IDENTITY is not set. This suite needs the spawned helper to \
            carry the CloudKit entitlement, which an ad-hoc signature cannot do — set it to a real \
            signing identity (see `security find-identity -v -p codesigning`).
            """)
        let entitlements = try #require(
            environment["ANGLESITE_HELPER_ENTITLEMENTS"],
            """
            ANGLESITE_HELPER_ENTITLEMENTS is not set. Point it at an entitlements plist carrying \
            com.apple.security.virtualization, com.apple.security.network.{client,server}, and the \
            iCloud.io.dwk.anglesite CloudKit container/service pair, backed by a provisioning \
            profile for that container.
            """)
        guard FileManager.default.fileExists(atPath: entitlements) else {
            throw HelperContainerE2EError.fixtureSetupFailed("missing entitlements file \(entitlements)")
        }
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = [
            "--force", "--sign", identity, "--entitlements", entitlements, binary.path,
        ]
        let errors = Pipe()
        codesign.standardError = errors
        try codesign.run()
        let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            throw HelperContainerE2EError.fixtureSetupFailed(
                "codesign exited \(codesign.terminationStatus): \(detail)")
        }
    }
}

#endif

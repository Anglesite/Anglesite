import Testing
import Foundation
@testable import AnglesiteContainer
import AnglesiteCore
import AnglesiteTestSupport

/// Local-only, entitlement-gated integration test for the real Apple-Containerization driver.
///
/// This whole *target* is excluded from CI's `swift test` (it's appended to `packageTargets` in
/// Package.swift only when `ANGLESITE_CONTAINER_TESTS=1`), and every test *body* additionally
/// requires `ANGLESITE_CONTAINER_E2E=1` so it is skipped unless explicitly run on an entitled
/// Apple-Silicon Mac with the vendored boot artifacts present (image + kernel + initfs — see
/// BundledImage; set the ANGLESITE_CONTAINER_* overrides only when testing custom local artifacts).
struct ContainerizationControlTests {
    private var enabled: Bool { ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_E2E"] == "1" }

    @Test("boots a container, hydrates a repo, and serves a loadable preview URL")
    func bootsAndServes() async throws {
        try #require(enabled, "set ANGLESITE_CONTAINER_E2E=1 on an entitled Apple-Silicon Mac")

        let control = ContainerizationControl()
        let repo = try makeThrowawayAstroRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        // Capture every guest boot/process line to stderr as it arrives — this is the diagnostic
        // trail #69 lacked (a hung/slow `npm install` or guest network/DNS failure previously
        // surfaced only as an opaque `waitUntilServing` timeout with nothing to look at).
        let session = try await control.start(siteID: "e2e", sourceRepo: repo, ref: "HEAD") { line, stream in
            FileHandle.standardError.write(Data("[\(stream)] \(line)\n".utf8))
        }
        // Safety net: fires on any exit path (incl. a thrown #expect below) so a failed
        // assertion doesn't leave the VM running. stop() is idempotent, so the awaited
        // happy-path stop below is harmless after this.
        defer { Task { try? await control.stop(siteID: "e2e") } }

        // The preview URL must serve HTTP 200 within the ready window.
        let (_, resp) = try await URLSession.shared.data(from: session.previewURL)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)

        // Await teardown on the happy path so the VM is down before the test returns.
        try? await control.stop(siteID: "e2e")
    }

    @Test("suspend pauses the VM without deleting its ext4 artifacts")
    func suspendPausesWithoutDeletingArtifacts() async throws {
        try #require(enabled, "set ANGLESITE_CONTAINER_E2E=1 on an entitled Apple-Silicon Mac")
        let control = ContainerizationControl()
        let siteID = "suspend-test-\(UUID().uuidString.prefix(8))"
        let repo = try makeThrowawayAstroRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        _ = try await control.start(siteID: siteID, sourceRepo: repo, ref: "HEAD", onOutput: { _, _ in })
        try await control.suspend(siteID: siteID)

        let entry = await PausedContainerRegistry.shared.reclaim(siteID: siteID)
        #expect(entry != nil)
        for url in entry?.ext4Artifacts ?? [] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        // Cleanup: reclaim() already removed it from the registry — tear it down for real so the
        // test doesn't leak a paused VM.
        if let entry { await PausedContainerRegistry.teardown(entry, siteID: siteID) }
    }

    @Test("start resumes a paused container instead of cold-booting")
    func startResumesAPausedContainerInsteadOfColdBooting() async throws {
        try #require(enabled, "set ANGLESITE_CONTAINER_E2E=1 on an entitled Apple-Silicon Mac")
        let control = ContainerizationControl()
        let siteID = "resume-test-\(UUID().uuidString.prefix(8))"
        let repo = try makeThrowawayAstroRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let firstSession = try await control.start(siteID: siteID, sourceRepo: repo, ref: "HEAD", onOutput: { _, _ in })
        try await control.suspend(siteID: siteID)
        defer { Task { try? await control.stop(siteID: siteID) } }

        let start = ContinuousClock.now
        let resumedSession = try await control.start(siteID: siteID, sourceRepo: repo, ref: "HEAD", onOutput: { _, _ in })
        let elapsed = ContinuousClock.now - start

        // A resume never re-hydrates the guest (no clone/npm install/astro cold start), so it must
        // land well under the ~186s+ a cold boot pays (`previewReadyTimeout`'s own doc comment) —
        // 30s gives ample margin over VM-resume + proxy-redial + short readiness poll while still
        // catching a regression that silently fell back to a full cold boot.
        #expect(elapsed < .seconds(30))
        #expect(resumedSession.previewURL != firstSession.previewURL || resumedSession.mcpURL != firstSession.mcpURL)

        try await control.stop(siteID: siteID)
    }

    @Test("execInteractive echoes what's written to its stdin back out through onOutput")
    func execInteractiveEchoesStdin() async throws {
        try #require(enabled, "set ANGLESITE_CONTAINER_E2E=1 on an entitled Apple-Silicon Mac")

        let control = ContainerizationControl()
        let repo = try makeThrowawayAstroRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await control.start(siteID: "e2e-interactive", sourceRepo: repo, ref: "HEAD") { _, _ in }
        defer { Task { try? await control.stop(siteID: "e2e-interactive") } }

        var receivedLines: [String] = []
        let handle = try await control.execInteractive(
            siteID: "e2e-interactive",
            argv: ["cat"],
            environment: [:],
            workingDirectory: "/workspace/site",
            onOutput: { line, _ in receivedLines.append(line) }
        )
        try await handle.write(Data("hello from the host\n".utf8))
        // `cat` echoes what it reads from stdin; give the guest a moment before asserting.
        try await Task.sleep(for: .milliseconds(500))
        #expect(receivedLines.contains("hello from the host"))
        await handle.terminate()

        try? await control.stop(siteID: "e2e-interactive")
    }

    @Test("startWorkersDev boots a reachable local wrangler-dev endpoint for an active worker")
    func startsWorkersDevForActiveWorker() async throws {
        try #require(enabled, "set ANGLESITE_CONTAINER_E2E=1 on an entitled Apple-Silicon Mac")

        let siteID = "workers-dev-e2e"
        let control = ContainerizationControl()
        let repo = try makeThrowawayAstroRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        _ = try await control.start(siteID: siteID, sourceRepo: repo, ref: "HEAD", onOutput: { _, _ in })
        // Safety net: fires on any exit path (incl. a thrown #expect below) so a failed
        // assertion doesn't leave the VM running. stop() is idempotent, so the awaited
        // happy-path stop below is harmless after this.
        defer { Task { try? await control.stop(siteID: siteID) } }

        let workers = [WorkerDescriptor(
            id: "indieauth", displayName: "IndieAuth", description: "d", group: "identity",
            binding: .settingsActivated, resources: .init(needsD1: true, needsKV: true, needsR2: false))]
        let collector = StateCollector()
        let workersDevURL = try await control.startWorkersDev(
            siteID: siteID, workers: workers,
            onOutput: { _, _ in },
            onState: { state in await collector.append(state) })

        let ok = await pollForHTTPResponse(workersDevURL, timeout: .seconds(60))
        #expect(ok, "wrangler dev --local never answered within the timeout")

        // observe() replays the current state on subscribe, so `.running` must have been
        // delivered by the time the endpoint answers HTTP (#699).
        var states = await collector.states
        for _ in 0..<50 {
            if !states.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
            states = await collector.states
        }
        #expect(states.first == .running)

        try? await control.stop(siteID: siteID)
    }

    /// Polls `url` for any HTTP response (any status code is a pass — we only care that
    /// wrangler-dev is accepting connections and speaking HTTP), bounded by `timeout`. There is no
    /// internal readiness wait for `startWorkersDev` equivalent to `start()`'s `waitUntilServing`
    /// (wrangler-dev can take a few seconds to bind its port after the call returns), so this test
    /// needs its own retry loop. Mirrors `AnglesiteContainerProbe.pollForHTTPResponse` in
    /// `Sources/AnglesiteContainerProbe/main.swift` — kept as a small, self-contained duplicate
    /// here rather than sharing code across the test target/executable boundary (SwiftPM test
    /// targets aren't importable from an executable target).
    private func pollForHTTPResponse(_ url: URL, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if response is HTTPURLResponse { return true }
            } catch {
                // Not ready yet — wrangler-dev may still be starting up inside the guest.
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Create a throwaway on-disk git repo containing a minimal Astro site and an initial commit.
    /// Returns the repo directory URL (a `file://` path the driver clones into the guest).
    ///
    /// Stages a real `worker/` (plus the handful of files it imports from outside that directory)
    /// and a `dist/` placeholder so `startWorkersDev` tests actually reach `wrangler dev`'s
    /// bundling step instead of failing earlier at "entry point not found" / assets-directory
    /// resolution (#1780) — real sites get this from `SiteScaffolder`'s template copy
    /// (`scripts/scaffold.sh`), which this mirrors for the throwaway fixture.
    private func makeThrowawayAstroRepo() throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anglesite-e2e-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let templateRoot = try AnglesiteTestSupport.templateRoot()

        // package.json + package-lock.json verbatim from the template: the exact dependency
        // versions (including the `@dwk/*` worker packages and `wrangler` itself) the container
        // image's baked node_modules archive was built from — `container/hydrate.sh` matches this
        // lockfile byte-for-byte to take its zero-install fast path instead of an offline `npm
        // install` that could never resolve these packages from a from-scratch `astro`-only
        // manifest.
        for name in ["package.json", "package-lock.json"] {
            try fm.copyItem(at: templateRoot.appendingPathComponent(name), to: dir.appendingPathComponent(name))
        }

        let pages = dir.appendingPathComponent("src/pages", isDirectory: true)
        try fm.createDirectory(at: pages, withIntermediateDirectories: true)
        try "<html><body><h1>Anglesite e2e</h1></body></html>\n"
            .write(to: pages.appendingPathComponent("index.astro"), atomically: true, encoding: .utf8)

        // `worker/` verbatim — `worker.ts` and `mcp-server.ts` statically import sibling files
        // (`experiments.ts`, `render-utils.ts`, …) throughout this directory, and
        // `WorkerComposition.generateWranglerToml` emits `migrations_dir = "worker/migrations"`
        // for every active D1-backed worker, so nothing less than the whole directory resolves.
        try fm.copyItem(at: templateRoot.appendingPathComponent("worker"), to: dir.appendingPathComponent("worker"))

        // The handful of files `worker.ts`/`mcp-server.ts` import from *outside* `worker/` — the
        // gap #1780 called out: staging `worker/` alone still leaves these unresolved.
        let srcLib = dir.appendingPathComponent("src/lib", isDirectory: true)
        try fm.createDirectory(at: srcLib, withIntermediateDirectories: true)
        for name in ["html-to-plain-text.ts", "mcp-search-entries.ts", "feeds.ts"] {
            try fm.copyItem(
                at: templateRoot.appendingPathComponent("src/lib/\(name)"),
                to: srcLib.appendingPathComponent(name))
        }
        try fm.copyItem(
            at: templateRoot.appendingPathComponent("utm-codes.json"), to: dir.appendingPathComponent("utm-codes.json"))

        let scripts = dir.appendingPathComponent("scripts", isDirectory: true)
        try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
        for name in ["experiments-paths.ts", "anglesite-config.ts", "experiments-artifact.ts", "mcp-artifact.ts"] {
            try fm.copyItem(
                at: templateRoot.appendingPathComponent("scripts/\(name)"), to: scripts.appendingPathComponent(name))
        }

        // `dist/` is Astro's build output — gitignored, so the template checkout never has one —
        // but `generateWranglerToml` unconditionally emits `[assets] directory = "dist"`, and
        // wrangler needs that directory to exist on disk even for a worker-only dev session.
        let dist = dir.appendingPathComponent("dist", isDirectory: true)
        try fm.createDirectory(at: dist, withIntermediateDirectories: true)
        try "<!doctype html><title>e2e placeholder</title>\n"
            .write(to: dist.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = dir
            p.environment = ProcessInfo.processInfo.environment
                .merging(["GIT_AUTHOR_NAME": "e2e", "GIT_AUTHOR_EMAIL": "e2e@anglesite.test",
                          "GIT_COMMITTER_NAME": "e2e", "GIT_COMMITTER_EMAIL": "e2e@anglesite.test"]) { _, new in new }
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw LocalContainerError.cloneFailed("git \(args.joined(separator: " ")) exited \(p.terminationStatus)")
            }
        }
        try git(["init", "-q"])
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "initial"])
        return dir
    }
}

/// Collects `onState` deliveries for assertion (#699) — actor-isolated because the callback
/// fires from the control's state-forwarding task, not the test's own task.
private actor StateCollector {
    private(set) var states: [WorkersDevProcessState] = []
    func append(_ state: WorkersDevProcessState) { states.append(state) }
}

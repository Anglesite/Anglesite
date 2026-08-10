// Real-podman integration test for PodmanContainerControl. Gated the same way
// ANGLESITE_CONTAINER_TESTS gates ContainerizationControlTests (cross-platform port design §9):
// never runs by default, opts in via an env var, and — being genuinely Linux/podman-only —
// compiles out entirely off Glibc platforms.
//
// Run locally with:
//   ANGLESITE_PODMAN_TESTS=1 swift test --filter PodmanContainerControlIntegrationTests
//
// Needs a `localhost/anglesite-podman-test:latest` image on the podman image store — a minimal
// alpine + git + python3 image (see the PR description for the Dockerfile) standing in for the
// real MCP-sidecar/Astro-baked production image, which isn't available outside the app's actual
// build pipeline. `astroCommand`/`mcpCommand` are swapped for `python3 -m http.server` fakes
// accordingly — this test exercises PodmanContainerControl's own orchestration (bind mount, exec-
// based process startup, port publishing, readiness polling, teardown), not the production guest
// toolchain.
#if canImport(Glibc)
import Testing
import Foundation
// URLSession/HTTPURLResponse live in FoundationNetworking on non-Darwin platforms
// (swift-corelibs-foundation); this file only ever builds on Glibc (see the gate above), but
// matches the rest of the codebase's canImport-gated form rather than an unconditional import.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AnglesiteCore

@Suite("PodmanContainerControl (real podman)")
struct PodmanContainerControlIntegrationTests {
    private static var podmanTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["ANGLESITE_PODMAN_TESTS"] == "1"
    }

    private func makeTempGitRepo() async throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anglesite-podman-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hello from anglesite podman test\n".write(
            to: dir.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let supervisor = ProcessSupervisor()
        for args in [
            ["init", "-q"],
            ["-c", "user.email=test@example.com", "-c", "user.name=Test", "add", "marker.txt"],
            ["-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-q", "-m", "initial"],
        ] {
            let result = try await supervisor.run(executable: git, arguments: args, currentDirectoryURL: dir)
            #expect(result.exitCode == 0, "git \(args) failed: \(result.stderr)")
        }
        return dir
    }

    private func makeControl() -> PodmanContainerControl {
        PodmanContainerControl(
            image: "localhost/anglesite-podman-test:latest",
            astroCommand: "cd /workspace/site && python3 -m http.server 4321 --bind 0.0.0.0",
            mcpCommand: "cd /workspace/site && python3 -m http.server 4399 --bind 0.0.0.0"
        )
    }

    @Test(
        "start() boots a real container, publishes ports, and both fake services answer over HTTP",
        .enabled(if: podmanTestsEnabled, "requires podman and the localhost/anglesite-podman-test:latest test image — set ANGLESITE_PODMAN_TESTS=1 to opt in")
    )
    func startBootsRealContainerAndPublishesPorts() async throws {
        let repo = try await makeTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let control = makeControl()
        let siteID = "integration-\(UUID().uuidString)"
        var lines: [String] = []
        let session = try await control.start(siteID: siteID, sourceRepo: repo, ref: "HEAD") { line, _ in
            lines.append(line)
        }
        defer { Task { try? await control.stop(siteID: siteID) } }

        #expect(session.previewURL.scheme == "http")
        #expect(session.mcpURL.path.hasSuffix("/mcp"))

        // start() already waited for the preview to serve; confirm both published ports actually
        // answer, and that the cloned repo's content made it into the container (python's
        // directory listing includes the cloned marker.txt).
        let (previewData, previewResponse) = try await URLSession.shared.data(from: session.previewURL)
        #expect((previewResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: previewData, encoding: .utf8)?.contains("marker.txt") == true)

        // mcpURL has "/mcp" appended (matching production's session.mcpURL contract); strip it
        // back off to hit the fake server's actual listen root.
        let mcpRoot = session.mcpURL.deletingLastPathComponent()
        let (_, mcpResponse) = try await URLSession.shared.data(from: mcpRoot)
        #expect((mcpResponse as? HTTPURLResponse)?.statusCode == 200)

        #expect(lines.contains { $0.contains("clone") || $0.lowercased().contains("cloning") })

        try await control.stop(siteID: siteID)

        // Teardown actually removed the container (--rm), not just stopped it.
        let psResult = try await ProcessSupervisor().run(
            executable: URL(fileURLWithPath: "/usr/bin/podman"),
            arguments: ["ps", "-a", "--filter", "name=\(PodmanContainerControl.containerName(for: siteID))", "--format", "{{.Names}}"]
        )
        #expect(psResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test(
        "start() fails with cloneFailed when sourceRepo has no .git directory",
        .enabled(if: podmanTestsEnabled, "requires podman and the localhost/anglesite-podman-test:latest test image — set ANGLESITE_PODMAN_TESTS=1 to opt in")
    )
    func startRejectsNonGitSourceRepo() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anglesite-podman-test-nongit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let control = makeControl()
        await #expect(throws: LocalContainerError.self) {
            _ = try await control.start(siteID: "integration-nongit", sourceRepo: dir, ref: "HEAD") { _, _ in }
        }
    }
}
#endif

// Glibc-safe subset of AnglesiteCoreTests/ProcessSupervisorRunLoggingTests (#1966). That suite
// lives in a target the Linux CI leg never builds, so without this file the `posix_spawn`
// path behind `runDetaching` — and the streaming `run` — would only ever compile on Linux, not
// execute. Deliberately unconditional (no `#if canImport(Glibc)`): it runs on macOS too, where it
// is plain duplication that keeps the two platforms' behaviour pinned to the same expectations.
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ProcessSupervisor run logging (portable)")
struct ProcessSupervisorRunLoggingPortableTests {
    private let sh = URL(fileURLWithPath: "/bin/sh")

    @Test("run streams stdout and stderr lines into the log center under the caller's source")
    func runStreamsBothPipes() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let result = try await supervisor.run(
            source: "portable-run",
            executable: sh,
            arguments: ["-c", "printf 'one\\ntwo\\n'; printf 'err\\n' 1>&2; exit 3"],
            logCenter: center
        )
        #expect(result.stdout == "one\ntwo\n")
        #expect(result.stderr == "err\n")
        #expect(result.exitCode == 3)
        let snapshot = await center.snapshot().filter { $0.source == "portable-run" }
        #expect(snapshot.filter { $0.stream == .stdout }.map(\.text) == ["one", "two"])
        #expect(snapshot.filter { $0.stream == .stderr }.map(\.text) == ["err", "[supervisor] sh exited 3"])
    }

    @Test("runDetaching survives a daemonizing grandchild and replays its output")
    func runDetachingSurvivesDaemon() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let start = ContinuousClock.now
        let result = try await supervisor.runDetaching(
            source: "portable-detach",
            executable: sh,
            arguments: ["-c", "(sleep 5 &) ; printf 'spawned\\n'; printf 'note\\n' 1>&2"],
            logCenter: center
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == "spawned\n")
        #expect(result.stderr == "note\n")
        // Half the grandchild's 5s sleep: comfortable headroom over a real (sub-second)
        // return, but still squarely on the immediate side of "waited for the daemon"
        // (~5s+). This suite runs in the isolated timing-sensitive lane (see
        // scripts/lib/timing-sensitive-tests.sh), so it no longer needs slack for
        // build-test's full-parallel scheduler contention.
        #expect(ContinuousClock.now - start < .seconds(2.5))
        let snapshot = await center.snapshot().filter { $0.source == "portable-detach" }
        #expect(snapshot.filter { $0.stream == .stdout }.map(\.text) == ["spawned"])
        #expect(snapshot.filter { $0.stream == .stderr }.map(\.text) == ["note"])
    }

    @Test("runDetaching honours cwd and environment, and maps a signal death to 128+signal")
    func runDetachingCwdEnvironmentAndSignal() async throws {
        let supervisor = ProcessSupervisor()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portable-detach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await supervisor.runDetaching(
            source: "portable-detach-cwd",
            executable: sh,
            arguments: ["-c", "printf '%s|%s' \"$(pwd -P)\" \"$ANGLESITE_DETACH\""],
            environment: ["ANGLESITE_DETACH": "yes", "PATH": "/usr/bin:/bin"],
            currentDirectoryURL: dir,
            logCenter: LogCenter()
        )
        #expect(result.exitCode == 0)
        let parts = result.stdout.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        #expect(parts.count == 2)
        let reported = URL(fileURLWithPath: parts.first ?? "").resolvingSymlinksInPath().path
        #expect(reported == dir.resolvingSymlinksInPath().path)
        #expect(parts.last == "yes")

        let killed = try await supervisor.runDetaching(
            source: "portable-detach-signal", executable: sh, arguments: ["-c", "kill -9 $$"], logCenter: LogCenter())
        #expect(killed.exitCode == 128 + 9)
    }

    @Test("runDetaching's child does not inherit this process's other file descriptors")
    func runDetachingDoesNotLeakDescriptorsToTheDaemon() async throws {
        // On Glibc this is the case that first surfaced the leak (the sibling `run` case in this
        // suite stalled for the full length of the daemon case's `sleep 5 &`).
        let supervisor = ProcessSupervisor()
        let pipe = Pipe()
        _ = try await supervisor.runDetaching(
            source: "portable-detach-fds",
            executable: sh,
            arguments: ["-c", "(sleep 3 &)"],
            logCenter: LogCenter()
        )
        try pipe.fileHandleForWriting.close()
        let start = ContinuousClock.now
        let leftover = try pipe.fileHandleForReading.readToEnd()
        #expect(leftover == nil || leftover?.isEmpty == true)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test("a missing executable throws and leaves a spawn-failure marker without argv")
    func missingExecutableIsLoggedWithoutArgv() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        await #expect(throws: ProcessSupervisor.SupervisorError.self) {
            _ = try await supervisor.runDetaching(
                source: "portable-missing",
                executable: URL(fileURLWithPath: "/usr/bin/definitely-not-a-real-binary-xyz"),
                arguments: ["--token", "SECRET"],
                logging: .redacted(reason: "token in argv"),
                logCenter: center
            )
        }
        let texts = await center.snapshot().filter { $0.source == "portable-missing" }.map(\.text)
        #expect(texts.count == 1)
        #expect(texts.first?.hasPrefix("[supervisor] definitely-not-a-real-binary-xyz could not be spawned:") == true)
        #expect(!(texts.joined().contains("SECRET")))
    }
}

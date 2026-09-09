import Testing
import Foundation
@testable import AnglesiteCore

/// `ProcessSupervisor.run` (and the daemon-tolerant `runDetaching`) must land every byte of a
/// one-shot child's output in `LogCenter` by default (#1966) — "logs are sacred" applied to the
/// short-lived path, not just `launch`. The opt-outs are explicit and leave a marker.
struct ProcessSupervisorRunLoggingTests {
    private let sh = URL(fileURLWithPath: "/bin/sh")

    @Test("Run streams stdout lines into the log center under the caller's source")
    func runStreamsStdoutLines() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let result = try await supervisor.run(
            source: "run-stdout",
            executable: sh,
            arguments: ["-c", "printf 'one\\ntwo\\nthree\\n'"],
            logCenter: center
        )
        #expect(result.stdout == "one\ntwo\nthree\n")
        let lines = await center.snapshot().filter { $0.source == "run-stdout" && $0.stream == .stdout }
        #expect(lines.map(\.text) == ["one", "two", "three"])
    }

    @Test("Run streams stderr lines separately from stdout")
    func runStreamsStderrLines() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        _ = try await supervisor.run(
            source: "run-stderr",
            executable: sh,
            arguments: ["-c", "printf 'out\\n'; printf 'err\\n' 1>&2"],
            logCenter: center
        )
        let snapshot = await center.snapshot().filter { $0.source == "run-stderr" }
        #expect(snapshot.filter { $0.stream == .stdout }.map(\.text) == ["out"])
        #expect(snapshot.filter { $0.stream == .stderr }.map(\.text) == ["err"])
    }

    @Test("Run's last output line is in the snapshot the moment run returns")
    func runOutputIsDrainedBeforeReturning() async throws {
        for _ in 0..<10 {
            let supervisor = ProcessSupervisor()
            let center = LogCenter()
            _ = try await supervisor.run(
                source: "run-drain",
                executable: sh,
                arguments: ["-c", "for i in 1 2 3 4 5 6 7 8 9 10; do printf 'line %s\\n' $i; done; printf 'SENTINEL\\n'"],
                logCenter: center
            )
            let texts = await center.snapshot().filter { $0.source == "run-drain" }.map(\.text)
            #expect(texts.last == "SENTINEL")
            #expect(texts.count == 11)
        }
    }

    @Test("A clean exit adds no supervisor marker line")
    func cleanExitAddsNoMarker() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        _ = try await supervisor.run(source: "run-clean", executable: sh, arguments: ["-c", "printf ok"], logCenter: center)
        let texts = await center.snapshot().filter { $0.source == "run-clean" }.map(\.text)
        #expect(texts == ["ok"])
    }

    @Test("A non-zero exit appends a supervisor marker with the exit code")
    func nonZeroExitAppendsMarker() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let result = try await supervisor.run(source: "run-exit", executable: sh, arguments: ["-c", "exit 7"], logCenter: center)
        #expect(result.exitCode == 7)
        let lines = await center.snapshot().filter { $0.source == "run-exit" }
        #expect(lines.count == 1)
        #expect(lines.first?.stream == .stderr)
        #expect(lines.first?.text == "[supervisor] sh exited 7")
    }

    @Test("Redacted logging withholds output but records that the process ran")
    func redactedWithholdsOutputAndLeavesMarker() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let result = try await supervisor.run(
            source: "run-redacted",
            executable: sh,
            arguments: ["-c", "printf 'SECRET\\n'; printf 'also secret\\n' 1>&2; exit 3"],
            logging: .redacted(reason: "test token on stdout"),
            logCenter: center
        )
        // The caller still gets the captured output — only the debug pane is withheld.
        #expect(result.stdout == "SECRET\n")
        #expect(result.stderr == "also secret\n")
        let lines = await center.snapshot().filter { $0.source == "run-redacted" }
        #expect(lines.map(\.text) == ["[supervisor] sh exited 3; output redacted (test token on stdout)"])
        #expect(!(lines.map(\.text).joined().contains("SECRET")))
    }

    @Test("Relayed logging is silent on success and still marks a non-zero exit")
    func relayedIsSilentOnSuccess() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        _ = try await supervisor.run(
            source: "run-relayed",
            executable: sh,
            arguments: ["-c", "printf 'forwarded elsewhere\\n'"],
            logging: .relayed(via: "onOutput"),
            logCenter: center
        )
        let silent = await center.snapshot().filter { $0.source == "run-relayed" }
        #expect(silent.isEmpty)

        _ = try await supervisor.run(
            source: "run-relayed",
            executable: sh,
            arguments: ["-c", "exit 2"],
            logging: .relayed(via: "onOutput"),
            logCenter: center
        )
        let marked = await center.snapshot().filter { $0.source == "run-relayed" }
        #expect(marked.map(\.text) == ["[supervisor] sh exited 2"])
    }

    @Test("A spawn failure is logged under the caller's source before it throws")
    func spawnFailureIsLogged() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        await #expect(throws: ProcessSupervisor.SupervisorError.self) {
            _ = try await supervisor.run(
                source: "run-spawn-fail",
                executable: URL(fileURLWithPath: "/usr/bin/definitely-not-a-real-binary-xyz"),
                logCenter: center
            )
        }
        let lines = await center.snapshot().filter { $0.source == "run-spawn-fail" }
        #expect(lines.count == 1)
        #expect(lines.first?.stream == .stderr)
        #expect(lines.first?.text.hasPrefix("[supervisor] definitely-not-a-real-binary-xyz could not be spawned:") == true)
    }

    @Test("Spawn failure is logged even for a redacted run (the message carries no argv)")
    func spawnFailureIsLoggedWhenRedacted() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        await #expect(throws: ProcessSupervisor.SupervisorError.self) {
            _ = try await supervisor.run(
                source: "run-spawn-fail-redacted",
                executable: URL(fileURLWithPath: "/usr/bin/definitely-not-a-real-binary-xyz"),
                arguments: ["--token", "SECRET"],
                logging: .redacted(reason: "token in argv"),
                logCenter: center
            )
        }
        let texts = await center.snapshot().filter { $0.source == "run-spawn-fail-redacted" }.map(\.text)
        #expect(texts.count == 1)
        #expect(!(texts.joined().contains("SECRET")))
    }

    // MARK: runDetaching

    @Test("runDetaching captures stdout/stderr and replays them into the log center")
    func runDetachingCapturesAndReplays() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let result = try await supervisor.runDetaching(
            source: "detach",
            executable: sh,
            arguments: ["-c", "printf 'container-id\\n'; printf 'warn\\n' 1>&2"],
            logCenter: center
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == "container-id\n")
        #expect(result.stderr == "warn\n")
        let snapshot = await center.snapshot().filter { $0.source == "detach" }
        #expect(snapshot.filter { $0.stream == .stdout }.map(\.text) == ["container-id"])
        #expect(snapshot.filter { $0.stream == .stderr }.map(\.text) == ["warn"])
    }

    @Test("runDetaching returns even when the child leaves a daemon holding its stdio open")
    func runDetachingSurvivesADaemonizingChild() async throws {
        // The reason this primitive exists (`podman run -d` → conmon): a grandchild that inherits
        // stdout/stderr and outlives the direct child. A pipe-based reader would wait for that
        // grandchild's EOF; the file-backed capture must not.
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let start = ContinuousClock.now
        let result = try await supervisor.runDetaching(
            source: "detach-daemon",
            executable: sh,
            arguments: ["-c", "(sleep 5 &) ; printf 'spawned\\n'; exit 0"],
            logCenter: center
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == "spawned\n")
        #expect(ContinuousClock.now - start < .seconds(4))
        let texts = await center.snapshot().filter { $0.source == "detach-daemon" }.map(\.text)
        #expect(texts == ["spawned"])
    }

    @Test("runDetaching's child does not inherit this process's other file descriptors")
    func runDetachingDoesNotLeakDescriptorsToTheDaemon() async throws {
        // Regression for the relocated hang: if the daemon grandchild inherited the write end
        // of a pipe we hold, its reader would only see EOF once `sleep` died (~3 s). With
        // everything above stderr closed in the child, closing our own write end is enough.
        let supervisor = ProcessSupervisor()
        let pipe = Pipe()
        _ = try await supervisor.runDetaching(
            source: "detach-fds",
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

    @Test("runDetaching reports a non-zero exit and marks it")
    func runDetachingReportsNonZeroExit() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let result = try await supervisor.runDetaching(
            source: "detach-exit",
            executable: sh,
            arguments: ["-c", "printf 'boom\\n' 1>&2; exit 5"],
            logCenter: center
        )
        #expect(result.exitCode == 5)
        #expect(result.stderr == "boom\n")
        let texts = await center.snapshot().filter { $0.source == "detach-exit" }.map(\.text)
        #expect(texts == ["boom", "[supervisor] sh exited 5"])
    }

    @Test("runDetaching maps a signal death to 128+signal like a shell")
    func runDetachingMapsSignalExit() async throws {
        let supervisor = ProcessSupervisor()
        let result = try await supervisor.runDetaching(
            source: "detach-signal",
            executable: sh,
            arguments: ["-c", "kill -9 $$"],
            logCenter: LogCenter()
        )
        #expect(result.exitCode == 128 + 9)
    }

    @Test("runDetaching honours the working directory and environment")
    func runDetachingHonoursCwdAndEnvironment() async throws {
        let supervisor = ProcessSupervisor()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detach-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await supervisor.runDetaching(
            source: "detach-cwd",
            executable: sh,
            arguments: ["-c", "printf '%s|%s' \"$(pwd -P)\" \"$ANGLESITE_DETACH\""],
            environment: ["ANGLESITE_DETACH": "yes", "PATH": "/usr/bin:/bin"],
            currentDirectoryURL: dir,
            logCenter: LogCenter()
        )
        #expect(result.exitCode == 0)
        let parts = result.stdout.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        #expect(parts.count == 2)
        // Normalise both sides the same way: Darwin's `resolvingSymlinksInPath()` drops the
        // `/private` prefix that `pwd -P` keeps, so a raw string compare is never equal there.
        let reported = URL(fileURLWithPath: parts.first ?? "").resolvingSymlinksInPath().path
        #expect(reported == dir.resolvingSymlinksInPath().path)
        #expect(parts.last == "yes")
    }

    @Test("runDetaching throws (and logs) when the executable is missing")
    func runDetachingThrowsForMissingExecutable() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        await #expect(throws: ProcessSupervisor.SupervisorError.self) {
            _ = try await supervisor.runDetaching(
                source: "detach-missing",
                executable: URL(fileURLWithPath: "/usr/bin/definitely-not-a-real-binary-xyz"),
                logCenter: center
            )
        }
        let texts = await center.snapshot().filter { $0.source == "detach-missing" }.map(\.text)
        #expect(texts.count == 1)
        #expect(texts.first?.hasPrefix("[supervisor] definitely-not-a-real-binary-xyz could not be spawned:") == true)
    }

    @Test("runDetaching honours redacted logging")
    func runDetachingHonoursRedaction() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        _ = try await supervisor.runDetaching(
            source: "detach-redacted",
            executable: sh,
            arguments: ["-c", "printf 'SECRET\\n'"],
            logging: .redacted(reason: "test"),
            logCenter: center
        )
        let texts = await center.snapshot().filter { $0.source == "detach-redacted" }.map(\.text)
        #expect(texts == ["[supervisor] sh exited 0; output redacted (test)"])
    }
}

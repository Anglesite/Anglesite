import Testing
import Foundation
@testable import AnglesiteCore

struct ProcessSupervisorTests {
    @Test("Run captures standard output") func runCapturesStandardOutput() async throws {
        let supervisor = ProcessSupervisor()
        let result = try await supervisor.run(
            source: "test",
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"]
        )
        #expect(result.stdout == "hello\n")
        #expect(result.stderr == "")
        #expect(result.exitCode == 0)
    }

    @Test("Run captures standard error") func runCapturesStandardError() async throws {
        let supervisor = ProcessSupervisor()
        let result = try await supervisor.run(
            source: "test",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf err 1>&2"]
        )
        #expect(result.stdout == "")
        #expect(result.stderr == "err")
        #expect(result.exitCode == 0)
    }

    @Test("Run reports non-zero exit code") func runReportsNonZeroExitCode() async throws {
        let supervisor = ProcessSupervisor()
        let result = try await supervisor.run(
            source: "test",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"]
        )
        #expect(result.exitCode == 7)
    }

    @Test("Run throws when executable missing") func runThrowsWhenExecutableMissing() async {
        let supervisor = ProcessSupervisor()
        await #expect(throws: ProcessSupervisor.SupervisorError.self) {
            _ = try await supervisor.run(
                source: "test",
                executable: URL(fileURLWithPath: "/usr/bin/definitely-not-a-real-binary-xyz"),
                arguments: []
            )
        }
    }

    @Test("Run passes environment") func runPassesEnvironment() async throws {
        let supervisor = ProcessSupervisor()
        let result = try await supervisor.run(
            source: "test",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s \"$ANGLESITE_TEST\""],
            environment: ["ANGLESITE_TEST": "phase-1"]
        )
        #expect(result.stdout == "phase-1")
    }

    @Test("Run injects the default environment when none is passed")
    func runInjectsDefaultEnvironment() async throws {
        let supervisor = ProcessSupervisor(
            backend: InProcessBackend(),
            defaultEnvironment: { ["ANGLESITE_DEFAULT": "from-default", "PATH": "/usr/bin:/bin"] }
        )
        let result = try await supervisor.run(
            source: "test",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s \"$ANGLESITE_DEFAULT\""]
        )
        #expect(result.stdout == "from-default")
    }

    @Test("Explicit environment overrides the default")
    func explicitEnvironmentOverridesDefault() async throws {
        let supervisor = ProcessSupervisor(
            backend: InProcessBackend(),
            defaultEnvironment: { ["ANGLESITE_DEFAULT": "from-default"] }
        )
        let result = try await supervisor.run(
            source: "test",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s \"${ANGLESITE_DEFAULT:-none}\""],
            environment: ["FOO": "bar"]
        )
        #expect(result.stdout == "none")
    }
}

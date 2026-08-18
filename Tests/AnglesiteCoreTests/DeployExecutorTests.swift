import Testing
import Foundation
@testable import AnglesiteCore

struct DeployExecutorTests {
    /// A real, existing directory — the supervisor `cd`s into the site dir before spawning.
    private let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    /// Builds a `HostDeployExecutor` with a single injected resolver and isolated supervision.
    private func makeExecutor(
        resolveCommand: @escaping @Sendable (URL) -> DeployCommand.LaunchPlan
    ) -> (HostDeployExecutor, ProcessSupervisor, LogCenter) {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let executor = HostDeployExecutor(
            supervisor: supervisor,
            logCenter: center,
            resolveCommand: { _ in { dir in resolveCommand(dir) } }
        )
        return (executor, supervisor, center)
    }

    /// Mirrors `DeployCommandTests.shFixture`.
    private func shPlan(_ script: String) -> DeployCommand.LaunchPlan {
        .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    }

    // MARK: - build step

    @Test("HostDeployExecutor build: exit 0 and stdout captured")
    func buildStepReturnsExitCodeAndOutput() async {
        let (executor, _, center) = makeExecutor(resolveCommand: { _ in
            self.shPlan("echo 'build output line'; exit 0")
        })

        let result = await executor.run(
            step: .build,
            siteDirectory: tmpDir,
            environment: ProcessInfo.processInfo.environment,
            source: "test:build"
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("build output line"))
        // The line must also appear in LogCenter under the given source.
        let lines = await center.snapshot()
        #expect(
            lines.contains { $0.source == "test:build" && $0.text == "build output line" },
            "build output should be streamed to LogCenter under the supplied source"
        )
    }

    @Test("HostDeployExecutor build: non-zero exit code is preserved")
    func buildStepNonZeroExitCode() async {
        let (executor, _, _) = makeExecutor(resolveCommand: { _ in self.shPlan("exit 42") })
        let result = await executor.run(
            step: .build,
            siteDirectory: tmpDir,
            environment: ProcessInfo.processInfo.environment,
            source: "test:build"
        )
        #expect(result.exitCode == 42)
    }

    @Test("HostDeployExecutor build: unavailable plan returns nil exitCode with reason")
    func buildStepUnavailableReturnsNilExitCode() async {
        let (executor, _, _) = makeExecutor(resolveCommand: { _ in
            .unavailable(reason: "node not bundled — test")
        })
        let result = await executor.run(
            step: .build,
            siteDirectory: tmpDir,
            environment: ProcessInfo.processInfo.environment,
            source: "test:build"
        )
        #expect(result.exitCode == nil)
        #expect(result.output.contains("node not bundled"))
    }

    // MARK: - wrangler step

    @Test("HostDeployExecutor wrangler: stdout captured for URL parsing")
    func wranglerStepStdoutCaptured() async {
        let (executor, _, _) = makeExecutor(resolveCommand: { _ in
            self.shPlan(
                """
                echo 'Published site (0.42 sec)'
                echo '  https://site.example.workers.dev'
                exit 0
                """
            )
        })
        let result = await executor.run(
            step: .wrangler,
            siteDirectory: tmpDir,
            environment: ProcessInfo.processInfo.environment,
            source: "test:wrangler"
        )
        #expect(result.exitCode == 0)
        #expect(result.output.contains("Published"))
        #expect(result.output.contains("https://site.example.workers.dev"))
    }

    // MARK: - preflight step

    @Test("HostDeployExecutor preflight: stdout captured")
    func preflightStepStdoutCaptured() async {
        let (executor, _, _) = makeExecutor(resolveCommand: { _ in
            self.shPlan(#"echo '{"status":"pass"}'; exit 0"#)
        })
        let result = await executor.run(
            step: .preflight,
            siteDirectory: tmpDir,
            environment: ProcessInfo.processInfo.environment,
            source: "test:preflight"
        )
        #expect(result.exitCode == 0)
        #expect(result.output.contains("pass"))
    }

    @Test("HostDeployExecutor defaults fail every step explicitly after host Node retirement")
    func defaultResolverUnavailable() async {
        let dir = tmpDir

        #expect(HostDeployExecutor.defaultResolver(.build)(dir) == .unavailable(reason: "site build must run in the container runtime; host Node has been retired"))
        #expect(HostDeployExecutor.defaultResolver(.preflight)(dir) == .unavailable(reason: "pre-deploy check must run in the container runtime; host Node has been retired"))
        #expect(HostDeployExecutor.defaultResolver(.wrangler)(dir) == .unavailable(reason: "wrangler deploy must run in the container runtime; host Node has been retired"))
        #expect(HostDeployExecutor.defaultResolver(.githubPagesPublish)(dir) == .unavailable(reason: "GitHub Pages publish must run in the container runtime; host Node has been retired"))

        let executor = HostDeployExecutor(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let result = await executor.run(step: .preflight, siteDirectory: dir, environment: [:], source: "test:default")
        #expect(result.exitCode == nil)
        #expect(result.output == "pre-deploy check must run in the container runtime; host Node has been retired")
    }

    // MARK: - DeployStepResult equatability

    @Test("DeployStepResult is Equatable")
    func deployStepResultEquatable() {
        let a = DeployStepResult(exitCode: 0, output: "hello")
        let b = DeployStepResult(exitCode: 0, output: "hello")
        let c = DeployStepResult(exitCode: 1, output: "hello")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("DeployStepResult with nil exitCode is Equatable")
    func deployStepResultNilExitCodeEquatable() {
        let a = DeployStepResult(exitCode: nil, output: "unavailable")
        let b = DeployStepResult(exitCode: nil, output: "unavailable")
        let c = DeployStepResult(exitCode: 0, output: "unavailable")
        #expect(a == b)
        #expect(a != c)
    }
}

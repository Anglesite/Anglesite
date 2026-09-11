import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("ContainerCommandRunner")
struct ContainerCommandRunnerTests {
    @Test("secretRunner pipes the value through an environment variable, never through argv")
    func secretRunnerPipesValueThroughEnvironment() async throws {
        let fake = FakeLocalContainerControl(
            startResult: .failure(.virtualizationUnavailable),
            execResult: ContainerExecResult(exitCode: 0, stdout: "Success! Uploaded secret AP_PRIVATE_KEY", stderr: "")
        )
        // No Config/wrangler.toml at this location, so no staging exec precedes `secret put`.
        let runner = ContainerCommandRunner(
            control: fake, siteID: "site-abc",
            configDirectory: URL(fileURLWithPath: "/host/no-config-\(UUID().uuidString)"), logCenter: LogCenter())
        let privateKeyPem = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"

        let result = try await runner.secretRunner(
            URL(fileURLWithPath: "/host/irrelevant"), "AP_PRIVATE_KEY", privateKeyPem,
            ["CLOUDFLARE_API_TOKEN": "token"], "test-source"
        )

        #expect(result.exitCode == 0)
        let calls = await fake.execCalls
        #expect(calls.count == 1)
        // The secret value must never appear as a literal argv element — only the shell script text
        // (which references it by variable name) and the environment dict (checked below) do.
        #expect(!calls[0].argv.contains(where: { $0.contains("BEGIN PRIVATE KEY") }))
        #expect(calls[0].argv == [
            "sh", "-c",
            "printf '%s' \"$WRANGLER_SECRET_VALUE\" | npx wrangler secret put \"$WRANGLER_SECRET_NAME\"",
        ])
        #expect(calls[0].env["WRANGLER_SECRET_NAME"] == "AP_PRIVATE_KEY")
        #expect(calls[0].env["WRANGLER_SECRET_VALUE"] == privateKeyPem)
        #expect(calls[0].env["CLOUDFLARE_API_TOKEN"] == "token")
        #expect(calls[0].cwd == "/workspace/site")
    }

    @Test("secretRunner stages the host's Config/wrangler.toml into the guest before `wrangler secret put` (#1960)")
    func secretRunnerStagesWranglerConfigFirst() async throws {
        // `wrangler secret put` resolves the Worker's name from wrangler.toml in the working
        // directory, and the guest's clone of Source/ no longer carries one — the host package's
        // Config/ copy has to be staged first, the same way `ContainerDeployExecutor` does before
        // `wrangler deploy`.
        let fake = FakeLocalContainerControl(
            startResult: .failure(.virtualizationUnavailable),
            execResult: ContainerExecResult(exitCode: 0, stdout: "ok", stderr: "")
        )
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContainerCommandRunnerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: configDirectory) }
        let toml = "name = \"my-site\"\nmain = \"worker/worker.ts\"\n"
        try WranglerConfigFile.write(toml, configDirectory: configDirectory)
        let runner = ContainerCommandRunner(
            control: fake, siteID: "site-abc", configDirectory: configDirectory, logCenter: LogCenter())

        let result = try await runner.secretRunner(
            URL(fileURLWithPath: "/host/irrelevant"), "AP_PRIVATE_KEY", "pem",
            ["CLOUDFLARE_API_TOKEN": "token"], "test-source"
        )

        #expect(result.exitCode == 0)
        let calls = await fake.execCalls
        #expect(calls.count == 2, "expected the staging exec followed by the secret-put exec")
        #expect(calls[0].argv.prefix(2) == ["sh", "-c"])
        #expect(calls[0].argv[2].hasSuffix("| base64 -d > wrangler.toml"))
        #expect(calls[0].cwd == "/workspace/site")
        let base64Part = calls[0].argv[2]
            .replacingOccurrences(of: "echo ", with: "")
            .replacingOccurrences(of: " | base64 -d > wrangler.toml", with: "")
        #expect(Data(base64Encoded: base64Part).flatMap { String(data: $0, encoding: .utf8) } == toml)
        #expect(calls[1].argv[2].contains("npx wrangler secret put"))
    }
}

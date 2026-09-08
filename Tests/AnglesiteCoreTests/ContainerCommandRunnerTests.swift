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
        let runner = ContainerCommandRunner(control: fake, siteID: "site-abc", logCenter: LogCenter())
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
}

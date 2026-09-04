import Foundation
import Testing
@testable import AnglesiteCore
import AnglesiteTestSupport

@Suite("WranglerInvocation")
struct WranglerInvocationTests {
    @Test("argv prefixes npx wrangler")
    func argvPrefixesNpxWrangler() {
        #expect(WranglerInvocation.argv(subcommand: ["d1", "create", "site-social"])
            == ["npx", "wrangler", "d1", "create", "site-social"])
    }

    @Test("tokenOnly scope keeps only CLOUDFLARE_API_TOKEN")
    func tokenOnlyScope() {
        let env = WranglerInvocation.guestEnvironment(
            from: ["CLOUDFLARE_API_TOKEN": "tok", "CLOUDFLARE_ACCOUNT_ID": "acct", "PATH": "/bin"],
            scope: .tokenOnly)
        #expect(env == ["CLOUDFLARE_API_TOKEN": "tok"])
    }

    @Test("tokenAndAccount scope keeps both Cloudflare keys")
    func tokenAndAccountScope() {
        let env = WranglerInvocation.guestEnvironment(
            from: ["CLOUDFLARE_API_TOKEN": "tok", "CLOUDFLARE_ACCOUNT_ID": "acct", "PATH": "/bin"],
            scope: .tokenAndAccount)
        #expect(env == ["CLOUDFLARE_API_TOKEN": "tok", "CLOUDFLARE_ACCOUNT_ID": "acct"])
    }

    @Test("exec streams output to LogCenter and returns the result")
    func execStreamsAndReturns() async throws {
        let control = FakeLocalContainerControl(
            execResult: ContainerExecResult(exitCode: 0, stdout: "created\nid=abc123", stderr: ""),
            execStdoutLines: ["created", "id=abc123"])
        let logCenter = LogCenter()
        let result = try await WranglerInvocation.exec(
            control: control, siteID: "site-1",
            argv: ["npx", "wrangler", "d1", "create", "x"],
            environment: ["CLOUDFLARE_API_TOKEN": "tok"],
            logCenter: logCenter, source: "worker-provision:site-1")
        #expect(result.exitCode == 0)
        #expect(result.stdout == "created\nid=abc123")
        let snapshot = await logCenter.snapshot()
        #expect(snapshot.filter { $0.source == "worker-provision:site-1" }.map(\.text) == ["created", "id=abc123"])
        let calls = await control.execCalls
        #expect(calls.count == 1)
        #expect(calls[0].argv == ["npx", "wrangler", "d1", "create", "x"])
    }

    @Test("exec drains buffered output before rethrowing on failure")
    func execDrainsBeforeRethrowing() async throws {
        let control = FakeLocalContainerControl(
            execStdoutLines: ["partial output"],
            execError: LocalContainerError.bootFailed("boom"))
        let logCenter = LogCenter()
        await #expect(throws: LocalContainerError.self) {
            _ = try await WranglerInvocation.exec(
                control: control, siteID: "site-1", argv: ["npx", "wrangler", "deploy"],
                environment: [:], logCenter: logCenter, source: "deploy:site-1")
        }
        let snapshot = await logCenter.snapshot()
        #expect(snapshot.filter { $0.source == "deploy:site-1" }.map(\.text) == ["partial output"])
    }
}

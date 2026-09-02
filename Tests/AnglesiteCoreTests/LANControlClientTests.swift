import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport

struct LANControlClientTests {
    private static let unusedRemote = LANControlClient.unusedGitRemote
    private static let anyToken = SessionToken(value: "unused")

    @Test("start returns the LAN preview/MCP URL pair without any RPC")
    func startBuildsURLPair() async throws {
        let client = LANControlClient(
            configuration: LANRuntimeConfiguration(host: "mac-studio.local", previewPort: 8080, mcpPort: 9090))
        let session = try await client.start(
            siteID: "s1", gitRemote: Self.unusedRemote, gitRef: "HEAD", token: Self.anyToken)
        #expect(session.previewURL == URL(string: "http://mac-studio.local:8080/"))
        #expect(session.mcpURL == URL(string: "http://mac-studio.local:9090/mcp"))
    }

    @Test("default ports match the container guest convention")
    func defaultPorts() async throws {
        let client = LANControlClient(configuration: LANRuntimeConfiguration(host: "192.168.64.1"))
        let session = try await client.start(
            siteID: "s1", gitRemote: Self.unusedRemote, gitRef: "HEAD", token: Self.anyToken)
        #expect(session.previewURL == URL(string: "http://192.168.64.1:4321/"))
        #expect(session.mcpURL == URL(string: "http://192.168.64.1:4399/mcp"))
    }

    @Test("an unusable host throws startFailed instead of crashing on URL construction",
          arguments: ["", "not a host"])
    func invalidHostThrows(host: String) async {
        let client = LANControlClient(configuration: LANRuntimeConfiguration(host: host))
        await #expect(throws: SandboxControlError.startFailed("invalid LAN runtime host “\(host)”")) {
            _ = try await client.start(
                siteID: "s1", gitRemote: Self.unusedRemote, gitRef: "HEAD", token: Self.anyToken)
        }
    }

    @Test("status reports ready — the standing host process has no status RPC")
    func statusAlwaysReady() async throws {
        let client = LANControlClient(configuration: LANRuntimeConfiguration(host: "mac-studio.local"))
        let status = try await client.status(siteID: "s1")
        #expect(status == SandboxStatus(siteID: "s1", previewReady: true, mcpReady: true))
    }

    @Test("RemoteSandboxSiteRuntime over a LANControlClient settles to .ready with the LAN preview URL")
    func runtimeIntegration() async {
        let client = LANControlClient(configuration: LANRuntimeConfiguration(host: "mac-studio.local"))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let runtime = RemoteSandboxSiteRuntime(
            gitRemote: LANControlClient.unusedGitRemote,
            gitRef: "HEAD",
            control: client,
            mcpClient: mcp,
            connect: { _, _, _ in })  // trusted-LAN path: factory connects without a bearer
        await runtime.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        #expect(await runtime.state == .ready(siteID: "s1", url: URL(string: "http://mac-studio.local:4321/")!))
    }
}

/// `AppSettings.lanRuntimeConfiguration` parsing — the seam `LiveSiteRuntimeFactory` gates its
/// LAN branch on (kept in AnglesiteCore so it's testable off the app target, per CLAUDE.md).
final class LANRuntimeSettingsTests {
    private let scratch = TemporaryUserDefaults()
    private var defaults: UserDefaults { scratch.defaults }

    deinit { scratch.cleanup() }

    @Test("nil until a host is configured — runtime selection stays untouched by default")
    func nilByDefault() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.lanRuntimeConfiguration == nil)
    }

    @Test("blank or whitespace host still disables the LAN runtime", arguments: ["", "   ", "\n"])
    func blankHostIsNil(host: String) {
        defaults.set(host, forKey: AppSettings.Key.lanRuntimeHost)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.lanRuntimeConfiguration == nil)
    }

    @Test("host alone gets the default ports")
    func hostWithDefaultPorts() {
        defaults.set("mac-studio.local", forKey: AppSettings.Key.lanRuntimeHost)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.lanRuntimeConfiguration == LANRuntimeConfiguration(host: "mac-studio.local"))
    }

    @Test("host is trimmed; custom ports are parsed")
    func customPorts() {
        defaults.set("  192.168.64.1 ", forKey: AppSettings.Key.lanRuntimeHost)
        defaults.set("8080", forKey: AppSettings.Key.lanRuntimePreviewPort)
        defaults.set("9090", forKey: AppSettings.Key.lanRuntimeMCPPort)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.lanRuntimeConfiguration
            == LANRuntimeConfiguration(host: "192.168.64.1", previewPort: 8080, mcpPort: 9090))
    }

    @Test("unparseable or out-of-range ports fall back to the defaults",
          arguments: ["", "abc", "0", "-1", "70000"])
    func badPortsFallBack(port: String) {
        defaults.set("mac-studio.local", forKey: AppSettings.Key.lanRuntimeHost)
        defaults.set(port, forKey: AppSettings.Key.lanRuntimePreviewPort)
        defaults.set(port, forKey: AppSettings.Key.lanRuntimeMCPPort)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.lanRuntimeConfiguration == LANRuntimeConfiguration(host: "mac-studio.local"))
    }
}

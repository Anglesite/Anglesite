import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport

/// End-to-end: spawn the *real* bundled plugin's MCP server, drive a `get_component_model` call
/// through a real `MCPClient` via the production `ComponentModelClient`, and assert the decoded
/// `ComponentModel` matches the on-disk fixture component.
///
/// Skipped (via the `.enabled(if:)` trait) when the sibling plugin checkout, its `node_modules`,
/// or a Node binary aren't present — CI provides them via the `ANGLESITE_PLUGIN_PATH` env var;
/// local dev relies on the `../anglesite` sibling layout documented in CLAUDE.md. Mirrors the
/// boot mechanism in `Tests/AnglesiteBridgeTests/AppliesEditEndToEndTests.swift`.
@Suite(.serialized)
struct ComponentModelEndToEndTests {
    @Test(
        "get_component_model round-trips into ComponentModel",
        .enabled(
            if: E2EPrerequisites.prerequisitesMet,
            "requires the sibling Anglesite plugin checkout with a complete install (ANGLESITE_PLUGIN_PATH, or ../anglesite — run `npm install` in the plugin so sharp is present) and a Node ≥22 binary"
        )
    )
    func roundTrips() async throws {
        // 1. Temp project root with a fixture component (mirror AppliesEditEndToEndTests' setup).
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("anglesite-cm-e2e-\(UUID().uuidString)")
        let componentsDir = projectRoot.appendingPathComponent("src/components")
        try FileManager.default.createDirectory(at: componentsDir, withIntermediateDirectories: true)
        try """
        ---
        interface Props {
          title: string;
        }
        const { title } = Astro.props;
        ---
        <article class="card"><h2>{title}</h2><slot /></article>
        <style>.card { padding: 1rem; }</style>
        """.write(to: componentsDir.appendingPathComponent("Card.astro"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        // 2. Boot the plugin MCP server exactly as AppliesEditEndToEndTests does.
        let mcp = try await Self.startPluginServer(projectRoot: projectRoot)
        defer { Task { await mcp.stop() } }

        // 3. Fetch + decode via the production client.
        let modelClient = ComponentModelClient(toolCaller: { name, args in
            try await mcp.callTool(name: name, arguments: args)
        })
        let model = try await modelClient.fetch(path: "src/components/Card.astro")

        #expect(model.path == "src/components/Card.astro")
        #expect(model.template.children.first?.tag == "article")
        #expect(model.frontmatter?.props.first?.name == "title")
        #expect(model.styles.first?.selector == ".card")
        #expect(model.clientScript == nil)

        await mcp.stop()
    }

    // MARK: - boot helper

    /// Boots the real bundled plugin's MCP server against `projectRoot`, mirroring the
    /// `ProcessSupervisor`/`MCPClient` startup in `AppliesEditEndToEndTests`.
    private static func startPluginServer(projectRoot: URL) async throws -> MCPClient {
        let pluginRoot = try #require(E2EPrerequisites.locateSiblingPlugin())
        let node = try #require(E2EPrerequisites.locateNode())
        let serverPath = pluginRoot.appendingPathComponent("server/index.mjs")

        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let mcp = MCPClient(supervisor: supervisor, logCenter: center)
        try await mcp.start(
            executable: node,
            arguments: [serverPath.path],
            environment: ["ANGLESITE_PROJECT_ROOT": projectRoot.path],
            source: "mcp:e2e-component-model",
            readyTimeout: 15
        )
        return mcp
    }
}

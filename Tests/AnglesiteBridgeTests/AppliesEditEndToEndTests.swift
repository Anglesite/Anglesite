import Testing
import Foundation
@testable import AnglesiteBridge
import AnglesiteCore
import AnglesiteTestSupport

/// End-to-end: spawn the *real* bundled plugin's MCP server, drive an `apply_edit` through a
/// real `MCPClient` via `MCPApplyEditRouter`, and assert the file's bytes change on disk.
///
/// Skipped (via the `.enabled(if:)` trait) when the sibling plugin checkout, its `node_modules`,
/// or a Node binary aren't present — CI provides them via the `ANGLESITE_PLUGIN_PATH` env var;
/// local dev relies on the `../anglesite` sibling layout documented in CLAUDE.md.
///
/// A `final class` (not a `struct`) so `deinit` can tear down the temp site, mirroring the
/// former `tearDownWithError`.
final class AppliesEditEndToEndTests {
    private let tmpSite: URL
    private static let editableHeading = "Welcome to E2E Test Site"
    private static let pageContents = """
    <h1>\(editableHeading)</h1>
    <p>Stable paragraph for context.</p>
    """

    // MARK: setup / teardown

    init() throws {
        // Prerequisites are gated by the test's `.enabled(if:)` trait, so this initializer only
        // runs when the plugin checkout and Node are present — no need to re-probe here.
        tmpSite = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anglesite-e2e-\(UUID().uuidString)", isDirectory: true)
        let pagesDir = tmpSite.appendingPathComponent("src/pages", isDirectory: true)
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        try Self.pageContents.write(
            to: pagesDir.appendingPathComponent("index.astro"),
            atomically: true, encoding: .utf8
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpSite)
    }

    // MARK: the test

    @Test(
        "Apply edit end to end mutates the file on disk",
        .enabled(
            if: E2EPrerequisites.prerequisitesMet,
            "requires the sibling Anglesite plugin checkout with a complete install (ANGLESITE_PLUGIN_PATH, or ../anglesite — run `npm install` in the plugin so sharp is present) and a Node ≥22 binary"
        )
    )
    func applyEditEndToEndMutatesTheFileOnDisk() async throws {
        let pluginRoot = try #require(E2EPrerequisites.locateSiblingPlugin())
        let node = try #require(E2EPrerequisites.locateNode())
        let serverPath = pluginRoot.appendingPathComponent("server/index.mjs")

        // Real MCPClient against the real bundled plugin server, scoped to our tmp site.
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let mcp = MCPClient(supervisor: supervisor, logCenter: center)
        try await mcp.start(
            executable: node,
            arguments: [serverPath.path],
            environment: ["ANGLESITE_PROJECT_ROOT": tmpSite.path],
            source: "mcp:e2e",
            readyTimeout: 15
        )
        defer { Task { await mcp.stop() } }

        // Real router pointing at the real client.
        let router = MCPApplyEditRouter(mcpClient: { mcp })

        let message = EditMessage(
            id: "e2e-1",
            type: .applyEdit,
            path: "/",
            selector: .object([
                "tag": .string("H1"),
                "classes": .array([]),
                "nthChild": .int(1),
                "textContent": .string(Self.editableHeading),
            ]),
            op: "replace-text",
            value: .string("Welcome to the new headline")
        )

        // Sanity: file currently has the original heading.
        let pagePath = tmpSite.appendingPathComponent("src/pages/index.astro")
        let before = try String(contentsOf: pagePath, encoding: .utf8)
        #expect(before.contains(Self.editableHeading))

        // Drive the round-trip.
        let reply = await router.apply(message)
        #expect(reply.id == "e2e-1")
        #expect(
            reply.status == .applied,
            "expected the plugin's apply_edit to succeed; router message: \(reply.message ?? "nil")"
        )

        // The file's bytes actually changed.
        let after = try String(contentsOf: pagePath, encoding: .utf8)
        #expect(!after.contains(Self.editableHeading), "old heading should be gone")
        #expect(after.contains("Welcome to the new headline"), "new heading should be present")

        await mcp.stop()
    }

    @Test(
        "Dry-run edit-style returns preview with color change, file unchanged on disk",
        .enabled(
            if: E2EPrerequisites.prerequisitesMet,
            "requires the sibling Anglesite plugin checkout with a complete install (ANGLESITE_PLUGIN_PATH, or ../anglesite — run `npm install` in the plugin so sharp is present) and a Node ≥22 binary"
        )
    )
    func dryRunEditStyleReturnsPreviewFileUnchanged() async throws {
        let pluginRoot = try #require(E2EPrerequisites.locateSiblingPlugin())
        let node = try #require(E2EPrerequisites.locateNode())
        let serverPath = pluginRoot.appendingPathComponent("server/index.mjs")

        // Temp site with a heading that has a stable id for the selector.
        let pagePath = tmpSite.appendingPathComponent("src/pages/index.astro")
        let originalContents = try String(contentsOf: pagePath, encoding: .utf8)

        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let mcp = MCPClient(supervisor: supervisor, logCenter: center)
        try await mcp.start(
            executable: node,
            arguments: [serverPath.path],
            environment: ["ANGLESITE_PROJECT_ROOT": tmpSite.path],
            source: "mcp:e2e-dryrun",
            readyTimeout: 15
        )
        defer { Task { await mcp.stop() } }

        let router = MCPApplyEditRouter(mcpClient: { mcp })

        // Dry-run edit-style: add `color: teal` to the <h1>.
        let message = EditMessage(
            id: "e2e-dryrun-1",
            type: .applyEdit,
            path: "/",
            selector: .object([
                "tag": .string("H1"),
                "classes": .array([]),
                "nthChild": .int(1),
                "textContent": .string(Self.editableHeading),
            ]),
            op: "edit-style",
            value: .object(["property": .string("color"), "value": .string("teal")]),
            dryRun: true
        )

        let reply = await router.apply(message)
        #expect(reply.id == "e2e-dryrun-1")
        #expect(
            reply.status == .preview,
            "expected a preview reply for dry_run; got status=\(reply.status), message=\(reply.message ?? "nil")"
        )
        // The after fragment must contain the applied color.
        let after = try #require(reply.after, "expected a non-nil after fragment in the preview reply")
        #expect(after.contains("teal"), "after fragment should contain 'teal': \(after)")

        // The on-disk file must be byte-for-byte identical to what it was before the call.
        let contentsAfterCall = try String(contentsOf: pagePath, encoding: .utf8)
        #expect(
            contentsAfterCall == originalContents,
            "dry_run must not write to disk — file changed unexpectedly"
        )

        await mcp.stop()
    }

    @Test(
        "insertBlock end to end resolves a manifest block and lands it in the page model",
        .enabled(
            if: E2EPrerequisites.prerequisitesMet,
            "requires the sibling Anglesite plugin checkout with a complete install (ANGLESITE_PLUGIN_PATH, or ../anglesite — run `npm install` in the plugin so sharp is present) and a Node ≥22 binary"
        )
    )
    func insertBlockRoundTrip() async throws {
        let pluginRoot = try #require(E2EPrerequisites.locateSiblingPlugin())
        let node = try #require(E2EPrerequisites.locateNode())
        let serverPath = pluginRoot.appendingPathComponent("server/index.mjs")

        // This suite's scratch site (see `init()`) is a minimal synthetic fixture with no
        // blocks.manifest.json of its own. Give it one real, registered effect block — copied
        // straight from the committed template — so insertBlock's `manifestBlock` lookup has a
        // genuine entry to resolve against, matching the real template's registration shape
        // rather than a fabricated one.
        let manifestSource = try templateRoot().appendingPathComponent("blocks.manifest.json")
        let componentSource = try templateRoot()
            .appendingPathComponent("src/components/effects/ParticleField.astro")
        let componentDestDir = tmpSite.appendingPathComponent("src/components/effects", isDirectory: true)
        try FileManager.default.createDirectory(at: componentDestDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: manifestSource, to: tmpSite.appendingPathComponent("blocks.manifest.json"))
        try FileManager.default.copyItem(
            at: componentSource, to: componentDestDir.appendingPathComponent("ParticleField.astro"))

        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let mcp = MCPClient(supervisor: supervisor, logCenter: center)
        try await mcp.start(
            executable: node,
            arguments: [serverPath.path],
            environment: ["ANGLESITE_PROJECT_ROOT": tmpSite.path],
            source: "mcp:e2e-insert-block",
            readyTimeout: 15
        )
        defer { Task { await mcp.stop() } }

        let pageModelClient = PageModelClient(mcpClient: { mcp })
        let model = try await pageModelClient.fetch(path: "src/pages/index.astro")

        // `Self.pageContents` (see `init()`) has no <html>/<body> wrapper, so the tree is rooted
        // at a synthetic fragment with the <h1>/<p> as direct children. Look for a real <body>
        // first — matching how `PlacementMatcher` matches on tag — and fall back to the
        // fragment root, which is what this fixture actually has.
        let bodyId = model.tree.children.first(where: { $0.tag?.uppercased() == "BODY" })?.id ?? model.tree.id

        let router = MCPApplyEditRouter(mcpClient: { mcp })
        let edit = ComponentStructureEditBuilder.insertBlock(
            id: "e2e-insert-block-1",
            path: "src/pages/index.astro",
            baseVersion: model.version,
            parentId: bodyId,
            index: model.tree.children.count,
            manifestBlock: "Particle Field"
        )
        let reply = await router.apply(edit)
        #expect(
            reply.status == .applied,
            "expected insertBlock to succeed; router message: \(reply.message ?? "nil")"
        )

        // Re-fetch: the model version must have moved, and the new node must show up annotated
        // against the manifest entry we registered above (proof the block actually resolved, not
        // just that some component tag landed).
        let after = try await pageModelClient.fetch(path: "src/pages/index.astro")
        #expect(after.version != model.version)
        #expect(after.tree.children.contains { $0.block?.name == "Particle Field" })

        await mcp.stop()
    }
}

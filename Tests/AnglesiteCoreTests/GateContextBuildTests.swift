import Foundation
import Testing
@testable import AnglesiteCore

@Suite("GateContext.build(fromSourceDirectory:)")
struct GateContextBuildTests {
    @Test("parses tokens from src/styles/global.css and routes from src/pages")
    func buildsFromDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = root.appendingPathComponent("src/styles")
        let pagesDir = root.appendingPathComponent("src/pages/blog")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("public"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try ":root { --color-text: #111111; }".write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
        try "---\ntitle: Home\n---\n".write(to: root.appendingPathComponent("src/pages/index.astro"), atomically: true, encoding: .utf8)
        try "---\ntitle: Post\n---\n".write(to: pagesDir.appendingPathComponent("hello-world.md"), atomically: true, encoding: .utf8)

        let context = GateContext.build(fromSourceDirectory: root)

        #expect(context.resolvedTokens["color-text"] == "#111111")
        #expect(context.internalRoutes.contains("/"))
        #expect(context.internalRoutes.contains("/blog/hello-world"))
        #expect(context.assetRoot == root.appendingPathComponent("public"))
    }

    @Test("skips bracketed dynamic-route directories")
    func skipsDynamicRoutes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dynamicDir = root.appendingPathComponent("src/pages/[collection]")
        try FileManager.default.createDirectory(at: dynamicDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\n---\n".write(to: dynamicDir.appendingPathComponent("[slug].astro"), atomically: true, encoding: .utf8)

        let context = GateContext.build(fromSourceDirectory: root)

        #expect(context.internalRoutes.isEmpty)
    }

    @Test("records the first-level directory of a bracketed source file as a dynamic-route directory")
    func recordsDynamicRouteDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let blogDir = root.appendingPathComponent("src/pages/blog")
        let tagsDir = root.appendingPathComponent("src/pages/tags/[tag]")
        try FileManager.default.createDirectory(at: blogDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tagsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\n---\n".write(to: blogDir.appendingPathComponent("[...slug].astro"), atomically: true, encoding: .utf8)
        try "---\n---\n".write(to: tagsDir.appendingPathComponent("index.astro"), atomically: true, encoding: .utf8)

        let context = GateContext.build(fromSourceDirectory: root)

        #expect(context.dynamicRouteDirectories == ["blog", "tags"])
    }

    @Test("maps a .ts endpoint module to the route it renders at")
    func mapsEndpointRoutes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pagesDir = root.appendingPathComponent("src/pages/articles")
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "export const GET = () => {};\n".write(to: root.appendingPathComponent("src/pages/rss.xml.ts"), atomically: true, encoding: .utf8)
        try "export const GET = () => {};\n".write(to: pagesDir.appendingPathComponent("feed.json.ts"), atomically: true, encoding: .utf8)

        let context = GateContext.build(fromSourceDirectory: root)

        #expect(context.internalRoutes.contains("/rss.xml"))
        #expect(context.internalRoutes.contains("/articles/feed.json"))
    }

    @Test("normalizedRoute strips a trailing slash, query and fragment but keeps the root")
    func normalizesRoutes() {
        #expect(GateContext.normalizedRoute("/blog/") == "/blog")
        #expect(GateContext.normalizedRoute("/blog?page=2") == "/blog")
        #expect(GateContext.normalizedRoute("/blog/#recent") == "/blog")
        #expect(GateContext.normalizedRoute("/") == "/")
        #expect(GateContext.normalizedRoute("/#contact") == "/")
        #expect(GateContext.normalizedRoute("/about") == "/about")
    }

    @Test("an unreadable global.css yields an empty token set instead of throwing")
    func missingCSSYieldsEmptyTokens() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) // never created

        let context = GateContext.build(fromSourceDirectory: root)

        #expect(context.resolvedTokens.isEmpty)
    }
}

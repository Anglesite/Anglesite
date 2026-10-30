// Portable target: the app-owned file set, site-open sync and the deploy gate are Foundation-only,
// and this is the AnglesiteCore test target the Linux CI leg runs.
import AnglesiteSiteModel
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("EmDash overlay refresh (#2177)")
struct EmDashOverlayRefreshTests {
    /// A small template: one file of each app-owned kind, plus the overlay files that stay the
    /// owner's or dependency sync's, and a build-generated `worker/` artifact.
    private static func makeTemplate(in root: URL) throws -> URL {
        let template = root.appendingPathComponent("Template", isDirectory: true)
        let files: [String: String] = [
            "scripts/pre-deploy-check.ts": "// gate v2\n",
            "src/lib/feed-items.ts": "export const feeds = 2;\n",
            "src/pages/rss.xml.ts": "// the template's own feed\n",
            "worker/worker.ts": "export const social = 2;\n",
            "worker/migrations/0001_indieauth.sql": "-- v2\n",
            "worker/experiments.json": "{\"generated\":true}\n",
            "emdash/astro.config.ts": "// overlay config v2\n",
            "emdash/src/worker.ts": "// overlay entry v2\n",
            "emdash/src/lib/syndication-plugin.ts": "// syndication v2\n",
            "emdash/src/pages/rss.xml.ts": "// overlay feed v2\n",
            "emdash/src/pages/articles/[slug].astro": "<!-- article v2 -->\n",
            "emdash/package.json": "{}\n",
            "emdash/seed/seed.json": "{}\n",
            "emdash/README.md": "# overlay\n",
        ]
        for (path, content) in files {
            let url = template.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return template
    }

    private static func makeSite(kind: AnglesitePackage.SiteKind, in root: URL) throws -> AnglesitePackage {
        let (package, _) = try AnglesitePackage.createSkeleton(
            at: root.appendingPathComponent("News.anglesite", isDirectory: true), displayName: "News", kind: kind)
        try FileManager.default.createDirectory(at: package.sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.configURL, withIntermediateDirectories: true)
        return package
    }

    private static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ content: String, to path: String, in source: URL) throws {
        let url = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func read(_ path: String, in source: URL) -> String? {
        try? String(contentsOf: source.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("an EmDash site owns its overlay's code and routes and the social Worker, at their site paths")
    func emdashFileSet() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try Self.makeTemplate(in: root)
        let emdash = try Self.makeSite(kind: .emdash, in: root.appendingPathComponent("e"))

        let files = TemplateScriptsManifest.appOwnedFiles(templateRoot: template, sourceDirectory: emdash.sourceURL)
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.sitePath, $0.templatePath) })
        #expect(byPath == [
            "astro.config.ts": "emdash/astro.config.ts",
            "scripts/pre-deploy-check.ts": "scripts/pre-deploy-check.ts",
            "src/lib/feed-items.ts": "src/lib/feed-items.ts",
            "src/lib/syndication-plugin.ts": "emdash/src/lib/syndication-plugin.ts",
            "src/pages/articles/[slug].astro": "emdash/src/pages/articles/[slug].astro",
            // The overlay's route replaced the template's when the site was made, so it is the pin.
            "src/pages/rss.xml.ts": "emdash/src/pages/rss.xml.ts",
            "src/worker.ts": "emdash/src/worker.ts",
            "worker/migrations/0001_indieauth.sql": "worker/migrations/0001_indieauth.sql",
            "worker/worker.ts": "worker/worker.ts",
        ])
        #expect(files.map(\.sitePath) == files.map(\.sitePath).sorted())
        #expect(TemplateScriptsManifest.templatePath(
            forSitePath: "src/worker.ts", templateRoot: template, sourceDirectory: emdash.sourceURL) == "emdash/src/worker.ts")
    }

    @Test("an Anglesite site's set is unchanged: scripts/ and src/lib/ only")
    func anglesiteFileSet() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try Self.makeTemplate(in: root)
        let site = try Self.makeSite(kind: .anglesite, in: root.appendingPathComponent("a"))

        let files = TemplateScriptsManifest.appOwnedFiles(templateRoot: template, sourceDirectory: site.sourceURL)
        #expect(files.map(\.sitePath) == TemplateScriptsManifest.appOwnedRelativePaths(templateRoot: template))
        #expect(files.allSatisfy { $0.sitePath == $0.templatePath })
        // A directory that isn't a package is an Anglesite site too.
        #expect(TemplateScriptsManifest.appOwnedFiles(templateRoot: template, sourceDirectory: root).count == files.count)
    }

    @Test("opening an existing EmDash site brings its overlay and social Worker up to date")
    func siteOpenSyncRefreshesOverlay() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try Self.makeTemplate(in: root)
        let site = try Self.makeSite(kind: .emdash, in: root.appendingPathComponent("e"))
        let source = site.sourceURL
        // Made with an older overlay: an entry without syndication, and an older social Worker.
        try Self.write("// overlay entry v1\n", to: "src/worker.ts", in: source)
        try Self.write("export const social = 1;\n", to: "worker/worker.ts", in: source)

        let plan = TemplateScriptsSyncChecker.check(
            sourceDirectory: source, configDirectory: site.configURL, templateDirectory: template)
        #expect(plan.toApply.contains(.create(relativePath: "src/lib/syndication-plugin.ts")))
        #expect(Set(plan.divergences.map(\.relativePath)).isSuperset(of: ["src/worker.ts", "worker/worker.ts"]))

        try TemplateScriptsSyncApplier.applyQueued(
            plan.toApply, sourceDirectory: source, configDirectory: site.configURL, templateDirectory: template)
        for divergence in plan.divergences {
            try TemplateScriptsSyncApplier.restore(
                divergence, sourceDirectory: source, configDirectory: site.configURL, templateDirectory: template)
        }
        #expect(Self.read("src/worker.ts", in: source) == "// overlay entry v2\n")
        #expect(Self.read("src/lib/syndication-plugin.ts", in: source) == "// syndication v2\n")
        #expect(Self.read("src/pages/rss.xml.ts", in: source) == "// overlay feed v2\n")
        #expect(Self.read("worker/worker.ts", in: source) == "export const social = 2;\n")
        // Not the app's: dependency sync's, scaffold's, or the site's own build output.
        for path in ["package.json", "seed/seed.json", "README.md", "worker/experiments.json", "emdash/src/worker.ts"] {
            #expect(Self.read(path, in: source) == nil, "\(path)")
        }

        // A second open finds nothing to do.
        let again = TemplateScriptsSyncChecker.check(
            sourceDirectory: source, configDirectory: site.configURL, templateDirectory: template)
        #expect(again.toApply.isEmpty && again.divergences.isEmpty)
    }

    @Test("publishing restores a changed overlay file, as it does a changed script")
    func deployGateRestoresOverlay() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try Self.makeTemplate(in: root)
        let site = try Self.makeSite(kind: .emdash, in: root.appendingPathComponent("e"))
        let source = site.sourceURL
        for file in TemplateScriptsManifest.appOwnedFiles(templateRoot: template, sourceDirectory: source) {
            try Self.write(
                try String(contentsOf: template.appendingPathComponent(file.templatePath), encoding: .utf8),
                to: file.sitePath, in: source)
        }

        let pins = AppOwnedScriptsGate.pins(templateDirectory: template, sourceDirectory: source)
        #expect(pins.first { $0.relativePath == "src/worker.ts" }?.content == Data("// overlay entry v2\n".utf8))
        #expect(AppOwnedScriptsGate.verify(sourceDirectory: source, pins: pins).isIntact)

        try Self.write("// tampered: no gate, no syndication\n", to: "src/pages/articles/[slug].astro", in: source)
        let commits = CommitLog()
        let outcome = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: site.configURL, templateDirectory: template,
            source: "test", logCenter: LogCenter(),
            gitCommitBatch: { _, paths, _ in commits.record(paths); return "abc123" })
        #expect(outcome == .blocked(restored: ["src/pages/articles/[slug].astro"], unrestorable: [], committed: true))
        #expect(Self.read("src/pages/articles/[slug].astro", in: source) == "<!-- article v2 -->\n")
        #expect(commits.paths.contains("src/pages/articles/[slug].astro"))

        let clean = await AppOwnedScriptsGate.enforce(
            sourceDirectory: source, configDirectory: site.configURL, templateDirectory: template,
            source: "test", logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "abc123" })
        #expect(clean == .intact)
    }

    @Test("the gate fails closed when it can't read an overlay file of its own")
    func gateFailsClosedOnUnreadableOverlayFile() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try Self.makeTemplate(in: root)
        let site = try Self.makeSite(kind: .emdash, in: root.appendingPathComponent("e"))
        // Listed by the walk of the overlay, but unreadable even as root: a link to nothing.
        try FileManager.default.createSymbolicLink(
            at: template.appendingPathComponent("emdash/src/lib/locked.ts"),
            withDestinationURL: root.appendingPathComponent("missing.ts"))
        #expect(TemplateScriptsManifest.appOwnedFiles(templateRoot: template, sourceDirectory: site.sourceURL)
            .contains { $0.sitePath == "src/lib/locked.ts" })

        let outcome = await AppOwnedScriptsGate.enforce(
            sourceDirectory: site.sourceURL, configDirectory: site.configURL, templateDirectory: template,
            source: "test", logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "abc123" })
        guard case .unverifiable(let reason) = outcome else {
            Issue.record("expected .unverifiable, got \(outcome)")
            return
        }
        #expect(reason.contains("src/lib/locked.ts"))
    }

    @Test("pins without a site are the plain set, as before")
    func pinsWithoutSite() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try Self.makeTemplate(in: root)
        let pins = AppOwnedScriptsGate.pins(templateDirectory: template)
        #expect(pins.map(\.relativePath) == TemplateScriptsManifest.appOwnedRelativePaths(templateRoot: template))
        #expect(pins.first { $0.relativePath == "src/lib/feed-items.ts" }?.content == Data("export const feeds = 2;\n".utf8))
        // An Anglesite site's pins are the same set.
        let site = try Self.makeSite(kind: .anglesite, in: root.appendingPathComponent("a"))
        #expect(AppOwnedScriptsGate.pins(templateDirectory: template, sourceDirectory: site.sourceURL) == pins)
    }

    @Test("a restored overlay route is named for what readers see, once")
    func ownerFacingNames() {
        #expect(AppOwnedFileDescription.summary(for: [
            "src/pages/articles/[slug].astro", "src/pages/articles/index.astro",
            "src/pages/tags/[tag]/index.astro", "src/worker.ts", "worker/worker.ts",
        ]) == ["Article pages", "Tag pages", "2 site framework files"])
    }

    @Test("the real template's overlay is covered: entry, syndication, routes, config and the social Worker")
    func realTemplate() throws {
        let template = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Template")
        let overlay = TemplateScriptsManifest.emdashOverlayFiles(templateRoot: template)
        let sitePaths = Set(overlay.map(\.sitePath))
        for path in [
            "astro.config.ts", "src/worker.ts", "src/middleware.ts", "src/live.config.ts",
            "src/lib/syndication-plugin.ts", "src/lib/federation-record.ts", "src/pages/articles/[slug].astro",
            "src/pages/rss.xml.ts", "src/pages/tags/[tag]/index.astro", "worker/worker.ts",
        ] {
            #expect(sitePaths.contains(path), "\(path)")
        }
        for path in ["package.json", "package-lock.json", "seed/seed.json", "README.md", "tsconfig.json",
                     "worker/experiments.json", "worker/mcp-config.json"] {
            #expect(!sitePaths.contains(path), "\(path)")
        }
        // Every pin is a file the app can read.
        for file in overlay {
            #expect(FileManager.default.isReadableFile(atPath: template.appendingPathComponent(file.templatePath).path), "\(file.templatePath)")
        }
    }
}

/// The paths each gate commit was asked to record.
private final class CommitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var paths: [String] { lock.withLock { recorded } }
    func record(_ paths: [String]) { lock.withLock { recorded += paths } }
}

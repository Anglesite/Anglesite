// Portable target: site-open sync is Foundation-only, and this is the AnglesiteCore test target
// the Linux CI leg runs.
import AnglesiteSiteModel
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("Site sync removes app-owned files a later template drops (#2179)")
struct TemplateScriptsPruneTests {
    private static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sync-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ content: String, to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func exists(_ path: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    private static func makeSite(kind: AnglesitePackage.SiteKind, in root: URL) throws -> AnglesitePackage {
        let (package, _) = try AnglesitePackage.createSkeleton(
            at: root.appendingPathComponent("Site.anglesite", isDirectory: true), displayName: "Site", kind: kind)
        try FileManager.default.createDirectory(at: package.sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.configURL, withIntermediateDirectories: true)
        return package
    }

    /// A site whose first sync wrote `files` from a template, and that template, now trimmed to
    /// `kept`: what a later app version that dropped the rest looks like.
    private static func syncedThenDropped(
        kind: AnglesitePackage.SiteKind = .anglesite,
        files: [String: String],
        kept: Set<String>,
        in root: URL
    ) throws -> (site: AnglesitePackage, template: URL) {
        let template = root.appendingPathComponent("Template", isDirectory: true)
        for (path, content) in files { try write(content, to: path, in: template) }
        let site = try makeSite(kind: kind, in: root)
        let first = TemplateScriptsSyncChecker.check(
            sourceDirectory: site.sourceURL, configDirectory: site.configURL, templateDirectory: template)
        try TemplateScriptsSyncApplier.applyQueued(
            first.toApply, sourceDirectory: site.sourceURL, configDirectory: site.configURL, templateDirectory: template)
        for path in files.keys where !kept.contains(path) {
            try FileManager.default.removeItem(at: template.appendingPathComponent(path))
        }
        return (site, template)
    }

    private static let gate = "scripts/pre-deploy-check.ts"

    @Test("an unchanged dropped file is removed, its empty folder too, and the removal is handed to the commit and reported")
    func unchangedDroppedFileIsRemoved() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (site, template) = try Self.syncedThenDropped(
            files: [Self.gate: "// gate\n", "scripts/retired/old.ts": "// old\n", "src/lib/kept.ts": "// kept\n"],
            kept: [Self.gate, "src/lib/kept.ts"], in: root)
        try Self.write("SECURITY_TXT_MODE=disabled\n", to: ".site-config", in: site.sourceURL)

        let report = await ExistingSiteMigration.runNoninteractively(
            sourceDirectory: site.sourceURL, configDirectory: site.configURL, templateDirectory: template,
            source: "test", logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "sha" })

        #expect(report.removedPaths == ["scripts/retired/old.ts"])
        #expect(report.releasedPaths.isEmpty)
        #expect(!Self.exists("scripts/retired/old.ts", in: site.sourceURL))
        #expect(!Self.exists("scripts/retired", in: site.sourceURL))
        #expect(Self.exists("scripts", in: site.sourceURL))
        // Handed to the committer, which stages a tracked path's deletion.
        #expect(report.touchedPaths.contains("scripts/retired/old.ts"))
        #expect(TemplateScriptsBaseline.load(from: site.configURL).files["scripts/retired/old.ts"] == nil)

        let notice = SiteOpenUpdateNotice.build(migration: report, dependencyOffers: nil)
        #expect(notice?.details.contains("Removed, because Anglesite no longer uses them: 1 site framework file.") == true)

        // Nothing left to do on the next open.
        #expect(TemplateScriptsSyncChecker.check(
            sourceDirectory: site.sourceURL, configDirectory: site.configURL, templateDirectory: template).isEmpty)
    }

    @Test("a dropped file the owner changed stays as theirs, and the app stops keeping it")
    func changedDroppedFileIsReleased() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (site, template) = try Self.syncedThenDropped(
            files: [Self.gate: "// gate\n", "scripts/redirects.ts": "// app's\n"], kept: [Self.gate], in: root)
        try Self.write("// owner's\n", to: "scripts/redirects.ts", in: site.sourceURL)
        try Self.write("SECURITY_TXT_MODE=disabled\n", to: ".site-config", in: site.sourceURL)

        let report = await ExistingSiteMigration.runNoninteractively(
            sourceDirectory: site.sourceURL, configDirectory: site.configURL, templateDirectory: template,
            source: "test", logCenter: LogCenter(), gitCommitBatch: { _, _, _ in "sha" })

        #expect(report.removedPaths.isEmpty)
        #expect(report.releasedPaths == ["scripts/redirects.ts"])
        #expect(!report.touchedPaths.contains("scripts/redirects.ts"))
        #expect(try String(contentsOf: site.sourceURL.appendingPathComponent("scripts/redirects.ts"), encoding: .utf8) == "// owner's\n")
        #expect(TemplateScriptsBaseline.load(from: site.configURL).files["scripts/redirects.ts"] == nil)

        let notice = SiteOpenUpdateNotice.build(migration: report, dependencyOffers: nil)
        #expect(notice?.message == "Anglesite kept part of this site as it is — see Details.")
        #expect(notice?.details == ["Kept as yours, because you had changed them and Anglesite no longer uses them: Redirects."])

        // Released for good: a later open neither removes nor reports it again.
        let again = TemplateScriptsSyncChecker.check(
            sourceDirectory: site.sourceURL, configDirectory: site.configURL, templateDirectory: template)
        #expect(again.isEmpty && again.releasedCustomized.isEmpty)
    }

    @Test("a dropped file already gone just drops its baseline entry")
    func missingDroppedFileForgotten() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (site, template) = try Self.syncedThenDropped(
            files: [Self.gate: "// gate\n", "scripts/old.ts": "// old\n"], kept: [Self.gate], in: root)
        try FileManager.default.removeItem(at: site.sourceURL.appendingPathComponent("scripts/old.ts"))

        let plan = TemplateScriptsSyncChecker.check(
            sourceDirectory: site.sourceURL, configDirectory: site.configURL, templateDirectory: template)
        #expect(plan.isEmpty && plan.releasedCustomized.isEmpty)
        #expect(TemplateScriptsBaseline.load(from: site.configURL).files["scripts/old.ts"] == nil)
    }

    @Test("nothing is pruned from a template read without its gate, or a site whose kind isn't known")
    func noPruneWhenTheSetCantBeTrusted() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // A template missing its gate: likely an incomplete copy, not a deliberate drop.
        let (site, template) = try Self.syncedThenDropped(
            files: [Self.gate: "// gate\n", "scripts/a.ts": "// a\n"], kept: [], in: root.appendingPathComponent("1"))
        let partial = TemplateScriptsSyncChecker.check(
            sourceDirectory: site.sourceURL, configDirectory: site.configURL, templateDirectory: template)
        #expect(partial.toRemove.isEmpty && partial.releasedCustomized.isEmpty)
        #expect(TemplateScriptsBaseline.load(from: site.configURL).files["scripts/a.ts"] != nil)

        // A marker from a newer app: its overlay files would all look dropped.
        let (newer, newerTemplate) = try Self.syncedThenDropped(
            kind: .unrecognized("future"), files: [Self.gate: "// gate\n", "scripts/a.ts": "// a\n"],
            kept: [Self.gate], in: root.appendingPathComponent("2"))
        let unknown = TemplateScriptsSyncChecker.check(
            sourceDirectory: newer.sourceURL, configDirectory: newer.configURL, templateDirectory: newerTemplate)
        #expect(unknown.toRemove.isEmpty)
        #expect(Self.exists("scripts/a.ts", in: newer.sourceURL))
    }

    @Test("an EmDash route a later overlay drops is removed at its site path")
    func emdashOverlayRouteDropped() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (site, template) = try Self.syncedThenDropped(
            kind: .emdash,
            files: [
                Self.gate: "// gate\n",
                "emdash/src/worker.ts": "// entry\n",
                "emdash/src/pages/tags/index.astro": "<!-- tags -->\n",
            ],
            kept: [Self.gate, "emdash/src/worker.ts"], in: root)
        #expect(TemplateScriptsBaseline.load(from: site.configURL).files["src/pages/tags/index.astro"] != nil)

        let plan = TemplateScriptsSyncChecker.check(
            sourceDirectory: site.sourceURL, configDirectory: site.configURL, templateDirectory: template)
        #expect(plan.toRemove == ["src/pages/tags/index.astro"])
        try TemplateScriptsSyncApplier.remove(
            relativePath: "src/pages/tags/index.astro", sourceDirectory: site.sourceURL, configDirectory: site.configURL)
        #expect(!Self.exists("src/pages/tags", in: site.sourceURL))
        #expect(Self.exists("src/worker.ts", in: site.sourceURL))
    }
}

import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite struct TemplateScriptsManifestTests {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func writeFile(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func excludesScaffoldInfraAndTopLevelTestFilesOnly() throws {
        let root = tmpDir()
        let scripts = root.appendingPathComponent("scripts")
        try writeFile("keep", to: scripts.appendingPathComponent("keep.ts"))
        try writeFile("scaffold", to: scripts.appendingPathComponent("scaffold.sh"))
        try writeFile("themes", to: scripts.appendingPathComponent("themes.ts"))
        try writeFile("themesjson", to: scripts.appendingPathComponent("themes.json"))
        try writeFile("checkpack", to: scripts.appendingPathComponent("check-pack.ts"))
        try writeFile("buildpacks", to: scripts.appendingPathComponent("build-packs.sh"))
        try writeFile("drop", to: scripts.appendingPathComponent("drop.test.ts"))
        try writeFile("adapter", to: scripts.appendingPathComponent("embeds/adapter.ts"))
        try writeFile("adapterTest", to: scripts.appendingPathComponent("embeds/adapter.test.ts"))
        try writeFile("fixture", to: scripts.appendingPathComponent("embeds/fixtures/data.json"))

        let result = TemplateScriptsManifest.appOwnedRelativePaths(templateRoot: root)

        #expect(result == [
            "scripts/embeds/adapter.test.ts",
            "scripts/embeds/adapter.ts",
            "scripts/embeds/fixtures/data.json",
            "scripts/keep.ts",
        ])
    }

    @Test func returnsEmptyWhenScriptsDirectoryIsMissing() {
        let root = tmpDir()
        #expect(TemplateScriptsManifest.appOwnedRelativePaths(templateRoot: root).isEmpty)
    }

    @Test func excludesDSStoreAtAnyDepthButNoOtherDotfiles() throws {
        let root = tmpDir()
        let scripts = root.appendingPathComponent("scripts")
        try writeFile("keep", to: scripts.appendingPathComponent("keep.ts"))
        try writeFile("ds1", to: scripts.appendingPathComponent(".DS_Store"))
        try writeFile("ds2", to: scripts.appendingPathComponent("embeds/.DS_Store"))
        // Not `.DS_Store` — a real dotfile that `scaffold.sh`'s rsync would still copy, and that
        // `.skipsHiddenFiles` would have wrongly dropped.
        try writeFile("dotfile", to: scripts.appendingPathComponent(".env.example"))

        let result = TemplateScriptsManifest.appOwnedRelativePaths(templateRoot: root)

        #expect(result == [
            "scripts/.env.example",
            "scripts/keep.ts",
        ])
    }

    // MARK: - src/lib

    @Test func includesEverySrcLibFileIncludingTestFiles() throws {
        // Unlike `scripts/`, `scaffold.sh` has no `src/lib/*` excludes at all — every file there
        // (including `.test.ts` files) is already shipped to every scaffolded site, so the
        // app-owned manifest must not invent a `.test.ts` exclusion `scaffold.sh` doesn't have.
        let root = tmpDir()
        let lib = root.appendingPathComponent("src/lib")
        try writeFile("robots", to: lib.appendingPathComponent("robots-config.ts"))
        try writeFile("robotsTest", to: lib.appendingPathComponent("robots-config.test.ts"))
        try writeFile("licensing", to: lib.appendingPathComponent("licensing.ts"))

        let result = TemplateScriptsManifest.appOwnedRelativePaths(templateRoot: root)

        #expect(result == [
            "src/lib/licensing.ts",
            "src/lib/robots-config.test.ts",
            "src/lib/robots-config.ts",
        ])
    }

    @Test func combinesScriptsAndSrcLibIntoOneSortedList() throws {
        let root = tmpDir()
        try writeFile("keep", to: root.appendingPathComponent("scripts/keep.ts"))
        try writeFile("lib", to: root.appendingPathComponent("src/lib/rsl.ts"))

        let result = TemplateScriptsManifest.appOwnedRelativePaths(templateRoot: root)

        #expect(result == [
            "scripts/keep.ts",
            "src/lib/rsl.ts",
        ])
    }

    @Test func returnsEmptyWhenSrcLibDirectoryIsMissing() {
        let root = tmpDir()
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true
        )
        #expect(TemplateScriptsManifest.appOwnedRelativePaths(templateRoot: root).isEmpty)
    }

    @Test func excludesDSStoreUnderSrcLib() throws {
        let root = tmpDir()
        let lib = root.appendingPathComponent("src/lib")
        try writeFile("keep", to: lib.appendingPathComponent("keep.ts"))
        try writeFile("ds", to: lib.appendingPathComponent(".DS_Store"))

        let result = TemplateScriptsManifest.appOwnedRelativePaths(templateRoot: root)

        #expect(result == ["src/lib/keep.ts"])
    }

    // MARK: - Real template regression (#1426)

    /// Pins this manifest against the actual in-repo template rather than only a synthetic
    /// fixture — #1426 happened because `scaffold.sh`'s own exclude list and this hand-maintained
    /// Swift mirror silently drifted apart. A synthetic-fixture-only test can't catch that kind of
    /// drift; only checking the real files can.
    @Test func matchesScaffoldShsExcludesAgainstTheRealTemplate() throws {
        let paths = Set(TemplateScriptsManifest.appOwnedRelativePaths(templateRoot: try templateRoot()))

        // scaffold.sh excludes these outright (pack-authoring tooling, not site runtime code) —
        // shipping them into a site breaks its `./themes` import, since `themes.ts`/`themes.json`
        // are correctly excluded right alongside them.
        for excluded in ["scripts/check-pack.ts", "scripts/build-packs.sh", "scripts/scaffold.sh", "scripts/themes.ts", "scripts/themes.json"] {
            #expect(!paths.contains(excluded), "\(excluded) should never be app-owned")
        }

        // The framework modules #1426's synced scripts actually import at build time — these must
        // be part of the app-owned set or an existing-site migration ships call sites without their
        // dependencies.
        for required in ["src/lib/robots-config.ts", "src/lib/rsl.ts", "src/lib/licensing.ts", "src/lib/embed-card.ts"] {
            #expect(paths.contains(required), "\(required) must be app-owned so migrated scripts keep a working import")
        }
    }
}

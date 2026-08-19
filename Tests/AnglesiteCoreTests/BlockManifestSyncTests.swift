import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct BlockManifestSyncTests {
    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A throwaway (template root, site root) pair. Component paths resolve against these, since
    /// the manifest sits at each root.
    private func makeRoots() -> (template: URL, site: URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (tmp.appendingPathComponent("template"), tmp.appendingPathComponent("site"))
    }

    private func manifestJSON(_ paths: [String]) -> String {
        let modules = paths.map { path -> String in
            let name = (path as NSString).deletingPathExtension.components(separatedBy: "/").last ?? path
            return "{\"path\":\"\(path)\",\"export\":\"\(name)\",\"kind\":\"astro\",\"name\":\"\(name)\",\"description\":\"d\",\"icon\":null,\"propEditors\":[],\"slots\":[]}"
        }
        return "{\"schemaVersion\":\"anglesite-block-manifest/1\",\"modules\":[\(modules.joined(separator: ","))]}"
    }

    private static let particleField = "src/components/effects/ParticleField.astro"
    private static let auroraGradient = "src/components/effects/AuroraGradient.astro"

    @Test func createsManifestWhenSiteHasNone() throws {
        let roots = makeRoots()
        try write(manifestJSON([Self.particleField]), to: roots.template.appendingPathComponent("blocks.manifest.json"))
        try write("<canvas />", to: roots.template.appendingPathComponent(Self.particleField))

        let outcome = try BlockManifestSync.sync(
            templateBlocksManifest: roots.template.appendingPathComponent("blocks.manifest.json"),
            siteBlocksManifest: roots.site.appendingPathComponent("blocks.manifest.json"))

        let written = try String(contentsOf: roots.site.appendingPathComponent("blocks.manifest.json"), encoding: .utf8)
        #expect(written.contains("ParticleField"))
        #expect(outcome.didWriteManifest)
        #expect(outcome.addedPaths == [Self.particleField])
    }

    @Test func appendsOnlyMissingEntriesByPath() throws {
        let roots = makeRoots()
        try write(manifestJSON([Self.particleField, Self.auroraGradient]), to: roots.template.appendingPathComponent("blocks.manifest.json"))
        try write("<canvas />", to: roots.template.appendingPathComponent(Self.particleField))
        try write("<canvas />", to: roots.template.appendingPathComponent(Self.auroraGradient))
        let siteManifest = roots.site.appendingPathComponent("blocks.manifest.json")
        let siteJSON = "{\"schemaVersion\":\"anglesite-block-manifest/1\",\"modules\":[{\"path\":\"\(Self.particleField)\",\"export\":\"ParticleField\",\"kind\":\"astro\",\"name\":\"CUSTOMIZED BY OWNER\",\"description\":\"d\",\"icon\":null,\"propEditors\":[],\"slots\":[]}]}"
        try write(siteJSON, to: siteManifest)

        try BlockManifestSync.sync(
            templateBlocksManifest: roots.template.appendingPathComponent("blocks.manifest.json"),
            siteBlocksManifest: siteManifest)

        let written = try String(contentsOf: siteManifest, encoding: .utf8)
        #expect(written.contains("CUSTOMIZED BY OWNER")) // untouched
        #expect(written.contains("AuroraGradient")) // appended
        // Verify only one ParticleField entry (not duplicated) by checking it appears exactly twice:
        // once in "export":"ParticleField" and once in the path. Split gives 3 components.
        #expect(written.components(separatedBy: "ParticleField").count == 3) // not duplicated
    }

    @Test func throwsOnCorruptSiteManifest() throws {
        let roots = makeRoots()
        let templateManifest = roots.template.appendingPathComponent("blocks.manifest.json")
        let siteManifest = roots.site.appendingPathComponent("blocks.manifest.json")
        try write(manifestJSON([]), to: templateManifest)

        // Test case 1: valid JSON but missing "modules" key
        let corruptJSON1 = "{\"schemaVersion\":\"anglesite-block-manifest/1\"}"
        try write(corruptJSON1, to: siteManifest)

        #expect(throws: BlockManifestSync.SyncError.corruptSiteManifest) {
            try BlockManifestSync.sync(templateBlocksManifest: templateManifest, siteBlocksManifest: siteManifest)
        }

        // Verify original corrupt file is untouched
        let stillThere = try String(contentsOf: siteManifest, encoding: .utf8)
        #expect(stillThere == corruptJSON1)

        // Test case 2: valid JSON but "modules" is not an array
        let corruptJSON2 = "{\"schemaVersion\":\"anglesite-block-manifest/1\",\"modules\":{}}"
        try write(corruptJSON2, to: siteManifest)

        #expect(throws: BlockManifestSync.SyncError.corruptSiteManifest) {
            try BlockManifestSync.sync(templateBlocksManifest: templateManifest, siteBlocksManifest: siteManifest)
        }

        // Verify original corrupt file is untouched
        let stillThere2 = try String(contentsOf: siteManifest, encoding: .utf8)
        #expect(stillThere2 == corruptJSON2)
    }

    // MARK: - Component files (#768 final review, Finding 3)

    @Test func copiesMissingComponentFilesIntoTheSite() throws {
        let roots = makeRoots()
        try write(manifestJSON([Self.particleField]), to: roots.template.appendingPathComponent("blocks.manifest.json"))
        try write("<canvas data-particle-field />", to: roots.template.appendingPathComponent(Self.particleField))

        let outcome = try BlockManifestSync.sync(
            templateBlocksManifest: roots.template.appendingPathComponent("blocks.manifest.json"),
            siteBlocksManifest: roots.site.appendingPathComponent("blocks.manifest.json"))

        let copied = roots.site.appendingPathComponent(Self.particleField)
        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(try String(contentsOf: copied, encoding: .utf8) == "<canvas data-particle-field />")
        #expect(outcome.copiedComponentPaths == [Self.particleField])
    }

    @Test func neverOverwritesAComponentTheOwnerAlreadyEdited() throws {
        let roots = makeRoots()
        try write(manifestJSON([Self.particleField]), to: roots.template.appendingPathComponent("blocks.manifest.json"))
        try write("<canvas />", to: roots.template.appendingPathComponent(Self.particleField))
        try write("MY OWN VERSION", to: roots.site.appendingPathComponent(Self.particleField))

        let outcome = try BlockManifestSync.sync(
            templateBlocksManifest: roots.template.appendingPathComponent("blocks.manifest.json"),
            siteBlocksManifest: roots.site.appendingPathComponent("blocks.manifest.json"))

        #expect(try String(contentsOf: roots.site.appendingPathComponent(Self.particleField), encoding: .utf8) == "MY OWN VERSION")
        #expect(outcome.copiedComponentPaths.isEmpty)
        #expect(outcome.addedPaths == [Self.particleField]) // still registered — the file is there
    }

    @Test func skipsRegisteringAnEntryWhoseComponentFileCantBeMadeToExist() throws {
        let roots = makeRoots()
        // Template manifest lists two effects but only ships one component file.
        try write(manifestJSON([Self.particleField, Self.auroraGradient]), to: roots.template.appendingPathComponent("blocks.manifest.json"))
        try write("<canvas />", to: roots.template.appendingPathComponent(Self.particleField))

        let outcome = try BlockManifestSync.sync(
            templateBlocksManifest: roots.template.appendingPathComponent("blocks.manifest.json"),
            siteBlocksManifest: roots.site.appendingPathComponent("blocks.manifest.json"))

        let written = try String(contentsOf: roots.site.appendingPathComponent("blocks.manifest.json"), encoding: .utf8)
        #expect(written.contains("ParticleField"))
        // A dangling entry would make the sidecar import a file that doesn't exist, breaking the
        // owner's Astro build — better unregistered than dangling.
        #expect(!written.contains("AuroraGradient"))
        #expect(outcome.skippedMissingComponentPaths == [Self.auroraGradient])
    }

    // MARK: - No-op writes (#768 final review, Finding 7)

    @Test func leavesTheOwnersManifestByteIdenticalWhenNothingIsMissing() throws {
        let roots = makeRoots()
        try write(manifestJSON([Self.particleField]), to: roots.template.appendingPathComponent("blocks.manifest.json"))
        try write("<canvas />", to: roots.template.appendingPathComponent(Self.particleField))
        try write("<canvas />", to: roots.site.appendingPathComponent(Self.particleField))
        let siteManifest = roots.site.appendingPathComponent("blocks.manifest.json")
        // Deliberately hand-formatted: different key order and indentation from what
        // `JSONSerialization` would emit, i.e. exactly the shape a rewrite would churn.
        let ownersFormatting = """
        {
          "modules": [
            { "export": "ParticleField", "path": "\(Self.particleField)", "kind": "astro", "name": "Particle Field", "description": "d", "propEditors": [], "slots": [] }
          ],
          "schemaVersion": "anglesite-block-manifest/1"
        }
        """
        try write(ownersFormatting, to: siteManifest)
        let before = try Data(contentsOf: siteManifest)
        let modifiedBefore = try FileManager.default.attributesOfItem(atPath: siteManifest.path)[.modificationDate] as? Date

        let outcome = try BlockManifestSync.sync(
            templateBlocksManifest: roots.template.appendingPathComponent("blocks.manifest.json"),
            siteBlocksManifest: siteManifest)

        #expect(!outcome.didWriteManifest)
        #expect(outcome.addedPaths.isEmpty)
        #expect(try Data(contentsOf: siteManifest) == before)
        let modifiedAfter = try FileManager.default.attributesOfItem(atPath: siteManifest.path)[.modificationDate] as? Date
        #expect(modifiedAfter == modifiedBefore)
    }
}

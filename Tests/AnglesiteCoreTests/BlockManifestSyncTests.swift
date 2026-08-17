import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct BlockManifestSyncTests {
    private func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func createsManifestWhenSiteHasNone() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let templateManifest = tmp.appendingPathComponent("template/blocks.manifest.json")
        let siteManifest = tmp.appendingPathComponent("site/blocks.manifest.json")
        let templateJSON = "{\"schemaVersion\":\"anglesite-block-manifest/1\",\"modules\":[{\"path\":\"src/components/effects/ParticleField.astro\",\"export\":\"ParticleField\",\"kind\":\"astro\",\"name\":\"Particle Field\",\"description\":\"d\",\"icon\":null,\"propEditors\":[],\"slots\":[]}]}"
        try write(templateJSON, to: templateManifest)

        try BlockManifestSync.sync(templateBlocksManifest: templateManifest, siteBlocksManifest: siteManifest)

        let written = try String(contentsOf: siteManifest, encoding: .utf8)
        #expect(written.contains("ParticleField"))
    }

    @Test func appendsOnlyMissingEntriesByPath() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let templateManifest = tmp.appendingPathComponent("template/blocks.manifest.json")
        let siteManifest = tmp.appendingPathComponent("site/blocks.manifest.json")
        let templateJSON = "{\"schemaVersion\":\"anglesite-block-manifest/1\",\"modules\":[{\"path\":\"src/components/effects/ParticleField.astro\",\"export\":\"ParticleField\",\"kind\":\"astro\",\"name\":\"Particle Field\",\"description\":\"d\",\"icon\":null,\"propEditors\":[],\"slots\":[]},{\"path\":\"src/components/effects/AuroraGradient.astro\",\"export\":\"AuroraGradient\",\"kind\":\"astro\",\"name\":\"Aurora Gradient\",\"description\":\"d\",\"icon\":null,\"propEditors\":[],\"slots\":[]}]}"
        try write(templateJSON, to: templateManifest)
        let siteJSON = "{\"schemaVersion\":\"anglesite-block-manifest/1\",\"modules\":[{\"path\":\"src/components/effects/ParticleField.astro\",\"export\":\"ParticleField\",\"kind\":\"astro\",\"name\":\"CUSTOMIZED BY OWNER\",\"description\":\"d\",\"icon\":null,\"propEditors\":[],\"slots\":[]}]}"
        try write(siteJSON, to: siteManifest)

        try BlockManifestSync.sync(templateBlocksManifest: templateManifest, siteBlocksManifest: siteManifest)

        let written = try String(contentsOf: siteManifest, encoding: .utf8)
        #expect(written.contains("CUSTOMIZED BY OWNER")) // untouched
        #expect(written.contains("AuroraGradient")) // appended
        // Verify only one ParticleField entry (not duplicated) by checking it appears exactly twice:
        // once in "export":"ParticleField" and once in the path. Split gives 3 components.
        #expect(written.components(separatedBy: "ParticleField").count == 3) // not duplicated
    }
}

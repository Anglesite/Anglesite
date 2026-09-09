import Testing
import Foundation
@testable import AnglesiteCore

struct WorkerNameRenameTests {
    /// A bare `Source/` + `Config/` pair: `wrangler.toml` lives in `Config/` (#1960), `.site-config`
    /// in `Source/`.
    private func makeSite(wranglerToml: String?, siteConfig: String = "") -> (source: URL, config: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let config = root.appendingPathComponent("Config", isDirectory: true)
        try! FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        if let wranglerToml {
            try! WranglerConfigFile.write(wranglerToml, configDirectory: config)
        }
        if !siteConfig.isEmpty {
            try! siteConfig.write(to: source.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        }
        return (source, config)
    }

    @Test("Rewrites only the name line, leaving the rest of Config/wrangler.toml untouched")
    func rewritesNameLineOnly() throws {
        let toml = """
        name = "old-name"
        compatibility_date = "2026-07-15"
        compatibility_flags = ["nodejs_compat"]

        [assets]
        directory = "dist"
        """
        let site = makeSite(wranglerToml: toml, siteConfig: "CF_PROJECT_NAME=old-name\nSITE_NAME=My Site\n")

        try WorkerNameRename.apply(newName: "new-name", siteDirectory: site.source, configDirectory: site.config)

        let updatedToml = try #require(WranglerConfigFile.read(configDirectory: site.config))
        #expect(updatedToml.contains(#"name = "new-name""#))
        #expect(updatedToml.contains(#"compatibility_date = "2026-07-15""#))
        #expect(updatedToml.contains("[assets]"))
        #expect(!FileManager.default.fileExists(atPath: site.source.appendingPathComponent("wrangler.toml").path),
                "a rename must never re-create wrangler.toml inside the clonable Source/ repo")
    }

    @Test("Updates CF_PROJECT_NAME in .site-config without disturbing other keys")
    func updatesSiteConfig() throws {
        let site = makeSite(
            wranglerToml: #"name = "old-name""#,
            siteConfig: "CF_PROJECT_NAME=old-name\nSITE_NAME=My Site\n"
        )

        try WorkerNameRename.apply(newName: "new-name", siteDirectory: site.source, configDirectory: site.config)

        let config = try String(contentsOf: site.source.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config) == "new-name")
        #expect(SiteConfigFile.value(forKey: "SITE_NAME", in: config) == "My Site")
    }

    @Test("Rejects an invalid name before touching any file")
    func rejectsInvalidName() throws {
        let site = makeSite(wranglerToml: #"name = "old-name""#, siteConfig: "CF_PROJECT_NAME=old-name\n")

        #expect(throws: WorkerNameRename.RenameError.invalidName("bad name!")) {
            try WorkerNameRename.apply(newName: "bad name!", siteDirectory: site.source, configDirectory: site.config)
        }

        let toml = try #require(WranglerConfigFile.read(configDirectory: site.config))
        #expect(toml.contains(#"name = "old-name""#), "wrangler.toml must be untouched on rejection")
    }

    @Test("Throws wranglerConfigMissing when Config/ has no wrangler.toml")
    func throwsWhenWranglerConfigMissing() throws {
        let site = makeSite(wranglerToml: nil, siteConfig: "CF_PROJECT_NAME=old-name\n")

        #expect(throws: WorkerNameRename.RenameError.wranglerConfigMissing) {
            try WorkerNameRename.apply(newName: "new-name", siteDirectory: site.source, configDirectory: site.config)
        }
        let config = try String(contentsOf: site.source.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config) == "old-name", ".site-config must be untouched")
    }

    @Test("Throws nameLineNotFound when wrangler.toml has no name line")
    func throwsWhenNameLineMissing() throws {
        let site = makeSite(wranglerToml: "compatibility_date = \"2026-07-15\"\n", siteConfig: "CF_PROJECT_NAME=old-name\n")

        #expect(throws: WorkerNameRename.RenameError.nameLineNotFound) {
            try WorkerNameRename.apply(newName: "new-name", siteDirectory: site.source, configDirectory: site.config)
        }
    }
}

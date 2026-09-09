import Testing
import Foundation
@testable import AnglesiteCore

final class UntitledSitePropagationTests {
    private var createdDirs: [URL] = []

    deinit {
        for dir in createdDirs { try? FileManager.default.removeItem(at: dir) }
    }

    /// A bare `Source/` directory; its `Config/` sibling (#1960) holds `wrangler.toml` and the
    /// deploy markers (`settings`).
    private func makeSiteDirectory(
        siteConfig: String, wranglerToml: String? = #"name = "untitled""#, settings: SiteSettings? = nil
    ) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dir = root.appendingPathComponent("Source", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! siteConfig.write(to: dir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        if let wranglerToml {
            try! WranglerConfigFile.write(wranglerToml, configDirectory: configDirectory(for: dir))
        }
        if let settings {
            try! SiteConfigStore.write(settings, to: configDirectory(for: dir))
        }
        createdDirs.append(root)
        return dir
    }

    private func configDirectory(for siteDirectory: URL) -> URL {
        siteDirectory.deletingLastPathComponent().appendingPathComponent("Config", isDirectory: true)
    }

    private func propagate(_ name: String, in dir: URL) {
        UntitledSitePropagation.propagateIfUntitled(newDisplayName: name, siteDirectory: dir, configDirectory: configDirectory(for: dir))
    }

    @Test("Propagates SITE_NAME, CF_PROJECT_NAME, and wrangler.toml name for a virgin untitled site")
    func propagatesForVirginUntitledSite() throws {
        let dir = makeSiteDirectory(siteConfig: "SITE_NAME=Untitled\nCF_PROJECT_NAME=untitled\nTAGLINE=hi\n")

        propagate("Acme Bakery", in: dir)

        let config = try String(contentsOf: dir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "SITE_NAME", in: config) == "Acme Bakery")
        #expect(SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config) == "acme-bakery")
        #expect(SiteConfigFile.value(forKey: "TAGLINE", in: config) == "hi", "unrelated keys must survive")
        let toml = try #require(WranglerConfigFile.read(configDirectory: configDirectory(for: dir)))
        #expect(toml.contains(#"name = "acme-bakery""#))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("wrangler.toml").path),
                "propagation must never create wrangler.toml inside Source/")
    }

    @Test("Propagates for a virgin site still carrying the chooser's numbered 'Untitled N' default")
    func propagatesForNumberedUntitledSite() throws {
        let dir = makeSiteDirectory(siteConfig: "SITE_NAME=Untitled 3\nCF_PROJECT_NAME=untitled-3\n")

        propagate("My Blog", in: dir)

        let config = try String(contentsOf: dir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "SITE_NAME", in: config) == "My Blog")
        #expect(SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config) == "my-blog")
    }

    @Test("Propagates a second pre-publish rename too, as long as CF_PROJECT_NAME still matches the previous name's derived slug")
    func propagatesSecondPrePublishRename() throws {
        // Simulates: scaffold as "Untitled" -> rename to "My Blog" (first propagation already
        // applied) -> rename again to "Dave's Blog", still before any deploy.
        let dir = makeSiteDirectory(siteConfig: "SITE_NAME=My Blog\nCF_PROJECT_NAME=my-blog\n")

        propagate("Dave's Blog", in: dir)

        let config = try String(contentsOf: dir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "SITE_NAME", in: config) == "Dave's Blog")
        #expect(SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config) == "dave-s-blog")
    }

    @Test("No-ops once the site has deployed (SiteSettings.workerDeployed, #1960)")
    func noOpWhenDeployed() throws {
        let dir = makeSiteDirectory(
            siteConfig: "SITE_NAME=Untitled\nCF_PROJECT_NAME=untitled\n", settings: SiteSettings(workerDeployed: true))

        propagate("Acme Bakery", in: dir)

        let config = try String(contentsOf: dir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "SITE_NAME", in: config) == "Untitled")
        #expect(SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config) == "untitled")
    }

    @Test("No-ops once the site's Worker name is provisioned (SiteSettings.workerProvisioned, #1960)")
    func noOpWhenProvisioned() throws {
        let dir = makeSiteDirectory(
            siteConfig: "SITE_NAME=Untitled\nCF_PROJECT_NAME=untitled\n", settings: SiteSettings(workerProvisioned: true))

        propagate("Acme Bakery", in: dir)

        let config = try String(contentsOf: dir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "SITE_NAME", in: config) == "Untitled")
    }

    @Test("No-ops when CF_PROJECT_NAME was hand-customized away from the derived slug")
    func noOpWhenProjectNameCustomized() throws {
        let dir = makeSiteDirectory(siteConfig: "SITE_NAME=Untitled\nCF_PROJECT_NAME=custom-project-name\n")

        propagate("Acme Bakery", in: dir)

        let config = try String(contentsOf: dir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "SITE_NAME", in: config) == "Untitled")
        #expect(SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config) == "custom-project-name")
    }

    @Test("No-ops gracefully when .site-config is missing")
    func noOpWhenSiteConfigMissing() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        createdDirs.append(dir)

        // Must not throw or crash.
        propagate("Acme Bakery", in: dir)
    }

    @Test("Still updates .site-config when wrangler.toml is missing")
    func updatesSiteConfigWhenWranglerMissing() throws {
        let dir = makeSiteDirectory(siteConfig: "SITE_NAME=Untitled\nCF_PROJECT_NAME=untitled\n", wranglerToml: nil)

        propagate("Acme Bakery", in: dir)

        let config = try String(contentsOf: dir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "SITE_NAME", in: config) == "Acme Bakery")
        #expect(SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config) == "acme-bakery")
    }

    @Test("Sanitizes an embedded newline in the new display name to its first line, without injecting extra .site-config keys")
    func sanitizesEmbeddedNewline() throws {
        let dir = makeSiteDirectory(siteConfig: "SITE_NAME=Untitled\nCF_PROJECT_NAME=untitled\n")

        propagate("Acme Bakery\nEVIL_KEY=1", in: dir)

        let config = try String(contentsOf: dir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "SITE_NAME", in: config) == "Acme Bakery")
        #expect(SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config) == "acme-bakery")
        #expect(SiteConfigFile.value(forKey: "EVIL_KEY", in: config) == nil, "an embedded newline must not inject a new .site-config key")
    }

    @Test("No-ops when the sanitized display name is blank")
    func noOpWhenSanitizedNameIsBlank() throws {
        let dir = makeSiteDirectory(siteConfig: "SITE_NAME=Untitled\nCF_PROJECT_NAME=untitled\n")

        propagate("\n  \n", in: dir)

        let config = try String(contentsOf: dir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(SiteConfigFile.value(forKey: "SITE_NAME", in: config) == "Untitled")
        #expect(SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config) == "untitled")
    }
}

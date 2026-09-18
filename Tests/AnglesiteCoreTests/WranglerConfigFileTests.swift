import Testing
import Foundation
import AnglesiteSiteModel
@testable import AnglesiteCore

@Suite("WranglerConfigFile")
struct WranglerConfigFileTests {
    private func tempConfigDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WranglerConfigFileTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Config", isDirectory: true)
    }

    @Test("url resolves to Config/wrangler.toml, matching the package layout's filename")
    func urlMatchesPackageLayout() {
        let config = tempConfigDir()
        #expect(WranglerConfigFile.url(configDirectory: config) == config.appendingPathComponent("wrangler.toml"))
        #expect(WranglerConfigFile.filename == AnglesitePackage.wranglerConfigFilename)
        let pkg = AnglesitePackage(url: config.deletingLastPathComponent().appendingPathComponent("Site.anglesite"))
        #expect(pkg.wranglerConfigURL == WranglerConfigFile.url(configDirectory: pkg.configURL))
    }

    @Test("write creates Config/ on first use and read round-trips the contents")
    func writeCreatesDirectoryAndReadRoundTrips() throws {
        let config = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        #expect(WranglerConfigFile.read(configDirectory: config) == nil)
        try WranglerConfigFile.write("name = \"site\"\n", configDirectory: config)
        #expect(WranglerConfigFile.read(configDirectory: config) == "name = \"site\"\n")
    }

    @Test("rewritingName replaces only the top-level name line")
    func rewritingNameReplacesOnlyNameLine() {
        let toml = "name = \"old\"\ncompatibility_date = \"2026-07-15\"\n\n[assets]\ndirectory = \"dist\"\n"
        let renamed = WranglerConfigFile.rewritingName("new", in: toml)
        #expect(renamed == "name = \"new\"\ncompatibility_date = \"2026-07-15\"\n\n[assets]\ndirectory = \"dist\"\n")
        #expect(WranglerConfigFile.rewritingName("new", in: "compatibility_date = \"2026-07-15\"\n") == nil)
    }

    @Test("addingGitignoreEntry is additive and idempotent, and recognises a rooted entry")
    func gitignoreEntryIsAdditiveAndIdempotent() {
        let original = "node_modules/\ndist/\n"
        let once = WranglerConfigFile.addingGitignoreEntry(to: original)
        #expect(once.hasPrefix(original))
        #expect(once.split(separator: "\n").contains("wrangler.toml"))
        #expect(WranglerConfigFile.addingGitignoreEntry(to: once) == once)
        #expect(WranglerConfigFile.addingGitignoreEntry(to: "/wrangler.toml\n") == "/wrangler.toml\n")
        #expect(WranglerConfigFile.addingGitignoreEntry(to: "").split(separator: "\n").last == "wrangler.toml")
    }
}

import Testing
import Foundation
@testable import AnglesiteCore

@Suite("DeployStateRelocation")
struct DeployStateRelocationTests {
    private func tmpDirs() -> (source: URL, config: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Source")
        let config = root.appendingPathComponent("Config")
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        return (source, config)
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("a migrated site has nothing to do")
    func migratedSiteIsANoOp() throws {
        let (source, config) = tmpDirs()
        try write("node_modules/\nwrangler.toml\n", to: source.appendingPathComponent(".gitignore"))
        try write("SITE_NAME=Acme\nCF_PROJECT_NAME=acme\n", to: source.appendingPathComponent(".site-config"))
        try WranglerConfigFile.write("name = \"acme\"\n", configDirectory: config)

        #expect(DeployStateRelocation.check(sourceDirectory: source, configDirectory: config).isEmpty)
        #expect(DeployStateRelocation.apply(sourceDirectory: source, configDirectory: config).isEmpty)
    }

    @Test("a Source/ with no .gitignore at all is not given one")
    func noGitignoreIsLeftAlone() {
        let (source, config) = tmpDirs()
        let plan = DeployStateRelocation.check(sourceDirectory: source, configDirectory: config)
        #expect(plan.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent(".gitignore").path))
    }

    @Test("moves Source/wrangler.toml into Config/ and reports it as a touched (removed) path")
    func movesWranglerConfig() throws {
        let (source, config) = tmpDirs()
        let toml = "name = \"acme\"\n\n[[d1_databases]]\nbinding = \"AUTH_DB\"\ndatabase_id = \"d1-id\"\n"
        try write(toml, to: source.appendingPathComponent("wrangler.toml"))

        let plan = DeployStateRelocation.check(sourceDirectory: source, configDirectory: config)
        #expect(plan.legacyWranglerConfigPresent)

        let touched = DeployStateRelocation.apply(sourceDirectory: source, configDirectory: config)
        #expect(touched == ["wrangler.toml"])
        #expect(WranglerConfigFile.read(configDirectory: config) == toml)
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("wrangler.toml").path))
        #expect(DeployStateRelocation.check(sourceDirectory: source, configDirectory: config).isEmpty)
    }

    @Test("when Config/ already holds a wrangler.toml, it wins and the Source/ copy is just removed")
    func configCopyWinsOverStaleSourceCopy() throws {
        let (source, config) = tmpDirs()
        try WranglerConfigFile.write("name = \"acme\"\ndatabase_id = \"current\"\n", configDirectory: config)
        try write("name = \"acme\"\ndatabase_id = \"stale-from-a-clone\"\n", to: source.appendingPathComponent("wrangler.toml"))

        let touched = DeployStateRelocation.apply(sourceDirectory: source, configDirectory: config)
        #expect(touched == ["wrangler.toml"])
        #expect(WranglerConfigFile.read(configDirectory: config)?.contains("current") == true)
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("wrangler.toml").path))
    }

    @Test("moves the CF_WORKER_DEPLOYED/CF_WORKER_PROVISIONED/CF_SOURCE_BUCKET markers into SiteSettings and strips them from .site-config")
    func movesDeployMarkers() throws {
        let (source, config) = tmpDirs()
        try write(
            "SITE_NAME=Acme\nCF_PROJECT_NAME=acme\nCF_WORKER_DEPLOYED=true\nSITE_URL=https://acme.example\nCF_WORKER_PROVISIONED=true\nCF_SOURCE_BUCKET=acme-source\nATPROTO_DID=did:plc:abc\n",
            to: source.appendingPathComponent(".site-config"))
        try SiteConfigStore.write(SiteSettings(displayName: "Acme"), to: config)

        let plan = DeployStateRelocation.check(sourceDirectory: source, configDirectory: config)
        #expect(plan.legacyMarkerKeys == ["CF_WORKER_DEPLOYED", "CF_WORKER_PROVISIONED", "CF_SOURCE_BUCKET"])

        let touched = DeployStateRelocation.apply(sourceDirectory: source, configDirectory: config)
        #expect(touched == [".site-config"])

        let settings = try SiteConfigStore.read(from: config)
        #expect(settings.workerDeployed == true)
        #expect(settings.workerProvisioned == true)
        #expect(settings.sourceBundleBucket == "acme-source")
        #expect(settings.displayName == "Acme", "existing settings survive the marker merge")

        let remaining = try String(contentsOf: source.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(remaining == "SITE_NAME=Acme\nCF_PROJECT_NAME=acme\nSITE_URL=https://acme.example\nATPROTO_DID=did:plc:abc\n",
                "template-owned keys — including the build-time ATPROTO_DID — stay in .site-config, in their original order")
        #expect(DeployStateRelocation.check(sourceDirectory: source, configDirectory: config).isEmpty)
    }

    @Test("a partial marker set only sets the markers that were present")
    func partialMarkersOnlySetWhatWasThere() throws {
        let (source, config) = tmpDirs()
        try write("CF_WORKER_PROVISIONED=true\n", to: source.appendingPathComponent(".site-config"))

        _ = DeployStateRelocation.apply(sourceDirectory: source, configDirectory: config)

        let settings = try SiteConfigStore.read(from: config)
        #expect(settings.workerProvisioned == true)
        #expect(settings.workerDeployed == nil)
        #expect(settings.sourceBundleBucket == nil)
    }

    @Test("adds wrangler.toml to an existing .gitignore, additively")
    func addsGitignoreEntry() throws {
        let (source, config) = tmpDirs()
        try write("node_modules/\ndist/\n", to: source.appendingPathComponent(".gitignore"))

        #expect(DeployStateRelocation.check(sourceDirectory: source, configDirectory: config).gitignoreEntryMissing)
        let touched = DeployStateRelocation.apply(sourceDirectory: source, configDirectory: config)
        #expect(touched == [".gitignore"])

        let gitignore = try String(contentsOf: source.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(gitignore.hasPrefix("node_modules/\ndist/\n"))
        #expect(gitignore.split(separator: "\n").contains("wrangler.toml"))
        #expect(!DeployStateRelocation.check(sourceDirectory: source, configDirectory: config).gitignoreEntryMissing)
    }

    @Test("a full legacy site migrates all three in one pass and is a no-op afterwards")
    func fullLegacySiteMigratesInOnePass() throws {
        let (source, config) = tmpDirs()
        try write("name = \"acme\"\n", to: source.appendingPathComponent("wrangler.toml"))
        try write("CF_PROJECT_NAME=acme\nCF_WORKER_DEPLOYED=true\n", to: source.appendingPathComponent(".site-config"))
        try write("node_modules/\n", to: source.appendingPathComponent(".gitignore"))

        let touched = DeployStateRelocation.apply(sourceDirectory: source, configDirectory: config)
        #expect(Set(touched) == ["wrangler.toml", ".site-config", ".gitignore"])
        #expect(DeployStateRelocation.check(sourceDirectory: source, configDirectory: config).isEmpty)
        #expect(DeployStateRelocation.apply(sourceDirectory: source, configDirectory: config).isEmpty)
    }
}

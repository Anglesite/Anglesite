import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct DependencySyncCheckerTests {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func writeFile(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeSite(siteConfig: String?, packageJSON: String, baseline: [String: String]?) throws -> (source: URL, config: URL) {
        let root = tmpDir()
        let source = root.appendingPathComponent("Source")
        let config = root.appendingPathComponent("Config")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try writeFile(packageJSON, to: source.appendingPathComponent("package.json"))
        if let siteConfig {
            try writeFile(siteConfig, to: source.appendingPathComponent(".site-config"))
        }
        if let baseline {
            try DependencyBaseline.save(baseline, to: config)
        }
        return (source, config)
    }

    private func makeTemplate(packageJSON: String) throws -> URL {
        let dir = tmpDir()
        try writeFile(packageJSON, to: dir.appendingPathComponent("package.json"))
        return dir
    }

    private static let stalePackageJSON = """
    { "dependencies": { "astro": "^5.0.0" } }
    """
    private static let currentTemplatePackageJSON = """
    { "dependencies": { "astro": "^6.4.8" } }
    """

    @Test func fastPathSkipsEverythingWhenStampedVersionMatchesRunningVersion() throws {
        let (source, config) = try makeSite(
            siteConfig: "ANGLESITE_VERSION=1.4.0\n",
            packageJSON: Self.stalePackageJSON,  // deliberately stale, to prove the fast path never looks
            baseline: nil
        )
        let template = try makeTemplate(packageJSON: Self.currentTemplatePackageJSON)
        let offers = DependencySyncChecker.check(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runningAppVersion: "1.4.0"
        )
        #expect(offers.isEmpty)
    }

    @Test func fallsThroughToTheRealDiffWhenStampedVersionDiffers() throws {
        let (source, config) = try makeSite(
            siteConfig: "ANGLESITE_VERSION=1.2.0\n",
            packageJSON: Self.stalePackageJSON,
            baseline: ["astro": "^5.0.0"]
        )
        let template = try makeTemplate(packageJSON: Self.currentTemplatePackageJSON)
        let offers = DependencySyncChecker.check(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runningAppVersion: "1.4.0"
        )
        #expect(offers.updates == [DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8")])
    }

    @Test func fallsThroughWhenThereIsNoSiteConfigAtAll() throws {
        let (source, config) = try makeSite(siteConfig: nil, packageJSON: Self.stalePackageJSON, baseline: nil)
        let template = try makeTemplate(packageJSON: Self.currentTemplatePackageJSON)
        let offers = DependencySyncChecker.check(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runningAppVersion: "1.4.0"
        )
        #expect(offers.updates == [DependencyUpdateOffer(name: "astro", currentRange: "^5.0.0", offeredRange: "^6.4.8")])
    }

    @Test func returnsEmptyRatherThanThrowingWhenPackageJSONIsMissing() throws {
        let root = tmpDir()
        let source = root.appendingPathComponent("Source")
        let config = root.appendingPathComponent("Config")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let template = try makeTemplate(packageJSON: Self.currentTemplatePackageJSON)
        let offers = DependencySyncChecker.check(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runningAppVersion: "1.4.0"
        )
        #expect(offers.isEmpty)
    }

    @Test func surfacesANewTemplateDevDependencyAsAnAdditionOffer() throws {
        let (source, config) = try makeSite(
            siteConfig: "ANGLESITE_VERSION=1.2.0\n",
            packageJSON: """
            { "dependencies": { "astro": "^6.4.8" }, "devDependencies": {} }
            """,
            baseline: ["astro": "^6.4.8"]
        )
        let template = try makeTemplate(packageJSON: """
        { "dependencies": { "astro": "^6.4.8" }, "devDependencies": { "html-validate": "^11.6.0" } }
        """)
        let offers = DependencySyncChecker.check(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runningAppVersion: "1.4.0"
        )
        #expect(offers.additions == [DependencyAdditionOffer(name: "html-validate", offeredRange: "^11.6.0", section: .devDependencies)])
    }

    // MARK: - #1440: foreign peerDependencies hold a bump out of the auto-offer

    /// The #1426/#1440 repro, end to end: an imported site carries its own (untracked)
    /// `@astrojs/cloudflare@13.5.0`, whose `peerDependencies` require `astro ^6.3.0`. The
    /// template legitimately bumps `astro` to `^7.1.3` — but applying that would leave the
    /// site unable to `npm install` at all, so the bump must be held for the owner, not
    /// silently auto-offered as a safe update.
    @Test func holdsABumpThatViolatesAForeignDependencysPeerRange() throws {
        let (source, config) = try makeSite(
            siteConfig: "ANGLESITE_VERSION=1.2.0\n",
            packageJSON: """
            { "dependencies": { "astro": "^6.2.0", "@astrojs/cloudflare": "13.5.0" } }
            """,
            baseline: ["astro": "^6.2.0"]
        )
        try """
        {
          "lockfileVersion": 3,
          "packages": {
            "node_modules/@astrojs/cloudflare": {
              "version": "13.5.0",
              "peerDependencies": { "astro": "^6.3.0" }
            }
          }
        }
        """.write(to: source.appendingPathComponent("package-lock.json"), atomically: true, encoding: .utf8)
        let template = try makeTemplate(packageJSON: """
        { "dependencies": { "astro": "^7.1.3" } }
        """)
        let offers = DependencySyncChecker.check(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runningAppVersion: "1.4.0"
        )
        #expect(offers.updates.isEmpty)
        #expect(offers.heldUpdates == [
            DependencyHeldUpdate(
                offer: DependencyUpdateOffer(name: "astro", currentRange: "^6.2.0", offeredRange: "^7.1.3"),
                blockers: [DependencyPeerBlocker(dependentName: "@astrojs/cloudflare", requiredRange: "^6.3.0")]
            )
        ])
        #expect(!offers.isEmpty)  // held bumps still surface the sheet, so the owner learns why
    }

    @Test func stillOffersABumpAForeignPeerRangeAllows() throws {
        let (source, config) = try makeSite(
            siteConfig: "ANGLESITE_VERSION=1.2.0\n",
            packageJSON: """
            { "dependencies": { "astro": "^6.2.0", "@astrojs/cloudflare": "14.2.1" } }
            """,
            baseline: ["astro": "^6.2.0"]
        )
        try """
        {
          "lockfileVersion": 3,
          "packages": {
            "node_modules/@astrojs/cloudflare": {
              "version": "14.2.1",
              "peerDependencies": { "astro": "^7.2.0 || ^6.4.0" }
            }
          }
        }
        """.write(to: source.appendingPathComponent("package-lock.json"), atomically: true, encoding: .utf8)
        let template = try makeTemplate(packageJSON: """
        { "dependencies": { "astro": "^6.4.8" } }
        """)
        let offers = DependencySyncChecker.check(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runningAppVersion: "1.4.0"
        )
        #expect(offers.updates == [DependencyUpdateOffer(name: "astro", currentRange: "^6.2.0", offeredRange: "^6.4.8")])
        #expect(offers.heldUpdates.isEmpty)
    }

    /// A dependency the template *does* track is never treated as a foreign blocker —
    /// tracked packages are the template's own responsibility to keep mutually compatible.
    @Test func doesNotTreatTemplateTrackedDependenciesAsForeignBlockers() throws {
        let (source, config) = try makeSite(
            siteConfig: "ANGLESITE_VERSION=1.2.0\n",
            packageJSON: """
            { "dependencies": { "astro": "^6.2.0", "astro-seo-schema": "^5.0.0" } }
            """,
            baseline: ["astro": "^6.2.0", "astro-seo-schema": "^5.0.0"]
        )
        try """
        {
          "lockfileVersion": 3,
          "packages": {
            "node_modules/astro-seo-schema": {
              "peerDependencies": { "astro": "^6.0.0" }
            }
          }
        }
        """.write(to: source.appendingPathComponent("package-lock.json"), atomically: true, encoding: .utf8)
        // The template tracks astro-seo-schema (and would bump it alongside astro).
        let template = try makeTemplate(packageJSON: """
        { "dependencies": { "astro": "^7.1.3", "astro-seo-schema": "^6.0.0" } }
        """)
        let offers = DependencySyncChecker.check(
            sourceDirectory: source, configDirectory: config, templateDirectory: template,
            runningAppVersion: "1.4.0"
        )
        #expect(offers.updates.count == 2)
        #expect(offers.heldUpdates.isEmpty)
    }
}

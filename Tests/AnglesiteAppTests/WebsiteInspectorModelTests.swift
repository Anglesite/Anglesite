import Foundation
import Testing
@testable import AnglesiteAppCore
@testable import AnglesiteCore

/// Tests `WebsiteInspectorModel` (#714 v2 slice 1) — the data model behind the Website
/// inspector panel's site-identity basics (title, language, domain, stylesheets).
@Suite("WebsiteInspectorModel (#714)")
@MainActor
struct WebsiteInspectorModelTests {
    /// Builds a fixture `.anglesite` package: an `Info.plist` marker written via
    /// `PlistDocumentIO.save` with the exact key set `AnglesitePackage.isPackage` needs to
    /// recognize it (so `SiteFileTree.layout(for:)` resolves the `Source/`/`Config/` split
    /// rather than treating it as a plain pre-package directory), a `Source/.site-config` with
    /// the real keys `SiteLanguageAsset.parseSettings`/`WebsiteAnalyticsAsset.bestHost` read
    /// (`LANG`, `DOMAIN` — confirmed in `Sources/AnglesiteCore/SiteLanguageAsset.swift` and
    /// `WebsiteAnalyticsAsset.swift:152`), and a stylesheet under `Source/src/styles`.
    private func makeFixturePackage(title: String, domain: String?, lang: String) throws -> URL {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebsiteInspectorModelTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Fixture.anglesite", isDirectory: true)
        let sourceDir = packageURL.appendingPathComponent("Source", isDirectory: true)
        let configDir = packageURL.appendingPathComponent("Config", isDirectory: true)
        let stylesDir = sourceDir.appendingPathComponent("src/styles", isDirectory: true)
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        let infoPlistURL = packageURL.appendingPathComponent("Info.plist")
        try PlistDocumentIO.save([
            .init(key: "AnglesiteFormatVersion", value: .integer(1)),
            .init(key: "AnglesiteSiteID", value: .string(UUID().uuidString)),
            .init(key: "AnglesiteDisplayName", value: .string(title)),
            .init(key: "AnglesiteCreatedDate", value: .date(Date())),
        ], to: infoPlistURL)

        var config = "LANG=\(lang)\n"
        if let domain { config += "DOMAIN=\(domain)\n" }
        try config.write(
            to: sourceDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)

        try "body { margin: 0; }".write(
            to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)

        return packageURL
    }

    @Test func loadPopulatesIdentityAndStyles() async throws {
        let pkg = try makeFixturePackage(title: "My Site", domain: "example.com", lang: "en")
        let model = WebsiteInspectorModel(packageURL: pkg)
        await model.load()
        #expect(model.loadError == nil)
        #expect(model.title == "My Site")
        #expect(model.lang == "en")
        #expect(model.domain == "example.com")
        #expect(model.stylesheets.map(\.name) == ["global.css"])
        #expect(!model.isDirty)
    }

    @Test func saveTitleRoundTrips() async throws {
        let pkg = try makeFixturePackage(title: "My Site", domain: nil, lang: "en")
        let model = WebsiteInspectorModel(packageURL: pkg)
        await model.load()
        model.title = "Renamed"
        #expect(model.isDirty)
        #expect(await model.saveTitle())
        #expect(!model.isDirty)

        let reread = WebsiteInspectorModel(packageURL: pkg)
        await reread.load()
        #expect(reread.title == "Renamed")
    }

    @Test func saveLangRoundTrips() async throws {
        let pkg = try makeFixturePackage(title: "My Site", domain: nil, lang: "en")
        let model = WebsiteInspectorModel(packageURL: pkg)
        await model.load()
        model.lang = "fr-CA"
        #expect(model.isDirty)
        #expect(await model.saveLang())
        #expect(!model.isDirty)

        let reread = WebsiteInspectorModel(packageURL: pkg)
        await reread.load()
        #expect(reread.lang == "fr-CA")
    }

    @Test func missingDomainReadsNil() async throws {
        let pkg = try makeFixturePackage(title: "My Site", domain: nil, lang: "en")
        let model = WebsiteInspectorModel(packageURL: pkg)
        await model.load()
        #expect(model.domain == nil)
    }

    /// A double-fire of `saveTitle()` (e.g. a field commit racing a window close) must not
    /// launch two concurrent read-modify-writes on `Info.plist`. Both calls are started before
    /// either is awaited; the actor serializes their synchronous prefixes, so the second sees
    /// `isSavingTitle` already `true` and returns `false` without touching disk — proven here by
    /// exactly one of the two results being `true`, with no artificial delay or polling needed.
    @Test func saveTitleGuardsReentrancy() async throws {
        let pkg = try makeFixturePackage(title: "My Site", domain: nil, lang: "en")
        let model = WebsiteInspectorModel(packageURL: pkg)
        await model.load()
        model.title = "Renamed"
        async let first = model.saveTitle()
        async let second = model.saveTitle()
        let results = await [first, second]
        #expect(results.filter { $0 }.count == 1)
        #expect(!model.isDirty)
        #expect(model.title == "Renamed")
    }

    /// Same reentrancy guard, for `saveLang()`'s `.site-config` write.
    @Test func saveLangGuardsReentrancy() async throws {
        let pkg = try makeFixturePackage(title: "My Site", domain: nil, lang: "en")
        let model = WebsiteInspectorModel(packageURL: pkg)
        await model.load()
        model.lang = "fr-CA"
        async let first = model.saveLang()
        async let second = model.saveLang()
        let results = await [first, second]
        #expect(results.filter { $0 }.count == 1)
        #expect(!model.isDirty)
        #expect(model.lang == "fr-CA")
    }
}

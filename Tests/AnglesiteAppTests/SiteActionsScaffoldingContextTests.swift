import Testing
import Foundation
import AnglesiteCore
import AnglesiteTestSupport
@testable import AnglesiteAppCore

@Suite("SiteActions scaffolding context")
@MainActor
struct SiteActionsScaffoldingContextTests {
    /// Deterministic stand-in for `FileManager`'s ubiquity-container lookup — mirrors
    /// `AppSettingsTests.FakeUbiquityContainerResolver` — so this test doesn't depend on the
    /// real iCloud account state of the machine running `swift test` (which never carries the
    /// app's iCloud entitlement anyway, and must never be the thing making the test pass or
    /// fail). Reporting an iCloud container also keeps `resolveScaffoldingContext()` off the
    /// `#if ANGLESITE_MAS` sites-root access-grant path, which would otherwise pop a real
    /// `NSOpenPanel` under `swift test`.
    private struct FakeUbiquityContainerResolver: UbiquityContainerResolving {
        let result: URL?
        func url(forUbiquityContainerIdentifier containerIdentifier: String?) -> URL? { result }
    }

    /// An isolated `AppSettings` backed by its own `UserDefaults` suite and a fake ubiquity
    /// resolver — mirrors `SiteWindowModelTests.makeIsolatedSettings()`. Never mutate
    /// `AppSettings.shared` directly, since that's a real singleton other tests/suites could
    /// observe, and `Bundle.main` is never the app bundle under `swift test` (it's the Swift
    /// toolchain's own `swiftpm-testing-helper`), so the default `AppSettings.shared`/`Bundle.main`
    /// pair can never resolve the real template in this environment.
    private func makeIsolatedSettings(sitesRoot: URL) throws -> (AppSettings, cleanup: () -> Void) {
        let scratch = TemporaryUserDefaults()
        let settings = AppSettings(
            defaults: scratch.defaults,
            ubiquityContainerResolver: FakeUbiquityContainerResolver(result: sitesRoot)
        )
        return (settings, scratch.cleanup)
    }

    /// A minimal on-disk template — `scripts/themes.ts` (what `TemplateRuntime.isTemplateDirectory`
    /// checks for) plus `scripts/themes.json` (what `ThemeCatalog.load` actually reads) — mirrors
    /// `SiteWindowModelTests.makeFixtureThemeTemplate()`.
    private func makeFixtureThemeTemplate() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scaffolding-context-\(UUID().uuidString)")
        let scriptsDir = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try Data("export const THEMES".utf8).write(to: scriptsDir.appendingPathComponent("themes.ts"))
        let themesJSON = """
        [
          {
            "id": "classic",
            "displayName": "Classic",
            "description": "Traditional, trustworthy, professional",
            "bestFor": ["legal"],
            "vars": { "color-primary": "#1e3a5f", "color-accent": "#c8a951" }
          }
        ]
        """
        try Data(themesJSON.utf8).write(to: scriptsDir.appendingPathComponent("themes.json"))
        return root
    }

    @Test("resolveScaffoldingContext loads the bundled theme catalog")
    func loadsCatalog() async throws {
        let template = try makeFixtureThemeTemplate()
        defer { try? FileManager.default.removeItem(at: template) }
        let sitesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("scaffolding-context-sites-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sitesRoot) }
        let (settings, cleanup) = try makeIsolatedSettings(sitesRoot: sitesRoot)
        defer { cleanup() }
        settings.templatePathOverride = template

        let context = await SiteActions.resolveScaffoldingContext(settings: settings)

        let unwrapped = try #require(context, "Template/catalog should resolve from the fixture override")
        #expect(!unwrapped.catalog.themes.isEmpty)
    }

    @Test("resolveScaffoldingContext reports the template-missing message via onFailure")
    func templateMissingCallsOnFailure() async throws {
        // A directory that exists but isn't a template (no scripts/themes.ts) — combined with
        // `swift test`'s `Bundle.main` never having a bundled Template either (it's the Swift
        // toolchain's own `swiftpm-testing-helper`, not the app bundle — see `loadsCatalog()`'s
        // doc comment above), `TemplateRuntime.resolve()` falls all the way through to `.missing`.
        let bareDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scaffolding-context-bare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bareDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bareDir) }
        let sitesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("scaffolding-context-sites-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sitesRoot) }
        let (settings, cleanup) = try makeIsolatedSettings(sitesRoot: sitesRoot)
        defer { cleanup() }
        settings.templatePathOverride = bareDir

        var reportedMessage: String?
        let context = await SiteActions.resolveScaffoldingContext(settings: settings, onFailure: { reportedMessage = $0 })

        #expect(context == nil)
        #expect(reportedMessage == "Template not found — can't create a site. Reinstall the app.")
    }

    @Test("resolveScaffoldingContext reports the catalog-load-failure message via onFailure")
    func catalogLoadFailureCallsOnFailure() async throws {
        // A directory that passes `TemplateRuntime.isTemplateDirectory` (has `scripts/themes.ts`)
        // but whose `scripts/themes.json` is malformed — `ThemeCatalog.load` throws, same as
        // `ThemeCatalogTests.malformedJSONThrows()` exercises directly against `parse(themesJSON:)`.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scaffolding-context-malformed-\(UUID().uuidString)")
        let scriptsDir = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try Data("export const THEMES".utf8).write(to: scriptsDir.appendingPathComponent("themes.ts"))
        try Data("not json".utf8).write(to: scriptsDir.appendingPathComponent("themes.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        let sitesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("scaffolding-context-sites-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sitesRoot) }
        let (settings, cleanup) = try makeIsolatedSettings(sitesRoot: sitesRoot)
        defer { cleanup() }
        settings.templatePathOverride = root

        var reportedMessage: String?
        let context = await SiteActions.resolveScaffoldingContext(settings: settings, onFailure: { reportedMessage = $0 })

        #expect(context == nil)
        #expect(reportedMessage?.hasPrefix("Couldn't load themes: ") == true)
    }
}

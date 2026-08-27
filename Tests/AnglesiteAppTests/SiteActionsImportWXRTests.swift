import Testing
import Foundation
import AnglesiteCore
import AnglesiteSiteModel
@testable import AnglesiteAppCore

@Suite("SiteActions importWXR")
@MainActor
struct SiteActionsImportWXRTests {
    private final class StubConverter: ImportHTMLConverter, @unchecked Sendable {
        var responses: [String: (markdown: String, images: [String])] = [:]
        func convert(html: String) async -> (markdown: String, images: [String]) {
            responses[html] ?? ("", [])
        }
    }

    private static let sampleWXR = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <rss version="2.0"
      xmlns:content="http://purl.org/rss/1.0/modules/content/"
      xmlns:excerpt="http://wordpress.org/export/1.1/excerpt/"
      xmlns:wp="http://wordpress.org/export/1.2/">
    <channel>
      <title>My Old Blog</title>
      <link>https://old-blog.example</link>
      <item>
        <title>Hello</title>
        <link>https://old-blog.example/hello/</link>
        <content:encoded><![CDATA[<p>Hi there.</p>]]></content:encoded>
        <excerpt:encoded><![CDATA[]]></excerpt:encoded>
        <wp:post_date_gmt>2024-05-01 10:00:00</wp:post_date_gmt>
        <pubDate>Wed, 01 May 2024 10:00:00 +0000</pubDate>
        <wp:status>publish</wp:status>
        <wp:post_type>post</wp:post_type>
      </item>
    </channel>
    </rss>
    """

    private func tempSitesRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wxr-import-sites-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The real in-repo template (`Resources/Template/`), resolved repo-root-relative from this
    /// file's own path — mirrors `SiteScaffolderTests.realScaffoldScriptURL()`.
    ///
    /// Deviates from the brief's literal `TemplateRuntime.resolve().url`: that call defaults to
    /// `AppSettings.shared`/`Bundle.main`, and under `swift test` `Bundle.main` is the SwiftPM
    /// test host, not the app bundle — it always resolves to `.missing` here (confirmed live: the
    /// brief's test as written failed with `TemplateRuntime.resolve() → Resolution(source: .missing)`
    /// even after `importWXR` was implemented). Every other test in this suite that needs a real
    /// resolvable template (`SiteActionsScaffoldingContextTests`, `SiteWindowModelTests`,
    /// `TemplateRuntimeTests`) already avoids this by injecting an isolated `AppSettings` with
    /// `templatePathOverride` set — but this test's `SiteScaffolder` uses the real
    /// `ProcessSupervisor`-backed `CommandRunner` (per the brief) to run the actual
    /// `scripts/scaffold.sh`, so it needs a real, complete template directory rather than a
    /// minimal themes-only fixture. `SiteScaffolderTests.realScaffoldScriptURL()` resolves the
    /// same real template the same way for the same reason.
    private static func realTemplateURL() -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Resources/Template", isDirectory: true)
    }

    /// A minimal, real `SiteScaffolder` against a temp sites root — exercises the actual
    /// scaffolding pipeline (this repo has no lighter test double for it; every other
    /// `SiteActions`/`NewSiteWizardModel` test does the same).
    ///
    /// `register` records into `store` — an isolated `SiteStore`, not `SiteStore.shared` — via the
    /// same `record(_:)` production uses (``SiteActions/resolveScaffoldingContext(settings:bundle:onFailure:)``
    /// registers through `SiteStore.shared` the identical way). `importWXR`'s post-scaffold
    /// look-up needs a real, queryable store to find the newly scaffolded site by ID; routing that
    /// through `SiteStore.shared` here would write a real (if temporary) entry into this machine's
    /// actual `~/Library/Application Support/Anglesite/recents.json` — no test in this repo does
    /// that (see `SiteStoreTests`/`SiteActionsRegisterHealTests`/etc., which all construct their
    /// own `SiteStore(persistenceURL:)` instead) — so this does the same, and `importWXR`'s
    /// `siteStore:` injection seam (mirroring `registerPackage(_:siteStore:)`'s existing one) lets
    /// the test point at it instead of the default `.shared`.
    private func makeScaffolder(sitesRoot: URL, store: SiteStore, registered: @escaping @Sendable (AnglesitePackage) -> Void)
        throws -> SiteScaffolder {
        let templateURL = Self.realTemplateURL()
        try #require(FileManager.default.fileExists(atPath: templateURL.appendingPathComponent("scripts/scaffold.sh").path),
                    "Real template not found at \(templateURL.path) — expected Resources/Template/ in this checkout")
        let catalog = try ThemeCatalog.load(templateURL: templateURL)
        return SiteScaffolder(
            sitesRoot: sitesRoot, templateURL: templateURL, catalog: catalog,
            run: { exe, args, cwd in try await ProcessSupervisor.shared.run(executable: exe, arguments: args, currentDirectoryURL: cwd) },
            gitInit: { sourceDir in try GitInitRunner.run(in: sourceDir) },
            gitCommit: { _ in },
            register: { package in
                registered(package)
                return try await store.record(package)
            })
    }

    @Test func importsAWXRFileIntoAFreshlyScaffoldedSite() async throws {
        let root = try tempSitesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SiteStore(persistenceURL: root.appendingPathComponent("recents.json"))
        var registeredPackage: AnglesitePackage?
        let scaffolder = try makeScaffolder(sitesRoot: root, store: store) { registeredPackage = $0 }
        let catalog = try ThemeCatalog.load(templateURL: Self.realTemplateURL())
        let context = SiteActions.ScaffoldingContext(
            catalog: catalog, scaffolder: scaffolder, templateURL: Self.realTemplateURL(),
            isNameTaken: { _ in false }, sitesRootAccess: nil)

        let converter = StubConverter()
        converter.responses["<p>Hi there.</p>"] = ("Hi there.", [])

        var committed: URL?
        let (site, report) = try await SiteActions.importWXR(
            data: Data(Self.sampleWXR.utf8), fileName: "export.xml", context: context, converter: converter,
            commitGit: { sourceDirectory in committed = sourceDirectory },
            now: Date(timeIntervalSince1970: 1_700_000_000), siteStore: store)

        #expect(site.name == "My Old Blog")
        #expect(registeredPackage != nil)
        #expect(committed == site.sourceDirectory)
        let written = try String(
            contentsOf: site.sourceDirectory.appendingPathComponent("src/content/blog/hello.md"), encoding: .utf8)
        #expect(written.contains("Hi there."))

        // The returned ImportReport is what a caller (the panel-driving importWXR() wrapper)
        // builds the owner-facing import summary from — assert it's actually populated rather
        // than a discarded/empty value, so that summary path can't silently regress (#1636 final
        // review, Important #2).
        #expect(report.plan.counts["blog"] == 1)
        let summary = ImportSummaryModel(plan: report.plan)
        #expect(summary.countLines == ["1 blog post"])
    }

    @Test func numbersTheChannelTitleWhenAlreadyTaken() async throws {
        let root = try tempSitesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SiteStore(persistenceURL: root.appendingPathComponent("recents.json"))
        let scaffolder = try makeScaffolder(sitesRoot: root, store: store) { _ in }
        let catalog = try ThemeCatalog.load(templateURL: Self.realTemplateURL())
        let context = SiteActions.ScaffoldingContext(
            catalog: catalog, scaffolder: scaffolder, templateURL: Self.realTemplateURL(),
            isNameTaken: { $0 == "My Old Blog" }, sitesRootAccess: nil)

        let converter = StubConverter()
        converter.responses["<p>Hi there.</p>"] = ("Hi there.", [])

        let (site, _) = try await SiteActions.importWXR(
            data: Data(Self.sampleWXR.utf8), fileName: "old-blog-export.xml", context: context, converter: converter,
            commitGit: { _ in }, now: Date(timeIntervalSince1970: 1_700_000_000), siteStore: store)
        #expect(site.name == "My Old Blog 2")
    }

    /// Captures the package URL `commitGit` observed before throwing — a small actor, mirroring
    /// `SiteActionsImportTests.ImportRecorder`, so the `@Sendable` `commitGit` closure below can
    /// record it without a mutable-var-capture warning.
    private actor PackageURLRecorder {
        private(set) var packageURL: URL?
        func record(_ url: URL) { packageURL = url }
    }

    @Test func cleansUpTheScaffoldedPackageWhenCommitGitFails() async throws {
        struct Boom: Error {}

        let root = try tempSitesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SiteStore(persistenceURL: root.appendingPathComponent("recents.json"))
        let scaffolder = try makeScaffolder(sitesRoot: root, store: store) { _ in }
        let catalog = try ThemeCatalog.load(templateURL: Self.realTemplateURL())
        let context = SiteActions.ScaffoldingContext(
            catalog: catalog, scaffolder: scaffolder, templateURL: Self.realTemplateURL(),
            isNameTaken: { _ in false }, sitesRootAccess: nil)

        let converter = StubConverter()
        converter.responses["<p>Hi there.</p>"] = ("Hi there.", [])

        let recorder = PackageURLRecorder()
        await #expect(throws: SiteActions.WXRImportError.self) {
            _ = try await SiteActions.importWXR(
                data: Data(Self.sampleWXR.utf8), fileName: "export.xml", context: context, converter: converter,
                commitGit: { sourceDirectory in
                    // The package directory is two levels up from Source/ — record it before
                    // throwing, so the assertion below can confirm cleanup actually removed it.
                    await recorder.record(sourceDirectory.deletingLastPathComponent())
                    throw Boom()
                },
                now: Date(timeIntervalSince1970: 1_700_000_000), siteStore: store)
        }

        let cleanedUp = try #require(await recorder.packageURL)
        #expect(!FileManager.default.fileExists(atPath: cleanedUp.path))
        #expect(await store.sites.isEmpty)
    }
}

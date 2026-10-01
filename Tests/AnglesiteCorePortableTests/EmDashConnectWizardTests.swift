// Portable target: the New Site wizard's "connect an EmDash site I already have" path (#2106)
// is model and scaffolder logic over injected seams, and this target runs on the Linux CI leg.
import AnglesiteSiteModel
import Foundation
import Testing
@testable import AnglesiteCore

@MainActor
@Suite("New Site: connecting an existing EmDash install (#2106)")
struct EmDashConnectWizardTests {
    nonisolated private static func install(_ name: String, problem: EmDashInstall.Problem? = nil, codePlugins: [String] = []) -> EmDashInstall {
        EmDashInstall(
            workerName: name, databaseName: "\(name)-db", databaseID: "db-\(name)", mediaBucketName: "\(name)-media",
            sessionKVNamespaceID: nil, hasWorkerLoader: false, marketplacePlugins: ["seo"], codePlugins: codePlugins,
            problem: problem)
    }

    private static func search(
        token: String? = "tok", account: String? = "acct",
        installs: @escaping @Sendable () throws -> [EmDashInstall] = { [] }
    ) -> EmDashInstallSearch {
        EmDashInstallSearch(
            tokenSource: { token }, accountIDSource: { _ in account }, installsSource: { _, _ in try installs() })
    }

    @Test("without a Cloudflare sign-in the owner is asked to sign in")
    func needsSignIn() async {
        let search = Self.search(token: nil)
        await search.search()
        #expect(search.state == .needsSignIn)
    }

    @Test("the only connectable install is picked; a pick that's still there is kept")
    func picksSoleConnectable() async {
        let news = Self.install("news")
        let broken = Self.install("old", problem: .mediaBucketUnclear)
        let search = Self.search(installs: { [broken, news] })
        await search.search()
        #expect(search.state == .found([broken, news]))
        #expect(search.selectedWorkerName == "news")
        #expect(search.connectableSelection == news)

        let both = Self.search(installs: { [news, Self.install("zine")] })
        both.selectedWorkerName = "zine"
        await both.search()
        #expect(both.selectedWorkerName == "zine")

        // An install that can't be connected can be picked to read why, but never connected.
        both.selectedWorkerName = nil
        let onlyBroken = Self.search(installs: { [broken] })
        await onlyBroken.search()
        #expect(onlyBroken.selectedWorkerName == nil)
        onlyBroken.selectedWorkerName = "old"
        #expect(onlyBroken.selectedInstall == broken)
        #expect(onlyBroken.connectableSelection == nil)
    }

    @Test("each way the search can fail is reported as its own state")
    func failures() async {
        let noAccount = Self.search(account: nil)
        await noAccount.search()
        #expect(noAccount.state == .failed(.noAccount))

        let cases: [(any Error, EmDashInstallSearch.State)] = [
            (EmDashInstallFinder.FindError.cannotReadDatabases, .failed(.cannotReadDatabases)),
            (CloudflareError.unauthorized, .failed(.signInRefused)),
            (CloudflareError.http(status: 500), .failed(.unavailable)),
            (CancellationError(), .idle),
        ]
        for (error, expected) in cases {
            let search = Self.search(installs: { throw error })
            await search.search()
            #expect(search.state == expected, "\(error)")
        }

        let signIn = Self.search()
        signIn.signInFailed()
        #expect(signIn.state == .failed(.signInFailed))
    }

    @Test("the pre-connect notice names code plugins and marketplace plugins with nowhere to run")
    func pluginsThatStop() {
        let install = Self.install("news", codePlugins: ["audit-log"])
        #expect(install.pluginsThatStop == ["audit-log", "seo"])
    }

    @Test("Create waits for a connectable pick, only when connecting an EmDash site")
    func createGate() async {
        let catalog = ThemeCatalog(themes: [Theme(id: "classic", name: "Classic", blurb: "", swatch: [], cssVars: [:])])
        let news = Self.install("news")
        let model = NewSiteWizardModel(catalog: catalog, isNameTaken: { _ in false }, emdashSearch: Self.search(installs: { [news] }))
        #expect(model.canCreate)

        model.connectsExistingEmDash = true
        #expect(model.canCreate, "an Anglesite site ignores the EmDash choice")
        #expect(model.emdashInstallToConnect == nil)

        model.draft.siteKind = .emdash
        #expect(!model.canCreate)
        await model.emdashSearch.search()
        #expect(model.canCreate)
        #expect(model.emdashInstallToConnect == news)

        model.connectsExistingEmDash = false
        #expect(model.emdashInstallToConnect == nil)
    }

    @Test("scaffolding a connected EmDash draft records the install before the first commit")
    func scaffoldsConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("connect-wizard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let template = root.appendingPathComponent("Template", isDirectory: true)
        try FileManager.default.createDirectory(at: template.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: template.appendingPathComponent("emdash"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: template.appendingPathComponent("package.json"))
        try Data("// overlay config\n".utf8).write(to: template.appendingPathComponent("emdash/astro.config.ts"))

        // What `.site-config` said when the initial commit was made.
        final class Commits: @unchecked Sendable { var siteConfig: String? }
        let commits = Commits()
        let scaffolder = SiteScaffolder(
            sitesRoot: root,
            templateURL: template,
            catalog: ThemeCatalog(themes: []),
            run: { _, args, _ in
                let source = URL(fileURLWithPath: args.last ?? "")
                try Data("// template config\n".utf8).write(to: source.appendingPathComponent("astro.config.ts"))
                return .init(stdout: "", stderr: "", exitCode: 0)
            },
            gitInit: { _ in },
            gitCommit: { source in
                commits.siteConfig = try? String(contentsOf: source.appendingPathComponent(".site-config"), encoding: .utf8)
            },
            register: { try SiteStore.Site.make(package: $0) },
            attributionsLoader: { _ in [] },
            appVersion: { "1.0.0" },
            hostLanguage: { "en" }
        )

        let install = Self.install("news_room")
        var failure: String?
        for await step in scaffolder.scaffold(NewSiteDraft(siteType: .blog, name: "News", siteKind: .emdash, emdashInstall: install)) {
            if case .failed(_, let message) = step { failure = message }
        }
        #expect(failure == nil)

        let package = AnglesitePackage(url: root.appendingPathComponent("news.anglesite", isDirectory: true))
        #expect(commits.siteConfig?.contains("CF_PROJECT_NAME=news_room") == true)
        let settings = try await SiteConfigStore(configDirectory: package.configURL).load()
        #expect(settings.emdashResources == install.resources)
        #expect(settings.workerProvisioned == true)
    }
}

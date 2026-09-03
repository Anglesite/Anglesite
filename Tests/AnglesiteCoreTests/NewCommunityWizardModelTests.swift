import Testing
import Foundation
@testable import AnglesiteCore

@MainActor
struct NewCommunityWizardModelTests {
    @Test("starts on chooser with an empty name and cannot create")
    func startsOnChooserWithEmptyNameAndCannotCreate() {
        let m = NewCommunityWizardModel(isNameTaken: { _ in false })
        #expect(m.step == .chooser)
        #expect(m.communityName == "")
        #expect(!m.canCreate)
    }

    @Test("can create once the name is non-empty and not taken")
    func canCreateOnceNameIsNonEmptyAndNotTaken() {
        let m = NewCommunityWizardModel(isNameTaken: { _ in false })
        m.communityName = "Birding Club"
        #expect(m.canCreate)
    }

    @Test("cannot create when the name is taken")
    func cannotCreateWhenNameIsTaken() {
        let m = NewCommunityWizardModel(isNameTaken: { $0 == "Birding Club" })
        m.communityName = "Birding Club"
        #expect(!m.canCreate)
    }

    @Test("cannot create with a whitespace-only name")
    func cannotCreateWithWhitespaceOnlyName() {
        let m = NewCommunityWizardModel(isNameTaken: { _ in false })
        m.communityName = "   "
        #expect(!m.canCreate)
    }

    @Test("build drives the scaffolder with the community site type and a fixed theme")
    func buildDrivesScaffolderWithCommunitySiteTypeAndFixedTheme() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let m = NewCommunityWizardModel(isNameTaken: { _ in false })
        m.communityName = "Birding Club"

        var seenDraft: NewSiteDraft?
        let scaffolder = SiteScaffolder(
            sitesRoot: root,
            templateURL: URL(fileURLWithPath: "/template"),
            catalog: ThemeCatalog(themes: [Theme(id: "community", name: "Community", blurb: "", swatch: [], cssVars: [:])]),
            run: { _, args, cwd in
                if args.contains(where: { $0.hasSuffix("scaffold.sh") }), let cwd {
                    let css = cwd.appendingPathComponent("src/styles/global.css")
                    let astro = cwd.appendingPathComponent("src/pages/index.astro")
                    try? FileManager.default.createDirectory(at: css.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.createDirectory(at: astro.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? ":root { --color-primary: #2563eb; }".write(to: css, atomically: true, encoding: .utf8)
                    try? "<h1>Welcome</h1>".write(to: astro, atomically: true, encoding: .utf8)
                    try? "ANGLESITE_VERSION=1.0.0".write(to: cwd.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
                }
                return ProcessSupervisor.RunResult(stdout: "", stderr: "", exitCode: 0)
            },
            gitInit: { _ in },
            gitCommit: { _ in },
            register: { pkg in
                SiteStore.Site(id: pkg.url.path, name: pkg.url.lastPathComponent, packageURL: pkg.url, isValid: true, missingSentinels: [])
            },
            attributionsLoader: { _ in [] }
        )

        let id = await m.build(using: scaffolder)

        #expect(id != nil)
        #expect(m.completedSiteID != nil)
        #expect(m.draft.siteType == .community)
        #expect(m.draft.name == "Birding Club")
        #expect(m.draft.themeID == "community")
        #expect(m.draft.headline == "")   // skip homepage write, matches NewSiteWizardModel's convention
        seenDraft = m.draft
        #expect(seenDraft != nil)
    }

    /// #1263 final review finding 2: a freshly-scaffolded community must come out of the wizard
    /// with a live ActivityPub worker — no manual Workers-tab step — since the whole point of
    /// "New Community" is a working Group actor with no extra owner action.
    @Test("build activates the ActivityPub worker after scaffolding")
    func buildActivatesActivityPubWorkerAfterScaffold() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var registeredConfigDirectory: URL?
        let m = NewCommunityWizardModel(
            isNameTaken: { _ in false },
            resolveConfigDirectory: { _ in registeredConfigDirectory }
        )
        m.communityName = "Birding Club"

        let scaffolder = SiteScaffolder(
            sitesRoot: root,
            templateURL: URL(fileURLWithPath: "/template"),
            catalog: ThemeCatalog(themes: [Theme(id: "community", name: "Community", blurb: "", swatch: [], cssVars: [:])]),
            run: { _, args, cwd in
                if args.contains(where: { $0.hasSuffix("scaffold.sh") }), let cwd {
                    let css = cwd.appendingPathComponent("src/styles/global.css")
                    let astro = cwd.appendingPathComponent("src/pages/index.astro")
                    try? FileManager.default.createDirectory(at: css.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.createDirectory(at: astro.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? ":root { --color-primary: #2563eb; }".write(to: css, atomically: true, encoding: .utf8)
                    try? "<h1>Welcome</h1>".write(to: astro, atomically: true, encoding: .utf8)
                    try? "ANGLESITE_VERSION=1.0.0".write(to: cwd.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
                }
                return ProcessSupervisor.RunResult(stdout: "", stderr: "", exitCode: 0)
            },
            gitInit: { _ in },
            gitCommit: { _ in },
            register: { pkg in
                registeredConfigDirectory = pkg.configURL
                return SiteStore.Site(id: pkg.url.path, name: pkg.url.lastPathComponent, packageURL: pkg.url, isValid: true, missingSentinels: [])
            },
            attributionsLoader: { _ in [] }
        )

        _ = await m.build(using: scaffolder)

        let configDirectory = try #require(registeredConfigDirectory)
        let settings = try await SiteConfigStore(configDirectory: configDirectory).load()
        #expect(settings.activeWorkerIDs == [WorkerComposition.activitypubWorkerID])
    }
}

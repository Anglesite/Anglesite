import XCTest
@testable import AnglesiteCore

@MainActor
final class NewCommunityWizardModelTests: XCTestCase {

    func testStartsOnChooserWithEmptyNameAndCannotCreate() {
        let m = NewCommunityWizardModel(isNameTaken: { _ in false })
        XCTAssertEqual(m.step, .chooser)
        XCTAssertEqual(m.communityName, "")
        XCTAssertFalse(m.canCreate)
    }

    func testCanCreateOnceNameIsNonEmptyAndNotTaken() {
        let m = NewCommunityWizardModel(isNameTaken: { _ in false })
        m.communityName = "Birding Club"
        XCTAssertTrue(m.canCreate)
    }

    func testCannotCreateWhenNameIsTaken() {
        let m = NewCommunityWizardModel(isNameTaken: { $0 == "Birding Club" })
        m.communityName = "Birding Club"
        XCTAssertFalse(m.canCreate)
    }

    func testCannotCreateWithWhitespaceOnlyName() {
        let m = NewCommunityWizardModel(isNameTaken: { _ in false })
        m.communityName = "   "
        XCTAssertFalse(m.canCreate)
    }

    func testBuildDrivesScaffolderWithCommunitySiteTypeAndFixedTheme() async throws {
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

        XCTAssertNotNil(id)
        XCTAssertTrue(m.didCompleteCleanly)
        XCTAssertEqual(m.draft.siteType, .community)
        XCTAssertEqual(m.draft.name, "Birding Club")
        XCTAssertEqual(m.draft.themeID, "community")
        XCTAssertEqual(m.draft.headline, "")   // skip homepage write, matches NewSiteWizardModel's convention
        seenDraft = m.draft
        XCTAssertNotNil(seenDraft)
    }
}

import Testing
import Foundation
@testable import AnglesiteCore

@MainActor
struct NewSiteWizardModelTests {
    private func catalog() -> ThemeCatalog {
        ThemeCatalog(themes: [
            Theme(id: "classic", name: "Classic", blurb: "", swatch: [], cssVars: [:]),
            Theme(id: "warm", name: "Warm", blurb: "", swatch: [], cssVars: [:]),
        ])
    }

    /// Two Blank (uncategorized) themes plus one Business and one Personal — enough to prove
    /// filtering, pre-selection, and the empty-category case without needing a real pack.
    private func categorizedCatalog() -> ThemeCatalog {
        ThemeCatalog(themes: [
            Theme(id: "classic", name: "Classic", blurb: "", swatch: [], cssVars: [:]),
            Theme(id: "warm", name: "Warm", blurb: "", swatch: [], cssVars: [:]),
            Theme(id: "astrowind", name: "AstroWind", blurb: "", swatch: [], cssVars: [:], category: "business"),
            Theme(id: "cactus", name: "Astro Cactus", blurb: "", swatch: [], cssVars: [:], category: "personal"),
        ])
    }

    // MARK: Category sidebar (#1452)

    @Test("starts on the blank category showing uncategorized themes")
    func startsOnBlankCategoryShowingUncategorizedThemes() {
        let m = NewSiteWizardModel(catalog: categorizedCatalog(), isNameTaken: { _ in false })
        #expect(m.selectedCategory == .blank)
        #expect(m.filteredThemes.map(\.id) == ["classic", "warm"])
    }

    @Test("selecting a category filters the grid and records the site type")
    func selectingCategoryFiltersGridAndRecordsSiteType() {
        let m = NewSiteWizardModel(catalog: categorizedCatalog(), isNameTaken: { _ in false })
        m.selectCategory(.business)
        #expect(m.selectedCategory == .business)
        #expect(m.draft.siteType == .business)
        #expect(m.filteredThemes.map(\.id) == ["astrowind"])
        #expect(m.draft.themeID == "astrowind")
    }

    @Test("selecting a category with no themes leaves an empty selection")
    func selectingCategoryWithNoThemesLeavesEmptySelection() {
        let m = NewSiteWizardModel(catalog: categorizedCatalog(), isNameTaken: { _ in false })
        m.selectCategory(.portfolio)
        #expect(m.filteredThemes.isEmpty)
        #expect(m.draft.themeID == "")
        #expect(!m.canCreate)
    }

    @Test("switching back to blank restores the uncategorized grid and pre-selects")
    func switchingBackToBlankRestoresUncategorizedGridAndPreSelects() {
        let m = NewSiteWizardModel(catalog: categorizedCatalog(), isNameTaken: { _ in false })
        m.selectCategory(.business)
        m.selectCategory(.blank)
        #expect(m.draft.siteType == .blank)
        #expect(m.filteredThemes.map(\.id) == ["classic", "warm"])
        #expect(m.draft.themeID == "classic")   // defaultThemeID(for: .blank) == "classic", present in candidates
    }

    @Test("chooserCategories excludes community")
    func chooserCategoriesExcludesCommunity() {
        #expect(NewSiteWizardModel.chooserCategories ==
                       [.business, .personal, .blog, .portfolio, .organization, .blank])
    }

    /// Regression for the init pre-selection bug: a categorized theme ordered FIRST in the
    /// catalog must not get pre-selected just because it's `catalog.themes.first`. The initial
    /// draft (like ``selectedCategory``) starts on Blank, so pre-selection must come from the
    /// Blank-filtered set, matching what the (initially-shown) grid displays.
    @Test("init pre-selects from the blank-filtered set even when a categorized theme is first in the catalog")
    func initPreSelectsFromBlankFilteredSetEvenWhenACategorizedThemeIsFirstInCatalog() {
        let catalog = ThemeCatalog(themes: [
            Theme(id: "astrowind", name: "AstroWind", blurb: "", swatch: [], cssVars: [:], category: "business"),
            Theme(id: "classic", name: "Classic", blurb: "", swatch: [], cssVars: [:]),
            Theme(id: "warm", name: "Warm", blurb: "", swatch: [], cssVars: [:]),
        ])
        let m = NewSiteWizardModel(catalog: catalog, isNameTaken: { _ in false })
        #expect(m.selectedCategory == .blank)
        #expect(m.draft.themeID == "classic")   // first Blank (uncategorized) theme, not "astrowind"
        #expect(m.filteredThemes.contains { $0.id == m.draft.themeID })
    }

    // MARK: Chooser state (#1071)

    @Test("starts on chooser with the first theme and an untitled draft")
    func startsOnChooserWithFirstThemeAndUntitledDraft() {
        let m = NewSiteWizardModel(catalog: catalog(), isNameTaken: { _ in false })
        #expect(m.step == .chooser)
        #expect(m.draft.themeID == "classic")     // catalog order, not a per-type default
        #expect(m.draft.name == "Untitled")
        #expect(m.draft.saveFileName == "Untitled.anglesite")
        #expect(m.draft.siteType == .blank)
        #expect(m.draft.domainChoice == .later)   // deferred to publish (#1071)
        #expect(m.draft.headline == "")           // template placeholder stays
        #expect(m.canCreate)
    }

    @Test("the untitled name skips taken names")
    func untitledNameSkipsTakenNames() {
        let m = NewSiteWizardModel(catalog: catalog(),
                                   isNameTaken: { ["Untitled", "Untitled 2"].contains($0) })
        #expect(m.draft.name == "Untitled 3")
        #expect(m.draft.saveFileName == "Untitled 3.anglesite")
    }

    @Test("canCreate requires a catalog theme")
    func canCreateRequiresACatalogTheme() {
        let m = NewSiteWizardModel(catalog: catalog(), isNameTaken: { _ in false })
        m.draft.themeID = "no-such-theme"
        #expect(!m.canCreate)
        m.draft.themeID = "warm"
        #expect(m.canCreate)
    }

    @Test("an empty catalog cannot create")
    func emptyCatalogCannotCreate() {
        let m = NewSiteWizardModel(catalog: ThemeCatalog(themes: []), isNameTaken: { _ in false })
        #expect(!m.canCreate)
    }

    // MARK: Build warnings (#229)

    /// A scaffolder whose `scaffold.sh` writes the template files the appliers expect, then emits a
    /// non-fatal `git init` warning.
    private func warningScaffolder(root: URL) -> SiteScaffolder {
        SiteScaffolder(
            sitesRoot: root,
            templateURL: URL(fileURLWithPath: "/template"),
            catalog: catalog(),
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
            gitInit: { _ in throw CocoaError(.fileWriteUnknown) },
            gitCommit: { _ in },
            register: { pkg in SiteStore.Site(id: pkg.url.path, name: pkg.url.lastPathComponent, packageURL: pkg.url, isValid: true, missingSentinels: []) }
        )
    }

    @Test("a fresh model has no warnings and is not completed cleanly")
    func freshModelHasNoWarningsAndIsNotCompletedCleanly() {
        let m = NewSiteWizardModel(catalog: catalog(), isNameTaken: { _ in false })
        #expect(!m.hasWarnings)
        #expect(m.warnings.isEmpty)
        #expect(!m.didCompleteCleanly)
    }

    @Test("build enters the building step and disables create")
    func buildEntersBuildingStepAndDisablesCreate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let m = NewSiteWizardModel(catalog: catalog(), isNameTaken: { _ in false })
        _ = await m.build(using: warningScaffolder(root: root))
        #expect(m.step == .building)
        #expect(!m.canCreate)
    }

    @Test("build with a warning surfaces the warning and blocks clean completion")
    func buildWithWarningSurfacesWarningAndBlocksCleanCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let m = NewSiteWizardModel(catalog: catalog(), isNameTaken: { _ in false })

        let id = await m.build(using: warningScaffolder(root: root))

        #expect(id != nil)                       // the site was still registered
        #expect(m.hasWarnings)                    // …but with a non-fatal warning
        // Assert on the stable step identifier, not the (rephrasable) message text.
        #expect(m.progress.contains {
            if case .warning(let step, _) = $0 { return step == "copyingTemplate" } else { return false }
        })
        #expect(!m.didCompleteCleanly)             // so the wizard must NOT auto-open
    }
}

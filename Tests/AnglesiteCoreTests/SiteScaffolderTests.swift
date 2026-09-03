import Testing
import Foundation
import os
import AnglesiteTestSupport
@testable import AnglesiteCore

struct SiteScaffolderTests {

    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeDraft() -> NewSiteDraft {
        NewSiteDraft(siteType: .business, name: "Acme Co", tagline: "We build.",
                     themeID: "classic", headline: "Acme", blurb: "Welcome to Acme.")
    }

    private func makeScaffolder(root: URL, calls: CallRecorder = CallRecorder()) -> SiteScaffolder {
        SiteScaffolder(
            sitesRoot: root,
            templateURL: URL(fileURLWithPath: "/template"),
            catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(calls: calls),
            gitInit: { _ in },
            gitCommit: { _ in },
            register: { pkg in try SiteStore.Site.make(package: pkg) }
        )
    }

    private let theme = Theme(id: "classic", name: "Classic", blurb: "", swatch: [],
                              cssVars: ["color-primary": "#1e3a5f"])

    /// A scaffolder whose catalog carries a pack-bearing theme and whose templateURL
    /// points at a real temp template containing packs/<packName>/.
    private func makePackScaffolder(root: URL, packName: String = "paper",
                                    includePackDir: Bool = true) throws -> SiteScaffolder {
        let templateDir = tmpDir()
        if includePackDir {
            let packSrc = templateDir.appendingPathComponent("packs/\(packName)/src/styles")
            try FileManager.default.createDirectory(at: packSrc, withIntermediateDirectories: true)
            // Deliberately a DIFFERENT primary than the theme's cssVars below: PackApplier fully
            // overwrites global.css, so if the pipeline ran ThemeApplier before the pack overlay
            // (order swapped), this value would survive untouched and the assertions below would
            // still pass — using the same value in both places couldn't catch that bug.
            try ":root { --pack-marker: 1; --color-primary: #202020; }"
                .write(to: packSrc.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
            try "MIT — upstream".write(
                to: templateDir.appendingPathComponent("packs/\(packName)/LICENSE"),
                atomically: true, encoding: .utf8)
        }
        let packTheme = Theme(id: "paper", name: "Paper", blurb: "", swatch: [],
                              cssVars: ["color-primary": "#101010"],
                              category: "blog", pack: packName)
        return SiteScaffolder(
            sitesRoot: root,
            templateURL: templateDir,
            catalog: ThemeCatalog(themes: [packTheme]),
            run: fakeRunner(calls: CallRecorder()),
            gitInit: { _ in },
            gitCommit: { _ in },
            register: { pkg in try SiteStore.Site.make(package: pkg) }
        )
    }

    /// A fake CommandRunner that records calls and simulates scaffold.sh by writing the
    /// template files the appliers expect.
    private func fakeRunner(scaffoldExit: Int32 = 0, npmExit: Int32 = 0,
                            calls: CallRecorder) -> SiteScaffolder.CommandRunner {
        return { executable, args, cwd in
            await calls.append(args.joined(separator: " "))
            if args.contains(where: { $0.hasSuffix("scaffold.sh") }), scaffoldExit == 0, let cwd {
                // Simulate the template copy the real scaffold.sh performs.
                let css = cwd.appendingPathComponent("src/styles/global.css")
                let astro = cwd.appendingPathComponent("src/pages/index.astro")
                try? FileManager.default.createDirectory(at: css.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(at: astro.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? ":root {\n  --color-primary: #2563eb;\n  --color-accent: #f59e0b;\n}".write(to: css, atomically: true, encoding: .utf8)
                try? "<section class=\"hero\">\n  <h1>Welcome</h1>\n</section>".write(to: astro, atomically: true, encoding: .utf8)
                try? "ANGLESITE_VERSION=1.0.0".write(to: cwd.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
            }
            let exit = args.contains(where: { $0.hasSuffix("scaffold.sh") }) ? scaffoldExit : npmExit
            return ProcessSupervisor.RunResult(stdout: "", stderr: exit == 0 ? "" : "boom", exitCode: exit)
        }
    }

    @Test("the happy path emits steps in order and registers")
    func happyPathEmitsStepsInOrderAndRegisters() async throws {
        let root = tmpDir()
        // appVersion is injected (rather than defaulting to AppVersion.current()) so the
        // ANGLESITE_VERSION assertion below is deterministic: Bundle.main has no
        // CFBundleShortVersionString under some test hosts, which would otherwise leave the
        // scaffold.sh placeholder unstamped depending on which runner executes this test.
        let scaffolder = SiteScaffolder(
            sitesRoot: root, templateURL: URL(fileURLWithPath: "/template"), catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(calls: CallRecorder()),
            gitInit: { _ in },
            gitCommit: { _ in },
            register: { pkg in try SiteStore.Site.make(package: pkg) },
            appVersion: { "9.9.9" }
        )
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(makeDraft()) { steps.append(s) }

        #expect(steps.first == .creatingFolder)
        let pkgURL = root.appendingPathComponent("acme-co.anglesite")
        let expectedID = try AnglesitePackage(url: pkgURL).readMarker().siteID.uuidString
        if case .done(let id) = steps.last { #expect(id == expectedID) }
        else { Issue.record("expected .done last, got \(String(describing: steps.last))") }
        // .site-config gained SITE_NAME. The ANGLESITE_VERSION scaffold.sh's placeholder wrote
        // ("1.0.0") gets corrected to the injected app version by SiteScaffolder itself.
        let cfg = try String(contentsOf: pkgURL.appendingPathComponent("Source/.site-config"), encoding: .utf8)
        #expect(!cfg.contains("ANGLESITE_VERSION=1.0.0"))
        #expect(cfg.contains("ANGLESITE_VERSION=9.9.9"))
        #expect(cfg.contains("SITE_NAME=Acme Co"))
        #expect(cfg.contains("CF_PROJECT_NAME=acme-co"))
        // Theme + homepage applied in Source/:
        let css = try String(contentsOf: pkgURL.appendingPathComponent("Source/src/styles/global.css"), encoding: .utf8)
        #expect(css.contains("--color-primary: #1e3a5f;"))
    }

    @Test("the happy path writes a deployable wrangler config")
    func happyPathWritesADeployableWranglerConfig() async throws {
        let root = tmpDir()
        let scaffolder = makeScaffolder(root: root)
        for await _ in scaffolder.scaffold(makeDraft()) {}

        let pkgURL = root.appendingPathComponent("acme-co.anglesite")
        let toml = try String(contentsOf: pkgURL.appendingPathComponent("Source/wrangler.toml"), encoding: .utf8)
        #expect(toml.contains(#"name = "acme-co""#))
        #expect(toml.contains(#"directory = "dist""#))
        // Static-only: no social-feature bindings and no Worker entrypoint.
        #expect(!toml.contains("main ="))
        #expect(!toml.contains("d1_databases"))
    }

    /// Two sites with different names must never share a Worker name (#701 case 11):
    /// the slug is derived the same way the wizard's `slugTaken` uniqueness check runs against.
    @Test("two sites get distinct Worker names")
    func twoSitesGetDistinctWorkerNames() async throws {
        let root = tmpDir()
        let scaffolder = makeScaffolder(root: root)
        var second = makeDraft()
        second.name = "Beta Co"
        for await _ in scaffolder.scaffold(makeDraft()) {}
        for await _ in scaffolder.scaffold(second) {}

        let firstCfg = try String(
            contentsOf: root.appendingPathComponent("acme-co.anglesite/Source/.site-config"), encoding: .utf8)
        let secondCfg = try String(
            contentsOf: root.appendingPathComponent("beta-co.anglesite/Source/.site-config"), encoding: .utf8)
        #expect(firstCfg.contains("CF_PROJECT_NAME=acme-co"))
        #expect(secondCfg.contains("CF_PROJECT_NAME=beta-co"))
    }

    @Test("site config values are sanitized and blurb backfills tagline")
    func siteConfigValuesAreSanitizedAndBlurbBackfillsTagline() async throws {
        let root = tmpDir()
        let scaffolder = makeScaffolder(root: root)
        let draft = NewSiteDraft(siteType: .business,
                                 name: "Acme\nEVIL=1",
                                 domainChoice: .transfer,
                                 domain: "example.com\nEVIL=1",
                                 themeID: "classic",
                                 headline: "Acme",
                                 blurb: "Short description")

        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(draft) { steps.append(s) }

        guard case .done? = steps.last else {
            Issue.record("expected .done")
            return
        }
        let pkgURL = root.appendingPathComponent("acme-evil-1.anglesite")
        let cfg = try String(contentsOf: pkgURL.appendingPathComponent("Source/.site-config"), encoding: .utf8)
        #expect(cfg.contains("SITE_NAME=Acme"))
        #expect(cfg.contains("DOMAIN=example.com"))
        #expect(cfg.contains("TAGLINE=Short description"))
        #expect(!cfg.contains("EVIL=1"))
    }

    /// The chooser flow (#1071) hands over a fully-defaulted Untitled draft: blank type, no
    /// headline/blurb. The template's placeholder homepage must survive untouched, and
    /// `.site-config` must defer the domain (`later`) and omit `SITE_TYPE` entirely.
    @Test("a chooser draft keeps the template placeholder and omits the site type")
    func chooserDraftKeepsTemplatePlaceholderAndOmitsSiteType() async throws {
        let root = tmpDir()
        let scaffolder = makeScaffolder(root: root)
        let draft = NewSiteDraft(siteType: .blank, name: "Untitled",
                                 saveFileName: "Untitled.anglesite",
                                 themeID: "classic", headline: "")
        for await _ in scaffolder.scaffold(draft) {}

        let pkgURL = root.appendingPathComponent("Untitled.anglesite")
        // Homepage untouched: exactly the placeholder the fake scaffold.sh wrote.
        let home = try String(contentsOf: pkgURL.appendingPathComponent("Source/src/pages/index.astro"), encoding: .utf8)
        #expect(home == "<section class=\"hero\">\n  <h1>Welcome</h1>\n</section>")

        let cfg = try String(contentsOf: pkgURL.appendingPathComponent("Source/.site-config"), encoding: .utf8)
        #expect(cfg.contains("SITE_NAME=Untitled"))
        #expect(cfg.contains("CF_PROJECT_NAME=untitled"))
        #expect(cfg.contains("DOMAIN_CHOICE=later"))
        #expect(!cfg.contains("SITE_TYPE="))
        #expect(!cfg.contains("TAGLINE="))
    }

    /// The chooser's category sidebar (#1452) can now produce a non-blank `siteType` — prove
    /// the scaffolder actually writes it. Complements the Blank case above, which omits it.
    @Test("a non-blank site type writes the SITE_TYPE config key")
    func nonBlankSiteTypeWritesSiteConfigKey() async throws {
        let root = tmpDir()
        let scaffolder = makeScaffolder(root: root)
        let draft = makeDraft()   // siteType: .business
        for await _ in scaffolder.scaffold(draft) {}

        let cfg = try String(
            contentsOf: root.appendingPathComponent("acme-co.anglesite/Source/.site-config"),
            encoding: .utf8)
        #expect(cfg.contains("SITE_TYPE=business"))
    }

    @Test("a custom color scheme and logo are applied")
    func customColorSchemeAndLogoAreApplied() async throws {
        let root = tmpDir()
        let logo = root.appendingPathComponent("brand.PNG")
        try Data("logo".utf8).write(to: logo)
        let scaffolder = makeScaffolder(root: root)
        var draft = makeDraft()
        draft.themeID = CustomTheme.id
        draft.customPrimaryColor = "#123456"
        draft.customAccentColor = "#abcdef"
        draft.logoURL = logo

        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(draft) { steps.append(s) }

        guard case .done? = steps.last else {
            Issue.record("expected .done")
            return
        }
        let pkgURL = root.appendingPathComponent("acme-co.anglesite")
        let css = try String(contentsOf: pkgURL.appendingPathComponent("Source/src/styles/global.css"), encoding: .utf8)
        #expect(css.contains("--color-primary: #123456;"))
        #expect(css.contains("--color-accent: #abcdef;"))
        #expect(FileManager.default.fileExists(atPath: pkgURL.appendingPathComponent("Source/public/logo.png").path))
        let home = try String(contentsOf: pkgURL.appendingPathComponent("Source/src/pages/index.astro"), encoding: .utf8)
        #expect(home.contains(#"src="/logo.png""#))
        #expect(home.contains(#"class="site-logo""#))
        let cfg = try String(contentsOf: pkgURL.appendingPathComponent("Source/.site-config"), encoding: .utf8)
        #expect(cfg.contains("THEME=__custom"))
        #expect(cfg.contains("COLOR_PRIMARY=#123456"))
        #expect(cfg.contains("COLOR_ACCENT=#abcdef"))
        #expect(cfg.contains("LOGO=/logo.png"))
    }

    @Test("a custom save location and domain are used")
    func customSaveLocationAndDomainAreUsed() async throws {
        let root = tmpDir()
        let saveDirectory = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        let scaffolder = makeScaffolder(root: root)
        var draft = makeDraft()
        draft.domainChoice = .transfer
        draft.domain = "example.com"
        draft.saveDirectory = saveDirectory
        draft.saveFileName = "Example Website"

        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(draft) { steps.append(s) }

        guard case .done? = steps.last else {
            Issue.record("expected .done")
            return
        }
        let pkgURL = saveDirectory.appendingPathComponent("Example Website.anglesite")
        #expect(FileManager.default.fileExists(atPath: pkgURL.path))
        let cfg = try String(contentsOf: pkgURL.appendingPathComponent("Source/.site-config"), encoding: .utf8)
        #expect(cfg.contains("DOMAIN_CHOICE=transfer"))
        #expect(cfg.contains("DOMAIN=example.com"))
    }

    @Test("a scaffold failure is fatal")
    func scaffoldFailureIsFatal() async throws {
        let root = tmpDir()
        let scaffolder = SiteScaffolder(
            sitesRoot: root, templateURL: URL(fileURLWithPath: "/template"), catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(scaffoldExit: 1, calls: CallRecorder()),
            gitInit: { _ in },
            gitCommit: { _ in },
            register: { _ in
                Issue.record("must not register on scaffold failure")
                fatalError()
            }
        )
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(makeDraft()) { steps.append(s) }
        guard case .failed(let step, _)? = steps.last else {
            Issue.record("expected .failed")
            return
        }
        #expect(step == "copyingTemplate")
    }

    @Test("the happy path writes a dependency baseline and stamps the real app version")
    func happyPathWritesADependencyBaselineAndStampsTheRealAppVersion() async throws {
        let root = tmpDir()
        let templateURL = try templateRoot()
        let calls = CallRecorder()
        let scaffolder = SiteScaffolder(
            sitesRoot: root, templateURL: templateURL, catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(calls: calls),
            gitInit: { _ in },
            gitCommit: { _ in },
            register: { pkg in try SiteStore.Site.make(package: pkg) },
            appVersion: { "9.9.9" }
        )
        for await _ in scaffolder.scaffold(makeDraft()) {}

        let pkgURL = root.appendingPathComponent("acme-co.anglesite")
        let configDir = pkgURL.appendingPathComponent("Config")
        let baseline = DependencyBaseline.load(from: configDir)
        #expect(baseline != nil)
        #expect(baseline?["astro"] == "^7.1.3")  // matches Resources/Template/package.json today

        let siteConfig = try String(
            contentsOf: pkgURL.appendingPathComponent("Source/.site-config"), encoding: .utf8)
        let stampedVersion = SiteConfigFile.value(forKey: "ANGLESITE_VERSION", in: siteConfig)
        #expect(stampedVersion == "9.9.9")
        #expect(stampedVersion != "1.0.0")  // no longer the scaffold.sh placeholder
    }

    @Test("the happy path writes a third-party notices file from template attributions")
    func happyPathWritesThirdPartyNoticesFileFromTemplateAttributions() async throws {
        let root = tmpDir()
        let scaffolder = SiteScaffolder(
            sitesRoot: root, templateURL: URL(fileURLWithPath: "/template"), catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(calls: CallRecorder()),
            gitInit: { _ in },
            gitCommit: { _ in },
            register: { pkg in try SiteStore.Site.make(package: pkg) },
            attributionsLoader: { source in
                guard source == .websiteTemplate else { return [] }
                return [OSSAttribution(name: "astro", version: "7.1.3", licenseSPDXId: "MIT",
                                       licenseText: "MIT License text", homepage: "https://astro.build")]
            }
        )
        for await _ in scaffolder.scaffold(makeDraft()) {}

        let pkgURL = root.appendingPathComponent("acme-co.anglesite")
        let notice = try String(contentsOf: pkgURL.appendingPathComponent("Source/THIRD-PARTY-NOTICES.md"), encoding: .utf8)
        #expect(notice.contains("astro 7.1.3"))
        #expect(notice.contains("MIT License text"))
    }

    @Test("a missing attributions catalog warns but still registers")
    func missingAttributionsCatalogWarnsButStillRegisters() async throws {
        let root = tmpDir()
        let scaffolder = SiteScaffolder(
            sitesRoot: root, templateURL: URL(fileURLWithPath: "/template"), catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(calls: CallRecorder()),
            gitInit: { _ in },
            gitCommit: { _ in },
            register: { pkg in try SiteStore.Site.make(package: pkg) },
            attributionsLoader: { _ in throw AttributionCatalogError.resourceMissing(.websiteTemplate) }
        )
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(makeDraft()) { steps.append(s) }

        #expect(steps.contains {
            if case .warning(let s, let m) = $0 { return s == "copyingTemplate" && m.contains("Third-party notice") }
            return false
        })
        guard case .done? = steps.last else {
            Issue.record("expected .done despite missing attributions catalog")
            return
        }
    }

    /// #956: a newly scaffolded site's `<html lang>` must default to the owner's actual
    /// language, not a hardcoded "en" — `hostLanguage` is injected here since the real host
    /// locale running `swift test` varies by machine.
    @Test("the happy path stamps lang from the host language")
    func happyPathStampsLangFromHostLanguage() async throws {
        let root = tmpDir()
        let scaffolder = SiteScaffolder(
            sitesRoot: root, templateURL: URL(fileURLWithPath: "/template"), catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(calls: CallRecorder()),
            gitInit: { _ in },
            gitCommit: { _ in },
            register: { pkg in try SiteStore.Site.make(package: pkg) },
            hostLanguage: { "fr-CA" }
        )
        for await _ in scaffolder.scaffold(makeDraft()) {}

        let pkgURL = root.appendingPathComponent("acme-co.anglesite")
        let cfg = try String(contentsOf: pkgURL.appendingPathComponent("Source/.site-config"), encoding: .utf8)
        #expect(cfg.contains("LANG=fr-CA"))
    }

    @Test("a missing template package.json warns but still registers")
    func missingTemplatePackageJSONWarnsButStillRegisters() async throws {
        // makeScaffolder's default templateURL ("/template") has no package.json,
        // so reading it for the dependency baseline fails — this must surface as a
        // warning rather than disappearing silently (the site would otherwise never
        // get dependency-sync, with no record of why).
        let root = tmpDir()
        let scaffolder = makeScaffolder(root: root)
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(makeDraft()) { steps.append(s) }

        #expect(steps.contains { if case .warning(let s, _) = $0 { return s == "copyingTemplate" }; return false })
        let pkgURL = root.appendingPathComponent("acme-co.anglesite")
        #expect(DependencyBaseline.load(from: pkgURL.appendingPathComponent("Config")) == nil)
        guard case .done? = steps.last else {
            Issue.record("expected .done despite missing template package.json")
            return
        }
    }

    /// Resolve the real scaffold.sh from the in-repo template (Resources/Template/), mirroring
    /// HomepageWriterTests.realIndexAstroURL()'s repo-root-relative lookup.
    private static func realScaffoldScriptURL() -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Resources/Template/scripts/scaffold.sh")
    }

    private static var realScaffoldScriptExists: Bool {
        FileManager.default.fileExists(atPath: Self.realScaffoldScriptURL().path)
    }

    /// Regression coverage for #501: exercises the real scaffold.sh subprocess (not the mocked
    /// CommandRunner the other tests use) to confirm .site-config is still generated correctly
    /// now that the heredoc has been replaced with printf. Other tests in this file mock
    /// scaffold.sh entirely, so they wouldn't catch a reintroduced heredoc-shaped regression here.
    @Test(
        "the real scaffold.sh script writes .site-config without a heredoc",
        .enabled(if: SiteScaffolderTests.realScaffoldScriptExists, "scaffold.sh not found")
    )
    func realScaffoldScriptWritesSiteConfigWithoutHeredoc() throws {
        let script = Self.realScaffoldScriptURL()
        let target = tmpDir().appendingPathComponent("scaffold-test")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path, "--yes", target.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "scaffold.sh failed: \(stderr)")
        #expect(!stderr.contains("here document"), "heredoc scratch-file error reintroduced: \(stderr)")

        let cfg = try String(contentsOf: target.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(cfg.contains("ANGLESITE_VERSION=1.0.0"))
        #expect(cfg.contains("# SITE_URL=https://example.com"))
    }

    @Test("a git init failure is non-fatal and still registers")
    func gitInitFailureIsNonFatalAndStillRegisters() async throws {
        let root = tmpDir()
        let registered = OSAllocatedUnfairLock<Bool>(initialState: false)
        let scaffolder = SiteScaffolder(
            sitesRoot: root, templateURL: URL(fileURLWithPath: "/template"), catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(calls: CallRecorder()),
            gitInit: { _ in throw CocoaError(.fileWriteUnknown) },
            gitCommit: { _ in },
            register: { pkg in
                registered.withLock { $0 = true }
                return try SiteStore.Site.make(package: pkg)
            }
        )
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(makeDraft()) { steps.append(s) }
        #expect(registered.withLock { $0 }, "git init failure should not block registration")
        #expect(steps.contains { if case .warning(let s, _) = $0 { return s == "copyingTemplate" }; return false })
        guard case .done? = steps.last else {
            Issue.record("expected .done despite git init failure")
            return
        }
    }

    @Test("a git commit failure is non-fatal and still registers")
    func gitCommitFailureIsNonFatalAndStillRegisters() async throws {
        let root = tmpDir()
        let registered = OSAllocatedUnfairLock<Bool>(initialState: false)
        let scaffolder = SiteScaffolder(
            sitesRoot: root, templateURL: URL(fileURLWithPath: "/template"), catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(calls: CallRecorder()),
            gitInit: { _ in },
            gitCommit: { _ in throw CocoaError(.fileWriteUnknown) },
            register: { pkg in
                registered.withLock { $0 = true }
                return try SiteStore.Site.make(package: pkg)
            }
        )
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(makeDraft()) { steps.append(s) }
        #expect(registered.withLock { $0 }, "initial-commit failure should not block registration")
        #expect(steps.contains { if case .warning(let s, let m) = $0 { return s == "writingContent" && m.contains("Initial commit skipped") }; return false })
        guard case .done? = steps.last else {
            Issue.record("expected .done despite git commit failure")
            return
        }
    }

    /// Regression coverage for the missing-initial-commit bug: a brand-new site's `gitInit`
    /// closure creates a real `.git` (via `GitInitRunner`, same as production) and `gitCommit`
    /// creates a real commit (via `RepoBootstrap.commitAll`, same as production) — asserting the
    /// scaffolded repo actually has a `HEAD` afterward, not just that the closures were called.
    /// Without the fix, `Source/` had a `.git` but zero commits, so a container runtime cloning
    /// it and running `git checkout HEAD` failed and the site could never preview.
    @Test("the happy path lands a real initial commit")
    func happyPathLandsARealInitialCommit() async throws {
        let root = tmpDir()
        let scaffolder = SiteScaffolder(
            sitesRoot: root, templateURL: URL(fileURLWithPath: "/template"), catalog: ThemeCatalog(themes: [theme]),
            run: fakeRunner(calls: CallRecorder()),
            gitInit: { sourceDir in
                try GitInitRunner.run(in: sourceDir)
            },
            gitCommit: { sourceDir in try await RepoBootstrap.live().commitAll(source: sourceDir) },
            register: { pkg in try SiteStore.Site.make(package: pkg) }
        )
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(makeDraft()) { steps.append(s) }
        guard case .done? = steps.last else {
            Issue.record("expected .done, got \(String(describing: steps.last))")
            return
        }

        let pkgURL = root.appendingPathComponent("acme-co.anglesite")
        let sourceDir = pkgURL.appendingPathComponent("Source")
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let log = try await ProcessSupervisor.shared.run(
            executable: git, arguments: ["log", "--oneline"], currentDirectoryURL: sourceDir)
        #expect(log.exitCode == 0, "git log failed — no initial commit was created: \(log.stderr)")
        #expect(!log.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "expected at least one commit in the freshly scaffolded Source/ repo")
    }

    @Test("a pack theme overlays files and copies the LICENSE")
    func packThemeOverlaysFilesAndCopiesLicense() async throws {
        let root = tmpDir()
        let scaffolder = try makePackScaffolder(root: root)
        var draft = makeDraft()
        draft.themeID = "paper"
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(draft) { steps.append(s) }

        guard case .done? = steps.last else {
            Issue.record("expected .done, got \(String(describing: steps.last))")
            return
        }
        let source = root.appendingPathComponent("acme-co.anglesite/Source")
        let css = try String(contentsOf: source.appendingPathComponent("src/styles/global.css"), encoding: .utf8)
        // The pack's css landed, then ThemeApplier reaffirmed the palette over it.
        #expect(css.contains("--pack-marker: 1"))
        #expect(css.contains("--color-primary: #101010;"))
        let license = try String(contentsOf: source.appendingPathComponent(PackApplier.licenseFileName), encoding: .utf8)
        #expect(license == "MIT — upstream")
    }

    @Test("a missing pack directory warns but still scaffolds")
    func missingPackDirWarnsButStillScaffolds() async throws {
        let root = tmpDir()
        let scaffolder = try makePackScaffolder(root: root, includePackDir: false)
        var draft = makeDraft()
        draft.themeID = "paper"
        var steps: [SiteScaffolder.ScaffoldStep] = []
        for await s in scaffolder.scaffold(draft) { steps.append(s) }

        guard case .done? = steps.last else {
            Issue.record("expected .done, got \(String(describing: steps.last))")
            return
        }
        let sawPackWarning = steps.contains { step in
            if case .warning(let s, _) = step { return s == "applyingTheme" }
            return false
        }
        #expect(sawPackWarning, "expected a non-fatal applyingTheme warning for the missing pack")
        // ThemeApplier still ran on the base css the fake runner wrote.
        let css = try String(
            contentsOf: root.appendingPathComponent("acme-co.anglesite/Source/src/styles/global.css"),
            encoding: .utf8)
        #expect(css.contains("--color-primary: #101010;"))
    }
}

/// Tiny test helper: records command-runner calls behind an actor (no data race in @Sendable).
actor CallRecorder {
    private(set) var calls: [String] = []
    func append(_ s: String) { calls.append(s) }
}

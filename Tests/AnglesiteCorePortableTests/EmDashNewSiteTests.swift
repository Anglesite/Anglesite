// Lives in the portable target on purpose: the New Site kind choice, the EmDash scaffold step and
// the deploy refusal are pure Foundation, and this is the only AnglesiteCore test target the
// Linux CI leg executes (AnglesiteCoreTests isn't purity-swept — see Package.swift). The
// wizard's picker is macOS-only.
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("New EmDash site (#2050)")
struct EmDashNewSiteTests {

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmDashNewSiteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The repo's own template content folder, so the test tracks the real starter entries.
    private static let templateContent = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Template/src/content", isDirectory: true)

    @Test("a new site is an Anglesite site unless the owner picks EmDash")
    func defaultKind() {
        #expect(NewSiteDraft(siteType: .blank, name: "Untitled").siteKind == .anglesite)
        #expect(NewSiteWizardModel.siteKindChoices == [.anglesite, .emdash])
    }

    @Test("starter content is removed from every collection, which keeps its folder")
    func removesStarterContent() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appendingPathComponent("src/content", isDirectory: true)
        try FileManager.default.createDirectory(at: content.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.templateContent, to: content)
        let config = root.appendingPathComponent("src/content.config.ts")
        try Data("export const collections = {};\n".utf8).write(to: config)
        let collections = try FileManager.default.contentsOfDirectory(atPath: content.path).sorted()
        #expect(!collections.isEmpty)

        try EmDashScaffold.removeStarterContent(siteDirectory: root)

        #expect(try FileManager.default.contentsOfDirectory(atPath: content.path).sorted() == collections)
        for collection in collections {
            let entries = try FileManager.default.contentsOfDirectory(atPath: content.appendingPathComponent(collection).path)
            #expect(entries == [".gitkeep"], "\(collection)")
        }
        #expect(FileManager.default.fileExists(atPath: config.path))
    }

    @Test("the template never references a starter entry outside its collection folder")
    func templateIntegrityWithoutStarterContent() throws {
        // Removing the starter entries is only safe while every page lists collections
        // dynamically. A page that linked or rendered one by slug would break on an EmDash site.
        let template = Self.templateContent.deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        let slugs = try fm.subpathsOfDirectory(atPath: Self.templateContent.path)
            .filter { $0.hasSuffix(".md") }
            .map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        #expect(!slugs.isEmpty)
        var offenders: [String] = []
        for folder in ["src", "public", "scripts"] {
            let root = template.appendingPathComponent(folder)
            guard let paths = fm.enumerator(atPath: root.path) else { continue }
            for case let path as String in paths {
                guard !path.hasPrefix("content/"), !path.contains(".test."),
                      ["astro", "ts", "js", "mjs", "md", "mdx", "json", "html"].contains((path as NSString).pathExtension),
                      let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                else { continue }
                for line in text.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
                    for slug in slugs where line.contains(slug) {
                        offenders.append("\(folder)/\(path): \(slug)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test("Publish Site and the deploy share one refusal decision")
    func sharedStaticDeployRefusal() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (anglesite, _) = try AnglesitePackage.createSkeleton(at: root.appendingPathComponent("Blog.anglesite"), displayName: "Blog")
        let (emdash, _) = try AnglesitePackage.createSkeleton(
            at: root.appendingPathComponent("News.anglesite"), displayName: "News", kind: .emdash)
        #expect(SiteEditingSurfaces.staticDeployRefusal(sourceDirectory: anglesite.sourceURL) == nil)
        #expect(SiteEditingSurfaces.staticDeployRefusal(sourceDirectory: emdash.sourceURL)
            == SiteEditingSurfaces.staticDeployUnavailableReason)
        try FileManager.default.removeItem(at: anglesite.infoPlistURL)
        #expect(SiteEditingSurfaces.staticDeployRefusal(sourceDirectory: anglesite.sourceURL)
            == SiteEditingSurfaces.siteKindUnconfirmedReason)
        // A bare directory (tests, import) isn't a package, so nothing to refuse.
        #expect(SiteEditingSurfaces.staticDeployRefusal(sourceDirectory: root) == nil)
    }

    @Test("a site with no content folder is left alone")
    func noContentFolder() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try EmDashScaffold.removeStarterContent(siteDirectory: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("scaffolding an EmDash draft records the kind and ships no starter posts", arguments: [
        AnglesitePackage.SiteKind.anglesite, .emdash,
    ])
    func scaffoldsKind(kind: AnglesitePackage.SiteKind) async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = root.appendingPathComponent("Template", isDirectory: true)
        try FileManager.default.createDirectory(at: template.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data(#"{"dependencies":{"astro":"^7.0.0"}}"#.utf8).write(to: template.appendingPathComponent("package.json"))
        let overlay = template.appendingPathComponent("emdash/src/pages/articles", isDirectory: true)
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        try Data("// overlay config\n".utf8).write(to: template.appendingPathComponent("emdash/astro.config.ts"))
        try Data("# about the overlay\n".utf8).write(to: template.appendingPathComponent("emdash/README.md"))
        try Data(#"{"dependencies":{"astro":"7.3.4","emdash":"1.0.1"}}"#.utf8)
            .write(to: template.appendingPathComponent("emdash/package.json"))
        try Data("---\n---\n".utf8).write(to: overlay.appendingPathComponent("index.astro"))

        // Stands in for scaffold.sh: copies a config and a README, and drops one starter post
        // into the new Source/.
        let scaffolder = SiteScaffolder(
            sitesRoot: root,
            templateURL: template,
            catalog: ThemeCatalog(themes: []),
            run: { _, args, _ in
                let source = URL(fileURLWithPath: args.last ?? "")
                try Data("// template config\n".utf8).write(to: source.appendingPathComponent("astro.config.ts"))
                try Data("# the site\n".utf8).write(to: source.appendingPathComponent("README.md"))
                let blog = source.appendingPathComponent("src/content/blog", isDirectory: true)
                try FileManager.default.createDirectory(at: blog, withIntermediateDirectories: true)
                try Data("---\ntitle: Welcome\n---\n".utf8).write(to: blog.appendingPathComponent("welcome.md"))
                return .init(stdout: "", stderr: "", exitCode: 0)
            },
            gitInit: { _ in },
            gitCommit: { _ in },
            register: { try SiteStore.Site.make(package: $0) },
            attributionsLoader: { _ in [] },
            appVersion: { "1.0.0" },
            hostLanguage: { "en" }
        )

        var site: String?
        for await step in scaffolder.scaffold(NewSiteDraft(siteType: .blog, name: "News", siteKind: kind)) {
            if case .done(let id) = step { site = id }
            if case .failed(let at, let message) = step { Issue.record("scaffold failed at \(at): \(message)") }
        }

        let package = AnglesitePackage(url: root.appendingPathComponent("news.anglesite", isDirectory: true))
        let marker = try package.readMarker()
        #expect(site == marker.siteID.uuidString)
        #expect(marker.kind == kind)
        let starter = package.sourceURL.appendingPathComponent("src/content/blog/welcome.md")
        #expect(FileManager.default.fileExists(atPath: starter.path) == (kind == .anglesite))

        // An EmDash site gets the overlay on top, building on the template's renamed config; its
        // dependency baseline is the overlay's. An Anglesite site gets neither.
        let source = package.sourceURL
        let read = { (path: String) in try? String(contentsOf: source.appendingPathComponent(path), encoding: .utf8) }
        let baseline = DependencyBaseline.load(from: package.configURL)
        #expect(read("README.md") == "# the site\n")
        if kind == .emdash {
            #expect(read("astro.config.ts") == "// overlay config\n")
            #expect(read(EmDashScaffold.templateConfigFileName) == "// template config\n")
            #expect(read("src/pages/articles/index.astro") == "---\n---\n")
            #expect(baseline?["emdash"] == "1.0.1")
        } else {
            #expect(read("astro.config.ts") == "// template config\n")
            #expect(read(EmDashScaffold.templateConfigFileName) == nil)
            #expect(read("src/pages/articles/index.astro") == nil)
            #expect(baseline?["emdash"] == nil)
            #expect(baseline?["astro"] == "^7.0.0")
        }
    }

    @Test("dependency sync tracks the overlay's package.json for an EmDash site only")
    func packageTemplateDirectory() {
        let template = URL(fileURLWithPath: "/T", isDirectory: true)
        #expect(EmDashScaffold.packageTemplateDirectory(templateURL: template, kind: .emdash).path == "/T/emdash")
        #expect(EmDashScaffold.packageTemplateDirectory(templateURL: template, kind: .anglesite).path == "/T")
        #expect(EmDashScaffold.packageTemplateDirectory(templateURL: template, kind: .unrecognized("x")).path == "/T")
    }

    @Test("the overlay's skips apply at its top level only, and a symbolic link is refused")
    func overlayCopyRules() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let template = root.appendingPathComponent("Template", isDirectory: true)
        let overlay = template.appendingPathComponent("emdash", isDirectory: true)
        let site = root.appendingPathComponent("Source", isDirectory: true)
        try fm.createDirectory(at: overlay.appendingPathComponent("dist"), withIntermediateDirectories: true)
        try fm.createDirectory(at: overlay.appendingPathComponent("src/dist"), withIntermediateDirectories: true)
        try fm.createDirectory(at: site, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: overlay.appendingPathComponent("dist/stale.js"))
        try Data("x".utf8).write(to: overlay.appendingPathComponent("src/dist/kept.ts"))
        try Data("x".utf8).write(to: overlay.appendingPathComponent("src/README.md"))
        try Data("// t".utf8).write(to: site.appendingPathComponent("astro.config.ts"))

        try EmDashScaffold.applyTemplateOverlay(templateURL: template, siteDirectory: site)
        #expect(!fm.fileExists(atPath: site.appendingPathComponent("dist").path))
        #expect(fm.fileExists(atPath: site.appendingPathComponent("src/dist/kept.ts").path))
        #expect(fm.fileExists(atPath: site.appendingPathComponent("src/README.md").path))

        let link = overlay.appendingPathComponent("src/linked.ts")
        try fm.createSymbolicLink(at: link, withDestinationURL: overlay.appendingPathComponent("src/dist/kept.ts"))
        try Data("// t".utf8).write(to: site.appendingPathComponent("astro.config.ts"))
        #expect(throws: EmDashScaffold.OverlayError.symbolicLinkInOverlay(link.path)) {
            try EmDashScaffold.applyTemplateOverlay(templateURL: template, siteDirectory: site)
        }
    }

    @Test("applying the overlay needs the overlay and the template's config")
    func overlayPreconditions() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = root.appendingPathComponent("Template", isDirectory: true)
        let site = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        #expect(throws: EmDashScaffold.OverlayError.overlayNotFound(template.appendingPathComponent("emdash").path)) {
            try EmDashScaffold.applyTemplateOverlay(templateURL: template, siteDirectory: site)
        }
        try FileManager.default.createDirectory(at: template.appendingPathComponent("emdash"), withIntermediateDirectories: true)
        #expect(throws: EmDashScaffold.OverlayError.templateConfigMissing(site.appendingPathComponent("astro.config.ts").path)) {
            try EmDashScaffold.applyTemplateOverlay(templateURL: template, siteDirectory: site)
        }
    }

    @Test("the static deploy refuses an EmDash site before doing anything")
    func deployRefusesEmDash() async throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (package, _) = try AnglesitePackage.createSkeleton(
            at: root.appendingPathComponent("News.anglesite"), displayName: "News", kind: .emdash)
        let command = DeployCommand(target: CloudflareDeployTarget(tokenSource: { nil }), templateDirectory: { nil })
        let result = await command.deploy(
            siteID: "news", siteDirectory: package.sourceURL, configDirectory: package.configURL)
        #expect(result == .failed(reason: SiteEditingSurfaces.staticDeployUnavailableReason, exitCode: nil))
        #expect(SiteEditingSurfaces(kind: .anglesite).staticDeploy)

        // A package whose marker can't be read is refused too, with its own reason.
        let (anglesite, _) = try AnglesitePackage.createSkeleton(
            at: root.appendingPathComponent("Blog.anglesite"), displayName: "Blog")
        try FileManager.default.removeItem(at: anglesite.infoPlistURL)
        let unreadable = await command.deploy(
            siteID: "blog", siteDirectory: anglesite.sourceURL, configDirectory: anglesite.configURL)
        #expect(unreadable == .failed(reason: SiteEditingSurfaces.siteKindUnconfirmedReason, exitCode: nil))
        #expect(!SiteEditingSurfaces(kind: .unrecognized("x")).staticDeploy)
    }
}

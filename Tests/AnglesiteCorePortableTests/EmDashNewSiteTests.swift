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

        // Stands in for scaffold.sh: drops one starter post into the new Source/.
        let scaffolder = SiteScaffolder(
            sitesRoot: root,
            templateURL: template,
            catalog: ThemeCatalog(themes: []),
            run: { _, args, _ in
                let source = URL(fileURLWithPath: args.last ?? "")
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

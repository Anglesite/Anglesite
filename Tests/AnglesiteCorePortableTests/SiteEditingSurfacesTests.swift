// Lives in the portable target on purpose: the site-kind policy and the recents `kind` field are
// pure Foundation, and this is the only AnglesiteCore test target the Linux CI leg executes
// (AnglesiteCoreTests isn't purity-swept — see Package.swift). Runs on macOS too, where it is
// plain coverage. The app-side gates that read this policy are macOS-only.
import Testing
import Foundation
import AnglesiteSiteModel
@testable import AnglesiteCore

@Suite("SiteEditingSurfaces (#2050)")
struct SiteEditingSurfacesTests {

    @Test("an Anglesite site offers every in-app surface and no external editor")
    func anglesiteSite() throws {
        let surfaces = SiteEditingSurfaces(kind: .anglesite)
        #expect(surfaces.typedContent)
        #expect(surfaces.pagesAndLayout)
        #expect(surfaces.externalContentEditor == nil)
        try surfaces.requireTypedContent()
    }

    @Test("an EmDash site hides typed content, keeps pages and layout, and points at EmDash")
    func emdashSite() {
        let surfaces = SiteEditingSurfaces(kind: .emdash)
        #expect(!surfaces.typedContent)
        #expect(surfaces.pagesAndLayout)
        #expect(surfaces.externalContentEditor == .emdash)
        #expect(throws: SiteEditingSurfaces.TypedContentUnavailable(kind: .emdash, externalContentEditor: .emdash)) {
            try surfaces.requireTypedContent()
        }
    }

    @Test("an unrecognised kind offers nothing (it opens read-only)")
    func unrecognisedSite() {
        let surfaces = SiteEditingSurfaces(kind: .unrecognized("ghost"))
        #expect(!surfaces.typedContent)
        #expect(!surfaces.pagesAndLayout)
        #expect(surfaces.externalContentEditor == nil)
        #expect(throws: SiteEditingSurfaces.TypedContentUnavailable.self) {
            try surfaces.requireTypedContent()
        }
    }

    @Test("Open EmDash accepts only an https admin URL on an EmDash site")
    func emdashAdminURL() throws {
        let admin = try #require(URL(string: "https://news.example/_emdash/admin"))
        let emdash = SiteEditingSurfaces(kind: .emdash)
        #expect(emdash.emdashAdminURL(settings: SiteSettings(emdashAdminURL: admin)) == admin)
        #expect(emdash.emdashAdminURL(settings: SiteSettings()) == nil)
        for raw in ["http://news.example/_emdash/admin", "file:///etc/passwd", "emdash://admin", "https:///admin"] {
            let url = try #require(URL(string: raw))
            #expect(emdash.emdashAdminURL(settings: SiteSettings(emdashAdminURL: url)) == nil, "\(raw)")
        }
        // A stray admin URL in an Anglesite site's settings never surfaces "Open EmDash".
        #expect(SiteEditingSurfaces(kind: .anglesite).emdashAdminURL(settings: SiteSettings(emdashAdminURL: admin)) == nil)
    }

    @Test("settings round-trip the EmDash admin URL, and older settings decode without it")
    func settingsRoundTrip() throws {
        let admin = try #require(URL(string: "https://news.example/_emdash/admin"))
        let encoded = try PropertyListEncoder().encode(SiteSettings(emdashAdminURL: admin))
        #expect(try PropertyListDecoder().decode(SiteSettings.self, from: encoded).emdashAdminURL == admin)
        let old = try PropertyListEncoder().encode(SiteSettings(displayName: "Old"))
        #expect(try PropertyListDecoder().decode(SiteSettings.self, from: old).emdashAdminURL == nil)
    }
}

@Suite("SiteStore.Site kind (#2050)")
struct SiteStoreSiteKindTests {

    private static func tempPackageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SiteStoreSiteKindTests-\(UUID().uuidString)")
            .appendingPathComponent("News.anglesite")
    }

    @Test("Site.make reads the kind from the package marker", arguments: [
        AnglesitePackage.SiteKind.anglesite, .emdash,
    ])
    func makeReadsKind(kind: AnglesitePackage.SiteKind) throws {
        let url = Self.tempPackageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (package, _) = try AnglesitePackage.createSkeleton(at: url, displayName: "News", kind: kind)
        #expect(try SiteStore.Site.make(package: package).kind == kind)
    }

    @Test("the kind survives a recents round-trip")
    func recentsRoundTrip() throws {
        let site = SiteStore.Site(
            id: UUID().uuidString, name: "News", packageURL: URL(fileURLWithPath: "/tmp/News.anglesite"),
            isValid: true, missingSentinels: [], kind: .emdash)
        let decoded = try JSONDecoder().decode(SiteStore.Site.self, from: JSONEncoder().encode(site))
        #expect(decoded.kind == .emdash)
        #expect(decoded == site)
    }

    @Test("a recents entry written before site kinds decodes as an Anglesite site")
    func legacyRecentsEntry() throws {
        let site = SiteStore.Site(
            id: UUID().uuidString, name: "Blog", packageURL: URL(fileURLWithPath: "/tmp/Blog.anglesite"),
            isValid: true, missingSentinels: [], kind: .emdash)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(site)) as? [String: Any])
        json.removeValue(forKey: "kind")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        #expect(try JSONDecoder().decode(SiteStore.Site.self, from: legacy).kind == .anglesite)
    }
}

@Suite("ContentCreationWorkflow EmDash backstop (#2050)")
struct ContentCreationWorkflowEmDashTests {

    /// Records which operations reached the underlying service, and always "succeeds".
    private final class Recorder: ContentOperationsService, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }
        private func record(_ call: String) -> ContentCreateResult {
            lock.withLock { _calls.append(call) }
            return .created(filePath: "src/\(call)", identifier: call)
        }
        func createPage(siteID: String, name: String, route: String?, onProgress: ProgressHandler?) async -> ContentCreateResult { record("page") }
        func createPost(siteID: String, title: String, collection: String?, slug: String?, onProgress: ProgressHandler?) async -> ContentCreateResult { record("post") }
        func createTyped(siteID: String, typeID: String, title: String, onProgress: ProgressHandler?) async -> ContentCreateResult { record("typed") }
        func createTypedSingleton(siteID: String, typeID: String, title: String, onProgress: ProgressHandler?) async -> ContentCreateResult { record("singleton") }
    }

    private static func workflow(kind: AnglesitePackage.SiteKind) throws -> (ContentCreationWorkflow, Recorder, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentCreationWorkflowEmDashTests-\(UUID().uuidString)")
        let (package, _) = try AnglesitePackage.createSkeleton(
            at: root.appendingPathComponent("News.anglesite"), displayName: "News", kind: kind)
        let source = package.sourceURL
        let recorder = Recorder()
        let workflow = ContentCreationWorkflow(
            operations: recorder,
            contentGraph: nil,
            siteDirectory: { _ in source },
            typedSlugCreator: { _, _, _, _, _, _ in .created(filePath: "src/content/blog/a.md", identifier: "a") },
            postDuplicator: { _, _, _, _ in .created(filePath: "src/content/blog/b.md", identifier: "b") },
            postPublisher: { _, _, _ in .created(filePath: "src/content/blog/a.md", identifier: "a") },
            postUnpublisher: { _, _, _ in .created(filePath: "src/content/blog/a.md", identifier: "a") }
        )
        return (workflow, recorder, root)
    }

    @Test("an EmDash site refuses every typed-content write and keeps pages and singletons")
    func emdashRefusesTypedContent() async throws {
        let (workflow, recorder, root) = try Self.workflow(kind: .emdash)
        defer { try? FileManager.default.removeItem(at: root) }
        let refused = ContentCreateResult.failed(reason: SiteEditingSurfaces.typedContentUnavailableReason)

        #expect(await workflow.createPost(siteID: "s", title: "Council vote", collection: nil, slug: nil) == refused)
        #expect(await workflow.createTyped(siteID: "s", typeID: "note", title: "Hi") == refused)
        #expect(await workflow.createTyped(siteID: "s", typeID: "bookmark", title: "Link", slug: nil) == refused)
        #expect(await workflow.duplicatePost(siteID: "s", relativePath: "a.md", collection: "blog", title: "Copy") == refused)
        #expect(await workflow.publish(siteID: "s", relativePath: "a.md", collection: "blog") == refused)
        #expect(await workflow.unpublish(siteID: "s", relativePath: "a.md", collection: "blog") == refused)
        #expect(recorder.calls.isEmpty)

        #expect(await workflow.createPage(siteID: "s", name: "About", route: nil) == .created(filePath: "src/page", identifier: "page"))
        #expect(await workflow.createTypedSingleton(siteID: "s", typeID: "profile", title: "Me") == .created(filePath: "src/singleton", identifier: "singleton"))
        #expect(recorder.calls == ["page", "singleton"])
    }

    @Test("an Anglesite site's typed-content writes reach the service unchanged")
    func anglesitePassesThrough() async throws {
        let (workflow, recorder, root) = try Self.workflow(kind: .anglesite)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await workflow.createPost(siteID: "s", title: "Hello", collection: nil, slug: nil) == .created(filePath: "src/post", identifier: "post"))
        #expect(await workflow.createTyped(siteID: "s", typeID: "bookmark", title: "Link", slug: nil) == .created(filePath: "src/content/blog/a.md", identifier: "a"))
        #expect(await workflow.publish(siteID: "s", relativePath: "a.md", collection: "blog") == .created(filePath: "src/content/blog/a.md", identifier: "a"))
        #expect(recorder.calls == ["post"])
    }

    @Test("a bare Source directory with no package marker is treated as an Anglesite site")
    func bareDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SiteEditingSurfaces.forSourceDirectory(dir).kind == .anglesite)
    }
}

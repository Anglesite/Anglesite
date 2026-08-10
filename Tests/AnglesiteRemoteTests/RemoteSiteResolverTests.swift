import Testing
import Foundation
@testable import AnglesiteRemote
@testable import AnglesiteCore

struct FakeBookmarking: SecurityScopedBookmarking {
    var createResult: Result<Data, Error> = .success(Data("bookmark".utf8))
    var resolveResult: Result<SecurityScopedBookmarkResolution, Error>
    func create(for url: URL) throws -> Data { try createResult.get() }
    func resolve(_ data: Data) throws -> SecurityScopedBookmarkResolution { try resolveResult.get() }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}

@Suite struct RemoteSiteResolverTests {
    static func makeStore() throws -> RemoteBookmarkStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bookmarks-\(UUID().uuidString).json")
        return RemoteBookmarkStore(fileURL: file)
    }

    @Test func firstTimeGrantPersistsBookmarkAndReturnsSourceDirectory() async throws {
        let panelURL = URL(fileURLWithPath: "/tmp/MySite.anglesite")
        let sourceURL = panelURL.appendingPathComponent("Source")
        let resolver = RemoteSiteResolver(
            bookmarkStore: try Self.makeStore(),
            bookmarking: FakeBookmarking(resolveResult: .success(.init(url: sourceURL, isStale: false))),
            presentOpenPanel: { _ in panelURL })
        let result = try await resolver.resolveSourceDirectory(siteID: "site-1", expectedPackageURL: panelURL)
        #expect(result == sourceURL)
    }

    @Test func secondCallReusesPersistedBookmarkWithoutPanel() async throws {
        var panelCallCount = 0
        let panelURL = URL(fileURLWithPath: "/tmp/MySite.anglesite")
        let sourceURL = panelURL.appendingPathComponent("Source")
        let store = try Self.makeStore()
        let resolver = RemoteSiteResolver(
            bookmarkStore: store,
            bookmarking: FakeBookmarking(resolveResult: .success(.init(url: sourceURL, isStale: false))),
            presentOpenPanel: { url in panelCallCount += 1; return url })
        _ = try await resolver.resolveSourceDirectory(siteID: "site-1", expectedPackageURL: panelURL)
        _ = try await resolver.resolveSourceDirectory(siteID: "site-1", expectedPackageURL: panelURL)
        #expect(panelCallCount == 1)
    }

    @Test func cancelledPanelThrowsUserCancelledGrant() async {
        let resolver = RemoteSiteResolver(
            bookmarkStore: try! Self.makeStore(),
            bookmarking: FakeBookmarking(resolveResult: .failure(SecurityScopedBookmarkError.resolveFailed("n/a"))),
            presentOpenPanel: { _ in nil })
        await #expect(throws: RemoteSiteResolverError.userCancelledGrant) {
            _ = try await resolver.resolveSourceDirectory(siteID: "site-1", expectedPackageURL: URL(fileURLWithPath: "/tmp/x"))
        }
    }

    /// The iCloud fast path (brief Step 4, final paragraph): when `expectedPackageURL` already
    /// sits inside the shared ubiquity container, resolution skips the bookmark dance entirely —
    /// no panel presented, no bookmark store touched, no `bookmarking` call made. Injects a fake
    /// `ubiquityContainerURLProvider` pointing at a temp directory standing in for the real
    /// ubiquity container, and a package URL nested inside it.
    @Test func iCloudSitePathSkipsBookmarkEntirely() async throws {
        var panelCallCount = 0
        let ubiquityRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ubiquity-\(UUID().uuidString)")
        let packageURL = ubiquityRoot
            .appendingPathComponent("Documents")
            .appendingPathComponent("MySite.anglesite")
        let sourceURL = packageURL.appendingPathComponent("Source")
        let resolver = RemoteSiteResolver(
            bookmarkStore: try Self.makeStore(),
            bookmarking: FakeBookmarking(resolveResult: .failure(SecurityScopedBookmarkError.resolveFailed("should not be called"))),
            presentOpenPanel: { url in panelCallCount += 1; return url },
            ubiquityContainerURLProvider: { ubiquityRoot })
        let result = try await resolver.resolveSourceDirectory(siteID: "site-2", expectedPackageURL: packageURL)
        #expect(result == sourceURL)
        #expect(panelCallCount == 0)
    }
}

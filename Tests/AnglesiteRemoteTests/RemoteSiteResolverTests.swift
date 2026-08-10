import Testing
import Foundation
@testable import AnglesiteRemote
@testable import AnglesiteCore

/// Thread-safe call counter shared by a `FakeBookmarking` instance across the possibly-multiple
/// `resolveSourceDirectory` calls a single test makes, so tests can assert the resolver opens
/// (and does not close) the resolved URL's security scope — see `RemoteSiteResolver
/// .resolveSourceDirectory`'s doc comment for why access is deliberately left open.
final class BookmarkingCallTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _startAccessingCallCount = 0
    private var _stopAccessingCallCount = 0

    var startAccessingCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _startAccessingCallCount
    }

    var stopAccessingCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _stopAccessingCallCount
    }

    func recordStartAccessing() {
        lock.lock(); defer { lock.unlock() }
        _startAccessingCallCount += 1
    }

    func recordStopAccessing() {
        lock.lock(); defer { lock.unlock() }
        _stopAccessingCallCount += 1
    }
}

struct FakeBookmarking: SecurityScopedBookmarking {
    var createResult: Result<Data, Error> = .success(Data("bookmark".utf8))
    var resolveResult: Result<SecurityScopedBookmarkResolution, Error>
    var tracker = BookmarkingCallTracker()
    func create(for url: URL) throws -> Data { try createResult.get() }
    func resolve(_ data: Data) throws -> SecurityScopedBookmarkResolution { try resolveResult.get() }
    func startAccessing(_ url: URL) -> Bool { tracker.recordStartAccessing(); return true }
    func stopAccessing(_ url: URL) { tracker.recordStopAccessing() }
}

@Suite struct RemoteSiteResolverTests {
    static func makeStore() throws -> RemoteBookmarkStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bookmarks-\(UUID().uuidString).json")
        return RemoteBookmarkStore(fileURL: file)
    }

    @Test func firstTimeGrantPersistsBookmarkAndReturnsSourceDirectory() async throws {
        let panelURL = URL(fileURLWithPath: "/tmp/MySite.anglesite")
        let sourceURL = panelURL.appendingPathComponent("Source")
        let bookmarking = FakeBookmarking(resolveResult: .success(.init(url: sourceURL, isStale: false)))
        let resolver = RemoteSiteResolver(
            bookmarkStore: try Self.makeStore(),
            bookmarking: bookmarking,
            presentOpenPanel: { _ in panelURL })
        let result = try await resolver.resolveSourceDirectory(siteID: "site-1", expectedPackageURL: panelURL)
        #expect(result == sourceURL)
        // Access to the resolved Source/ URL is opened for the caller's session-long use and
        // deliberately left open — not paired with a matching stopAccessing here.
        #expect(bookmarking.tracker.startAccessingCallCount == 1)
        #expect(bookmarking.tracker.stopAccessingCallCount == 0)
    }

    @Test func secondCallReusesPersistedBookmarkWithoutPanel() async throws {
        var panelCallCount = 0
        let panelURL = URL(fileURLWithPath: "/tmp/MySite.anglesite")
        let sourceURL = panelURL.appendingPathComponent("Source")
        let store = try Self.makeStore()
        let bookmarking = FakeBookmarking(resolveResult: .success(.init(url: sourceURL, isStale: false)))
        let resolver = RemoteSiteResolver(
            bookmarkStore: store,
            bookmarking: bookmarking,
            presentOpenPanel: { url in panelCallCount += 1; return url })
        _ = try await resolver.resolveSourceDirectory(siteID: "site-1", expectedPackageURL: panelURL)
        _ = try await resolver.resolveSourceDirectory(siteID: "site-1", expectedPackageURL: panelURL)
        #expect(panelCallCount == 1)
        // Both calls resolve the persisted bookmark and open access again; neither closes it.
        #expect(bookmarking.tracker.startAccessingCallCount == 2)
        #expect(bookmarking.tracker.stopAccessingCallCount == 0)
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
        let bookmarking = FakeBookmarking(resolveResult: .failure(SecurityScopedBookmarkError.resolveFailed("should not be called")))
        let resolver = RemoteSiteResolver(
            bookmarkStore: try Self.makeStore(),
            bookmarking: bookmarking,
            presentOpenPanel: { url in panelCallCount += 1; return url },
            ubiquityContainerURLProvider: { ubiquityRoot })
        let result = try await resolver.resolveSourceDirectory(siteID: "site-2", expectedPackageURL: packageURL)
        #expect(result == sourceURL)
        #expect(panelCallCount == 0)
        // The iCloud fast path never touches the bookmarking seam at all — sandboxed apps get
        // automatic access to their own ubiquity container from the entitlement alone.
        #expect(bookmarking.tracker.startAccessingCallCount == 0)
        #expect(bookmarking.tracker.stopAccessingCallCount == 0)
    }
}

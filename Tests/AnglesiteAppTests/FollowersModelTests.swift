import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Covers the recovery and paging behavior the whole-branch review found missing: every error
/// state has to be escapable from inside the pane, and paging has to be additive — a page that
/// fails, or a page that arrives twice, must not cost the owner the rows already on screen.
@Suite("FollowersModel")
@MainActor
struct FollowersModelTests {
    // MARK: - Fixtures

    /// A site directory whose `.site-config` optionally declares a published URL. `nil` models a
    /// site that has never been published — the `.noSiteURL` state.
    private static func makeSite(siteURL: String?) throws -> (CurrentSite, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FollowersModelTests-\(UUID().uuidString)")
        let source = root.appendingPathComponent("Source")
        let config = root.appendingPathComponent("Config")
        for directory in [source, config] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if let siteURL {
            try Data("SITE_URL=\(siteURL)\n".utf8).write(
                to: source.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath))
        }
        return (
            CurrentSite(
                id: "site-1", packageURL: root, sourceDirectory: source, configDirectory: config),
            root)
    }

    /// Publishes the site after the fact, the way the owner would in response to the
    /// `.noSiteURL` message.
    private static func publish(_ site: CurrentSite, siteURL: String) throws {
        try Data("SITE_URL=\(siteURL)\n".utf8).write(
            to: site.sourceDirectory.appendingPathComponent(
                WebsiteAnalyticsAsset.configRelativePath))
    }

    /// Serves the followers collection out of a scripted routing table, and records every URL it
    /// was asked for. An `actor` because the transport closure is `@Sendable`.
    private actor Server {
        /// Path suffix → JSON body. A path with no entry answers 404.
        private var routes: [String: String]
        private var failing: Set<String> = []
        private(set) var requestedPaths: [String] = []
        /// Signalled bodies wait here, so a test can hold a request open and observe what the
        /// model does while it's in flight.
        private var gateContinuations: [String: CheckedContinuation<Void, Never>] = [:]
        private var gatedPaths: Set<String> = []

        init(routes: [String: String]) {
            self.routes = routes
        }

        /// Also clears any scripted failure for the path — this is how a test models the owner
        /// fixing whatever was wrong and the route starting to answer.
        func setRoute(_ path: String, body: String) {
            routes[path] = body
            failing.remove(path)
        }
        func fail(_ path: String) { failing.insert(path) }
        func gate(_ path: String) { gatedPaths.insert(path) }

        /// Releases a gated path, letting its in-flight request complete.
        func release(_ path: String) {
            gatedPaths.remove(path)
            gateContinuations.removeValue(forKey: path)?.resume()
        }

        private func waitIfGated(_ path: String) async {
            guard gatedPaths.contains(path) else { return }
            await withCheckedContinuation { continuation in
                gateContinuations[path] = continuation
            }
        }

        fileprivate func respond(to request: URLRequest) async -> (Data, HTTPURLResponse) {
            let url = request.url!
            requestedPaths.append(url.path)
            await waitIfGated(url.path)

            let status = failing.contains(url.path) ? 500 : (routes[url.path] == nil ? 404 : 200)
            let http = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data((routes[url.path] ?? "nope").utf8), http)
        }

        fileprivate var transport: ActivityPubFollowersClient.Transport {
            { [self] request in await respond(to: request) }
        }
    }

    private static func collectionBody(total: Int, first: String?) -> String {
        let firstField = first.map { #""first":"\#($0)","# } ?? ""
        return #"{"totalItems":\#(total),\#(firstField)"type":"OrderedCollection"}"#
    }

    private static func pageBody(items: [String], next: String?) -> String {
        let nextField = next.map { #""next":"\#($0)","# } ?? ""
        let list = items.map { #""\#($0)""# }.joined(separator: ",")
        return #"{\#(nextField)"orderedItems":[\#(list)]}"#
    }

    /// A model whose profile enrichment never fires — these tests are about collection paging,
    /// and a live `ActorProfileFetcher` would reach the network.
    private static func makeModel(server: Server) async -> FollowersModel {
        FollowersModel(
            fetcher: ActorProfileFetcher(transport: { _ in
                throw ActorProfileError.requestFailed(status: 500)
            }),
            avatarLoader: AvatarLoader(transport: { _ in
                throw AvatarLoadError.requestFailed(status: 500)
            }),
            followersTransport: await server.transport)
    }

    final class InMemorySecretStore: SecretStore, @unchecked Sendable {
        var values: [String: String] = [:]
        func read(account: String) throws -> String? { values[account] }
        func write(_ value: String, account: String) throws { values[account] = value }
        func delete(account: String) throws { values.removeValue(forKey: account) }
    }

    /// Serves `GET <actor>/follow_requests` out of a scripted routing table, same shape as
    /// `Server` but for the membership (outbox/follow_requests) transport rather than the
    /// public followers transport.
    private actor MembershipServer {
        private var routes: [String: (status: Int, body: String)]
        private(set) var requestedBodies: [[String: Any]] = []

        init(routes: [String: (status: Int, body: String)] = [:]) {
            self.routes = routes
        }

        func setRoute(_ path: String, status: Int, body: String) {
            routes[path] = (status, body)
        }

        fileprivate func respond(to request: URLRequest) -> (Data, HTTPURLResponse) {
            if let data = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                requestedBodies.append(json)
            }
            let path = request.url!.path
            let (status, body) = routes[path] ?? (404, "not found")
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), http)
        }

        fileprivate var transport: CommunityMembershipClient.Transport {
            { [self] request in await respond(to: request) }
        }
    }

    /// A model with both a scripted followers server and a scripted membership (pending/
    /// accept/reject) server, plus a preloaded publish token — for pending-request tests.
    private static func makeModelWithPending(
        server: Server, membershipServer: MembershipServer, secretStore: InMemorySecretStore
    ) async -> FollowersModel {
        FollowersModel(
            fetcher: ActorProfileFetcher(transport: { _ in
                throw ActorProfileError.requestFailed(status: 500)
            }),
            avatarLoader: AvatarLoader(transport: { _ in
                throw AvatarLoadError.requestFailed(status: 500)
            }),
            followersTransport: await server.transport,
            secretStore: secretStore,
            membershipTransport: await membershipServer.transport)
    }

    private static func followRequestsBody(items: [(actor: String, addedAt: String)]) -> String {
        let list = items.map { #"{"actor":"\#($0.actor)","addedAt":"\#($0.addedAt)"}"# }.joined(separator: ",")
        return #"{"items":[\#(list)],"total":\#(items.count)}"#
    }

    // MARK: - Finding 2: every error state must be escapable

    /// The `.noSiteURL` message tells the owner to publish the site. Before the fix, the pane
    /// could never notice that they had: `configure(site:)` ran once per window and nothing
    /// re-resolved the URL, so the only escape was closing and reopening the window.
    @Test("retry re-resolves the site URL, so publishing recovers .noSiteURL")
    func retryRecoversNoSiteURL() async throws {
        let (site, root) = try Self.makeSite(siteURL: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server(routes: [
            "/users/site/followers": Self.collectionBody(total: 0, first: nil)
        ])
        let model = await Self.makeModel(server: server)

        model.configure(site: site)
        await model.load()
        #expect(model.state == .noSiteURL)

        // The owner goes and publishes, exactly as the message asked.
        try Self.publish(site, siteURL: "https://example.com")
        await model.retry()

        #expect(model.state == .loaded)
        #expect(model.totalItems == 0)
        #expect(model.actorURL?.absoluteString == "https://example.com/users/site")
    }

    /// The same escape hatch for the other terminal states — the owner turns ActivityPub on and
    /// republishes, and the pane has to be able to see it without a window restart.
    @Test("retry recovers from a server-side failure")
    func retryRecoversFailure() async throws {
        let (site, root) = try Self.makeSite(siteURL: "https://example.com")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server(routes: [:])
        await server.fail("/users/site/followers")
        let model = await Self.makeModel(server: server)

        model.configure(site: site)
        await model.load()
        guard case .unreachable = model.state else {
            Issue.record("expected .unreachable, got \(model.state)")
            return
        }

        await server.setRoute(
            "/users/site/followers", body: Self.collectionBody(total: 0, first: nil))
        await model.retry()
        #expect(model.state == .loaded)
    }

    // MARK: - Finding 2: a paging failure must not destroy the loaded rows

    /// `loadMore` used to share `load`'s failure handling, which flips `state` to an error — and
    /// the view renders an error state *instead of* the list. One failed "Load More" therefore
    /// hid every successfully-loaded row, with no way back.
    @Test("a loadMore failure keeps the rows and the loaded state")
    func loadMoreFailureIsNonDestructive() async throws {
        let (site, root) = try Self.makeSite(siteURL: "https://example.com")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server(routes: [
            "/users/site/followers": Self.collectionBody(
                total: 3, first: "https://example.com/users/site/followers/1"),
            "/users/site/followers/1": Self.pageBody(
                items: ["https://a.example/users/a", "https://b.example/users/b"],
                next: "https://example.com/users/site/followers/2"),
        ])
        await server.fail("/users/site/followers/2")
        let model = await Self.makeModel(server: server)

        model.configure(site: site)
        await model.load()
        #expect(model.rows.count == 2)

        await model.loadMore()

        #expect(model.state == .loaded)
        #expect(model.rows.count == 2)
        #expect(model.loadMoreFailure != nil)
    }

    @Test("a successful load clears a previous loadMore failure")
    func refreshClearsLoadMoreFailure() async throws {
        let (site, root) = try Self.makeSite(siteURL: "https://example.com")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server(routes: [
            "/users/site/followers": Self.collectionBody(
                total: 1, first: "https://example.com/users/site/followers/1"),
            "/users/site/followers/1": Self.pageBody(
                items: ["https://a.example/users/a"],
                next: "https://example.com/users/site/followers/2"),
        ])
        await server.fail("/users/site/followers/2")
        let model = await Self.makeModel(server: server)

        model.configure(site: site)
        await model.load()
        await model.loadMore()
        #expect(model.loadMoreFailure != nil)

        await model.refresh()
        #expect(model.loadMoreFailure == nil)
    }

    // MARK: - Finding 5: concurrent paging must not duplicate ForEach IDs

    /// `FollowerRow.id` is the actor IRI, and SwiftUI documents duplicate `ForEach` IDs as
    /// undefined behavior. Two overlapping `loadMore()` calls used to both pass the guard (`state`
    /// doesn't change during paging), fetch the same `nextPage`, and append the same items.
    @Test("overlapping loadMore calls append each follower once")
    func concurrentLoadMoreDoesNotDuplicateRows() async throws {
        let (site, root) = try Self.makeSite(siteURL: "https://example.com")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server(routes: [
            "/users/site/followers": Self.collectionBody(
                total: 2, first: "https://example.com/users/site/followers/1"),
            "/users/site/followers/1": Self.pageBody(
                items: ["https://a.example/users/a"],
                next: "https://example.com/users/site/followers/2"),
            "/users/site/followers/2": Self.pageBody(
                items: ["https://b.example/users/b"], next: nil),
        ])
        let model = await Self.makeModel(server: server)

        model.configure(site: site)
        await model.load()
        #expect(model.rows.count == 1)

        // Hold page 2 open so the second call is issued while the first is genuinely in flight.
        await server.gate("/users/site/followers/2")
        async let first: Void = model.loadMore()
        while !model.isLoadingMore { await Task.yield() }
        async let second: Void = model.loadMore()
        await server.release("/users/site/followers/2")
        _ = await (first, second)

        #expect(model.rows.count == 2)
        #expect(Set(model.rows.map(\.id)).count == model.rows.count)
        #expect(model.isLoadingMore == false)
    }

    /// The generation check: a page that was already in flight when `refresh()` reset the list
    /// must discard itself rather than appending stale items to the fresh rows.
    @Test("a page in flight across a refresh is discarded")
    func staleLoadMoreIsDiscarded() async throws {
        let (site, root) = try Self.makeSite(siteURL: "https://example.com")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server(routes: [
            "/users/site/followers": Self.collectionBody(
                total: 2, first: "https://example.com/users/site/followers/1"),
            "/users/site/followers/1": Self.pageBody(
                items: ["https://a.example/users/a"],
                next: "https://example.com/users/site/followers/2"),
            "/users/site/followers/2": Self.pageBody(
                items: ["https://b.example/users/b"], next: nil),
        ])
        let model = await Self.makeModel(server: server)

        model.configure(site: site)
        await model.load()

        await server.gate("/users/site/followers/2")
        async let paging: Void = model.loadMore()
        while !model.isLoadingMore { await Task.yield() }
        // The refresh completes first and resets `rows` to page 1 only.
        await model.refresh()
        await server.release("/users/site/followers/2")
        await paging

        #expect(model.rows.map(\.id) == ["https://a.example/users/a"])
    }

    // MARK: - Pending requests

    @Test("loadPending decodes the follow_requests list into enrichable rows")
    func loadPendingDecodesRequests() async throws {
        let (site, root) = try Self.makeSite(siteURL: "https://example.com")
        defer { try? FileManager.default.removeItem(at: root) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"
        let membershipServer = MembershipServer(routes: [
            "/users/site/follow_requests": (
                200,
                Self.followRequestsBody(items: [("https://mastodon.social/users/alice", "2026-08-01T00:00:00.000Z")])
            )
        ])
        let model = await Self.makeModelWithPending(
            server: Server(routes: [:]), membershipServer: membershipServer, secretStore: secretStore)
        model.configure(site: site)

        await model.loadPending()

        #expect(model.pendingState == .loaded)
        #expect(model.pendingRows.count == 1)
        #expect(model.pendingRows[0].request.actor.absoluteString == "https://mastodon.social/users/alice")
    }

    @Test("loadPending treats a 404 as unavailable, not an error")
    func loadPendingTreats404AsUnavailable() async throws {
        let (site, root) = try Self.makeSite(siteURL: "https://example.com")
        defer { try? FileManager.default.removeItem(at: root) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"
        let model = await Self.makeModelWithPending(
            server: Server(routes: [:]), membershipServer: MembershipServer(), secretStore: secretStore)
        model.configure(site: site)

        await model.loadPending()

        #expect(model.pendingState == .unavailable)
        #expect(model.pendingRows.isEmpty)
    }

    @Test("loadPending is a no-op with no publish token provisioned")
    func loadPendingNoOpsWithoutToken() async throws {
        let (site, root) = try Self.makeSite(siteURL: "https://example.com")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = await Self.makeModelWithPending(
            server: Server(routes: [:]), membershipServer: MembershipServer(), secretStore: InMemorySecretStore())
        model.configure(site: site)

        await model.loadPending()

        #expect(model.pendingState == .unknown)
        #expect(model.pendingRows.isEmpty)
    }
}

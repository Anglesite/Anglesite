import Testing
import Foundation
@testable import AnglesiteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("CommunityMembershipClient")
struct CommunityMembershipClientTests {
    actor FakeTransport {
        private let status: Int
        private let body: String
        private(set) var requestedURLs: [URL] = []
        private(set) var requestedHeaders: [[String: String]] = []
        private(set) var requestedBodies: [[String: Any]] = []
        private(set) var requestedTimeouts: [TimeInterval] = []

        init(status: Int = 202, body: String = "{}") {
            self.status = status
            self.body = body
        }

        private func respond(to request: URLRequest) throws -> (Data, HTTPURLResponse) {
            requestedURLs.append(request.url!)
            requestedHeaders.append(request.allHTTPHeaderFields ?? [:])
            requestedTimeouts.append(request.timeoutInterval)
            if let bodyData = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                requestedBodies.append(json)
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), http)
        }

        nonisolated var transport: CommunityMembershipClient.Transport {
            { request in try await self.respond(to: request) }
        }
    }

    private static func client(_ fake: FakeTransport) -> CommunityMembershipClient {
        CommunityMembershipClient(
            ownActorURL: URL(string: "https://example.com/users/site")!,
            publishToken: "secret-token",
            transport: fake.transport)
    }

    @Test("POSTs a Follow activity to this site's own outbox")
    func postsFollow() async throws {
        let fake = FakeTransport(status: 202, body: #"{"id":"https://example.com/users/site/outbox/1"}"#)
        let target = try #require(URL(string: "https://lemmy.ml/c/birding"))

        let activityID = try await Self.client(fake).follow(target: target)

        #expect(activityID == "https://example.com/users/site/outbox/1")
        #expect(await fake.requestedURLs.first?.absoluteString == "https://example.com/users/site/outbox")
        let headers = await fake.requestedHeaders.first
        #expect(headers?["Authorization"] == "Bearer secret-token")
        let body = await fake.requestedBodies.first
        #expect(body?["type"] as? String == "Follow")
        #expect(body?["object"] as? String == "https://lemmy.ml/c/birding")
        #expect(body?["actor"] as? String == "https://example.com/users/site")
    }

    @Test("falls back to the target URL as the activity id when the response carries none")
    func followWithoutIDInResponse() async throws {
        let fake = FakeTransport(status: 202, body: "{}")
        let target = try #require(URL(string: "https://lemmy.ml/c/birding"))

        let activityID = try await Self.client(fake).follow(target: target)

        #expect(activityID == "https://lemmy.ml/c/birding")
    }

    @Test("POSTs an Undo(Follow) referencing the original activity id")
    func postsUndoWithActivityID() async throws {
        let fake = FakeTransport()
        let target = try #require(URL(string: "https://lemmy.ml/c/birding"))

        try await Self.client(fake).unfollow(
            target: target, followActivityID: "https://example.com/users/site/outbox/1")

        let body = await fake.requestedBodies.first
        #expect(body?["type"] as? String == "Undo")
        #expect(body?["object"] as? String == "https://example.com/users/site/outbox/1")
    }

    @Test("synthesizes a nested Follow object for Undo when no activity id is known")
    func postsUndoWithoutActivityID() async throws {
        let fake = FakeTransport()
        let target = try #require(URL(string: "https://lemmy.ml/c/birding"))

        try await Self.client(fake).unfollow(target: target, followActivityID: nil)

        let body = await fake.requestedBodies.first
        #expect(body?["type"] as? String == "Undo")
        let nestedFollow = body?["object"] as? [String: Any]
        #expect(nestedFollow?["type"] as? String == "Follow")
        #expect(nestedFollow?["object"] as? String == "https://lemmy.ml/c/birding")
    }

    @Test("maps a non-2xx status to requestFailed")
    func mapsNon2xx() async throws {
        let fake = FakeTransport(status: 403, body: "forbidden")
        let target = try #require(URL(string: "https://lemmy.ml/c/birding"))
        await #expect(throws: CommunityMembershipError.requestFailed(status: 403, body: "forbidden")) {
            _ = try await Self.client(fake).follow(target: target)
        }
    }

    @Test("POSTs a Remove activity to this site's own outbox")
    func postsRemove() async throws {
        let fake = FakeTransport()
        let target = try #require(URL(string: "https://lemmy.ml/u/spammer"))

        try await Self.client(fake).remove(target: target)

        let body = await fake.requestedBodies.first
        #expect(body?["type"] as? String == "Remove")
        #expect(body?["object"] as? String == "https://lemmy.ml/u/spammer")
        #expect(body?["actor"] as? String == "https://example.com/users/site")
        let headers = await fake.requestedHeaders.first
        #expect(headers?["Authorization"] == "Bearer secret-token")
    }

    @Test("remove maps a non-2xx status to requestFailed")
    func removeMapsNon2xx() async throws {
        let fake = FakeTransport(status: 403, body: "forbidden")
        let target = try #require(URL(string: "https://lemmy.ml/u/spammer"))
        await #expect(throws: CommunityMembershipError.requestFailed(status: 403, body: "forbidden")) {
            try await Self.client(fake).remove(target: target)
        }
    }

    @Test("POSTs an Accept activity to this site's own outbox")
    func postsAccept() async throws {
        let fake = FakeTransport()
        let target = try #require(URL(string: "https://lemmy.ml/u/newmember"))

        try await Self.client(fake).acceptFollow(target: target)

        let body = await fake.requestedBodies.first
        #expect(body?["type"] as? String == "Accept")
        #expect(body?["object"] as? String == "https://lemmy.ml/u/newmember")
        #expect(body?["actor"] as? String == "https://example.com/users/site")
        let headers = await fake.requestedHeaders.first
        #expect(headers?["Authorization"] == "Bearer secret-token")
        #expect(await fake.requestedTimeouts.first == ActorProfileFetcher.timeout)
    }

    @Test("acceptFollow maps a non-2xx status to requestFailed")
    func acceptMapsNon2xx() async throws {
        let fake = FakeTransport(status: 403, body: "forbidden")
        let target = try #require(URL(string: "https://lemmy.ml/u/newmember"))
        await #expect(throws: CommunityMembershipError.requestFailed(status: 403, body: "forbidden")) {
            try await Self.client(fake).acceptFollow(target: target)
        }
    }

    @Test("POSTs a Reject activity to this site's own outbox, confirming target resolution")
    func postsRejectFollow() async throws {
        let fake = FakeTransport(status: 202, body: "{}")
        let target = try #require(URL(string: "https://mastodon.social/users/spammer"))

        try await Self.client(fake).rejectFollow(target: target)

        #expect(await fake.requestedURLs.first?.absoluteString == "https://example.com/users/site/outbox")
        let headers = await fake.requestedHeaders.first
        #expect(headers?["Authorization"] == "Bearer secret-token")
        let body = await fake.requestedBodies.first
        #expect(body?["type"] as? String == "Reject")
        #expect(body?["object"] as? String == "https://mastodon.social/users/spammer")
        #expect(body?["actor"] as? String == "https://example.com/users/site")
    }

    @Test("rejectFollow propagates a non-2xx as CommunityMembershipError")
    func rejectFollowFailurePropagates() async throws {
        let fake = FakeTransport(status: 403, body: "forbidden")
        let target = try #require(URL(string: "https://mastodon.social/users/spammer"))

        await #expect(throws: CommunityMembershipError.requestFailed(status: 403, body: "forbidden")) {
            try await Self.client(fake).rejectFollow(target: target)
        }
    }

    @Test("GETs pending follow requests from this site's own actor endpoint")
    func listsFollowRequests() async throws {
        let fake = FakeTransport(
            status: 200,
            body: #"{"items":[{"actor":"https://lemmy.ml/u/newmember","addedAt":"2026-08-10T18:28:14.000Z"}],"total":1}"#)

        let requests = try await Self.client(fake).listFollowRequests()

        #expect(requests.count == 1)
        #expect(requests.first?.actor.absoluteString == "https://lemmy.ml/u/newmember")
        #expect(await fake.requestedURLs.first?.absoluteString == "https://example.com/users/site/follow_requests")
        let headers = await fake.requestedHeaders.first
        #expect(headers?["Authorization"] == "Bearer secret-token")
        #expect(await fake.requestedTimeouts.first == ActorProfileFetcher.timeout)
    }

    @Test("listFollowRequests returns an empty list when there are none")
    func listsEmptyFollowRequests() async throws {
        let fake = FakeTransport(status: 200, body: #"{"items":[],"total":0}"#)
        let requests = try await Self.client(fake).listFollowRequests()
        #expect(requests.isEmpty)
    }

    @Test("listFollowRequests maps a non-2xx status to requestFailed")
    func listFollowRequestsMapsNon2xx() async throws {
        let fake = FakeTransport(status: 404, body: "Not Found")
        await #expect(throws: CommunityMembershipError.requestFailed(status: 404, body: "Not Found")) {
            _ = try await Self.client(fake).listFollowRequests()
        }
    }
}

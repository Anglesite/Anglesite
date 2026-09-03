import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("ActivityPubFollowersClient")
struct ActivityPubFollowersClientTests {
    private static func client(_ fake: FakeTransport) throws -> ActivityPubFollowersClient {
        ActivityPubFollowersClient(
            siteURL: try #require(URL(string: "https://example.com")), transport: fake.transport)
    }

    @Test("decodes an OrderedCollection head with a first page link")
    func decodesCollection() async throws {
        let fake = FakeTransport(body: """
        {"@context":"https://www.w3.org/ns/activitystreams",
         "id":"https://example.com/users/site/followers","type":"OrderedCollection",
         "totalItems":42,
         "first":"https://example.com/users/site/followers?page=1",
         "last":"https://example.com/users/site/followers?page=3"}
        """)
        let collection = try await Self.client(fake).collection()

        #expect(collection.totalItems == 42)
        #expect(collection.firstPage?.absoluteString
            == "https://example.com/users/site/followers?page=1")
        #expect(await fake.requestedURLs.first?.absoluteString
            == "https://example.com/users/site/followers")
    }

    /// Fediverse servers content-negotiate on `Accept` and will serve HTML instead of AS2 to a
    /// client that omits it, so this header is functionally load-bearing, not decorative.
    @Test("sends the AS2 Accept header on every request")
    func sendsAcceptHeader() async throws {
        let fake = FakeTransport(body: """
        {"id":"https://example.com/users/site/followers",
         "type":"OrderedCollection","totalItems":0}
        """)
        _ = try await Self.client(fake).collection()

        let headers = await fake.requestedHeaders
        #expect(headers.first?["Accept"] == ActivityPubFollowersClient.acceptHeader)
    }

    /// `@dwk/activitypub` omits `first`/`last` entirely when the collection is empty, which is
    /// how the pane detects the genuine empty state without a second request.
    @Test("decodes an empty collection as totalItems 0 with no first page")
    func decodesEmptyCollection() async throws {
        let fake = FakeTransport(body: """
        {"id":"https://example.com/users/site/followers",
         "type":"OrderedCollection","totalItems":0}
        """)
        let collection = try await Self.client(fake).collection()

        #expect(collection.totalItems == 0)
        #expect(collection.firstPage == nil)
    }

    @Test("decodes a page's actor IRIs and its next link")
    func decodesPage() async throws {
        let fake = FakeTransport(body: """
        {"id":"https://example.com/users/site/followers?page=1",
         "type":"OrderedCollectionPage","totalItems":42,
         "orderedItems":["https://mastodon.social/users/alice","https://lemmy.world/u/bob"],
         "next":"https://example.com/users/site/followers?page=2"}
        """)
        let url = try #require(URL(string: "https://example.com/users/site/followers?page=1"))
        let page = try await Self.client(fake).page(at: url)

        #expect(page.items.map(\.absoluteString)
            == ["https://mastodon.social/users/alice", "https://lemmy.world/u/bob"])
        #expect(page.next?.absoluteString == "https://example.com/users/site/followers?page=2")
    }

    @Test("decodes a final page as having no next link")
    func decodesFinalPage() async throws {
        let fake = FakeTransport(body: """
        {"id":"https://example.com/users/site/followers?page=3",
         "type":"OrderedCollectionPage","totalItems":42,
         "orderedItems":["https://mastodon.social/users/zoe"],
         "prev":"https://example.com/users/site/followers?page=2"}
        """)
        let url = try #require(URL(string: "https://example.com/users/site/followers?page=3"))
        let page = try await Self.client(fake).page(at: url)

        #expect(page.items.count == 1)
        #expect(page.next == nil)
    }

    /// 503 is what the composed Worker answers when ActivityPub isn't provisioned; the pane
    /// distinguishes it from 404 (Worker not deployed), so the status must survive.
    @Test("maps a non-2xx status to requestFailed carrying that status")
    func mapsNon2xx() async throws {
        let fake = FakeTransport(status: 503, body: "ActivityPub is not configured")
        await #expect(throws: ActivityPubFollowersError.requestFailed(
            status: 503, body: "ActivityPub is not configured")) {
            _ = try await Self.client(fake).collection()
        }
    }

    @Test("maps a malformed body to decodingFailed")
    func mapsMalformedBody() async throws {
        let fake = FakeTransport(body: "not json at all")
        let error = try await #require(throws: ActivityPubFollowersError.self) {
            _ = try await Self.client(fake).collection()
        }
        guard case .decodingFailed = error else {
            Issue.record("expected .decodingFailed, got \(error)")
            return
        }
    }

    /// A transport-level throw (DNS failure, no connectivity — no HTTP response at all) is
    /// distinct from a non-2xx response, and `fetch` re-wraps it as `status: 0` so the pane can
    /// tell "couldn't reach the Worker" apart from a Worker-returned error status.
    @Test("maps a transport throw to requestFailed with status 0")
    func mapsTransportThrow() async throws {
        struct SampleTransportError: Error {}
        let fake = FakeTransport(throwing: SampleTransportError())

        let error = try await #require(throws: ActivityPubFollowersError.self) {
            _ = try await Self.client(fake).collection()
        }
        guard case .requestFailed(let status, _) = error else {
            Issue.record("expected .requestFailed, got \(error)")
            return
        }
        #expect(status == 0)
    }

    /// The failure body becomes model state and then UI text in a non-scrolling `VStack`. An
    /// origin-served nginx/Cloudflare error page can be megabytes, so it has to be bounded here —
    /// where it's constructed and testable — rather than at the view.
    @Test("truncates an oversize error body")
    func truncatesOversizeErrorBody() async throws {
        let huge = String(
            repeating: "A", count: ActivityPubFollowersClient.maximumErrorBodyCharacters * 50)
        let fake = FakeTransport(status: 500, body: huge)

        let error = try await #require(throws: ActivityPubFollowersError.self) {
            _ = try await Self.client(fake).collection()
        }
        guard case .requestFailed(_, let body) = error else {
            Issue.record("expected .requestFailed, got \(error)")
            return
        }
        #expect(body.count == ActivityPubFollowersClient.maximumErrorBodyCharacters + 1)
        #expect(body.hasSuffix("…"))
    }

    @Test("leaves a short error body intact")
    func keepsShortErrorBody() async throws {
        let fake = FakeTransport(status: 404, body: "  not found\n")
        await #expect(throws: ActivityPubFollowersError.requestFailed(
            status: 404, body: "not found")) {
            _ = try await Self.client(fake).collection()
        }
    }

    /// The `Data` is sliced before it's decoded, so the slice can land mid-character. Decoding
    /// must repair that rather than returning `nil` and throwing the whole diagnostic away.
    @Test("survives a truncation that splits a multi-byte character")
    func survivesSplitMultiByteCharacter() async throws {
        let fake = FakeTransport(
            status: 500,
            body: String(
                repeating: "é",
                count: ActivityPubFollowersClient.maximumErrorBodyCharacters * 3))

        let error = try await #require(throws: ActivityPubFollowersError.self) {
            _ = try await Self.client(fake).collection()
        }
        guard case .requestFailed(_, let body) = error else {
            Issue.record("expected .requestFailed, got \(error)")
            return
        }
        #expect(body.hasPrefix("é"))
        #expect(body.count == ActivityPubFollowersClient.maximumErrorBodyCharacters + 1)
    }
}

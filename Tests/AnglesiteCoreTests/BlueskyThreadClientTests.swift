import Testing
import Foundation
@testable import AnglesiteCore

@Suite("BlueskyThreadClient")
struct BlueskyThreadClientTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://public.api.bsky.app/")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static func post(
        uri: String = "at://alice.bsky.social/app.bsky.feed.post/3abc",
        handle: String = "alice.bsky.social", displayName: String? = "Alice", avatar: String? = "https://cdn.example/alice.jpg",
        text: String = "great post!", createdAt: String = "2026-08-01T10:00:00.000Z",
        labels: [[String: Any]]? = nil, selfLabels: [String]? = nil
    ) -> [String: Any] {
        var record: [String: Any] = ["text": text, "createdAt": createdAt]
        if let selfLabels {
            record["labels"] = ["$type": "com.atproto.label.defs#selfLabels", "values": selfLabels.map { ["val": $0] }]
        }
        var author: [String: Any] = ["did": "did:plc:alice", "handle": handle]
        if let displayName { author["displayName"] = displayName }
        if let avatar { author["avatar"] = avatar }
        var dict: [String: Any] = ["uri": uri, "author": author, "record": record]
        if let labels { dict["labels"] = labels }
        return dict
    }

    private static func threadNode(post: [String: Any], replies: [[String: Any]] = []) -> [String: Any] {
        ["$type": "app.bsky.feed.defs#threadViewPost", "post": post, "replies": replies]
    }

    // MARK: - flattenReplies

    @Test("flattenReplies collects a single reply with no children")
    func flattenSingleReply() {
        var results: [BlueskyThreadClient.RawReply] = []
        BlueskyThreadClient.flattenReplies(Self.threadNode(post: Self.post()), into: &results)
        #expect(results.count == 1)
        #expect(results[0].rkey == "3abc")
        #expect(results[0].authorHandle == "alice.bsky.social")
        #expect(results[0].authorName == "Alice")
        #expect(results[0].text == "great post!")
    }

    @Test("flattenReplies walks nested replies-to-replies depth-first")
    func flattenNestedReplies() {
        let grandchild = Self.threadNode(post: Self.post(uri: "at://carol.bsky.social/app.bsky.feed.post/3ggg", handle: "carol.bsky.social"))
        let child = Self.threadNode(
            post: Self.post(uri: "at://bob.bsky.social/app.bsky.feed.post/3bbb", handle: "bob.bsky.social"),
            replies: [grandchild])
        var results: [BlueskyThreadClient.RawReply] = []
        BlueskyThreadClient.flattenReplies(Self.threadNode(post: Self.post(), replies: [child]), into: &results)
        #expect(results.map(\.rkey) == ["3abc", "3bbb", "3ggg"])
    }

    @Test("flattenReplies skips a blockedPost branch")
    func flattenSkipsBlockedPost() {
        let blocked: [String: Any] = ["$type": "app.bsky.feed.defs#blockedPost", "uri": "at://evil.example/app.bsky.feed.post/3xxx"]
        var results: [BlueskyThreadClient.RawReply] = []
        BlueskyThreadClient.flattenReplies(Self.threadNode(post: Self.post(), replies: [blocked]), into: &results)
        #expect(results.count == 1)
    }

    @Test("flattenReplies skips a notFoundPost branch")
    func flattenSkipsNotFoundPost() {
        let notFound: [String: Any] = ["$type": "app.bsky.feed.defs#notFoundPost", "uri": "at://gone.example/app.bsky.feed.post/3xxx"]
        var results: [BlueskyThreadClient.RawReply] = []
        BlueskyThreadClient.flattenReplies(Self.threadNode(post: Self.post(), replies: [notFound]), into: &results)
        #expect(results.count == 1)
    }

    @Test("flattenReplies excludes an AppView-labeled adult-content reply but still walks its own children")
    func flattenExcludesAppViewLabeledPost() {
        let labeledPost = Self.post(
            uri: "at://bob.bsky.social/app.bsky.feed.post/3bbb", handle: "bob.bsky.social",
            labels: [["val": "porn", "src": "did:plc:labeler"]])
        let child = Self.threadNode(post: Self.post(uri: "at://carol.bsky.social/app.bsky.feed.post/3ggg", handle: "carol.bsky.social"))
        var results: [BlueskyThreadClient.RawReply] = []
        BlueskyThreadClient.flattenReplies(
            Self.threadNode(post: Self.post(), replies: [Self.threadNode(post: labeledPost, replies: [child])]),
            into: &results)
        #expect(results.map(\.rkey) == ["3abc", "3ggg"])
    }

    @Test("flattenReplies excludes a self-labeled adult-content reply")
    func flattenExcludesSelfLabeledPost() {
        let labeledPost = Self.post(
            uri: "at://bob.bsky.social/app.bsky.feed.post/3bbb", handle: "bob.bsky.social", selfLabels: ["sexual"])
        var results: [BlueskyThreadClient.RawReply] = []
        BlueskyThreadClient.flattenReplies(Self.threadNode(post: Self.post(), replies: [Self.threadNode(post: labeledPost)]), into: &results)
        #expect(results.map(\.rkey) == ["3abc"])
    }

    @Test("flattenReplies skips a reply missing a required field rather than crashing")
    func flattenSkipsMalformedPost() {
        let malformed: [String: Any] = ["uri": "at://bob.bsky.social/app.bsky.feed.post/3bbb"]
        var results: [BlueskyThreadClient.RawReply] = []
        BlueskyThreadClient.flattenReplies(Self.threadNode(post: Self.post(), replies: [Self.threadNode(post: malformed)]), into: &results)
        #expect(results.map(\.rkey) == ["3abc"])
    }

    // MARK: - fetchReplies

    @Test("fetchReplies parses a getPostThread response into flattened replies")
    func fetchRepliesHappyPath() async throws {
        let body = Data("""
        {"thread": {"$type": "app.bsky.feed.defs#threadViewPost",
          "post": {"uri": "at://root.example/app.bsky.feed.post/3root", "author": {"did": "did:plc:root", "handle": "root.example"},
                    "record": {"text": "the original post", "createdAt": "2026-08-01T09:00:00.000Z"}},
          "replies": [{"$type": "app.bsky.feed.defs#threadViewPost",
            "post": {"uri": "at://alice.bsky.social/app.bsky.feed.post/3abc",
                      "author": {"did": "did:plc:alice", "handle": "alice.bsky.social", "displayName": "Alice"},
                      "record": {"text": "great post!", "createdAt": "2026-08-01T10:00:00.000Z"}},
            "replies": []}]}}
        """.utf8)
        let replies = await BlueskyThreadClient.fetchReplies(
            atURI: "at://root.example/app.bsky.feed.post/3root", transport: { _ in (body, Self.response(200)) })
        let unwrapped = try #require(replies)
        #expect(unwrapped.count == 1)
        #expect(unwrapped[0].rkey == "3abc")
    }

    @Test("fetchReplies returns an empty (not nil) list when the root post is gone")
    func fetchRepliesRootNotFound() async throws {
        let body = Data("""
        {"thread": {"$type": "app.bsky.feed.defs#notFoundPost", "uri": "at://root.example/app.bsky.feed.post/3root"}}
        """.utf8)
        let replies = await BlueskyThreadClient.fetchReplies(
            atURI: "at://root.example/app.bsky.feed.post/3root", transport: { _ in (body, Self.response(200)) })
        #expect(replies == [])
    }

    @Test("fetchReplies returns nil (hard failure) on a non-2xx response")
    func fetchRepliesHardFailure() async throws {
        let replies = await BlueskyThreadClient.fetchReplies(
            atURI: "at://root.example/app.bsky.feed.post/3root", transport: { _ in (Data(), Self.response(500)) })
        #expect(replies == nil)
    }

    // MARK: - fetchLikes / fetchReposts

    @Test("fetchLikes parses a getLikes response including each like's createdAt")
    func fetchLikesHappyPath() async throws {
        let body = Data("""
        {"uri": "at://root.example/app.bsky.feed.post/3root", "likes": [
          {"createdAt": "2026-08-01T11:00:00.000Z", "indexedAt": "2026-08-01T11:00:01.000Z",
           "actor": {"did": "did:plc:dave", "handle": "dave.bsky.social", "displayName": "Dave"}}
        ]}
        """.utf8)
        let likes = await BlueskyThreadClient.fetchLikes(
            atURI: "at://root.example/app.bsky.feed.post/3root", transport: { _ in (body, Self.response(200)) })
        let unwrapped = try #require(likes)
        #expect(unwrapped.count == 1)
        #expect(unwrapped[0].actorHandle == "dave.bsky.social")
        #expect(unwrapped[0].createdAt != nil)
    }

    @Test("fetchReposts parses a getRepostedBy response whose items are bare actor profiles with no createdAt")
    func fetchRepostsHappyPath() async throws {
        let body = Data("""
        {"uri": "at://root.example/app.bsky.feed.post/3root", "repostedBy": [
          {"did": "did:plc:erin", "handle": "erin.bsky.social", "displayName": "Erin"}
        ]}
        """.utf8)
        let reposts = await BlueskyThreadClient.fetchReposts(
            atURI: "at://root.example/app.bsky.feed.post/3root", transport: { _ in (body, Self.response(200)) })
        let unwrapped = try #require(reposts)
        #expect(unwrapped.count == 1)
        #expect(unwrapped[0].actorHandle == "erin.bsky.social")
        #expect(unwrapped[0].createdAt == nil)
    }

    @Test("fetchLikes follows cursor across multiple pages")
    func fetchLikesPaginates() async throws {
        let page1 = Data("""
        {"uri": "x", "cursor": "page2", "likes": [{"createdAt": "2026-08-01T11:00:00.000Z", "actor": {"did": "did:plc:1", "handle": "one.bsky.social"}}]}
        """.utf8)
        let page2 = Data("""
        {"uri": "x", "likes": [{"createdAt": "2026-08-01T12:00:00.000Z", "actor": {"did": "did:plc:2", "handle": "two.bsky.social"}}]}
        """.utf8)
        let likes = await BlueskyThreadClient.fetchLikes(atURI: "at://root.example/app.bsky.feed.post/3root", transport: { request in
            let sawCursor = request.url?.query?.contains("cursor=page2") ?? false
            return (sawCursor ? page2 : page1, Self.response(200))
        })
        let unwrapped = try #require(likes)
        #expect(unwrapped.map(\.actorHandle) == ["one.bsky.social", "two.bsky.social"])
    }

    @Test("fetchLikes stops paginating at the page cap rather than trusting an endless cursor chain")
    func fetchLikesStopsAtPageCap() async throws {
        let requestCount = Counter()
        let likes = await BlueskyThreadClient.fetchLikes(atURI: "at://root.example/app.bsky.feed.post/3root", transport: { _ in
            let n = await requestCount.increment()
            let body = Data("""
            {"uri": "x", "cursor": "more", "likes": [{"createdAt": "2026-08-01T11:00:00.000Z", "actor": {"did": "did:plc:\(n)", "handle": "user\(n).bsky.social"}}]}
            """.utf8)
            return (body, Self.response(200))
        })
        let unwrapped = try #require(likes)
        #expect(await requestCount.value == BlueskyThreadClient.maximumPages)
        #expect(unwrapped.count == BlueskyThreadClient.maximumPages)
    }

    @Test("fetchLikes returns nil when the first page hard-fails")
    func fetchLikesFirstPageFailureIsNil() async throws {
        let likes = await BlueskyThreadClient.fetchLikes(
            atURI: "at://root.example/app.bsky.feed.post/3root", transport: { _ in (Data(), Self.response(500)) })
        #expect(likes == nil)
    }

    @Test("fetchLikes returns pages already gathered when a later page fails, rather than discarding them")
    func fetchLikesLaterPageFailureReturnsPartial() async throws {
        let requestCount = Counter()
        let likes = await BlueskyThreadClient.fetchLikes(atURI: "at://root.example/app.bsky.feed.post/3root", transport: { _ in
            let n = await requestCount.increment()
            if n == 1 {
                let body = Data("""
                {"uri": "x", "cursor": "page2", "likes": [{"createdAt": "2026-08-01T11:00:00.000Z", "actor": {"did": "did:plc:1", "handle": "one.bsky.social"}}]}
                """.utf8)
                return (body, Self.response(200))
            }
            return (Data(), Self.response(500))
        })
        let unwrapped = try #require(likes)
        #expect(unwrapped.map(\.actorHandle) == ["one.bsky.social"])
    }
}

private actor Counter {
    private(set) var value = 0
    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}

import Testing
import Foundation
@testable import AnglesiteCore

@Suite(.serialized)
struct BlueskyBackfeedSyncTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://public.api.bsky.app/")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static func emptyThreadBody(rkey: String) -> Data {
        Data("""
        {"thread": {"$type": "app.bsky.feed.defs#threadViewPost",
          "post": {"uri": "at://me.example/app.bsky.feed.post/\(rkey)", "author": {"did": "did:plc:me", "handle": "me.example"},
                    "record": {"text": "my post", "createdAt": "2026-08-01T09:00:00.000Z"}}, "replies": []}}
        """.utf8)
    }
    private static func emptyLikesBody() -> Data { Data(#"{"uri": "x", "likes": []}"#.utf8) }
    private static func emptyRepostsBody() -> Data { Data(#"{"uri": "x", "repostedBy": []}"#.utf8) }

    // MARK: - atURI

    @Test("atURI derives the at:// URI and rkey from a bsky.app permalink")
    func atURIParses() throws {
        let parsed = try #require(BlueskyBackfeedSync.atURI(from: URL(string: "https://bsky.app/profile/alice.bsky.social/post/3abc")!))
        #expect(parsed.uri == "at://alice.bsky.social/app.bsky.feed.post/3abc")
        #expect(parsed.rkey == "3abc")
    }

    @Test("atURI returns nil for a URL that isn't a bsky.app post permalink")
    func atURIRejectsUnrecognizedURL() {
        #expect(BlueskyBackfeedSync.atURI(from: URL(string: "https://example.com/other")!) == nil)
    }

    // MARK: - pullAndCommit

    @Test("pullAndCommit no-ops when the ledger has no bluesky entries")
    func noOpsWithoutBlueskyEntries() async {
        let ledger = POSSESyndicationLog(entries: [.init(
            sourceFile: "src/content/blog/hi.md", canonicalURL: URL(string: "https://me.example/blog/hi")!,
            platform: "mastodon", syndicationURL: URL(string: "https://mastodon.example/@me/1")!, postedAt: Date())])
        let count = await BlueskyBackfeedSync.pullAndCommit(
            ledger: ledger, siteDirectory: URL(fileURLWithPath: "/nonexistent"),
            transport: { _ in
                Issue.record("transport must not be called with no bluesky entries")
                struct Unexpected: Error {}
                throw Unexpected()
            })
        #expect(count == 0)
    }

    @Test("pullAndCommit fetches replies/likes/reposts for a tracked post and commits them")
    func happyPath() async throws {
        let siteDirectory = try Self.makeThrowawayGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }

        let ledger = POSSESyndicationLog(entries: [.init(
            sourceFile: "src/content/blog/hi.md", canonicalURL: URL(string: "https://me.example/blog/hi")!,
            platform: "bluesky", syndicationURL: URL(string: "https://bsky.app/profile/me.example/post/3root")!, postedAt: Date())])

        let threadBody = Data("""
        {"thread": {"$type": "app.bsky.feed.defs#threadViewPost",
          "post": {"uri": "at://me.example/app.bsky.feed.post/3root", "author": {"did": "did:plc:me", "handle": "me.example"},
                    "record": {"text": "my post", "createdAt": "2026-08-01T09:00:00.000Z"}},
          "replies": [{"$type": "app.bsky.feed.defs#threadViewPost",
            "post": {"uri": "at://alice.bsky.social/app.bsky.feed.post/3abc",
                      "author": {"did": "did:plc:alice", "handle": "alice.bsky.social", "displayName": "Alice"},
                      "record": {"text": "great post!", "createdAt": "2026-08-01T10:00:00.000Z"}}, "replies": []}]}}
        """.utf8)
        let likesBody = Data("""
        {"uri": "x", "likes": [{"createdAt": "2026-08-01T11:00:00.000Z", "actor": {"did": "did:plc:dave", "handle": "dave.bsky.social"}}]}
        """.utf8)

        let count = await BlueskyBackfeedSync.pullAndCommit(ledger: ledger, siteDirectory: siteDirectory, transport: { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("getPostThread") { return (threadBody, Self.response(200)) }
            if path.hasSuffix("getLikes") { return (likesBody, Self.response(200)) }
            if path.hasSuffix("getRepostedBy") { return (Self.emptyRepostsBody(), Self.response(200)) }
            return (Data(), Self.response(404))
        })
        #expect(count == 2)
        #expect(FileManager.default.fileExists(atPath: siteDirectory.appendingPathComponent("data/interactions/bsky-3abc.json").path))
        let likeFiles = try FileManager.default.contentsOfDirectory(atPath: siteDirectory.appendingPathComponent("data/interactions").path)
            .filter { $0.hasPrefix("bsky-like-") }
        #expect(likeFiles.count == 1)
    }

    @Test("pullAndCommit skips the whole commit when one tracked post's fetch hard-fails, leaving prior snapshots untouched")
    func hardFailureSkipsCommit() async throws {
        let siteDirectory = try Self.makeThrowawayGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }

        let existing = try ReceivedInteraction(
            id: "bsky-existing", type: .bluesky,
            source: URL(string: "https://bsky.app/profile/alice.bsky.social/post/existing")!,
            target: URL(string: "https://me.example/blog/hi")!, interactionType: .reply,
            author: nil, content: "hi", published: Date(), verified: Date(), verificationStatus: .verified)
        _ = await ReceivedInteractionCommitter.commit(interactions: [existing], scopedTo: [.bluesky], into: siteDirectory)

        let ledger = POSSESyndicationLog(entries: [.init(
            sourceFile: "src/content/blog/hi.md", canonicalURL: URL(string: "https://me.example/blog/hi")!,
            platform: "bluesky", syndicationURL: URL(string: "https://bsky.app/profile/me.example/post/3root")!, postedAt: Date())])

        let count = await BlueskyBackfeedSync.pullAndCommit(ledger: ledger, siteDirectory: siteDirectory, transport: { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("getPostThread") { return (Self.emptyThreadBody(rkey: "3root"), Self.response(200)) }
            if path.hasSuffix("getLikes") { return (Data(), Self.response(500)) }
            if path.hasSuffix("getRepostedBy") { return (Self.emptyRepostsBody(), Self.response(200)) }
            return (Data(), Self.response(404))
        })
        #expect(count == 0)
        #expect(FileManager.default.fileExists(atPath: siteDirectory.appendingPathComponent("data/interactions/bsky-existing.json").path))
    }

    @Test("pullAndCommit's bluesky-scoped reconcile leaves an existing webmention-sourced snapshot untouched")
    func doesNotDeleteWebmentionFiles() async throws {
        let siteDirectory = try Self.makeThrowawayGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }

        let webmentionInteraction = try ReceivedInteraction(
            id: "wm-abc123", type: .webmention,
            source: URL(string: "https://alice.example/post")!, target: URL(string: "https://me.example/blog/hi")!,
            interactionType: .reply, author: nil, content: "hi", published: Date(), verified: Date(), verificationStatus: .verified)
        _ = await ReceivedInteractionCommitter.commit(interactions: [webmentionInteraction], scopedTo: [.webmention], into: siteDirectory)

        let ledger = POSSESyndicationLog(entries: [.init(
            sourceFile: "src/content/blog/hi.md", canonicalURL: URL(string: "https://me.example/blog/hi")!,
            platform: "bluesky", syndicationURL: URL(string: "https://bsky.app/profile/me.example/post/3root")!, postedAt: Date())])

        _ = await BlueskyBackfeedSync.pullAndCommit(ledger: ledger, siteDirectory: siteDirectory, transport: { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("getPostThread") { return (Self.emptyThreadBody(rkey: "3root"), Self.response(200)) }
            if path.hasSuffix("getLikes") { return (Self.emptyLikesBody(), Self.response(200)) }
            if path.hasSuffix("getRepostedBy") { return (Self.emptyRepostsBody(), Self.response(200)) }
            return (Data(), Self.response(404))
        })
        #expect(FileManager.default.fileExists(atPath: siteDirectory.appendingPathComponent("data/interactions/wm-abc123.json").path))
    }

    @Test("pullAndCommit still commits a different post's fresh replies when one tracked post's fetch hard-fails")
    func partialFailureStillCommitsOtherPosts() async throws {
        let siteDirectory = try Self.makeThrowawayGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }

        let ledger = POSSESyndicationLog(entries: [
            .init(sourceFile: "src/content/blog/broken.md", canonicalURL: URL(string: "https://me.example/blog/broken")!,
                  platform: "bluesky", syndicationURL: URL(string: "https://bsky.app/profile/me.example/post/3broken")!, postedAt: Date()),
            .init(sourceFile: "src/content/blog/ok.md", canonicalURL: URL(string: "https://me.example/blog/ok")!,
                  platform: "bluesky", syndicationURL: URL(string: "https://bsky.app/profile/me.example/post/3ok")!, postedAt: Date()),
        ])

        let okThreadBody = Data("""
        {"thread": {"$type": "app.bsky.feed.defs#threadViewPost",
          "post": {"uri": "at://me.example/app.bsky.feed.post/3ok", "author": {"did": "did:plc:me", "handle": "me.example"},
                    "record": {"text": "my other post", "createdAt": "2026-08-01T09:00:00.000Z"}},
          "replies": [{"$type": "app.bsky.feed.defs#threadViewPost",
            "post": {"uri": "at://bob.bsky.social/app.bsky.feed.post/3bbb",
                      "author": {"did": "did:plc:bob", "handle": "bob.bsky.social"},
                      "record": {"text": "nice!", "createdAt": "2026-08-01T10:00:00.000Z"}}, "replies": []}]}}
        """.utf8)

        let count = await BlueskyBackfeedSync.pullAndCommit(ledger: ledger, siteDirectory: siteDirectory, transport: { request in
            let query = request.url?.query ?? ""
            let path = request.url?.path ?? ""
            if query.contains("3broken") { return (Data(), Self.response(500)) }
            if path.hasSuffix("getPostThread") { return (okThreadBody, Self.response(200)) }
            if path.hasSuffix("getLikes") { return (Self.emptyLikesBody(), Self.response(200)) }
            if path.hasSuffix("getRepostedBy") { return (Self.emptyRepostsBody(), Self.response(200)) }
            return (Data(), Self.response(404))
        })
        #expect(count == 1)
        #expect(FileManager.default.fileExists(atPath: siteDirectory.appendingPathComponent("data/interactions/bsky-3bbb.json").path))
    }

    @Test("pullAndCommit is a true no-op on a second call with unchanged upstream data, even as verified/published sync time advances")
    func secondSyncWithUnchangedDataIsNoOp() async throws {
        let siteDirectory = try Self.makeThrowawayGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }

        let ledger = POSSESyndicationLog(entries: [.init(
            sourceFile: "src/content/blog/hi.md", canonicalURL: URL(string: "https://me.example/blog/hi")!,
            platform: "bluesky", syndicationURL: URL(string: "https://bsky.app/profile/me.example/post/3root")!, postedAt: Date())])

        let threadBody = Data("""
        {"thread": {"$type": "app.bsky.feed.defs#threadViewPost",
          "post": {"uri": "at://me.example/app.bsky.feed.post/3root", "author": {"did": "did:plc:me", "handle": "me.example"},
                    "record": {"text": "my post", "createdAt": "2026-08-01T09:00:00.000Z"}},
          "replies": [{"$type": "app.bsky.feed.defs#threadViewPost",
            "post": {"uri": "at://alice.bsky.social/app.bsky.feed.post/3abc",
                      "author": {"did": "did:plc:alice", "handle": "alice.bsky.social", "displayName": "Alice"},
                      "record": {"text": "great post!", "createdAt": "2026-08-01T10:00:00.000Z"}}, "replies": []}]}}
        """.utf8)
        // A repost has no per-item createdAt, so `published` is stamped from `now` too — this
        // exercises both halves of finding 1's fix (verified always stamped from `now`, and
        // published additionally stamped from `now` for reposts).
        let repostsBody = Data(#"{"uri": "x", "repostedBy": [{"did": "did:plc:erin", "handle": "erin.bsky.social"}]}"#.utf8)

        let transport: BlueskyThreadClient.Transport = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("getPostThread") { return (threadBody, Self.response(200)) }
            if path.hasSuffix("getLikes") { return (Self.emptyLikesBody(), Self.response(200)) }
            if path.hasSuffix("getRepostedBy") { return (repostsBody, Self.response(200)) }
            return (Data(), Self.response(404))
        }

        let firstCount = await BlueskyBackfeedSync.pullAndCommit(
            ledger: ledger, siteDirectory: siteDirectory, transport: transport, now: Date(timeIntervalSince1970: 1_000_000))
        #expect(firstCount == 2)

        let replyFile = siteDirectory.appendingPathComponent("data/interactions/bsky-3abc.json")
        let repostFiles = try FileManager.default.contentsOfDirectory(atPath: siteDirectory.appendingPathComponent("data/interactions").path)
            .filter { $0.hasPrefix("bsky-repost-") }
        #expect(repostFiles.count == 1)
        let repostFile = siteDirectory.appendingPathComponent("data/interactions/\(repostFiles[0])")
        let replyBytesBeforeSecondSync = try Data(contentsOf: replyFile)
        let repostBytesBeforeSecondSync = try Data(contentsOf: repostFile)

        let secondCount = await BlueskyBackfeedSync.pullAndCommit(
            ledger: ledger, siteDirectory: siteDirectory, transport: transport, now: Date(timeIntervalSince1970: 2_000_000))
        #expect(secondCount == 0)
        #expect(try Data(contentsOf: replyFile) == replyBytesBeforeSecondSync)
        #expect(try Data(contentsOf: repostFile) == repostBytesBeforeSecondSync)
    }

    // MARK: - makeInteraction URL guards

    @Test("makeInteraction(from reply:) skips the reply rather than crashing when urlBuilder can't produce a URL")
    func makeInteractionSkipsReplyWithUnbuildableURL() {
        let reply = BlueskyThreadClient.RawReply(
            rkey: "3abc", authorHandle: "alice.bsky.social", authorName: "Alice", authorPhoto: nil,
            text: "hi", createdAt: Date())
        let interaction = BlueskyBackfeedSync.makeInteraction(
            from: reply, target: URL(string: "https://me.example/blog/hi")!, now: Date(),
            urlBuilder: { _ in nil })
        #expect(interaction == nil)
    }

    @Test("makeInteraction(from event:) skips the like/repost rather than crashing when urlBuilder can't produce a URL")
    func makeInteractionSkipsEventWithUnbuildableURL() {
        let event = BlueskyThreadClient.RawActorEvent(
            actorDID: "did:plc:dave", actorHandle: "dave.bsky.social", actorName: "Dave", actorPhoto: nil, createdAt: nil)
        let interaction = BlueskyBackfeedSync.makeInteraction(
            from: event, interactionType: .like, targetRkey: "3root", target: URL(string: "https://me.example/blog/hi")!,
            now: Date(), urlBuilder: { _ in nil })
        #expect(interaction == nil)
    }

    // MARK: - pullAndCommitIfConfigured

    @Test("pullAndCommitIfConfigured no-ops when there is no ledger file")
    func noOpsWithoutLedger() async {
        let fm = FileManager.default
        let configDir = fm.temporaryDirectory.appendingPathComponent("bluesky-backfeed-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: configDir) }

        let count = await BlueskyBackfeedSync.pullAndCommitIfConfigured(
            siteDirectory: URL(fileURLWithPath: "/nonexistent"), configDirectory: configDir,
            transport: { _ in
                Issue.record("transport must not be called with no ledger")
                struct Unexpected: Error {}
                throw Unexpected()
            })
        #expect(count == 0)
    }

    private static func makeThrowawayGitRepo() throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("bluesky-backfeed-repo-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "placeholder\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = dir
            p.environment = ProcessInfo.processInfo.environment.merging([
                "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@anglesite.test",
                "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@anglesite.test",
            ]) { _, new in new }
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                struct GitFailed: Error {}
                throw GitFailed()
            }
        }
        try git(["init", "-q"])
        try git(["config", "user.email", "test@anglesite.test"])
        try git(["config", "user.name", "test"])
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "initial"])
        return dir
    }
}

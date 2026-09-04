# Bluesky Replies as the Site's Comment Section Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pull the replies, likes, and reposts a POSSE'd Bluesky post receives back into the site's own `data/interactions/` git-canonical snapshot, so they render in the existing comment/facepile UI with zero render-side changes.

**Architecture:** A new unauthenticated AT-proto reader (`BlueskyThreadClient`) fetches `getPostThread`/`getLikes`/`getRepostedBy` from Bluesky's public AppView for every post the local POSSE ledger (`POSSESyndicationLog`) already knows was cross-posted. A new orchestrator (`BlueskyBackfeedSync`), mirroring the existing `ReceivedInteractionSync`/`AnnouncedPostSync` "pull on site-open" shape, maps the results into the existing `ReceivedInteraction` schema and commits them via `ReceivedInteractionCommitter`, which gains a `scopedTo` parameter so this new writer can share `data/interactions/` with the existing webmention/ActivityPub writer without either deleting the other's files.

**Tech Stack:** Swift 6.4 (`AnglesiteCore`, portable SwiftPM target — no Darwin-only APIs), Swift Testing (`@Suite`/`@Test`), TypeScript + `node:test` (Astro template `src/lib`).

**Full design:** [`docs/superpowers/specs/2026-08-17-bluesky-replies-comment-section-design.md`](../specs/2026-08-17-bluesky-replies-comment-section-design.md)

## Global Constraints

- Swift/SwiftUI + Apple frameworks only, no new third-party dependencies (`CONTRIBUTING.md` ▸ "Code guidelines"). This plan adds no dependency.
- `AnglesiteCore` is a portable SwiftPM target (Linux + Darwin) — no `CryptoKit`/Darwin-only APIs without a `#if canImport` fallback. This plan uses only `Foundation`/`FoundationNetworking`.
- Run `swift test --package-path .` and, from `JS/edit-overlay/`-adjacent template code, `npx tsx --test` before opening the PR (`CONTRIBUTING.md` ▸ "Testing"; template lib tests use `node:test`, not vitest, per existing convention in `Resources/Template/src/lib/interactions.test.ts`).
- Conventional commits, subject ≤72 characters, reference `#1236` (`CONTRIBUTING.md` ▸ "Commits and pull requests").
- This is app-only — no MCP schema change, so no paired `anglesite-skills` PR.
- Issue `#1236` is already claimed (`🛠️ In Progress` label set).

---

### Task 1: `ReceivedInteraction.ProtocolType` and the template zod schema gain `bluesky`

**Files:**
- Modify: `Sources/AnglesiteCore/ReceivedInteraction.swift:16-23`
- Modify: `Resources/Template/src/lib/interactions.ts` (the `interactionSchema`'s `type` field)
- Test: `Tests/AnglesiteCoreTests/ReceivedInteractionTests.swift`
- Test: `Resources/Template/src/lib/interactions.test.ts`

**Interfaces:**
- Produces: `ReceivedInteraction.ProtocolType.bluesky` — every later Swift task constructs `ReceivedInteraction`s with `type: .bluesky`.
- Produces: the template's `ReceivedInteraction["type"]` zod type now includes `"bluesky"` — without this, every Bluesky-sourced snapshot file fails validation and is silently dropped with a console warning (`parseInteractions`'s existing behavior for any unrecognized `type`).

- [ ] **Step 1: Write the failing Swift test**

Add to `Tests/AnglesiteCoreTests/ReceivedInteractionTests.swift` (after the existing `jsonRoundTrip` test):

```swift
    @Test("bluesky is a valid protocol type and round-trips through JSON")
    func blueskyProtocolTypeRoundTrips() throws {
        let interaction = try ReceivedInteraction(
            id: "bsky-abc123",
            type: .bluesky,
            source: URL(string: "https://bsky.app/profile/alice.bsky.social/post/abc123")!,
            target: URL(string: "https://my.site/articles/hello-world")!,
            interactionType: .reply,
            author: nil,
            content: "hello",
            published: Date(),
            verified: Date(),
            verificationStatus: .verified
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(interaction)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReceivedInteraction.self, from: data)
        #expect(decoded.type == .bluesky)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --filter ReceivedInteractionTests`
Expected: FAIL to compile — `type 'ReceivedInteraction.ProtocolType' has no member 'bluesky'`.

- [ ] **Step 3: Add the `.bluesky` case**

In `Sources/AnglesiteCore/ReceivedInteraction.swift`, change:

```swift
    public enum ProtocolType: String, Codable, Sendable, Equatable {
        /// Delivered to the site's Webmention endpoint (IndieWeb).
        case webmention
        /// Delivered via ActivityPub (fediverse) federation.
        case activitypub
        /// Created through the site's Micropub endpoint.
        case micropub
    }
```

to:

```swift
    public enum ProtocolType: String, Codable, Sendable, Equatable {
        /// Delivered to the site's Webmention endpoint (IndieWeb).
        case webmention
        /// Delivered via ActivityPub (fediverse) federation.
        case activitypub
        /// Created through the site's Micropub endpoint.
        case micropub
        /// Pulled from Bluesky's public AppView — a reply, like, or repost on the owner's POSSE'd
        /// copy of this post (#1236), not delivered to any endpoint of ours.
        case bluesky
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path . --filter ReceivedInteractionTests`
Expected: PASS

- [ ] **Step 5: Write the failing template test**

Add to `Resources/Template/src/lib/interactions.test.ts` (after the `"author and content are optional"` test):

```ts
test("accepts type: bluesky", () => {
  const all = parseInteractions(mods(raw({ id: "bsky-abc123", type: "bluesky" })));
  assert.equal(all.length, 1);
  assert.equal(all[0].type, "bluesky");
});
```

- [ ] **Step 6: Run the template test to verify it fails**

Run (from `Resources/Template/`): `npx tsx --test src/lib/interactions.test.ts`
Expected: FAIL — the new case's `raw({ type: "bluesky" })` fails `z.enum(["webmention", "activitypub", "micropub"])`, so `parseInteractions` returns `0` results, not `1`.

- [ ] **Step 7: Widen the zod schema**

In `Resources/Template/src/lib/interactions.ts`, change:

```ts
  type: z.enum(["webmention", "activitypub", "micropub"]),
```

to:

```ts
  type: z.enum(["webmention", "activitypub", "micropub", "bluesky"]),
```

- [ ] **Step 8: Run the template test to verify it passes**

Run (from `Resources/Template/`): `npx tsx --test src/lib/interactions.test.ts`
Expected: PASS (all tests in the file, not just the new one — this file has no other pending changes yet).

- [ ] **Step 9: Commit**

```bash
git add Sources/AnglesiteCore/ReceivedInteraction.swift Tests/AnglesiteCoreTests/ReceivedInteractionTests.swift \
  Resources/Template/src/lib/interactions.ts Resources/Template/src/lib/interactions.test.ts
git commit -m "feat(#1236): add bluesky received-interaction protocol type"
```

---

### Task 2: `ReceivedInteractionCommitter.commit` gains `scopedTo` for multi-source reconciliation

**Files:**
- Modify: `Sources/AnglesiteCore/ReceivedInteractionCommitter.swift`
- Test: `Tests/AnglesiteCoreTests/ReceivedInteractionCommitterTests.swift`

**Interfaces:**
- Consumes: `ReceivedInteraction.ProtocolType` (Task 1).
- Produces: `ReceivedInteractionCommitter.commit(interactions:scopedTo:into:fileManager:gitCommitBatch:) async -> [String]` — `scopedTo` is `Set<ReceivedInteraction.ProtocolType>?`, defaulting to `nil` (today's whole-directory behavior, unchanged for every existing caller). Task 3 and Task 6 are the two callers that pass an explicit scope.

- [ ] **Step 1: Write the failing test**

In `Tests/AnglesiteCoreTests/ReceivedInteractionCommitterTests.swift`, change the existing `interaction` helper to accept a `type`, defaulting to `.webmention` so every existing call site is unaffected:

```swift
    private static func interaction(
        id: String, type: ReceivedInteraction.ProtocolType = .webmention, content: String = "Great post!"
    ) -> ReceivedInteraction {
        try! ReceivedInteraction(
            id: id, type: type,
            source: URL(string: "https://alice.example/post")!,
            target: URL(string: "https://me.example/blog/hi")!,
            interactionType: .reply,
            author: .init(name: "Alice", url: URL(string: "https://alice.example"), photo: nil),
            content: content,
            published: Date(timeIntervalSince1970: 1_753_299_000),
            verified: Date(timeIntervalSince1970: 1_753_300_000),
            verificationStatus: .verified)
    }
```

Then add a new test (after `commitDeletesStaleFiles`):

```swift
    @Test("commit with scopedTo only reconciles staleness within its own scope, leaving other sources' files untouched")
    func commitScopedToLeavesOtherSourcesAlone() async throws {
        let siteDirectory = try Self.makeThrowawayGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }

        _ = await ReceivedInteractionCommitter.commit(
            interactions: [Self.interaction(id: "wm-abc123", type: .webmention)], into: siteDirectory)
        _ = await ReceivedInteractionCommitter.commit(
            interactions: [Self.interaction(id: "bsky-def456", type: .bluesky)],
            scopedTo: [.bluesky], into: siteDirectory)

        let webmentionFile = siteDirectory.appendingPathComponent("data/interactions/wm-abc123.json")
        let blueskyFile = siteDirectory.appendingPathComponent("data/interactions/bsky-def456.json")
        #expect(FileManager.default.fileExists(atPath: webmentionFile.path))
        #expect(FileManager.default.fileExists(atPath: blueskyFile.path))

        // A bluesky-scoped reconcile with zero current bluesky interactions deletes bsky-def456
        // (stale within its own scope) but must leave wm-abc123 alone (out of scope entirely).
        let ids = await ReceivedInteractionCommitter.commit(
            interactions: [], scopedTo: [.bluesky], into: siteDirectory)
        #expect(ids == ["bsky-def456"])
        #expect(FileManager.default.fileExists(atPath: webmentionFile.path))
        #expect(!FileManager.default.fileExists(atPath: blueskyFile.path))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --filter ReceivedInteractionCommitterTests`
Expected: FAIL to compile — `commit(interactions:scopedTo:into:)` doesn't exist yet.

- [ ] **Step 3: Add `scopedTo` and the scope-check helper**

In `Sources/AnglesiteCore/ReceivedInteractionCommitter.swift`, change the `commit` signature and its stale-deletion loop:

```swift
    @discardableResult
    public static func commit(
        interactions: [ReceivedInteraction],
        scopedTo protocolTypes: Set<ReceivedInteraction.ProtocolType>? = nil,
        into siteDirectory: URL,
        fileManager: FileManager = .default,
        gitCommitBatch: @Sendable (URL, [String], String) async -> String? = InboxSubmissionCommitter.processGitCommitBatch
    ) async -> [String] {
        let interactionsDir = siteDirectory.appendingPathComponent("data/interactions", isDirectory: true)
        let currentIDs = Set(interactions.map(\.id))

        var relPaths: [String] = []
        var writtenIDs: [String] = []
        var deletedIDs: [String] = []

        let existingFiles = (try? fileManager.contentsOfDirectory(at: interactionsDir, includingPropertiesForKeys: nil)) ?? []
        for file in existingFiles where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard !currentIDs.contains(id) else { continue }
            if let protocolTypes, !Self.isInScope(file, protocolTypes: protocolTypes, fileManager: fileManager) { continue }
            guard (try? fileManager.removeItem(at: file)) != nil else { continue }
            relPaths.append("data/interactions/\(id).json")
            deletedIDs.append(id)
        }
```

(The rest of the function body — writing new/changed files, the commit call — is unchanged.)

Then add the helper, right after `jsonData(for:)`:

```swift
    /// Whether an existing snapshot file's own decoded `type` is in `protocolTypes` — scopes
    /// staleness deletion so two independent sources sharing `data/interactions/` (#1236 adds a
    /// second one, the Bluesky backfeed, alongside the existing webmention/AP sync) don't delete
    /// each other's files. A file that fails to decode (malformed, or hand-authored without a
    /// recognized `type`) is treated as out of scope — never deleted by a source that can't
    /// identify it as its own.
    private static func isInScope(
        _ file: URL, protocolTypes: Set<ReceivedInteraction.ProtocolType>, fileManager: FileManager
    ) -> Bool {
        struct TypeOnly: Decodable { let type: ReceivedInteraction.ProtocolType }
        guard let data = fileManager.contents(atPath: file.path),
              let decoded = try? JSONDecoder().decode(TypeOnly.self, from: data)
        else { return false }
        return protocolTypes.contains(decoded.type)
    }
```

Also update the type-level doc comment (above `public enum ReceivedInteractionCommitter`) to mention scoping — append this sentence to the existing comment block:

```swift
/// Two independent sources can share this directory safely via `commit`'s `scopedTo` parameter —
/// see `docs/superpowers/specs/2026-08-17-bluesky-replies-comment-section-design.md`.
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path . --filter ReceivedInteractionCommitterTests`
Expected: PASS — including every pre-existing test in the file (the `type` param default preserves their behavior exactly).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ReceivedInteractionCommitter.swift Tests/AnglesiteCoreTests/ReceivedInteractionCommitterTests.swift
git commit -m "feat(#1236): scope interaction reconcile by protocol type"
```

---

### Task 3: `ReceivedInteractionSync` scopes its production commit to `.webmention`

**Files:**
- Modify: `Sources/AnglesiteCore/ReceivedInteractionSync.swift:49`
- Test: `Tests/AnglesiteCoreTests/ReceivedInteractionSyncTests.swift`

**Interfaces:**
- Consumes: `ReceivedInteractionCommitter.commit(interactions:scopedTo:into:)` (Task 2).

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/ReceivedInteractionSyncTests.swift` (after `reconcilesAwayStaleFiles`):

```swift
    @Test("pullAndCommit's webmention-scoped reconcile leaves an existing bluesky-sourced snapshot untouched")
    func webmentionReconcileLeavesBlueskyFilesAlone() async throws {
        let siteDirectory = try Self.makeThrowawayGitRepo()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }

        let blueskyInteraction = try ReceivedInteraction(
            id: "bsky-xyz", type: .bluesky,
            source: URL(string: "https://bsky.app/profile/alice.bsky.social/post/xyz")!,
            target: URL(string: "https://me.example/blog/hi")!, interactionType: .reply,
            author: nil, content: "hi", published: Date(), verified: Date(), verificationStatus: .verified)
        _ = await ReceivedInteractionCommitter.commit(
            interactions: [blueskyInteraction], scopedTo: [.bluesky], into: siteDirectory)

        let body = Self.d1Body("")
        let client = WebmentionInboxD1Client(
            accountID: "acct1", databaseID: "db1", apiToken: "token", transport: { _ in (body, Self.response(200)) })
        _ = await ReceivedInteractionSync.pullAndCommit(client: client, siteDirectory: siteDirectory)

        #expect(FileManager.default.fileExists(
            atPath: siteDirectory.appendingPathComponent("data/interactions/bsky-xyz.json").path))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --filter ReceivedInteractionSyncTests`
Expected: FAIL — `pullAndCommit`'s D1-empty reconcile currently deletes every file it doesn't recognize, including `bsky-xyz.json`.

- [ ] **Step 3: Pass the scope**

In `Sources/AnglesiteCore/ReceivedInteractionSync.swift`, change:

```swift
        let committedIDs = await ReceivedInteractionCommitter.commit(interactions: interactions, into: siteDirectory)
```

to:

```swift
        let committedIDs = await ReceivedInteractionCommitter.commit(
            interactions: interactions, scopedTo: [.webmention], into: siteDirectory)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path . --filter ReceivedInteractionSyncTests`
Expected: PASS — including all pre-existing tests in the file.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ReceivedInteractionSync.swift Tests/AnglesiteCoreTests/ReceivedInteractionSyncTests.swift
git commit -m "fix(#1236): scope webmention reconcile to its own protocol type"
```

---

### Task 4: `BlueskyThreadClient` — fetch and flatten a reply thread

**Files:**
- Create: `Sources/AnglesiteCore/BlueskyThreadClient.swift`
- Test: `Tests/AnglesiteCoreTests/BlueskyThreadClientTests.swift`

**Interfaces:**
- Consumes: `CappedHTTPTransport.session(requestTimeout:resourceTimeout:)` / `.fetch(_:session:cap:tooLarge:)` (existing, `Sources/AnglesiteCore/CappedHTTPTransport.swift`).
- Produces: `BlueskyThreadClient.Transport` (public typealias `@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)`), `BlueskyThreadClient.defaultTransport` (public), `BlueskyThreadClient.RawReply` (internal struct: `rkey`, `authorHandle`, `authorName: String?`, `authorPhoto: URL?`, `text`, `createdAt: Date`), `BlueskyThreadClient.fetchReplies(atURI:transport:) async -> [RawReply]?` (internal — `nil` means hard failure, `[]` means a successful fetch that found no replies). Task 6 (`BlueskyBackfeedSync`) is the consumer.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/BlueskyThreadClientTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter BlueskyThreadClientTests`
Expected: FAIL to compile — `BlueskyThreadClient` doesn't exist yet.

- [ ] **Step 3: Create `BlueskyThreadClient.swift` with the reply-fetching half**

Create `Sources/AnglesiteCore/BlueskyThreadClient.swift`:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Unauthenticated reader for Bluesky's public AppView (#1236): pulls the reply thread, likes,
/// and reposts of a POSSE'd post so `BlueskyBackfeedSync` can snapshot them into
/// `data/interactions/` per the received-interaction canonicality design
/// (`docs/specs/2026-06-29-c3-received-interaction-canonicality.md`). No app password or session
/// is needed — `public.api.bsky.app` serves `getPostThread`/`getLikes`/`getRepostedBy` to anyone,
/// the same trust posture the inline-embed fetch in
/// `Resources/Template/scripts/embeds/adapters.ts` already relies on for Bluesky link cards.
/// See `docs/superpowers/specs/2026-08-17-bluesky-replies-comment-section-design.md`.
public enum BlueskyThreadClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let timeout: TimeInterval = 10
    static let resourceTimeout: TimeInterval = 20
    /// A thread with many replies (or a heavily-liked post) can be sizeable; generous but bounded
    /// — the same "cap a third-party response, don't trust it blindly" posture
    /// `CappedHTTPTransport`'s other callers (`ActorProfileFetcher`, `AnnouncedPostSync.OutboxClient`) use.
    static let maximumResponseBytes = 4 * 1024 * 1024
    /// How deep into nested replies-to-replies `getPostThread` is asked to walk. Comfortably
    /// beyond any realistic blog-comment thread; deeper nesting is a documented limitation — the
    /// API gives no truncation marker past this depth to detect and log against.
    static let threadDepth = 100

    private static let session = CappedHTTPTransport.session(requestTimeout: timeout, resourceTimeout: resourceTimeout)

    /// Production transport — public so callers (`BlueskyBackfeedSync`, tests) can inject a fake,
    /// matching `AnnouncedPostSync.defaultTransport`'s own rationale.
    public static let defaultTransport: Transport = { request in
        try await CappedHTTPTransport.fetch(
            request, session: session, cap: maximumResponseBytes,
            tooLarge: { _ in URLError(.dataLengthExceedsMaximum) })
    }

    /// One reply flattened out of a `getPostThread` tree, before mapping to `ReceivedInteraction`
    /// (which needs a `target` this client has no reason to know about).
    struct RawReply: Sendable, Equatable {
        let rkey: String
        let authorHandle: String
        let authorName: String?
        let authorPhoto: URL?
        let text: String
        let createdAt: Date
    }

    private static let iso8601 = ISO8601DateFormatter()
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Bluesky timestamps are ISO 8601 with fractional seconds (`...000Z`); tries the fractional
    /// formatter first and falls back to the plain one rather than assuming either shape.
    private static func parseDate(_ raw: Any?) -> Date? {
        guard let string = raw as? String else { return nil }
        return iso8601Fractional.date(from: string) ?? iso8601.date(from: string)
    }

    private static let adultLabels: Set<String> = ["porn", "sexual", "nudity", "graphic-media"]

    /// Whether `post` (a `getPostThread` node's `post` object) carries any label — AppView-applied
    /// or self-applied — this codebase treats as adult content. `Interactions.astro` has no
    /// content-warning UI to gate display on, so such a reply is excluded entirely rather than
    /// rendered.
    static func isAdultLabeled(_ post: [String: Any]) -> Bool {
        let appViewLabels = (post["labels"] as? [[String: Any]]) ?? []
        if appViewLabels.contains(where: { adultLabels.contains(($0["val"] as? String) ?? "") }) {
            return true
        }
        let record = post["record"] as? [String: Any]
        let selfLabels = (record?["labels"] as? [String: Any])?["values"] as? [[String: Any]] ?? []
        return selfLabels.contains { adultLabels.contains(($0["val"] as? String) ?? "") }
    }

    /// Extracts a `RawReply` from a `getPostThread` node's `post` object, or `nil` if it's missing
    /// a field this schema requires — a malformed/unexpected AppView response shouldn't crash the
    /// whole sync, just skip this one reply.
    static func makeRawReply(from post: [String: Any]) -> RawReply? {
        guard let uri = post["uri"] as? String, let rkey = uri.split(separator: "/").last,
              let author = post["author"] as? [String: Any], let handle = author["handle"] as? String,
              let record = post["record"] as? [String: Any], let text = record["text"] as? String,
              let createdAt = parseDate(record["createdAt"])
        else { return nil }
        return RawReply(
            rkey: String(rkey), authorHandle: handle, authorName: author["displayName"] as? String,
            authorPhoto: (author["avatar"] as? String).flatMap(URL.init(string:)),
            text: text, createdAt: createdAt)
    }

    /// Recursively flattens every reply under `node` (a `getPostThread` thread or reply object)
    /// into `results`, depth-first. Skips `#blockedPost`/`#notFoundPost` branches (Bluesky-side
    /// moderation/deletion — see the design doc) and adult-labeled posts, but still walks an
    /// adult-labeled post's own children (their labels are independent of their parent's).
    static func flattenReplies(_ node: [String: Any], into results: inout [RawReply]) {
        guard (node["$type"] as? String) == "app.bsky.feed.defs#threadViewPost",
              let post = node["post"] as? [String: Any]
        else { return }
        if !isAdultLabeled(post), let reply = makeRawReply(from: post) {
            results.append(reply)
        }
        for child in (node["replies"] as? [[String: Any]]) ?? [] {
            flattenReplies(child, into: &results)
        }
    }

    private static func url(path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: "https://public.api.bsky.app/xrpc/\(path)")
        components?.queryItems = queryItems
        return components?.url
    }

    /// Fetches and flattens every reply under `atURI`'s thread, at any depth. Returns `nil` on any
    /// hard failure (network error, non-2xx, undecodable body) — callers must treat `nil` as
    /// "retry next time," never as "zero replies," since a root post that's genuinely gone comes
    /// back as a *successful* response whose `thread` is `#notFoundPost`/`#blockedPost` (handled
    /// here as an empty result, not a `nil` one).
    ///
    /// **Important:** this walks `thread["replies"]`, not `thread` itself. `thread["post"]` is the
    /// *tracked post's own copy* (the same post `atURI` names) — `flattenReplies` on `thread`
    /// directly would append the owner's own post as if it were a reply to itself. Each element of
    /// `thread["replies"]`, by contrast, genuinely is a reply — that's where `flattenReplies`
    /// (append this node's post, recurse into its own nested `replies`) is the correct walk.
    static func fetchReplies(atURI: String, transport: Transport) async -> [RawReply]? {
        guard let url = Self.url(path: "app.bsky.feed.getPostThread", queryItems: [
            URLQueryItem(name: "uri", value: atURI),
            URLQueryItem(name: "depth", value: String(threadDepth)),
            URLQueryItem(name: "parentHeight", value: "0"),
        ]) else { return nil }
        guard let (data, http) = try? await transport(URLRequest(url: url)), (200..<300).contains(http.statusCode)
        else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thread = json["thread"] as? [String: Any]
        else { return nil }
        guard (thread["$type"] as? String) == "app.bsky.feed.defs#threadViewPost" else { return [] }
        var results: [RawReply] = []
        for child in (thread["replies"] as? [[String: Any]]) ?? [] {
            flattenReplies(child, into: &results)
        }
        return results
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter BlueskyThreadClientTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/BlueskyThreadClient.swift Tests/AnglesiteCoreTests/BlueskyThreadClientTests.swift
git commit -m "feat(#1236): fetch and flatten Bluesky reply threads"
```

---

### Task 5: `BlueskyThreadClient` — fetch likes and reposts, with pagination

**Files:**
- Modify: `Sources/AnglesiteCore/BlueskyThreadClient.swift`
- Modify: `Tests/AnglesiteCoreTests/BlueskyThreadClientTests.swift`

**Interfaces:**
- Produces: `BlueskyThreadClient.RawActorEvent` (internal struct: `actorDID`, `actorHandle`, `actorName: String?`, `actorPhoto: URL?`, `createdAt: Date?` — `nil` when the endpoint exposes no per-item timestamp, observed on `getRepostedBy`'s bare actor-profile items), `BlueskyThreadClient.fetchLikes(atURI:transport:) async -> [RawActorEvent]?`, `BlueskyThreadClient.fetchReposts(atURI:transport:) async -> [RawActorEvent]?` (both internal). Task 6 is the consumer.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnglesiteCoreTests/BlueskyThreadClientTests.swift` (inside the `BlueskyThreadClientTests` struct, after the `fetchReplies` tests):

```swift
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
```

Note the closing `}` of `BlueskyThreadClientTests` moves to just before the new `private actor Counter` — the new tests are added *inside* the struct, and `Counter` is a new top-level (file-private) helper after it.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter BlueskyThreadClientTests`
Expected: FAIL to compile — `fetchLikes`/`fetchReposts`/`maximumPages` don't exist yet.

- [ ] **Step 3: Add likes/reposts fetching to `BlueskyThreadClient.swift`**

Add these members to the `BlueskyThreadClient` enum in `Sources/AnglesiteCore/BlueskyThreadClient.swift` (after `threadDepth`):

```swift
    /// Likes/reposts are paginated 100 at a time, up to this many pages — a generous, fixed cap
    /// rather than trusting a peer-controlled `cursor` chain to terminate, matching
    /// `AnnouncedPostSync.OutboxClient`'s own paging cap.
    static let maximumPages = 20
    static let pageSize = 100
```

Add, after `RawReply`:

```swift
    /// One like or repost, before mapping to `ReceivedInteraction`.
    struct RawActorEvent: Sendable, Equatable {
        let actorDID: String
        let actorHandle: String
        let actorName: String?
        let actorPhoto: URL?
        /// `nil` when the endpoint exposes no per-item timestamp — observed on `getRepostedBy`,
        /// whose items are bare actor profiles with no `createdAt` of their own. The caller falls
        /// back to sync time rather than inventing a value.
        let createdAt: Date?
    }
```

Add, after `flattenReplies`:

```swift
    /// Extracts one page of actor events from a `getLikes`/`getRepostedBy` response. `itemsKey` is
    /// `"likes"` (each item wraps `{actor, createdAt}`) or `"repostedBy"` (each item *is* the
    /// actor profile directly) — `item["actor"] ?? item` handles both shapes with one function.
    static func makeActorEvents(from json: [String: Any], itemsKey: String) -> [RawActorEvent] {
        let items = (json[itemsKey] as? [[String: Any]]) ?? []
        return items.compactMap { item -> RawActorEvent? in
            let actor = (item["actor"] as? [String: Any]) ?? item
            guard let did = actor["did"] as? String, let handle = actor["handle"] as? String else { return nil }
            return RawActorEvent(
                actorDID: did, actorHandle: handle, actorName: actor["displayName"] as? String,
                actorPhoto: (actor["avatar"] as? String).flatMap(URL.init(string:)),
                createdAt: parseDate(item["createdAt"]))
        }
    }

    /// Shared paging loop for `fetchLikes`/`fetchReposts`: follows `cursor` up to `maximumPages`,
    /// stopping early once a page returns no cursor. Returns `nil` only on the *first* page's hard
    /// failure — once at least one page has been read successfully, a later page failing mid-walk
    /// still returns what was gathered so far, since a partial-but-real list is more useful than
    /// discarding it, and a missed later page just means an undercount until the next site-open
    /// retries (unlike `fetchReplies`'s all-or-nothing failure, this never has to decide "zero or
    /// retry" for the whole post — see `BlueskyBackfeedSync`'s own all-or-nothing gate for that).
    private static func paginate(
        endpoint: String, atURI: String, itemsKey: String, transport: Transport
    ) async -> [RawActorEvent]? {
        var results: [RawActorEvent] = []
        var cursor: String?
        var page = 0
        var fetchedAnyPage = false
        repeat {
            var items = [URLQueryItem(name: "uri", value: atURI), URLQueryItem(name: "limit", value: String(pageSize))]
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            guard let url = Self.url(path: endpoint, queryItems: items),
                  let (data, http) = try? await transport(URLRequest(url: url)), (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return fetchedAnyPage ? results : nil }
            fetchedAnyPage = true
            results.append(contentsOf: makeActorEvents(from: json, itemsKey: itemsKey))
            cursor = json["cursor"] as? String
            page += 1
        } while cursor != nil && page < maximumPages
        return results
    }

    static func fetchLikes(atURI: String, transport: Transport) async -> [RawActorEvent]? {
        await paginate(endpoint: "app.bsky.feed.getLikes", atURI: atURI, itemsKey: "likes", transport: transport)
    }

    static func fetchReposts(atURI: String, transport: Transport) async -> [RawActorEvent]? {
        await paginate(endpoint: "app.bsky.feed.getRepostedBy", atURI: atURI, itemsKey: "repostedBy", transport: transport)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter BlueskyThreadClientTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/BlueskyThreadClient.swift Tests/AnglesiteCoreTests/BlueskyThreadClientTests.swift
git commit -m "feat(#1236): fetch Bluesky likes and reposts with pagination"
```

---

### Task 6: `BlueskyBackfeedSync` — orchestration and mapping

**Files:**
- Create: `Sources/AnglesiteCore/BlueskyBackfeedSync.swift`
- Test: `Tests/AnglesiteCoreTests/BlueskyBackfeedSyncTests.swift`

**Interfaces:**
- Consumes: `POSSESyndicationLog` / `POSSESyndicationLog.Entry` (`Sources/AnglesiteCore/POSSESyndicationLog.swift` — `entries`, `.platform`, `.canonicalURL`, `.syndicationURL`), `POSSEStableKey.make(_:) -> String` (`Sources/AnglesiteCore/POSSEClients.swift:495`), `BlueskyThreadClient.{Transport, defaultTransport, RawReply, RawActorEvent, fetchReplies, fetchLikes, fetchReposts}` (Tasks 4-5), `ReceivedInteraction` with `.bluesky` (Task 1), `ReceivedInteractionCommitter.commit(interactions:scopedTo:into:)` (Task 2).
- Produces: `BlueskyBackfeedSync.pullAndCommitIfConfigured(siteDirectory:configDirectory:transport:) async -> Int` (public) — the entry point Task 7 wires into `PreviewModel`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/BlueskyBackfeedSyncTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter BlueskyBackfeedSyncTests`
Expected: FAIL to compile — `BlueskyBackfeedSync` doesn't exist yet.

- [ ] **Step 3: Create `BlueskyBackfeedSync.swift`**

Create `Sources/AnglesiteCore/BlueskyBackfeedSync.swift`:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Orchestrates #1236's "pull the Bluesky replies/likes/reposts of every POSSE'd post and snapshot
/// them into the site's git working copy" step, mirroring `ReceivedInteractionSync`'s shape but
/// reading `POSSESyndicationLog` (the local POSSE ledger) instead of a Worker's D1 database — no
/// Cloudflare token or provisioned Worker resource is needed, since Bluesky's `getPostThread`/
/// `getLikes`/`getRepostedBy` are public, unauthenticated AppView endpoints (same trust posture as
/// `AnnouncedPostSync`'s outbox fetch). Designed to be called once per site-open
/// (`PreviewModel.open(site:)`), alongside the other per-site syncs.
///
/// See `docs/superpowers/specs/2026-08-17-bluesky-replies-comment-section-design.md` for the full
/// design, including why `ReceivedInteractionCommitter.commit` needed a `scopedTo` parameter for
/// this to share `data/interactions/` safely with `ReceivedInteractionSync`.
public enum BlueskyBackfeedSync {
    /// Derives the `at://` URI (and the post's own rkey) `BlueskyThreadClient` needs from a
    /// `POSSESyndicationLog.Entry.syndicationURL` — the Bluesky permalink
    /// `https://bsky.app/profile/<handle>/post/<rkey>` `BlueskyPOSSEClient.publicURL` produces
    /// (`Sources/AnglesiteCore/POSSEClients.swift`). `nil` for anything not shaped like that
    /// permalink — the entry is simply skipped rather than guessed at.
    static func atURI(from syndicationURL: URL) -> (uri: String, rkey: String)? {
        let components = syndicationURL.pathComponents
        guard components.count == 5, components[1] == "profile", components[3] == "post" else { return nil }
        return ("at://\(components[2])/app.bsky.feed.post/\(components[4])", components[4])
    }

    /// Maps one flattened reply to the git-canonical schema. `nil` only when
    /// `ReceivedInteraction`'s own path-traversal guard rejects the derived id — not expected for
    /// a real AT-proto rkey, but mirrors `ReceivedInteractionSync.makeInteraction`'s `try?` rather
    /// than trusting the upstream shape unconditionally.
    static func makeInteraction(from reply: BlueskyThreadClient.RawReply, target: URL, now: Date) -> ReceivedInteraction? {
        try? ReceivedInteraction(
            id: "bsky-\(reply.rkey)", type: .bluesky,
            source: URL(string: "https://bsky.app/profile/\(reply.authorHandle)/post/\(reply.rkey)")!,
            target: target, interactionType: .reply,
            author: .init(
                name: reply.authorName, url: URL(string: "https://bsky.app/profile/\(reply.authorHandle)"),
                photo: reply.authorPhoto),
            content: String(reply.text.prefix(500)),
            published: reply.createdAt, verified: now, verificationStatus: .verified)
    }

    /// Maps one like/repost. Bluesky has no distinct per-like/-repost resource URL (unlike a
    /// webmention `like-of`/`repost-of` post) — the interaction *is* the actor's relationship to
    /// the target post, so `source` and `author.url` both fall back to the actor's own profile.
    /// `id` folds in `targetRkey` so the same actor liking two different tracked posts can't
    /// collide (`POSSEStableKey.make` already produces a `[0-9a-f]+` hash, a safe subset of the id
    /// charset).
    static func makeInteraction(
        from event: BlueskyThreadClient.RawActorEvent, interactionType: ReceivedInteraction.InteractionType,
        targetRkey: String, target: URL, now: Date
    ) -> ReceivedInteraction? {
        let kind = interactionType == .like ? "like" : "repost"
        let profileURL = URL(string: "https://bsky.app/profile/\(event.actorHandle)")!
        return try? ReceivedInteraction(
            id: "bsky-\(kind)-" + POSSEStableKey.make("\(targetRkey)\n\(event.actorDID)"), type: .bluesky,
            source: profileURL, target: target, interactionType: interactionType,
            author: .init(name: event.actorName, url: profileURL, photo: event.actorPhoto),
            content: nil, published: event.createdAt ?? now, verified: now, verificationStatus: .verified)
    }

    /// One tracked post's full result set, or `nil` if any of its three fetches hard-failed.
    private static func interactions(
        for entry: POSSESyndicationLog.Entry, transport: BlueskyThreadClient.Transport, now: Date
    ) async -> [ReceivedInteraction]? {
        guard let (atURI, rkey) = Self.atURI(from: entry.syndicationURL) else { return [] }
        async let repliesTask = BlueskyThreadClient.fetchReplies(atURI: atURI, transport: transport)
        async let likesTask = BlueskyThreadClient.fetchLikes(atURI: atURI, transport: transport)
        async let repostsTask = BlueskyThreadClient.fetchReposts(atURI: atURI, transport: transport)
        guard let replies = await repliesTask, let likes = await likesTask, let reposts = await repostsTask
        else { return nil }

        var out: [ReceivedInteraction] = []
        out.append(contentsOf: replies.compactMap { Self.makeInteraction(from: $0, target: entry.canonicalURL, now: now) })
        out.append(contentsOf: likes.compactMap {
            Self.makeInteraction(from: $0, interactionType: .like, targetRkey: rkey, target: entry.canonicalURL, now: now)
        })
        out.append(contentsOf: reposts.compactMap {
            Self.makeInteraction(from: $0, interactionType: .repost, targetRkey: rkey, target: entry.canonicalURL, now: now)
        })
        return out
    }

    /// Pulls every Bluesky-syndicated entry's replies/likes/reposts and reconciles them into
    /// `siteDirectory`. Returns 0 (never throws, never partially reconciles) if `ledger` has no
    /// `"bluesky"` entries, or if *any* tracked post's fetch hard-fails — a transient failure on
    /// one post must not be misread as "this post now has zero replies" and wipe its real,
    /// previously-fetched snapshots (see the design doc's failure-handling section).
    public static func pullAndCommit(
        ledger: POSSESyndicationLog, siteDirectory: URL,
        transport: BlueskyThreadClient.Transport = BlueskyThreadClient.defaultTransport,
        now: Date = Date()
    ) async -> Int {
        let entries = ledger.entries.filter { $0.platform == "bluesky" }
        guard !entries.isEmpty else { return 0 }

        var all: [ReceivedInteraction] = []
        for entry in entries {
            guard let interactions = await Self.interactions(for: entry, transport: transport, now: now) else { return 0 }
            all.append(contentsOf: interactions)
        }
        let committedIDs = await ReceivedInteractionCommitter.commit(interactions: all, scopedTo: [.bluesky], into: siteDirectory)
        return committedIDs.count
    }

    /// Reads the site's POSSE ledger from `configDirectory`; no-ops (returns 0, no network call)
    /// when the site has never syndicated to Bluesky. `configDirectory` is the package's `Config/`
    /// directory (`AnglesitePackage.configURL`), a sibling of `siteDirectory`
    /// (`AnglesitePackage.sourceURL`).
    public static func pullAndCommitIfConfigured(
        siteDirectory: URL, configDirectory: URL,
        transport: BlueskyThreadClient.Transport = BlueskyThreadClient.defaultTransport
    ) async -> Int {
        guard let ledger = POSSESyndicationLog.load(from: configDirectory) else { return 0 }
        return await pullAndCommit(ledger: ledger, siteDirectory: siteDirectory, transport: transport)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter BlueskyBackfeedSyncTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/BlueskyBackfeedSync.swift Tests/AnglesiteCoreTests/BlueskyBackfeedSyncTests.swift
git commit -m "feat(#1236): orchestrate Bluesky interaction backfeed"
```

---

### Task 7: Wire `BlueskyBackfeedSync` into `PreviewModel.open(site:)`

**Files:**
- Modify: `Sources/AnglesiteApp/PreviewModel.swift:274-279`

**Interfaces:**
- Consumes: `BlueskyBackfeedSync.pullAndCommitIfConfigured(siteDirectory:configDirectory:) async -> Int` (Task 6).

No new test: none of the four existing per-site syncs wired into this same block (`MicropubContentSync`, `AnnouncedPostSync`, `CommunityMembersSync`, and `ReceivedInteractionSync` itself) has dedicated coverage for its presence in this call list — each is unit-tested in its own file (Task 6 already covers `BlueskyBackfeedSync` directly), and this step is pure mechanical wiring.

- [ ] **Step 1: Add the call**

In `Sources/AnglesiteApp/PreviewModel.swift`, change:

```swift
            // #362: pull the webmention Worker's verified inbox from D1 and snapshot it into the
            // git working copy. No-ops for sites without a provisioned D1 database
            // (SiteSettings.provisionedWorkerResources.d1DatabaseID unset).
            _ = await ReceivedInteractionSync.pullAndCommitIfConfigured(
                siteDirectory: siteDirectory, configDirectory: configDirectory)
            // #912: pull Micropub-created posts from MICROPUB_DB and sync each into a typed
            // content file under src/content/. No-ops for sites without a provisioned D1
            // database (same gate as ReceivedInteractionSync — Micropub shares the database).
            _ = await MicropubContentSync.pullAndCommitIfConfigured(
                siteDirectory: siteDirectory, configDirectory: configDirectory)
```

to:

```swift
            // #362: pull the webmention Worker's verified inbox from D1 and snapshot it into the
            // git working copy. No-ops for sites without a provisioned D1 database
            // (SiteSettings.provisionedWorkerResources.d1DatabaseID unset).
            _ = await ReceivedInteractionSync.pullAndCommitIfConfigured(
                siteDirectory: siteDirectory, configDirectory: configDirectory)
            // #1236: pull replies/likes/reposts on every Bluesky-POSSE'd post from the public
            // AppView and snapshot them alongside the webmention/AP interactions above. No-ops
            // for sites that have never syndicated to Bluesky (no "bluesky" entry in the local
            // POSSE ledger) — no Cloudflare token or provisioned Worker resource needed.
            _ = await BlueskyBackfeedSync.pullAndCommitIfConfigured(
                siteDirectory: siteDirectory, configDirectory: configDirectory)
            // #912: pull Micropub-created posts from MICROPUB_DB and sync each into a typed
            // content file under src/content/. No-ops for sites without a provisioned D1
            // database (same gate as ReceivedInteractionSync — Micropub shares the database).
            _ = await MicropubContentSync.pullAndCommitIfConfigured(
                siteDirectory: siteDirectory, configDirectory: configDirectory)
```

- [ ] **Step 2: Build to verify it compiles**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: build succeeds (this file lives in `AnglesiteApp`, the Xcode-built app target — `swift test --package-path .` alone doesn't compile it).

If `Anglesite.xcodeproj` is stale or missing in this worktree, run `xcodegen generate` first (`AGENTS.md` ▸ "Worktrees" — the `.xcodeproj` is gitignored and regenerated from `project.yml`).

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/PreviewModel.swift
git commit -m "feat(#1236): pull Bluesky backfeed on site-open"
```

---

### Task 8: Full verification pass

**Files:** none (verification only)

- [ ] **Step 1: Run the full Swift test suite**

Run: `swift test --package-path .`
Expected: PASS — including every test added in Tasks 1-6 and every pre-existing test (in particular `ReceivedInteractionCommitterTests`, `ReceivedInteractionSyncTests`, and anything else touching `data/interactions/`).

- [ ] **Step 2: Run the template test suite**

Run (from `Resources/Template/`): `npx tsx --test src/lib/interactions.test.ts`
Expected: PASS

- [ ] **Step 3: Build the app target**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: build succeeds.

- [ ] **Step 4: Confirm `Interactions.astro` needed no changes**

Run: `git diff --stat main -- Resources/Template/src/components/Interactions.astro`
Expected: empty output — the design's central claim (the render side is already protocol-agnostic) holds; if this shows a diff, something in Tasks 1-7 accidentally touched rendering and should be reverted back to relying on `interactionType`-based generic rendering.

- [ ] **Step 5: Review the full diff against `CONTRIBUTING.md` before opening the PR**

Run: `git diff main --stat`

Confirm: commit subjects are all ≤72 characters and reference `#1236`; no new third-party dependency was introduced; the PR body (when opened) uses `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings including **Paired PR check** (answer: no MCP schema change, app-only); the PR description includes a `Closes #1236` line.

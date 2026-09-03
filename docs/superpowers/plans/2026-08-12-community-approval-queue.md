# Community Approval Queue (V-5.3 slice) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a community owner see who is waiting to join their hosted `Group` and approve them from the Moderation pane — the approval-queue slice of #370 that design-doc decision D4 deferred pending an upstream listing endpoint, which has since shipped (`davidwkeith/workers` PR #488, closing workers#487).

**Architecture:** `CommunityMembershipClient` (`AnglesiteCore`) gets two new methods mirroring its existing `follow`/`remove` shape exactly: `listFollowRequests()` (bearer-`GET` `<actor>/follow_requests`, decodes the Worker's flat `{items, total}` JSON) and `acceptFollow(target:)` (bearer-`POST` an `Accept` activity to the outbox, same shape as `remove(target:)` but `type: "Accept"`). `ModerationModel` (`AnglesiteApp`) fetches the pending list on every `reload()` and exposes an `approve(_:)` action; `ModerationView` renders a new "Requests" section between Moderators and Members.

**Tech Stack:** Swift 6.4, Swift Testing, `URLSession`/`URLRequest` via the existing `CommunityMembershipClient.Transport` test seam, SwiftUI.

## Global Constraints

- The `davidwkeith/workers` route this consumes (`GET <actor>/follow_requests`) merged in workers PR #488 **after** the latest tagged release (`dwk-server-v1.0.0-beta.3`, cut 2026-08-10T18:28:14Z; the PR merged 2026-08-10T21:37:47Z). Per `CONTRIBUTING.md` ▸ "`@dwk/workers` catalog coordination": keep this feature backward-compatible and inert-safe until a newer tagged release ships — a 404/error from `listFollowRequests()` must **never** surface a blocking error to the owner; it must fail silently to an empty list, exactly like `ModerationModel.decodeAll`'s "a bad read must never make the pane unusable" philosophy already in this file.
- `acceptFollow(target:)`'s underlying `Accept`-via-outbox routing already shipped in beta.3 (workers#473, closed 2026-07-31) — this half is *not* pending-release and works today.
- Match existing code conventions exactly: doc-comment style (see `docs/comment-style-guide.md` if unsure), `Sendable`/`Equatable` on public model types, Swift Testing (`@Test`, `#expect`, `#require`) — not XCTest — for every new test in these two files.
- No confirmation dialog for "Approve" — unlike ban/remove, admitting a member is not destructive (a bad admit is reversible via the existing Ban action), so this mirrors `addModerator`'s no-confirmation precedent, not `ban`/`removePost`'s confirmation-dialog one.
- Run `swift test --package-path .` after each task and confirm the new tests plus the full existing suite pass before committing.

---

### Task 1: `PendingFollower` model + `CommunityMembershipClient` GET/Accept methods

**Files:**
- Create: `Sources/AnglesiteCore/PendingFollower.swift`
- Modify: `Sources/AnglesiteCore/CommunityMembershipClient.swift`
- Test: `Tests/AnglesiteCoreTests/CommunityMembershipClientTests.swift`

**Interfaces:**
- Produces: `public struct PendingFollower: Sendable, Equatable, Identifiable` with `actor: URL`, `addedAt: Date`, `id: URL { actor }`, `public init(actor: URL, addedAt: Date)`.
- Produces: `CommunityMembershipClient.acceptFollow(target: URL) async throws` (mirrors `remove(target:)`).
- Produces: `CommunityMembershipClient.listFollowRequests() async throws -> [PendingFollower]`.
- Consumes: nothing new from outside this task — `CommunityMembershipError`, `Transport` already exist in the file.

- [ ] **Step 1: Write the failing tests**

Append these four tests to the end of `Tests/AnglesiteCoreTests/CommunityMembershipClientTests.swift`, just before the suite's closing `}` (after `removeMapsNon2xx`):

```swift
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
    }

    @Test("acceptFollow maps a non-2xx status to requestFailed")
    func acceptMapsNon2xx() async throws {
        let fake = FakeTransport(status: 403, body: "forbidden")
        let target = try #require(URL(string: "https://lemmy.ml/u/newmember"))
        await #expect(throws: CommunityMembershipError.requestFailed(status: 403, body: "forbidden")) {
            try await Self.client(fake).acceptFollow(target: target)
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter CommunityMembershipClientTests`
Expected: FAIL to compile — `acceptFollow`/`listFollowRequests` don't exist yet on `CommunityMembershipClient`.

- [ ] **Step 3: Create `PendingFollower`**

Create `Sources/AnglesiteCore/PendingFollower.swift`:

```swift
// Sources/AnglesiteCore/PendingFollower.swift
import Foundation

/// One pending join request against this site's hosted `Group` actor: someone who sent a
/// `Follow` while the actor requires manual approval, awaiting the owner's `Accept`/`Reject`
/// (`davidwkeith/workers` PR #488's bearer-gated `GET <actor>/follow_requests`, closing
/// workers#487 — see
/// `docs/superpowers/specs/2026-08-10-hosted-community-provisioning-moderation-design.md` §6).
///
/// Transient: fetched live from this site's own Worker on every `ModerationModel.reload()`,
/// never written to `Source/` git — unlike ``CommunityMember``/`AnnouncedPost`, which snapshot
/// *confirmed* state, this is a live read of state the Worker alone owns.
public struct PendingFollower: Sendable, Equatable, Identifiable {
    /// The requester's own actor IRI — also this struct's ``id``, since it's the unique key
    /// the Worker itself uses (`followers.actor`).
    public let actor: URL
    /// When the `Follow` was recorded, decoded from the Worker's ISO 8601 `addedAt` string.
    public let addedAt: Date

    public var id: URL { actor }

    public init(actor: URL, addedAt: Date) {
        self.actor = actor
        self.addedAt = addedAt
    }
}
```

- [ ] **Step 4: Add the GET/Accept methods to `CommunityMembershipClient`**

In `Sources/AnglesiteCore/CommunityMembershipClient.swift`, replace the `remove(target:)` method through the end of the `post(_:)` method (i.e. replace this exact block):

```swift
    public func remove(target: URL) async throws {
        let body: [String: Any] = [
            "@context": "https://www.w3.org/ns/activitystreams",
            "type": "Remove",
            "actor": ownActorURL.absoluteString,
            "object": target.absoluteString,
        ]
        _ = try await post(body)
    }

    private func post(_ activity: [String: Any]) async throws -> Data {
        var request = URLRequest(url: outboxURL)
        request.httpMethod = "POST"
        request.setValue("application/activity+json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(publishToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: activity)

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            throw CommunityMembershipError.requestFailed(status: 0, body: "\(error)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CommunityMembershipError.requestFailed(
                status: http.statusCode, body: String(decoding: data.prefix(400), as: UTF8.self))
        }
        return data
    }
```

with:

```swift
    public func remove(target: URL) async throws {
        let body: [String: Any] = [
            "@context": "https://www.w3.org/ns/activitystreams",
            "type": "Remove",
            "actor": ownActorURL.absoluteString,
            "object": target.absoluteString,
        ]
        _ = try await post(body)
    }

    /// Confirms a pending join request — the owner-triggered half of workers#473's `Accept`
    /// routing, which already ships in `dwk-server-v1.0.0-beta.3`. Same shorthand `object` shape
    /// as ``remove(target:)``: a bare actor IRI, which the Worker's `#singleFollowTarget` resolves
    /// against the stored `Follow` row.
    public func acceptFollow(target: URL) async throws {
        let body: [String: Any] = [
            "@context": "https://www.w3.org/ns/activitystreams",
            "type": "Accept",
            "actor": ownActorURL.absoluteString,
            "object": target.absoluteString,
        ]
        _ = try await post(body)
    }

    /// Lists everyone whose `Follow` is awaiting this owner's `Accept` — the bearer-gated
    /// `GET <actor>/follow_requests` `davidwkeith/workers` PR #488 added (closing workers#487),
    /// mirroring `GET <actor>/blocked`'s unpaged flat `{items, total}` JSON exactly. **Not yet in
    /// a tagged `@dwk/workers` release** as of `dwk-server-v1.0.0-beta.3` — callers must treat a
    /// failure here (most likely a 404 from a not-yet-updated deployed Worker) as "nothing
    /// pending", never as a user-facing error; see `ModerationModel.loadPendingFollowers()`.
    public func listFollowRequests() async throws -> [PendingFollower] {
        var request = URLRequest(url: ownActorURL.appendingPathComponent("follow_requests"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(publishToken)", forHTTPHeaderField: "Authorization")
        let data = try await send(request)
        return Self.decodeFollowRequests(data)
    }

    /// Decodes the Worker's `{items: [{actor, addedAt}], total}` response. A malformed body, or
    /// an item whose `addedAt` doesn't parse as ISO 8601 (with or without fractional seconds —
    /// `Date.toISOString()` always emits `.000`-style milliseconds, which the plain
    /// `ISO8601DateFormatter()` default options reject), is dropped rather than failing the whole
    /// call — same "a bad item never blocks the good ones" rule ``ModerationModel``'s snapshot
    /// decoding already follows.
    private static func decodeFollowRequests(_ data: Data) -> [PendingFollower] {
        struct Response: Decodable {
            struct Item: Decodable { let actor: URL; let addedAt: String }
            let items: [Item]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        let withFractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        let plain = ISO8601DateFormatter()
        return response.items.compactMap { item in
            guard let date = withFractional.date(from: item.addedAt) ?? plain.date(from: item.addedAt) else {
                return nil
            }
            return PendingFollower(actor: item.actor, addedAt: date)
        }
    }

    /// Shared POST/GET status handling: maps a transport error or non-2xx response to
    /// ``CommunityMembershipError/requestFailed(status:body:)``, otherwise returns the raw body.
    /// Factored out of `post(_:)` so ``listFollowRequests()``'s GET reuses the exact same mapping
    /// instead of duplicating it.
    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport(request)
        } catch {
            throw CommunityMembershipError.requestFailed(status: 0, body: "\(error)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CommunityMembershipError.requestFailed(
                status: http.statusCode, body: String(decoding: data.prefix(400), as: UTF8.self))
        }
        return data
    }

    private func post(_ activity: [String: Any]) async throws -> Data {
        var request = URLRequest(url: outboxURL)
        request.httpMethod = "POST"
        request.setValue("application/activity+json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(publishToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: activity)
        return try await send(request)
    }
```

Note this also changes `CommunityMembershipError.decodingFailed`'s doc comment from "currently unused" to reflect it's still unused (decode failures here fall back to `[]`, not to that case) — leave the enum case and its doc comment as-is; `decodeFollowRequests` intentionally doesn't throw it, per the "never surface a blocking error for this" global constraint.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path . --filter CommunityMembershipClientTests`
Expected: PASS — all tests in the suite, including the 5 pre-existing ones and the 5 new ones.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/PendingFollower.swift Sources/AnglesiteCore/CommunityMembershipClient.swift Tests/AnglesiteCoreTests/CommunityMembershipClientTests.swift
git commit -m "feat(#370): add follow-request listing + accept to CommunityMembershipClient"
```

---

### Task 2: Wire the approval queue into `ModerationModel` + `ModerationView`

**Files:**
- Modify: `Sources/AnglesiteApp/ModerationModel.swift`
- Modify: `Sources/AnglesiteApp/ModerationView.swift`
- Test: `Tests/AnglesiteAppTests/ModerationModelTests.swift`

**Interfaces:**
- Consumes: `PendingFollower` (Task 1, `actor: URL`, `addedAt: Date`, `id: URL`), `CommunityMembershipClient.listFollowRequests() async throws -> [PendingFollower]`, `CommunityMembershipClient.acceptFollow(target: URL) async throws` (Task 1).
- Produces: `ModerationModel.pendingFollowers: [PendingFollower]` (read-only, published), `ModerationModel.approve(_ follower: PendingFollower) async` (non-throwing, sets `errorMessage` on failure — the view calls this directly, no confirmation state needed).

- [ ] **Step 1: Write the failing tests**

Append these three tests to `Tests/AnglesiteAppTests/ModerationModelTests.swift`, just before the suite's closing `}` (after `addModeratorRejectsInvalidURL`):

```swift
    @Test("reload fetches pending follow requests from this site's own actor")
    func reloadLoadsPendingFollowRequests() async throws {
        let (config, source) = try Self.makeSiteDirectories()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            if request.url?.lastPathComponent == "follow_requests" {
                let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (
                    Data(
                        #"{"items":[{"actor":"https://lemmy.ml/u/newmember","addedAt":"2026-08-10T18:28:14.000Z"}],"total":1}"#
                            .utf8), http
                )
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), http)
        })
        await model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))

        #expect(model.pendingFollowers.count == 1)
        #expect(model.pendingFollowers.first?.actor.absoluteString == "https://lemmy.ml/u/newmember")
    }

    /// The upstream listing endpoint (`davidwkeith/workers` PR #488) postdates the latest tagged
    /// `@dwk/workers` release as of this writing (see the plan's Global Constraints) — a deployed
    /// community's Worker will 404 on this route until it redeploys against a newer release. That
    /// must degrade to an empty list, never a blocking alert.
    @Test("a 404 from follow_requests leaves pendingFollowers empty without surfacing an error")
    func reloadIgnoresFollowRequests404() async throws {
        let (config, source) = try Self.makeSiteDirectories()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data("Not Found".utf8), http)
        })
        await model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))

        #expect(model.pendingFollowers.isEmpty)
        #expect(model.errorMessage == nil)
    }

    @Test("approving a follower POSTs Accept and drops them from the pending list")
    func approveAcceptsAndRemovesFromPendingList() async throws {
        let (config, source) = try Self.makeSiteDirectories()
        defer { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"
        actor Recorder {
            private(set) var bodies: [[String: Any]] = []
            func record(_ body: [String: Any]) { bodies.append(body) }
        }
        let recorder = Recorder()

        let model = ModerationModel(secretStore: secretStore, membershipTransport: { request in
            if request.url?.lastPathComponent == "follow_requests" {
                let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (
                    Data(
                        #"{"items":[{"actor":"https://lemmy.ml/u/newmember","addedAt":"2026-08-10T18:28:14.000Z"}],"total":1}"#
                            .utf8), http
                )
            }
            if let data = request.httpBody, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                await recorder.record(json)
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), http)
        })
        await model.configure(site: Self.site(configDirectory: config, sourceDirectory: source))
        #expect(model.pendingFollowers.count == 1)

        await model.approve(model.pendingFollowers[0])

        let body = await recorder.bodies.first
        #expect(body?["type"] as? String == "Accept")
        #expect(body?["object"] as? String == "https://lemmy.ml/u/newmember")
        #expect(model.pendingFollowers.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter ModerationModelTests`
Expected: FAIL to compile — `pendingFollowers`/`approve(_:)` don't exist yet on `ModerationModel`.

- [ ] **Step 3: Add `pendingFollowers` state and loading to `ModerationModel`**

In `Sources/AnglesiteApp/ModerationModel.swift`, replace:

```swift
    private(set) var members: [CommunityMember] = []
    private(set) var posts: [AnnouncedPost] = []
    private(set) var moderators: [String] = []
```

with:

```swift
    private(set) var members: [CommunityMember] = []
    private(set) var posts: [AnnouncedPost] = []
    private(set) var moderators: [String] = []
    private(set) var pendingFollowers: [PendingFollower] = []
```

Then replace:

```swift
    func reload() async {
        guard let sourceDirectory, let configDirectory else { return }
        let settings = (try? await SiteConfigStore(configDirectory: configDirectory).load()) ?? SiteSettings()
        async let loadedMembers = Self.decodeAll(
            CommunityMember.self, from: sourceDirectory.appendingPathComponent("data/community-members"))
        async let loadedPosts = Self.decodeAll(
            AnnouncedPost.self, from: sourceDirectory.appendingPathComponent("data/community-posts"))
        moderators = settings.moderators ?? []
        members = await loadedMembers
        posts = await loadedPosts
    }
```

with:

```swift
    func reload() async {
        guard let sourceDirectory, let configDirectory else { return }
        let settings = (try? await SiteConfigStore(configDirectory: configDirectory).load()) ?? SiteSettings()
        async let loadedMembers = Self.decodeAll(
            CommunityMember.self, from: sourceDirectory.appendingPathComponent("data/community-members"))
        async let loadedPosts = Self.decodeAll(
            AnnouncedPost.self, from: sourceDirectory.appendingPathComponent("data/community-posts"))
        moderators = settings.moderators ?? []
        members = await loadedMembers
        posts = await loadedPosts
        pendingFollowers = await loadPendingFollowers()
    }

    /// Fetches pending join requests from this site's own Worker
    /// (`CommunityMembershipClient.listFollowRequests()`). Fails silently to an empty list — same
    /// "a bad read must never make the pane unusable" philosophy ``decodeAll(_:from:)`` follows for
    /// member/post snapshots — because the underlying `GET <actor>/follow_requests` route
    /// (`davidwkeith/workers` PR #488) postdates the latest tagged `@dwk/workers` release as of
    /// this writing: a deployed community's Worker will 404 until it redeploys against a newer
    /// one, and that expected 404 must never pop a blocking alert on every pane open. No-ops
    /// (returns `[]`) until `ownActorURL`/`publishToken` are both available, same guard
    /// ``ban(_:)``/``removePost(_:)`` use.
    private func loadPendingFollowers() async -> [PendingFollower] {
        guard let ownActorURL, let publishToken else { return [] }
        let client = CommunityMembershipClient(ownActorURL: ownActorURL, publishToken: publishToken, transport: membershipTransport)
        return (try? await client.listFollowRequests()) ?? []
    }
```

Then, after the `confirmBan()` method and before `func removePost(...)`, insert the `approve` action (this keeps membership-related actions — ban, approve — grouped together, ahead of the post-removal actions):

Replace:

```swift
    func confirmBan() async {
        guard let member = banConfirmation else { return }
        banConfirmation = nil
        do { try await ban(member) }
        catch { errorMessage = "Couldn't ban \(member.name ?? member.actorURL.absoluteString): \(error.localizedDescription)" }
    }

    func removePost(_ post: AnnouncedPost) async throws {
```

with:

```swift
    func confirmBan() async {
        guard let member = banConfirmation else { return }
        banConfirmation = nil
        do { try await ban(member) }
        catch { errorMessage = "Couldn't ban \(member.name ?? member.actorURL.absoluteString): \(error.localizedDescription)" }
    }

    /// Confirms a pending join request. No confirmation dialog (unlike ``ban(_:)``/
    /// ``removePost(_:)``) — admitting a member isn't destructive; a bad admit is reversible via
    /// the existing ``ban(_:)`` action, so this mirrors ``addModerator(_:)``'s no-confirmation
    /// precedent.
    func approve(_ follower: PendingFollower) async {
        guard let ownActorURL, let publishToken else {
            errorMessage = "This site has no known public URL yet — deploy it at least once first."
            return
        }
        let client = CommunityMembershipClient(ownActorURL: ownActorURL, publishToken: publishToken, transport: membershipTransport)
        do {
            try await client.acceptFollow(target: follower.actor)
            pendingFollowers.removeAll { $0.id == follower.id }
        } catch {
            errorMessage = "Couldn't approve \(follower.actor.absoluteString): \(error.localizedDescription)"
        }
    }

    func removePost(_ post: AnnouncedPost) async throws {
```

Finally, update the file's top doc comment — replace:

```swift
/// Backs the Moderation section (V-5.1b/V-5.3, #907/#370, design doc §5): moderator-list
/// display, and ban/remove actions over this site's own `CommunityMember`/`AnnouncedPost`
/// snapshot files. App glue only, mirroring `CommunitiesModel`'s shape — protocol logic
/// (`Remove`) lives in `AnglesiteCore`'s `CommunityMembershipClient`. Approval-queue and
/// report-review are explicitly out of scope (design doc D4/D5) — no state for either here.
```

with:

```swift
/// Backs the Moderation section (V-5.1b/V-5.3, #907/#370, design doc §5): moderator-list
/// display, ban/remove actions over this site's own `CommunityMember`/`AnnouncedPost` snapshot
/// files, and the approval queue (design doc D4, unblocked by `davidwkeith/workers` PR #488).
/// App glue only, mirroring `CommunitiesModel`'s shape — protocol logic (`Remove`/`Accept`/the
/// `follow_requests` listing) lives in `AnglesiteCore`'s `CommunityMembershipClient`.
/// Report-review remains explicitly out of scope (design doc D5) — no state for it here.
```

- [ ] **Step 4: Add the "Requests" section to `ModerationView`**

In `Sources/AnglesiteApp/ModerationView.swift`, replace:

```swift
            Section("Members") {
                ForEach(moderation.members) { member in
```

with:

```swift
            Section("Requests") {
                if moderation.pendingFollowers.isEmpty {
                    Text("No pending requests.").foregroundStyle(.secondary)
                } else {
                    ForEach(moderation.pendingFollowers) { follower in
                        HStack {
                            Text(follower.actor.absoluteString)
                            Spacer()
                            Button("Approve") { Task { await moderation.approve(follower) } }
                        }
                    }
                }
            }
            Section("Members") {
                ForEach(moderation.members) { member in
```

Then update the file's top doc comment — replace:

```swift
/// The Moderation section (V-5.1b/V-5.3, #907/#370, design doc §5): moderators, members
/// (with ban), posts (with remove), and an inert reports placeholder (D5 — no report-handling
/// exists upstream yet).
```

with:

```swift
/// The Moderation section (V-5.1b/V-5.3, #907/#370, design doc §5): moderators, an approval
/// queue for pending join requests, members (with ban), posts (with remove), and an inert
/// reports placeholder (D5 — no report-handling exists upstream yet).
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path . --filter ModerationModelTests`
Expected: PASS — all tests in the suite, including the 4 pre-existing ones and the 3 new ones.

Then run the full suite to confirm nothing else broke:

Run: `swift test --package-path .`
Expected: PASS — all suites (390+ tests as of this writing).

- [ ] **Step 6: Build the app target**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: clean build (`ModerationView.swift` is an app-target file `swift test` alone doesn't compile).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/ModerationModel.swift Sources/AnglesiteApp/ModerationView.swift Tests/AnglesiteAppTests/ModerationModelTests.swift
git commit -m "feat(#370): surface pending join requests in the Moderation pane"
```

---

## After both tasks: update the tracking issue

This closes the approval-queue slice of #370, leaving only report-review (D5, no upstream primitive at all) open. Before opening the PR:

- [ ] Update `docs/superpowers/specs/2026-08-10-hosted-community-provisioning-moderation-design.md` D4's row to note it shipped, referencing this plan.
- [ ] In the PR body's Paired PR check section, note (per `CONTRIBUTING.md` ▸ "`@dwk/workers` catalog coordination"): this consumes `davidwkeith/workers` PR #488 (`GET <actor>/follow_requests`), which has **not shipped in a tagged release yet** as of `dwk-server-v1.0.0-beta.3` — the feature is safe to merge now (fails inert-empty until the release ships and existing communities redeploy against it), but flag it so a human tracks when to consider #370 fully scoped down to just report-review.
- [ ] Do **not** close #370 or #339 in this PR — report-review (D5) still has no upstream primitive, so #370 stays open and #339 stays blocked on it. Leave a comment on #370 narrowing its remaining scope to report-review only, referencing this PR.

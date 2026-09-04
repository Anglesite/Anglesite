# Follow Approval Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a site owner see pending ActivityPub follow requests and Accept/Reject them from the Followers pane, with a notification when new requests arrive while a site's window is open.

**Architecture:** Reuse the existing `CommunityMembershipClient` (already implements `listFollowRequests()`/`acceptFollow(target:)` against this site's own actor, for `ModerationModel`) by adding a symmetric `rejectFollow(target:)`. `FollowersModel` gains its own pending-request state machine, action methods, and a background poll loop started/stopped by `SiteWindowModel`'s existing lifecycle hooks. `FollowersView` gains a "Pending Requests" section. `CompletionNotificationHub` wires a new notice for genuinely-new arrivals.

**Tech Stack:** Swift 6.4, SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`), `swift test --package-path .`.

## Global Constraints

- No new Swift package dependencies.
- Reuse `SecretAccounts.activityPubPublishToken(siteID:)` — no new secret/token type.
- `CommunityMembershipClient` is the one client for this site's own actor's follow-request
  operations — do not add a second, parallel client.
- A 404 from `listFollowRequests()` means "not shipped upstream yet" — never surfaced as an
  error to the owner.
- Every new/changed public API needs a `swift test` case; run `swift test --package-path .`
  after every task.
- Destructive action (Reject) requires an explicit confirmation per mac-assed-app-spec §5/§9;
  Accept requires none.
- Design reference: `docs/superpowers/specs/2026-08-17-follow-approval-design.md`.

---

### Task 1: `CommunityMembershipClient.rejectFollow(target:)`

**Files:**
- Modify: `Sources/AnglesiteCore/CommunityMembershipClient.swift`
- Test: `Tests/AnglesiteCoreTests/CommunityMembershipClientTests.swift`

**Interfaces:**
- Produces: `CommunityMembershipClient.rejectFollow(target: URL) async throws` — POSTs
  `{"@context": "...", "type": "Reject", "actor": <ownActorURL>, "object": <target>}` to the
  outbox, same as `acceptFollow(target:)` but `"Reject"`.

- [ ] **Step 1: Write the failing test**

Add to `CommunityMembershipClientTests` (near the existing `acceptFollow`-shaped test — search
the file for `"Accept"` to find it and mirror its shape):

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter CommunityMembershipClientTests`
Expected: FAIL — `value of type 'CommunityMembershipClient' has no member 'rejectFollow'`

- [ ] **Step 3: Implement `rejectFollow(target:)`**

In `Sources/AnglesiteCore/CommunityMembershipClient.swift`, add immediately after
`acceptFollow(target:)`:

```swift
    /// Declines a pending join request — the owner's alternative to ``acceptFollow(target:)``.
    /// Same `POST <actor>/outbox` seam and target-resolution rules (bare actor IRI as
    /// `object`), just `"Reject"` instead of `"Accept"`. Unlike `remove(target:)` (which bans
    /// an *already-accepted* member), this only makes sense against a still-pending request —
    /// the Worker's `#singleFollowTarget` resolves it the same way either verb does.
    public func rejectFollow(target: URL) async throws {
        let body: [String: Any] = [
            "@context": "https://www.w3.org/ns/activitystreams",
            "type": "Reject",
            "actor": ownActorURL.absoluteString,
            "object": target.absoluteString,
        ]
        _ = try await post(body)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter CommunityMembershipClientTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/CommunityMembershipClient.swift Tests/AnglesiteCoreTests/CommunityMembershipClientTests.swift
git commit -m "feat(#965): add CommunityMembershipClient.rejectFollow"
```

---

### Task 2: `CompletionNoticeBuilder.followRequest(...)`

**Files:**
- Modify: `Sources/AnglesiteCore/CompletionNotice.swift`
- Test: `Tests/AnglesiteCoreTests/CompletionNoticeTests.swift`

**Interfaces:**
- Produces: `CompletionNoticeBuilder.followRequest(siteName: String, siteID: String, count: Int) -> CompletionNotice`
  — identifier `"followRequest.<siteID>"`.

- [ ] **Step 1: Write the failing test**

Add a new `// MARK: Follow Request` section to `CompletionNoticeTests` (after the existing
`// MARK: Audit` section — search the file for `// MARK: Audit`):

```swift

    // MARK: Follow Request

    @Test("Singular follow request reads as one person")
    func followRequestSingular() {
        let notice = CompletionNoticeBuilder.followRequest(siteName: "Pullets Forever", siteID: "site-1", count: 1)
        #expect(notice.title == "New Follow Request")
        #expect(notice.subtitle == "Pullets Forever")
        #expect(notice.body == "1 person wants to follow your site.")
        #expect(notice.siteID == "site-1")
        #expect(!notice.isFailure)
    }

    @Test("Plural follow requests read as N people", arguments: [2, 5])
    func followRequestPlural(count: Int) {
        let notice = CompletionNoticeBuilder.followRequest(siteName: "Site", siteID: "site-1", count: count)
        #expect(notice.title == "New Follow Requests")
        #expect(notice.body == "\(count) people want to follow your site.")
    }

    @Test("Follow request identifier is stable per site so a later count replaces the banner")
    func followRequestIdentifierStable() {
        let a = CompletionNoticeBuilder.followRequest(siteName: "S", siteID: "site-1", count: 1)
        let b = CompletionNoticeBuilder.followRequest(siteName: "S", siteID: "site-1", count: 3)
        let other = CompletionNoticeBuilder.followRequest(siteName: "S", siteID: "site-2", count: 1)
        #expect(a.identifier == b.identifier)
        #expect(a.identifier != other.identifier)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter CompletionNoticeTests`
Expected: FAIL — `type 'CompletionNoticeBuilder' has no member 'followRequest'`

- [ ] **Step 3: Implement `followRequest(...)`**

In `Sources/AnglesiteCore/CompletionNotice.swift`, add a new section after the `// MARK: Audit`
block's `auditSummary(...)` helper and before `// MARK: Duration`:

```swift

    // MARK: Follow Request

    /// Builds the notice for newly-arrived pending follow requests (#965). Unlike
    /// deploy/backup/audit this isn't a terminal phase of a user-triggered operation — it's
    /// posted by `FollowersModel`'s background poll whenever the pending count exceeds what
    /// was last notified (see that type's `onNewPendingRequests`). Stable identifier per site
    /// so a later, larger count replaces the earlier banner rather than stacking — the banner
    /// always reflects the true current pending total, never a stale partial count.
    public static func followRequest(siteName: String, siteID: String, count: Int) -> CompletionNotice {
        let isSingular = count == 1
        return CompletionNotice(
            title: isSingular ? "New Follow Request" : "New Follow Requests",
            subtitle: siteName,
            body: isSingular
                ? "1 person wants to follow your site."
                : "\(count) people want to follow your site.",
            siteID: siteID,
            identifier: "followRequest.\(siteID)",
            isFailure: false
        )
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter CompletionNoticeTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/CompletionNotice.swift Tests/AnglesiteCoreTests/CompletionNoticeTests.swift
git commit -m "feat(#965): add CompletionNoticeBuilder.followRequest notice"
```

---

### Task 3: `FollowersModel` — pending list state and loading

**Files:**
- Modify: `Sources/AnglesiteApp/FollowersModel.swift`
- Test: `Tests/AnglesiteAppTests/FollowersModelTests.swift`

**Interfaces:**
- Consumes: `CommunityMembershipClient.listFollowRequests() -> [PendingFollower]` (existing),
  `CommunityMembershipError.requestFailed(status:body:)` (existing), `PendingFollower { actor: URL, addedAt: Date }`
  (existing, `Sources/AnglesiteCore/PendingFollower.swift`), `SecretStore.read(account:)`,
  `SecretAccounts.activityPubPublishToken(siteID:)`, `PlatformSecretStore.make()` (all existing).
- Produces: `FollowersModel.pendingRows: [PendingRequestRow]`, `FollowersModel.pendingState: PendingState`,
  `FollowersModel.loadPending() async` — used by Task 4 (accept/reject) and Task 5 (polling).
  `PendingRequestRow { request: PendingFollower, profile: ActorProfile? }`, `id: URL` (the
  actor IRI), `displayName: String`, `handle: String?`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteAppTests/FollowersModelTests.swift`. First, extend the file's fixtures:
find `private static func makeModel(server: Server) async -> FollowersModel` and add a sibling
fixture right after it that also wires an in-memory secret store and a scripted membership
transport (mirrors `ModerationModelTests.InMemorySecretStore`, defined as a nested type in this
file since `FollowersModelTests` doesn't yet have one):

```swift
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
```

Then add the test cases (new `// MARK: - Pending requests` section, appended at the end of the
`struct FollowersModelTests` body, just before its closing `}`):

```swift

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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter FollowersModelTests`
Expected: FAIL — `value of type 'FollowersModel' has no member 'loadPending'` (and no
`secretStore`/`membershipTransport` init parameters yet)

- [ ] **Step 3: Implement the pending state machine and `loadPending()`**

In `Sources/AnglesiteApp/FollowersModel.swift`:

1. Add near the top, right after the `FollowerRow` struct, a shared display-name helper and the
   new `PendingRequestRow` type:

```swift
/// Shared display-name derivation for both `FollowerRow` and `PendingRequestRow`: fetched
/// display name, else fetched username, else derived handle, else the raw IRI.
enum ActorDisplay {
    static func name(profile: ActorProfile?, handle: String?, actor: URL) -> String {
        if let name = profile?.name, !name.isEmpty { return name }
        if let username = profile?.preferredUsername, !username.isEmpty { return "@\(username)" }
        return handle ?? actor.absoluteString
    }
}

/// One pending follow request in the Followers pane's "Pending Requests" section — pairs the
/// Worker's `PendingFollower` with the same lazily-enriched display identity `FollowerRow` uses.
struct PendingRequestRow: Identifiable, Equatable {
    let request: PendingFollower
    var profile: ActorProfile?

    var id: URL { request.actor }
    var handle: String? { ActorHandle.derive(from: request.actor) }
    var displayName: String { ActorDisplay.name(profile: profile, handle: handle, actor: request.actor) }
}
```

2. Update `FollowerRow.displayName` to use the shared helper instead of its own inline chain:

```swift
    var displayName: String { ActorDisplay.name(profile: profile, handle: handle, actor: actor) }
```

(replacing the existing 4-line `if`/`if`/`return` body).

3. Add the pending state enum, as a nested type on `FollowersModel` right after the existing
   `enum State`:

```swift
    /// Loading lifecycle for the pending-request list — deliberately separate from `State`
    /// (see the design doc's rationale): pending availability is orthogonal to whether the
    /// main follower list loaded.
    enum PendingState: Equatable {
        case unknown
        case loading
        case loaded
        /// The upstream `GET <actor>/follow_requests` route 404s — not shipped yet. Never
        /// shown as an error; the pending section simply stays hidden.
        case unavailable
        case unreachable(String)
    }
```

4. Add stored properties, right after the existing `private var pendingQueue`/`saveTask`
   declarations:

```swift
    private(set) var pendingRows: [PendingRequestRow] = []
    private(set) var pendingState: PendingState = .unknown

    private var siteID: String?
    private let secretStore: any SecretStore
    private let membershipTransport: CommunityMembershipClient.Transport
    private var membershipClient: CommunityMembershipClient?
```

5. Update the initializer to accept the two new dependencies:

```swift
    init(
        fetcher: ActorProfileFetcher = ActorProfileFetcher(),
        avatarLoader: AvatarLoader = AvatarLoader(),
        followersTransport: @escaping ActivityPubFollowersClient.Transport
            = ActivityPubFollowersClient.defaultTransport,
        secretStore: any SecretStore = PlatformSecretStore.make(),
        membershipTransport: @escaping CommunityMembershipClient.Transport
            = CommunityMembershipClient.defaultTransport
    ) {
        self.fetcher = fetcher
        self.avatarLoader = avatarLoader
        self.followersTransport = followersTransport
        self.secretStore = secretStore
        self.membershipTransport = membershipTransport
    }
```

6. Update `configure(site:)` to record `siteID` (add one line before the existing
   `resolveSite()` call):

```swift
    func configure(site: CurrentSite) {
        configDirectory = site.configDirectory
        sourceDirectory = site.sourceDirectory
        siteID = site.id
        cache = ActorProfileCache.load(from: site.configDirectory) ?? ActorProfileCache()
        resolveSite()
    }
```

7. Update `resolveSite()` to also build `membershipClient` (replace its body):

```swift
    private func resolveSite() {
        guard let sourceDirectory else { return }
        siteURL = DeployCoordinator.resolveSiteURL(siteDirectory: sourceDirectory)
            .flatMap { URL(string: $0) }
        guard let siteURL else {
            client = nil
            actorURL = nil
            membershipClient = nil
            return
        }
        client = ActivityPubFollowersClient(siteURL: siteURL, transport: followersTransport)
        actorURL = ActivityPubActor.actorURL(siteURL: siteURL)
        membershipClient = publishToken.map { token in
            CommunityMembershipClient(ownActorURL: actorURL!, publishToken: token, transport: membershipTransport)
        }
    }

    private var publishToken: String? {
        guard let siteID else { return nil }
        return try? secretStore.read(account: SecretAccounts.activityPubPublishToken(siteID: siteID))
    }
```

8. Add `loadPending()`, in a new `// MARK: - Pending requests` section after the existing
   `// MARK: - Enrichment` section:

```swift

    // MARK: - Pending requests

    /// Fetches the pending-follow-request list from this site's own Worker. A 404 (the
    /// upstream capability not shipped yet) degrades to `.unavailable` with an empty list —
    /// never a user-facing error, mirroring `ModerationModel.loadPendingFollowers()`'s same
    /// rule against the same endpoint. No-ops (leaves `.unknown`) until `configure(site:)` has
    /// resolved a `membershipClient` — no site URL yet, or no publish token provisioned.
    func loadPending() async {
        guard let membershipClient else { return }
        pendingState = .loading
        do {
            let requests = try await membershipClient.listFollowRequests()
            pendingRows = requests.map { request in
                PendingRequestRow(request: request, profile: cache.profile(for: request.actor))
            }
            pendingState = .loaded
        } catch CommunityMembershipError.requestFailed(status: 404, body: _) {
            pendingRows = []
            pendingState = .unavailable
        } catch {
            // Additive, not destructive: a transient failure keeps whatever rows are already
            // on screen rather than blanking the section, matching `loadMoreFailure`'s rule
            // for the main list.
            pendingState = .unreachable("\(error)")
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter FollowersModelTests`
Expected: PASS. Also run the full app-core suite to confirm the `FollowerRow.displayName`
refactor didn't regress: `swift test --package-path . --filter AnglesiteAppTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/FollowersModel.swift Tests/AnglesiteAppTests/FollowersModelTests.swift
git commit -m "feat(#965): load pending follow requests in FollowersModel"
```

---

### Task 4: `FollowersModel` — accept/reject actions and enrichment

**Files:**
- Modify: `Sources/AnglesiteApp/FollowersModel.swift`
- Test: `Tests/AnglesiteAppTests/FollowersModelTests.swift`

**Interfaces:**
- Consumes: `CommunityMembershipClient.acceptFollow(target:)` (existing),
  `CommunityMembershipClient.rejectFollow(target:)` (Task 1), `PendingRequestRow`/`pendingRows`
  (Task 3).
- Produces: `FollowersModel.accept(_ row: PendingRequestRow) async`,
  `FollowersModel.reject(_ row: PendingRequestRow) async`, `FollowersModel.rejectConfirmation: PendingRequestRow?`,
  `FollowersModel.confirmReject() async`, `FollowersModel.pendingActionFailure: String?` — all
  consumed by `FollowersView` in Task 6.

- [ ] **Step 1: Write the failing test**

Append to the `// MARK: - Pending requests` section in `FollowersModelTests.swift`:

```swift

    @Test("accept POSTs Accept and removes the row from pendingRows")
    func acceptRemovesRow() async throws {
        let (site, root) = try Self.makeSite(siteURL: "https://example.com")
        defer { try? FileManager.default.removeItem(at: root) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"
        let membershipServer = MembershipServer(routes: [
            "/users/site/follow_requests": (
                200,
                Self.followRequestsBody(items: [("https://mastodon.social/users/alice", "2026-08-01T00:00:00.000Z")])
            ),
            "/users/site/outbox": (202, "{}"),
        ])
        let model = await Self.makeModelWithPending(
            server: Server(routes: [:]), membershipServer: membershipServer, secretStore: secretStore)
        model.configure(site: site)
        await model.loadPending()
        let row = try #require(model.pendingRows.first)

        await model.accept(row)

        #expect(model.pendingRows.isEmpty)
        let body = await membershipServer.requestedBodies.last
        #expect(body?["type"] as? String == "Accept")
        #expect(body?["object"] as? String == "https://mastodon.social/users/alice")
    }

    @Test("a failed accept restores the row and sets pendingActionFailure")
    func acceptFailureRestoresRow() async throws {
        let (site, root) = try Self.makeSite(siteURL: "https://example.com")
        defer { try? FileManager.default.removeItem(at: root) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"
        let membershipServer = MembershipServer(routes: [
            "/users/site/follow_requests": (
                200,
                Self.followRequestsBody(items: [("https://mastodon.social/users/alice", "2026-08-01T00:00:00.000Z")])
            ),
            "/users/site/outbox": (500, "server error"),
        ])
        let model = await Self.makeModelWithPending(
            server: Server(routes: [:]), membershipServer: membershipServer, secretStore: secretStore)
        model.configure(site: site)
        await model.loadPending()
        let row = try #require(model.pendingRows.first)

        await model.accept(row)

        #expect(model.pendingRows.count == 1)
        #expect(model.pendingActionFailure != nil)
    }

    @Test("reject is only sent through confirmReject, after rejectConfirmation is set")
    func rejectRequiresConfirmation() async throws {
        let (site, root) = try Self.makeSite(siteURL: "https://example.com")
        defer { try? FileManager.default.removeItem(at: root) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"
        let membershipServer = MembershipServer(routes: [
            "/users/site/follow_requests": (
                200,
                Self.followRequestsBody(items: [("https://mastodon.social/users/bob", "2026-08-01T00:00:00.000Z")])
            ),
            "/users/site/outbox": (202, "{}"),
        ])
        let model = await Self.makeModelWithPending(
            server: Server(routes: [:]), membershipServer: membershipServer, secretStore: secretStore)
        model.configure(site: site)
        await model.loadPending()
        let row = try #require(model.pendingRows.first)

        model.rejectConfirmation = row
        #expect(model.pendingRows.count == 1)  // unchanged until confirmed

        await model.confirmReject()

        #expect(model.pendingRows.isEmpty)
        #expect(model.rejectConfirmation == nil)
        let body = await membershipServer.requestedBodies.last
        #expect(body?["type"] as? String == "Reject")
        #expect(body?["object"] as? String == "https://mastodon.social/users/bob")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter FollowersModelTests`
Expected: FAIL — `value of type 'FollowersModel' has no member 'accept'` etc.

- [ ] **Step 3: Implement accept/reject**

In `Sources/AnglesiteApp/FollowersModel.swift`, add after `loadPending()`:

```swift

    var pendingActionFailure: String?
    /// Set by the view to arm the Reject confirmation dialog; cleared by whichever button runs
    /// (Reject or Cancel) — same no-op-setter/clear-in-button-action contract
    /// `ModerationModel.banConfirmation` already establishes.
    var rejectConfirmation: PendingRequestRow?

    /// Confirms a pending follower. Optimistically removes the row; a failure restores it
    /// (appended, not reinserted at its original position — pending lists are short enough
    /// that exact ordering after a failure isn't worth the extra bookkeeping) and reports
    /// `pendingActionFailure`, same additive-not-replacing shape as `loadMoreFailure`.
    func accept(_ row: PendingRequestRow) async {
        guard let membershipClient else { return }
        pendingRows.removeAll { $0.id == row.id }
        do {
            try await membershipClient.acceptFollow(target: row.request.actor)
        } catch {
            pendingRows.append(row)
            pendingActionFailure = "Couldn't accept \(row.displayName): \(error.localizedDescription)"
        }
    }

    /// Declines a pending follower. Never called directly by the view — only through
    /// ``confirmReject()``, after `rejectConfirmation` is armed, since Reject is destructive
    /// (mac-assed-app-spec §5).
    func reject(_ row: PendingRequestRow) async {
        guard let membershipClient else { return }
        pendingRows.removeAll { $0.id == row.id }
        do {
            try await membershipClient.rejectFollow(target: row.request.actor)
        } catch {
            pendingRows.append(row)
            pendingActionFailure = "Couldn't reject \(row.displayName): \(error.localizedDescription)"
        }
    }

    func confirmReject() async {
        guard let row = rejectConfirmation else { return }
        rejectConfirmation = nil
        await reject(row)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter FollowersModelTests`
Expected: PASS

- [ ] **Step 5: Write the failing test for shared enrichment**

Append to `FollowersModelTests.swift`:

```swift

    @Test("enrichIfNeeded also fills in a pending row's profile")
    func enrichmentCoversPendingRows() async throws {
        let (site, root) = try Self.makeSite(siteURL: "https://example.com")
        defer { try? FileManager.default.removeItem(at: root) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"
        let actor = try #require(URL(string: "https://mastodon.social/users/alice"))
        let membershipServer = MembershipServer(routes: [
            "/users/site/follow_requests": (
                200, Self.followRequestsBody(items: [(actor.absoluteString, "2026-08-01T00:00:00.000Z")])
            )
        ])
        let profile = ActorProfile(
            actor: actor, preferredUsername: "alice", name: "Alice", iconURL: nil, fetchedAt: Date())
        let model = FollowersModel(
            fetcher: ActorProfileFetcher(transport: { _ in
                (try JSONEncoder().encode(profile), HTTPURLResponse(
                    url: actor, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }),
            avatarLoader: AvatarLoader(transport: { _ in throw AvatarLoadError.requestFailed(status: 500) }),
            followersTransport: { _ in
                (Data(), HTTPURLResponse(url: actor, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            },
            secretStore: secretStore,
            membershipTransport: await membershipServer.transport)
        model.configure(site: site)
        await model.loadPending()
        #expect(model.pendingRows.first?.profile == nil)

        model.enrichIfNeeded(actor)
        // enrichIfNeeded fires a detached Task; give it a beat to land.
        for _ in 0..<50 where model.pendingRows.first?.profile == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.pendingRows.first?.profile?.name == "Alice")
    }
```

- [ ] **Step 6: Run test to verify it fails**

Run: `swift test --package-path . --filter FollowersModelTests/enrichmentCoversPendingRows`
Expected: FAIL — `pendingRows.first?.profile` stays `nil` (enrichment only updates `rows` today)

- [ ] **Step 7: Generalize enrichment to cover `pendingRows`**

In `Sources/AnglesiteApp/FollowersModel.swift`, update `enrichIfNeeded(_:)` and
`finishEnrichment(_:profile:)`:

```swift
    func enrichIfNeeded(_ actor: URL) {
        let key = actor.absoluteString
        let alreadyKnown = rows.first(where: { $0.actor == actor })?.profile != nil
            || pendingRows.first(where: { $0.request.actor == actor })?.profile != nil
        guard !alreadyKnown, !inFlight.contains(key), !queued.contains(key), !unreachableActors.contains(key)
        else { return }
        queued.insert(key)
        pendingQueue.append(actor)
        pumpQueue()
    }
```

```swift
    private func finishEnrichment(_ actor: URL, profile: ActorProfile?) {
        let key = actor.absoluteString
        inFlight.remove(key)
        if let profile {
            cache.store(profile)
            if let index = rows.firstIndex(where: { $0.actor == actor }) {
                rows[index].profile = profile
            }
            if let index = pendingRows.firstIndex(where: { $0.request.actor == actor }) {
                pendingRows[index].profile = profile
            }
            scheduleCacheSave()
        } else {
            unreachableActors.insert(key)
        }
        pumpQueue()
    }
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `swift test --package-path . --filter FollowersModelTests`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add Sources/AnglesiteApp/FollowersModel.swift Tests/AnglesiteAppTests/FollowersModelTests.swift
git commit -m "feat(#965): accept/reject pending follow requests in FollowersModel"
```

---

### Task 5: `FollowersModel` — background polling and new-request notification hook

**Files:**
- Modify: `Sources/AnglesiteApp/FollowersModel.swift`
- Test: `Tests/AnglesiteAppTests/FollowersModelTests.swift`

**Interfaces:**
- Produces: `FollowersModel.startPendingPollingIfNeeded()`, `FollowersModel.stopPendingPolling()`,
  `FollowersModel.onNewPendingRequests: ((String, Int) -> Void)?` — consumed by
  `SiteWindowModel`/`CompletionNotificationHub` in Task 7. An init parameter
  `pendingPollInterval: Duration = .seconds(300)` makes the interval testable.

- [ ] **Step 1: Write the failing test**

Append to `FollowersModelTests.swift`:

```swift

    @Test("the first loadPending establishes a baseline without notifying")
    func firstLoadDoesNotNotify() async throws {
        let (site, root) = try Self.makeSite(siteURL: "https://example.com")
        defer { try? FileManager.default.removeItem(at: root) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"
        let membershipServer = MembershipServer(routes: [
            "/users/site/follow_requests": (
                200, Self.followRequestsBody(items: [("https://mastodon.social/users/alice", "2026-08-01T00:00:00.000Z")])
            )
        ])
        let model = await Self.makeModelWithPending(
            server: Server(routes: [:]), membershipServer: membershipServer, secretStore: secretStore)
        model.configure(site: site)
        let recorder = Recorder()
        model.onNewPendingRequests = { siteID, count in Task { await recorder.record((siteID, count)) } }

        await model.loadPending()

        try await Task.sleep(for: .milliseconds(20))
        let notified = await recorder.events
        #expect(notified.isEmpty)
    }

    @Test("a later poll notifies once when the pending count grows past the baseline")
    func laterPollNotifiesOnGrowth() async throws {
        let (site, root) = try Self.makeSite(siteURL: "https://example.com")
        defer { try? FileManager.default.removeItem(at: root) }
        let secretStore = InMemorySecretStore()
        secretStore.values[SecretAccounts.activityPubPublishToken(siteID: "site-1")] = "token"
        let membershipServer = MembershipServer(routes: [
            "/users/site/follow_requests": (
                200, Self.followRequestsBody(items: [("https://mastodon.social/users/alice", "2026-08-01T00:00:00.000Z")])
            )
        ])
        let model = FollowersModel(
            fetcher: ActorProfileFetcher(transport: { _ in throw ActorProfileError.requestFailed(status: 500) }),
            avatarLoader: AvatarLoader(transport: { _ in throw AvatarLoadError.requestFailed(status: 500) }),
            followersTransport: { _ in
                (Data(), HTTPURLResponse(
                    url: URL(string: "https://example.com")!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            },
            secretStore: secretStore,
            membershipTransport: await membershipServer.transport,
            pendingPollInterval: .milliseconds(20))
        model.configure(site: site)
        let recorder = Recorder()
        model.onNewPendingRequests = { siteID, count in Task { await recorder.record((siteID, count)) } }
        await model.loadPending()  // establishes the baseline of 1, as in the test above

        await membershipServer.setRoute(
            "/users/site/follow_requests", status: 200,
            body: Self.followRequestsBody(items: [
                ("https://mastodon.social/users/alice", "2026-08-01T00:00:00.000Z"),
                ("https://mastodon.social/users/carol", "2026-08-02T00:00:00.000Z"),
            ]))
        model.startPendingPollingIfNeeded()
        defer { model.stopPendingPolling() }

        var events: [(String, Int)] = []
        for _ in 0..<50 where events.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            events = await recorder.events
        }

        #expect(events == [("site-1", 2)])
    }
```

Add the `Recorder` actor as a private nested type in `FollowersModelTests` (near the other
fixtures, e.g. right after `InMemorySecretStore`):

```swift
    private actor Recorder {
        private(set) var events: [(String, Int)] = []
        func record(_ event: (String, Int)) { events.append(event) }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter FollowersModelTests`
Expected: FAIL — no `onNewPendingRequests`, no `startPendingPollingIfNeeded`/`stopPendingPolling`,
no `pendingPollInterval` init parameter.

- [ ] **Step 3: Implement polling and the notification hook**

In `Sources/AnglesiteApp/FollowersModel.swift`:

1. Add stored properties after `membershipClient`:

```swift
    private var pollTask: Task<Void, Never>?
    private var lastNotifiedPendingCount = 0
    private var hasEstablishedPendingBaseline = false
    private let pendingPollInterval: Duration

    /// Fired with the current total pending count whenever a `loadPending()` finds it greater
    /// than the last count this fired for. The *first* `loadPending()` per model instance only
    /// establishes the baseline — it never fires on its own (a relaunch must not re-notify
    /// about requests the owner has already seen and simply hasn't acted on yet).
    var onNewPendingRequests: ((String, Int) -> Void)?
```

2. Update the initializer to accept `pendingPollInterval`:

```swift
    init(
        fetcher: ActorProfileFetcher = ActorProfileFetcher(),
        avatarLoader: AvatarLoader = AvatarLoader(),
        followersTransport: @escaping ActivityPubFollowersClient.Transport
            = ActivityPubFollowersClient.defaultTransport,
        secretStore: any SecretStore = PlatformSecretStore.make(),
        membershipTransport: @escaping CommunityMembershipClient.Transport
            = CommunityMembershipClient.defaultTransport,
        pendingPollInterval: Duration = .seconds(300)
    ) {
        self.fetcher = fetcher
        self.avatarLoader = avatarLoader
        self.followersTransport = followersTransport
        self.secretStore = secretStore
        self.membershipTransport = membershipTransport
        self.pendingPollInterval = pendingPollInterval
    }
```

3. Update `loadPending()`'s success branch to call the new notify step, and add the polling
   methods + `notifyIfNewRequestsArrived()` right after it:

```swift
    func loadPending() async {
        guard let membershipClient else { return }
        pendingState = .loading
        do {
            let requests = try await membershipClient.listFollowRequests()
            pendingRows = requests.map { request in
                PendingRequestRow(request: request, profile: cache.profile(for: request.actor))
            }
            pendingState = .loaded
            notifyIfNewRequestsArrived()
        } catch CommunityMembershipError.requestFailed(status: 404, body: _) {
            pendingRows = []
            pendingState = .unavailable
        } catch {
            pendingState = .unreachable("\(error)")
        }
    }

    private func notifyIfNewRequestsArrived() {
        guard let siteID else { return }
        defer { hasEstablishedPendingBaseline = true }
        guard hasEstablishedPendingBaseline, pendingRows.count > lastNotifiedPendingCount else {
            lastNotifiedPendingCount = pendingRows.count
            return
        }
        lastNotifiedPendingCount = pendingRows.count
        onNewPendingRequests?(siteID, pendingRows.count)
    }

    /// Starts the recurring background recheck, idempotently — a second call (e.g. a window
    /// replayed onto a different site) is a no-op; `loadPending()` always reads the *current*
    /// `membershipClient`/`siteID` at call time, so the one running loop naturally picks up a
    /// replayed site's data on its next tick. Callers that want fresher data immediately after
    /// a replay should `await loadPending()` explicitly (this method only owns the recurring
    /// timer, not an immediate fetch — see `SiteWindowModel.loadAndStart`).
    func startPendingPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let interval = self?.pendingPollInterval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.loadPending()
            }
        }
    }

    /// Stops the recurring recheck — called from `SiteWindowModel.close()`.
    func stopPendingPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter FollowersModelTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/FollowersModel.swift Tests/AnglesiteAppTests/FollowersModelTests.swift
git commit -m "feat(#965): poll for new pending follow requests while a site window is open"
```

---

### Task 6: `FollowersView` — Pending Requests section

**Files:**
- Modify: `Sources/AnglesiteApp/FollowersView.swift`

**Interfaces:**
- Consumes: `FollowersModel.pendingRows`, `.pendingState`, `.pendingActionFailure`,
  `.rejectConfirmation`, `.accept(_:)`, `.reject(_:)` (unused directly by the view — only
  `confirmReject()` is), `.confirmReject()`, `.enrichIfNeeded(_:)` (all from Tasks 3-5).

- [ ] **Step 1: Restructure `body` so the pending section renders regardless of the main list's `State`**

In `Sources/AnglesiteApp/FollowersView.swift`, replace `var body: some View { ... }`:

```swift
    var body: some View {
        VStack(spacing: 0) {
            pendingSection
            Group {
                switch followers.state {
                case .idle, .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded:
                    loadedContent
                case .noSiteURL:
                    message(
                        "This site hasn't been published yet",
                        detail: Text("Publish it at least once, then followers will appear here."))
                case .notActivated:
                    message(
                        "The Fediverse isn't turned on for this site",
                        detail: Text("Turn on the Fediverse in Settings ▸ Workers, then publish again."))
                case .unreachable(let reason):
                    // `reason` is server-supplied (HTTP body / error description) — untrusted remote
                    // content, never a localization key or format string. `Text(reason)` binds to the
                    // `StringProtocol` overload and renders it verbatim.
                    message("Couldn't reach this site", detail: Text(reason))
                }
            }
        }
        .navigationSubtitle("Followers")
        .task { if followers.state == .idle { await followers.load() } }
        .onDisappear { followers.saveCacheNow() }
        .confirmationDialog(
            "Reject this follow request?",
            isPresented: Binding(get: { followers.rejectConfirmation != nil }, set: { _ in }),
            titleVisibility: .visible
        ) {
            Button("Reject", role: .destructive) { Task { await followers.confirmReject() } }
            Button("Cancel", role: .cancel) { followers.rejectConfirmation = nil }
        } message: {
            Text("This declines the follow request from \(followers.rejectConfirmation?.displayName ?? "this requester").")
        }
    }
```

- [ ] **Step 2: Add the pending section and row views**

Add these new views right after `body`, before the existing `loadedContent` computed property:

```swift

    @ViewBuilder
    private var pendingSection: some View {
        // Hidden entirely when there's nothing to show — no error noise for a capability that
        // hasn't shipped upstream yet (`.unavailable`), no dead space for a site with nothing
        // pending. Deliberately independent of `followers.state`: pending arrives from its own
        // background poll and may be known before the main list ever loads.
        if !followers.pendingRows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Pending Requests (\(followers.pendingRows.count))")
                    .font(.headline)
                    .padding()
                List {
                    ForEach(followers.pendingRows) { row in
                        pendingRow(row)
                    }
                    if let failure = followers.pendingActionFailure {
                        Text(failure).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: min(CGFloat(followers.pendingRows.count) * 44 + 16, 220))
                Divider()
            }
        }
    }

    @ViewBuilder
    private func pendingRow(_ row: PendingRequestRow) -> some View {
        HStack(spacing: 10) {
            avatar(iconURL: row.profile?.iconURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName).font(.headline).lineLimit(1)
                Text(row.handle ?? row.request.actor.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Accept") { Task { await followers.accept(row) } }
                .accessibilityLabel("Accept follow request from \(row.displayName)")
            Button("Reject", role: .destructive) { followers.rejectConfirmation = row }
                .accessibilityLabel("Reject follow request from \(row.displayName)")
        }
        .padding(.vertical, 2)
        .task { followers.enrichIfNeeded(row.request.actor) }
    }
```

- [ ] **Step 3: Generalize the existing `avatar(for:)` helper so both rows can use it**

Replace the existing `avatar(for:)` method:

```swift
    @ViewBuilder
    private func avatar(for row: FollowerRow) -> some View {
        FollowerAvatar(url: row.profile?.iconURL, loader: followers.avatarLoader)
    }
```

with a version keyed on the icon URL alone, and update its one existing call site
(`avatar(for: row)` inside `followerRow(_:)`) to `avatar(iconURL: row.profile?.iconURL)`:

```swift
    @ViewBuilder
    private func avatar(iconURL: URL?) -> some View {
        FollowerAvatar(url: iconURL, loader: followers.avatarLoader)
    }
```

- [ ] **Step 4: Build the app target**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED. `FollowersView` isn't covered by `swift test` (it's a View, not a
tested model), so this build is this task's verification.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/FollowersView.swift
git commit -m "feat(#965): surface pending follow requests in FollowersView"
```

---

### Task 7: Wire polling lifecycle and the completion notification

**Files:**
- Modify: `Sources/AnglesiteApp/CompletionNotificationHub.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift`

**Interfaces:**
- Consumes: `FollowersModel.onNewPendingRequests`, `.loadPending()`,
  `.startPendingPollingIfNeeded()`, `.stopPendingPolling()` (Tasks 3-5),
  `CompletionNoticeBuilder.followRequest(siteName:siteID:count:)` (Task 2).

- [ ] **Step 1: Wire the notification hook in `CompletionNotificationHub`**

In `Sources/AnglesiteApp/CompletionNotificationHub.swift`, change the `wire` signature and add
the `followers` wiring at the end of the function body, right before its closing `}`:

```swift
    static func wire(deploy: DeployModel, backup: BackupModel, audit: AuditModel, followers: FollowersModel) {
```

```swift
        followers.onNewPendingRequests = { siteID, count in
            postNotice(siteID: siteID) { name in
                CompletionNoticeBuilder.followRequest(siteName: name, siteID: siteID, count: count)
            }
        }
    }
```

- [ ] **Step 2: Update the `SiteWindowModel` call site and lifecycle hooks**

In `Sources/AnglesiteApp/SiteWindowModel.swift`:

1. Update the `wire` call (currently `CompletionNotificationHub.wire(deploy: deploy, backup: backup, audit: audit)`):

```swift
        CompletionNotificationHub.wire(deploy: deploy, backup: backup, audit: audit, followers: followers)
```

2. In `loadAndStart(...)`, right after the existing `followers.configure(site: currentSite)`
   line, add:

```swift
        followers.configure(site: currentSite)
        await followers.loadPending()
        followers.startPendingPollingIfNeeded()
```

3. In `close(suddenTerminationLease:)`, add a line alongside the existing
   `stopInvisiblePublishing()`/`sync.stop()`/`preview.close()`/`startup.stop()` calls:

```swift
    func close(suddenTerminationLease: SuddenTerminationController.Lease? = nil) {
        stopInvisiblePublishing()
        followers.stopPendingPolling()
        sync.stop()
        preview.close()
        startup.stop()
```

- [ ] **Step 3: Build and run the full suite**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED

Run: `swift test --package-path .`
Expected: all suites PASS, including the untouched `AnglesiteCoreTests`/`AnglesiteAppTests`
suites (regression check).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/CompletionNotificationHub.swift Sources/AnglesiteApp/SiteWindowModel.swift
git commit -m "feat(#965): start/stop pending-follower polling with the site window"
```

---

## Final verification (not a task — run before opening the PR)

- [ ] `swift test --package-path .` — full suite green.
- [ ] `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` — green.
- [ ] Manually open a site in the app, open Website ▸ Followers…, confirm the pane still loads
  the existing public follower list unchanged, and that no "Pending Requests" section appears
  for a site whose Worker doesn't yet expose `follow_requests` (expected — matches the 404 →
  `.unavailable` degrade).
- [ ] PR body: note the still-missing upstream piece (externally bearer-gated
  `GET <actor>/follow_requests` — `CommunityMembershipClient.listFollowRequests()`'s existing
  doc comment on this) as a pending `davidwkeith/workers` dependency, per
  `CONTRIBUTING.md` ▸ "`@dwk/workers` catalog coordination." This PR does not block on it.

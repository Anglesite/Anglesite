import Foundation
import Observation
import AnglesiteCore

/// One row in the Followers pane. `profile` is `nil` until enrichment lands (or forever, if the
/// follower's instance is unreachable) — `displayName` degrades gracefully either way.
struct FollowerRow: Identifiable, Equatable {
    let actor: URL
    var profile: ActorProfile?

    var id: String { actor.absoluteString }

    /// `@alice@mastodon.social`, or `nil` for an IRI shape `ActorHandle` doesn't recognize.
    var handle: String? { ActorHandle.derive(from: actor) }

    /// Never empty: the fetched display name, else the fetched username, else the derived
    /// handle, else the raw IRI. This chain is why a failed profile fetch needs no error state.
    var displayName: String { ActorDisplay.name(profile: profile, handle: handle, actor: actor) }
}

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

/// Drives the Followers pane (Website ▸ Followers…, V-4.2 #364): reads the site's own public
/// ActivityPub followers collection and enriches rows with each follower's display identity.
/// App glue only — protocol logic, parsing, and the security guards live in `AnglesiteCore`.
@MainActor
@Observable
final class FollowersModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        /// No public URL — the site has never been published.
        case noSiteURL
        /// The Worker answered 503: ActivityPub isn't activated for this site.
        case notActivated
        /// 404 or a transport failure: unreachable, or the Worker isn't deployed.
        case unreachable(String)
    }

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

    /// Bounded so a site with thousands of followers doesn't fan out thousands of sockets.
    private static let maxConcurrentEnrichments = 4

    private(set) var state: State = .idle
    private(set) var rows: [FollowerRow] = []
    private(set) var totalItems = 0
    /// The actor URL to paste into Mastodon search — shown in the empty state, since WebFinger
    /// (#366) hasn't shipped and this is the only way to find the site.
    private(set) var actorURL: URL?
    /// A "Load More" failure, surfaced *beside* the list rather than replacing it. Paging is an
    /// additive operation: flipping `state` to an error the way `load()` does would hide every
    /// row already fetched, with nothing left on screen to get them back.
    private(set) var loadMoreFailure: String?
    /// Disables "Load More" while a page is in flight. Two rapid clicks would otherwise both pass
    /// the guard (`state` doesn't change during paging), fetch the same `nextPage`, and append the
    /// same items — and `FollowerRow.id` is the actor IRI, so `ForEach` would see duplicate IDs,
    /// which SwiftUI documents as undefined behavior.
    private(set) var isLoadingMore = false

    private var siteURL: URL?
    private var sourceDirectory: URL?
    private var configDirectory: URL?
    private var client: ActivityPubFollowersClient?
    private var nextPage: URL?
    /// Bumped by every `load()`. An in-flight page checks it after each `await` and discards
    /// itself if it no longer matches, so a request that started before a `refresh()` can't append
    /// its stale items to the freshly-reset `rows`.
    private var generation = 0

    private let fetcher: ActorProfileFetcher
    /// The client is rebuilt whenever the site URL is re-resolved, so the transport — not a
    /// prebuilt client — is what gets injected.
    private let followersTransport: ActivityPubFollowersClient.Transport
    /// Avatars go through `AnglesiteCore`'s capped loader rather than `AsyncImage` — see
    /// `AvatarLoader`. Held here (not built per row) so tests and previews can inject one.
    let avatarLoader: AvatarLoader
    private var cache = ActorProfileCache()
    private var inFlight: Set<String> = []
    private var queued: Set<String> = []
    /// Actor keys whose enrichment already failed this session. Without this, a row that scrolls
    /// out of the `List` and back in re-triggers its `.task` and re-enqueues a fetch — so an
    /// unreachable (or hostile, or merely slow) follower instance would get re-pinged every time
    /// its row is realized, for the life of the window. That's an unbounded retry storm against
    /// exactly the servers the concurrency cap and 7-day cache exist to protect. Session-scoped
    /// (never persisted): `refresh()` clears it, since that's the user's deliberate escape hatch
    /// for "try again" once a flaky instance comes back up.
    private var unreachableActors: Set<String> = []
    private var pendingQueue: [URL] = []
    private var saveTask: Task<Void, Never>?

    private(set) var pendingRows: [PendingRequestRow] = []
    private(set) var pendingState: PendingState = .unknown

    private var siteID: String?
    private let secretStore: any SecretStore
    private let membershipTransport: CommunityMembershipClient.Transport
    private var membershipClient: CommunityMembershipClient?

    private var pollTask: Task<Void, Never>?
    private var lastNotifiedPendingCount = 0
    private var hasEstablishedPendingBaseline = false
    private let pendingPollInterval: Duration

    /// Fired with the current total pending count whenever a `loadPending()` finds it greater
    /// than the last count this fired for. The *first* `loadPending()` per model instance only
    /// establishes the baseline — it never fires on its own (a relaunch must not re-notify
    /// about requests the owner has already seen and simply hasn't acted on yet).
    var onNewPendingRequests: ((String, Int) -> Void)?

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

    var canLoadMore: Bool { nextPage != nil && state == .loaded }

    /// Records which site this pane reads and warms the profile cache from disk. No network I/O.
    /// Called once per site open from `SiteWindowModel.loadAndStart()`, like `reader.configure`.
    func configure(site: CurrentSite) {
        configDirectory = site.configDirectory
        sourceDirectory = site.sourceDirectory
        siteID = site.id
        cache = ActorProfileCache.load(from: site.configDirectory) ?? ActorProfileCache()
        resolveSite()
    }

    /// Re-reads the site's public URL from its `.site-config` and rebuilds the client around it.
    ///
    /// Split out of ``configure(site:)`` — which runs once per site open, from
    /// `SiteWindowModel.loadAndStart()` — so ``retry()`` can run it again without needing a
    /// `CurrentSite`. Without that, the `.noSiteURL` state is a dead end: it tells the owner to
    /// publish the site, and then can never notice that they did, because nothing re-resolves the
    /// URL until the window is closed and reopened. Still no network I/O — this reads one local
    /// config file, exactly as `configure` always did.
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

    /// The error states' Try Again. Re-resolves the site before reloading, so publishing the site
    /// (`.noSiteURL`) or turning ActivityPub on and republishing (`.notActivated`) is recoverable
    /// from within the pane.
    func retry() async {
        resolveSite()
        await refresh()
    }

    /// Loads the collection head and its first page. Safe to call repeatedly; it no-ops while
    /// already loading.
    func load() async {
        guard state != .loading else { return }
        guard let client else { state = .noSiteURL; return }

        generation &+= 1
        let token = generation
        state = .loading
        rows = []
        nextPage = nil
        totalItems = 0
        loadMoreFailure = nil
        do {
            let collection = try await client.collection()
            guard token == generation else { return }
            totalItems = collection.totalItems
            guard let firstPage = collection.firstPage else {
                // No `first` link means an empty collection — the genuine zero-followers state.
                state = .loaded
                return
            }
            let page = try await client.page(at: firstPage)
            guard token == generation else { return }
            rows = page.items.map { FollowerRow(actor: $0, profile: cache.profile(for: $0)) }
            nextPage = page.next
            state = .loaded
        } catch {
            guard token == generation else { return }
            state = Self.failureState(for: error)
        }
    }

    /// Appends the next page. Unlike ``load()`` this never changes `state`: a paging failure is
    /// reported through ``loadMoreFailure`` so the rows already on screen stay on screen.
    func loadMore() async {
        guard let client, let page = nextPage, state == .loaded, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreFailure = nil
        let token = generation
        defer { isLoadingMore = false }
        do {
            let next = try await client.page(at: page)
            // A `refresh()` may have landed while this page was in flight; appending now would
            // duplicate IDs into the reset list.
            guard token == generation else { return }
            rows.append(contentsOf: next.items.map {
                FollowerRow(actor: $0, profile: cache.profile(for: $0))
            })
            nextPage = next.next
        } catch {
            guard token == generation else { return }
            loadMoreFailure = Self.failureMessage(for: error)
        }
    }

    func refresh() async {
        state = .idle
        // The user's explicit escape hatch for a flaky follower instance: give every previously
        // failed actor a fresh attempt instead of honoring the session-scoped failure memory.
        unreachableActors.removeAll()
        await load()
    }

    private static func failureState(for error: Error) -> State {
        guard case let ActivityPubFollowersError.requestFailed(status, body) = error else {
            return .unreachable("\(error)")
        }
        switch status {
        case 503: return .notActivated
        default: return .unreachable(body.isEmpty ? "HTTP \(status)" : body)
        }
    }

    /// The paging equivalent of ``failureState(for:)``: paging can't meaningfully re-diagnose the
    /// site (the collection head already loaded), so every failure is one line of detail.
    /// `ActivityPubFollowersClient` bounds `body` before it gets here.
    private static func failureMessage(for error: Error) -> String {
        guard case let ActivityPubFollowersError.requestFailed(status, body) = error else {
            return "\(error)"
        }
        return body.isEmpty ? "HTTP \(status)" : body
    }

    // MARK: - Enrichment

    /// Requests this row's display identity if it isn't already known or in flight. Called from
    /// each visible row's `.task`, so only rows the owner actually scrolls to cost a request.
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

    private func pumpQueue() {
        while inFlight.count < Self.maxConcurrentEnrichments, !pendingQueue.isEmpty {
            let actor = pendingQueue.removeFirst()
            queued.remove(actor.absoluteString)
            inFlight.insert(actor.absoluteString)
            Task { [fetcher] in
                // Every failure mode — unreachable instance, 404, oversize body, insecure
                // redirect — is non-fatal: the row keeps its derived handle.
                let profile = try? await fetcher.profile(for: actor)
                self.finishEnrichment(actor, profile: profile)
            }
        }
    }

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
            notifyIfNewRequestsArrived()
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
    private func reject(_ row: PendingRequestRow) async {
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

    // MARK: - Cache persistence

    /// Debounced rather than save-on-close so a quit, crash, or window close that never runs the
    /// disappear hook still leaves a warm cache — the enrichment work is wasted otherwise.
    ///
    /// `Task.detached`, not `Task`: a plain `Task` created inside a `@MainActor` type *inherits*
    /// MainActor isolation, which would put `createDirectory` plus a full pretty-printed,
    /// sorted-keys encode and atomic write on the main thread every two seconds for as long as
    /// enrichment keeps streaming in. Detaching is safe here precisely because the closure
    /// captures a *value copy* of the cache — `ActorProfileCache` is a `Sendable` struct, so the
    /// snapshot can't be mutated out from under the write.
    private func scheduleCacheSave() {
        saveTask?.cancel()
        saveTask = Task.detached(priority: .utility) { [cache, configDirectory] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let configDirectory else { return }
            try? cache.save(to: configDirectory)
        }
    }

    func saveCacheNow() {
        saveTask?.cancel()
        guard let configDirectory else { return }
        try? cache.save(to: configDirectory)
    }
}

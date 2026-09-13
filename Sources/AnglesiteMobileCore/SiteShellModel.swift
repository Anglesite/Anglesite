import Foundation
import Observation
import AnglesiteCore
import AnglesiteIOS

/// The iOS shell's orchestration state (#869, design §3), split out of `SiteSplitScreen` so it
/// runs under `swift test` (#1968): which site is selected and how that resets the content
/// filter and composer selection; how a site's Micropub session resolves into a post list (or
/// the sign-in pane); position persistence and restore across relaunch (#1436); the one
/// "Edit Site" session model per site and the warm-session bookkeeping behind the
/// "Continue editing…" offer; and the App Intent hand-off through `EditSessionRouter`.
///
/// SwiftUI still drives the triggers — `SiteSplitScreen` forwards discovery results, calls
/// `resolveSession()` from `.task(id:)`, and reports post-list state changes — because those
/// originate in view lifecycle. Everything the triggers *do* lives here.
@MainActor
@Observable
public final class SiteShellModel {
    /// The selected site's session pane state — re-resolved whenever the site changes.
    public enum SessionState: Equatable, Sendable {
        /// No site selected.
        case none
        /// `resolveSession()` in flight (or a site switch awaiting it).
        case checking
        /// No stored credential — the sign-in pane shows.
        case signedOut
        /// Session resolved; ``postList`` and ``session`` are set.
        case ready
    }

    /// One `List` selection over the sidebar's two sections: picking a site switches sites
    /// (resetting the type filter); picking a content row narrows the post list.
    public enum SidebarSelection: Hashable, Sendable {
        case site(UUID)
        case allPosts
        case type(String)
    }

    /// Owns which site is selected and persists it.
    public let siteSelection: SiteSelectionModel
    /// Persists/restores the content-type filter, post selection, and warm-session set.
    public let restoration: NavigationRestorationModel
    /// The content-type registry the sidebar and composer read.
    public let registry: ContentTypeRegistry

    /// The sites discovery last produced (empty until it settles, or when it found none).
    public private(set) var discoveredSites: [SitePickerModel.DiscoveredSite] = []
    /// The sidebar's content-type filter: a registry type id, or `nil` for "All Posts".
    public var selectedTypeID: String?
    /// The composer column's selection.
    public var selection: PostListItemSelection?
    /// A restored `.existing(postURL:)` selection waiting for the post list to load so it can
    /// resolve into a real `PostListModel.Item` — cleared once applied or found stale.
    public private(set) var pendingRestoredPostURL: URL?
    /// See ``SessionState``.
    public private(set) var sessionState: SessionState = .none
    /// The resolved session's post list, rebuilt per site.
    public private(set) var postList: PostListModel?
    /// The resolved session, rebuilt per site.
    public private(set) var session: MicropubSession?
    /// One "Edit Site" session model per site, kept for the shell's lifetime (#1431): the
    /// full-screen cover only *renders* a session, so dismissing it leaves the model — and its
    /// warm P2P session — untouched, and switching sites never tears another site's session down.
    public private(set) var editSessions: [UUID: EditSessionModel] = [:]
    /// The site whose session cover is presented, or `nil` when none is.
    public var editingSite: SitePickerModel.DiscoveredSite?

    /// The App Intent hand-off the shell consumes requests from; the view observes its
    /// `requestedSiteID` and calls ``handleEditSessionRequest()``.
    public let editSessionRouter: EditSessionRouter

    private let sessions: any MicropubSessionProviding
    private let clientTransport: MicropubClient.Transport
    private let pairedMacs: () throws -> [PairedDevice]
    private let makeEditRuntime: @MainActor () -> any SiteRuntime

    /// Creates the shell model.
    ///
    /// - Parameters:
    ///   - sessions: The session source; production is `StoredMicropubSessions`.
    ///   - siteSelection: Site choice + persistence; tests pass one over temporary defaults.
    ///   - restoration: Position + warm-session persistence; tests pass one over temporary defaults.
    ///   - registry: The content-type registry.
    ///   - editSessionRouter: The App Intent hand-off; `.shared` in production.
    ///   - pairedMacs: `PairedDeviceStore().load` in production; feeds each `EditSessionModel`.
    ///   - makeEditRuntime: Builds an "Edit Site" session's runtime. Production hands out
    ///     `PendingP2PSiteRuntime` until #1208 P4 ships the real `P2PSiteRuntime`.
    ///   - clientTransport: The transport for the post list's Micropub client; tests fake it.
    public init(
        sessions: any MicropubSessionProviding,
        siteSelection: SiteSelectionModel = SiteSelectionModel(),
        restoration: NavigationRestorationModel = NavigationRestorationModel(),
        registry: ContentTypeRegistry = .default,
        editSessionRouter: EditSessionRouter = .shared,
        pairedMacs: @escaping () throws -> [PairedDevice] = { try PairedDeviceStore().load() },
        makeEditRuntime: @escaping @MainActor () -> any SiteRuntime = { PendingP2PSiteRuntime() },
        clientTransport: @escaping MicropubClient.Transport = MicropubClient.defaultTransport
    ) {
        self.sessions = sessions
        self.siteSelection = siteSelection
        self.restoration = restoration
        self.registry = registry
        self.editSessionRouter = editSessionRouter
        self.pairedMacs = pairedMacs
        self.makeEditRuntime = makeEditRuntime
        self.clientTransport = clientTransport
    }

    // MARK: - Derived state

    /// The selected site, if any.
    public var selectedSite: SitePickerModel.DiscoveredSite? { siteSelection.selectedSite }

    /// The content types a phone can post: collection-stored (post-family) descriptors.
    /// Pages and singletons (business profile, résumé) are site-editing, not posting — v2.0
    /// scope (#66/#71).
    public var postTypes: [ContentTypeDescriptor] {
        registry.all.filter { $0.collection != nil }
    }

    /// The descriptor behind the content pane's title, or `nil` for "All Posts".
    public var contentTitleDescriptor: ContentTypeDescriptor? {
        selectedTypeID.flatMap { registry.descriptor(id: $0) }
    }

    /// The collection the post list filters to (`nil` = every post).
    public var selectedCollection: String? {
        selectedTypeID.flatMap { registry.descriptor(id: $0)?.collection }
    }

    /// The sites `restoration` remembers as warm, resolved against the currently-discovered
    /// site list — a persisted ID for a site that's since vanished (deleted, not yet synced)
    /// resolves to nothing, same as `SiteSelectionModel.restoreSelection`'s handling of that case.
    public var warmSites: [SitePickerModel.DiscoveredSite] {
        discoveredSites.filter { restoration.warmSessionIDs.contains($0.id) }
    }

    /// The sidebar `List`'s current selection, derived from the type filter and site.
    public var sidebarSelection: SidebarSelection? {
        if let selectedTypeID { return .type(selectedTypeID) }
        if siteSelection.selectedSite != nil { return .allPosts }
        return nil
    }

    /// Applies a sidebar `List` selection.
    ///
    /// - Parameter newValue: The tapped row, or `nil` for a cleared selection (ignored).
    public func select(sidebar newValue: SidebarSelection?) {
        switch newValue {
        case .site(let id):
            guard let site = discoveredSites.first(where: { $0.id == id }) else { return }
            selectSite(site)
        case .allPosts:
            selectedTypeID = nil
        case .type(let id):
            selectedTypeID = id
        case nil:
            break
        }
    }

    // MARK: - Discovery and sessions

    /// Applies a discovery result. Only the cold-launch restore (no prior selection) re-applies
    /// a saved position — an interactive site switch already resets the filter/selection itself.
    ///
    /// - Parameter state: `SitePickerModel.state` after a refresh.
    public func discoverySettled(_ state: SitePickerModel.State) {
        guard case .sites(let sites) = state else {
            discoveredSites = []
            return
        }
        discoveredSites = sites
        let hadNoSelection = siteSelection.selectedSite == nil
        siteSelection.restoreSelection(from: sites)
        if hadNoSelection, let site = siteSelection.selectedSite {
            restorePosition(forSite: site.id)
        }
    }

    /// Resolves the selected site's session into a post list, or the signed-out pane. Only
    /// publishes for the site that was selected when it started — the site may change while
    /// resolving.
    public func resolveSession() async {
        guard let site = siteSelection.selectedSite else {
            sessionState = .none
            session = nil
            postList = nil
            return
        }
        sessionState = .checking
        let resolved = await sessions.session(for: site)
        guard site == siteSelection.selectedSite else { return }
        if let resolved {
            session = resolved
            postList = PostListModel(client: resolved.makeClient(transport: clientTransport), registry: registry)
            sessionState = .ready
        } else {
            session = nil
            postList = nil
            sessionState = .signedOut
        }
    }

    /// Single path for every site-switch trigger (sidebar row, switcher menu, App Intent) so the
    /// reset-filter-and-selection side effect can't drift between call sites. Drops to
    /// `.checking` synchronously — otherwise the previous site's session/post list keeps
    /// rendering under the new site's name until `resolveSession()` re-runs a frame or two later.
    ///
    /// - Parameter site: The site to select; a no-op when it's already selected.
    public func selectSite(_ site: SitePickerModel.DiscoveredSite) {
        guard site.id != siteSelection.selectedSite?.id else { return }
        siteSelection.select(site)
        sessionState = .checking
        selectedTypeID = nil
        selection = nil
    }

    // MARK: - Position restoration (#1436)

    /// Persists the current site's content-type filter and post selection. Call on every
    /// change — cheap, and the only way to avoid losing position to memory pressure rather than
    /// an orderly background transition.
    public func persistPosition() {
        guard let siteID = siteSelection.selectedSite?.id else { return }
        restoration.recordPosition(
            siteID: siteID, typeID: selectedTypeID, selection: selection.map(PersistedSelection.init))
    }

    /// Applies a saved position for `siteID`: the type filter immediately, and a `.new` selection
    /// immediately (the composer needs nothing else). An `.existing` selection instead waits for
    /// the post list to load — resolved by ``postListStateChanged(_:)``.
    private func restorePosition(forSite siteID: UUID) {
        guard let saved = restoration.restorePosition(forSite: siteID) else { return }
        selectedTypeID = saved.typeID
        switch saved.selection {
        case .new(let typeID):
            selection = .new(typeID: typeID)
        case .existing(let postURL):
            pendingRestoredPostURL = postURL
        case nil:
            break
        }
    }

    /// Resolves a pending restored post selection once the list has rows. A deleted/moved post
    /// simply leaves the composer pane on its existing empty state — the same "already correct"
    /// fallback `SiteSelectionModel.restoreSelection` uses.
    ///
    /// - Parameter state: The post list's new state (`nil` when there is no list).
    public func postListStateChanged(_ state: PostListModel.State?) {
        guard let pendingRestoredPostURL, case .posts(let items)? = state else { return }
        defer { self.pendingRestoredPostURL = nil }
        guard let item = items.first(where: { $0.id == pendingRestoredPostURL }) else { return }
        selection = .existing(item)
    }

    // MARK: - Composer

    /// Starts a new composition — of the sidebar-selected type, or `note` (the quickest
    /// capture) when browsing all posts.
    public func startNewPost() {
        selection = .new(typeID: selectedTypeID ?? "note")
    }

    // MARK: - Edit Site sessions (#1431)

    /// The session model for `site`, if one has been created by ``presentEditSession(for:)``.
    public func editSession(for site: SitePickerModel.DiscoveredSite) -> EditSessionModel? {
        editSessions[site.id]
    }

    /// Single path for every "Edit Site" trigger (toolbar, context menu, App Intent): ensures
    /// the site's session model exists — created here, in an action, never during body
    /// evaluation — then presents the cover. Reusing an existing model re-enters its warm
    /// session (#1431, design §3).
    ///
    /// - Parameter site: The site to edit.
    public func presentEditSession(for site: SitePickerModel.DiscoveredSite) {
        if editSessions[site.id] == nil {
            editSessions[site.id] = EditSessionModel(
                siteID: site.id,
                siteDisplayName: site.displayName,
                pairedMacs: pairedMacs,
                makeRuntime: makeEditRuntime,
                // #1436: remember which sites have a live/starting session so a relaunch can
                // re-offer it instead of silently dropping it.
                onPhaseChange: { [restoration] phase in
                    switch phase {
                    case .waking, .starting, .ready:
                        restoration.markSessionWarm(siteID: site.id)
                    case .idle, .failed, .pairingRequired:
                        restoration.markSessionEnded(siteID: site.id)
                    }
                }
            )
        }
        editingSite = site
    }

    /// The owner declined a "Continue editing…" offer: forget the warm marker.
    ///
    /// - Parameter site: The site whose offer was dismissed.
    public func declineWarmSession(for site: SitePickerModel.DiscoveredSite) {
        restoration.markSessionEnded(siteID: site.id)
    }

    /// Accepts a "Continue editing…" offer, or an Edit Site request for a specific site: selects
    /// it and presents its session.
    ///
    /// - Parameter site: The site to resume.
    public func resumeEditing(_ site: SitePickerModel.DiscoveredSite) {
        selectSite(site)
        presentEditSession(for: site)
    }

    /// The Edit Site App Intent's hand-off (the iOS twin of `WindowRouter`): consumes the
    /// router's pending request and walks into that site's session. A request for a site
    /// discovery doesn't know is consumed and dropped.
    public func handleEditSessionRequest() {
        guard editSessionRouter.requestedSiteID != nil, let siteID = editSessionRouter.consume() else { return }
        guard let site = discoveredSites.first(where: { $0.id == siteID }) else { return }
        resumeEditing(site)
    }
}

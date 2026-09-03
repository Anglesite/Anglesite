// Sources/AnglesiteMobile/SiteSplitScreen.swift
import SwiftUI
import AnglesiteIOS
import AnglesiteCore

/// The app's shell (#869, design §3): one `NavigationSplitView`, adaptive — three columns on
/// iPad (sites/content-types sidebar, post list, composer), collapsing to a single
/// `NavigationStack` on iPhone. Single scene, no multi-window for v1.
///
/// Sessions come from a ``MicropubSessionProviding`` — in production
/// ``StoredMicropubSessions``, which assembles a session from the credential the IndieAuth
/// onboarding flow (#868) stored plus a fresh endpoint discovery. A site with no stored
/// credential shows `SiteSignInScreen` in the content pane; there is no unauthenticated browse
/// path (design §6).
struct SiteSplitScreen: View {
    /// The session source; previews/tests can substitute ``NoMicropubSessions`` or a fake.
    var sessions: any MicropubSessionProviding = StoredMicropubSessions()

    @State private var sitePicker = SitePickerModel()
    @State private var siteSelection = SiteSelectionModel()
    /// Persists/restores the content-type filter, post selection, and warm-session set across
    /// relaunch (#1436, design §8.6).
    @State private var restoration = NavigationRestorationModel()
    /// The sidebar's content-type filter: a registry type id, or `nil` for "All Posts".
    @State private var selectedTypeID: String?
    @State private var selection: PostListItemSelection?
    /// A restored `.existing(postURL:)` selection waiting for the post list to load so it can
    /// resolve into a real `PostListModel.Item` — cleared once applied or found stale.
    @State private var pendingRestoredPostURL: URL?
    /// The selected site's session pane state — re-resolved whenever the site changes.
    @State private var sessionState: SessionState = .none
    private let registry = ContentTypeRegistry.default

    private enum SessionState: Equatable {
        case none
        case checking
        case signedOut
        case ready
    }

    /// The resolved session's models, rebuilt per site.
    @State private var postList: PostListModel?
    @State private var session: MicropubSession?

    /// One "Edit Site" session model per site, kept for the shell's lifetime (#1431): the
    /// full-screen cover only *renders* a session, so dismissing it leaves the model — and its
    /// warm P2P session — untouched, and switching sites never tears another site's session down.
    @State private var editSessions: [UUID: EditSessionModel] = [:]
    /// The site whose session cover is presented, or `nil` when none is.
    @State private var editingSite: SitePickerModel.DiscoveredSite?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle(Text("Anglesite"))
        } content: {
            contentPane
                .navigationTitle(contentTitle)
        } detail: {
            detailPane
        }
        .task { await sitePicker.refresh() }
        .task(id: siteSelection.selectedSite?.id) { await resolveSession() }
        .onChange(of: sitePicker.state) { _, newState in
            if case .sites(let sites) = newState {
                let hadNoSelection = siteSelection.selectedSite == nil
                siteSelection.restoreSelection(from: sites)
                // Only the cold-launch restore (no prior selection) re-applies a saved position —
                // an interactive site switch already resets the filter/selection itself.
                if hadNoSelection, let site = siteSelection.selectedSite {
                    restorePosition(forSite: site.id)
                }
            }
        }
        .onChange(of: selectedTypeID) { _, _ in persistPosition() }
        .onChange(of: selection) { _, _ in persistPosition() }
        .onChange(of: postList?.state) { _, newState in
            guard let pendingRestoredPostURL, case .posts(let items) = newState else { return }
            defer { self.pendingRestoredPostURL = nil }
            // A deleted/moved post simply leaves the composer pane on its existing empty state —
            // the same "already correct" fallback `SiteSelectionModel.restoreSelection` uses.
            guard let item = items.first(where: { $0.id == pendingRestoredPostURL }) else { return }
            selection = .existing(item)
        }
        .fullScreenCover(item: $editingSite) { site in
            if let model = editSessions[site.id] {
                EditSiteScreen(model: model)
            }
        }
        .onChange(of: EditSessionRouter.shared.requestedSiteID) { _, requested in
            // The Edit Site App Intent's hand-off (the iOS twin of WindowRouter): consume the
            // request and walk into that site's session.
            guard requested != nil, let siteID = EditSessionRouter.shared.consume() else { return }
            guard case .sites(let sites) = sitePicker.state,
                  let site = sites.first(where: { $0.id == siteID })
            else { return }
            selectSite(site)
            presentEditSession(for: site)
        }
        .safeAreaInset(edge: .top) { continueEditingBanner }
    }

    // MARK: - Position restoration (#1436)

    /// Persists the current site's content-type filter and post selection. Called on every
    /// change — cheap, and the only way to avoid losing position to memory pressure rather than
    /// an orderly background transition.
    private func persistPosition() {
        guard let siteID = siteSelection.selectedSite?.id else { return }
        restoration.recordPosition(
            siteID: siteID, typeID: selectedTypeID, selection: selection.map(PersistedSelection.init))
    }

    /// Applies a saved position for `siteID`: the type filter immediately, and a `.new` selection
    /// immediately (the composer needs nothing else). An `.existing` selection instead waits for
    /// `postList` to load — resolved by the `postList?.state` observer above.
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

    // MARK: - Sidebar (sites + content types)

    @ViewBuilder
    private var sidebar: some View {
        switch sitePicker.state {
        case .loading:
            ProgressView("Finding your sites…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .iCloudUnavailable:
            ContentUnavailableView {
                Label("iCloud Unavailable", systemImage: "icloud.slash")
            } description: {
                Text("Sign in to iCloud and turn on iCloud Drive to see your Anglesite sites.")
            } actions: {
                Button("Try Again") { Task { await sitePicker.refresh() } }
                    .buttonStyle(.borderedProminent)
            }
        case .empty:
            ContentUnavailableView {
                Label("No Sites Found", systemImage: "globe")
            } description: {
                Text("No sites found — create a site in Anglesite on your Mac first.")
            } actions: {
                Button("Refresh") { Task { await sitePicker.refresh() } }
                    .buttonStyle(.borderedProminent)
            }
        case .sites(let sites):
            List(selection: sidebarSelection) {
                Section("Sites") {
                    ForEach(sites) { site in
                        Label {
                            Text(verbatim: site.displayName)
                        } icon: {
                            Image(systemName: "globe")
                        }
                        .tag(SidebarSelection.site(site.id))
                        .contextMenu {
                            Button {
                                selectSite(site)
                                presentEditSession(for: site)
                            } label: {
                                Label("Edit Site", systemImage: "paintbrush.pointed")
                            }
                        }
                    }
                }
                if siteSelection.selectedSite != nil {
                    Section("Content") {
                        Label {
                            Text("All Posts")
                        } icon: {
                            Image(systemName: "tray.full")
                        }
                        .tag(SidebarSelection.allPosts)
                        ForEach(postTypes) { descriptor in
                            Label {
                                Text(verbatim: descriptor.displayName)
                            } icon: {
                                Image(systemName: "square.and.pencil")
                            }
                            .tag(SidebarSelection.type(descriptor.id))
                        }
                    }
                }
            }
            .refreshable { await sitePicker.refresh() }
        }
    }

    /// The content types a phone can post: collection-stored (post-family) descriptors.
    /// Pages and singletons (business profile, résumé) are site-editing, not posting — v2.0
    /// scope (#66/#71).
    private var postTypes: [ContentTypeDescriptor] {
        registry.all.filter { $0.collection != nil }
    }

    /// The discovered site list, or empty when discovery hasn't produced one yet — feeds
    /// `SiteSwitcherMenu`, which is hidden entirely below 2 sites.
    private var switcherSites: [SitePickerModel.DiscoveredSite] {
        guard case .sites(let sites) = sitePicker.state else { return [] }
        return sites
    }

    @ToolbarContentBuilder
    private func siteSwitcherToolbarItem(site: SitePickerModel.DiscoveredSite) -> some ToolbarContent {
        if switcherSites.count >= 2 {
            ToolbarItem(placement: .navigation) {
                SiteSwitcherMenu(sites: switcherSites, selected: site, onSelect: selectSite)
            }
        }
    }

    private enum SidebarSelection: Hashable {
        case site(UUID)
        case allPosts
        case type(String)
    }

    /// One `List` selection over both sections: picking a site switches sites (resetting the
    /// type filter); picking a content row narrows the post list.
    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(
            get: {
                if let selectedTypeID { return .type(selectedTypeID) }
                if siteSelection.selectedSite != nil { return .allPosts }
                return nil
            },
            set: { newValue in
                switch newValue {
                case .site(let id):
                    guard case .sites(let sites) = sitePicker.state,
                          let site = sites.first(where: { $0.id == id })
                    else { return }
                    selectSite(site)
                case .allPosts:
                    selectedTypeID = nil
                case .type(let id):
                    selectedTypeID = id
                case nil:
                    break
                }
            }
        )
    }

    // MARK: - Content (post list)

    private var contentTitle: Text {
        if let selectedTypeID, let descriptor = registry.descriptor(id: selectedTypeID) {
            return Text(verbatim: descriptor.displayName)
        }
        return Text("All Posts")
    }

    @ViewBuilder
    private var contentPane: some View {
        if let site = siteSelection.selectedSite {
            Group {
                switch sessionState {
                case .none, .checking:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .signedOut:
                    // #868's onboarding flow, embedded: when it lands signed-in, re-resolve so
                    // the freshly stored credential becomes this shell's session.
                    SiteSignInScreen(site: site) {
                        Task { await resolveSession() }
                    }
                case .ready:
                    if let postList {
                        PostListScreen(
                            model: postList,
                            collection: selectedCollection,
                            selection: $selection
                        )
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                newPostButton
                            }
                        }
                    }
                }
            }
            .toolbar {
                siteSwitcherToolbarItem(site: site)
                // Available regardless of Micropub sign-in state: editing rides the P2P
                // session's pairing, not the posting shell's IndieAuth credential (#1431).
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        presentEditSession(for: site)
                    } label: {
                        Label("Edit Site", systemImage: "paintbrush.pointed")
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("Pick a Site", systemImage: "globe")
            } description: {
                Text("Choose one of your sites to see its posts.")
            }
        }
    }

    private var selectedCollection: String? {
        selectedTypeID.flatMap { registry.descriptor(id: $0)?.collection }
    }

    /// Starts a new composition — of the sidebar-selected type, or `note` (the quickest
    /// capture) when browsing all posts.
    private var newPostButton: some View {
        Button {
            selection = .new(typeID: selectedTypeID ?? "note")
        } label: {
            Label("New Post", systemImage: "square.and.pencil")
        }
    }

    // MARK: - Detail (composer)

    @ViewBuilder
    private var detailPane: some View {
        if let session, let site = siteSelection.selectedSite, let selection {
            ComposerPane(
                selection: selection,
                session: session,
                siteID: site.id,
                registry: registry,
                postList: postList,
                onSent: { Task { await postList?.refresh() } }
            )
            // A fresh pane per selection: composer state must never leak across posts.
            .id(selection)
            .toolbar {
                siteSwitcherToolbarItem(site: site)
            }
        } else {
            ContentUnavailableView {
                Label("Nothing Selected", systemImage: "square.and.pencil")
            } description: {
                Text("Pick a post to edit, or start a new one.")
            }
        }
    }

    private func resolveSession() async {
        guard let site = siteSelection.selectedSite else {
            sessionState = .none
            session = nil
            postList = nil
            return
        }
        sessionState = .checking
        let resolved = await sessions.session(for: site)
        // The site may have changed while resolving; only publish for the current one.
        guard site == siteSelection.selectedSite else { return }
        if let resolved {
            session = resolved
            postList = PostListModel(client: resolved.makeClient(), registry: registry)
            sessionState = .ready
        } else {
            session = nil
            postList = nil
            sessionState = .signedOut
        }
    }

    /// Single path for every "Edit Site" trigger (toolbar, context menu, App Intent): ensures
    /// the site's session model exists — created here, in an action, never during body
    /// evaluation — then presents the cover. Reusing an existing model re-enters its warm
    /// session (#1431, design §3).
    private func presentEditSession(for site: SitePickerModel.DiscoveredSite) {
        if editSessions[site.id] == nil {
            editSessions[site.id] = EditSessionModel(
                siteID: site.id,
                siteDisplayName: site.displayName,
                pairedMacs: { try PairedDeviceStore().load() },
                // #1208 P4 swaps this factory for the real WebRTC-backed P2PSiteRuntime;
                // nothing else in the session UI knows which runtime it drives.
                makeRuntime: { PendingP2PSiteRuntime() },
                // #1436: remember which sites have a live/starting session so a relaunch can
                // re-offer it instead of silently dropping it.
                onPhaseChange: { phase in
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

    /// The sites `restoration` remembers as warm, resolved against the currently-discovered
    /// site list — a persisted ID for a site that's since vanished (deleted, not yet synced)
    /// resolves to nothing, same as `SiteSelectionModel.restoreSelection`'s handling of that case.
    private var warmSites: [SitePickerModel.DiscoveredSite] {
        switcherSites.filter { restoration.warmSessionIDs.contains($0.id) }
    }

    /// A dismissible, non-modal "Continue editing…" offer (#1436, design §8.6 / platform spec
    /// §4: re-offer a warm session after relaunch rather than silently dropping it — never a
    /// sheet or alert for this, per §4's "don't use an alert for routine information").
    @ViewBuilder
    private var continueEditingBanner: some View {
        if !warmSites.isEmpty {
            VStack(spacing: 8) {
                ForEach(warmSites) { site in
                    HStack {
                        Label {
                            Text("Continue editing \(site.displayName)?")
                        } icon: {
                            Image(systemName: "paintbrush.pointed")
                        }
                        Spacer()
                        Button("Continue") {
                            selectSite(site)
                            presentEditSession(for: site)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Not Now") {
                            restoration.markSessionEnded(siteID: site.id)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(12)
            .background(.thinMaterial)
        }
    }

    /// Single path for every site-switch trigger (sidebar row, switcher menu) so the
    /// reset-filter-and-selection side effect can't drift between call sites.
    private func selectSite(_ site: SitePickerModel.DiscoveredSite) {
        guard site.id != siteSelection.selectedSite?.id else { return }
        siteSelection.select(site)
        // Drop to the loading state synchronously — otherwise the previous site's session/post
        // list keeps rendering under the new site's name until `.task(id:)` re-resolves a frame
        // or two later.
        sessionState = .checking
        selectedTypeID = nil
        selection = nil
    }
}

/// Builds the right composer for a selection: a fresh model for a new post (restoring any
/// interrupted draft of the same site + type), or an async `q=source` load for an existing one.
private struct ComposerPane: View {
    let selection: PostListItemSelection
    let session: MicropubSession
    let siteID: UUID
    let registry: ContentTypeRegistry
    let postList: PostListModel?
    var onSent: () -> Void

    @State private var model: PostComposerModel?
    @State private var loadFailure: String?

    var body: some View {
        Group {
            if let model {
                ComposeScreen(model: model, onSent: onSent)
            } else if let loadFailure {
                ContentUnavailableView {
                    Label("Couldn't Open Post", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: loadFailure)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private func load() async {
        loadFailure = nil
        switch selection {
        case .new(let typeID):
            guard let descriptor = registry.descriptor(id: typeID) else {
                loadFailure = String(localized: "That content type isn't available.")
                return
            }
            let store = ComposerDraftStore()
            model = PostComposerModel(
                descriptor: descriptor,
                siteID: siteID,
                client: session.makeClient(),
                draftStore: store,
                // Only a genuinely-new draft of this type restores here — a queued *update*
                // to an existing post must never resume from the "New Post" entry point
                // (#1370 review); it surfaces when that post itself is reopened, below.
                restoringDraft: store.loadNewDraft(forSite: siteID, typeID: typeID)
            )
        case .existing(let item):
            guard let descriptor = postList?.descriptor(for: item) else {
                loadFailure = String(localized: "This post's type isn't one this app can edit.")
                return
            }
            let store = ComposerDraftStore()
            // A queued/pending edit for this very post takes precedence over the server copy:
            // reopening the post is the natural recovery path after a failed send, so the
            // pending edit (and its waiting-for-network state) must be discoverable here, not
            // hidden behind a fresh fetch (#1370 review).
            if let pending = store.loadDraft(forSite: siteID, postURL: item.id),
               pending.typeID == descriptor.id {
                model = PostComposerModel(
                    descriptor: descriptor,
                    siteID: siteID,
                    client: session.makeClient(),
                    draftStore: store,
                    restoringDraft: pending
                )
                return
            }
            do {
                model = try await PostComposerModel.openExisting(
                    url: item.id,
                    descriptor: descriptor,
                    siteID: siteID,
                    client: session.makeClient(),
                    draftStore: store
                )
            } catch {
                loadFailure = String(localized: "The post couldn't be loaded from your site.")
            }
        }
    }
}

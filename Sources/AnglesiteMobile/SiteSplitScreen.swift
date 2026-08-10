// Sources/AnglesiteMobile/SiteSplitScreen.swift
import SwiftUI
import AnglesiteIOS
import AnglesiteCore

/// The app's shell (#869, design §3): one `NavigationSplitView`, adaptive — three columns on
/// iPad (sites/content-types sidebar, post list, composer), collapsing to a single
/// `NavigationStack` on iPhone. Single scene, no multi-window for v1.
///
/// Sessions come from a ``MicropubSessionProviding`` — the seam the IndieAuth onboarding issue
/// (#868) fills in. Until a site has a session, its panes show the sign-in-required state; there
/// is no unauthenticated browse path (design §6).
struct SiteSplitScreen: View {
    /// The session source; the default reads every site as signed out until #868's provider
    /// replaces it.
    var sessions: any MicropubSessionProviding = NoMicropubSessions()

    @State private var sitePicker = SitePickerModel()
    @State private var selectedSite: SitePickerModel.DiscoveredSite?
    /// The sidebar's content-type filter: a registry type id, or `nil` for "All Posts".
    @State private var selectedTypeID: String?
    @State private var selection: PostListItemSelection?
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
        .task(id: selectedSite?.id) { await resolveSession() }
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
                    }
                }
                if selectedSite != nil {
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
                if selectedSite != nil { return .allPosts }
                return nil
            },
            set: { newValue in
                switch newValue {
                case .site(let id):
                    guard case .sites(let sites) = sitePicker.state,
                          let site = sites.first(where: { $0.id == id })
                    else { return }
                    if site != selectedSite {
                        selectedSite = site
                        selectedTypeID = nil
                        selection = nil
                    }
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
        if selectedSite == nil {
            ContentUnavailableView {
                Label("Pick a Site", systemImage: "globe")
            } description: {
                Text("Choose one of your sites to see its posts.")
            }
        } else {
            switch sessionState {
            case .none, .checking:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                signInRequired
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

    /// The conformance/onboarding gate state: names the requirement instead of degrading
    /// silently (design §1/§7). The actual sign-in flow is #868's.
    private var signInRequired: some View {
        ContentUnavailableView {
            Label("Sign In to Post", systemImage: "person.badge.key")
        } description: {
            Text("Posting to this site needs a sign-in with your site itself. Site sign-in arrives with IndieAuth onboarding.")
        }
    }

    // MARK: - Detail (composer)

    @ViewBuilder
    private var detailPane: some View {
        if let session, let site = selectedSite, let selection {
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
        } else {
            ContentUnavailableView {
                Label("Nothing Selected", systemImage: "square.and.pencil")
            } description: {
                Text("Pick a post to edit, or start a new one.")
            }
        }
    }

    private func resolveSession() async {
        guard let site = selectedSite else {
            sessionState = .none
            session = nil
            postList = nil
            return
        }
        sessionState = .checking
        let resolved = await sessions.session(forSite: site.id)
        // The site may have changed while resolving; only publish for the current one.
        guard site == selectedSite else { return }
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

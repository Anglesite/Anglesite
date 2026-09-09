// Sources/AnglesiteMobile/SiteSplitScreen.swift
import SwiftUI
import AnglesiteIOS
import AnglesiteCore
import AnglesiteMobileCore

/// The app's shell (#869, design §3): one `NavigationSplitView`, adaptive — three columns on
/// iPad (sites/content-types sidebar, post list, composer), collapsing to a single
/// `NavigationStack` on iPhone. Single scene, no multi-window for v1.
///
/// Sessions come from a ``MicropubSessionProviding`` — in production
/// ``StoredMicropubSessions``, which assembles a session from the credential the IndieAuth
/// onboarding flow (#868) stored plus a fresh endpoint discovery. A site with no stored
/// credential shows `SiteSignInScreen` in the content pane; there is no unauthenticated browse
/// path (design §6).
///
/// Every decision — what a site switch resets, how a session resolves, position persistence,
/// the per-site Edit Site models, the App Intent hand-off — lives in `SiteShellModel`
/// (`AnglesiteMobileCore`, tested under `swift test`, #1968). This view owns discovery
/// (`SitePickerModel`), forwards the lifecycle triggers, and renders.
struct SiteSplitScreen: View {
    @State private var sitePicker = SitePickerModel()
    @State private var shell: SiteShellModel

    /// - Parameter sessions: The session source; previews/tests can substitute
    ///   ``NoMicropubSessions`` or a fake.
    init(sessions: any MicropubSessionProviding = StoredMicropubSessions()) {
        _shell = State(initialValue: SiteShellModel(sessions: sessions))
    }

    var body: some View {
        @Bindable var shell = shell
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
        .task(id: shell.selectedSite?.id) { await shell.resolveSession() }
        .onChange(of: sitePicker.state) { _, newState in shell.discoverySettled(newState) }
        .onChange(of: shell.selectedTypeID) { _, _ in shell.persistPosition() }
        .onChange(of: shell.selection) { _, _ in shell.persistPosition() }
        .onChange(of: shell.postList?.state) { _, newState in shell.postListStateChanged(newState) }
        .fullScreenCover(item: $shell.editingSite) { site in
            if let model = shell.editSession(for: site) {
                EditSiteScreen(model: model)
            }
        }
        // The Edit Site App Intent's hand-off (the iOS twin of WindowRouter): the shell
        // consumes the request and walks into that site's session.
        .onChange(of: shell.editSessionRouter.requestedSiteID) { _, _ in shell.handleEditSessionRequest() }
        .safeAreaInset(edge: .top) { continueEditingBanner }
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
                        .tag(SiteShellModel.SidebarSelection.site(site.id))
                        .contextMenu {
                            Button {
                                shell.resumeEditing(site)
                            } label: {
                                Label("Edit Site", systemImage: "paintbrush.pointed")
                            }
                        }
                    }
                }
                if shell.selectedSite != nil {
                    Section("Content") {
                        Label {
                            Text("All Posts")
                        } icon: {
                            Image(systemName: "tray.full")
                        }
                        .tag(SiteShellModel.SidebarSelection.allPosts)
                        ForEach(shell.postTypes) { descriptor in
                            Label {
                                Text(verbatim: descriptor.displayName)
                            } icon: {
                                Image(systemName: "square.and.pencil")
                            }
                            .tag(SiteShellModel.SidebarSelection.type(descriptor.id))
                        }
                    }
                }
            }
            .refreshable { await sitePicker.refresh() }
        }
    }

    @ToolbarContentBuilder
    private func siteSwitcherToolbarItem(site: SitePickerModel.DiscoveredSite) -> some ToolbarContent {
        // Hidden entirely below 2 sites.
        if shell.discoveredSites.count >= 2 {
            ToolbarItem(placement: .navigation) {
                SiteSwitcherMenu(sites: shell.discoveredSites, selected: site, onSelect: shell.selectSite)
            }
        }
    }

    /// One `List` selection over both sections, routed through the shell.
    private var sidebarSelection: Binding<SiteShellModel.SidebarSelection?> {
        Binding(
            get: { shell.sidebarSelection },
            set: { shell.select(sidebar: $0) }
        )
    }

    // MARK: - Content (post list)

    private var contentTitle: Text {
        if let descriptor = shell.contentTitleDescriptor {
            return Text(verbatim: descriptor.displayName)
        }
        return Text("All Posts")
    }

    @ViewBuilder
    private var contentPane: some View {
        @Bindable var shell = shell
        if let site = shell.selectedSite {
            Group {
                switch shell.sessionState {
                case .none, .checking:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .signedOut:
                    // #868's onboarding flow, embedded: when it lands signed-in, re-resolve so
                    // the freshly stored credential becomes this shell's session.
                    SiteSignInScreen(site: site) {
                        Task { await shell.resolveSession() }
                    }
                case .ready:
                    if let postList = shell.postList {
                        PostListScreen(
                            model: postList,
                            collection: shell.selectedCollection,
                            selection: $shell.selection
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
                        shell.presentEditSession(for: site)
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

    /// Starts a new composition — of the sidebar-selected type, or `note` (the quickest
    /// capture) when browsing all posts.
    private var newPostButton: some View {
        Button {
            shell.startNewPost()
        } label: {
            Label("New Post", systemImage: "square.and.pencil")
        }
    }

    // MARK: - Detail (composer)

    @ViewBuilder
    private var detailPane: some View {
        if let session = shell.session, let site = shell.selectedSite, let selection = shell.selection {
            ComposerPane(
                selection: selection,
                session: session,
                siteID: site.id,
                registry: shell.registry,
                postList: shell.postList,
                onSent: { Task { await shell.postList?.refresh() } }
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

    /// A dismissible, non-modal "Continue editing…" offer (#1436, design §8.6 / platform spec
    /// §4: re-offer a warm session after relaunch rather than silently dropping it — never a
    /// sheet or alert for this, per §4's "don't use an alert for routine information").
    @ViewBuilder
    private var continueEditingBanner: some View {
        let warmSites = shell.warmSites
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
                            shell.resumeEditing(site)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Not Now") {
                            shell.declineWarmSession(for: site)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(12)
            .background(.thinMaterial)
        }
    }
}

/// Builds the right composer for a selection through `ComposerLoader` (`AnglesiteMobileCore`):
/// a fresh model for a new post (restoring any interrupted draft of the same site + type), or an
/// async `q=source` load for an existing one. Only the failure copy lives here.
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
        let loader = ComposerLoader(
            siteID: siteID, registry: registry, draftStore: ComposerDraftStore(),
            makeClient: { session.makeClient() })
        switch await loader.load(ComposerLoadRequest(selection: selection, postList: postList)) {
        case .success(let loaded):
            model = loaded
        case .failure(let failure):
            loadFailure = Self.describe(failure)
        }
    }

    private static func describe(_ failure: ComposerLoadFailure) -> String {
        switch failure {
        case .unavailableContentType:
            return String(localized: "That content type isn't available.")
        case .uneditablePostType:
            return String(localized: "This post's type isn't one this app can edit.")
        case .postFetchFailed:
            return String(localized: "The post couldn't be loaded from your site.")
        }
    }
}

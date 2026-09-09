// Tests for the iOS shell's orchestration model (#1968): discovery → selection restore, the
// session-resolution state machine (including a stale resolve after a site switch), sidebar
// selection mapping, position persistence and the deferred existing-post restore (#1436), the
// one-model-per-site Edit Site bookkeeping with warm-session markers, and the App Intent
// hand-off. Everything runs against temporary defaults and fakes — no iCloud, Keychain, or
// network.
import Foundation
import Testing
import AnglesiteCore
import AnglesiteIOS
import AnglesiteTestSupport
@testable import AnglesiteMobileCore

/// Returns a canned session per site id — `nil` (signed out) for everything else.
private struct FakeSessions: MicropubSessionProviding {
    var sessions: [UUID: MicropubSession] = [:]
    func session(for site: SitePickerModel.DiscoveredSite) async -> MicropubSession? {
        sessions[site.id]
    }
}

/// A one-shot latch the test opens by hand, plus a flag saying a resolve has actually reached
/// it — `selectSite` already sets `.checking` synchronously, so the state alone can't tell a
/// test that `resolveSession()` is in flight.
private final class ResolveLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var _entered = false
    private let released: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        (released, releaseContinuation) = AsyncStream<Void>.makeStream()
    }

    var entered: Bool { lock.withLock { _entered } }

    func markEntered() { lock.withLock { _entered = true } }

    func release() {
        releaseContinuation.yield()
        releaseContinuation.finish()
    }

    func wait() async {
        for await _ in released { return }
    }
}

/// Holds every resolution on `latch` until the test releases it — for the stale-resolve case.
private struct GatedSessions: MicropubSessionProviding {
    let latch: ResolveLatch
    func session(for site: SitePickerModel.DiscoveredSite) async -> MicropubSession? {
        latch.markEntered()
        await latch.wait()
        return nil
    }
}

/// An "Edit Site" runtime that settles straight to `.ready`.
private actor ReadyRuntime: SiteRuntime {
    let mcpClient = MCPClient(supervisor: ProcessSupervisor())
    private let stateMachine = SiteRuntimeStateMachine()
    func start(siteID: String, siteDirectory: URL) async {
        let gen = stateMachine.beginStarting(siteID: siteID)
        stateMachine.settle(gen: gen, to: .ready(siteID: siteID, url: URL(string: "https://p2p.local/")!))
    }
    func stop() async { stateMachine.settle(gen: stateMachine.beginAttempt(), to: .idle) }
    func observe() -> AsyncStream<SiteRuntimeState> { stateMachine.observe() }
}

@Suite("SiteShellModel")
@MainActor
struct SiteShellModelTests {
    private static func site(_ name: String, id: UUID = UUID()) -> SitePickerModel.DiscoveredSite {
        SitePickerModel.DiscoveredSite(id: id, displayName: name, packageURL: URL(fileURLWithPath: "/tmp/\(name).anglesite"))
    }

    private static func session() -> MicropubSession {
        MicropubSession(
            micropubEndpoint: URL(string: "https://owner.example/micropub")!,
            mediaEndpoint: nil, accessToken: "tok", dpopKeyPair: DPoPKeyPair())
    }

    private static let mac = PairedDevice(deviceID: "mac-1", displayName: "Studio", pinnedPublicKey: Data([1, 2, 3]), pairedAt: Date())

    private static func makeShell(
        defaults: UserDefaults,
        sessions: any MicropubSessionProviding = FakeSessions(),
        router: EditSessionRouter = EditSessionRouter(),
        pairedMacs: [PairedDevice] = []
    ) -> SiteShellModel {
        SiteShellModel(
            sessions: sessions,
            siteSelection: SiteSelectionModel(defaults: defaults),
            restoration: NavigationRestorationModel(defaults: defaults),
            editSessionRouter: router,
            pairedMacs: { pairedMacs },
            makeEditRuntime: { ReadyRuntime() },
            clientTransport: { _ in throw URLError(.notConnectedToInternet) })
    }

    // MARK: - Discovery and site selection

    @Test("selecting a site resets the filter and composer selection and drops to checking")
    func selectSiteResets() async throws {
        try await withTemporaryUserDefaults { defaults in
            let shell = Self.makeShell(defaults: defaults)
            let alpha = Self.site("Alpha"), beta = Self.site("Beta")
            shell.discoverySettled(.sites([alpha, beta]))
            shell.selectSite(alpha)
            shell.selectedTypeID = "note"
            shell.startNewPost()
            #expect(shell.selection == .new(typeID: "note"))

            shell.selectSite(beta)
            #expect(shell.selectedSite == beta)
            #expect(shell.sessionState == .checking)
            #expect(shell.selectedTypeID == nil)
            #expect(shell.selection == nil)

            // Re-selecting the current site is a no-op: nothing resets.
            shell.selectedTypeID = "article"
            shell.selectSite(beta)
            #expect(shell.selectedTypeID == "article")
        }
    }

    @Test("a cold launch restores the persisted site and its saved position; a later refresh doesn't")
    func coldLaunchRestoresSiteAndPosition() async throws {
        try await withTemporaryUserDefaults { defaults in
            let alpha = Self.site("Alpha")
            do {
                let first = Self.makeShell(defaults: defaults)
                first.discoverySettled(.sites([alpha]))
                first.selectSite(alpha)
                first.selectedTypeID = "note"
                first.startNewPost()
                first.persistPosition()
            }

            let relaunched = Self.makeShell(defaults: defaults)
            #expect(relaunched.selectedSite == nil)
            relaunched.discoverySettled(.sites([alpha]))
            #expect(relaunched.selectedSite == alpha)
            #expect(relaunched.selectedTypeID == "note")
            #expect(relaunched.selection == .new(typeID: "note"))

            // A later discovery pass (pull-to-refresh) must not re-apply the saved position
            // over whatever the owner has since done.
            relaunched.selectedTypeID = nil
            relaunched.selection = nil
            relaunched.discoverySettled(.sites([alpha]))
            #expect(relaunched.selectedTypeID == nil)
            #expect(relaunched.selection == nil)
        }
    }

    @Test("a discovery result with no sites clears the switcher list")
    func emptyDiscoveryClearsSites() async throws {
        try await withTemporaryUserDefaults { defaults in
            let shell = Self.makeShell(defaults: defaults)
            shell.discoverySettled(.sites([Self.site("Alpha")]))
            #expect(shell.discoveredSites.count == 1)
            shell.discoverySettled(.empty)
            #expect(shell.discoveredSites.isEmpty)
            shell.discoverySettled(.iCloudUnavailable)
            #expect(shell.discoveredSites.isEmpty)
        }
    }

    // MARK: - Session resolution

    @Test("a site with a stored session lands ready with a post list; without one, signed out")
    func resolveSessionStates() async throws {
        try await withTemporaryUserDefaults { defaults in
            let signedIn = Self.site("Alpha"), signedOut = Self.site("Beta")
            let shell = Self.makeShell(
                defaults: defaults, sessions: FakeSessions(sessions: [signedIn.id: Self.session()]))
            shell.discoverySettled(.sites([signedIn, signedOut]))

            await shell.resolveSession()
            #expect(shell.sessionState == .none)

            shell.selectSite(signedIn)
            await shell.resolveSession()
            #expect(shell.sessionState == .ready)
            #expect(shell.session != nil)
            #expect(shell.postList != nil)

            shell.selectSite(signedOut)
            await shell.resolveSession()
            #expect(shell.sessionState == .signedOut)
            #expect(shell.session == nil)
            #expect(shell.postList == nil)
        }
    }

    @Test("a resolve that finishes after a site switch never publishes for the old site")
    func staleResolveIsDropped() async throws {
        try await withTemporaryUserDefaults { defaults in
            let latch = ResolveLatch()
            let shell = Self.makeShell(defaults: defaults, sessions: GatedSessions(latch: latch))
            let alpha = Self.site("Alpha"), beta = Self.site("Beta")
            shell.discoverySettled(.sites([alpha, beta]))
            shell.selectSite(alpha)

            let resolving = Task { await shell.resolveSession() }
            try await waitUntil("resolve in flight") { latch.entered }
            shell.selectSite(beta)
            latch.release()
            await resolving.value

            // Alpha's (signed-out) answer must not land on Beta's pane.
            #expect(shell.sessionState == .checking)
            #expect(shell.selectedSite == beta)
        }
    }

    // MARK: - Sidebar selection

    @Test("the sidebar selection mirrors site + filter, and applying one routes correctly")
    func sidebarSelectionMapping() async throws {
        try await withTemporaryUserDefaults { defaults in
            let shell = Self.makeShell(defaults: defaults)
            let alpha = Self.site("Alpha"), beta = Self.site("Beta")
            #expect(shell.sidebarSelection == nil)

            shell.discoverySettled(.sites([alpha, beta]))
            shell.select(sidebar: .site(alpha.id))
            #expect(shell.selectedSite == alpha)
            #expect(shell.sidebarSelection == .allPosts)

            shell.select(sidebar: .type("note"))
            #expect(shell.selectedTypeID == "note")
            #expect(shell.sidebarSelection == .type("note"))
            #expect(shell.contentTitleDescriptor?.id == "note")
            #expect(shell.selectedCollection == ContentTypeRegistry.default.descriptor(id: "note")?.collection)

            shell.select(sidebar: .allPosts)
            #expect(shell.selectedTypeID == nil)
            #expect(shell.contentTitleDescriptor == nil)
            #expect(shell.selectedCollection == nil)

            shell.select(sidebar: .site(UUID()))
            #expect(shell.selectedSite == alpha, "an unknown site id is ignored")
            shell.select(sidebar: nil)
            #expect(shell.selectedSite == alpha)
        }
    }

    @Test("postTypes are the collection-stored descriptors only")
    func postTypesFilter() async throws {
        try await withTemporaryUserDefaults { defaults in
            let shell = Self.makeShell(defaults: defaults)
            #expect(!shell.postTypes.isEmpty)
            #expect(shell.postTypes.allSatisfy { $0.collection != nil })
            #expect(shell.postTypes.count < ContentTypeRegistry.default.all.count, "pages/singletons are excluded")
        }
    }

    @Test("New Post composes the filtered type, or a note when browsing all posts")
    func startNewPost() async throws {
        try await withTemporaryUserDefaults { defaults in
            let shell = Self.makeShell(defaults: defaults)
            shell.startNewPost()
            #expect(shell.selection == .new(typeID: "note"))
            shell.selectedTypeID = "article"
            shell.startNewPost()
            #expect(shell.selection == .new(typeID: "article"))
        }
    }

    // MARK: - Existing-post restore (#1436)

    @Test("a persisted existing-post selection waits for the list, then resolves to its row")
    func existingSelectionRestoresOnceListLoads() async throws {
        try await withTemporaryUserDefaults { defaults in
            let alpha = Self.site("Alpha")
            let postURL = URL(string: "https://owner.example/notes/hello")!
            let item = PostListModel.Item(id: postURL, title: "Hello", collection: "notes", isDraft: false)
            do {
                let first = Self.makeShell(defaults: defaults)
                first.discoverySettled(.sites([alpha]))
                first.selectSite(alpha)
                first.selection = .existing(item)
                first.persistPosition()
            }

            let relaunched = Self.makeShell(defaults: defaults)
            relaunched.discoverySettled(.sites([alpha]))
            #expect(relaunched.selection == nil)
            #expect(relaunched.pendingRestoredPostURL == postURL)

            relaunched.postListStateChanged(.loading)
            #expect(relaunched.pendingRestoredPostURL == postURL, "only a loaded list resolves it")

            relaunched.postListStateChanged(.posts([item]))
            #expect(relaunched.selection == .existing(item))
            #expect(relaunched.pendingRestoredPostURL == nil)
        }
    }

    @Test("a persisted post that's gone from the list is dropped, leaving the pane empty")
    func missingRestoredPostIsDropped() async throws {
        try await withTemporaryUserDefaults { defaults in
            let alpha = Self.site("Alpha")
            let gone = URL(string: "https://owner.example/notes/gone")!
            do {
                let first = Self.makeShell(defaults: defaults)
                first.discoverySettled(.sites([alpha]))
                first.selectSite(alpha)
                first.selection = .existing(PostListModel.Item(id: gone, title: "Gone", collection: "notes", isDraft: false))
                first.persistPosition()
            }
            let relaunched = Self.makeShell(defaults: defaults)
            relaunched.discoverySettled(.sites([alpha]))
            let other = PostListModel.Item(id: URL(string: "https://owner.example/notes/other")!, title: "Other", collection: "notes", isDraft: false)
            relaunched.postListStateChanged(.posts([other]))
            #expect(relaunched.selection == nil)
            #expect(relaunched.pendingRestoredPostURL == nil)
        }
    }

    // MARK: - Edit Site sessions (#1431, #1436)

    @Test("presenting a site's session creates its model once and reuses it")
    func editSessionModelIsPerSite() async throws {
        try await withTemporaryUserDefaults { defaults in
            let shell = Self.makeShell(defaults: defaults)
            let alpha = Self.site("Alpha")
            #expect(shell.editSession(for: alpha) == nil)

            shell.presentEditSession(for: alpha)
            let model = try #require(shell.editSession(for: alpha))
            #expect(shell.editingSite == alpha)
            #expect(model.siteDisplayName == "Alpha")

            shell.editingSite = nil
            shell.presentEditSession(for: alpha)
            #expect(shell.editSession(for: alpha) === model)
            #expect(shell.editingSite == alpha)
        }
    }

    @Test("a session that reaches ready marks the site warm; declining the offer clears it")
    func warmSessionBookkeeping() async throws {
        try await withTemporaryUserDefaults { defaults in
            let shell = Self.makeShell(defaults: defaults, pairedMacs: [Self.mac])
            let alpha = Self.site("Alpha")
            shell.discoverySettled(.sites([alpha]))
            shell.presentEditSession(for: alpha)
            let model = try #require(shell.editSession(for: alpha))

            await model.open()
            try await waitUntil("session ready") {
                if case .ready = model.phase { return true }
                return false
            }
            #expect(shell.restoration.warmSessionIDs.contains(alpha.id))
            #expect(shell.warmSites == [alpha])

            shell.declineWarmSession(for: alpha)
            #expect(shell.warmSites.isEmpty)
            await model.stop()
        }
    }

    @Test("with no paired Mac the session lands on pairing and is never marked warm")
    func unpairedSessionIsNotWarm() async throws {
        try await withTemporaryUserDefaults { defaults in
            let shell = Self.makeShell(defaults: defaults)
            let alpha = Self.site("Alpha")
            shell.discoverySettled(.sites([alpha]))
            shell.presentEditSession(for: alpha)
            let model = try #require(shell.editSession(for: alpha))
            await model.open()
            #expect(model.phase == .pairingRequired)
            #expect(shell.warmSites.isEmpty)
        }
    }

    @Test("a warm marker for a site discovery no longer lists resolves to nothing")
    func warmMarkerForVanishedSiteIsHidden() async throws {
        try await withTemporaryUserDefaults { defaults in
            let shell = Self.makeShell(defaults: defaults)
            let alpha = Self.site("Alpha")
            shell.restoration.markSessionWarm(siteID: alpha.id)
            shell.discoverySettled(.sites([Self.site("Beta")]))
            #expect(shell.warmSites.isEmpty)
            shell.discoverySettled(.sites([alpha]))
            #expect(shell.warmSites == [alpha])
        }
    }

    // MARK: - App Intent hand-off

    @Test("an Edit Site request from the router selects that site and presents its session")
    func routerRequestPresentsSession() async throws {
        try await withTemporaryUserDefaults { defaults in
            let router = EditSessionRouter()
            let shell = Self.makeShell(defaults: defaults, router: router)
            let alpha = Self.site("Alpha"), beta = Self.site("Beta")
            shell.discoverySettled(.sites([alpha, beta]))
            shell.selectSite(alpha)

            router.requestEditSession(siteID: beta.id)
            shell.handleEditSessionRequest()

            #expect(shell.selectedSite == beta)
            #expect(shell.editingSite == beta)
            #expect(shell.editSession(for: beta) != nil)
            #expect(router.requestedSiteID == nil, "consumed exactly once")
        }
    }

    @Test("a request for an unknown site is consumed and dropped; no request is a no-op")
    func routerUnknownOrAbsentRequest() async throws {
        try await withTemporaryUserDefaults { defaults in
            let router = EditSessionRouter()
            let shell = Self.makeShell(defaults: defaults, router: router)
            shell.discoverySettled(.sites([Self.site("Alpha")]))

            shell.handleEditSessionRequest()
            #expect(shell.editingSite == nil)

            router.requestEditSession(siteID: UUID())
            shell.handleEditSessionRequest()
            #expect(shell.editingSite == nil)
            #expect(router.requestedSiteID == nil)
        }
    }
}

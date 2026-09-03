import SwiftUI
import AnglesiteCore
import AnglesiteIOS

/// Serializes `MicropubSiteConnectSheet`'s automatic and manual content-import paths
/// (`runAutomaticImportIfNeeded()` / `runManualImport()`) so at most one of them is ever calling
/// `runImportAndPersistCompletion` for a given sheet instance at a time. Without this, tapping
/// "Import Content" while the automatic `.task`-triggered import is still running would let both
/// read the same (stale) `Config/micropubSync.json` sync state, `create` duplicate posts against
/// the live Micropub endpoint, and have whichever `writeSyncState` call finishes last silently
/// overwrite the other's update instead of merging it.
///
/// An `actor` — rather than a `@State private var` `Bool` checked-and-set inline at each call
/// site — so mutual exclusion is enforced by the actor's own serial execution instead of by
/// reasoning that no `await` sneaks in between a check and a set, and so `begin()`/`end()` are
/// directly unit-testable (see `MicropubSiteConnectSheetTests`) without hosting the view or
/// racing real `Task` scheduling.
actor ImportInFlightGate {
    private var inProgress = false

    /// Claims the gate for a new import. Returns `true` (and marks it in-progress) if nothing
    /// else currently holds it; returns `false` without changing state if it's already claimed —
    /// the caller should treat that as "decline to start", not wait.
    func begin() -> Bool {
        guard !inProgress else { return false }
        inProgress = true
        return true
    }

    /// Releases a previously-claimed gate.
    func end() {
        inProgress = false
    }
}

/// Outcome of `MicropubSiteConnectSheet.runImportAndPersistCompletion`: how many files that call
/// imported, and — separately — whether `contentImportCompleted` was actually persisted to disk.
/// The two can diverge: a call that imports `0` files because everything was already synced still
/// has `completed == true`, while a call that imports `0` files because every pending file's
/// `client.create` failed has `completed == false`. Callers must gate any in-memory "done" UI
/// state on `completed`, never on `importedCount` alone or on the function merely having returned
/// — see `runImportAndPersistCompletion`'s doc comment for the two guards that decide it.
struct ImportCompletionResult: Equatable {
    let importedCount: Int
    let completed: Bool
}

/// Mac-side entry point for the same IndieAuth onboarding flow the iOS app already ships (#868)
/// — reused as-is via `MicropubOnboardingModel`, with `SiteMicropubSignIn` (Task A1) standing in
/// as the AppKit `ASWebAuthenticationSession` adapter where iOS drives SwiftUI's
/// `webAuthenticationSession` environment value instead (see `SiteMicropubSignIn.swift`'s doc
/// comment). A successful sign-in leaves a `MicropubSession` resolvable from Keychain for this
/// site (`SecretStore.readMicropubAccessToken(siteID:)`) — the CMS-mode save path (Task A5)
/// checks for exactly that.
///
/// Presented from Website ▸ Connect for CMS Mode… (`WebsiteCommands`); the site is captured at
/// sheet-presentation time from `SiteWindowModel.site`, mirroring how `SiteWindow.swift` already
/// passes `site` into `NewPageSheet`/`NewCollectionEntrySheet` for its other `.sheet(isPresented:)`
/// presentations.
struct MicropubSiteConnectSheet: View {
    let site: SiteStore.Site

    @Environment(\.dismiss) private var dismiss
    @State private var model: MicropubOnboardingModel?
    /// Set when `site.id` (a `String`) doesn't parse as a `UUID` — `SitePickerModel.DiscoveredSite`
    /// requires a real `UUID`, unlike `SiteStore.Site`. This should never happen in practice (both
    /// ultimately trace back to the same `AnglesitePackage.Marker.siteID`), but `configure(site:)`
    /// can't run without one, so this is surfaced rather than silently substituting a fresh
    /// `UUID()` that would scope Keychain reads/writes to the wrong identity.
    @State private var invalidSiteID = false

    /// This site's persisted `SiteSettings.contentImportCompleted`, loaded off the main actor by
    /// `runAutomaticImportIfNeeded()`. `nil` until that load completes — treated the same as "not
    /// completed" by `shouldShowManualImportButton`, so the manual trigger is available
    /// immediately rather than waiting on a disk read.
    @State private var contentImportCompleted: Bool?
    /// Guards `runAutomaticImportIfNeeded()` and `runManualImport()` against running concurrently
    /// for this sheet instance; see `ImportInFlightGate`'s doc comment for why.
    @State private var importGate = ImportInFlightGate()
    /// Mirrors `importGate`'s claimed/released state on the main actor, purely so
    /// `manualImportControl` can render its "Importing…" `ProgressView` while either path holds
    /// the gate — actor state can't be read synchronously from SwiftUI's view body. Set alongside
    /// every `importGate.begin()`/`end()` call; never read or written on its own.
    @State private var importInProgress = false
    /// Set once a manual import completes, so the control shows a brief confirmation instead of
    /// silently vanishing the moment `contentImportCompleted` flips to `true`.
    @State private var manualImportSucceeded = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Connect for CMS Mode")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .padding()
        .frame(minWidth: 380, minHeight: 220)
        // Guarded the same way `SiteSignInScreen.task` guards its `model == nil` check: the
        // outer `NavigationStack`/`content` identity is stable across the state transitions
        // this drives, so `.task` only runs configuration once per sheet presentation.
        .task {
            guard model == nil, !invalidSiteID else { return }
            guard let siteID = UUID(uuidString: site.id) else {
                invalidSiteID = true
                return
            }
            let discovered = SitePickerModel.DiscoveredSite(
                id: siteID, displayName: site.name, packageURL: site.packageURL)
            let model = MicropubOnboardingModel(webAuthenticator: SiteMicropubSignIn())
            self.model = model
            await model.configure(site: discovered)
            await model.refreshConformanceAdvisory()
        }
    }

    @ViewBuilder
    private var content: some View {
        if invalidSiteID {
            ContentUnavailableView {
                Label("Can't Connect", systemImage: "exclamationmark.triangle")
            } description: {
                Text("This site's identity couldn't be read. Try reopening it and connecting again.")
            }
        } else {
            switch model?.state ?? .idle {
            case .idle, .discovering:
                ProgressView("Looking for this site's Micropub endpoint…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsDeployedSite:
                ContentUnavailableView {
                    Label("Not Published Yet", systemImage: "icloud.and.arrow.up")
                } description: {
                    Text("Publish this site at least once before connecting it for CMS mode.")
                }
            case .signedOut:
                signInPrompt(
                    title: Text("Connect This Site"),
                    message: Text(
                        "Sign in with this site's own IndieAuth server to enable editing it as a CMS from other devices."
                    )
                )
            case .exchanging:
                ProgressView("Signing in…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .authorizing:
                // The web-auth sheet is up; this sits behind it.
                ProgressView("Waiting for sign-in…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedIn(let me):
                signedIn(me: me)
            case .cancelled:
                signInPrompt(
                    title: Text("Sign-In Canceled"),
                    message: Text("You closed the sign-in page before finishing. Sign in when you're ready.")
                )
            case .reauthorizationRequired:
                signInPrompt(
                    title: Text("Session Expired"),
                    message: Text("This site signed you out. Sign in again to keep CMS mode connected.")
                )
            case .failed(let reason):
                failure(reason: reason)
            }
        }
    }

    private func signInPrompt(title: Text, message: Text) -> some View {
        VStack(spacing: 12) {
            title.font(.title2.bold())
            message
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Sign In") { Task { await model?.signIn() } }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            ConformanceAdvisoryLabel(advisory: model?.conformanceAdvisory)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signedIn(me: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Connected")
                .font(.title2.bold())
            Text(verbatim: me)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            if Self.shouldShowManualImportButton(contentImportCompleted: contentImportCompleted) {
                manualImportControl
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            ConformanceAdvisoryLabel(advisory: model?.conformanceAdvisory)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One-time import of this site's existing typed content into D1 (Task B1/B2, spec §C.7).
        // `micropubClient` is only non-nil right after a fresh `signIn()` — a session restored
        // from Keychain on `configure(site:)` leaves it `nil` (endpoint discovery isn't
        // persisted), so this simply loads the completion flag for `manualImportControl` and
        // no-ops otherwise; the manual button below is the path for that (common — sign in once,
        // reopen the app later) case.
        .task { await runAutomaticImportIfNeeded() }
    }

    /// The manual "Import Content" control shown below the connected state whenever this site's
    /// import hasn't completed (`shouldShowManualImportButton`) — the discoverable path for the
    /// common case where `model.micropubClient` is `nil` (a restored session, not a fresh
    /// sign-in) so the automatic `.task` above never ran the import.
    @ViewBuilder
    private var manualImportControl: some View {
        if importInProgress {
            ProgressView("Importing…")
        } else if manualImportSucceeded {
            Label("Content Imported", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Button("Import Content") { Task { await runManualImport() } }
                .buttonStyle(.bordered)
        }
    }

    /// Whether `manualImportControl` should be shown: whenever this site's persisted
    /// `contentImportCompleted` isn't explicitly `true`, including `nil` (not loaded yet, or
    /// genuinely never run) — pulled out as a pure static function so the condition is testable
    /// without hosting the view.
    static func shouldShowManualImportButton(contentImportCompleted: Bool?) -> Bool {
        contentImportCompleted != true
    }

    /// Auto-triggered once per sheet presentation while `.signedIn` is showing (Task B2, spec
    /// §C.7). Loads the persisted completion flag for `manualImportControl` regardless of
    /// outcome; only actually runs the import when a fresh sign-in populated
    /// `model.micropubClient`, the site hasn't imported yet, and `importGate` isn't already
    /// claimed by a concurrent `runManualImport()` — see `ImportInFlightGate`'s doc comment.
    private func runAutomaticImportIfNeeded() async {
        // `SiteConfigStore.load()` (the actor-isolated instance method) hops off the main actor
        // for its file I/O, unlike the synchronous `SiteConfigStore.read(from:)` seam — this
        // `.task` runs under a SwiftUI view, i.e. on the main actor, so blocking here would stall
        // the UI (same hazard `MicropubOnboardingModel.configure`'s `Task.detached` and
        // `StoredMicropubSessions.session` both route around).
        let loaded = (try? await SiteConfigStore(configDirectory: site.configDirectory).load()) ?? SiteSettings()
        contentImportCompleted = loaded.contentImportCompleted
        guard loaded.contentImportCompleted != true, let client = model?.micropubClient else { return }
        guard await importGate.begin() else { return }
        importInProgress = true
        let result = await Self.runImportAndPersistCompletion(
            siteDirectory: site.sourceDirectory, configDirectory: site.configDirectory, client: client)
        // `result.completed` already reflects both guards `runImportAndPersistCompletion` applies
        // before persisting `contentImportCompleted` to disk — the calling `.task` being cancelled
        // (the view disappearing mid-import) and any pending file still left unsynced after a
        // per-file failure — so mirroring it directly here can't drift from the disk state it's
        // supposed to reflect, with no way to retrigger the import short of relaunching.
        if result.completed {
            contentImportCompleted = true
        }
        await releaseImportGate()
    }

    /// `manualImportControl`'s button action: resolves a Micropub client without forcing a fresh
    /// interactive sign-in. Reuses `model.micropubClient` when a sign-in just happened in this
    /// sheet presentation; otherwise resolves one from the already-stored Keychain credential via
    /// `StoredMicropubSessions` — the same resolver `MicropubSession`'s doc comment names as "the
    /// composer's own flow" for re-discovering the endpoint after a restored session, so this
    /// never re-prompts the user.
    ///
    /// Declines to start (a no-op return) if `importGate` is already claimed by a concurrent
    /// `runAutomaticImportIfNeeded()`; see `ImportInFlightGate`'s doc comment.
    private func runManualImport() async {
        guard await importGate.begin() else { return }
        importInProgress = true

        guard let client = await resolveClient() else {
            await releaseImportGate()
            return
        }
        let result = await Self.runImportAndPersistCompletion(
            siteDirectory: site.sourceDirectory, configDirectory: site.configDirectory, client: client)
        // Only claim success (and hide the button behind `contentImportCompleted`) when
        // `result.completed` says the persisted flag actually flipped — i.e. nothing is left
        // pending. A total or partial failure (expired token, endpoint unreachable, network down
        // mid-import) must leave both flags alone so `manualImportControl` keeps showing the
        // "Import Content" button rather than stranding the owner on a run that made no progress.
        if result.completed {
            contentImportCompleted = true
            manualImportSucceeded = true
        }
        await releaseImportGate()
    }

    /// Releases `importGate` and clears its main-actor UI mirror together, so the two never drift
    /// apart. Called at every exit path of `runAutomaticImportIfNeeded()` / `runManualImport()`
    /// that follows a successful `importGate.begin()`.
    private func releaseImportGate() async {
        importInProgress = false
        await importGate.end()
    }

    /// A ready-to-use Micropub client for this site, without prompting for sign-in: a fresh
    /// sign-in's client when one is available, else one resolved from the stored Keychain
    /// credential (`nil` if the site was never signed in, or the credential is gone and needs
    /// re-auth — the "Session Expired" state handles that separately).
    private func resolveClient() async -> MicropubClient? {
        if let client = model?.micropubClient { return client }
        return await StoredMicropubSessions()
            .session(siteID: site.id, sourceDirectory: site.sourceDirectory)?
            .makeClient()
    }

    /// Runs the one-time content import, then persists `contentImportCompleted = true` — but only
    /// when doing so is actually true. Two independent gates must both pass first:
    ///
    /// 1. `isCancelled()` must report the calling task was **not** cancelled. SwiftUI cancels a
    ///    `.task` when its view disappears (e.g. the user taps Done while the automatic import is
    ///    still running), but `MicropubContentImport.importIfNeeded` never throws or checks
    ///    `Task.isCancelled` itself — per-file failures, cancellation included, are caught and
    ///    logged rather than propagated — so the import keeps running to completion regardless.
    /// 2. `MicropubContentImport.unsyncedFileCount` must report `0` pending files afterward.
    ///    `importIfNeeded`'s own `Int` return only counts files imported *this call* — it can't
    ///    distinguish "nothing left to import" from "ran, but some or every file failed" (an
    ///    expired token, an unreachable endpoint, the network dropping mid-import all land here),
    ///    since a per-file `client.create` failure is caught and logged rather than surfaced. A
    ///    site whose files all failed would otherwise come back with `imported == 0` and still get
    ///    marked done.
    ///
    /// Without both guards, a sheet dismissed mid-import or a transient/total import failure would
    /// still get marked "done", permanently hiding `manualImportControl`'s retry button with no
    /// UI-visible way to retrigger the import short of hand-editing `Config/settings.plist`.
    /// `isCancelled` is injectable so tests can exercise cancellation deterministically instead of
    /// racing real `Task` cancellation timing.
    ///
    /// - Parameters:
    ///   - siteDirectory: The site's `Source/` directory.
    ///   - configDirectory: The site's `Config/` directory.
    ///   - client: The Micropub client to import through.
    ///   - isCancelled: Reports whether the calling task was cancelled; defaults to the real
    ///     `Task.isCancelled`.
    /// - Returns: The number of files imported this call (see
    ///   `MicropubContentImport.importIfNeeded`), and whether `contentImportCompleted` was
    ///   actually persisted to disk. Callers must gate any in-memory "done" mirror on `completed`,
    ///   not merely on this function having returned.
    static func runImportAndPersistCompletion(
        siteDirectory: URL, configDirectory: URL, client: MicropubClient,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) async -> ImportCompletionResult {
        let imported = await MicropubContentImport.importIfNeeded(
            siteDirectory: siteDirectory, configDirectory: configDirectory, client: client)
        guard !isCancelled() else { return ImportCompletionResult(importedCount: imported, completed: false) }
        let stillPending = MicropubContentImport.unsyncedFileCount(
            siteDirectory: siteDirectory, configDirectory: configDirectory)
        guard stillPending == 0 else {
            return ImportCompletionResult(importedCount: imported, completed: false)
        }
        var settings = (try? await SiteConfigStore(configDirectory: configDirectory).load()) ?? SiteSettings()
        settings.contentImportCompleted = true
        try? await SiteConfigStore(configDirectory: configDirectory).save(settings)
        return ImportCompletionResult(importedCount: imported, completed: true)
    }

    @ViewBuilder
    private func failure(reason: MicropubOnboardingModel.FailureReason) -> some View {
        switch reason {
        case .micropubNotSupported:
            ContentUnavailableView {
                Label("CMS Mode Not Available", systemImage: "server.rack")
            } description: {
                Text("This site's Worker doesn't include Micropub yet. Redeploy it with a current Anglesite build.")
            }
        case .indieAuthNotSupported:
            ContentUnavailableView {
                Label("Sign-In Not Available", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("This site doesn't offer IndieAuth sign-in yet. Redeploy it with a current Anglesite build.")
            }
        case .siteUnreachable:
            ContentUnavailableView {
                Label("Site Unreachable", systemImage: "wifi.slash")
            } description: {
                Text("Couldn't reach this site. Check your connection and try again.")
            } actions: {
                retryButton
            }
        case .signInFailed:
            ContentUnavailableView {
                Label("Sign-In Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Something went wrong while signing in. Try again.")
            } actions: {
                retryButton
            }
        }
    }

    private var retryButton: some View {
        Button("Try Again") { Task { await model?.signIn() } }
            .buttonStyle(.borderedProminent)
    }
}

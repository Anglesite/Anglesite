import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AnglesiteCore
import AnglesiteIntents

/// The "Sites" launcher window: a list of known sites plus actions to open an
/// existing one or add a folder to the registry. This is the single entry point
/// to a site window now that there's no in-window sidebar.
///
/// Launch behavior: on the very first appearance of *this app session* the
/// launcher checks `AppSettings.lastOpenedSiteID`. If that site is still valid,
/// the launcher opens its window and dismisses itself — the user lands in the
/// site they were last working in. On subsequent appearances (the user re-opens
/// the launcher from the Window menu or the dock), no autoopen occurs.
struct SitesLauncherView: View {
    /// Tracks whether the autoopen attempt has already happened this app session.
    /// Static so re-instantiations of the view (e.g. after the user closes and
    /// reopens the launcher) don't retrigger the MRU path.
    private static var didAutoOpenAttempt = false

    @State private var sites: [SiteStore.Site] = []
    /// Drives a visible highlight while a file-URL drag hovers `siteList` (#676). Lights up for
    /// any file-URL drag, not only valid `.anglesite` packages — see the design doc's "Drop-
    /// highlight fidelity" decision. The drop itself still only accepts `.anglesite` packages,
    /// unchanged below.
    @State private var isDropTargeted = false
    /// Non-nil while the quick-capture compose sheet is up (launcher flow, #531); carries the
    /// dropped/pasted URL pre-fill ("" for the menu path with no URL on the clipboard).
    @State private var quickCaptureRequest: QuickCaptureRequest?

    private struct QuickCaptureRequest: Identifiable {
        let id = UUID()
        let urlString: String
    }
    @State private var loadError: String?
    @State private var deciding = true
    /// Guards `presentNewSite()` against a double-trigger while it is preparing (it `await`s
    /// before `newSiteSession` is set, so two near-simultaneous callers could both pass a
    /// `newSiteSession == nil` check). Reset via `defer` on every exit path.
    @State private var preparingNewSite = false
    /// The site awaiting a remove confirmation, or nil when no prompt is up. Drives the
    /// `.confirmationDialog`; SwiftUI clears it (via the `isPresented` binding) when any dialog
    /// button is tapped.
    @State private var siteToRemove: SiteStore.Site?
    /// The name shown in the confirmation title. Held separately from `siteToRemove` so the title
    /// stays stable through the dismiss animation — reading `siteToRemove?.name` directly would
    /// collapse to "" the instant the dialog clears the optional.
    @State private var siteToRemoveName = ""
    /// The site awaiting a rename, or nil when no rename prompt is up. Drives the rename `.alert`.
    @State private var siteToRename: SiteStore.Site?
    /// Bound to the rename alert's text field; seeded with the current name when the prompt opens.
    @State private var renameText = ""
    private struct NewSiteSession: Identifiable {
        let id = UUID()
        let model: NewSiteWizardModel
        let scaffolder: SiteScaffolder
        let templateURL: URL
    }
    /// Non-nil while the New Site wizard is showing; nil dismisses it.
    @State private var newSiteSession: NewSiteSession?
    private struct NewCommunitySession: Identifiable {
        let id = UUID()
        let model: NewCommunityWizardModel
        let scaffolder: SiteScaffolder
    }
    /// Non-nil while the New Community wizard is showing; nil dismisses it.
    @State private var newCommunitySession: NewCommunitySession?
    /// Guards `presentNewCommunity()` against a double-trigger while it is preparing — mirrors
    /// `preparingNewSite`'s note above.
    @State private var preparingNewCommunity = false
    @State private var sitesRootScopedURL: URL?
    @State private var router = WindowRouter.shared

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if deciding {
                // Render nothing while we decide whether to autoopen — avoids a
                // visible flash of the picker before we dismiss ourselves. Also stays up
                // (instead of the full picker) while a requested New Site wizard is
                // preparing/showing — see onFirstAppear(). Same frame as `launcherUI` so
                // the window doesn't resize when this flips.
                Color(NSColor.windowBackgroundColor)
                    .frame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 480)
            } else {
                launcherUI
            }
        }
        .task { await onFirstAppear() }
        .task { await observeChanges() }
        .onChange(of: router.newSiteRequested) { _, requested in
            guard requested else { return }
            router.clearNewSiteRequest()
            Task { await presentNewSite() }
        }
        .onChange(of: router.newCommunityRequested) { _, requested in
            guard requested else { return }
            router.clearNewCommunityRequest()
            Task { await presentNewCommunity() }
        }
        .onChange(of: router.quickCaptureRequested) { _, requested in
            guard requested else { return }
            router.clearQuickCaptureRequest()
            quickCaptureRequest = QuickCaptureRequest(urlString: QuickCapture.clipboardURLString() ?? "")
        }
        .onPasteCommand(of: [.url]) { _ in
            guard let urlString = QuickCapture.clipboardURLString() else { return }
            quickCaptureRequest = QuickCaptureRequest(urlString: urlString)
        }
        .sheet(item: $quickCaptureRequest) { request in
            QuickCaptureSheet(
                pickerSites: sites,
                defaultSiteID: AppSettings.shared.lastOpenedSiteID,
                initialURLString: request.urlString,
                fetchMetadata: { try await LinkMetadataFetcher().fetch(url: $0) },
                onCreate: { siteID, title, urlString, commentary, imageURL, draft in
                    guard let siteID else { return .failed(reason: "Choose a site for this link post.") }
                    // Windowless: the entry is written and committed; a Publish here saves it
                    // draft: false and it goes live with the site's next deploy (spec §3.3 —
                    // capture never boots a container).
                    return await QuickCapture.createLinkPost(
                        siteID: siteID, title: title, urlString: urlString,
                        commentary: commentary, imageURL: imageURL, draft: draft)
                }
            )
        }
        // Attached here (not inside `launcherUI`) so it still presents while `deciding`
        // is showing the blank placeholder above — a File ▸ New Site launch keeps
        // `deciding` true so only the wizard sheet is visible, not the full Sites picker
        // opening behind it (#928).
        .sheet(item: $newSiteSession) { session in
            NewSiteWizard(
                model: session.model,
                scaffolder: session.scaffolder,
                templateURL: session.templateURL,
                onComplete: { siteID in
                    newSiteSession = nil
                    Task {
                        await refreshSites()
                        openWindow(value: siteID)
                        dismissWindow()
                    }
                },
                onCancel: {
                    newSiteSession = nil
                    // Reveal the picker now that the wizard is gone — mirrors the
                    // presentNewSite()-failed path in onFirstAppear() below.
                    deciding = false
                }
            )
            .onDisappear {
                sitesRootScopedURL?.stopAccessingSecurityScopedResource()
                sitesRootScopedURL = nil
            }
        }
        .sheet(item: $newCommunitySession) { session in
            NewCommunityWizard(
                model: session.model,
                scaffolder: session.scaffolder,
                onComplete: { siteID in
                    newCommunitySession = nil
                    Task {
                        await refreshSites()
                        openWindow(value: siteID)
                        dismissWindow()
                    }
                },
                onCancel: {
                    newCommunitySession = nil
                    deciding = false
                }
            )
            .onDisappear {
                sitesRootScopedURL?.stopAccessingSecurityScopedResource()
                sitesRootScopedURL = nil
            }
        }
        .navigationTitle("Sites")
    }

    private var launcherUI: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let loadError {
                errorState(loadError)
            } else if sites.isEmpty {
                emptyState
            } else {
                siteList
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 480)
    }

    private var header: some View {
        HStack {
            Text("Sites").font(.title2.bold())
            Spacer()
            Button("Reload sites", systemImage: "arrow.clockwise") {
                Task { await refreshSites() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Reload site list")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var siteList: some View {
        List(sites) { site in
            Button {
                open(site: site)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: site.isValid
                          ? "checkmark.circle.fill"
                          : "exclamationmark.triangle.fill")
                        .foregroundStyle(site.isValid ? Color.green : Color.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(site.name).font(.body.monospaced())
                        Text(site.packageURL.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            // A dead bookmark (needsReauthorization) still lets the row respond to a click — it
            // routes to the same "Locate…" recovery as the context-menu action — rather than
            // going fully dead with no way to fix it in place (#776).
            .disabled(!site.isValid && !site.needsReauthorization)
            // Draggable out to Finder/Terminal/another app (#676) — offers the package URL
            // regardless of validity (a dead bookmark is still a real path on disk), and must
            // come AFTER .disabled(...) above so the drag isn't scoped inside that disabled
            // subtree — otherwise a row with missing files couldn't be dragged out at all,
            // contradicting this comment.
            .draggable(site.packageURL)
            .accessibilityValue(site.isValid
                                 ? "Valid"
                                 : (site.needsReauthorization ? "Needs re-authorization" : "Missing required files"))
            .help(helpText(for: site))
            .contextMenu {
                if site.needsReauthorization {
                    Button("Locate…", systemImage: "questionmark.folder") {
                        Task { await reauthorize(site) }
                    }
                }
                Button("Rename…", systemImage: "pencil") {
                    promptRename(site)
                }
                Button("Remove from Anglesite…", systemImage: "minus.circle", role: .destructive) {
                    promptRemove(site)
                }
            }
            .swipeActions(edge: .trailing) {
                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                    promptRemove(site)
                }
            }
        }
        .listStyle(.inset)
        // Accept `.anglesite` packages dragged from Finder (#524) — same register path as
        // Finder double-click (`onOpenURL`), including the MAS bookmark mint (a user drag
        // conveys sandbox access to the dragged item).
        .dropDestination(for: URL.self) { urls, _ in
            // A link dragged from a browser → quick capture with the site picker (#531).
            if let web = QuickCapture.webURL(from: urls) {
                quickCaptureRequest = QuickCaptureRequest(urlString: web.absoluteString)
                return true
            }
            let packages = urls.filter { $0.pathExtension == AnglesitePackage.packageExtension }
            guard !packages.isEmpty else { return false }
            Task { @MainActor in
                for url in packages {
                    do {
                        let site = try await SiteActions.registerPackage(at: url)
                        openWindow(value: site.id)
                    } catch {
                        NSAlert(error: SiteActions.ImportError(
                            folderName: url.lastPathComponent, underlying: error
                        )).runModal()
                    }
                }
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            // Explicit targeted feedback (#676) — the system's default drag highlight is subtle
            // enough that #524's drop target had no clearly visible accepted/rejected state.
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            "Remove “\(siteToRemoveName)” from Anglesite?",
            isPresented: Binding(
                get: { siteToRemove != nil },
                set: { if !$0 { siteToRemove = nil } }
            ),
            titleVisibility: .visible,
            presenting: siteToRemove
        ) { site in
            Button("Remove from Anglesite", role: .destructive) { removeSite(site) }
            Button("Cancel", role: .cancel) {}
        } message: { site in
            // Removal only forgets the site here — the package on disk is untouched, matching
            // `SiteStore.remove(id:)`. Owners can still open it in Finder, VS Code, or the CLI.
            Text("This removes it from Anglesite's list only. The files in \(site.packageURL.path) are left on disk.")
        }
        .alert(
            "Rename Site",
            isPresented: Binding(
                get: { siteToRename != nil },
                set: { if !$0 { siteToRename = nil } }
            )
        ) {
            TextField("Site name", text: $renameText)
            Button("Rename") { if let site = siteToRename { commitRename(site) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sets a display name just for Anglesite. Leave blank to use the site's built-in name.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text("No Anglesite sites found")
                .font(.headline)
            Text("Create one with **Add Site → Create new site…**, or use **Add Site → Import existing site…** to add an existing `.anglesite` package.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle).foregroundStyle(.orange)
            Text("Couldn't load sites").font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("Retry") { Task { await refreshSites() } }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Menu {
                Button("Create new site…") { Task { await presentNewSite() } }
                Button("Import existing site…") { openFolder() }
            } label: {
                Label("Add Site", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    /// The row tooltip: names the actual problem rather than a generic disabled state. A dead
    /// bookmark (needsReauthorization) is not the same failure as missing project files, and
    /// reporting it as such sends owners chasing a fix that doesn't exist (#776).
    private func helpText(for site: SiteStore.Site) -> String {
        if site.isValid {
            return "Open \(site.name) in its own window"
        }
        if site.needsReauthorization {
            return "Anglesite lost access to this site, likely after a restart. Click to relocate it and restore access."
        }
        return "Site is missing required files: \(site.missingSentinels.joined(separator: ", "))"
    }

    private func open(site: SiteStore.Site) {
        guard site.isValid else {
            Task { await reauthorize(site) }
            return
        }
        openWindow(value: site.id)
        dismissWindow()
    }

    /// Re-grant access to `site` (#776) via `SiteActions.reauthorize` — an `NSOpenPanel` anchored
    /// at its last-known path, confirmed to be the same package by marker UUID. A successful heal
    /// reaches this view through `observeChanges()`'s `SiteStore.changeStream()` subscription, so
    /// there's no need to patch `sites` here directly; go ahead and open the now-healed site.
    private func reauthorize(_ site: SiteStore.Site) async {
        do {
            guard let healed = try await SiteActions.reauthorize(site) else { return }
            openWindow(value: healed.id)
            dismissWindow()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Raise the remove-confirmation dialog for `site`. `siteToRemoveName` is captured here so the
    /// dialog title survives the dismiss animation (see the property's note).
    private func promptRemove(_ site: SiteStore.Site) {
        siteToRemoveName = site.name
        siteToRemove = site
    }

    /// Open the rename alert for `site`, seeding the field with its current name.
    private func promptRename(_ site: SiteStore.Site) {
        renameText = site.name
        siteToRename = site
    }

    /// Persist a display-name override for `site` via `SiteStore.setDisplayName` (blank clears it
    /// back to the marker name) and refresh the local list. An open `SiteWindow` for this site
    /// updates its title independently — it observes `SiteStore.changeStream()`.
    private func commitRename(_ site: SiteStore.Site) {
        Task {
            do {
                guard let updated = try await SiteStore.shared.setDisplayName(renameText, for: site.id) else { return }
                if let index = sites.firstIndex(where: { $0.id == updated.id }) {
                    sites[index].name = updated.name
                }
            } catch {
                loadError = "Couldn't rename \(site.name): \(error)"
            }
        }
    }

    /// Forget `site` from the registry without touching its files. On MAS this also drops the
    /// site's persisted security-scoped bookmark, since that lives inline in the `Site` entry.
    /// We prune the local list directly rather than re-running `refreshSites()`: the registry no
    /// longer scans `~/Sites`, so removal is permanent until the package is re-opened.
    ///
    /// An already-open `SiteWindow` for this site auto-closes: it observes `SiteStore.changeStream()`
    /// and dismisses itself when its id leaves the registry, which tears down its dev-server/MCP
    /// subprocess via `onDisappear` (#188).
    private func removeSite(_ site: SiteStore.Site) {
        Task {
            do {
                try await SiteStore.shared.remove(id: site.id)
                sites.removeAll { $0.id == site.id }
            } catch {
                loadError = "Couldn't remove \(site.name): \(error)"
            }
        }
    }

    private func openFolder() {
        Task {
            do {
                guard let site = try await SiteActions.pickAndRegisterSite() else { return }
                await refreshSites()
                open(site: site)
            } catch {
                // `SiteActions.ImportError.localizedDescription` names the package and the reason.
                loadError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func presentNewSite() async {
        guard newSiteSession == nil, !preparingNewSite else { return }
        preparingNewSite = true
        defer { preparingNewSite = false }
        guard let context = await SiteActions.resolveScaffoldingContext() else { return }
        sitesRootScopedURL = context.sitesRootAccess
        let model = NewSiteWizardModel(catalog: context.catalog, isNameTaken: context.isNameTaken)
        newSiteSession = NewSiteSession(model: model, scaffolder: context.scaffolder, templateURL: context.templateURL)
    }

    @MainActor
    private func presentNewCommunity() async {
        guard newCommunitySession == nil, !preparingNewCommunity else { return }
        preparingNewCommunity = true
        defer { preparingNewCommunity = false }
        guard let context = await SiteActions.resolveScaffoldingContext() else { return }
        sitesRootScopedURL = context.sitesRootAccess
        let model = NewCommunityWizardModel(isNameTaken: context.isNameTaken)
        newCommunitySession = NewCommunitySession(model: model, scaffolder: context.scaffolder)
    }

    // MARK: - Lifecycle

    private func onFirstAppear() async {
        await refreshSites()

        // A File ▸ New Site that opened this launcher set the flag before our `.task` ran;
        // `.onChange` won't fire for that initial value, so consume it here.
        if router.newSiteRequested {
            router.clearNewSiteRequest()
            await presentNewSite()
            // Leave `deciding` true when presentNewSite() succeeded — the wizard sheet
            // (attached at the body level) then appears over a blank window instead of
            // flashing the full Sites picker first (#928). If it didn't produce a session
            // (template/theme load failure, or the MAS sites-root access panel was
            // cancelled), fall through to the picker so the resulting error/list is
            // visible instead of a dead blank window.
            if newSiteSession == nil {
                deciding = false
            }
            return
        }

        // Mirrors the New Site consume above, for File ▸ New Community.
        if router.newCommunityRequested {
            router.clearNewCommunityRequest()
            await presentNewCommunity()
            if newCommunitySession == nil {
                deciding = false
            }
            return
        }

        if !Self.didAutoOpenAttempt {
            Self.didAutoOpenAttempt = true
            if let id = AppSettings.shared.lastOpenedSiteID,
               sites.contains(where: { $0.id == id && $0.isValid }) {
                openWindow(value: id)
                dismissWindow()
                return
            }
        }
        deciding = false
    }

    private func refreshSites() async {
        do {
            try await SiteStore.shared.load()
            sites = await SiteStore.shared.sites
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
    }

    /// Mirrors `RecentSitesModel`'s subscription: keeps the launcher's list live across any
    /// registry mutation from elsewhere in the app — Open Site…, the Dock menu, drag-drop, or a
    /// "Locate…" reauthorization — not just this view's own `refreshSites()` calls. Before this,
    /// a site opened successfully via ⌘O in the same session still showed ⚠ here until the next
    /// manual reload (#776).
    private func observeChanges() async {
        for await updated in SiteStore.shared.changeStream() {
            sites = updated
        }
    }
}

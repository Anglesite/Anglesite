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
    /// The selected row's site id (#1641). Rows used to be `Button`s in a selection-less `List`,
    /// which left the list's `AXRow`s unselectable and without an `AXShowMenu` action — the only
    /// menu hook was on the inner button, and performing it there failed and dropped focus, so
    /// Full Keyboard Access (⌃Return / the Menu key) and VoiceOver could never reach a row's
    /// context menu. Native `List(selection:)` rows are what those paths target.
    @State private var selectedSiteID: SiteStore.Site.ID?

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
        List(sites, selection: $selectedSiteID) { site in
            siteRow(site)
        }
        .listStyle(.inset)
        .accessibilityIdentifier(AXID.launcherList)
        // The row menu lives on the list, keyed by selection (#1641), rather than as a
        // `.contextMenu` on each row's content: this is the form AppKit's table rows expose as
        // the row-level `AXShowMenu` action, which is what Full Keyboard Access (⌃Return / the
        // Menu key) and VoiceOver (VO-Shift-M) invoke on the focused row. SwiftUI hands the
        // closure the right-clicked row's id when the click lands outside the selection, so a
        // mouse right-click still acts on the clicked row, not the selection (#680). Double-click
        // is the primary action (open); Return does the same via the hidden default button below.
        .contextMenu(forSelectionType: SiteStore.Site.ID.self) { ids in
            if let site = site(for: ids) {
                rowMenu(for: site)
            }
        } primaryAction: { ids in
            if let site = site(for: ids) {
                open(site: site)
            }
        }
        .background {
            // Return opens the selected site — the launcher's default action, same shape as the
            // navigator's Return-to-rename affordance. Hidden from the Tab loop and VoiceOver:
            // it is a key equivalent, not a control.
            Button("") {
                if let site = selectedSite {
                    open(site: site)
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .hidden()
            .accessibilityHidden(true)
            .disabled(selectedSite == nil)
        }
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

    private func siteRow(_ site: SiteStore.Site) -> some View {
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
        .padding(.vertical, 2)
        // A site with missing project files can't be opened, but its row stays selectable so the
        // context menu (Remove from Anglesite…) is reachable by keyboard — dim it rather than
        // `.disabled(...)`, which would also strip the row out of the keyboard/AT path.
        .opacity(site.isValid || site.needsReauthorization ? 1 : 0.5)
        // Draggable out to Finder/Terminal/another app (#676) — offers the package URL
        // regardless of validity (a dead bookmark is still a real path on disk).
        .draggable(site.packageURL)
        // One AX element per row (name + path as the label), matching what the old button read
        // out, with the validity as its value.
        .accessibilityElement(children: .combine)
        .accessibilityValue(site.isValid
                             ? "Valid"
                             : (site.needsReauthorization ? "Needs re-authorization" : "Missing required files"))
        .help(helpText(for: site))
        .swipeActions(edge: .trailing) {
            Button("Remove", systemImage: "minus.circle", role: .destructive) {
                promptRemove(site)
            }
        }
    }

    /// The row context menu (#1641) — see `siteList` for why it's attached via
    /// `contextMenu(forSelectionType:)` rather than per row.
    @ViewBuilder
    private func rowMenu(for site: SiteStore.Site) -> some View {
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

    private var selectedSite: SiteStore.Site? {
        sites.first { $0.id == selectedSiteID }
    }

    /// The single site a selection-keyed menu/primary action refers to. The list is
    /// single-select, so `ids` holds at most one id; empty means the click landed on no row.
    private func site(for ids: Set<SiteStore.Site.ID>) -> SiteStore.Site? {
        guard let id = ids.first else { return nil }
        return sites.first { $0.id == id }
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
            return String(localized: "Double-click to open \(site.name) in its own window")
        }
        if site.needsReauthorization {
            return String(localized: "Anglesite lost access to this site, likely after a restart. Double-click to relocate it and restore access.")
        }
        return String(localized: "Site is missing required files: \(site.missingSentinels.joined(separator: ", "))")
    }

    /// The row's primary action (double-click / Return). A dead bookmark routes to the same
    /// "Locate…" recovery as the context-menu action (#776); a site with missing project files
    /// has nothing to open — its tooltip names the problem and the row menu offers removal.
    private func open(site: SiteStore.Site) {
        if site.isValid {
            openWindow(value: site.id)
            dismissWindow()
        } else if site.needsReauthorization {
            Task { await reauthorize(site) }
        }
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
        // A File ▸ New Site that follows hot on a just-dismissed wizard (Esc, then immediately
        // reopening) can land this sheet's presentation transaction on top of the previous one's
        // still-settling dismissal — back-to-back `.sheet(item:)` presentations, the same macOS 27
        // beta AppKit constraint-update storm as #1126/#1139, and the same shape
        // `SiteWindowModel.loadAndStart`'s dependency-sheet-to-scripts-sheet handoff already guards
        // with this mitigation. Crash: Anglesite-2026-08-27-101104.ips (#1639).
        await AppKitConstraintStormMitigation.settle()
        guard let context = await SiteActions.resolveScaffoldingContext(onFailure: { loadError = $0 }) else { return }
        sitesRootScopedURL = context.sitesRootAccess
        let model = NewSiteWizardModel(catalog: context.catalog, isNameTaken: context.isNameTaken)
        newSiteSession = NewSiteSession(model: model, scaffolder: context.scaffolder, templateURL: context.templateURL)
    }

    @MainActor
    private func presentNewCommunity() async {
        guard newCommunitySession == nil, !preparingNewCommunity else { return }
        preparingNewCommunity = true
        defer { preparingNewCommunity = false }
        // Same #1639/#1126-class guard as `presentNewSite()` above — this sheet is presented the
        // same way, from the same view, so it's exposed to the same back-to-back-presentation race.
        await AppKitConstraintStormMitigation.settle()
        guard let context = await SiteActions.resolveScaffoldingContext(onFailure: { loadError = $0 }) else { return }
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

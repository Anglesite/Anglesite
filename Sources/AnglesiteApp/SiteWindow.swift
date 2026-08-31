import SwiftUI
import UniformTypeIdentifiers
import WebKit
import AnglesiteCore
import AnglesiteIntents

/// Root view for a single per-site window. Per-site orchestration lives in
/// `SiteWindowModel`; this type owns only SwiftUI layout and scene-scoped UI state.
///
/// Multi-window invariant: every site window stands alone. Closing one does not
/// affect the others, and SwiftUI dedupes `openWindow(value: id)` calls — opening
/// the same site twice just focuses the existing window.
struct SiteWindow: View {
    /// Optional because SwiftUI may restore a `WindowGroup(for: String.self)` with a
    /// nil payload — see `SiteWindowModel.loadAndStart` for how that's handled.
    let siteID: String?

    private let contentTypeRegistry = ContentTypeRegistry()
    @State private var model: SiteWindowModel

    /// Sidebar visibility persisted per scene (window), per the design spec. Column WIDTH is restored
    /// automatically by `NavigationSplitView`'s own scene state, so only explicit visibility is wired.
    @SceneStorage("siteNavigator.sidebarVisible") private var sidebarVisible = true
    /// Inspector visibility, persisted per window. Defaults to shown (auto-open); the toolbar toggle
    /// flips it and the choice persists across selections.
    @SceneStorage("siteInspector.shown") private var inspectorShown = true
    /// WYSIWYG block palette visibility (#1588 Task 20). Unlike `inspectorShown`, this isn't
    /// persisted across launches — the palette is only meaningful while Site ▸ Edit Page is on
    /// (see the toolbar item's `.disabled`), so there's no stable state to restore between runs.
    @State private var showWYSIWYGPalette = false
    /// Which inspector occupies the trailing panel while `inspectorShown` is true (#714 v2 slice
    /// 1): the existing per-selection inspector, or the new Website inspector. Mutually exclusive
    /// — switching one on switches the other off. Persisted per window like `inspectorShown`.
    @SceneStorage("siteInspector.active") private var activeInspector: ActiveSiteInspector = .selection
    /// Suppresses exactly one stale `inspectorPresented` write-back scheduled under the inspector
    /// kind active BEFORE a switch (#714 v2 slice 1 fix round 1, Important 1 — reopens #968/#969
    /// through the new activation seam). SwiftUI's automatic `isPresented = false` collapse
    /// write-back on a transient-nil selection is asynchronous (see the #968/#969 comment at
    /// `SiteWindowModel.applyNavigatorSelection`): if the user switches `activeInspector` between
    /// the moment that write-back is queued and the moment it lands, the binding setter's guard
    /// would re-read under the NEW activation and wrongly persist `inspectorShown = false` on the
    /// panel the user just opened. `toggleSelectionInspector()`/`toggleWebsiteInspector()` set
    /// this synchronously in the same transaction that switches `activeInspector`, and clear it
    /// one run-loop turn later — same "defer a turn" idiom as `MarkdownFindBar`'s focus
    /// workaround — long enough for an already-queued stale write-back to land and be swallowed,
    /// short enough that a later, genuine write-back for the NEW activation isn't suppressed too.
    @State private var suppressNextInspectorWriteBack = false
    /// Temporarily withholds the website inspector from the panel across a main-pane swap (#714 v2
    /// slice 1 fix round 6) — the state behind `SiteWindowModel.setWebsiteInspectorSuspended`.
    ///
    /// Deliberately `@State`, not `@SceneStorage`: this is a transient, app-initiated *withholding*
    /// of a panel the user still wants, not a change of their mind about it. Fix round 5 implemented
    /// the same dismissal by routing through `activateInspector(.website)`, which wrote
    /// `inspectorShown = false` into scene storage — so Metadata ▸ More Settings… (a button *inside*
    /// the panel, whose `openFile` goes through `clearInspectorThenSwitchPane`) permanently closed
    /// the panel and the closure survived relaunch, with no way back except ⌥⌘J. Suspension keeps
    /// `inspectorShown`/`activeInspector` untouched, so the preference is preserved and the panel
    /// returns on its own once the swap has settled.
    ///
    /// Set true by `suspendWebsiteInspector(_:)` before the pane swap and false by the same seam
    /// after it — `SiteWindowModel.clearInspectorThenSwitchPane` owns both edges, because it is the
    /// only place that knows when the swap actually completed. A `.onChange(of: model.mainPaneMode)`
    /// here would have been the alternative signal, but it silently never fires when the swap
    /// target equals the current mode (re-opening the already-open `Info.plist` editor is exactly
    /// that case), which would strand the panel suspended until the next ⌥⌘J.
    @State private var websiteInspectorSuspended = false
    /// The title shown in the content-delete confirmation dialog. Held separately from
    /// `model.deleteConfirmation` so the title stays stable through the dismiss animation —
    /// mirrors `SiteNavigatorView`'s `candidateToDeleteTitle` for the same reason.
    @State private var contentDeleteTitle: String = ""
    @State private var unsavedEditsTerminationLease: SuddenTerminationController.Lease?
    /// The component harness canvas's live webview, bubbled up through
    /// `MainPaneEditorView`/`ComponentEditorView` so the window inspector's Style pane can drive
    /// the ColorPicker scrub preview (#714 slice 3). A UI resource handle — view state, not model
    /// state.
    @State private var componentCanvasWebView: WKWebView?
    /// The last `ComponentEditorActivationKey` this window's activation `.task(id:)` actually ran
    /// for — lets that task tell a genuine key change (new component/dev-server URL) apart from a
    /// same-key re-appearance (e.g. a Preview↔Editor toggle), since `.task(id:)` restarts on every
    /// reappearance of its host view even when `id` is unchanged. See the task body for why that
    /// distinction matters (#714 final review, Important 1).
    @State private var lastComponentActivationKey: ComponentEditorActivationKey?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// Reduce Motion → fade the chat panel and deploy drawer in/out instead of sliding them.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The window's undo manager, published into the model so app-applied edits register with
    /// Edit ▸ Undo (⌘Z) — see `ChatModel.editUndoCoordinator` (#527).
    @Environment(\.undoManager) private var undoManager

    init(
        siteID: String?,
        contentGraph: SiteContentGraph,
        knowledgeIndex: SiteKnowledgeIndex,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine,
        runtimeFactory: any SiteRuntimeFactory,
        contentIndexerStore: ContentIndexerStore
    ) {
        self.siteID = siteID
        _model = State(initialValue: SiteWindowModel(
            contentGraph: contentGraph,
            knowledgeIndex: knowledgeIndex,
            semanticRanker: semanticRanker,
            conventionsEngine: conventionsEngine,
            runtimeFactory: runtimeFactory,
            contentIndexerStore: contentIndexerStore
        ))
    }

    var body: some View {
        focusedValues(for: coreBody)
            // Invisible responder-chain seam for File ▸ Share…'s in-app Quick Look (#1617,
            // #1621). Deliberately attached HERE, outside `focusedValues(for:)`'s wrapping and
            // outside `coreBody`'s `Group { if let site ... } else { ... } }` branch switch —
            // NOT alongside it as originally shipped in #1619. A manual smoke test (#1621) found
            // the File ▸ Share… menu item staying permanently disabled even once
            // `SiteWindowModel.canShareSite` genuinely evaluated `true` (confirmed by
            // instrumenting the getter directly). Instrumenting `QuickLookPreviewController`'s
            // lifecycle in the same pass showed `QuickLookPreviewHost.makeNSViewController`
            // firing more than once per window and the underlying controller identity churning
            // while `model.site` transitioned from nil (the loading placeholder) to loaded — this
            // controller sitting inside the exact subtree `focusedValues(for:)` wraps with
            // `.focusedSceneValue(...)` is the most likely interference with AppKit's
            // `NSMenuItem` validation/sync for Commands scoped to that focused value, though the
            // precise SwiftUI-internal mechanism isn't confirmed beyond the repro. Moving the
            // attachment to `body`'s own top-level modifier chain (unaffected by both of those)
            // fixed it, re-verified with the same manual smoke test that first caught it — same
            // "outlives any single `body` evaluation" placement reasoning `onAppear`/`onDisappear`
            // below already rely on for `setWebsiteInspectorSuspended`.
            .background(QuickLookPreviewHost(model: model).frame(width: 0, height: 0))
            .onAppear {
                // Also stash the launcher-opener here (see SitesWindowRoot): window restoration can
                // relaunch the app with only site windows, so relying on the launcher's onAppear
                // alone would leave Dock ▸ New Site a silent no-op on such launches (#522 review).
                let openWindow = openWindow
                WindowRouter.shared.openSitesWindow = { openWindow(id: "sites") }
                // The model's seam back into this view's presentation state — see
                // `SiteWindowModel.setWebsiteInspectorSuspended`. Stored once, like the router
                // closure above: `@State`/`@SceneStorage` read and write through storage that
                // outlives any single `body` evaluation, so a closure captured here stays bound to
                // this window's live state for its whole lifetime.
                model.setWebsiteInspectorSuspended = { suspendWebsiteInspector($0) }
            }
            .onDisappear {
                // Break the seam before teardown: the closure captures this view value, which
                // holds `_model`'s storage, so leaving it installed would keep the whole
                // `SiteWindowModel` (and its preview/runtime graph) alive past window close.
                model.setWebsiteInspectorSuspended = nil
                let terminationLease = unsavedEditsTerminationLease
                unsavedEditsTerminationLease = nil
                model.close(suddenTerminationLease: terminationLease)
            }
    }

    /// The Group + lifecycle-task/onChange chain, factored out of `body` as its own type-checking
    /// unit — see `focusedValues(for:)` for why.
    @ViewBuilder
    private var coreBody: some View {
        Group {
            if let site = model.site {
                siteUI(for: site)
            } else {
                ProgressView("Loading site…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: siteID) {
            await model.loadAndStart(
                siteID: siteID,
                openSitesWindow: { openWindow(id: "sites") },
                dismissSiteWindow: { dismissWindow() }
            )
        }
        .task(id: model.site?.id) { await model.observeStoreChanges() }
        // Warm path: an already-open window reacts to a new `PreviewSiteIntent` request (the
        // cold path is `applyPendingNavigation` in `SiteWindowModel.loadAndStart`).
        .onChange(of: model.router.pendingNavigation) { _, _ in
            if let id = model.site?.id { model.applyPendingNavigation(for: id) }
        }
        // Same warm/cold split as above, for `StartDesignInterviewIntent` requests (#631).
        .onChange(of: model.router.pendingDesignInterview) { _, _ in
            if let id = model.site?.id { model.applyPendingDesignInterviewRequest(for: id) }
        }
        .onChange(of: model.site?.id) { _, _ in model.handleSiteChanged() }
        // `initial: true` covers the common case where the environment value is already set on
        // first render; the change handler covers SwiftUI delivering/replacing it later.
        .onChange(of: undoManager, initial: true) { _, newValue in
            model.windowUndoManager = newValue
        }
        // Catch-all sync of `model.websiteInspectorPresented` (#714 v2 slice 1 fix round 1,
        // Important 3) — the toggle funcs already sync it in their own transaction, but other
        // paths can flip `inspectorShown`/`activeInspector` outside them (e.g.
        // `SiteSearchFieldModifier`'s programmatic dismiss, scene restoration on first appearance),
        // so this scene-level pair of `onChange`s covers those too. `initial: true` handles scene
        // restoration landing `activeInspector == .website` before either toggle func ever runs.
        .onChange(of: inspectorShown, initial: true) { _, _ in syncWebsiteInspectorPresented() }
        .onChange(of: activeInspector, initial: true) { _, _ in syncWebsiteInspectorPresented() }
        // The third input to `websiteInspectorVisible`. `suspendWebsiteInspector(_:)` already syncs
        // in its own transaction; this is the same catch-all backstop as the two above.
        .onChange(of: websiteInspectorSuspended) { _, _ in syncWebsiteInspectorPresented() }
        .onChange(of: model.preview.state) { _, newState in
            model.previewStateChanged(newState)
        }
        .onChange(of: model.hasUnsavedEdits, initial: true) { _, hasUnsavedEdits in
            if hasUnsavedEdits {
                if unsavedEditsTerminationLease == nil {
                    unsavedEditsTerminationLease = SuddenTerminationController.shared.acquire()
                }
            } else {
                unsavedEditsTerminationLease?.release()
                unsavedEditsTerminationLease = nil
            }
        }
    }

    /// Publishes all `focusedSceneValue`s onto `content`. Factored out of `body` as its own
    /// function (rather than inlined into one long modifier chain) so the type checker solves it
    /// as an independent unit — `navigatorSelectionActions(for:)` pushed the combined `body`
    /// expression over Swift's type-check-in-reasonable-time budget once added inline (#516).
    ///
    /// One exception to "every focused value is published here": `siteSearchActions` is published
    /// by `SiteSearchFieldModifier` (`SiteSearchField.swift`, #520), because it hands out a
    /// closure over that modifier's own `@FocusState` — scene-local state this function has no
    /// access to. Look there too when auditing the full set.
    @ViewBuilder
    private func focusedValues<Content: View>(for content: Content) -> some View {
        content
            // `focusedSceneValue`, not `focusedValue`: keyboard focus often sits in an AppKit
            // responder (the WKWebView preview) where nothing in SwiftUI's focus system is
            // focused, so a plain focusedValue resolves to nil and File ▸ Export To ▸ Astro Website…
            // stays disabled even with the site window frontmost (same trap documented for
            // `\.preview` below).
            .focusedSceneValue(\.siteID, model.site?.id ?? siteID)
            .focusedSceneValue(\.newContentActions, model.site == nil ? nil : NewContentActions(
                newPage: { model.newPagePresented = true },
                newCollection: { model.newCollectionPresented = true },
                newPost: { model.newPostPresented = true },
                newComponent: { model.newComponentPresented = true },
                newLinkPost: {
                    model.quickCaptureURL = QuickCapture.clipboardURLString()
                    model.quickCapturePresented = true
                }
            ))
            .focusedSceneValue(\.navigatorSelectionActions, navigatorSelectionActions(for: model))
            // `focusedSceneValue` (not `focusedValue`): publishes while this site window is the
            // active scene, regardless of where keyboard focus sits. The preview pane is a
            // WKWebView (an AppKit responder), so nothing in SwiftUI's focus system is focused and
            // a plain `focusedValue` would resolve to nil — leaving the preview navigation commands
            // (Reload, Back/Forward, zoom) perpetually disabled.
            .focusedSceneValue(\.preview, model.preview)
            // Publishes the whole window model so menu commands (File ▸ Save/Revert today, the
            // Site menu in #511) can reach the focused window's editing surfaces and site
            // operations.
            .focusedSceneValue(\.siteWindowModel, model)
            // Inspector visibility is scene state (@SceneStorage), so the View menu's Show/Hide
            // Inspector reaches it through its own focused value rather than the window model
            // (#512).
            .focusedSceneValue(\.inspectorPanel, InspectorPanelActions(
                isShown: inspectorShown && activeInspector == .selection && model.inspectorSelection != nil,
                isAvailable: model.inspectorSelection != nil,
                toggle: { toggleSelectionInspector() },
                isWebsiteShown: inspectorShown && activeInspector == .website,
                toggleWebsite: { toggleWebsiteInspector() }
            ))
    }

    /// Shows the selection inspector, switching away from the website inspector if that's active;
    /// hides it if it's already the active, shown inspector. Shared by the toolbar item and the
    /// View menu's Show/Hide Inspector command.
    @MainActor
    private func toggleSelectionInspector() { activateInspector(.selection) }

    /// The website inspector's mirror of `toggleSelectionInspector()`, behind the View menu's
    /// Show/Hide Website Inspector (⌥⌘J).
    @MainActor
    private func toggleWebsiteInspector() { activateInspector(.website) }

    /// Applies one inspector-toggle request. The decision itself lives in
    /// `InspectorActivationPolicy` — a pure function, so the toolbar item, both menu commands, and
    /// the unit tests all agree on one mutually-exclusive-activation policy (#714 v2 slice 1).
    ///
    /// Applied as a single synchronous MainActor transaction with no `await` anywhere between
    /// reading the current activation and writing the new one, per the #968/#969 presentation-gate
    /// discipline. Field order matters:
    ///
    /// 1. `armSuppress` before the flip, so a write-back queued under the outgoing activation is
    ///    already being swallowed by the time it lands.
    /// 2. `needsWebsiteModel` before the flip, so `model.websiteInspector` is non-nil the very
    ///    first time SwiftUI builds `inspectorContent`'s `.website` branch for this activation —
    ///    the panel renders from whatever the model holds at build time (fix round 3/4, #714 v2
    ///    slice 1; see `SiteWindowModel.ensureWebsiteInspectorLoaded()` for the other paths that
    ///    have to guarantee the same thing).
    /// 3. The activation flip, then the presented-state mirror the #1126 settle predicate reads.
    @MainActor
    private func activateInspector(_ target: ActiveSiteInspector) {
        let outcome = InspectorActivationPolicy.apply(
            current: activeInspector,
            shown: inspectorShown,
            target: target
        )
        if outcome.armSuppress { armSuppressNextInspectorWriteBack() }
        if outcome.needsWebsiteModel { model.ensureWebsiteInspectorLoaded() }
        activeInspector = outcome.active
        inspectorShown = outcome.shown
        syncWebsiteInspectorPresented()
    }

    /// Withholds the website inspector across a main-pane swap, then puts it back — the
    /// implementation behind `SiteWindowModel.setWebsiteInspectorSuspended` (#714 v2 slice 1 fix
    /// round 6, replacing round 5's hide).
    ///
    /// Writes only `websiteInspectorSuspended`, never `inspectorShown`/`activeInspector`: the
    /// user's persisted choice to have this panel open is not what the pane swap is trying to
    /// change (see `websiteInspectorSuspended`'s doc comment for the regression that motivated
    /// the distinction). Because the preference is untouched, resuming is the whole restore — the
    /// panel returns to exactly the state it was in, which is also why the answer to "does it come
    /// back?" is *yes, automatically*: More Settings… and ⌘3 should not silently close a panel the
    /// user opened, and re-opening it by hand every time would be worse UX than the brief blink.
    ///
    /// Suspending is idempotent and only meaningful while the panel is actually up; resuming is
    /// unconditional, so a stray resume can never leave the flag stuck true.
    ///
    /// Deliberately does *not* arm `suppressNextInspectorWriteBack`. That flag swallows a
    /// write-back queued under an activation the user has since switched *away* from, and this is
    /// not a kind switch. The collapse SwiftUI posts here is handled instead by the
    /// `websiteInspectorSuspended` guard in `inspectorPresented`'s setter, which covers the whole
    /// suspension window rather than a single run-loop turn — the suspension outlives one turn by
    /// design (it spans the pane swap plus a settle).
    @MainActor
    private func suspendWebsiteInspector(_ suspended: Bool) {
        if suspended {
            guard inspectorShown, activeInspector == .website else { return }
        }
        websiteInspectorSuspended = suspended
        syncWebsiteInspectorPresented()
    }

    /// Sets `suppressNextInspectorWriteBack` for one run-loop turn — see its doc comment. Called
    /// synchronously, in the same transaction as the `activeInspector` switch, by both toggle
    /// funcs above.
    @MainActor
    private func armSuppressNextInspectorWriteBack() {
        suppressNextInspectorWriteBack = true
        DispatchQueue.main.async { suppressNextInspectorWriteBack = false }
    }

    /// Whether the website inspector is on screen right now: the user's persisted activation, minus
    /// any transient pane-swap suspension. The single source the `.inspector(isPresented:)`
    /// binding, the model mirror, and `inspectorContent`'s panel gate all read, so those three
    /// can't drift apart (they must agree, or the panel renders content into a collapsing column —
    /// the #1126-class abort the gate exists to prevent).
    ///
    /// Not what the View menu's Show/Hide Website Inspector state reads: that reflects the
    /// *preference* (`inspectorShown && activeInspector == .website`), which a sub-second
    /// suspension shouldn't flicker.
    private var websiteInspectorVisible: Bool {
        inspectorShown && activeInspector == .website && !websiteInspectorSuspended
    }

    /// Mirrors the website inspector's actual presented state onto the model — see
    /// `SiteWindowModel.websiteInspectorPresented`'s doc comment. Called synchronously by both
    /// toggle funcs above, by `suspendWebsiteInspector(_:)`, and by `coreBody`'s `.onChange` (for
    /// the other paths that can flip `inspectorShown`/`activeInspector`:
    /// `SiteSearchFieldModifier`'s programmatic dismiss, scene restoration).
    @MainActor
    private func syncWebsiteInspectorPresented() {
        model.websiteInspectorPresented = websiteInspectorVisible
    }

    @ViewBuilder
    private func siteUI(for site: SiteStore.Site) -> some View {
        @Bindable var bindableModel = model

        // Shared with `SiteSearchFieldModifier` below (#1126): search-field activation is
        // another "substantial toolbar re-layout while the inspector is presented" trigger for
        // the same macOS 27 beta AppKit constraint-update storm as the pane-switch case, so it
        // needs the same presented-state read the `.inspector(isPresented:)` modifier itself
        // uses, not a copy that could drift out of sync.
        let inspectorPresented = Binding(
            get: {
                websiteInspectorVisible
                    || (inspectorShown && activeInspector == .selection && model.inspectorSelection != nil)
            },
            set: { newValue in
                // Swallow a write-back scheduled under an activation that's since been switched
                // away from — see `suppressNextInspectorWriteBack`'s doc comment (#714 v2 slice 1
                // fix round 1, Important 1).
                guard !suppressNextInspectorWriteBack else { return }
                // Same idea, for the collapse that a pane-swap suspension triggers: the panel goes
                // away because the app withheld it for one transaction, not because the user closed
                // it, so persisting the resulting `isPresented = false` would turn a temporary
                // suspension into a permanent preference change — precisely the regression fix
                // round 5 shipped by routing the dismissal through `activateInspector` (#714 v2
                // slice 1 fix round 6, Important 1).
                guard !websiteInspectorSuspended else { return }
                // The website inspector always has content, so while it's the active panel a
                // write-back really is the user's own show/hide. Selection keeps the #968 guard:
                // never persist an auto-hide caused by a transient-nil selection.
                if activeInspector == .website || model.inspectorSelection != nil {
                    inspectorShown = newValue
                }
            }
        )

        NavigationSplitView(columnVisibility: Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = ($0 != .detailOnly) }
        )) {
            if let navigator = model.navigator {
                SiteNavigatorView(
                    model: navigator,
                    canvasHasKeyboardFocus: model.preview.wysiwygCanvas?.hasKeyboardFocus == true,
                    onDeleteRequested: { item in
                        contentDeleteTitle = "Delete “\(item.title)”?"
                        model.deleteConfirmation = item
                    },
                    onDuplicateRequested: { item in
                        Task { await model.duplicate(id: item.id) }
                    },
                    onRepurposeRequested: { item in
                        Task { await model.presentRepurpose(postRowID: item.id) }
                    },
                    onPublishRequested: { item in
                        Task { await model.publish(id: item.id) }
                    },
                    onUnpublishRequested: { item in
                        Task { await model.unpublish(id: item.id) }
                    }
                )
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
                    .onChange(of: navigator.selection) { _, newID in
                        model.applyNavigatorSelection(newID)
                    }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } detail: {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    // Non-blocking conflict banner (#881): docked above the content, never a
                    // sheet/alert, so the site stays fully editable while it's showing.
                    if model.sync.bannerPresented {
                        SyncConflictBannerView(
                            fileCount: (model.sync.conflict?.conflictedPaths.count ?? 0) + model.sync.quarantinedFiles.count,
                            onResolve: { model.sync.openResolutionSheet() },
                            onDismiss: { model.sync.dismissBanner() }
                        )
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                    HStack(spacing: 0) {
                        // Leading tool panel (#1588 Task 20): same Divider + fixed-width +
                        // transition convention the trailing chat/related-pages panels below use,
                        // just anchored on the leading edge since this is a palette next to the
                        // canvas rather than an auxiliary content panel.
                        if showWYSIWYGPalette, model.preview.isEditModeEnabled {
                            WYSIWYGPaletteView(entries: WYSIWYGCanvasController.stubBlockPalette) { entry in
                                Task { await model.preview.wysiwygCanvas?.insertBlock(entry) }
                            }
                            .frame(width: 220)
                            .transition(reduceMotion
                                ? .opacity
                                : .move(edge: .leading).combined(with: .opacity))
                            Divider()
                        }
                        mainPane(for: site)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if model.chatPresented, let chat = model.chat {
                            Divider()
                            ChatView(model: chat, revealCitation: { path in model.revealCitationInGraph(path) })
                                .frame(width: 420)
                                .transition(reduceMotion
                                    ? .opacity
                                    : .move(edge: .trailing).combined(with: .opacity))
                        }
                        if model.relatedPagesPresented {
                            Divider()
                            RelatedPagesPanel(model: model.relatedPages)
                                .frame(width: 320)
                                .transition(reduceMotion
                                    ? .opacity
                                    : .move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: model.chatPresented)
                    .animation(.easeInOut(duration: 0.18), value: model.relatedPagesPresented)
                    .animation(.easeInOut(duration: 0.18), value: showWYSIWYGPalette)
                }
                if model.deploy.drawerPresented {
                    DeployDrawerView(
                        model: model.deploy, siteName: site.name,
                        onConnectDomain: { model.connectDomain.openSheet() }
                    )
                        .transition(reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity))
                        .shadow(radius: 8, y: -2)
                } else if model.backup.drawerPresented {
                    // Backup and deploy can't both run at once (each disables the other's
                    // button while running), but a stale completed-deploy drawer might still
                    // be on screen when a backup finishes. Deploy wins the z-order — its
                    // drawer carries the more critical "your deploy URL" payload.
                    BackupDrawerView(model: model.backup, siteName: site.name)
                        .transition(reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity))
                        .shadow(radius: 8, y: -2)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.deploy.drawerPresented)
        .animation(.easeInOut(duration: 0.18), value: model.backup.drawerPresented)
        .inspector(isPresented: inspectorPresented) {
            inspectorContent
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .navigationTitle(model.preview.editingPageTitle ?? site.name)
        .navigationSubtitle(model.preview.readyURL?.absoluteString ?? "")
        // Titlebar proxy icon (#521): ⌘-click shows the package's path, and the icon drags as the
        // `.anglesite` package itself. The window's security-scoped grant already covers the URL.
        // While WYSIWYG edit mode is active (#1588 Task 18), both title and proxy icon instead
        // point at the specific page being edited inside `Source/`.
        .navigationDocument(model.preview.editingPageSourceURL ?? site.packageURL)
        // Titlebar edited-dot (#1588 Task 17): reflects uncommitted in-memory WYSIWYG ops against
        // the stub backend, not a real git-dirty state — see `WindowEditedStateBridge`'s doc comment.
        .background(WindowEditedStateBridge(isEdited: model.preview.wysiwygCanvas?.hasUncommittedOps ?? false))
        // Leading title, free center — the document-style layout (Pages/Freeform). No `.principal`
        // item occupies that center anymore: Editor/Graph/Cleanup are drill-in takeovers reached
        // by opening a file or a Website-menu command, not a toolbar-centered mode switch.
        .toolbarRole(.editor)
        // Customizable toolbar (#519): every item has a STABLE id — saved customizations key off
        // these strings, so renaming one silently discards users' layouts (the id set is frozen
        // by SiteToolbarItemIDTests in AnglesiteCoreTests). Items must also be
        // unconditional (no `if let` wrappers): identity-swapping or appearing/vanishing items
        // fight the customization palette, so state-dependent items render disabled instead.
        // Curated default ≈8 items; episodic setup/maintenance actions ship hidden and live in
        // the palette (View ▸ Customize Toolbar…, added in #510).
        .toolbar(id: "site") {
            // Leading, per Pages/Freeform convention for the content-creation `+` menu (#714 v2
            // slice 3). Content-only for now — a Blocks section joins once the WYSIWYG palette's
            // insert actions exist (slice 4, tracked separately so this menu isn't blocked on it).
            ToolbarItem(id: SiteToolbarItemID.insert.rawValue, placement: .primaryAction) {
                Menu {
                    Button("New Page…") { model.newPagePresented = true }
                    Button("New Post…") { model.newPostPresented = true }
                    Button("New Collection Entry…") { model.newCollectionPresented = true }
                } label: {
                    Label("Insert", systemImage: "plus")
                }
                .help("Add a new page, post, or collection entry")
                .accessibilityIdentifier(AXID.toolbar(.insert))
            }

            ToolbarItem(id: SiteToolbarItemID.graph.rawValue, placement: .primaryAction) {
                Button {
                    Task { await model.showGraph() }
                } label: {
                    Label("Site Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .help("Explore pages, layouts, components, collections, and assets")
                .accessibilityIdentifier(AXID.toolbar(.graph))
            }

            // iCloud sync status (#881): renders nothing for a package that isn't in iCloud
            // Drive (`SyncStatusView` is an `EmptyView` when `!model.sync.isEligible`), so this
            // item never widens a local-only site's toolbar.
            ToolbarItem(id: SiteToolbarItemID.sync.rawValue, placement: .primaryAction) {
                SyncStatusView(model: model.sync)
                    .accessibilityIdentifier(AXID.toolbar(.sync))
            }

            // Open GitHub security advisories/Dependabot alerts (#975). Renders nothing (an
            // EmptyView) for a clean site — see SecurityReportsBadgeView's doc comment.
            ToolbarItem(id: SiteToolbarItemID.securityReports.rawValue, placement: .primaryAction) {
                SecurityReportsBadgeView(
                    model: model.securityReports,
                    onRecheck: { model.recheckSecurityReports() },
                    onViewAll: { model.openWebsiteSettings(landOn: .securityReports) }
                )
                .accessibilityIdentifier(AXID.toolbar(.securityReports))
            }

            ToolbarItem(id: SiteToolbarItemID.backup.rawValue, placement: .primaryAction) {
                Button {
                    model.backupSite()
                } label: {
                    Label("Backup", systemImage: "externaldrive.fill.badge.icloud")
                }
                .disabled(!model.canRunBackup)
                .help(site.isValid
                      ? "Commit and push working-tree changes to your current branch"
                      : "Site is missing required files")
                .accessibilityIdentifier(AXID.toolbar(.backup))
            }

            ToolbarItem(id: SiteToolbarItemID.audit.rawValue, placement: .primaryAction) {
                Button {
                    model.auditSite()
                } label: {
                    if model.audit.isRunning {
                        Label("Auditing…", systemImage: "magnifyingglass")
                    } else {
                        Label("Audit", systemImage: "checkmark.shield.fill")
                    }
                }
                .disabled(!model.canRunAudit)
                .help(site.isValid && model.preview.canDeploy
                      ? "Run the structured accessibility audit against this site"
                      : site.isValid
                        ? "Open the preview first to start the runtime before auditing"
                        : "Site is missing required files")
                .accessibilityIdentifier(AXID.toolbar(.audit))
            }

            ToolbarItem(id: SiteToolbarItemID.openInBrowser.rawValue, placement: .primaryAction) {
                Button {
                    model.openPreviewInBrowser()
                } label: {
                    Label("Open in browser", systemImage: "arrow.up.forward.app")
                }
                .disabled(!model.canOpenPreviewInBrowser)
                .help("Open the live preview in your default browser")
                .accessibilityIdentifier(AXID.toolbar(.openInBrowser))
            }

            // — Palette-only items (View ▸ Customize Toolbar…) —

            ToolbarItem(id: SiteToolbarItemID.harden.rawValue, placement: .primaryAction) {
                Button {
                    model.harden.openSheet()
                } label: {
                    if model.harden.isRunning {
                        Label("Hardening…", systemImage: "shield.lefthalf.filled")
                    } else {
                        Label("Harden", systemImage: "shield.lefthalf.filled")
                    }
                }
                .disabled(!model.canRunHarden)
                .help(site.isValid
                      ? "Preview and apply Cloudflare security hardening for this site"
                      : "Site is missing required files")
                .accessibilityIdentifier(AXID.toolbar(.harden))
            }
            .defaultCustomization(.hidden)

            ToolbarItem(id: SiteToolbarItemID.aiSearch.rawValue, placement: .primaryAction) {
                Button {
                    model.aiSearch.openSheet()
                } label: {
                    if model.aiSearch.isRunning {
                        Label("Setting Up AI Search…", systemImage: "text.magnifyingglass")
                    } else {
                        Label("AI Search", systemImage: "text.magnifyingglass")
                    }
                }
                .disabled(!model.canRunAISearch)
                .help(site.isValid
                      ? "Provision Cloudflare AI Search for this site"
                      : "Site is missing required files")
                .accessibilityIdentifier(AXID.toolbar(.aiSearch))
            }
            .defaultCustomization(.hidden)

            ToolbarItem(id: SiteToolbarItemID.domainConfigAudit.rawValue, placement: .primaryAction) {
                Button {
                    model.domainConfigAudit.openSheet()
                } label: {
                    if model.domainConfigAudit.isRunning {
                        Label("Checking Domain Config…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Domain Config", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(!model.canRunDomainConfigAudit)
                .help(site.isValid
                      ? "Compare anglesite.json's declared domain/DNS/edge config against live Cloudflare state"
                      : "Site is missing required files")
                .accessibilityIdentifier(AXID.toolbar(.domainConfigAudit))
            }
            .defaultCustomization(.hidden)

            ToolbarItem(id: SiteToolbarItemID.agentReadiness.rawValue, placement: .primaryAction) {
                Button {
                    model.agentReadiness.openSheet()
                } label: {
                    if model.agentReadiness.isRunning {
                        Label("Checking Agent Readiness…", systemImage: "sparkle.magnifyingglass")
                    } else {
                        Label("Agent Readiness", systemImage: "sparkle.magnifyingglass")
                    }
                }
                .disabled(!model.canRunAgentReadiness)
                .help(site.isValid
                      ? "Check Cloudflare's Agent Readiness score for this site's deployed URL"
                      : "Site is missing required files")
                .accessibilityIdentifier(AXID.toolbar(.agentReadiness))
            }
            .defaultCustomization(.hidden)

            ToolbarItem(id: SiteToolbarItemID.onionRouting.rawValue, placement: .primaryAction) {
                Button {
                    model.onionRouting.openSheet()
                } label: {
                    Label("Onion Routing", systemImage: "network")
                }
                .disabled(!model.canRunOnionRouting)
                .help(site.isValid
                      ? "Enable Tor Browser access for this site via Cloudflare's zone-level setting"
                      : "Site is missing required files")
                .accessibilityIdentifier(AXID.toolbar(.onionRouting))
            }
            .defaultCustomization(.hidden)

            ToolbarItem(id: SiteToolbarItemID.domain.rawValue, placement: .primaryAction) {
                Button {
                    model.domain.openSheet()
                } label: {
                    Label("Domain", systemImage: "globe")
                }
                .disabled(!model.canOpenDomain)
                .help("View and manage this domain's DNS records")
                .accessibilityIdentifier(AXID.toolbar(.domain))
            }
            .defaultCustomization(.hidden)

            ToolbarItem(id: SiteToolbarItemID.integration.rawValue, placement: .primaryAction) {
                Button {
                    model.openIntegrationWizard()
                } label: {
                    Label("Add Integration…", systemImage: "puzzlepiece.extension")
                }
                .disabled(!model.canOpenIntegrationWizard)
                .help("Set up a third-party integration for this site")
                .accessibilityIdentifier(AXID.toolbar(.integration))
            }
            .defaultCustomization(.hidden)

            ToolbarItem(id: SiteToolbarItemID.siriReadiness.rawValue, placement: .primaryAction) {
                Button {
                    model.openSiriReadiness()
                } label: {
                    Label("Siri AI Readiness", systemImage: "sparkles")
                }
                .disabled(!model.canOpenSiriReadiness)
                .help("Check whether Siri workflows are ready for this site")
                .accessibilityIdentifier(AXID.toolbar(.siriReadiness))
            }
            .defaultCustomization(.hidden)

            ToolbarItem(id: SiteToolbarItemID.relatedPages.rawValue, placement: .primaryAction) {
                Button {
                    model.relatedPagesPresented.toggle()
                } label: {
                    Label("Related Pages", systemImage: model.relatedPagesPresented
                          ? "link.badge.plus" : "link")
                }
                .help(model.relatedPagesPresented ? "Hide related pages" : "Show related pages")
                .accessibilityIdentifier(AXID.toolbar(.relatedPages))
            }
            .defaultCustomization(.hidden)

            ToolbarItem(id: SiteToolbarItemID.styleGuide.rawValue, placement: .primaryAction) {
                Button {
                    model.openStyleGuide()
                } label: {
                    Label("Style Guide", systemImage: "textformat.abc")
                }
                .help("See and edit this site's learned writing, image, and naming conventions")
                .accessibilityIdentifier(AXID.toolbar(.styleGuide))
            }
            .defaultCustomization(.hidden)

            // One stable item whose label/action reflects publish state — two swapping items
            // would break saved customizations.
            ToolbarItem(id: SiteToolbarItemID.github.rawValue, placement: .primaryAction) {
                if let remote = model.publish.existingRemote {
                    Button {
                        NSWorkspace.shared.open(remote.url)
                    } label: {
                        Label("View on GitHub", systemImage: "arrow.up.forward.square")
                    }
                    .help("Open this site's GitHub repository")
                    .accessibilityIdentifier(AXID.toolbar(.github))
                } else {
                    Button {
                        model.publish.publish(source: site.sourceDirectory, repoName: site.name)
                    } label: {
                        Label("Publish to GitHub", systemImage: "square.and.arrow.up.on.square")
                    }
                    .disabled(!model.canPublishToGitHub)
                    .help(site.isValid ? "Create a private GitHub repo and push this site" : "Site is missing required files")
                    .accessibilityIdentifier(AXID.toolbar(.github))
                }
            }
            .defaultCustomization(.hidden)

            // — Default trailing cluster —

            // Health badge and Deploy are one item: the badge is the readiness signal for the
            // button it gates, so customization can never separate them.
            ToolbarItem(id: SiteToolbarItemID.deploy.rawValue, placement: .primaryAction) {
                HStack(spacing: 8) {
                    HealthBadgeView(
                        model: model.health,
                        onRecheck: { model.recheckHealth() },
                        onAskAssistant: {
                            guard let chat = model.chat else { return }
                            model.chatPresented = true
                            chat.send(SiteWindowModel.healthAssistantPrompt)
                        }
                    )
                    Button {
                        model.deploySite()
                    } label: {
                        Label("Deploy", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRunDeploy)
                    .help(site.isValid && model.preview.canDeploy
                          ? "Build, scan, and run wrangler deploy on this site"
                          : site.isValid
                            ? "Open the preview first to start the runtime before deploying"
                            : "Site is missing required files")
                    .accessibilityIdentifier(AXID.toolbar(.deploy))
                }
            }
            .customizationBehavior(.reorderable)

            ToolbarItem(id: SiteToolbarItemID.chat.rawValue, placement: .primaryAction) {
                Button {
                    model.chatPresented.toggle()
                } label: {
                    Label("Chat", systemImage: model.chatPresented
                        ? "bubble.left.and.bubble.right.fill"
                        : "bubble.left.and.bubble.right")
                }
                .help(model.chatPresented ? "Hide chat panel" : "Show chat panel")
                .accessibilityIdentifier(AXID.toolbar(.chat))
                // ⌘K moved to View ▸ Show/Hide Chat (#512) — a second registration here would
                // recreate the duplicate-shortcut ambiguity #509 removed for ⌘S.
            }

            // Far trailing, immediately before the selection inspector toggle (#714 v2 slice 3) —
            // the Website inspector (Document analog) is always available, unlike `inspector`
            // (Format analog) which disables with no selection, so this item never disables.
            ToolbarItem(id: SiteToolbarItemID.websiteInspector.rawValue, placement: .primaryAction) {
                Button {
                    toggleWebsiteInspector()
                } label: {
                    Label("Website Inspector", systemImage: "globe")
                }
                .help("Show or hide the website inspector")
                .accessibilityIdentifier(AXID.toolbar(.websiteInspector))
            }

            // Far trailing, adjacent to the inspector panel it controls (Pages/Freeform convention).
            ToolbarItem(id: SiteToolbarItemID.inspector.rawValue, placement: .primaryAction) {
                Button {
                    toggleSelectionInspector()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .disabled(model.inspectorSelection == nil)
                .help("Show or hide the inspector")
                .accessibilityIdentifier(AXID.toolbar(.inspector))
            }

            // Unconditional per the file's own toolbar-customization rule above: disabled (not
            // hidden) outside Site ▸ Edit Page, so Customize Toolbar always shows it (#1588 Task 20).
            ToolbarItem(id: SiteToolbarItemID.wysiwygPalette.rawValue, placement: .primaryAction) {
                Button {
                    showWYSIWYGPalette.toggle()
                } label: {
                    Label("Block Palette", systemImage: "square.grid.2x2")
                }
                .disabled(!model.preview.isEditModeEnabled)
                .help("Show or hide the block palette")
                .accessibilityIdentifier(AXID.toolbar(.wysiwygPalette))
            }
        }
        // Trailing search field (#520). Not a `.toolbar(id:)` item: `.searchable` mints its own
        // toolbar item id, so it stays out of the frozen `SiteToolbarItemID` set and out of
        // users' saved customizations.
        .modifier(SiteSearchFieldModifier(
            model: model.search,
            siteID: site.id,
            inspectorPresented: inspectorPresented,
            activate: { hit in model.openSearchHit(hit) }
        ))
        .sheet(isPresented: $bindableModel.deploy.blockedPresented) {
            if case .blocked(let failures, let warnings) = model.deploy.phase {
                BlockedDeploySheetView(failures: failures, warnings: warnings) {
                    model.deploy.dismissBlocked()
                }
            }
        }
        .sheet(isPresented: $bindableModel.deploy.tokenPromptPresented) {
            CloudflareOAuthSignInView(model: model.deploy) {
                model.deploy.cancelTokenPrompt()
            }
        }
        .sheet(isPresented: $bindableModel.deploy.workerNameConflictPresented) {
            if case .workerNameConflict(let name) = model.deploy.phase {
                WorkerNameConflictSheetView(model: model.deploy, takenName: name) {
                    model.deploy.cancelWorkerNameConflictPrompt()
                }
            }
        }
        .sheet(isPresented: $bindableModel.deploy.domainConflictPresented) {
            if case .conflict(let hostname, let ownedBy) = model.deploy.domainAttachStatus {
                DomainConflictSheetView(hostname: hostname, ownedBy: ownedBy) {
                    model.deploy.dismissDomainConflict()
                }
            }
        }
        .sheet(isPresented: $bindableModel.deploy.webmentionPaidPlanConfirmationPresented) {
            WebmentionPaidPlanConfirmationSheetView(model: model.deploy) {
                model.deploy.cancelWebmentionPaidPlanConfirmation()
            }
        }
        .sheet(isPresented: $bindableModel.deploy.activityPubHandleRenameConfirmationPresented) {
            if let change = model.deploy.activityPubHandleRenameChange {
                ActivityPubHandleRenameSheetView(model: model.deploy, change: change) {
                    model.deploy.cancelActivityPubHandleRenameConfirmation()
                }
            }
        }
        .sheet(isPresented: $bindableModel.deploy.domainConfigDriftPresented) {
            if case .domainConfigDrift(let findings) = model.deploy.phase {
                DomainConfigDriftSheetView(
                    findings: findings,
                    onReview: {
                        model.deploy.dismissDomainConfigDrift()
                        model.domainConfigAudit.openSheet()
                    },
                    onDismiss: { model.deploy.dismissDomainConfigDrift() }
                )
            }
        }
        .sheet(isPresented: $bindableModel.deploy.licenseGatePresented) {
            LicenseGateSheetView(model: model.deploy)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $bindableModel.audit.sheetPresented) {
            AuditSheetView(
                model: model.audit,
                siteName: site.name,
                onRunAgain: { model.auditSite() }
            )
        }
        .sheet(isPresented: $bindableModel.sync.resolutionSheetPresented) {
            SyncConflictResolutionSheetView(model: model.sync, siteName: site.name)
        }
        .sheet(isPresented: $bindableModel.domainConfigAudit.sheetPresented) {
            DomainConfigAuditSheetView(model: model.domainConfigAudit)
        }
        .sheet(isPresented: $bindableModel.harden.sheetPresented) {
            HardenSheetView(model: model.harden)
        }
        .sheet(isPresented: $bindableModel.aiSearch.sheetPresented) {
            AISearchSheetView(model: model.aiSearch, sourceDirectory: site.sourceDirectory)
        }
        .sheet(isPresented: $bindableModel.agentReadiness.sheetPresented) {
            AgentReadinessSheetView(model: model.agentReadiness)
        }
        .sheet(isPresented: $bindableModel.onionRouting.sheetPresented) {
            OnionRoutingSheetView(model: model.onionRouting)
        }
        .sheet(isPresented: Binding(
            get: { bindableModel.styleGuide?.sheetPresented ?? false },
            set: { bindableModel.styleGuide?.sheetPresented = $0 }
        )) {
            if let styleGuide = model.styleGuide {
                ProjectStyleGuideView(model: styleGuide, siteName: site.name)
            }
        }
        .sheet(isPresented: $bindableModel.domain.sheetPresented, onDismiss: {
            // Sequences the "Set up email" handoff to `EmailSetupSheetView` after this sheet's
            // own dismissal transaction finishes — same pattern as the Connect Domain → Buy
            // Domain handoff just below.
            if model.domain.pendingEmailSetup {
                model.domain.pendingEmailSetup = false
                model.presentEmailSetup()
            }
        }) {
            DomainSheetView(model: model.domain)
        }
        .sheet(isPresented: $bindableModel.connectDomain.sheetPresented, onDismiss: {
            // Sequences the "Buy a domain" handoff to `BuyDomainSheetView` after this sheet's own
            // dismissal transaction finishes, rather than flipping both sheets' `sheetPresented`
            // bindings synchronously from one button action — see `ConnectDomainModel
            // .pendingBuyDomain`'s doc comment.
            if model.connectDomain.pendingBuyDomain {
                model.connectDomain.pendingBuyDomain = false
                model.buyDomain.openSheet()
            }
        }) {
            ConnectDomainSheetView(model: model.connectDomain)
        }
        .sheet(isPresented: $bindableModel.buyDomain.sheetPresented) {
            BuyDomainSheetView(model: model.buyDomain)
        }
        .sheet(isPresented: $bindableModel.publish.sheetPresented) {
            PublishSheet(model: model.publish, siteName: site.name)
        }
        .sheet(isPresented: $bindableModel.publish.tokenPromptPresented) {
            GitHubTokenPromptView(model: model.publish) {
                model.publish.cancelTokenPrompt()
            }
        }
        .sheet(item: $bindableModel.siriReadinessModel) { readinessModel in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Siri AI readiness for “\(site.name)”.")
                            .font(.caption).foregroundStyle(.secondary)
                        SiriReadinessList(model: readinessModel)
                    }
                    .padding()
                }
                .frame(minWidth: 420, minHeight: 260)
                .navigationTitle("Siri AI Readiness")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.siriReadinessModel = nil }
                    }
                }
            }
        }
        .sheet(item: $bindableModel.dependencyUpdateModel) { updateModel in
            NavigationStack {
                List {
                    if !updateModel.offers.updates.isEmpty {
                        Section("Dependency Updates") {
                            ForEach(updateModel.offers.updates, id: \.name) { offer in
                                LabeledContent(offer.name) {
                                    Text("\(offer.currentRange) → \(offer.offeredRange)")
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                        }
                    }
                    if !updateModel.offers.additions.isEmpty {
                        Section("New Dependencies") {
                            ForEach(updateModel.offers.additions, id: \.name) { offer in
                                LabeledContent {
                                    Text(offer.offeredRange)
                                        .font(.system(.body, design: .monospaced))
                                } label: {
                                    Label(offer.name, systemImage: "plus.circle")
                                }
                            }
                        }
                    }
                    // #1440: bumps held back because one of the site's own packages (one the
                    // template doesn't manage) can't work with the newer version yet. Shown as
                    // information, not a choice — applying one would leave the site unable to
                    // install its dependencies at all, and the app doesn't delegate decisions
                    // it already knows the answer to.
                    if !updateModel.offers.heldUpdates.isEmpty {
                        Section("Not Updated") {
                            ForEach(updateModel.offers.heldUpdates, id: \.offer.name) { held in
                                VStack(alignment: .leading, spacing: 4) {
                                    LabeledContent(held.offer.name) {
                                        Text("stays at \(held.offer.currentRange)")
                                            .font(.system(.body, design: .monospaced))
                                    }
                                    Text(DependencyUpdateModel.heldCopy(for: held))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Dependency Updates Available")
                .toolbar {
                    if updateModel.isHeldBackOnly {
                        // Nothing to apply — a lone acknowledge still routes through
                        // `update()` so the version stamp lands and the sheet doesn't
                        // re-nag on every site open.
                        ToolbarItem(placement: .confirmationAction) {
                            Button("OK") { updateModel.update() }
                        }
                    } else {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Skip") { updateModel.skip() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Update") { updateModel.update() }
                        }
                    }
                }
            }
            .frame(minWidth: 420, minHeight: 260)
            // `loadAndStart()` suspends on a `CheckedContinuation` that only Skip/Update resume
            // (see `SiteWindowModel.loadAndStart`). Block outside-tap/swipe dismissal so those two
            // buttons are structurally the only way out — otherwise the continuation would leak
            // and `preview.open()` would never run.
            .interactiveDismissDisabled()
        }
        .sheet(item: $bindableModel.scriptSyncModel) { syncModel in
            NavigationStack {
                List(syncModel.pending) { divergence in
                    let copy = ScriptSyncModel.rowCopy(for: divergence.relativePath)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(copy.title)
                            .font(.headline)
                        Text(copy.consequence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(divergence.relativePath)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        if syncModel.failedRelativePaths.contains(divergence.relativePath) {
                            Label("Couldn't update this file — see the debug log for details.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        HStack {
                            Button("Keep My Version") { syncModel.keepMine(divergence) }
                            Spacer()
                            Button("Update This File") { syncModel.update(divergence) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .navigationTitle("Site Scripts Customized")
            }
            .frame(minWidth: 420, minHeight: 260)
            // Mirrors the dependency-update sheet immediately above: `loadAndStart()` suspends on
            // a `CheckedContinuation` that only resumes once every row is resolved (see
            // `ScriptSyncModel.remove`/`SiteWindowModel.loadAndStart`). Block outside-tap/swipe
            // dismissal so per-row buttons are structurally the only way out.
            .interactiveDismissDisabled()
        }
        .sheet(item: $bindableModel.securityTxtMigrationModel) { migrationModel in
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Hand-Authored security.txt Found")
                        .font(.headline)
                    Text("This site publishes a security.txt Anglesite didn't generate. Adopt it so Anglesite keeps it current going forward, or leave it as yours to maintain.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Preserve as Hand-Authored") { migrationModel.preserve() }
                        Spacer()
                        Button("Adopt as Generated") { migrationModel.adopt() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .navigationTitle("security.txt")
            }
            .frame(minWidth: 420, minHeight: 220)
            // Mirrors the scripts-sync sheet immediately above: `loadAndStart()` suspends on a
            // `CheckedContinuation` that only Adopt/Preserve resume. Block outside-tap/swipe
            // dismissal so those two buttons are structurally the only way out.
            .interactiveDismissDisabled()
        }
        .sheet(item: $bindableModel.copyEditModel) { reportModel in
            CopyEditReportView(model: reportModel)
        }
        .sheet(item: $bindableModel.socialPlanModel) { planModel in
            SocialPlanView(model: planModel)
        }
        .sheet(item: $bindableModel.repurposeModel) { repurposeModel in
            RepurposeView(model: repurposeModel)
        }
        .sheet(item: $bindableModel.emailSetupModel) { setupModel in
            EmailSetupSheetView(model: setupModel, onDone: { model.emailSetupModel = nil })
        }
        .sheet(item: $bindableModel.experimentStatsModel) { statsModel in
            ExperimentStatsSheetView(
                model: statsModel,
                deployModel: model.deploy,
                deploySite: { model.deploySite() },
                deployUnavailableReason: {
                    // `deploySite()`'s own `canRunDeploy` guard first — it returns silently, which
                    // would strand the sheet on "Starting your test…" — then `DeployModel`'s
                    // token/license/in-flight preconditions, whose sheets can't present over this
                    // one anyway (#1518 review, I5).
                    guard model.canRunDeploy else {
                        return "Your site isn't ready to publish yet. Wait for the preview to finish starting (or for the current task to end), then start your test."
                    }
                    return model.deploy.deployUnavailableReason(siteDirectory: statsModel.sourceDirectory)
                },
                onDone: { model.experimentStatsModel = nil },
                enterGoalPickMode: {
                    model.preview.webView?.evaluateJavaScript("window.anglesite?._enterGoalPickMode?.()")
                },
                exitGoalPickMode: {
                    model.preview.webView?.evaluateJavaScript("window.anglesite?._exitGoalPickMode?.()")
                }
            )
        }
        .sheet(item: $bindableModel.designInterviewModel) { interviewModel in
            NavigationStack {
                DesignInterviewPanel(model: interviewModel)
                    .navigationTitle("Design Interview")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.designInterviewModel = nil }
                        }
                    }
            }
            .frame(minWidth: 640, minHeight: 420)
        }
        .sheet(item: $bindableModel.integrationWizardModel) { wizardModel in
            NavigationStack {
                IntegrationWizard(model: wizardModel, onClose: { model.integrationWizardModel = nil })
                    .navigationTitle("Add Integration")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { model.integrationWizardModel = nil }
                        }
                    }
            }
        }
        .sheet(item: $bindableModel.themeApplyWizardModel) { wizardModel in
            NavigationStack {
                ThemeApplyWizard(model: wizardModel, onDone: { model.themeApplyWizardModel = nil })
                    .navigationTitle("Apply a Theme")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { model.themeApplyWizardModel = nil }
                        }
                    }
            }
        }
        .alert("Revert to the last saved version?", isPresented: $bindableModel.revertConfirmationPresented) {
            Button("Revert", role: .destructive) { Task { await model.confirmRevertToSaved() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved changes in the editor and inspector will be discarded.")
        }
        // The setter has NO side effect, and each button is solely responsible for clearing
        // `deleteConfirmation` — the same rule (and the same reason) as `MainPaneEditorView`'s
        // conflict alert. A clearing setter is what made every content delete a silent no-op
        // (#968/#969): SwiftUI runs it as the dialog dismisses, which lands *after* the Delete
        // button's synchronous action but *before* the `Task` it spawns gets to run, so
        // `confirmDelete()`'s `guard let item = deleteConfirmation` always saw nil and returned —
        // no delete, no commit, and no error to raise the alert below.
        .confirmationDialog(
            contentDeleteTitle,
            isPresented: Binding(
                get: { bindableModel.deleteConfirmation != nil },
                set: { _ in }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await model.confirmDelete() } }
            Button("Cancel", role: .cancel) { model.deleteConfirmation = nil }
        } message: {
            Text("This will remove the file from your site. You can bring it back with Edit ▸ Undo.")
        }
        .alert(
            "Couldn't complete that action",
            isPresented: Binding(
                get: { model.contentActionError != nil },
                set: { if !$0 { model.contentActionError = nil } }),
            presenting: model.contentActionError
        ) { _ in
            Button("OK", role: .cancel) { model.contentActionError = nil }
        } message: { msg in
            Text(msg)
        }
        .sheet(item: Binding(
            get: { model.pendingRedirectOfferRoute.map { IdentifiableRoute($0) } },
            set: { model.pendingRedirectOfferRoute = $0?.value }
        )) { route in
            if let navigator = model.navigator {
                AddRedirectSheet(source: route.value) { destination, code in
                    let saved = await navigator.saveRedirect(source: route.value, destination: destination, code: code)
                    return saved ? nil : navigator.redirectSaveError
                }
            }
        }
        .sheet(isPresented: $bindableModel.newPagePresented) {
            NewPageSheet(site: site) { title, route, template in
                await model.createPage(title: title, route: route, template: template)
            }
        }
        .sheet(isPresented: $bindableModel.newCollectionPresented) {
            NewCollectionEntrySheet(
                descriptors: contentTypeRegistry.all.filter { $0.collection != nil }
            ) { title, slug, descriptor, fieldValues in
                await model.createCollectionEntry(
                    title: title, slug: slug, descriptor: descriptor, fieldValues: fieldValues)
            }
        }
        .sheet(isPresented: $bindableModel.newPostPresented) {
            NewPostSheet(
                checkRestrictedAvailability: { await model.canPublishRestrictedPosts() }
            ) { title, visibility, body in
                switch visibility {
                case .public:
                    switch await model.createPost(title: title) {
                    case .created: return .success
                    case .siteNotFound: return .siteNotFound
                    case .failed(let reason): return .failed(reason: reason)
                    }
                case .contacts:
                    return await model.createRestrictedPost(title: title, body: body)
                }
            }
        }
        .sheet(isPresented: $bindableModel.newComponentPresented) {
            NewComponentSheet { name in
                await model.createComponent(name: name)
            }
        }
        .sheet(isPresented: $bindableModel.quickCapturePresented) {
            QuickCaptureSheet(
                pickerSites: nil,
                defaultSiteID: nil,
                initialURLString: model.quickCaptureURL ?? "",
                fetchMetadata: { try await LinkMetadataFetcher().fetch(url: $0) },
                onCreate: { _, title, urlString, commentary, imageURL, draft in
                    let result = await model.createLinkPost(
                        title: title, urlString: urlString, commentary: commentary,
                        imageURL: imageURL, draft: draft)
                    // Publish = create + the normal deploy path. deploySite() no-ops via its
                    // canRunDeploy guard when the runtime isn't available — the entry is already
                    // written draft: false and goes live with the next deploy (spec §3.3).
                    if case .created = result, !draft { model.deploySite() }
                    return result
                }
            )
        }
        // Drag a link anywhere onto the site window → quick capture for this site (#531).
        // File URLs (image drops onto the preview, .anglesite packages) don't match and
        // fall through to their existing handlers.
        .dropDestination(for: URL.self) { urls, _ in
            guard let web = QuickCapture.webURL(from: urls) else { return false }
            model.quickCaptureURL = web.absoluteString
            model.quickCapturePresented = true
            return true
        }
        // Edit ▸ Paste with a URL on the clipboard, while focus sits in the navigator/preview
        // chrome (not a text field — those take their own paste). Scoped to the URL flavor so
        // pasting prose never hijacks (#531). Reads the pasteboard directly: the provider
        // payload and the pasteboard agree here, and clipboardURLString is the one gate.
        .onPasteCommand(of: [.url]) { _ in
            guard let urlString = QuickCapture.clipboardURLString() else { return }
            model.quickCaptureURL = urlString
            model.quickCapturePresented = true
        }
        // The click-to-place HUD lives here, on the site window itself — NOT inside the Effects
        // gallery sheet, which is window-modal and therefore blocks input to the very preview it
        // asks the owner to click (#768 final review, Finding 4). Bottom-aligned so it occupies
        // only the capsule's own bounds; idle, it renders as an `EmptyView`.
        .overlay(alignment: .bottom) {
            EffectPlacementHUD(controller: model.effectPlacementController)
        }
        .sheet(isPresented: $bindableModel.effectsPresented) {
            EffectsGalleryView(
                controller: model.effectPlacementController,
                enterOverlayMode: {
                    model.preview.webView?.evaluateJavaScript("window.anglesite?._enterPlacementMode?.()")
                },
                exitOverlayMode: {
                    model.preview.webView?.evaluateJavaScript("window.anglesite?._exitPlacementMode?.()")
                }
            )
        }
        .sheet(isPresented: $bindableModel.micropubConnectPresented) {
            MicropubSiteConnectSheet(site: site)
        }
        .annotatedAsSite(site)
    }

    /// The window's trailing inspector panel content (#714 v2 slice 1) — the existing per-selection
    /// inspector, or the new Website inspector, chosen by `activeInspector`. Factored out of
    /// `siteUI(for:)`'s `.inspector` modifier as its own computed var rather than inlined, per the
    /// same type-checking-budget discipline as `mainPane(for:)`/`mainPaneContent(for:)` below.
    @ViewBuilder
    private var inspectorContent: some View {
        switch activeInspector {
        case .selection:
            if let selection = model.inspectorSelection {
                SiteInspectorView(
                    selection: selection,
                    canvasWebView: componentCanvasWebView,
                    previewBaseURL: model.preview.readyURL
                )
            }
        case .website:
            Group {
                if !websiteInspectorVisible {
                    // Render nothing while the panel is hidden, suspended, or collapsing — a leaf,
                    // not an empty branch, so the `.task(id:)` below still attaches (fix round 4,
                    // Important 3).
                    //
                    // The selection branch above gets this for free: its content is
                    // `inspectorContext`, which the dismissal path clears synchronously, so its
                    // column always animates closed over an empty subtree. The website panel's
                    // model deliberately outlives its presentation (it holds unsaved edits), so
                    // without this gate the whole `Form` stays mounted inside a column animating to
                    // zero width — and a `Form` on macOS is bridged through an
                    // `AppKitPlatformViewHost`, which invalidates layout from inside the display
                    // cycle's commit phase. `-[NSWindow _postWindowNeedsUpdateConstraints]` then
                    // raises, and the rethrown ObjC exception aborts the process (#1126 class).
                    //
                    // Verified live, both directions (#714 v2 slice 1 fix round 5): with the
                    // dismissal seam below but *without* this gate, six ⌘3/⌘1 pane switches
                    // survived but Metadata ▸ More Settings… still aborted — the heavier `.plist`
                    // editor rebuild lands while the collapse is still animating past the 300 ms
                    // settle (crash report Anglesite-2026-08-20-131656.ips, faulting frames
                    // `AppKitPlatformViewHost.invalidateLayout()` →
                    // `-[NSView setNeedsUpdateConstraints:]` → `_postWindowNeedsUpdateConstraints`).
                    // With the gate, the same sequence is clean.
                    //
                    // The gate cuts both ways in principle — leaving it *remounts* the `Form`, which
                    // is #1139's own crash shape (a fresh inspector subtree mounting into a column
                    // that's expanding) — but measurement says that half is not what bites here
                    // (#714 v2 slice 1 fix round 6, Important 2). Holding the content back behind
                    // its own settle was implemented and then reverted: with the mount deliberately
                    // delayed to 4 s, the app was already pinned at 92% CPU in AppKit's
                    // update-constraints cycle 0.5 s after the panel opened, i.e. the storm belongs
                    // to the *column opening* over a heavy main pane, and the mount is a bystander.
                    // See `SiteWindowModel.setWebsiteInspectorSuspended` for what that residual
                    // (⌥⌘J with the Graph pane up, reproduced identically on this branch's parent)
                    // does and does not have to do with this round.
                    //
                    // `clearInspectorThenSwitchPane` still resumes a suspension only after the pane
                    // rebuild has settled, so the remount never lands in the same transaction as
                    // the swap.
                    Color.clear.frame(width: 0, height: 0)
                } else if let websiteModel = model.websiteInspector {
                    WebsiteInspectorView(
                        model: websiteModel,
                        openStylesheet: { model.openFile($0) },
                        openMoreSettings: { model.openWebsiteSettings() }
                    )
                    // A site swap replaces the model instance (`handleSiteChanged()` tears the old
                    // one down and rebuilds against the new package). Keying on the package URL
                    // gives the panel a fresh view identity per site, so no view-local state
                    // (@FocusState, in-flight field editing) can carry across and write an edit
                    // into the previous site's Info.plist/.site-config (fix round 4, Critical 2).
                    .id(websiteModel.packageURL)
                } else {
                    // Deliberately NOT an empty branch: SwiftUI does not run `.task` for a subtree
                    // that renders nothing, so with `if let` alone the fallback below could never
                    // fire while the model was nil — exactly the state it exists to repair (fix
                    // round 4, Important 3). A spinner also replaces the blank column that used to
                    // flash while the site loaded.
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Belt-and-braces, not the guarantee. `SiteWindowModel.ensureWebsiteInspectorLoaded()`
            // is called from the paths that *are* guaranteed to run — `activateInspector(.website)`
            // for a toggle, `handleSiteChanged()` for a site load/swap under a persisted or
            // pressed-while-loading `.website` activation. This re-fires it on the site's identity
            // for anything neither path anticipated; the guard inside makes it idempotent.
            .task(id: model.site?.id) {
                model.ensureWebsiteInspectorLoaded()
            }
        }
    }

    @ViewBuilder
    private func mainPane(for site: SiteStore.Site) -> some View {
        // Editor and Graph are drill-in takeovers (opening a file, or Website ▸ Graph…), each with
        // its own Done control back to the canvas via View ▸ Preview (⌘1) — no in-content picker
        // row (#519, #714 v2 slice 2).
        mainPaneContent(for: site)
    }

    @ViewBuilder
    private func mainPaneContent(for site: SiteStore.Site) -> some View {
        switch model.mainPaneMode {
        case .editor:
            if case .text(let editorModel) = model.activeEditor {
                let activationKey = ComponentEditorActivationKey(
                    baseURL: model.preview.readyURL?.absoluteString,
                    fileID: editorModel.file.id
                )
                MainPaneEditorView(
                    model: editorModel,
                    componentEditor: model.componentEditor,
                    onCanvasWebView: { componentCanvasWebView = $0 },
                    onDone: { model.returnToCanvas() }
                )
                    // Re-fires on file change AND on the dev server becoming ready (nil→non-nil
                    // readyURL) — the same identity the old view-local LoadKey watched — so the
                    // hoisted model rebuilds exactly when the old @State model did. It ALSO
                    // restarts on every reappearance of this view (e.g. toggling Preview↔Editor
                    // back to the same component) even though `activationKey` didn't change —
                    // that's `.task(id:)`'s documented behavior, not a bug to work around here.
                    .task(id: activationKey) {
                        // Genuine key change (a new file, or the dev server just came up):
                        // any previously captured canvas webview belongs to the outgoing
                        // component — drop it until the new canvas reports in via
                        // `onCanvasWebView`, so the Style pane's ColorPicker scrub preview never
                        // pairs component B's model with component A's (possibly torn-down)
                        // webview during the rebuild (#714 review).
                        //
                        // A same-key re-appearance (the Preview↔Editor toggle case, #714 final
                        // review Important 1) must NOT clear it: `onCanvasWebView`/`makeNSView`
                        // reports the live webview synchronously during the render commit, which
                        // can land before this async task body even runs, and nil-ing it here
                        // unconditionally would then wipe out that just-reported webview and
                        // permanently break the scrub preview after every toggle.
                        if lastComponentActivationKey != activationKey {
                            componentCanvasWebView = nil
                        }
                        lastComponentActivationKey = activationKey
                        await model.ensureComponentEditorLoaded()
                    }
            } else if case .plist(let plistEditorModel) = model.activeEditor {
                PlistEditorView(model: plistEditorModel, onDone: { model.returnToCanvas() }) { title in
                    Task { await model.saveWebsiteTitle(title) }
                }
            } else {
                previewPane(for: site)
            }
        case .graph:
            SiteGraphExplorerView(
                model: model.graphExplorer,
                onOpenFile: { node in model.openGraphNode(node, site: site) },
                onDone: { model.returnToCanvas() }
            )
        case .cleanup:
            ProjectCleanupView(
                cleanup: model.cleanup,
                onOpen: { model.openCleanupCandidate($0) },
                onDelete: { await model.deleteCleanupCandidate($0) },
                onDone: { model.returnToCanvas() }
            )
        case .reader:
            MicrosubReaderView(reader: model.reader)
        case .followers:
            FollowersView(followers: model.followers)
        case .communities:
            CommunitiesView(communities: model.communities)
        case .moderation:
            ModerationView(moderation: model.moderation)
        case .contacts:
            ContactsView(
                contacts: model.contacts,
                candidateFollowerURLs: { await model.candidateFollowerURLsForContactsMatching() }
            )
        case .preview:
            previewPane(for: site)
        }
    }

    /// Task identity for component-editor activation — see the `.task` above.
    private struct ComponentEditorActivationKey: Hashable {
        let baseURL: String?
        let fileID: String
    }

    @ViewBuilder
    private func previewPane(for site: SiteStore.Site) -> some View {
        switch model.preview.state {
        case .ready(_, let url, _) where !model.startup.isShowingCompletionHold:
            PreviewView(
                url: model.preview.displayURL ?? url,
                router: model.preview.editRouter,
                annotationProvider: model.annotationProvider,
                wysiwygTransport: model.preview.wysiwygCanvas,
                onPlacementPick: { message in
                    await model.effectPlacementController.handlePick(message)
                },
                onGoalElementPick: { message in
                    await model.experimentStatsModel?.goalPickController.handlePick(message)
                },
                // A finished navigation means the page's injected JS — including the overlay's
                // placement-pick listener — was just thrown away and came back inactive. Cancel
                // rather than silently re-arm: the page may be a different page entirely now, and
                // an armed HUD over a listener that no longer exists waits forever (#768 final
                // review, Finding 8). `cancel()` is a no-op unless a pick is actually in flight.
                onPreviewNavigated: {
                    model.effectPlacementController.cancel()
                },
                onWebView: { [preview = model.preview] webView in
                    preview.webView = webView
                    // #1225 Task 10: gives WYSIWYGCanvasController.applyFormat something to post
                    // the Format menu's Strong/Emphasis/Add Link commands into once edit mode is on.
                    preview.wysiwygCanvas?.webView = webView
                    // No `mountEngine()` call here (unlike the final-review fix wave's Finding 1
                    // fix): this closure fires synchronously right after `webView.load(...)` is
                    // dispatched in `PreviewView.makeNSView` — before the page (and the
                    // `WKUserScript` that defines `window.__anglesiteWysiwygMount`) has actually
                    // finished loading, so a call here was *always* a silent no-op (JS's own `?.`
                    // swallows it). `PreviewView`'s own `WKNavigationDelegate` now mounts reliably
                    // once the page really finishes loading, covering both this initial-load
                    // ordering and every later reload/navigation (#1225 final-review round 2,
                    // Finding B) — see `PreviewView.Coordinator.webView(_:didFinish:)`.
                },
                // Explicit detach: ARC zeroing the model's weak `webView` doesn't fire `didSet`,
                // so without this the Back/Forward menu enablement would freeze when the dev
                // server restarts or fails (see PreviewModel.detachWebView).
                onWebViewDismantled: { [preview = model.preview] webView in preview.detachWebView(webView) }
            )
            .wysiwygCanvasFocusTracking(model.preview.wysiwygCanvas)
            // #1588 Task 11: a palette row dragged onto the canvas. Guarding on `wysiwygCanvas`
            // (nil except while Site ▸ Edit Page is on, per `PreviewModel.isEditModeEnabled`'s doc
            // comment) is what keeps this inert outside edit mode — no separate `active:` gate
            // needed the way `.onDeleteCommand` below requires one, since returning `false` here
            // both declines the drop and leaves nothing else attached that could conflict with it.
            .dropDestination(for: WYSIWYGPaletteDragPayload.self) { payloads, location in
                guard let payload = payloads.first, let canvas = model.preview.wysiwygCanvas, let webView = model.preview.webView else { return false }
                Task { await performWYSIWYGPaletteDrop(payload: payload, location: location, webView: webView, controller: canvas) }
                return true
            }
            // #1588 Task 13: a real Finder/Photos drag, stacked alongside Task 11's
            // `.dropDestination` above (a `Transferable`-based palette-row drag) rather than
            // replacing it — the two mechanisms serve different drag sources and SwiftUI allows
            // both attached to the same view. Same `wysiwygCanvas`-nil guard keeps this inert
            // outside edit mode. Reuses `resolveWYSIWYGDropTarget` (`PreviewView.swift`) for the
            // drop-target JS evaluate-and-decode step instead of duplicating it here.
            //
            // `UTType.fileURL` matches *any* Finder file drag, not only images (there's no
            // narrower UTI that still covers Photos' own promise), so a `.zip` dropped here is
            // accepted by the drag session and then rejected downstream by
            // `WYSIWYGImageAssetIngestor`'s magic-byte sniff. Each rejection along that path logs
            // to `LogCenter` (final-review Finding 3 / the plan's "no silent failure paths"
            // constraint) so the no-op is at least traceable in the debug pane; a user-facing
            // error presentation is deferred with the rest of the drop UX.
            .onDrop(of: [UTType.image.identifier, UTType.fileURL.identifier], isTargeted: nil) { providers, location in
                guard let canvas = model.preview.wysiwygCanvas, let webView = model.preview.webView,
                      let siteDirectory = model.preview.openSiteDirectory
                else { return false }
                let route = model.preview.activeRoute ?? "/"
                Task {
                    let logCenter = LogCenter.shared
                    guard var bytes = await WYSIWYGImageDropHandler.loadImageBytes(from: providers) else { return }

                    // #1671: embed the last-used file license (mirroring `Insert ▸ Image…`) before
                    // `ingest` writes the copy — never a picker at drop time, and never anything
                    // when no selection was persisted, per #999 §4's resolved defaults.
                    let policy = (try? LicensingStore(sourceDirectory: siteDirectory).load()) ?? LicensingPolicy()
                    let license = WYSIWYGDropLicenseResolver.resolve(
                        policy: policy, route: route, lastUsed: AppSettings.shared.lastUsedFileLicenseSelection)
                    if let license, let type = WYSIWYGImageAssetIngestor.sniffedUTType(bytes) {
                        do {
                            if case .embedded(let embedded) = try LicenseMetadataEmbedder.embed(license, into: bytes, type: type) {
                                bytes = embedded
                            }
                        } catch {
                            await logCenter.append(
                                source: WYSIWYGImageAssetIngestor.logSource, stream: .stderr,
                                text: "failed to embed license metadata into dropped image: \(error.localizedDescription)")
                        }
                    }

                    let assetPath: String?
                    do {
                        assetPath = try WYSIWYGImageAssetIngestor.ingest(bytes: bytes, siteDirectory: siteDirectory)
                    } catch {
                        await logCenter.append(
                            source: WYSIWYGImageAssetIngestor.logSource, stream: .stderr,
                            text: "failed to write dropped image into public/images: \(error.localizedDescription)")
                        return
                    }
                    guard let assetPath else { return }
                    guard let target = await resolveWYSIWYGDropTarget(at: location, webView: webView) else { return }
                    let newId = UUID().uuidString
                    // Alt-text proposal is stubbed empty — the real proposal is on-device AI
                    // (#1227, out of scope here per the design doc).
                    let content = BlockNodeContent(
                        kind: .astro, componentName: "img", props: ["src": .string(assetPath), "alt": .string("")],
                        slots: [:], sourceSpan: [0, 0])
                    await canvas.insertBlockAndSelect(parentId: target.parentId, slot: target.slot, index: target.index, newId: newId, block: content)
                }
                return true
            }
            // #1225 Task 11 / #1423: the canvas's own Delete target — attached only while the
            // sentinel above reports real keyboard focus on the canvas (menu-bar IA spec's "one
            // focus-scoped command" rule; no second Commands-level Delete button). The `active:`
            // gate (not just a nil-selection guard inside the closure) is load-bearing: leaving
            // this `.onDeleteCommand` attached unconditionally alongside `SiteNavigatorView`'s made
            // AppKit's Edit ▸ Delete menu-bridging pick between the two non-deterministically — see
            // `onDeleteCommand(active:perform:)`'s doc comment (`PreviewView.swift`).
            .onDeleteCommand(active: model.preview.wysiwygCanvas?.hasKeyboardFocus == true) {
                guard let canvas = model.preview.wysiwygCanvas else { return }
                Task { await canvas.deleteSelectedBlock() }
            }
            // #1588 Task 16 (reviewed): the canvas's own Copy target, same `active:`-gated shape
            // as `.onDeleteCommand` immediately above and for the same reason — a Commands-level
            // "Copy" button would duplicate AppKit's default Edit ▸ Copy item. `copySelectedBlock()`
            // writes HTML + plain text directly onto `NSPasteboard.general` itself (see its doc
            // comment, `WYSIWYGCanvasController.swift`), so this closure returns `[]`: SwiftUI's
            // `onCopyCommand(perform:)` requires a non-optional `[NSItemProvider]` back, but there's
            // nothing left for its own pasteboard-placement plumbing to add on top of that.
            .onCopyCommand(active: model.preview.wysiwygCanvas?.hasKeyboardFocus == true) {
                model.preview.wysiwygCanvas?.copySelectedBlock()
                return []
            }
            // #1588 Task 19: Edit ▸ Find… over the WYSIWYG canvas. `WYSIWYGFindBar` itself checks
            // `isFindBarPresented`, so this overlay is inert (renders nothing) outside edit mode
            // and while the bar isn't showing.
            .overlay(alignment: .top) {
                if let canvas = model.preview.wysiwygCanvas {
                    WYSIWYGFindBar(controller: canvas)
                }
            }
        case .starting, .ready:
            // `.ready` reaches here only while `isShowingCompletionHold` is true (see the guarded
            // case above) — a brief window so the fully-filled phase progress strip is actually
            // visible before swapping to the live preview.
            centeredStatus {
                StartupProgressView(
                    title: model.preview.isUpdatingDependencies
                        ? "Updating dependencies — this may take a minute…"
                        : "Starting dev server for \(site.name)…",
                    model: model.startup,
                    // Deliberately ungated (unlike the ⌥⌘D menu item): the point of #560 is
                    // letting non-developers look under the hood while they wait.
                    onShowLogs: { openWindow(id: "debug") }
                )
            }
        case .failed(_, let message):
            centeredStatus {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle).foregroundStyle(.orange)
                    Text("Can't preview \(site.name)").font(.headline)
                    Text(message)
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                    // Only for the vmnet failures `VmnetFailureRecovery` recognizes — plain Retry
                    // alone would keep reusing the same wedged network object (#812).
                    if VmnetFailureRecovery.isRecoverable(failureMessage: message) {
                        Button("Restart Networking & Retry") {
                            model.restartNetworkingAndRetry()
                        }
                    }
                    Button("Retry") {
                        model.retryPreview()
                    }
                    // Same deliberately-ungated affordance as the .starting screen (#560/#562):
                    // the message above is a one-liner, but the *why* is in the subprocess log.
                    Button("Show Logs") { openWindow(id: "debug") }
                        .buttonStyle(.link)
                        .font(.callout)
                        .accessibilityHint("Opens the log of the failed dev server launch.")
                }
            }
        case .idle:
            if model.preview.devServerStoppedByUser {
                // Site ▸ Stop Dev Server (#515) parks the runtime at `.idle` on purpose — show a
                // real stopped state with a restart affordance, not the pre-boot spinner.
                centeredStatus {
                    VStack(spacing: 12) {
                        Image(systemName: "stop.circle")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("Dev server stopped").font(.headline)
                        Text("The preview is paused for \(site.name). Start the dev server to resume.")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 420)
                        Button("Start Dev Server") {
                            model.startDevServer()
                        }
                    }
                }
            } else {
                centeredStatus { ProgressView() }
            }
        }
    }

    private func centeredStatus<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
    }

    /// Builds the Edit-menu Duplicate/Publish/Unpublish actions for whichever selection currently
    /// owns keyboard focus — the WYSIWYG canvas's block selection (#1225 Task 11) if it holds
    /// real focus, otherwise the Navigator's row selection — or nil when neither applies. This is
    /// the "one focus-scoped command" rule from the menu-bar IA spec: ⌘D Duplicate has exactly one
    /// live target at a time, decided by which surface has focus, not two competing menu items.
    /// Publish/Unpublish have no canvas equivalent, so the canvas branch always reports them nil;
    /// each Navigator action is individually nil when the selected row doesn't support that verb
    /// (`canDuplicate`/`canPublish`/`canUnpublish`), which is what disables the individual menu
    /// items rather than hiding the whole group. Delete has no action built here (#989) — see
    /// `NavigatorSelectionActions`; the canvas's own Delete is wired directly onto `PreviewView`
    /// via `.onDeleteCommand` in `previewPane(for:)`, same reasoning.
    private func navigatorSelectionActions(for model: SiteWindowModel) -> NavigatorSelectionActions? {
        if let canvas = model.preview.wysiwygCanvas, canvas.hasKeyboardFocus, canvas.selectedBlockId != nil {
            return NavigatorSelectionActions(
                duplicate: { Task { await canvas.duplicateSelectedBlock() } },
                publish: nil, unpublish: nil)
        }
        guard model.site != nil, let navigator = model.navigator, let id = navigator.selection else {
            return nil
        }
        let duplicateAction: (() -> Void)?
        if navigator.canDuplicate(id) {
            duplicateAction = {
                Task { await model.duplicate(id: id) }
            }
        } else {
            duplicateAction = nil
        }
        let publishAction: (() -> Void)?
        if navigator.canPublish(id) {
            publishAction = {
                Task { await model.publish(id: id) }
            }
        } else {
            publishAction = nil
        }
        let unpublishAction: (() -> Void)?
        if navigator.canUnpublish(id) {
            unpublishAction = {
                Task { await model.unpublish(id: id) }
            }
        } else {
            unpublishAction = nil
        }
        return NavigatorSelectionActions(
            duplicate: duplicateAction, publish: publishAction, unpublish: unpublishAction)
    }
}

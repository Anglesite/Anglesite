import AnglesiteCore

/// Stable accessibility identifiers for AX-driven automation (#1535).
///
/// Never user-visible and never localized: VoiceOver reads `accessibilityLabel`s, while these
/// strings exist so UI automation (System Events / AXUIElement scripts today, an XCUITest
/// target if one lands) can address controls without depending on localized, wording-sensitive
/// labels. See `docs/testing-macos-app.md` § Accessibility identifiers.
///
/// Naming: dotted `<surface>.<control>` paths with camelCase segments — `navigator.list`,
/// `debug.sourceFilter`.
/// Site-window toolbar controls derive theirs from `SiteToolbarItemID` so the two stable-ID
/// namespaces can never drift apart. Like those customization IDs, values are frozen once
/// shipped — automation scripts key off them (`AXIDTests` enforces format and uniqueness).
enum AXID {
    /// Identifier for a site-window toolbar control, derived from its frozen customization ID
    /// (`SiteToolbarItemIDTests` freezes the raw values).
    static func toolbar(_ id: SiteToolbarItemID) -> String { "toolbar.\(id.rawValue)" }

    // MARK: Site navigator (sidebar)

    static let navigatorList = "navigator.list"
    static let navigatorRenameField = "navigator.renameField"

    // MARK: Sites launcher

    /// The launcher's site list (#1641) — automation selects a row and performs `AXShowMenu` on it.
    static let launcherList = "launcher.list"

    // MARK: Shared sheet chrome

    /// The title/subtitle group every `SheetHeader`-based sheet and drawer renders; automation
    /// reads its accessibility label to learn which sheet is frontmost.
    static let sheetHeader = "sheet.header"

    // MARK: Main-pane takeover header (#714 v2 slice 2)

    /// The title group `MainPaneTakeoverHeader` renders for every takeover (Editor/Settings,
    /// Graph, Cleanup) — same one-shared-id-per-family convention as `sheetHeader` above:
    /// automation reads its label to learn which takeover is frontmost.
    static let mainPaneTakeoverHeader = "mainPaneTakeover.header"
    /// `MainPaneTakeoverHeader`'s Done control — a stable, non-localized way to drive "return to
    /// canvas" without depending on the (localized) "Done" label.
    static let mainPaneTakeoverDone = "mainPaneTakeover.done"

    // MARK: Website Settings takeover (#1751)

    /// The Settings tab picker — `PlistEditorView.tabBar`'s accessibility representation, whose
    /// segments are otherwise only addressable by their localized tab names.
    static let settingsTabs = "settings.tabs"
    /// The Workers tab's Cloudflare-dashboard deep links.
    static let settingsWorkersLogs = "settings.workers.logs"
    static let settingsWorkersAnalytics = "settings.workers.analytics"
    /// A Workers-tab row's activation switch, keyed by the catalog's worker id
    /// (`WorkerDescriptor.id`, e.g. `solid-pod`) — stable and non-localized, unlike the
    /// catalog-supplied display name that is the switch's only label.
    static func settingsWorkerToggle(_ workerID: String) -> String { "settings.workers.toggle.\(workerID)" }
    /// A Workers-tab row's status cell, keyed the same way: the "Inactive — not used" text, the
    /// "Active — used on N pages" popover button, or the switch's On/Off text — whichever the row
    /// renders. One id per row, so automation reads the row's state without knowing which shape it
    /// took.
    static func settingsWorkerStatus(_ workerID: String) -> String { "settings.workers.status.\(workerID)" }

    // MARK: Debug pane

    static let debugSourceFilter = "debug.sourceFilter"
    static let debugStreamFilter = "debug.streamFilter"
    static let debugSearchField = "debug.search"
    static let debugPauseToggle = "debug.pause"
    static let debugAutoScrollToggle = "debug.autoScroll"
    static let debugClearButton = "debug.clear"
    static let debugCopyButton = "debug.copy"
    static let debugSaveButton = "debug.save"
    /// The Server section's headline and the Local Workers subheading beneath it — both AX
    /// headings (#1752), so the Debug window's heading rotor has somewhere to land.
    static let debugServerHeader = "debug.serverHeader"
    static let debugLocalWorkersHeader = "debug.localWorkersHeader"

    /// A Local Workers row and its parts, keyed by the owning site's stable id
    /// (`WorkersDevSession.siteID`; a site has at most one dev session, so it is the row identity).
    /// `debugWorkerRow` is the `.contain` group labelled with the site name; the rest are the
    /// controls inside it. The URL link and copy button exist only while the session is
    /// `.running` with a URL; the failure text only while it is `.failed`.
    static func debugWorkerRow(_ siteID: String) -> String { "debug.worker.\(siteID)" }
    static func debugWorkerName(_ siteID: String) -> String { "debug.worker.\(siteID).name" }
    static func debugWorkerStatus(_ siteID: String) -> String { "debug.worker.\(siteID).status" }
    static func debugWorkerURL(_ siteID: String) -> String { "debug.worker.\(siteID).url" }
    static func debugWorkerCopy(_ siteID: String) -> String { "debug.worker.\(siteID).copy" }
    static func debugWorkerFailure(_ siteID: String) -> String { "debug.worker.\(siteID).failure" }

    /// Every hand-assigned identifier, for `AXIDTests`' uniqueness/format checks (the
    /// toolbar family is generated from `SiteToolbarItemID`, and the per-worker / per-site
    /// families above from their stable ids; each is frozen by its own formatting test).
    static let allStatic: [String] = [
        navigatorList, navigatorRenameField,
        launcherList,
        sheetHeader,
        mainPaneTakeoverHeader, mainPaneTakeoverDone,
        settingsTabs, settingsWorkersLogs, settingsWorkersAnalytics,
        debugSourceFilter, debugStreamFilter, debugSearchField,
        debugPauseToggle, debugAutoScrollToggle,
        debugClearButton, debugCopyButton, debugSaveButton,
        debugServerHeader, debugLocalWorkersHeader,
    ]
}

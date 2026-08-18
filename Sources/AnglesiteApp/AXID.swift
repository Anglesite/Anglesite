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

    // MARK: Shared sheet chrome

    /// The title/subtitle group every `SheetHeader`-based sheet and drawer renders; automation
    /// reads its accessibility label to learn which sheet is frontmost.
    static let sheetHeader = "sheet.header"

    // MARK: Debug pane

    static let debugSourceFilter = "debug.sourceFilter"
    static let debugStreamFilter = "debug.streamFilter"
    static let debugSearchField = "debug.search"
    static let debugPauseToggle = "debug.pause"
    static let debugAutoScrollToggle = "debug.autoScroll"
    static let debugClearButton = "debug.clear"
    static let debugCopyButton = "debug.copy"
    static let debugSaveButton = "debug.save"

    /// Every hand-assigned identifier, for `AXIDTests`' uniqueness/format checks (the
    /// toolbar family is generated from `SiteToolbarItemID` and covered separately).
    static let allStatic: [String] = [
        navigatorList, navigatorRenameField,
        sheetHeader,
        debugSourceFilter, debugStreamFilter, debugSearchField,
        debugPauseToggle, debugAutoScrollToggle,
        debugClearButton, debugCopyButton, debugSaveButton,
    ]
}

import AnglesiteCore
import Foundation

extension SiteToolbarItemID {
    /// The item's user-facing name, used for `NSToolbarItem.label` / `.paletteLabel` under the
    /// AppKit shell (#1699 slice 2). Without it every hosted item shows up nameless in
    /// View ▸ Customize Toolbar… and in the toolbar's overflow menu — a `NSHostingView`-backed
    /// item has no title of its own for AppKit to fall back on.
    ///
    /// Each value is the wording that item's SwiftUI content already uses in
    /// `SiteWindow.toolbarItemContent(_:site:)`, so the palette and the button agree. The three
    /// exceptions have no single `Label` to copy and take an equivalent string the app already
    /// ships: `sync` and `securityReports` are badge views (their content carries only an
    /// `accessibilityLabel`), and `github` renders one of two labels depending on whether the
    /// site already has a remote, while a palette label has to be stable.
    ///
    /// Lives in the app target rather than beside the enum in AnglesiteCore because these are
    /// localized strings: `String(localized:)` literals are only extracted into
    /// `Sources/AnglesiteApp/Localizable.xcstrings` (and only checked by
    /// `scripts/check-localization-catalog.sh`) for app-target sources. The exhaustive `switch`
    /// gives the same compile-time completeness guarantee a stored property on the enum would.
    var displayTitle: String {
        switch self {
        case .graph: String(localized: "Site Graph")
        case .backup: String(localized: "Backup")
        case .audit: String(localized: "Audit")
        case .openInBrowser: String(localized: "Open in Browser")
        case .harden: String(localized: "Harden")
        case .domainConfigAudit: String(localized: "Domain Config")
        case .agentReadiness: String(localized: "Agent Readiness")
        case .onionRouting: String(localized: "Onion Routing")
        case .aiSearch: String(localized: "AI Search")
        case .domain: String(localized: "Domain")
        case .integration: String(localized: "Add Integration…")
        case .siriReadiness: String(localized: "Siri AI Readiness")
        case .relatedPages: String(localized: "Related Pages")
        case .github: String(localized: "GitHub")
        case .deploy: String(localized: "Publish Site")
        case .chat: String(localized: "Chat")
        case .inspector: String(localized: "Inspector")
        case .wysiwygPalette: String(localized: "Block Palette")
        case .styleGuide: String(localized: "Style Guide")
        case .sync: String(localized: "iCloud Sync")
        case .securityReports: String(localized: "Security Reports")
        case .insert: String(localized: "Insert")
        case .websiteInspector: String(localized: "Website Inspector")
        }
    }
}

import Foundation

/// Stable identifiers for the site window's customizable toolbar items (#519).
///
/// These raw values are API: macOS persists each user's toolbar customization keyed by them, so
/// renaming one silently discards every user's saved layout. `SiteToolbarItemIDTests` freezes the
/// full set — change a raw value only with a deliberate migration story.
///
/// Lives in AnglesiteCore (not the app target) solely so CI's SwiftPM test suites can enforce the
/// freeze; hosted app-target tests don't run on CI (see CLAUDE.md "Build").
public enum SiteToolbarItemID: String, CaseIterable, Sendable {
    case graph
    case backup
    case audit
    case openInBrowser
    case harden
    /// Domain config drift audit + reconcile (#1171): declared `anglesite.json` vs live Cloudflare.
    case domainConfigAudit
    /// Cloudflare Agent Readiness score for the deployed site (#1248).
    case agentReadiness
    case onionRouting
    case aiSearch
    case domain
    case integration
    case siriReadiness
    case relatedPages
    /// Non-MAS builds only; the id stays reserved on MAS so layouts roam across build flavors.
    case github
    case deploy
    case chat
    case inspector
    /// Toggles the native WYSIWYG block palette source list (#1588 Task 20).
    case wysiwygPalette
    case styleGuide
    /// iCloud sync status badge (#881) — synced/syncing/waiting-for-iCloud/needs-attention.
    case sync
    /// Open GitHub security advisories + Dependabot alerts badge (#975).
    case securityReports
    /// The `+` content-creation menu (#714 v2 slice 3): New Page…/New Post…/New Collection
    /// Entry…, joined later by a Blocks section (slice 4).
    case insert
    /// Toggles the Website inspector (Document analog, #714 v2 slice 1/3) — mutually exclusive
    /// with `inspector` (the selection/Format-analog inspector).
    case websiteInspector

    /// Whether this item starts in the toolbar's curated default set, vs. hidden in the palette
    /// until a user adds it via View ▸ Customize Toolbar… (#510). `SiteWindow` drives each item's
    /// `.defaultCustomization(_:)` modifier from this property rather than hardcoding `.hidden`
    /// per call site, so `SiteToolbarItemIDTests` can pin the default/hidden split in CI — a gap
    /// the #714 v2 slice 3 review flagged: nothing previously caught a PR that dropped or forgot
    /// a `.defaultCustomization(.hidden)` line.
    public var isDefaultVisible: Bool {
        switch self {
        case .graph, .backup, .audit, .harden, .domainConfigAudit, .agentReadiness, .onionRouting,
             .aiSearch, .domain, .integration, .siriReadiness, .relatedPages, .github, .styleGuide:
            return false
        case .openInBrowser, .insert, .deploy, .chat, .inspector, .wysiwygPalette, .sync,
             .securityReports, .websiteInspector:
            return true
        }
    }
}

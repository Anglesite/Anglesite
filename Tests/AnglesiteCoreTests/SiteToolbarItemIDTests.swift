import Testing
@testable import AnglesiteCore

struct SiteToolbarItemIDTests {
    /// The site-window toolbar item ids are API: macOS persists user toolbar customizations keyed
    /// by these strings, so a rename silently discards every user's saved layout (#519). This test
    /// freezes the exact set — if it fails, you are breaking saved customizations; only proceed
    /// with a deliberate migration story, then update the expectation.
    @Test func toolbarItemIDsAreFrozen() {
        #expect(SiteToolbarItemID.allCases.map(\.rawValue) == [
            "graph",
            "backup",
            "audit",
            "openInBrowser",
            "harden",
            "domainConfigAudit",
            "agentReadiness",
            "onionRouting",
            "aiSearch",
            "domain",
            "integration",
            "siriReadiness",
            "relatedPages",
            "github",
            "deploy",
            "chat",
            "inspector",
            "wysiwygPalette",
            "styleGuide",
            "sync",
            "securityReports",
            "insert",
            "websiteInspector",
        ])
    }

    /// First retired toolbar id (#714 v2 slice 2): `panes` — the Preview/Editor/Graph segmented
    /// control — is gone from the toolbar entirely; Editor and Graph are reached by drilling in
    /// (opening a file, Website ▸ Graph…) instead. SwiftUI silently drops unknown ids from a saved
    /// `NSToolbar` customization, so a user who customized their toolbar before this ship keeps
    /// the rest of their layout; "panes" just never reappears. Don't reuse this raw value.
    @Test func panesIsRetiredNotReused() {
        #expect(!SiteToolbarItemID.allCases.map(\.rawValue).contains("panes"))
    }
}

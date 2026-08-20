import Testing
@testable import AnglesiteAppCore

/// Pins the trailing panel's activation rules (#714 v2 slice 1, fix round 4). These used to live
/// inline in `SiteWindow`'s two toggle funcs, where nothing could test them — and the invariant
/// they carry is exactly the one whose violation rendered the Website inspector permanently blank
/// in the live app: the panel's model must be requested BEFORE the activation it renders under is
/// written.
@Suite("InspectorActivationPolicy")
struct InspectorActivationPolicyTests {
    @Test("pressing the active inspector's command hides the panel")
    func secondPressHides() {
        let selection = InspectorActivationPolicy.apply(
            current: .selection, shown: true, target: .selection)
        #expect(selection.active == .selection)
        #expect(selection.shown == false)

        let website = InspectorActivationPolicy.apply(
            current: .website, shown: true, target: .website)
        #expect(website.active == .website)
        #expect(website.shown == false)
    }

    @Test("pressing the active inspector's command while hidden shows it again")
    func pressWhileHiddenShows() {
        let outcome = InspectorActivationPolicy.apply(
            current: .website, shown: false, target: .website)
        #expect(outcome.active == .website)
        #expect(outcome.shown)
    }

    @Test("switching kind always shows the requested inspector — never both, never a hide")
    func switchingIsMutuallyExclusiveAndAlwaysShows() {
        for shown in [true, false] {
            let toWebsite = InspectorActivationPolicy.apply(
                current: .selection, shown: shown, target: .website)
            #expect(toWebsite.active == .website)
            #expect(toWebsite.shown)

            let toSelection = InspectorActivationPolicy.apply(
                current: .website, shown: shown, target: .selection)
            #expect(toSelection.active == .selection)
            #expect(toSelection.shown)
        }
    }

    /// The load-bearing ordering invariant. `SiteWindow.activateInspector(_:)` acts on
    /// `needsWebsiteModel` before writing `active`/`shown`, so "requested exactly when the website
    /// panel ends up presented" is what guarantees the model is non-nil the first time SwiftUI
    /// builds the panel's content under the new activation.
    @Test("the website model is requested exactly when the outcome leaves the website panel presented")
    func websiteModelRequestedExactlyWhenPresented() {
        let cases: [(ActiveSiteInspector, Bool, ActiveSiteInspector)] = [
            (.selection, true, .selection), (.selection, false, .selection),
            (.selection, true, .website), (.selection, false, .website),
            (.website, true, .selection), (.website, false, .selection),
            (.website, true, .website), (.website, false, .website)
        ]
        for (current, shown, target) in cases {
            let outcome = InspectorActivationPolicy.apply(
                current: current, shown: shown, target: target)
            #expect(
                outcome.needsWebsiteModel == (outcome.active == .website && outcome.shown),
                "current: \(current), shown: \(shown), target: \(target)"
            )
        }
    }

    /// The write-back suppression exists only for the switch seam (#968/#969 through the new
    /// activation) — arming it on a plain show/hide of the already-active inspector would swallow
    /// a genuine write-back.
    @Test("the stale-write-back suppression is armed only when the activation switches kind")
    func suppressionArmedOnlyOnSwitch() {
        #expect(InspectorActivationPolicy.apply(
            current: .selection, shown: true, target: .website).armSuppress)
        #expect(InspectorActivationPolicy.apply(
            current: .website, shown: true, target: .selection).armSuppress)
        #expect(!InspectorActivationPolicy.apply(
            current: .selection, shown: true, target: .selection).armSuppress)
        #expect(!InspectorActivationPolicy.apply(
            current: .website, shown: false, target: .website).armSuppress)
    }

    /// A second ⌥⌘J on the presented website panel. Pinned because three things about the outcome
    /// are load-bearing: it must hide (not switch kind), it must leave `active == .website` so the
    /// next ⌥⌘J brings the same panel straight back, and it must not request a model for a panel
    /// that is going away.
    ///
    /// Note what does *not* come through here any more: fix round 5 dismissed the panel ahead of a
    /// main-pane swap by reusing this policy, which meant an app-initiated, temporary withholding
    /// wrote the user's persisted `inspectorShown` preference to false — More Settings… closed the
    /// panel for good. Round 6 moved that to `SiteWindow.suspendWebsiteInspector(_:)`, which is
    /// deliberately *not* an activation change and so has no business in this policy.
    @Test("dismissing the presented website panel is a plain hide that keeps it the active kind")
    func websiteDismissalIsAPlainHide() {
        let outcome = InspectorActivationPolicy.apply(
            current: .website, shown: true, target: .website)
        #expect(outcome.shown == false)
        #expect(outcome.active == .website)
        #expect(!outcome.armSuppress)
        #expect(!outcome.needsWebsiteModel)
    }
}

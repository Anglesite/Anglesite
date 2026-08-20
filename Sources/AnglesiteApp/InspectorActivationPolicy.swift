/// The window trailing panel's mutually-exclusive activation rules (#714 v2 slice 1), hoisted out
/// of `SiteWindow` as a pure function so they can be tested.
///
/// `SiteWindow` is a SwiftUI `View` with `@SceneStorage` state and no view-inspection harness in
/// this repo, so the load-bearing invariants of its two inspector toggles — mutual exclusivity,
/// second-press-hides, and above all *the website inspector's model must be requested before the
/// activation flips*, never after — were only enforced by prose. This mirrors the repo's existing
/// precedent of pushing app-target logic into a type the SwiftPM test targets can reach
/// (`TokenOnboarding` for `DeployModel`'s orchestration).
///
/// Everything here is value-in/value-out: the caller applies the returned `Outcome` as one
/// synchronous MainActor transaction, which is what the #968/#969 presentation-gate discipline
/// requires (no suspension point between reading the current activation and writing the new one).
enum InspectorActivationPolicy {
    /// What the caller must do, in the order the fields are documented.
    struct Outcome: Equatable {
        /// Suppress one stale presentation write-back — set only when the activation actually
        /// switches kind. See `SiteWindow.suppressNextInspectorWriteBack`.
        var armSuppress: Bool
        /// The website inspector's model must exist *before* `active`/`shown` are written, because
        /// the panel's content is built from that model the first time the new activation renders.
        /// True exactly when the outcome leaves the website inspector presented.
        var needsWebsiteModel: Bool
        /// The inspector kind that occupies the panel afterwards. Always the requested target —
        /// the two inspectors are mutually exclusive, so requesting one never leaves the other up.
        var active: ActiveSiteInspector
        /// Whether the panel is shown afterwards.
        var shown: Bool
    }

    /// Resolves a toggle request against the current activation.
    ///
    /// Pressing the *already-active* inspector's command toggles the panel's visibility; pressing
    /// the other one switches kind and always shows the panel (a switch is never also a hide —
    /// the user asked to see that inspector).
    ///
    /// - Parameters:
    ///   - current: The inspector kind currently occupying the panel.
    ///   - shown: Whether the panel is currently shown.
    ///   - target: The inspector kind whose toggle command was invoked.
    /// - Returns: The `Outcome` to apply as one synchronous transaction.
    static func apply(
        current: ActiveSiteInspector,
        shown: Bool,
        target: ActiveSiteInspector
    ) -> Outcome {
        let isSwitchingKind = current != target
        let willShow = isSwitchingKind ? true : !shown
        return Outcome(
            armSuppress: isSwitchingKind,
            // Requested whenever the website panel ends up presented — including the
            // hidden-then-shown case, where the model may have been torn down by a site change
            // since it was last built.
            needsWebsiteModel: target == .website && willShow,
            active: target,
            shown: willShow
        )
    }
}

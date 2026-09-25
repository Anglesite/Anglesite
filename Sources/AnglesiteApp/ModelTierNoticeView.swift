import SwiftUI
import AnglesiteCore

/// The BBEdit-style model-tier badge (#1965, revised LLM policy 2026-07-08 §8): a feature that
/// was designed for a larger model than the one serving it says so, in one line, wherever its
/// result appears. Renders nothing when `tier` is served as designed, so every call site can
/// declare the tier its feature targets unconditionally and the badge disappears on its own
/// the day the PCC entitlement lands (`FoundationModelTier.servingTier`).
///
/// The copy comes from `FoundationModelTier.degradationNotice` rather than a local literal so
/// the sheets here and the canvas selection toolbar (which receives the same string on
/// `WritingHelpOutcome.rewritten`'s `notice`) can never drift apart.
struct ModelTierNoticeView: View {
    let tier: FoundationModelTier

    var body: some View {
        if let notice = tier.degradationNotice {
            Label(notice, systemImage: "cpu")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(notice)
        }
    }
}

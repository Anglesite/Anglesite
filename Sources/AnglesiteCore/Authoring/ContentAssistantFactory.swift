import Foundation

/// The shared model-tier seam for content-help capabilities (#464/#465). Every heavy generation
/// path obtains its backend HERE with a requested `FoundationModelTier` — today `.privateCloudCompute`
/// is served by the on-device session (`FoundationModelTier.servingTier`), and every caller that
/// requests it (`CopyEditAuditor`, `SocialMediaPlanner`, `PostRepurposer`, writing help) shows
/// `FoundationModelTier.degradationNotice` so the owner knows (#1965). When real PCC lands,
/// `servingTier` is the one place that changes. `nil` below the Xcode-27 toolchain (no
/// FoundationModels — see #128), matching `SiteGraphExplainerFactory`.
public enum ContentAssistantFactory {
    /// Returns a `FoundationModelAssistant` targeting `tier`, or `nil` on a pre-Xcode-27
    /// toolchain where `FoundationModels` can't be linked (#128). Callers must treat `nil` as
    /// "assistant unavailable" (surface `ContentHelpDialogs.assistantUnavailable(feature:)` or
    /// degrade the feature), never as an error to retry.
    public static func make(tier: FoundationModelTier) -> (any ContentAssistant)? {
        #if compiler(>=6.4) && canImport(FoundationModels)
        return FoundationModelAssistant(tier: tier)
        #else
        return nil
        #endif
    }
}

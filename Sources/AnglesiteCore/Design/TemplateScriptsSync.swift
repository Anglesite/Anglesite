/// One silently-appliable action from `TemplateScriptsSyncChecker` — no owner consent needed for
/// either case (design doc §Detection steps 1 and 4).
public enum TemplateScriptsSyncAction: Sendable, Equatable {
    /// The template has a file the site doesn't have yet (added since this site scaffolded).
    case create(relativePath: String)
    /// The site's file is unmodified since its last known-good baseline, and the template moved on.
    case refresh(relativePath: String)

    /// The affected file's template-relative path, regardless of case — both actions target
    /// exactly one path, so callers can group/sort a plan without switching.
    public var relativePath: String {
        switch self {
        case .create(let path), .refresh(let path): return path
        }
    }
}

/// An app-owned file (`scripts/`, `src/lib/`) whose site copy differs from the app's and can't be
/// classified as a plain stale-but-untouched refresh: it was customized since its last baseline,
/// or it predates any baseline (a legacy site, #745). Before #1962 this was the one case put to
/// the owner ("Keep My Version" / "Update This File"); owner decision D1 (2026-09-08) closed that
/// — these are the app's own build/security machinery, so the app restores them without asking
/// (#1053) and tells the owner in consequences afterwards. The type survives as the record of
/// *which* files were restored rather than merely refreshed, so the site-open notice can say so.
public struct TemplateScriptsDivergence: Sendable, Equatable, Identifiable {
    /// `Identifiable` via the path — at most one divergence per file per check pass.
    public var id: String { relativePath }
    /// The divergent file's template-relative path.
    public let relativePath: String
    /// Hash of the template's current content — the content the restore writes.
    public let templateHash: String

    /// Creates a divergence record; normally only `TemplateScriptsSyncChecker` does.
    public init(relativePath: String, templateHash: String) {
        self.relativePath = relativePath
        self.templateHash = templateHash
    }
}

/// The full result of one `TemplateScriptsSyncChecker.check` pass. Every entry in both lists is
/// applied by the app without an owner decision (#1053, D1); the split only drives how the
/// outcome is reported.
public struct TemplateScriptsSyncPlan: Sendable, Equatable {
    /// Files to create or refresh silently — nothing of the owner's is overwritten.
    public let toApply: [TemplateScriptsSyncAction]
    /// App-owned files whose site copy had been changed — restored to the app's copy, and named
    /// as "restored" (not merely "updated") when the owner is told.
    public let divergences: [TemplateScriptsDivergence]

    /// Creates a plan; the all-empty default is the nothing-to-do result.
    public init(toApply: [TemplateScriptsSyncAction] = [], divergences: [TemplateScriptsDivergence] = []) {
        self.toApply = toApply
        self.divergences = divergences
    }

    /// True when the pass found nothing to write.
    public var isEmpty: Bool { toApply.isEmpty && divergences.isEmpty }
}

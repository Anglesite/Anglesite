import Foundation
import Observation
import AnglesiteCore

/// Drives the Experiment Results sheet (#769) and, as of #1518, the experiment lifecycle that
/// leads up to it: propose a suggestion, configure its variant/goal, start it running, and only
/// then fall back to manual-entry analysis. The retired Claude Code plugin's edge A/B machinery
/// (cookie-based variant assignment, an analytics pipeline reporting impressions/conversions back
/// to the app) was never rebuilt after #466 — see `ExperimentStats`' doc comment and the
/// follow-up (#1270) — so `.manual` still takes the two variants' counts as owner-typed input
/// (read off whatever analytics the owner already has) rather than reading them from a stored
/// experiment config. Fresh-per-open, same lifecycle as `CopyEditReportModel`.
@Observable @MainActor
final class ExperimentStatsModel: Identifiable {
    let id = UUID()
    let siteID: String
    let sourceDirectory: URL
    let currentRoute: String

    /// The sheet's current lifecycle position, resolved from `anglesite.json`'s declared
    /// experiment (if any) at construction time and advanced by `propose(from:)`/`proposeCustom`
    /// (this task) and the configure/start actions (Task 12).
    enum Step: Equatable {
        case manual
        case propose
        case configure(Draft)
        case starting
        case running(DomainConfig.Experiments.Experiment)
    }

    /// A not-yet-declared experiment being assembled through the configure step: an id/name/page
    /// seeded by `propose(from:)`, then filled in by Task 12's variant-scaffolding and
    /// goal-picking actions.
    struct Draft: Equatable {
        var id: String
        var name: String
        var page: String
        var variantID: String = "b"
        var variantName: String
        var variantPage: String?
        var goalKind: String?
        var goalPath: String?
        var goalDepth: Int?
        var goalSelector: String?

        /// A `draft`-status `DomainConfig.Experiments.Experiment` once the variant is scaffolded
        /// and a goal is picked — `nil` while either is still missing, matching `canStart`'s gate
        /// in Task 13.
        var asExperiment: DomainConfig.Experiments.Experiment? {
            guard let variantPage, let goalKind else { return nil }
            let goal = DomainConfig.Experiments.Experiment.Goal(
                kind: goalKind, path: goalPath, depth: goalDepth, selector: goalSelector)
            return DomainConfig.Experiments.Experiment(
                id: id, name: name, page: page,
                variant: .init(id: variantID, name: variantName, page: variantPage),
                split: 0.5, goal: goal, status: "draft")
        }
    }

    private(set) var step: Step
    let goalPickController = GoalElementPickController()

    // #769 manual-entry fields — unchanged from before this task.
    var experimentName: String = ""
    var controlName: String = "Original"
    var controlImpressions: Int = 0
    var controlConversions: Int = 0
    var treatmentName: String = "Variant"
    var treatmentImpressions: Int = 0
    var treatmentConversions: Int = 0

    private(set) var result: ExperimentStats.Result?
    private(set) var hasSufficientData = false
    private(set) var sampleRatioMismatch = false

    let suggestions = ExperimentStats.suggestionPlaybook

    init(siteID: String, sourceDirectory: URL, currentRoute: String) {
        self.siteID = siteID
        self.sourceDirectory = sourceDirectory
        self.currentRoute = currentRoute
        self.step = Self.resolveInitialStep(sourceDirectory: sourceDirectory)
    }

    /// Reads `anglesite.json`'s declared experiment (if any) to decide where the sheet opens:
    /// `.manual` when there's nothing declared, `.running` when it's live, `.configure`
    /// (pre-populated from the declaration) when it's still a draft.
    private static func resolveInitialStep(sourceDirectory: URL) -> Step {
        guard let config = try? DomainConfigStore(sourceDirectory: sourceDirectory).load(),
              let active = config.experiments?.active?.first else {
            return .manual
        }
        if active.status == "running" { return .running(active) }
        return .configure(Draft(
            id: active.id, name: active.name, page: active.page,
            variantID: active.variant.id, variantName: active.variant.name, variantPage: active.variant.page,
            goalKind: active.goal.kind, goalPath: active.goal.path,
            goalDepth: active.goal.depth, goalSelector: active.goal.selector))
    }

    /// Advances from `.manual` to the suggestion-browsing step. A no-op from any other step.
    func openPropose() {
        guard case .manual = step else { return }
        step = .propose
    }

    /// Seeds a `Draft` from a playbook suggestion's title and moves to `.configure`.
    func propose(from suggestion: ExperimentStats.Suggestion) {
        proposeCustom(name: suggestion.title)
    }

    /// Seeds a `Draft` from an owner-typed name (slugified into the experiment id) and moves to
    /// `.configure`. `page` defaults to the route the sheet was opened from.
    func proposeCustom(name: String) {
        let slug = ContentScaffold.slugify(name)
        step = .configure(Draft(id: slug, name: name, page: currentRoute, variantName: "\(name) — variant"))
    }

    /// Both variants need at least one visitor before there's anything to analyze —
    /// `ExperimentStats.Variant`'s own clamping already handles zero/negative conversions.
    var canAnalyze: Bool {
        controlImpressions > 0 && treatmentImpressions > 0
    }

    func analyze() {
        guard canAnalyze else { return }
        let control = ExperimentStats.Variant(
            name: controlName.isEmpty ? "Original" : controlName,
            impressions: controlImpressions, conversions: controlConversions)
        let treatment = ExperimentStats.Variant(
            name: treatmentName.isEmpty ? "Variant" : treatmentName,
            impressions: treatmentImpressions, conversions: treatmentConversions)
        result = ExperimentStats.analyze(control: control, treatment: treatment)
        hasSufficientData = ExperimentStats.hasSufficientData(control: control, treatment: treatment)
        sampleRatioMismatch = ExperimentStats.hasSampleRatioMismatch(control: control, treatment: treatment)
    }

    var summary: String? {
        guard let result else { return nil }
        return ExperimentStats.formatSummary(
            experimentName: experimentName.isEmpty ? "Experiment" : experimentName, result: result)
    }

    /// Clears the result so the owner can revise counts and re-analyze — doesn't reset the
    /// entered counts themselves.
    func editAgain() {
        result = nil
    }
}

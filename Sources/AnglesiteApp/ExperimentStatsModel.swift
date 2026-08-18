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
    /// Resolves `siteID` back to `sourceDirectory` — the only site this model ever operates on —
    /// rather than widening `NativeContentOperations`' general-purpose multi-site resolver.
    private let contentOps: NativeContentOperations

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
        self.contentOps = NativeContentOperations(
            siteDirectory: { queriedSiteID in queriedSiteID == siteID ? sourceDirectory : nil })
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

    /// Duplicates the control page under `/x/<experimentID>/<variantID>` via
    /// `NativeContentOperations.duplicatePageAsVariant`, then records the built route on the
    /// draft and persists it. A no-op outside `.configure` or once a variant is already scaffolded
    /// (re-running would collide with the existing variant file).
    func scaffoldVariant() async {
        guard case .configure(var draft) = step, draft.variantPage == nil else { return }
        let controlRelPath = "src/pages\(draft.page == "/" ? "/index" : draft.page).astro"
        let result = await contentOps.duplicatePageAsVariant(
            siteID: siteID, relativePath: controlRelPath, experimentID: draft.id, variantID: draft.variantID)
        guard case .created(_, let route) = result else { return }
        draft.variantPage = route
        step = .configure(draft)
        persistDraft(draft)
    }

    /// Sets a pageview goal (reaching `path` counts as a conversion) and persists the draft.
    func setPageviewGoal(path: String) {
        updateDraftGoal { $0.goalKind = "pageview"; $0.goalPath = path; $0.goalDepth = nil; $0.goalSelector = nil }
    }

    /// Sets a scroll-depth goal (`depth` percent of the page scrolled) and persists the draft.
    func setScrollGoal(depth: Int) {
        updateDraftGoal { $0.goalKind = "scroll"; $0.goalDepth = depth; $0.goalPath = nil; $0.goalSelector = nil }
    }

    /// Call after `goalPickController.state` reaches `.succeeded(selector:)` — the sheet view's
    /// `.onChange(of: goalPickController.state)` is the caller (Task 14).
    func applyPickedVisibleGoal() {
        guard case .succeeded(let selector) = goalPickController.state else { return }
        updateDraftGoal { $0.goalKind = "visible"; $0.goalSelector = selector; $0.goalPath = nil; $0.goalDepth = nil }
        goalPickController.acknowledge()
    }

    private func updateDraftGoal(_ mutate: (inout Draft) -> Void) {
        guard case .configure(var draft) = step else { return }
        mutate(&draft)
        step = .configure(draft)
        persistDraft(draft)
    }

    /// Best-effort write-through of the in-progress draft to `anglesite.json` — a no-op until
    /// both the variant and a goal are set (`Draft.asExperiment` is `nil` until then).
    private func persistDraft(_ draft: Draft) {
        guard let experiment = draft.asExperiment else { return }
        DomainConfigStore.update(sourceDirectory: sourceDirectory) { $0.experiments = .init(active: [experiment]) }
    }

    /// Gates Task 13's start action: both the variant page and a goal must be set.
    var canStart: Bool {
        guard case .configure(let draft) = step else { return false }
        return draft.asExperiment != nil
    }

    /// Flips the draft's status to `running`, persists it, and invokes `deploy` — a closure rather
    /// than a direct `DeployModel` dependency so this model stays testable without constructing one
    /// (`DeployModel` pulls in token/license/container machinery none of this model's own logic
    /// needs). `SiteWindow` (Task 15) supplies the real `DeployModel.deploy(...)` call; the view's
    /// own `.onChange(of: deployModel.phase)` then calls `observeDeployPhase(_:)` below.
    func start(deploy: (String, URL, URL, [String]) -> Void) {
        guard case .configure(let draft) = step, var experiment = draft.asExperiment else { return }
        experiment.status = "running"
        experiment.startedAt = ISO8601DateFormatter().string(from: Date()).prefix(10).description
        DomainConfigStore.update(sourceDirectory: sourceDirectory) { $0.experiments = .init(active: [experiment]) }
        step = .starting
        deploy(siteID, sourceDirectory, sourceDirectory, [experiment.page, experiment.variant.page])
    }

    /// Called from the sheet view's `.onChange(of: deployModel.phase)` while `step == .starting`.
    /// Any phase other than a clean success reverts to `.configure` with the draft intact and its
    /// config entry rolled back to `"draft"` — a failed start must never leave `anglesite.json`
    /// claiming a test is live when the deploy that would make it so never landed.
    func observeDeployPhase(_ phase: DeployModel.Phase) {
        guard case .starting = step else { return }
        switch phase {
        case .succeeded:
            guard let config = try? DomainConfigStore(sourceDirectory: sourceDirectory).load(),
                  let running = config.experiments?.active?.first else { return }
            step = .running(running)
        case .failed(let reason, _):
            revertToConfigureAfterFailedStart(reason: reason)
        case .blocked:
            revertToConfigureAfterFailedStart(reason: "The pre-deploy check found issues that need fixing first.")
        case .idle, .running, .workerNameConflict, .webmentionPaidPlanConfirmationNeeded, .domainConfigDrift:
            return
        }
    }

    private func revertToConfigureAfterFailedStart(reason: String) {
        guard case .starting = step,
              let config = try? DomainConfigStore(sourceDirectory: sourceDirectory).load(),
              let entry = config.experiments?.active?.first else { return }
        DomainConfigStore.update(sourceDirectory: sourceDirectory) { config in
            var reverted = entry
            reverted.status = "draft"
            reverted.startedAt = nil
            config.experiments = .init(active: [reverted])
        }
        step = .configure(Draft(
            id: entry.id, name: entry.name, page: entry.page,
            variantID: entry.variant.id, variantName: entry.variant.name, variantPage: entry.variant.page,
            goalKind: entry.goal.kind, goalPath: entry.goal.path,
            goalDepth: entry.goal.depth, goalSelector: entry.goal.selector))
        startFailureReason = reason
    }

    private(set) var startFailureReason: String?
}

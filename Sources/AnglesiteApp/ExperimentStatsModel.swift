import Foundation
import Observation
import AnglesiteCore

/// Drives the Experiment Results sheet (#769) and, as of #1518/#1270 slice 6, the full experiment
/// lifecycle: propose a suggestion, configure its variant/goal, start it running, conclude it
/// (promote/keep/discard), and only then fall back to manual-entry analysis. The retired Claude
/// Code plugin's edge A/B machinery (cookie-based variant assignment, an analytics pipeline
/// reporting impressions/conversions back to the app) has since been rebuilt as deterministic
/// template TypeScript + Swift (#1270 slices 1-4) — `.manual` still takes the two variants' counts
/// as owner-typed input (read off whatever analytics the owner already has) for a non-Cloudflare
/// deploy or a site with no token configured, but live prefill (#1270 §4/§10 slice 4) wired the
/// manual form up to `ExperimentResultsSync`: when the site has a running experiment, a
/// provisioned D1 database, and a Cloudflare token, `loadLivePrefillIfAvailable()` fills the
/// manual form's fields from live counts instead of leaving them for the owner to type.
/// Fresh-per-open, same lifecycle as `CopyEditReportModel`.
@Observable @MainActor
final class ExperimentStatsModel: Identifiable {
    let id = UUID()
    let siteID: String
    let sourceDirectory: URL
    private let configDirectory: URL
    let currentRoute: String

    /// The sheet's current lifecycle position, resolved from `anglesite.json`'s declared
    /// experiment (if any) at construction time and advanced by `propose(from:)`/`proposeCustom`
    /// and the configure/start actions.
    enum Step: Equatable {
        case manual
        case propose
        case configure(Draft)
        case starting
        case running(DomainConfig.Experiments.Experiment)
    }

    /// A not-yet-declared experiment being assembled through the configure step: an id/name/page
    /// seeded by `propose(from:)`, then filled in by the variant-scaffolding and goal-picking
    /// actions.
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
        /// and a goal is picked — `nil` while either is still missing, matching `canStart`'s gate.
        ///
        /// The single choke point through which anything reaches `anglesite.json`, so it is also
        /// where the served-route shape `scripts/pre-deploy-check.ts` demands is enforced: `page`,
        /// `variant.page`, and a `pageview` goal's `path` all get the trailing slash, whatever
        /// shape the `Draft` was assembled from (a fresh propose, a legacy config entry read back
        /// by `resolveInitialStep`, or a failed start's revert). A slash-less value here fails the
        /// gate for *every* subsequent deploy of the site — draft entries are validated too —
        /// which is a publishing-breaking regression the app itself would have created (#1518).
        var asExperiment: DomainConfig.Experiments.Experiment? {
            guard let variantPage, let goalKind else { return nil }
            let goal = DomainConfig.Experiments.Experiment.Goal(
                kind: goalKind,
                path: goalPath.map { goalKind == "pageview" ? ContentScaffold.servedRoute($0) : $0 },
                depth: goalDepth, selector: goalSelector)
            return DomainConfig.Experiments.Experiment(
                id: id, name: name, page: ContentScaffold.servedRoute(page),
                variant: .init(
                    id: variantID, name: variantName,
                    page: ContentScaffold.servedRoute(variantPage)),
                split: 0.5, goal: goal, status: "draft")
        }
    }

    private(set) var step: Step
    let goalPickController = GoalElementPickController()
    /// Resolves `siteID` back to `sourceDirectory` — the only site this model ever operates on —
    /// rather than widening `NativeContentOperations`' general-purpose multi-site resolver.
    private let contentOps: NativeContentOperations

    // #769 manual-entry fields.
    var experimentName: String = "" { didSet { markUserEditedIfNeeded() } }
    var controlName: String = "Original" { didSet { markUserEditedIfNeeded() } }
    var controlImpressions: Int = 0 { didSet { markUserEditedIfNeeded() } }
    var controlConversions: Int = 0 { didSet { markUserEditedIfNeeded() } }
    var treatmentName: String = "Variant" { didSet { markUserEditedIfNeeded() } }
    var treatmentImpressions: Int = 0 { didSet { markUserEditedIfNeeded() } }
    var treatmentConversions: Int = 0 { didSet { markUserEditedIfNeeded() } }

    /// Set once the owner has typed into any field, so an in-flight `loadLivePrefillIfAvailable()`
    /// fetch that resolves afterward knows not to clobber it (the sheet's fields are editable from
    /// the moment it opens, and the fetch is fire-and-forget).
    private(set) var hasUserEdits = false
    /// Suppresses `hasUserEdits` tracking while the model itself is writing prefill values.
    private var isApplyingLivePrefill = false

    private func markUserEditedIfNeeded() {
        guard !isApplyingLivePrefill else { return }
        hasUserEdits = true
    }

    private(set) var result: ExperimentStats.Result?
    private(set) var hasSufficientData = false
    private(set) var sampleRatioMismatch = false

    /// Set once `loadLivePrefillIfAvailable()` has filled the fields from live D1 counts, so the
    /// sheet can tell the owner these numbers came from their site rather than typed in by hand.
    private(set) var isLive = false

    let suggestions = ExperimentStats.suggestionPlaybook

    init(siteID: String, sourceDirectory: URL, configDirectory: URL, currentRoute: String) {
        self.siteID = siteID
        self.sourceDirectory = sourceDirectory
        self.configDirectory = configDirectory
        self.currentRoute = currentRoute
        self.step = Self.resolveInitialStep(sourceDirectory: sourceDirectory)
        self.contentOps = NativeContentOperations(
            siteDirectory: { queriedSiteID in queriedSiteID == siteID ? sourceDirectory : nil })
    }

    /// Fetches live counts for the site's running experiment and prefills the manual form, if
    /// available. A no-op (fields stay owner-editable, empty/zeroed as usual) when there's no
    /// running experiment, no provisioned D1 database, or no Cloudflare token — the manual-entry
    /// path is unaffected either way. Called once, right after presentation (see `SiteWindowModel
    /// .presentExperimentStats()`), same fire-and-forget shape as other async-prefill models — it
    /// runs regardless of which `step` the sheet opens in, so the manual form already has live
    /// counts by the time `returnToManual()` reaches it from `.running`.
    /// Also a no-op if the owner has already typed into any field by the time the fetch resolves
    /// (`hasUserEdits`) — the sheet's fields are editable the moment it opens, so without this
    /// guard a slow fetch could silently overwrite counts the owner already entered by hand.
    /// `secretStore`/`baseURL`/`transport` are injectable, matching `ExperimentResultsSync.prefill`
    /// itself, so tests can stub the Cloudflare API instead of hitting the network.
    func loadLivePrefillIfAvailable(
        secretStore: any SecretStore = PlatformSecretStore.make(),
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) async {
        guard let prefill = await ExperimentResultsSync.prefill(
            sourceDirectory: sourceDirectory, configDirectory: configDirectory,
            secretStore: secretStore, baseURL: baseURL, transport: transport)
        else { return }
        guard !hasUserEdits else { return }
        isApplyingLivePrefill = true
        defer { isApplyingLivePrefill = false }
        experimentName = prefill.experiment.name
        controlName = "Original"
        controlImpressions = prefill.counts.controlVisitors
        controlConversions = prefill.counts.controlConversions
        treatmentName = prefill.experiment.variant.name
        treatmentImpressions = prefill.counts.variantVisitors
        treatmentConversions = prefill.counts.variantConversions
        isLive = true
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

    /// Whether `anglesite.json` currently declares a `"running"` experiment, read fresh from disk
    /// rather than derived from `step`. `step` alone can't answer this: `returnToManual()` (I6)
    /// reaches `.manual` without touching the persisted config, so a running experiment can still
    /// be live on disk while `step == .manual`. Gates `openPropose()` below — starting a new draft
    /// from there would eventually reach `persistDraft`, which always replaces the *entire*
    /// `experiments.active` array, silently ending the live test (losing its `"running"` status
    /// and `startedAt`) with no warning. That violates both this schema's "only one active
    /// experiment at a time" invariant (`DomainConfig.Experiments.active`'s doc comment) and this
    /// codebase's "the app advises, it never surprises the owner" principle (#1518 review,
    /// escape-hatch fix).
    var runningExperiment: DomainConfig.Experiments.Experiment? {
        guard let config = try? DomainConfigStore(sourceDirectory: sourceDirectory).load(),
              let active = config.experiments?.active?.first, active.status == "running" else {
            return nil
        }
        return active
    }

    /// Advances from `.manual` to the suggestion-browsing step. A no-op from any other step, and
    /// also a no-op while a running experiment is declared on disk — reachable via
    /// `returnToManual()` while one is live (see `runningExperiment`). The manual-entry form
    /// itself stays reachable either way; only starting a *new* draft is refused.
    func openPropose() {
        guard case .manual = step, runningExperiment == nil else { return }
        step = .propose
    }

    /// Seeds a `Draft` from a playbook suggestion's title and moves to `.configure`.
    func propose(from suggestion: ExperimentStats.Suggestion) {
        proposeCustom(name: suggestion.title)
    }

    /// Seeds a `Draft` from an owner-typed name (slugified into the experiment id) and moves to
    /// `.configure`. `page` defaults to the route the sheet was opened from — normalized to the
    /// served, trailing-slash form (`ContentScaffold.servedRoute`), since `currentRoute` comes from
    /// `PreviewModel.activeRoute`/`ContentScanner.routeFromPagePath`, which produce the slash-less
    /// file-path shape that `pre-deploy-check.ts` rejects for `experiments.active[].page` (#1518).
    func proposeCustom(name: String) {
        let slug = ContentScaffold.slugify(name)
        step = .configure(Draft(
            id: slug, name: name, page: ContentScaffold.servedRoute(currentRoute),
            variantName: "\(name) — variant"))
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

    /// Duplicates the control page under `/x/<experimentID>/<variantID>/` via
    /// `NativeContentOperations.duplicatePageAsVariant`, then records the built route on the
    /// draft and persists it. A no-op outside `.configure` or once a variant is already scaffolded
    /// (re-running would collide with the existing variant file).
    ///
    /// A failure is surfaced through `scaffoldFailureReason` rather than swallowed: the underlying
    /// operation's `.failed` reasons ("No page exists at …", "A variant page already exists at …",
    /// "Couldn't find a <BaseLayout> invocation …") are each something the owner can act on, and a
    /// button that visibly does nothing is not (#1518 review, I3).
    func scaffoldVariant() async {
        guard case .configure(var draft) = step, draft.variantPage == nil else { return }
        // `draft.page` is a served route (trailing slash); the control's `.astro` is at the
        // file-path form of it — `/` → `src/pages/index.astro`, `/pricing/` → `src/pages/pricing.astro`.
        let controlRelPath = ContentScaffold.pageRelativePath(servedRoute: draft.page)
        let result = await contentOps.duplicatePageAsVariant(
            siteID: siteID, relativePath: controlRelPath, experimentID: draft.id, variantID: draft.variantID)
        switch result {
        case .created(_, let route):
            scaffoldFailureReason = nil
            draft.variantPage = route
            step = .configure(draft)
            persistDraft(draft)
        case .failed(let reason):
            scaffoldFailureReason = reason
        case .siteNotFound:
            scaffoldFailureReason = "Couldn't find this site's files on disk."
        }
    }

    /// Why the last "Create the variant page" attempt didn't produce a variant — `nil` when none
    /// has failed since the last success. Surfaced by `ExperimentConfigureView` beside the button.
    private(set) var scaffoldFailureReason: String?

    /// Sets a pageview goal (reaching `path` counts as a conversion) and persists the draft.
    ///
    /// `path` is normalized to the served, trailing-slash form for the same reason `page` and
    /// `variant.page` are: `pre-deploy-check.ts` validates a `pageview` goal path with
    /// `requireTrailingSlash`, and the edge worker's `matchesGoal` compares it against the
    /// canonicalized request path with `===`.
    func setPageviewGoal(path: String) {
        let normalized = ContentScaffold.servedRoute(path)
        updateDraftGoal { $0.goalKind = "pageview"; $0.goalPath = normalized; $0.goalDepth = nil; $0.goalSelector = nil }
    }

    /// Sets a scroll-depth goal (`depth` percent of the page scrolled) and persists the draft.
    func setScrollGoal(depth: Int) {
        updateDraftGoal { $0.goalKind = "scroll"; $0.goalDepth = depth; $0.goalPath = nil; $0.goalSelector = nil }
    }

    /// Call after `goalPickController.state` reaches `.succeeded(selector:)` — the sheet view's
    /// `.onChange(of: goalPickController.state)` is the caller.
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

    /// Gates the start action: both the variant page and a goal must be set.
    var canStart: Bool {
        guard case .configure(let draft) = step else { return false }
        return draft.asExperiment != nil
    }

    /// Flips the draft's status to `running`, persists it, and invokes `deploy` — a closure rather
    /// than a direct `DeployModel` dependency so this model stays testable without constructing one
    /// (`DeployModel` pulls in token/license/container machinery none of this model's own logic
    /// needs). The view's own `.onChange(of: deployModel.phase)` then calls `observeDeployPhase(_:)`
    /// below.
    ///
    /// `deploy` takes **no arguments** on purpose (#1518 review, C2). An earlier shape handed it
    /// the site id, directories, and routes, which invited the call site to reconstruct arguments
    /// only `SiteWindowModel.deploySite()` knows how to build correctly — and it got them wrong:
    /// `Source/` passed as the config directory (app-owned state must never live in the git repo),
    /// and a two-element `currentRoutes` that would have overwritten the site's whole
    /// `DeployedRoutesSnapshot` with just the experiment's two pages. The closure now simply calls
    /// `SiteWindowModel.deploySite()`, the one production deploy path.
    ///
    /// - Parameter unavailableReason: Non-`nil` when `deploy` would *not* actually run a deploy to
    ///   completion right now (no Cloudflare sign-in yet, no license choice yet, another publish in
    ///   flight) — see `DeployModel.deployUnavailableReason(siteDirectory:)`. In that case nothing
    ///   is written to `anglesite.json` and the step stays on `.configure`, because `deploy(...)`
    ///   silently parks in those cases and `.starting` would never be left (#1518 review, I5).
    func start(unavailableReason: String? = nil, deploy: () -> Void) {
        guard case .configure(let draft) = step, var experiment = draft.asExperiment else { return }
        if let unavailableReason {
            startFailureReason = unavailableReason
            return
        }
        startFailureReason = nil
        experiment.status = "running"
        experiment.startedAt = ISO8601DateFormatter().string(from: Date()).prefix(10).description
        DomainConfigStore.update(sourceDirectory: sourceDirectory) { $0.experiments = .init(active: [experiment]) }
        step = .starting
        deploy()
    }

    /// Whether the "Analyze manually" escape hatch applies (#1518 review, I6). Excluded from
    /// `.starting`: a deploy is in flight there and `observeDeployPhase(_:)` still needs the step
    /// to come back to it. Also excluded while `isConcluding`, for the same reason: `confirmConclude()`
    /// still needs `step` to be `.running` when its async work finishes.
    var canReturnToManual: Bool {
        guard !isConcluding else { return false }
        switch step {
        case .manual, .starting: return false
        case .propose, .configure, .running: return true
        }
    }

    /// Returns to the `.manual` analysis form. Purely a UI move — it neither reverts nor deletes
    /// whatever `anglesite.json` already records, so re-opening the sheet lands back on the
    /// lifecycle step the config implies.
    func returnToManual() {
        guard canReturnToManual else { return }
        step = .manual
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
        case .workerNameConflict, .webmentionPaidPlanConfirmationNeeded, .domainConfigDrift:
            // These three park the deploy on a confirmation sheet of `DeployModel`'s own — which
            // cannot present while this sheet occupies the window's modal slot. Treated as a failed
            // start (config rolled back to `"draft"`, so the parked deploy can't publish a test the
            // owner never confirmed) rather than ignored: ignoring them would strand `.starting`
            // forever, and Done is disabled during `.starting` to keep this observation alive
            // (#1518 review, I4).
            revertToConfigureAfterFailedStart(
                reason: "Publishing paused and needs an answer from you. Close this and choose Publish to finish, then start your test.")
        case .idle, .running:
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

    // MARK: - Conclude (#1270 slice 6)

    /// The conclude action awaiting owner confirmation, or `nil` when none is pending — drives
    /// `ExperimentRunningStatusView`'s `.confirmationDialog`, same optional-state-driven shape as
    /// `SiteWindowModel.deleteConfirmation`.
    var pendingConclude: ExperimentHistoryStore.Outcome.Decision?

    /// Set while `confirmConclude()`'s async work is in flight — gates the sheet's Done button and
    /// `canReturnToManual`, same reasoning as `.starting`: dismissing or navigating away mid-conclude
    /// would leave the operation racing the view that started it.
    private(set) var isConcluding = false

    /// Why the last conclude attempt failed — `nil` when none has failed since the last success.
    /// Surfaced by `ExperimentRunningStatusView` beside the conclude buttons, same idiom as
    /// `scaffoldFailureReason`/`startFailureReason`.
    private(set) var concludeFailureReason: String?

    /// Arms `pendingConclude`, which the view's confirmation dialog reads. A no-op outside
    /// `.running` or while a previous conclude is still in flight.
    func requestConclude(_ decision: ExperimentHistoryStore.Outcome.Decision) {
        guard case .running = step, !isConcluding else { return }
        pendingConclude = decision
    }

    /// Dismisses the pending confirmation dialog without acting.
    func cancelConclude() {
        pendingConclude = nil
    }

    /// Carries out the confirmed conclude decision (#1270 slice 6, design doc §5): promotes the
    /// variant into the control page (`.promote`) or simply removes it (`.keep`/`.discard` — the
    /// same file operation, per the design doc, differing only in what gets recorded), drops the
    /// experiment from `anglesite.json`, appends an outcome to `Config/experiment-history.json`,
    /// returns to `.manual`, and publishes.
    ///
    /// Unlike `start(unavailableReason:deploy:)`, there is no deploy-phase rollback here: the git
    /// content change (if any) and the config/history updates are valid the moment they land,
    /// regardless of whether the subsequent publish succeeds — a concluded experiment that hasn't
    /// published yet is simply "concluded, not yet live," not a false claim the way a `"running"`
    /// status with no successful deploy would be. `deploy` is therefore called unconditionally and
    /// fire-and-forget, same as every other content edit in this app that doesn't gate on deploy
    /// availability; the site window's own deploy-status UI covers publish progress from here.
    func confirmConclude(deploy: () -> Void) async {
        guard case .running(let experiment) = step, let decision = pendingConclude else { return }
        pendingConclude = nil
        isConcluding = true
        defer { isConcluding = false }
        concludeFailureReason = nil

        let succeeded: Bool
        switch decision {
        case .promote:
            switch await contentOps.promoteVariant(siteID: siteID, experiment: experiment) {
            case .created: succeeded = true
            case .failed(let reason): concludeFailureReason = reason; succeeded = false
            case .siteNotFound: concludeFailureReason = "Couldn't find this site's files on disk."; succeeded = false
            }
        case .keep, .discard:
            switch await contentOps.discardVariant(siteID: siteID, experiment: experiment) {
            case .deleted: succeeded = true
            case .failed(let reason): concludeFailureReason = reason; succeeded = false
            case .siteNotFound: concludeFailureReason = "Couldn't find this site's files on disk."; succeeded = false
            }
        }
        guard succeeded else { return }

        DomainConfigStore.update(sourceDirectory: sourceDirectory) { $0.experiments = .init(active: []) }
        let outcome = ExperimentHistoryStore.Outcome(
            experimentID: experiment.id, name: experiment.name, decision: decision,
            variantName: experiment.variant.name,
            controlVisitors: controlImpressions, controlConversions: controlConversions,
            variantVisitors: treatmentImpressions, variantConversions: treatmentConversions,
            startedAt: experiment.startedAt,
            concludedAt: ISO8601DateFormatter().string(from: Date()).prefix(10).description)
        await ExperimentHistoryStore(configDirectory: configDirectory).append(outcome)

        step = .manual
        deploy()
    }
}

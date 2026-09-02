import AppIntents
import AnglesiteCore
import Foundation

/// Siri/Shortcuts front-door for `ExperimentStats` (#769, live zero-argument path #1270 §4/§10
/// slice 4) — "How is my test going?". Two paths, same underlying analysis: give it counts and
/// it compares them (the original #769 shape, still exactly as before); give it nothing and it
/// resolves the one site (of everything the app knows about) with a running experiment and
/// analyzes its live D1 counts via `ExperimentResultsService`, falling back to "no running
/// experiment" rather than prompting for parameters Siri has no way to fill in for you. Like the
/// Experiment Results sheet (`ExperimentStatsSheetView`/`ExperimentStatsModel`), the manual path
/// remains available for a non-Cloudflare deploy or a site with no token configured.
///
/// Not registered in AnglesiteShortcuts: same phrase-budget reasoning as `ReviewCopyIntent` (the
/// 10-phrase cap is already spent) — stays discoverable via the Shortcuts app.
public struct AnalyzeExperimentIntent: AppIntent {
    /// Action name in the Shortcuts library.
    public static let title: LocalizedStringResource = "Analyze Experiment"
    /// Shortcuts-editor blurb.
    public static let description = IntentDescription(
        "Compare two variants' visitor and conversion counts and report whether either is winning, or ask about your currently running test with no parameters at all.")

    /// Optional label for the dialog, e.g. "Hero headline test". Purely cosmetic.
    @Parameter(title: "Experiment Name", default: "")
    public var experimentName: String
    @Parameter(title: "Original Name", default: "Original")
    public var controlName: String
    /// Optional (unlike #769's original required parameters): leaving both impression counts
    /// unset is what selects the zero-argument live-lookup path in `run(service:)`.
    @Parameter(title: "Original Visitors") public var controlImpressions: Int?
    @Parameter(title: "Original Conversions") public var controlConversions: Int?
    @Parameter(title: "Variant Name", default: "Variant")
    public var treatmentName: String
    @Parameter(title: "Variant Visitors") public var treatmentImpressions: Int?
    @Parameter(title: "Variant Conversions") public var treatmentConversions: Int?

    /// Required by the AppIntents runtime; parameters are populated after init.
    public init() {}

    /// Shortcuts-editor sentence: "Analyze (name) with (control) vs (variant)".
    public static var parameterSummary: some ParameterSummary {
        Summary("Analyze \(\.$experimentName)") {
            \.$controlName
            \.$controlImpressions
            \.$controlConversions
            \.$treatmentName
            \.$treatmentImpressions
            \.$treatmentConversions
        }
    }

    /// No side effects and nothing to confirm — reads no state, writes nothing. `LiveExperimentResultsService`
    /// needs no runtime configuration (it resolves the token/account/D1 database itself per
    /// site), so it's constructed directly rather than through `@Dependency`.
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await run(service: LiveExperimentResultsService())))
    }

    private func run(service: any ExperimentResultsService) async -> String {
        let name: String
        let control: ExperimentStats.Variant
        let treatment: ExperimentStats.Variant
        switch (controlImpressions, treatmentImpressions) {
        case (nil, nil):
            guard let prefill = await service.prefillForRunningExperiment() else {
                if let outcome = await service.mostRecentConcludedOutcome() {
                    return "I don't see a running experiment right now. Your last test, "
                        + "\(outcome.name), wrapped up on \(outcome.concludedAt) — you "
                        + "\(Self.phrase(outcome.decision)). Start a new one, or tell me the counts yourself."
                }
                return "I don't see a running experiment on any of your sites right now — "
                    + "start one, or tell me the counts yourself."
            }
            name = prefill.experiment.name
            control = ExperimentStats.Variant(
                name: "Original", impressions: prefill.counts.controlVisitors,
                conversions: prefill.counts.controlConversions)
            treatment = ExperimentStats.Variant(
                name: prefill.experiment.variant.name, impressions: prefill.counts.variantVisitors,
                conversions: prefill.counts.variantConversions)
        case let (.some(controlVisitors), .some(treatmentVisitors)):
            name = experimentName.isEmpty ? "This experiment" : experimentName
            control = ExperimentStats.Variant(
                name: controlName.isEmpty ? "Original" : controlName,
                impressions: controlVisitors, conversions: controlConversions ?? 0)
            treatment = ExperimentStats.Variant(
                name: treatmentName.isEmpty ? "Variant" : treatmentName,
                impressions: treatmentVisitors, conversions: treatmentConversions ?? 0)
        default:
            // Exactly one side's visitor count was supplied — too little for a manual comparison
            // (silently treating the missing side as zero would produce a meaningless result) and
            // too much to say nothing was provided, so this doesn't qualify for the zero-argument
            // live-lookup path either. Ask for the rest rather than guessing.
            return "I need both variants' visitor counts to compare them — tell me the original's "
                + "and the variant's visitors, or leave both blank and I'll check your running test."
        }

        let result = ExperimentStats.analyze(control: control, treatment: treatment)
        var reply = ExperimentStats.formatSummary(experimentName: name, result: result)
        if !ExperimentStats.hasSufficientData(control: control, treatment: treatment) {
            reply += "\nNot much traffic yet — the usual rule of thumb is 30+ days or 500+ visitors per variant."
        }
        if ExperimentStats.hasSampleRatioMismatch(control: control, treatment: treatment) {
            reply += "\nThe traffic split looks off from what you'd expect — check your test setup."
        }
        return reply
    }

    /// Phrases a concluded experiment's decision for the zero-argument fallback (#1270 slice 6).
    private static func phrase(_ decision: ExperimentHistoryStore.Outcome.Decision) -> String {
        switch decision {
        case .promote: return "promoted the variant"
        case .keep: return "kept the original"
        case .discard: return "ended it early"
        }
    }
}

// MARK: - Test-only helpers

extension AnalyzeExperimentIntent {
    /// Drives `perform`'s dialog logic directly, bypassing the AppIntents runtime — see
    /// `ReviewCopyIntent.performForTesting()`. `service` defaults to a stub that's never consulted
    /// by the manual (count-parameter) path; zero-argument-path tests pass a fake explicitly.
    func performForTesting(service: any ExperimentResultsService = UnreachableExperimentResultsService()) async -> String {
        await run(service: service)
    }
}

/// Test-only default for ``AnalyzeExperimentIntent/performForTesting(service:)`` — traps if the
/// manual-path assumption is ever wrong, i.e. a test exercises the zero-argument path without
/// passing its own fake.
struct UnreachableExperimentResultsService: ExperimentResultsService {
    func prefillForRunningExperiment() async -> ExperimentResultsSync.Prefill? {
        fatalError("UnreachableExperimentResultsService was called — pass a real fake service for this test case")
    }

    func mostRecentConcludedOutcome() async -> ExperimentHistoryStore.Outcome? {
        fatalError("UnreachableExperimentResultsService was called — pass a real fake service for this test case")
    }
}

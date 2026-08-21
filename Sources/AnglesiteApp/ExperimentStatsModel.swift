import Foundation
import Observation
import AnglesiteCore

/// Drives the Experiment Results sheet (#769, live prefill #1270 §4/§10 slice 4): a manual-entry
/// front door onto `ExperimentStats` that now prefills itself from `ExperimentResultsSync` when
/// the site has a running experiment, a provisioned D1 database, and a Cloudflare token — the
/// #769 manual-entry behavior (typing in counts read off whatever analytics the owner already has)
/// is the unconditional fallback whenever any of those isn't true, so nothing about #769 is
/// removed. Fresh-per-open, same lifecycle as `CopyEditReportModel`.
@Observable @MainActor
final class ExperimentStatsModel: Identifiable {
    let id = UUID()
    let siteID: String
    private let sourceDirectory: URL
    private let configDirectory: URL

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

    init(siteID: String, sourceDirectory: URL, configDirectory: URL) {
        self.siteID = siteID
        self.sourceDirectory = sourceDirectory
        self.configDirectory = configDirectory
    }

    /// Fetches live counts for the site's running experiment and prefills the form, if available.
    /// A no-op (fields stay owner-editable, empty/zeroed as usual) when there's no running
    /// experiment, no provisioned D1 database, or no Cloudflare token — the manual-entry path is
    /// unaffected either way. Called once, right after presentation (see `SiteWindowModel
    /// .presentExperimentStats()`), same fire-and-forget shape as other async-prefill models.
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

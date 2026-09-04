import Foundation

/// Site-portfolio-scoped front door onto ``ExperimentResultsSync`` for callers with no specific
/// site in hand — today, only `AnalyzeExperimentIntent`'s zero-argument path (#1270 §4/§10 slice
/// 4). `ExperimentStatsModel` doesn't need this: it already has the open site's directories and
/// calls ``ExperimentResultsSync/prefill(sourceDirectory:configDirectory:secretStore:baseURL:transport:)``
/// directly. Protocol-shaped (rather than a bare static function) so `AnglesiteIntents` can inject
/// a fake via `@Dependency`/`ExperimentResultsOverride`, matching `DomainOperationsService`'s
/// pattern.
public protocol ExperimentResultsService: Sendable {
    /// Finds the one site (among every site the app knows about) with a running experiment and
    /// returns its live counts, or `nil` when no site has one running, its D1 database isn't
    /// provisioned, or there's no Cloudflare token available.
    func prefillForRunningExperiment() async -> ExperimentResultsSync.Prefill?

    /// The most recently concluded experiment across every site the app knows about (#1270 slice
    /// 6), or `nil` when no site has ever concluded one. Backs `AnalyzeExperimentIntent`'s
    /// zero-argument fallback once there's no running experiment to report on.
    func mostRecentConcludedOutcome() async -> ExperimentHistoryStore.Outcome?
}

/// Production conformance: reads every site `SiteStore` knows about, MRU-first.
public struct LiveExperimentResultsService: ExperimentResultsService {
    public init() {}

    public func prefillForRunningExperiment() async -> ExperimentResultsSync.Prefill? {
        let sites = await SiteStore.shared.sites
        return await ExperimentResultsSync.prefillForRunningExperiment(
            sites: sites.map { (sourceDirectory: $0.sourceDirectory, configDirectory: $0.configDirectory) })
    }

    public func mostRecentConcludedOutcome() async -> ExperimentHistoryStore.Outcome? {
        let sites = await SiteStore.shared.sites
        var mostRecent: ExperimentHistoryStore.Outcome?
        for site in sites {
            let outcomes = await ExperimentHistoryStore(configDirectory: site.configDirectory).load()
            guard let latest = outcomes.last else { continue }
            if mostRecent == nil || latest.concludedAt > mostRecent!.concludedAt {
                mostRecent = latest
            }
        }
        return mostRecent
    }
}

import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Resolves a site's running experiment and its live D1 counts (#1270 design doc §4/§10 slice 4)
/// — the "app-side read path" the design doc describes: `ExperimentEventsD1Client` mirrors
/// `WebmentionInboxD1Client`, and this type mirrors `ReceivedInteractionSync`'s
/// `pullAndCommitIfConfigured` shape (read `SiteSettings`/`DomainConfig`, resolve the token,
/// resolve the account id, query). Every failure mode — no running experiment, no provisioned D1
/// database, no Cloudflare token, a network/decode failure — resolves to `nil` rather than
/// throwing, because the #769 manual-entry form is the unconditional fallback for all of them;
/// callers never need to distinguish *why* live data wasn't available.
public enum ExperimentResultsSync {
    /// Live counts for one site's running experiment, paired with the experiment's declared
    /// metadata (name, variant name) so callers can build ``ExperimentStats/Variant`` values
    /// without a second read of `anglesite.json`.
    public struct Prefill: Sendable, Equatable {
        public let experiment: DomainConfig.Experiments.Experiment
        public let counts: ExperimentEventsD1Client.Counts

        public init(experiment: DomainConfig.Experiments.Experiment, counts: ExperimentEventsD1Client.Counts) {
            self.experiment = experiment
            self.counts = counts
        }
    }

    /// Reads `sourceDirectory`'s declared `anglesite.json` and returns its one running experiment,
    /// if any — schema/the pre-deploy gate enforce at most one (§6). Local file I/O only, no
    /// network, so callers can use this to cheaply filter a list of sites before ever resolving a
    /// token or making an HTTP call.
    public static func runningExperiment(sourceDirectory: URL) -> DomainConfig.Experiments.Experiment? {
        guard let config = try? DomainConfigStore(sourceDirectory: sourceDirectory).load() else { return nil }
        return config.experiments?.active?.first { $0.status == "running" }
    }

    /// Live counts for `sourceDirectory`/`configDirectory`'s running experiment. `nil` when there
    /// is no running experiment, no provisioned D1 database (`SiteSettings
    /// .provisionedWorkerResources.d1DatabaseID`, set once `SocialWorkerProvisionCommand` has
    /// provisioned the site's Worker), no Cloudflare token, or the D1 query itself failed.
    public static func prefill(
        sourceDirectory: URL,
        configDirectory: URL,
        secretStore: any SecretStore = PlatformSecretStore.make(),
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) async -> Prefill? {
        guard let experiment = runningExperiment(sourceDirectory: sourceDirectory) else { return nil }
        guard let settings = try? SiteConfigStore.read(from: configDirectory),
              let databaseID = settings.provisionedWorkerResources?.d1DatabaseID, !databaseID.isEmpty
        else { return nil }
        guard let token = try? await CloudflareAPICredentials.resolve(secretStore: secretStore), !token.isEmpty
        else { return nil }
        guard let accountID = await Self.resolveAccountID(apiToken: token, baseURL: baseURL, transport: transport)
        else { return nil }

        let client = ExperimentEventsD1Client(
            accountID: accountID, databaseID: databaseID, apiToken: token, baseURL: baseURL, transport: transport)
        guard let counts = try? await client.counts(experimentID: experiment.id, variantID: experiment.variant.id)
        else { return nil }
        return Prefill(experiment: experiment, counts: counts)
    }

    /// Zero-argument entry point for `AnalyzeExperimentIntent`'s "How is my test going?" path
    /// (§4's "App-side read path" / §10 slice 4): scans every known site's declared config for the
    /// one with a running experiment (cheap, local-only via ``runningExperiment(sourceDirectory:)``,
    /// so a portfolio with nothing running costs no network calls) and fetches its live counts.
    /// Sites are checked in the order given — pass `SiteStore.shared.sites` (already MRU-ordered)
    /// so a tie between two running experiments (shouldn't happen — one running experiment is a
    /// per-site invariant, not a cross-site one, but nothing stops two different sites each
    /// running one) favors the most recently used site.
    public static func prefillForRunningExperiment(
        sites: [(sourceDirectory: URL, configDirectory: URL)],
        secretStore: any SecretStore = PlatformSecretStore.make(),
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) async -> Prefill? {
        for site in sites where runningExperiment(sourceDirectory: site.sourceDirectory) != nil {
            if let prefill = await prefill(
                sourceDirectory: site.sourceDirectory, configDirectory: site.configDirectory,
                secretStore: secretStore, baseURL: baseURL, transport: transport)
            {
                return prefill
            }
        }
        return nil
    }

    // MARK: - Account id resolution

    private struct CFAccount: Decodable, Sendable { let id: String }
    private struct CFEnvelope: Decodable, Sendable { let success: Bool; let result: [CFAccount]? }

    /// Resolves the token's first visible Cloudflare account id — same "just take the first
    /// account" resolution `ReceivedInteractionSync`/`MicropubContentSync` use, duplicated locally
    /// rather than shared (matching those two's own precedent: `SocialWorkerProvisionCommand`'s
    /// doc comment notes these are deliberately separate `private` helpers, not one shared utility).
    private static func resolveAccountID(apiToken: String, baseURL: String, transport: CloudflareTransport) async -> String? {
        guard let url = URL(string: "\(baseURL)/accounts?per_page=1") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        guard let (data, http) = try? await transport(request), (200..<300).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(CFEnvelope.self, from: data), envelope.success
        else { return nil }
        return envelope.result?.first?.id
    }
}

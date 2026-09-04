import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cloudflare D1 HTTP API client for the edge A/B testing pipeline's `experiment_counters` table
/// (#1270 design doc §4/§10 slice 4). The per-site Worker (`Resources/Template/worker/experiments.ts`)
/// writes one aggregate row per `(experiment_id, variant_id, metric, day)` into the shared
/// `{siteName}-social` D1 database (`worker/migrations/0002_experiments.sql`) via
/// `ON CONFLICT ... DO UPDATE SET n = n + 1`. This is the app-side reader — same injectable-transport
/// DI pattern as `WebmentionInboxD1Client`, no Keychain coupling, token passed in at init.
///
/// `variant_id` is always literally `"control"` for the control arm and the declared experiment's
/// `variant.id` for the treatment arm (`assignVariant`/`applyGoalConversion` in `experiments.ts`);
/// `metric` is `"impression"` or `"conversion"`. This client sums across every `day` bucket — the
/// app's front doors (the Experiment Results sheet, `AnalyzeExperimentIntent`) want the running
/// total, not a daily breakdown.
public struct ExperimentEventsD1Client: Sendable {
    /// Summed visitor/conversion counts for both arms of one experiment.
    public struct Counts: Sendable, Equatable {
        public let controlVisitors: Int
        public let controlConversions: Int
        public let variantVisitors: Int
        public let variantConversions: Int

        public init(controlVisitors: Int, controlConversions: Int, variantVisitors: Int, variantConversions: Int) {
            self.controlVisitors = controlVisitors
            self.controlConversions = controlConversions
            self.variantVisitors = variantVisitors
            self.variantConversions = variantConversions
        }

        /// The observed control share of total visitors — the SRM-adjacent number the app-side
        /// callers can compare against the declared `split`. Defaults to `0.5` (assume on-target)
        /// when there's no traffic yet, rather than dividing by zero.
        public var observedControlSplit: Double {
            let total = controlVisitors + variantVisitors
            guard total > 0 else { return 0.5 }
            return Double(controlVisitors) / Double(total)
        }
    }

    private struct Row: Decodable {
        let variant_id: String
        let metric: String
        let total: Int
    }

    private struct QueryResult: Decodable {
        let results: [Row]?
        let success: Bool
    }

    private struct Envelope: Decodable {
        let success: Bool
        let result: [QueryResult]?
    }

    private struct QueryBody: Encodable {
        let sql: String
        let params: [String]
    }

    /// Sums `n` across every day bucket, grouped by arm and metric — the running total this
    /// client hands back, not a time series.
    private static let countsSQL = """
    SELECT variant_id, metric, SUM(n) as total FROM experiment_counters \
    WHERE experiment_id = ? GROUP BY variant_id, metric
    """

    private let baseURL: String
    private let accountID: String
    private let databaseID: String
    private let apiToken: String
    private let transport: CloudflareTransport

    /// Creates a client for one site's experiments database. The token is passed in directly (no
    /// Keychain coupling — the caller owns credential resolution); `baseURL` and `transport` are
    /// injectable so tests can point at a stub instead of the live Cloudflare API.
    public init(
        accountID: String,
        databaseID: String,
        apiToken: String,
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) {
        self.accountID = accountID
        self.databaseID = databaseID
        self.apiToken = apiToken
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Sums `experimentID`'s counters into per-arm visitor/conversion totals. `variantID` is the
    /// declared experiment's `variant.id` (`DomainConfig.Experiments.Experiment.Variant.id`) —
    /// the control arm's key is always the literal `"control"`, never a stored id. Rows for any
    /// other `variant_id` (e.g. left behind by a since-concluded experiment that reused the id
    /// namespace) are ignored rather than misattributed. An experiment with no traffic yet — an
    /// empty result set — returns all-zero counts rather than throwing.
    public func counts(experimentID: String, variantID: String) async throws -> Counts {
        let url = URL(string: "\(baseURL)/accounts/\(accountID)/d1/database/\(databaseID)/query")
        guard let url else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(QueryBody(sql: Self.countsSQL, params: [experimentID]))

        let (data, http) = try await transport(request)
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.success,
              let rows = envelope.result?.first?.results
        else { throw CloudflareError.malformedResponse }

        var controlVisitors = 0, controlConversions = 0, variantVisitors = 0, variantConversions = 0
        for row in rows {
            if row.variant_id == "control" {
                if row.metric == "impression" { controlVisitors = row.total }
                else if row.metric == "conversion" { controlConversions = row.total }
            } else if row.variant_id == variantID {
                if row.metric == "impression" { variantVisitors = row.total }
                else if row.metric == "conversion" { variantConversions = row.total }
            }
        }
        return Counts(
            controlVisitors: controlVisitors, controlConversions: controlConversions,
            variantVisitors: variantVisitors, variantConversions: variantConversions)
    }
}

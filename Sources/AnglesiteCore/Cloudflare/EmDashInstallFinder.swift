import Foundation
// URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin platforms
// (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An EmDash install found in the owner's Cloudflare account, which Anglesite can take over
/// (#2106, decision 7 "Bring your own" in
/// `docs/specs/2026-09-28-external-cms-content-source-decision.md`).
///
/// Anglesite publishes to the install's own Worker, so its secrets (including
/// `EMDASH_ENCRYPTION_KEY`), custom domains and routes stay as they are, and binds the same
/// database and media bucket, so its content, users and roles stay too.
public struct EmDashInstall: Sendable, Equatable, Identifiable {
    /// Why an install can't be connected, in owner terms the app words.
    public enum Problem: Sendable, Equatable {
        /// The Worker has no media bucket, or several, none of them named `MEDIA`, so it isn't
        /// clear which holds the install's media.
        case mediaBucketUnclear
    }

    /// The Worker that serves the install; Anglesite publishes to it under the same name.
    public let workerName: String
    public let databaseName: String
    public let databaseID: String
    public let mediaBucketName: String?
    /// The install's session store, if it has one bound as `SESSION`; otherwise Anglesite makes one.
    public let sessionKVNamespaceID: String?
    /// The Worker has a `LOADER` Worker Loader binding, so its marketplace plugins run sandboxed
    /// and keep working after the takeover.
    public let hasWorkerLoader: Bool
    /// Plugins installed from EmDash's marketplace. Kept when the Worker has a Worker Loader.
    public let marketplacePlugins: [String]
    /// Plugins written into the install's own code. Anglesite replaces that code with its own
    /// theme, so these stop; the app names them before the owner confirms.
    public let codePlugins: [String]
    public let problem: Problem?

    public var id: String { workerName }

    public init(
        workerName: String, databaseName: String, databaseID: String, mediaBucketName: String?,
        sessionKVNamespaceID: String?, hasWorkerLoader: Bool,
        marketplacePlugins: [String], codePlugins: [String], problem: Problem?
    ) {
        self.workerName = workerName
        self.databaseName = databaseName
        self.databaseID = databaseID
        self.mediaBucketName = mediaBucketName
        self.sessionKVNamespaceID = sessionKVNamespaceID
        self.hasWorkerLoader = hasWorkerLoader
        self.marketplacePlugins = marketplacePlugins
        self.codePlugins = codePlugins
        self.problem = problem
    }

    /// Marketplace plugins that stop because the Worker has no Worker Loader to run them in.
    public var stoppedMarketplacePlugins: [String] { hasWorkerLoader ? [] : marketplacePlugins }

    /// Every plugin that stops working when Anglesite takes over: those written into the
    /// install's own code, and marketplace plugins with no Worker Loader to run in. What the
    /// pre-connect notice names.
    public var pluginsThatStop: [String] { (codePlugins + stoppedMarketplacePlugins).sorted() }

    /// The resources `EmDashDeployTarget` binds the Worker to; it creates only the session store
    /// if the install has none.
    public var resources: EmDashWorkerConfig.Resources {
        EmDashWorkerConfig.Resources(
            d1DatabaseName: databaseName, d1DatabaseID: databaseID, mediaBucketName: mediaBucketName,
            sessionKVNamespaceID: sessionKVNamespaceID, workerLoader: hasWorkerLoader ? true : nil)
    }
}

/// Finds the EmDash installs in a Cloudflare account (#2106) over the REST API: every Worker,
/// its bindings (`workers/scripts/{name}/settings`), and, for each D1 database it's bound to,
/// whether that database holds EmDash's schema. Same injectable-transport pattern as
/// ``WithheldPagesD1Client``.
public struct EmDashInstallFinder: Sendable {
    /// A table every EmDash database has, from its first migration.
    static let schemaMarkerTable = "_emdash_collections"
    /// EmDash's plugin registry: `plugin_id`, and `source` (`config` or `marketplace`).
    static let pluginTable = "_plugin_state"
    /// The publish gate Anglesite registers itself; never listed as one of the install's plugins.
    static let anglesiteGatePluginID = "anglesite-gate"

    /// One binding from a Worker's settings, as the API reports it.
    struct Binding: Decodable, Equatable {
        let type: String
        let name: String
        let id: String?
        let bucket_name: String?
        let namespace_id: String?
    }

    private let baseURL: String
    private let accountID: String
    private let apiToken: String
    private let transport: CloudflareTransport

    public init(
        accountID: String,
        apiToken: String,
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) {
        self.accountID = accountID
        self.apiToken = apiToken
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Why the search as a whole can't go on, as opposed to one Worker that can't be read.
    public enum FindError: Error, Equatable {
        /// The token can list Workers but can't read D1 databases, so no install can be
        /// recognised. Distinct from a refused token (`CloudflareError.unauthorized`): the token
        /// works, it's missing a permission.
        case cannotReadDatabases
    }

    /// How many Workers are examined at once: enough that a large account doesn't make the
    /// owner wait on one request at a time, few enough to stay polite to the API.
    static let concurrency = 4

    /// Every EmDash install in the account, by Worker name. A Worker whose settings or databases
    /// can't be read is left out rather than failing the search. A refused token throws
    /// `CloudflareError.unauthorized`, a token without D1 access throws
    /// ``FindError/cannotReadDatabases``, and cancelling the search stops it.
    public func installs() async throws -> [EmDashInstall] {
        let names = try await workerNames()
        var found: [EmDashInstall] = []
        try await withThrowingTaskGroup(of: EmDashInstall?.self) { group in
            var next = names.makeIterator()
            func addNext() {
                guard let name = next.next() else { return }
                group.addTask { try await self.installIfReadable(workerName: name) }
            }
            for _ in 0..<Self.concurrency { addNext() }
            while let result = try await group.next() {
                if let result { found.append(result) }
                addNext()
            }
        }
        return found.sorted { $0.workerName < $1.workerName }
    }

    /// ``install(workerName:)``, with a Worker that can't be read reported as no install. Only
    /// what ends the whole search is rethrown.
    private func installIfReadable(workerName: String) async throws -> EmDashInstall? {
        do {
            return try await install(workerName: workerName)
        } catch is CancellationError {
            throw CancellationError()
        } catch CloudflareError.unauthorized {
            throw CloudflareError.unauthorized
        } catch FindError.cannotReadDatabases {
            throw FindError.cannotReadDatabases
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    /// The install the Worker `workerName` serves, or `nil` when it isn't bound to an EmDash database.
    func install(workerName: String) async throws -> EmDashInstall? {
        let bindings = try await bindings(workerName: workerName)
        for database in bindings where database.type == "d1" {
            guard let databaseID = database.id, EmDashWorkerConfig.isPlainIdentifier(databaseID),
                  try await holdsEmDashSchema(databaseID: databaseID)
            else { continue }
            let plugins = try await plugins(databaseID: databaseID)
            let buckets = bindings.filter { $0.type == "r2_bucket" && $0.bucket_name != nil }
            let media = buckets.first { $0.name == EmDashWorkerConfig.mediaBinding } ?? (buckets.count == 1 ? buckets[0] : nil)
            let session = bindings.first { $0.type == "kv_namespace" && $0.name == EmDashWorkerConfig.sessionBinding }
            // The name goes into the Worker config's `database_name`; an install whose database
            // can't be named is treated like one that can't be read.
            guard let databaseName = try await databaseName(id: databaseID) else { return nil }
            return EmDashInstall(
                workerName: workerName,
                databaseName: databaseName,
                databaseID: databaseID,
                mediaBucketName: media?.bucket_name,
                sessionKVNamespaceID: session?.namespace_id,
                hasWorkerLoader: bindings.contains { $0.type == "worker_loader" && $0.name == EmDashWorkerConfig.workerLoaderBinding },
                marketplacePlugins: plugins.marketplace,
                codePlugins: plugins.code,
                problem: media == nil ? .mediaBucketUnclear : nil)
        }
        return nil
    }

    // MARK: - API calls

    private struct Envelope<T: Decodable>: Decodable {
        let success: Bool
        let result: T?
    }

    private struct Script: Decodable { let id: String }
    private struct Settings: Decodable { let bindings: [Binding]? }
    private struct Database: Decodable { let name: String? }
    /// One value in a query row: its text when it's a string, `nil` for anything else.
    struct Cell: Decodable, Equatable {
        let string: String?
        init(from decoder: Decoder) throws {
            string = try? decoder.singleValueContainer().decode(String.self)
        }
    }
    private struct QueryResult: Decodable { let results: [[String: Cell]]? }
    private struct QueryBody: Encodable { let sql: String }

    func workerNames() async throws -> [String] {
        let scripts: [Script] = try await get("/accounts/\(accountID)/workers/scripts")
        return scripts.map(\.id).filter(WorkerSiteName.isValidWorkerName)
    }

    func bindings(workerName: String) async throws -> [Binding] {
        let settings: Settings = try await get("/accounts/\(accountID)/workers/scripts/\(workerName)/settings")
        return settings.bindings ?? []
    }

    private func databaseName(id: String) async throws -> String? {
        let database: Database? = try? await get("/accounts/\(accountID)/d1/database/\(id)")
        return database?.name.flatMap { EmDashWorkerConfig.isPlainIdentifier($0) ? $0 : nil }
    }

    private func holdsEmDashSchema(databaseID: String) async throws -> Bool {
        let rows = try await query(
            databaseID: databaseID,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '\(Self.schemaMarkerTable)'")
        return !rows.isEmpty
    }

    /// The install's plugins by source. A database without the plugin table has none. EmDash
    /// records `marketplace` for plugins installed from its registry and `config` for those in the
    /// site's code; any other value is counted as code, so the owner is told it may stop rather
    /// than told it's kept when that isn't known.
    private func plugins(databaseID: String) async throws -> (marketplace: [String], code: [String]) {
        let tables = try await query(
            databaseID: databaseID,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '\(Self.pluginTable)'")
        guard !tables.isEmpty else { return ([], []) }
        let rows = try await query(databaseID: databaseID, sql: "SELECT plugin_id, source FROM \(Self.pluginTable) ORDER BY plugin_id")
        var marketplace: [String] = []
        var code: [String] = []
        for row in rows {
            guard let id = row["plugin_id"]?.string, id != Self.anglesiteGatePluginID else { continue }
            if row["source"]?.string == "marketplace" { marketplace.append(id) } else { code.append(id) }
        }
        return (marketplace, code)
    }

    private func query(databaseID: String, sql: String) async throws -> [[String: Cell]] {
        var request = try request(path: "/accounts/\(accountID)/d1/database/\(databaseID)/query")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(QueryBody(sql: sql))
        do {
            let results: [QueryResult] = try await send(request)
            return results.first?.results ?? []
        } catch CloudflareError.unauthorized {
            // Listing Workers and reading their settings worked, so the token is good; it lacks D1.
            throw FindError.cannotReadDatabases
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(try request(path: path))
    }

    private func request(path: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, http) = try await transport(request)
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data), envelope.success,
              let result = envelope.result
        else { throw CloudflareError.malformedResponse }
        return result
    }
}

/// Connects a new EmDash site's package to an existing install (#2106): records the install's
/// Worker and resources so the next Publish Site deploys to it through `EmDashDeployTarget`
/// instead of provisioning new ones.
public enum EmDashConnection {
    public enum ConnectError: Error, Equatable, LocalizedError {
        case notConnectable(EmDashInstall.Problem)
        /// The site has already been published, or already publishes to another Worker.
        /// Connecting would silently point a live site at a different one.
        case alreadyPublished

        public var errorDescription: String? {
            switch self {
            case .notConnectable(.mediaBucketUnclear):
                return "Anglesite couldn't tell where that EmDash site keeps its images, so it wasn't connected."
            case .alreadyPublished:
                return "This website is already published on its own, so it can't be connected to another EmDash site."
            }
        }
    }

    /// Records `install` for the site whose `Source/` is `sourceDirectory`:
    /// - its Worker name as `.site-config`'s `CF_PROJECT_NAME`, which the deploy publishes to;
    /// - its resources in `SiteSettings.emdashResources` (and `emdashD1DatabaseID`, for the
    ///   withheld-pages notice);
    /// - `workerProvisioned`, so the deploy's Worker-name check treats the install's Worker as
    ///   this site's own rather than someone else's.
    ///
    /// Refused with ``ConnectError/alreadyPublished`` for a site that already has a Worker of its
    /// own (published, provisioned, or with EmDash resources recorded): connecting would point a
    /// live site at another Worker. A new site's scaffolded `CF_PROJECT_NAME` is only a default and
    /// is replaced. `.site-config` is written first and restored if the settings can't be saved,
    /// so a failure never leaves the site marked as owning a Worker it doesn't publish to.
    public static func connect(_ install: EmDashInstall, sourceDirectory: URL, configDirectory: URL) async throws {
        if let problem = install.problem { throw ConnectError.notConnectable(problem) }
        let store = SiteConfigStore(configDirectory: configDirectory)
        let settings = try await store.load()
        guard settings.workerDeployed != true, settings.workerProvisioned != true, settings.emdashResources == nil else {
            throw ConnectError.alreadyPublished
        }

        let configURL = sourceDirectory.appendingPathComponent(".site-config")
        let original = try? String(contentsOf: configURL, encoding: .utf8)
        let updated = SiteConfigFile.upsert([("CF_PROJECT_NAME", install.workerName)], into: original ?? "")
        try updated.write(to: configURL, atomically: true, encoding: .utf8)
        do {
            _ = try await store.update {
                $0.emdashResources = install.resources
                $0.emdashD1DatabaseID = install.databaseID
                $0.workerProvisioned = true
            }
        } catch {
            if let original {
                try? original.write(to: configURL, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: configURL)
            }
            throw error
        }
    }
}

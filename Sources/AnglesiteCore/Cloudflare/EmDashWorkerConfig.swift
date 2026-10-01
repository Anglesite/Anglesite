import Foundation

/// The Worker configuration of a provisioned EmDash site (#2103, decision 7 in
/// `docs/specs/2026-09-28-external-cms-content-source-decision.md`).
///
/// Written to the package's `Config/wrangler.toml`, never to `Source/`. The container stages it
/// into the site's working directory before the build, because the Cloudflare adapter reads it
/// at build time: it copies the bindings into `dist/server/wrangler.json` and points
/// `.wrangler/deploy/config.json` at that file, which `wrangler deploy` then follows. The
/// binding names are the ones the overlay's `astro.config.ts` gives EmDash (`EMDASH_BINDINGS`)
/// plus the adapter's session store.
public enum EmDashWorkerConfig {
    /// The Cloudflare resources an EmDash site's Worker is bound to, recorded in
    /// `SiteSettings.emdashResources` as each is created so a failed deploy resumes where it
    /// stopped instead of creating them again.
    public struct Resources: Codable, Sendable, Equatable {
        /// EmDash's content database (binding `DB`).
        public var d1DatabaseName: String?
        public var d1DatabaseID: String?
        /// EmDash's media bucket (binding `MEDIA`).
        public var mediaBucketName: String?
        /// The Cloudflare adapter's Astro session store (binding `SESSION`).
        public var sessionKVNamespaceID: String?
        /// Whether the Worker gets a Worker Loader (binding `LOADER`), so EmDash runs marketplace
        /// plugins sandboxed. Set for a connected install that already had one (#2106); a paid-plan
        /// feature, so a provisioned site has none.
        public var workerLoader: Bool?

        public init(
            d1DatabaseName: String? = nil, d1DatabaseID: String? = nil,
            mediaBucketName: String? = nil, sessionKVNamespaceID: String? = nil,
            workerLoader: Bool? = nil
        ) {
            self.d1DatabaseName = d1DatabaseName
            self.d1DatabaseID = d1DatabaseID
            self.mediaBucketName = mediaBucketName
            self.sessionKVNamespaceID = sessionKVNamespaceID
            self.workerLoader = workerLoader
        }

        /// Whether every resource the Worker is bound to exists.
        public var isComplete: Bool {
            d1DatabaseName != nil && d1DatabaseID != nil && mediaBucketName != nil && sessionKVNamespaceID != nil
        }
    }

    /// The binding names (`EMDASH_BINDINGS` in the overlay's `astro.config.ts`, and the adapter's
    /// session store).
    public static let databaseBinding = "DB"
    public static let mediaBinding = "MEDIA"
    public static let sessionBinding = "SESSION"
    /// The Worker Loader binding EmDash's sandbox runner looks for (`sandbox()` in
    /// `@emdash-cms/cloudflare`).
    public static let workerLoaderBinding = "LOADER"

    /// The Worker's entry: the overlay's `src/worker.ts`, which adds EmDash's scheduled handler to
    /// Astro's, so scheduled articles publish when they come due.
    public static let main = "./src/worker.ts"

    /// How often the scheduled handler runs. EmDash publishes whatever has come due each time, so
    /// a scheduled article goes live within a minute of its time.
    public static let cron = "* * * * *"

    /// The Worker secret holding EmDash's encryption key for plugin secrets at rest.
    public static let encryptionKeySecretName = "EMDASH_ENCRYPTION_KEY"

    /// Resource names for the site's Worker `siteName`. Short suffixes, so a name
    /// `WorkerSiteName` allows (at most 52 characters) stays inside R2's 63-character limit.
    public static func databaseName(siteName: String) -> String { "\(siteName)-cms" }
    public static func mediaBucketName(siteName: String) -> String { "\(siteName)-cms-media" }
    public static func sessionNamespaceTitle(siteName: String) -> String { "\(siteName)-cms-session" }

    public enum ConfigError: Error, Equatable, CustomStringConvertible {
        case incomplete
        case invalidValue(String)

        public var description: String {
            switch self {
            case .incomplete: return "the EmDash Worker's resources haven't all been created yet"
            case .invalidValue(let value): return "unexpected value in the EmDash Worker's configuration: \(value)"
            }
        }
    }

    /// The `wrangler.toml` for the Worker `workerName` bound to `resources`. Every value is
    /// checked to be a plain identifier before it's written, so nothing a resource id or name
    /// carries can change the file's structure.
    public static func toml(workerName: String, resources: Resources) throws -> String {
        guard resources.isComplete,
              let databaseName = resources.d1DatabaseName, let databaseID = resources.d1DatabaseID,
              let bucket = resources.mediaBucketName, let session = resources.sessionKVNamespaceID
        else { throw ConfigError.incomplete }
        for value in [workerName, databaseName, databaseID, bucket, session] where !isPlainIdentifier(value) {
            throw ConfigError.invalidValue(value)
        }
        return """
        # Written by Anglesite for this EmDash site (#2103). App-owned: it lives in the site's Config/,
        # never in its repository, and is rewritten on every publish.
        name = "\(workerName)"
        main = "\(main)"
        compatibility_date = "\(compatibilityDate)"
        compatibility_flags = ["nodejs_compat"]

        [observability]
        enabled = true

        [triggers]
        crons = ["\(cron)"]

        [[d1_databases]]
        binding = "\(databaseBinding)"
        database_name = "\(databaseName)"
        database_id = "\(databaseID)"

        [[r2_buckets]]
        binding = "\(mediaBinding)"
        bucket_name = "\(bucket)"

        [[kv_namespaces]]
        binding = "\(sessionBinding)"
        id = "\(session)"

        """ + (resources.workerLoader == true ? """

        [[worker_loaders]]
        binding = "\(workerLoaderBinding)"

        """ : "")
    }

    /// The same compatibility date as the social Worker composition (`WorkerComposition`).
    static let compatibilityDate = "2026-07-15"

    /// Letters, digits, hyphens and underscores: every Worker, D1, R2 and KV name or id
    /// Cloudflare issues (Worker names may carry underscores).
    static func isPlainIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)) || scalar == "-" || scalar == "_"
        }
    }

    /// A new EmDash encryption key: `emdash_enc_v1_` and 32 random bytes as unpadded base64url
    /// (the format `emdash secrets generate` prints).
    public static func generateEncryptionKey() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let body = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "emdash_enc_v1_" + body
    }

    /// The site's EmDash encryption key, generated once and kept in the platform secret store.
    /// Never regenerated: losing it loses every plugin secret EmDash encrypted with it.
    public static func encryptionKey(siteID: String, secretStore: any SecretStore) throws -> String {
        let account = SecretAccounts.emdashEncryptionKey(siteID: siteID)
        if let existing = try secretStore.read(account: account), !existing.isEmpty {
            return existing
        }
        let key = generateEncryptionKey()
        try secretStore.write(key, account: account)
        return key
    }
}

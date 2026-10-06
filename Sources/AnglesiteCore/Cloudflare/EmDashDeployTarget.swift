import Foundation

/// Publishes a provisioned EmDash site (#2103, decision 7 in
/// `docs/specs/2026-09-28-external-cms-content-source-decision.md`): one Worker in the owner's
/// Cloudflare account that server-renders the site against EmDash, with EmDash's content in D1
/// and its media in R2. The owner never configures any of it (decision D1).
///
/// Wraps ``CloudflareDeployTarget`` like ``SocialWorkerProvisionTarget`` does, but provisions in
/// ``prepare(context:)``, before the build, because the site's Cloudflare adapter reads the
/// Worker config at build time:
///
/// 1. Creates the site's D1 database, R2 media bucket and session KV namespace, each only if
///    `SiteSettings.emdashResources` doesn't already record it, saving after each one so a failed
///    publish resumes where it stopped.
/// 2. Writes the Worker config (``EmDashWorkerConfig``) to `Config/wrangler.toml`, with Workers
///    Caching on only when the owner said the account is on the Workers Paid plan
///    (`SiteSettings.emdashWorkersPaidPlan`, #2116).
/// 3. Pushes `EMDASH_ENCRYPTION_KEY`, generated once and kept in the platform secret store.
///
/// The shared spine then builds and runs the pre-deploy gate (in its server-rendered mode, #2055)
/// before ``publish(context:)`` runs `wrangler deploy` through `CloudflareDeployTarget` and records
/// where Open EmDash goes. EmDash applies its own database migrations on first request, and the
/// owner creates the first EmDash account on its setup page.
///
/// Social Workers (Webmention, ActivityPub, IndieAuth) aren't composed on an EmDash site yet: the
/// EmDash Worker is the public site, and composing them with it is #2052/#2053.
public actor EmDashDeployTarget: DeployTarget {
    public static let id = "cloudflare-emdash"

    /// Reads the site's EmDash encryption key, creating it the first time.
    public typealias EncryptionKeySource = @Sendable (_ siteID: String) throws -> String

    private let cloudflareTarget: CloudflareDeployTarget
    private let siteName: String
    private let encryptionKeySource: EncryptionKeySource
    private let secretRunner: SocialWorkerProvisionCommand.SecretRunner

    public init(
        cloudflareTarget: CloudflareDeployTarget,
        siteName: String,
        encryptionKeySource: @escaping EncryptionKeySource = EmDashDeployTarget.defaultEncryptionKeySource,
        secretRunner: @escaping SocialWorkerProvisionCommand.SecretRunner
    ) {
        self.cloudflareTarget = cloudflareTarget
        self.siteName = siteName
        self.encryptionKeySource = encryptionKeySource
        self.secretRunner = secretRunner
    }

    /// The production key source: the platform secret store (Keychain on macOS).
    public static let defaultEncryptionKeySource: EncryptionKeySource = { siteID in
        try EmDashWorkerConfig.encryptionKey(siteID: siteID, secretStore: PlatformSecretStore.make())
    }

    public nonisolated var rendersOnServer: Bool { true }

    /// The full `CloudflareDeployTarget` gate, then the `workerProvisioned` marker, as
    /// `SocialWorkerProvisionTarget` does, so a retried first publish doesn't read this site's own
    /// Worker name as someone else's.
    public func authorize(siteDirectory: URL, configDirectory: URL) async -> DeployTargetAuthorization {
        let authorization = await cloudflareTarget.authorize(siteDirectory: siteDirectory, configDirectory: configDirectory)
        if case .ready = authorization {
            await CloudflareDeployTarget.persistWorkerProvisioned(configDirectory: configDirectory)
        }
        return authorization
    }

    /// Provisions before the build, because the build copies the resources' ids into the server
    /// bundle's config. That also means a first publish the pre-deploy gate then refuses has
    /// already created the site's (empty) database, bucket and session store and pushed its key:
    /// deliberate. Nothing is published, and the next publish reuses them rather than creating
    /// more. Each resource is looked up by its name before it's created, so a publish interrupted
    /// between creating one and recording it, or a lost settings file, adopts what's already there
    /// instead of failing on "already exists".
    public func prepare(context: DeployTargetContext) async -> DeployCommand.Result? {
        guard WorkerComposition.isValidSiteName(siteName) else {
            return .failed(reason: "invalid Worker name: \(siteName)", exitCode: nil)
        }
        var environment = context.baseEnvironment
        environment["CLOUDFLARE_API_TOKEN"] = context.credential
        let source = "emdash-provision:\(context.siteID)"
        let store = SiteConfigStore(configDirectory: context.configDirectory)
        var resources: EmDashWorkerConfig.Resources
        let workersPaidPlan: Bool
        do {
            let settings = try await store.load()
            resources = settings.emdashResources ?? .init()
            workersPaidPlan = settings.emdashWorkersPaidPlan == true
        } catch {
            // Without the record, every resource would have to be looked up again; a settings file
            // that can't be read is worth stopping for rather than guessing past.
            return .failed(reason: "couldn't read this site's settings: \(error)", exitCode: nil)
        }

        if resources.d1DatabaseID == nil {
            let name = EmDashWorkerConfig.databaseName(siteName: siteName)
            let found: String?
            switch await run(["d1", "list", "--json"], context: context, environment: environment, source: source) {
            case .failure(let failure): return failure
            case .success(let output): found = Self.existingID(named: name, nameKey: "name", idKey: "uuid", in: output)
            }
            let id: String
            if let found {
                id = found
            } else {
                switch await run(["d1", "create", name], context: context, environment: environment, source: source) {
                case .failure(let failure):
                    return failure
                case .success(let output):
                    guard let created = SocialWorkerProvisionCommand.extractResourceID(from: output) else {
                        return .failed(reason: "wrangler created D1 database \(name) but no database id was found", exitCode: 0)
                    }
                    id = created
                }
            }
            guard EmDashWorkerConfig.isPlainIdentifier(id) else {
                return .failed(reason: "wrangler created D1 database \(name) but no database id was found", exitCode: 0)
            }
            resources.d1DatabaseName = name
            resources.d1DatabaseID = id
            await save(resources, to: store)
        }

        if resources.mediaBucketName == nil {
            let name = EmDashWorkerConfig.mediaBucketName(siteName: siteName)
            guard WorkerSiteName.isValidR2BucketName(name) else {
                return .failed(reason: "invalid R2 bucket name: \(name)", exitCode: nil)
            }
            // Bucket names are per account, so a bucket `info` finds is this site's own.
            let exists = await context.executor.run(
                step: .wranglerSubcommand(args: ["r2", "bucket", "info", name, "--json"]),
                siteDirectory: context.siteDirectory, environment: environment, source: source).exitCode == 0
            if !exists {
                switch await run(["r2", "bucket", "create", name], context: context, environment: environment, source: source) {
                case .failure(let failure): return failure
                case .success: break
                }
            }
            resources.mediaBucketName = name
            await save(resources, to: store)
        }

        if resources.sessionKVNamespaceID == nil {
            let title = EmDashWorkerConfig.sessionNamespaceTitle(siteName: siteName)
            let found: String?
            switch await run(["kv", "namespace", "list"], context: context, environment: environment, source: source) {
            case .failure(let failure): return failure
            case .success(let output): found = Self.existingID(named: title, nameKey: "title", idKey: "id", in: output)
            }
            let id: String
            if let found {
                id = found
            } else {
                switch await run(["kv", "namespace", "create", title], context: context, environment: environment, source: source) {
                case .failure(let failure):
                    return failure
                case .success(let output):
                    guard let created = SocialWorkerProvisionCommand.extractResourceID(from: output) else {
                        return .failed(reason: "wrangler created KV namespace \(title) but no namespace id was found", exitCode: 0)
                    }
                    id = created
                }
            }
            guard EmDashWorkerConfig.isPlainIdentifier(id) else {
                return .failed(reason: "wrangler created KV namespace \(title) but no namespace id was found", exitCode: 0)
            }
            resources.sessionKVNamespaceID = id
            await save(resources, to: store)
        }

        do {
            let toml = try EmDashWorkerConfig.toml(workerName: siteName, resources: resources, cache: workersPaidPlan)
            try WranglerConfigFile.write(toml, configDirectory: context.configDirectory)
        } catch {
            return .failed(reason: "couldn't write the EmDash Worker's configuration: \(error)", exitCode: nil)
        }

        return await pushEncryptionKeyIfMissing(context: context, environment: environment, source: source)
    }

    /// Pushes `EMDASH_ENCRYPTION_KEY` only when the Worker doesn't already hold it. The key lives
    /// in this Mac's secret store, so another Mac (or a reset Keychain) has none and would make a
    /// new one; pushing that would make every plugin secret EmDash encrypted with the old key
    /// unreadable. So the Worker's own secret list decides: already there, nothing is pushed and
    /// no key is made here. A Worker that doesn't exist yet (the first publish) gets the key;
    /// `wrangler secret put` creates it as a draft, non-interactively, for the deploy to replace.
    /// If the list can't be read, the publish stops rather than risk replacing the key.
    private func pushEncryptionKeyIfMissing(
        context: DeployTargetContext, environment: [String: String], source: String
    ) async -> DeployCommand.Result? {
        let name = EmDashWorkerConfig.encryptionKeySecretName
        let listed = await context.executor.run(
            step: .wranglerSubcommand(args: ["secret", "list", "--format", "json"]),
            siteDirectory: context.siteDirectory, environment: environment, source: source)
        if listed.exitCode == 0 {
            guard let names = Self.jsonArray(in: listed.output)?.compactMap({ $0["name"] as? String }) else {
                return .failed(reason: "couldn't read the EmDash Worker's secrets: \(listed.output)", exitCode: 0)
            }
            if names.contains(name) { return nil }
        } else if !Self.isWorkerNotFound(listed.output) {
            return .failed(
                reason: listed.output.isEmpty ? "couldn't read the EmDash Worker's secrets" : listed.output,
                exitCode: listed.exitCode)
        }

        let key: String
        do {
            key = try encryptionKeySource(context.siteID)
        } catch {
            return .failed(reason: "couldn't prepare EmDash's encryption key: \(error)", exitCode: nil)
        }
        do {
            let result = try await secretRunner(context.siteDirectory, name, key, environment, source)
            guard result.exitCode == 0 else {
                let output = result.stdout.isEmpty ? result.stderr : result.stdout
                return .failed(reason: "couldn't push \(name): \(output)", exitCode: result.exitCode)
            }
        } catch {
            return .failed(reason: "couldn't push \(name): \(error)", exitCode: nil)
        }
        return nil
    }

    /// `wrangler secret list`'s refusal for a Worker that hasn't been deployed yet.
    static func isWorkerNotFound(_ output: String) -> Bool {
        output.range(of: #"Worker "[^"]*"( \(env: [^)]*\))? not found"#, options: .regularExpression) != nil
    }

    /// The JSON array in a wrangler command's output, which may carry warnings (`▲ [WARNING] …`)
    /// around it: the first `[` from which the rest, up to the last `]`, parses as an array.
    static func jsonArray(in output: String) -> [[String: Any]]? {
        guard let end = output.lastIndex(of: "]") else { return nil }
        var index = output.startIndex
        while let start = output[index..<end].firstIndex(of: "[") {
            if let data = String(output[start...end]).data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return array
            }
            index = output.index(after: start)
        }
        return nil
    }

    /// The id of the resource called `name` in a wrangler list's JSON output, if one exists.
    static func existingID(named name: String, nameKey: String, idKey: String, in output: String) -> String? {
        jsonArray(in: output)?.first { ($0[nameKey] as? String) == name }?[idKey] as? String
    }

    /// `wrangler deploy` and its post-publish effects through `CloudflareDeployTarget`, then, on
    /// success, where Open EmDash goes: EmDash's admin on the URL the site was published at.
    public func publish(context: DeployTargetContext) async -> DeployCommand.Result {
        let result = await cloudflareTarget.publish(context: context)
        if case .succeeded(let url, _) = result, let adminURL = Self.adminURL(siteURL: url) {
            let store = SiteConfigStore(configDirectory: context.configDirectory)
            do {
                _ = try await store.update { $0.emdashAdminURL = adminURL }
            } catch {
                // The site is published either way; Open EmDash picks the URL up on the next
                // publish. Logged, because the owner would otherwise see Open EmDash stay off.
                await LogCenter.shared.append(
                    source: "emdash-provision:\(context.siteID)", stream: .stderr,
                    text: "couldn't record the EmDash admin address: \(error)")
            }
        }
        return result
    }

    /// EmDash's admin for a site published at `siteURL`, when that URL is `https`.
    static func adminURL(siteURL: URL) -> URL? {
        guard siteURL.scheme == "https", let host = siteURL.host, !host.isEmpty,
              var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.path = "/_emdash/admin"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: - Helpers

    private enum StepResult {
        case success(String)
        case failure(DeployCommand.Result)
    }

    private func run(
        _ arguments: [String], context: DeployTargetContext, environment: [String: String], source: String
    ) async -> StepResult {
        let result = await context.executor.run(
            step: .wranglerSubcommand(args: arguments),
            siteDirectory: context.siteDirectory, environment: environment, source: source)
        guard let exitCode = result.exitCode, exitCode == 0 else {
            return .failure(.failed(
                reason: result.output.isEmpty ? "wrangler exited with code \(String(describing: result.exitCode))" : result.output,
                exitCode: result.exitCode))
        }
        return .success(result.output)
    }

    /// Records `resources`, and the database id the withheld-pages notice reads (#2097).
    private func save(_ resources: EmDashWorkerConfig.Resources, to store: SiteConfigStore) async {
        do {
            _ = try await store.update {
                $0.emdashResources = resources
                $0.emdashD1DatabaseID = resources.d1DatabaseID
            }
        } catch {
            // Not fatal: the Worker config written below still carries every id, and a lost record
            // only means a later publish can't resume. Logged, never swallowed silently.
            await LogCenter.shared.append(
                source: "emdash-provision", stream: .stderr,
                text: "couldn't record the EmDash site's Cloudflare resources: \(error)")
        }
    }
}

// MARK: - The Workers plan question (#2116)

public extension EmDashDeployTarget {
    /// Whether Publish Site should ask the owner, before publishing, whether their Cloudflare
    /// account is on the Workers Paid plan: an EmDash site whose owner hasn't answered yet. The
    /// answer decides whether the site's Worker caches its pages
    /// (`SiteSettings.emdashWorkersPaidPlan`). A settings file that can't be read is asked about
    /// too: the answer is saved through the same store, and asking again costs one click.
    ///
    /// Reads two small files synchronously (the package marker and `settings.plist`), like the
    /// license gate's `LicensingStore` read that runs just before it in `DeployModel.deploy`.
    static func needsWorkersPlanAnswer(sourceDirectory: URL, configDirectory: URL) -> Bool {
        guard SiteEditingSurfaces.forSourceDirectory(sourceDirectory).serverRenderedDeploy else { return false }
        return (try? SiteConfigStore.read(from: configDirectory))?.emdashWorkersPaidPlan == nil
    }

    /// The Website inspector's Workers Paid setting, which changes the answer later: `nil` for a
    /// site that isn't EmDash, which has no such setting, and otherwise whether the Worker caches its
    /// pages from the next publish on. An unanswered question reads as `false`, since Publish Site
    /// leaves the cache off until the owner says otherwise.
    static func workersPaidPlanSetting(sourceDirectory: URL, configDirectory: URL) -> Bool? {
        guard SiteEditingSurfaces.forSourceDirectory(sourceDirectory).serverRenderedDeploy else { return nil }
        return (try? SiteConfigStore.read(from: configDirectory))?.emdashWorkersPaidPlan == true
    }

    /// Records the owner's answer for the site whose `Config/` is `configDirectory`.
    static func recordWorkersPlan(paid: Bool, configDirectory: URL) async throws {
        _ = try await SiteConfigStore(configDirectory: configDirectory).update { $0.emdashWorkersPaidPlan = paid }
    }
}

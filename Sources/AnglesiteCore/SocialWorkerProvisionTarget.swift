import Foundation

/// `DeployTarget` conformer for Cloudflare Worker provisioning (#1821): resource creation
/// (D1/KV/R2/Queues), secret pushes, and D1 migrations all run inside `publish(context:)`,
/// reached only after `authorize` (the full `CloudflareDeployTarget` gate — worker-name-conflict
/// AND domain-config-drift, not just the former) and the shared build+`PreDeployCheck` spine have
/// passed. `publish` finishes by delegating to `cloudflareTarget.publish(context:)` for the
/// actual `wrangler deploy`, so the final step reuses `CloudflareDeployTarget`'s URL extraction,
/// custom-domain attach, Markdown for Agents, and `.site-config` persistence rather than
/// duplicating any of it.
///
/// An `actor`, not a `struct`: `resources` accumulates incrementally across `publish`'s many
/// resource-creation steps, and `SocialWorkerProvisionCommand.provision` needs to read the final
/// value back after `DeployCommand.deploy` returns — on every outcome, not just success, since a
/// partial failure must not lose ids already created (this target's `resources` is the same
/// resumability state `SocialWorkerProvisionCommand.Result` has always carried).
public actor SocialWorkerProvisionTarget: DeployTarget {
    public static let id = "cloudflare-worker-provisioning"

    private let cloudflareTarget: CloudflareDeployTarget
    private let siteName: String
    private let workers: [WorkerDescriptor]
    private let routeClaims: [WorkerRouteClaim]
    private let siteURL: String?
    private let displayName: String?
    private let apUsername: String?
    private let apIcon: String?
    private let acknowledgesPaidPlan: Bool
    private let inboxCaptureEnabled: Bool
    private let inboxForwardEmail: String?
    private let activityPubActorType: String?
    private let moderators: [String]?
    private let experiments: [DomainConfig.Experiments.Experiment]
    private let mcpEnabled: Bool
    private let keyPairSource: SocialWorkerProvisionCommand.KeyPairSource
    private let solidOidcSigningKeySource: SocialWorkerProvisionCommand.SolidOidcSigningKeySource
    private let webdavPepperSource: SocialWorkerProvisionCommand.WebdavPepperSource
    private let secretRunner: SocialWorkerProvisionCommand.SecretRunner
    private let accountIDSource: SocialWorkerProvisionCommand.AccountIDSource
    public private(set) var resources: WorkerComposition.ProvisionedResources

    public init(
        cloudflareTarget: CloudflareDeployTarget,
        siteName: String,
        workers: [WorkerDescriptor],
        routeClaims: [WorkerRouteClaim] = [],
        knownResources: WorkerComposition.ProvisionedResources = .init(),
        siteURL: String? = nil,
        displayName: String? = nil,
        apUsername: String? = nil,
        apIcon: String? = nil,
        acknowledgesPaidPlan: Bool = false,
        inboxCaptureEnabled: Bool = false,
        inboxForwardEmail: String? = nil,
        activityPubActorType: String? = nil,
        moderators: [String]? = nil,
        experiments: [DomainConfig.Experiments.Experiment] = [],
        mcpEnabled: Bool = false,
        keyPairSource: @escaping SocialWorkerProvisionCommand.KeyPairSource,
        solidOidcSigningKeySource: @escaping SocialWorkerProvisionCommand.SolidOidcSigningKeySource,
        webdavPepperSource: @escaping SocialWorkerProvisionCommand.WebdavPepperSource,
        secretRunner: @escaping SocialWorkerProvisionCommand.SecretRunner,
        accountIDSource: @escaping SocialWorkerProvisionCommand.AccountIDSource
    ) {
        self.cloudflareTarget = cloudflareTarget
        self.siteName = siteName
        self.workers = workers
        self.routeClaims = routeClaims
        self.resources = knownResources
        self.siteURL = siteURL
        self.displayName = displayName
        self.apUsername = apUsername
        self.apIcon = apIcon
        self.acknowledgesPaidPlan = acknowledgesPaidPlan
        self.inboxCaptureEnabled = inboxCaptureEnabled
        self.inboxForwardEmail = inboxForwardEmail
        self.activityPubActorType = activityPubActorType
        self.moderators = moderators
        self.experiments = experiments
        self.mcpEnabled = mcpEnabled
        self.keyPairSource = keyPairSource
        self.solidOidcSigningKeySource = solidOidcSigningKeySource
        self.webdavPepperSource = webdavPepperSource
        self.secretRunner = secretRunner
        self.accountIDSource = accountIDSource
    }

    /// Delegates to `CloudflareDeployTarget.authorize(siteDirectory:)` for the full pre-build gate
    /// (token resolution, worker-name-conflict, domain-config-drift), then — only once that gate
    /// returns `.ready` — persists `.site-config`'s `CF_WORKER_PROVISIONED` marker (#1075) so a
    /// later `checkWorkerNameConflict` on a retried/resumed provisioning attempt recognizes this
    /// site's own candidate name rather than misreporting it as a foreign collision.
    public func authorize(siteDirectory: URL) async -> DeployTargetAuthorization {
        let authorization = await cloudflareTarget.authorize(siteDirectory: siteDirectory)
        if case .ready = authorization {
            CloudflareDeployTarget.persistWorkerProvisioned(siteDirectory: siteDirectory)
        }
        return authorization
    }

    /// Provisions every Cloudflare resource the active workers need (D1, KV, R2, Queues,
    /// secrets), regenerates `wrangler.toml`, then delegates to `cloudflareTarget.publish(context:)`
    /// for the actual `wrangler deploy`. Idempotent and resumable: each resource is created only
    /// if not already known (from `resources`, seeded by `knownResources` at `init`), and config
    /// is persisted after every successful step so a failure partway through never loses ids
    /// already created.
    ///
    /// Only reached after `authorize(siteDirectory:)` returned `.ready` and the shared
    /// build+`PreDeployCheck` spine passed — the worker-name-conflict check that used to run at
    /// the top of `SocialWorkerProvisionCommand.provision` is superseded by `authorize` above, so
    /// it isn't repeated here.
    public func publish(context: DeployTargetContext) async -> DeployCommand.Result {
        var environment = context.baseEnvironment
        environment["CLOUDFLARE_API_TOKEN"] = context.credential
        let source = "worker-provision:\(context.siteID)"
        let hasRunningExperiment = experiments.contains(where: { $0.status == "running" })

        if workers.contains(where: { $0.resources.needsD1 }) || hasRunningExperiment {
            if resources.d1DatabaseID == nil {
                let name = "\(siteName)-social"
                let result = await runWranglerSubcommand(
                    context: context, arguments: ["d1", "create", name], environment: environment, source: source)
                let output: String
                switch result {
                case .success(let value):
                    output = value
                case .failure(let failure):
                    return failure
                }
                guard let id = SocialWorkerProvisionCommand.extractResourceID(from: output) else {
                    return .failed(reason: "wrangler created D1 database \(name) but no database id was found", exitCode: 0)
                }
                resources.d1DatabaseID = id
                if let failure = persistConfig(siteDirectory: context.siteDirectory) {
                    return failure
                }
            }
        }

        if workers.contains(where: { $0.resources.needsKV }) || mcpEnabled {
            if resources.kvNamespaceID == nil {
                let name = "\(siteName)-social"
                let result = await runWranglerSubcommand(
                    context: context, arguments: ["kv", "namespace", "create", name], environment: environment, source: source)
                let output: String
                switch result {
                case .success(let value):
                    output = value
                case .failure(let failure):
                    return failure
                }
                guard let id = SocialWorkerProvisionCommand.extractResourceID(from: output) else {
                    return .failed(reason: "wrangler created KV namespace \(name) but no namespace id was found", exitCode: 0)
                }
                resources.kvNamespaceID = id
                if let failure = persistConfig(siteDirectory: context.siteDirectory) {
                    return failure
                }
            }
        }

        if workers.contains(where: { $0.id == WorkerComposition.micropubWorkerID }) {
            if resources.r2BucketName == nil {
                let name = "\(siteName)-media"
                let result = await runWranglerSubcommand(
                    context: context, arguments: ["r2", "bucket", "create", name], environment: environment, source: source)
                if case .failure(let failure) = result {
                    return failure
                }
                resources.r2BucketName = name
                if let failure = persistConfig(siteDirectory: context.siteDirectory) {
                    return failure
                }
            }
        }

        let hasSolidPodOrWebdav = workers.contains(where: {
            $0.id == WorkerComposition.solidPodWorkerID || $0.id == WorkerComposition.webdavWorkerID
        })
        if hasSolidPodOrWebdav {
            if resources.podBlobsR2BucketName == nil {
                let name = "\(siteName)-pod-blobs"
                let result = await runWranglerSubcommand(
                    context: context, arguments: ["r2", "bucket", "create", name], environment: environment, source: source)
                if case .failure(let failure) = result {
                    return failure
                }
                resources.podBlobsR2BucketName = name
                if let failure = persistConfig(siteDirectory: context.siteDirectory) {
                    return failure
                }
            }
        }

        if inboxCaptureEnabled {
            // Namespace creation and account-id resolution are independent, separately-retriable
            // steps (final-review finding, #1173): `accountIDSource` can return nil on a
            // transient failure (its production default swallows any transport/API error), and
            // if the only re-entry guard were "namespace already exists" that nil would be
            // permanently stranded — `InboxSubmissionSync` requires both ids, so the feature would
            // silently never activate. Gating each step on its own nil-check means a future
            // provisioning run retries account resolution without ever re-creating a namespace
            // that already exists.
            if resources.inboxKVNamespaceID == nil {
                let name = "\(siteName)-inbox"
                let result = await runWranglerSubcommand(
                    context: context, arguments: ["kv", "namespace", "create", name], environment: environment, source: source)
                let output: String
                switch result {
                case .success(let value):
                    output = value
                case .failure(let failure):
                    return failure
                }
                guard let id = SocialWorkerProvisionCommand.extractResourceID(from: output) else {
                    return .failed(reason: "wrangler created KV namespace \(name) but no namespace id was found", exitCode: 0)
                }
                resources.inboxKVNamespaceID = id
            }
            if resources.inboxAccountID == nil {
                resources.inboxAccountID = await accountIDSource(context.credential)
            }
            if let failure = persistConfig(siteDirectory: context.siteDirectory) {
                return failure
            }
        }

        let hasActivityPub = workers.contains(where: { $0.id == WorkerComposition.activitypubWorkerID })
        if hasActivityPub {
            // ActivityPub's catalog resources are all needsD1/needsKV/needsR2 == false (it only
            // needs a Durable Object, which those flags don't track), so if it's the only active
            // worker none of the D1/KV/R2 blocks above ran and wrangler.toml may not exist yet.
            // `wrangler secret put` (below) resolves the Worker's project name from
            // wrangler.toml in the working directory — persist it here first so that lookup
            // succeeds even on an ActivityPub-only first deploy.
            if let failure = persistConfig(siteDirectory: context.siteDirectory) {
                return failure
            }
            let keys: ActivityPubKeyProvisioning.Secrets
            do {
                keys = try keyPairSource(context.siteID)
            } catch {
                return .failed(reason: "couldn't prepare ActivityPub signing key: \(error)", exitCode: nil)
            }
            for (name, value) in [
                ("AP_PRIVATE_KEY", keys.privateKeyPem),
                ("AP_PUBLIC_KEY", keys.publicKeyPem),
                ("AP_PUBLISH_TOKEN", keys.publishToken),
            ] {
                do {
                    let secretResult = try await secretRunner(context.siteDirectory, name, value, environment, source)
                    guard secretResult.exitCode == 0 else {
                        let output = secretResult.stdout.isEmpty ? secretResult.stderr : secretResult.stdout
                        return .failed(reason: "couldn't push \(name): \(output)", exitCode: secretResult.exitCode)
                    }
                } catch {
                    return .failed(reason: "couldn't push \(name): \(error)", exitCode: nil)
                }
            }
        }

        let hasSolidOidc = workers.contains(where: { $0.id == WorkerComposition.solidOidcWorkerID })
        if hasSolidOidc {
            let signingKeyJWK: String
            do {
                signingKeyJWK = try solidOidcSigningKeySource(context.siteID)
            } catch {
                return .failed(reason: "couldn't prepare Solid-OIDC signing key: \(error)", exitCode: nil)
            }
            do {
                let secretResult = try await secretRunner(context.siteDirectory, "OIDC_SIGNING_KEY", signingKeyJWK, environment, source)
                guard secretResult.exitCode == 0 else {
                    let output = secretResult.stdout.isEmpty ? secretResult.stderr : secretResult.stdout
                    return .failed(reason: "couldn't push OIDC_SIGNING_KEY: \(output)", exitCode: secretResult.exitCode)
                }
            } catch {
                return .failed(reason: "couldn't push OIDC_SIGNING_KEY: \(error)", exitCode: nil)
            }
        }

        let hasWebdav = workers.contains(where: { $0.id == WorkerComposition.webdavWorkerID })
        if hasWebdav {
            let pepper: String
            do {
                pepper = try webdavPepperSource(context.siteID)
            } catch {
                return .failed(reason: "couldn't prepare WebDAV pepper: \(error)", exitCode: nil)
            }
            do {
                let secretResult = try await secretRunner(context.siteDirectory, "WEBDAV_PEPPER", pepper, environment, source)
                guard secretResult.exitCode == 0 else {
                    let output = secretResult.stdout.isEmpty ? secretResult.stderr : secretResult.stdout
                    return .failed(reason: "couldn't push WEBDAV_PEPPER: \(output)", exitCode: secretResult.exitCode)
                }
            } catch {
                return .failed(reason: "couldn't push WEBDAV_PEPPER: \(error)", exitCode: nil)
            }
        }

        let hasWebmentionReceive = workers.contains(where: { $0.id == WorkerComposition.webmentionWorkerID })
        let hasWebSub = workers.contains(where: { $0.id == WorkerComposition.websubWorkerID })
        let hasMicrosub = workers.contains(where: { $0.id == WorkerComposition.microsubWorkerID })
        let needsWebmentionQueue = hasWebmentionReceive && resources.queueName == nil
        let needsWebSubQueue = hasWebSub && resources.websubQueueName == nil
        let needsMicrosubQueue = hasMicrosub && resources.microsubQueueName == nil
        if needsWebmentionQueue || needsWebSubQueue || needsMicrosubQueue {
            guard acknowledgesPaidPlan else {
                return .webmentionPaidPlanConfirmationNeeded
            }
        }
        if needsWebmentionQueue {
            let name = "\(siteName)-webmention"
            let result = await runWranglerSubcommand(
                context: context, arguments: ["queues", "create", name], environment: environment, source: source)
            switch result {
            case .success:
                resources.queueName = name
            case .failure(let failure):
                return failure
            }
            if let failure = persistConfig(siteDirectory: context.siteDirectory) {
                return failure
            }
        }

        if needsWebSubQueue {
            let name = "\(siteName)-websub"
            let result = await runWranglerSubcommand(
                context: context, arguments: ["queues", "create", name], environment: environment, source: source)
            switch result {
            case .success:
                resources.websubQueueName = name
            case .failure(let failure):
                return failure
            }
            if let failure = persistConfig(siteDirectory: context.siteDirectory) {
                return failure
            }
        }

        if needsMicrosubQueue {
            let name = "\(siteName)-microsub"
            let result = await runWranglerSubcommand(
                context: context, arguments: ["queues", "create", name], environment: environment, source: source)
            switch result {
            case .success:
                resources.microsubQueueName = name
            case .failure(let failure):
                return failure
            }
            if let failure = persistConfig(siteDirectory: context.siteDirectory) {
                return failure
            }
        }

        if let failure = persistConfig(siteDirectory: context.siteDirectory) {
            return failure
        }

        // @dwk/indieauth deliberately keeps schema deployment outside its request handler. Apply
        // the committed D1 migrations after wrangler.toml contains the concrete database id and
        // before publishing code that can receive authorization requests.
        if workers.contains(where: { $0.id == WorkerComposition.indieauthWorkerID }) {
            let result = await runWranglerSubcommand(
                context: context, arguments: ["d1", "migrations", "apply", "AUTH_DB", "--remote"], environment: environment, source: source)
            if case .failure(let failure) = result {
                return failure
            }
        }

        // #1270 slice 3: mirrors the IndieAuth AUTH_DB migration above — applies once
        // wrangler.toml has a concrete database id (either from the D1 gate above, in this same
        // run, or already known from a prior run) and before publishing code that can record
        // experiment events.
        if hasRunningExperiment {
            let result = await runWranglerSubcommand(
                context: context, arguments: ["d1", "migrations", "apply", "EXPERIMENTS_DB", "--remote"], environment: environment, source: source)
            if case .failure(let failure) = result {
                return failure
            }
        }

        // Every resource/secret/migration step above is done — hand off to the inner Cloudflare
        // target for the actual `wrangler deploy` and its post-publish effects (URL extraction,
        // custom-domain attach, Markdown for Agents, `.site-config` persistence). `context` here
        // already reflects the one shared build+`PreDeployCheck` spine run this `publish` call is
        // itself part of, so this must NOT go through `DeployCommand.deploy` again — that would
        // re-run `authorize`/build/`PreDeployCheck` a second time.
        return await cloudflareTarget.publish(context: context)
    }

    // MARK: - Wrangler subcommand seam

    private enum StepResult {
        case success(String)
        case failure(DeployCommand.Result)
    }

    /// Runs one arbitrary `wrangler <arguments>` subcommand (`d1 create`, `kv namespace create`,
    /// `queues create`, `d1 migrations apply`, etc.) through `context.executor`, translating a
    /// non-zero (or missing) exit code into a `DeployCommand.Result.failed`. `result.output`
    /// already carries the stdout-or-stderr fallback for this step
    /// (`ContainerDeployExecutor.run`'s `.wranglerSubcommand` case), so no fallback is needed here.
    private func runWranglerSubcommand(
        context: DeployTargetContext, arguments: [String], environment: [String: String], source: String
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

    // MARK: - Config persistence

    /// Regenerates `wrangler.toml` from `resources`/`workers`/`routeClaims`/etc. and reconciles
    /// `.site-config`'s derived `*_ENABLED` flags to the current true state. Copied from
    /// `SocialWorkerProvisionCommand.persistConfig` (#1821 Task 13) — moved rather than shared
    /// because it's provisioning-specific logic and reads `resources` (this actor's own current
    /// truth) directly instead of taking it as a parameter.
    private func persistConfig(siteDirectory: URL) -> DeployCommand.Result? {
        do {
            let configuration = try WorkerComposition.generateWranglerToml(
                siteName: siteName,
                workers: workers,
                routeClaims: routeClaims,
                resources: resources,
                inboxCaptureEnabled: inboxCaptureEnabled,
                inboxKVNamespaceID: resources.inboxKVNamespaceID,
                inboxForwardEmail: inboxForwardEmail,
                siteURL: siteURL,
                displayName: displayName,
                activityPubActorType: activityPubActorType,
                moderators: moderators,
                apUsername: apUsername, apIcon: apIcon,
                experiments: experiments, mcpEnabled: mcpEnabled
            )
            try configuration.toml.write(
                to: siteDirectory.appendingPathComponent("wrangler.toml"),
                atomically: true,
                encoding: .utf8
            )
            // Reflects "the receiver is actually live" (webmention worker active AND its Queue
            // exists), not just "webmention worker is in the active set" — and is written
            // unconditionally on every call (not gated behind `if hasWebmentionReceive`), so a
            // redeploy always reconciles it to the current true state, the same way the
            // D1/KV/R2/Queue TOML blocks above are always regenerated fresh. Without this, a
            // site that later deactivates webmention would keep advertising
            // `<link rel="webmention">` at an endpoint the Worker no longer serves.
            let hasWebmentionReceive = workers.contains(where: { $0.id == WorkerComposition.webmentionWorkerID })
            let webmentionReceiveEnabled = hasWebmentionReceive && resources.queueName != nil
            // Same "actually live" contract for Micropub: the flag gates BaseLayout.astro's
            // `<link rel="micropub">` discovery tag (Micropub/Micro.blog clients — including the
            // Micro.blog iOS/Mac apps — resolve the posting endpoint from that link, per
            // https://book.micro.blog/micropub/). Micropub has no bespoke queue of its own — it
            // rides the shared per-site D1 database (bound as MICROPUB_DB) and R2 bucket (bound
            // as MEDIA), both generic `resources` fields — so "actually live" here means those
            // two ids were actually assigned by provisioning, not just that the worker is in the
            // active set.
            let hasMicropub = workers.contains(where: { $0.id == WorkerComposition.micropubWorkerID })
            let micropubEnabled = hasMicropub && resources.d1DatabaseID != nil && resources.r2BucketName != nil
            // Same "actually live" contract for the WebSub hub: the flag gates the feeds'
            // rel="hub" advertisement (src/lib/feeds.ts), which must never point at an endpoint
            // the Worker doesn't serve or a hub whose Queue doesn't exist.
            let hasWebSub = workers.contains(where: { $0.id == WorkerComposition.websubWorkerID })
            let websubEnabled = hasWebSub && resources.websubQueueName != nil
            let configURL = siteDirectory.appendingPathComponent(".site-config")
            let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            let updated = SiteConfigFile.upsert(
                [
                    ("WEBMENTION_RECEIVE_ENABLED", webmentionReceiveEnabled ? "true" : "false"),
                    ("MICROPUB_ENABLED", micropubEnabled ? "true" : "false"),
                    ("WEBSUB_ENABLED", websubEnabled ? "true" : "false"),
                ], into: existing
            )
            if updated != existing {
                try updated.write(to: configURL, atomically: true, encoding: .utf8)
            }
            return nil
        } catch {
            return .failed(reason: "couldn't write wrangler.toml: \(error)", exitCode: nil)
        }
    }
}

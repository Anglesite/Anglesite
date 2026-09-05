import Foundation

/// Provisions the per-site Cloudflare Worker resources used by the V-2 social layer, then
/// publishes through ``DeployCommand`` so build and pre-deploy security checks stay in path.
///
/// This is the app-side integration seam for `@dwk/workers`: it creates the backing Cloudflare
/// resources with wrangler, writes a concrete `wrangler.toml`, then asks the existing deploy
/// pipeline to build, scan, and deploy the composed Worker.
/// The Worker source itself stays in the template's `worker/worker.ts`; when the upstream
/// `@dwk/*` packages are stable, that file is the only protocol-specific piece that needs to
/// grow imports and route handlers.
public actor SocialWorkerProvisionCommand {
    /// Outcome of one `provision()` run. Every case carries the `resources` provisioned so far
    /// because provisioning is incremental and resumable: a failure partway through must not lose
    /// the D1/KV/R2/Queue ids already created, or a retry would re-create them against wrangler.
    public enum Result: Sendable, Equatable {
        /// Provisioning and the downstream deploy both completed; `url` is the live Worker URL.
        case succeeded(url: URL, resources: WorkerComposition.ProvisionedResources, duration: TimeInterval)
        /// The pre-deploy security gate (``PreDeployCheck``) refused the deploy. Resources were
        /// still provisioned — the gate runs at the deploy stage, after resource creation.
        case blocked(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning], resources: WorkerComposition.ProvisionedResources)
        /// The candidate Worker name is already in use on the connected Cloudflare account by a
        /// project this site's own local config doesn't already claim as its own (`.site-config`'s
        /// `CF_WORKER_DEPLOYED`/`CF_WORKER_PROVISIONED`) — mirrors
        /// `DeployCommand.Result.workerNameConflict` rather than collapsing it, so callers can
        /// drive the same rename-and-retry UX (#740). Checked at the very start of `provision()`,
        /// before any wrangler call runs against the name, so a genuine collision is caught before
        /// this site's own D1/KV/R2/secret provisioning could touch a foreign project (#1075).
        case workerNameConflict(name: String, resources: WorkerComposition.ProvisionedResources)
        /// A Queue-backed worker (inbound Webmention #359, or the WebSub hub #361) is active but
        /// the site hasn't explicitly acknowledged that Cloudflare Queues require the Workers
        /// Paid plan. Returned *before any wrangler call for a Queue* — earlier D1/KV/R2
        /// wrangler calls (and their `persistConfig` writes) may already have run in this same
        /// `provision()` invocation before this gate is reached. `DeployModel` parks the deploy
        /// and presents a confirmation sheet; retrying with `acknowledgesPaidPlan: true`
        /// proceeds to create the Queue(s). (The case keeps its original Webmention-era name;
        /// one acknowledgment covers every Queue-backed feature — it's the same account-level
        /// plan fact.)
        case webmentionPaidPlanConfirmationNeeded(resources: WorkerComposition.ProvisionedResources)
        /// Mirrors `DeployCommand.Result.domainConfigDrift` (#1173) — the downstream deploy's
        /// declared-vs-live check found drift. Resources provisioned before the deploy stage
        /// still ride along, same as `.blocked`.
        case domainConfigDrift(findings: [DomainConfigAudit.Finding], resources: WorkerComposition.ProvisionedResources)
        /// A wrangler call, secret push, or the downstream deploy failed. `exitCode` is `nil` when
        /// the process couldn't run at all (as opposed to running and exiting non-zero).
        case failed(reason: String, exitCode: Int32?, resources: WorkerComposition.ProvisionedResources)
    }

    /// Re-exported from ``DeployCommand`` so both commands share one token-resolution seam
    /// (Keychain in production, injected values in tests).
    public typealias TokenSource = CloudflareDeployTarget.TokenSource
    /// Resolves the Cloudflare account id that owns a token — used only by inbox-capture
    /// provisioning (#764) to persist the id `InboxSubmissionSync` needs later. `nil` on any
    /// resolution failure (mirrors `MicropubContentSync`'s/`ReceivedInteractionSync`'s existing
    /// private `resolveAccountID` helpers, which return an optional rather than throwing — a
    /// missing account id here fails the *step* via a nil-check, not this closure itself). Reused
    /// from `CloudflareDeployTarget` (like `TokenSource` above) rather than a second, independent
    /// definition of the same shape.
    public typealias AccountIDSource = CloudflareDeployTarget.AccountIDSource
    /// Pushes one Cloudflare Worker secret whose value can't travel as a plain CLI argument
    /// (`wrangler secret put <NAME>` reads its value from stdin). Its production conformer
    /// (`ContainerCommandRunner.secretRunner`) runs a small in-guest shell script that reads
    /// `value` from an environment variable rather than stdin — the container-exec seam
    /// (`LocalContainerControl.exec`) is one-shot with no stdin plumbing.
    public typealias SecretRunner = @Sendable (
        _ siteDirectory: URL,
        _ name: String,
        _ value: String,
        _ environment: [String: String],
        _ source: String
    ) async throws -> ProcessSupervisor.RunResult
    /// Produces (generating and persisting on first call, per site) the ActivityPub actor's
    /// signing keypair and publish token. Defaults to the real Keychain via
    /// `ActivityPubKeyProvisioning`; tests inject a fake to avoid touching the real login
    /// keychain and to control the returned values deterministically.
    public typealias KeyPairSource = @Sendable (_ siteID: String) throws -> ActivityPubKeyProvisioning.Secrets
    /// Produces (generating and persisting on first call, per site) the Solid-OIDC OP's ES256
    /// signing key as a JSON private JWK. Defaults to the real Keychain via
    /// `SolidOidcKeyProvisioning`; tests inject a fake to avoid touching the real login keychain
    /// and to control the returned value deterministically — mirrors `KeyPairSource` exactly.
    public typealias SolidOidcSigningKeySource = @Sendable (_ siteID: String) throws -> String
    /// Produces (generating and persisting on first call, per site) `@dwk/webdav`'s app-password
    /// hashing pepper. Defaults to the real Keychain via `SolidOidcKeyProvisioning`; tests inject
    /// a fake, mirroring `KeyPairSource`/`SolidOidcSigningKeySource`.
    public typealias WebdavPepperSource = @Sendable (_ siteID: String) throws -> String

    /// The Cloudflare API token seam this command was constructed with. `nonisolated` (and
    /// public) so callers can reuse the exact same token source for related calls without
    /// hopping onto the actor.
    public nonisolated let tokenSource: TokenSource
    private let executor: any DeployExecutor
    private let keyPairSource: KeyPairSource
    private let solidOidcSigningKeySource: SolidOidcSigningKeySource
    private let webdavPepperSource: WebdavPepperSource
    private let secretRunner: SecretRunner
    private let workerScriptNamesSource: CloudflareDeployTarget.WorkerScriptNamesSource
    private let accountIDSource: AccountIDSource

    /// Creates a provisioner. Every dependency defaults to its production conformer; tests (and
    /// `DeployModel`, which threads its own executor) override only the seams they need.
    public init(
        tokenSource: @escaping TokenSource = CloudflareDeployTarget.keychainTokenSource,
        executor: any DeployExecutor = HostDeployExecutor(),
        keyPairSource: @escaping KeyPairSource = SocialWorkerProvisionCommand.defaultKeyPairSource,
        solidOidcSigningKeySource: @escaping SolidOidcSigningKeySource = SocialWorkerProvisionCommand.defaultSolidOidcSigningKeySource,
        webdavPepperSource: @escaping WebdavPepperSource = SocialWorkerProvisionCommand.defaultWebdavPepperSource,
        secretRunner: @escaping SecretRunner = SocialWorkerProvisionCommand.defaultSecretRunner,
        workerScriptNamesSource: @escaping CloudflareDeployTarget.WorkerScriptNamesSource = CloudflareDeployTarget.defaultWorkerScriptNames,
        /// Same seam shape as `workerScriptNamesSource`; only used by the inbox-capture block
        /// (#764) to persist the owning account id.
        accountIDSource: @escaping AccountIDSource = SocialWorkerProvisionCommand.defaultAccountIDSource
    ) {
        self.tokenSource = tokenSource
        self.executor = executor
        self.keyPairSource = keyPairSource
        self.solidOidcSigningKeySource = solidOidcSigningKeySource
        self.webdavPepperSource = webdavPepperSource
        self.secretRunner = secretRunner
        self.workerScriptNamesSource = workerScriptNamesSource
        self.accountIDSource = accountIDSource
    }

    /// Provisions every Cloudflare resource the active workers need (D1, KV, R2, Queues,
    /// secrets), regenerates `wrangler.toml`, then hands off to `DeployCommand` (via
    /// `SocialWorkerProvisionTarget`) to build, scan, and publish. Idempotent and resumable: each
    /// resource is created only if not already known (from `knownResources`), and config is
    /// persisted after every successful step so a failure partway through never loses ids already
    /// created.
    public func provision(
        siteID: String,
        siteDirectory: URL,
        siteName: String,
        workers: [WorkerDescriptor],
        /// Effective active dynamic-route claims (#746), pre-validated via
        /// `WorkerRouteClaims.activeClaims`. Written into `wrangler.toml` as selective
        /// `[assets].run_worker_first` patterns; empty = no worker-first routes.
        routeClaims: [WorkerRouteClaim] = [],
        /// Resources already known from `SiteSettings.provisionedWorkerResources` (#709) — the
        /// sole source of truth for already-provisioned resource ids. Durable across a worker
        /// being deactivated (which drops its binding block from the generated `wrangler.toml`)
        /// and later reactivated. The default (`.init()`, all-nil) means no resources are known
        /// yet, so every one needed by the active workers is (re-)created.
        knownResources: WorkerComposition.ProvisionedResources = .init(),
        /// The site's best-known public URL (`.site-config`'s `DOMAIN`/`SITE_DOMAIN`/`SITE_URL`,
        /// via `DeployCoordinator.resolveSiteURL`), threaded into `WorkerComposition`'s `SITE_URL`
        /// var. `nil` on a first-ever deploy before any host is known — the composed Worker
        /// degrades gracefully (worker.ts no-ops the queue consumer without it).
        siteURL: String? = nil,
        /// The site's display name (`SiteSettings.displayName`), threaded into the ActivityPub
        /// actor's `AP_DISPLAY_NAME` var via `WorkerComposition.generateWranglerToml`. `nil` when
        /// unknown — the composed Worker's actor document then falls back to a fixed generic
        /// name (`worker.ts`'s concern, not this function's).
        displayName: String? = nil,
        /// The site's ActivityPub handle override (`.site-config`'s `AP_USERNAME`, #1239 —
        /// `DeployCoordinator.resolveActivityPubUsername`), threaded into `AP_USERNAME` via
        /// `WorkerComposition.generateWranglerToml`. `nil` when unset — the composed Worker's
        /// `preferredUsername` then falls back to deriving one from the serving hostname
        /// (`worker.ts`'s concern, not this function's).
        apUsername: String? = nil,
        /// The site's ActivityPub avatar (`DeployCoordinator.resolveActivityPubIcon`, #1771 —
        /// `.site-config`'s `AP_ICON` override or the site's `apple-touch-icon.png`), threaded
        /// into `AP_ICON` via `WorkerComposition.generateWranglerToml`. `nil` when the site has
        /// no image — the composed Worker's actor document then carries no `icon` (`worker.ts`'s
        /// concern, not this function's).
        apIcon: String? = nil,
        /// Explicit per-deploy opt-in that the user has acknowledged inbound Webmention requires
        /// the Cloudflare Workers Paid plan (#359) — `DeployModel` sets this from
        /// `SiteSettings.webmentionReceivePaidPlanAcknowledged` plus the in-flight confirmation
        /// sheet's "Enable & retry" action. Ignored unless a `webmention` worker is active.
        acknowledgesPaidPlan: Bool = false,
        /// Effective active dynamic `/.well-known/` route claims (#746), with owner attribution —
        /// forwarded verbatim to `DeployCommand.deploy`'s pre-build #744 collision check, the same
        /// way `DeployModel.runDeploy` threads `WorkerRouteClaims.wellKnownClaims(routeClaims)`
        /// for the GUI path (#934). Distinct from `routeClaims` above (`[WorkerRouteClaim]`, used
        /// only to compose `wrangler.toml`) because the collision check needs the `OwnedClaim`
        /// wrapper's owner attribution.
        wellKnownDynamicClaims: [WorkerRouteClaims.OwnedClaim] = [],
        /// Whether inbox capture's `/inbox` route should be provisioned this run
        /// (`SiteSettings.inboxCaptureEnabled`, #764). `false` (the default) matches every
        /// existing caller's behavior unchanged — the KV namespace is created (or, if
        /// `knownResources`/a prior `wrangler.toml` already has one, reused) only when `true`.
        inboxCaptureEnabled: Bool = false,
        /// The owner's email address (`DeployCoordinator.resolveInboxForwardEmail`, #1570) that
        /// `/inbox` submissions additionally forward to, alongside the existing KV→git capture.
        /// Forwarded verbatim to `WorkerComposition.generateWranglerToml`, which already ignores
        /// it unless `inboxCaptureEnabled` is `true` and omits the `[[send_email]]` binding for
        /// an implausible value. `nil` (the default) matches every existing caller unchanged.
        inboxForwardEmail: String? = nil,
        /// This site's ActivityPub actor type (V-5.1b, #907; `SiteSettings`'s sibling concept
        /// to `communityActorURL`) — `"Group"` for a hosted community, `nil` for an ordinary
        /// Person actor. Forwarded verbatim to `WorkerComposition.generateWranglerToml`, which
        /// already only emits a var when this is exactly `"Group"`.
        activityPubActorType: String? = nil,
        /// Actor IRIs authorized to moderate this site's Group actor (`SiteSettings.moderators`).
        /// Ignored for a Person actor, same as `WorkerComposition.generateWranglerToml`'s own
        /// `moderators` parameter.
        moderators: [String]? = nil,
        /// The site's currently-declared experiments (`DomainConfig.Experiments.active`, #1270
        /// slice 3) — forwarded to `WorkerComposition.generateWranglerToml` unchanged. Only
        /// entries with `status == "running"` do anything: they extend the D1-provisioning gate
        /// below (so a static-only site's first running experiment still gets the shared
        /// `"\(siteName)-social"` database) and get their `EXPERIMENTS_DB` migration applied
        /// after `wrangler.toml` carries a concrete database id, mirroring the IndieAuth
        /// `AUTH_DB` migration below.
        experiments: [DomainConfig.Experiments.Experiment] = [],
        /// Whether this site's `experimental.mcp` flag is on (#1576, `DeployCoordinator.resolveMCPEnabled`).
        /// Forwarded to `WorkerComposition.generateWranglerToml` unchanged, and — separately —
        /// extends the `SOCIAL_KV` provisioning gate below: a plain-blog site with no
        /// `needsKV`-flagged worker active still needs `SOCIAL_KV` when MCP is on, since
        /// `worker/mcp-server.ts`'s rate limiter binds to it.
        mcpEnabled: Bool = false,
        /// The site's `Config/` directory, forwarded verbatim to `DeployCommand.deploy` — `nil`
        /// skips route-coverage scanning and the deployed-routes snapshot write (#530).
        configDirectory: URL? = nil,
        /// The site's currently published route set, forwarded verbatim to `DeployCommand.deploy`
        /// — used only when `configDirectory` is non-nil.
        currentRoutes: [String] = [],
        /// Forwarded verbatim to `DeployCommand.deploy` so a caller (`DeployModel`) can observe
        /// the pre-deploy security scan's outcome as it happens.
        onPreflight: DeployCommand.PreflightObserver? = nil,
        /// Forwarded verbatim to `DeployCommand.deploy` so a caller can observe the custom-domain
        /// attach step's outcome as it happens.
        onDomainAttach: DeployCommand.DomainAttachObserver? = nil,
        /// Forwarded verbatim to `DeployCommand.deploy` so a caller can observe the Markdown for
        /// Agents step's outcome as it happens.
        onMarkdownForAgents: DeployCommand.MarkdownForAgentsObserver? = nil,
        /// Forwarded verbatim to `DeployCommand.deploy` so a caller can surface deploy progress.
        onProgress: ProgressHandler? = nil
    ) async -> Result {
        let token: String?
        do {
            token = try await tokenSource()
        } catch {
            return .failed(reason: "couldn't read Cloudflare API token: \(error)", exitCode: nil, resources: knownResources)
        }
        guard let token, !token.isEmpty else {
            return .failed(
                reason: "no CLOUDFLARE_API_TOKEN — add it in Settings → Advanced → Credentials, or set the env var",
                exitCode: nil, resources: knownResources)
        }
        guard WorkerComposition.isValidSiteName(siteName) else {
            return .failed(reason: "invalid Worker name: \(siteName)", exitCode: nil, resources: knownResources)
        }

        let target = SocialWorkerProvisionTarget(
            cloudflareTarget: CloudflareDeployTarget(
                tokenSource: { token }, workerScriptNamesSource: workerScriptNamesSource,
                accountIDSource: { apiToken in await self.accountIDSource(apiToken) }),
            siteName: siteName, workers: workers, routeClaims: routeClaims, knownResources: knownResources,
            siteURL: siteURL, displayName: displayName, apUsername: apUsername, apIcon: apIcon,
            acknowledgesPaidPlan: acknowledgesPaidPlan, inboxCaptureEnabled: inboxCaptureEnabled,
            inboxForwardEmail: inboxForwardEmail, activityPubActorType: activityPubActorType,
            moderators: moderators, experiments: experiments, mcpEnabled: mcpEnabled,
            keyPairSource: keyPairSource, solidOidcSigningKeySource: solidOidcSigningKeySource,
            webdavPepperSource: webdavPepperSource, secretRunner: secretRunner, accountIDSource: self.accountIDSource)

        let deployResult = await DeployCommand(target: target, executor: executor).deploy(
            siteID: siteID, siteDirectory: siteDirectory, configDirectory: configDirectory,
            currentRoutes: currentRoutes, wellKnownDynamicClaims: wellKnownDynamicClaims,
            onPreflight: onPreflight, onDomainAttach: onDomainAttach,
            onMarkdownForAgents: onMarkdownForAgents, onProgress: onProgress)
        let finalResources = await target.resources

        switch deployResult {
        case .succeeded(let url, let duration):
            return .succeeded(url: url, resources: finalResources, duration: duration)
        case .blocked(let failures, let warnings):
            return .blocked(failures: failures, warnings: warnings, resources: finalResources)
        case .workerNameConflict(let name):
            return .workerNameConflict(name: name, resources: finalResources)
        case .domainConfigDrift(let findings):
            return .domainConfigDrift(findings: findings, resources: finalResources)
        case .webmentionPaidPlanConfirmationNeeded:
            return .webmentionPaidPlanConfirmationNeeded(resources: finalResources)
        case .failed(let reason, let exitCode):
            return .failed(reason: reason, exitCode: exitCode, resources: finalResources)
        }
    }

    static func extractResourceID(from output: String) -> String? {
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let id = findID(in: json) {
            return id
        }
        let pattern = #""?(?:id|uuid|database_id|namespace_id)"?\s*[:=]\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: output) {
            return String(output[range])
        }
        return nil
    }

    private static func findID(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for key in ["id", "uuid", "database_id", "namespace_id"] {
                if let id = dict[key] as? String, !id.isEmpty {
                    return id
                }
            }
            for child in dict.values {
                if let id = findID(in: child) {
                    return id
                }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let id = findID(in: child) {
                    return id
                }
            }
        }
        return nil
    }

    /// Same host-Node retirement stance as `HostDeployExecutor`'s production default, for the
    /// secret-push seam: fails with a logged explanation instead of spawning; production injects
    /// `ContainerCommandRunner.secretRunner`.
    public static let defaultSecretRunner: SecretRunner = { siteDirectory, name, value, environment, source in
        let reason = HostNodeRetirement.reason("social worker secret provisioning")
        await LogCenter.shared.append(source: source, stream: .stderr, text: reason)
        return ProcessSupervisor.RunResult(stdout: reason, stderr: "", exitCode: 127)
    }

    /// Production ``KeyPairSource``: the real per-site ActivityPub secrets, generated once and
    /// persisted in the platform secret store (Keychain on macOS).
    public static let defaultKeyPairSource: KeyPairSource = { siteID in
        try ActivityPubKeyProvisioning.secrets(siteID: siteID, secretStore: PlatformSecretStore.make())
    }

    /// Production ``SolidOidcSigningKeySource``: the real per-site ES256 signing key from the
    /// platform secret store, generated on first use.
    public static let defaultSolidOidcSigningKeySource: SolidOidcSigningKeySource = { siteID in
        try SolidOidcKeyProvisioning.signingKeyJWK(siteID: siteID, secretStore: PlatformSecretStore.make())
    }

    /// Production ``WebdavPepperSource``: the real per-site WebDAV hashing pepper from the
    /// platform secret store, generated on first use.
    public static let defaultWebdavPepperSource: WebdavPepperSource = { siteID in
        try SolidOidcKeyProvisioning.webdavPepper(siteID: siteID, secretStore: PlatformSecretStore.make())
    }

    /// Default ``AccountIDSource`` for production — forwards to `CloudflareDeployTarget`'s
    /// implementation (like `TokenSource`'s `keychainTokenSource`, this is the same account
    /// resolution every account-scoped seam in this codebase shares) rather than keeping an
    /// independent copy of `try? await HTTPCloudflareClient().accountID(apiToken:)`.
    public static let defaultAccountIDSource: AccountIDSource = CloudflareDeployTarget.defaultAccountIDSource
}

extension SocialWorkerProvisionCommand.Result {
    /// Maps this result onto `DeployCommand.Result`'s shape, dropping the `resources` payload
    /// (no caller surfaces it through this seam) — the shared mapping both `DeployModel.runDeploy`
    /// and `SiteOperations.deployWithWorkerComposition` need after routing every deploy through
    /// `SocialWorkerProvisionCommand.provision`.
    public var asDeployCommandResult: DeployCommand.Result {
        switch self {
        case .succeeded(let url, _, let duration):
            return .succeeded(url: url, duration: duration)
        case .blocked(let failures, let warnings, _):
            return .blocked(failures: failures, warnings: warnings)
        case .workerNameConflict(let name, _):
            return .workerNameConflict(name: name)
        case .domainConfigDrift(let findings, _):
            return .domainConfigDrift(findings: findings)
        case .webmentionPaidPlanConfirmationNeeded:
            return .webmentionPaidPlanConfirmationNeeded
        case .failed(let reason, let exitCode, _):
            return .failed(reason: reason, exitCode: exitCode)
        }
    }
}

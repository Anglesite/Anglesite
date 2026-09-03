import SwiftUI
import AnglesiteCore
import AuthenticationServices

/// SwiftUI-facing wrapper around `DeployCommand`. Drives one deploy at a time and exposes the
/// live log stream, the terminal `Phase`, and the two presentation flags the views consume.
///
/// Subscribes to `LogCenter` for the deploy's lifetime, filtering by source so the drawer only
/// shows wrangler / build output (not unrelated Astro or MCP traffic). Subscription is dropped
/// once the deploy resolves — the drawer keeps the captured `logLines` so the user can read and
/// copy them after dismissal becomes available.
@MainActor
@Observable
final class DeployModel {
    /// Resolves the local-container capability at the moment a deploy actually runs — including
    /// a token-prompt/rename retry — rather than once at dispatch time, so a retry queries the
    /// runtime's current state (via `SiteRuntime.containerCapability`, #823) instead of replaying
    /// a snapshot that may be stale by the time the user finishes the token/rename prompt. Mirrors
    /// `ACPAssistant.ContainerControlProvider` / `SiteAssistantSessionFactory.ContainerControlProvider`.
    typealias ContainerControlProvider = @Sendable () async -> (siteID: String, control: any LocalContainerControl)?

    enum Phase: Equatable {
        case idle
        case running(siteID: String, since: Date)
        case succeeded(url: URL, duration: TimeInterval)
        case failed(reason: String, exitCode: Int32?)
        case blocked(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning])
        case workerNameConflict(name: String)
        case webmentionPaidPlanConfirmationNeeded
        case domainConfigDrift(findings: [DomainConfigAudit.Finding])
    }

    private(set) var phase: Phase = .idle
    /// Captured deploy + build log lines for the current/most-recent run.
    private(set) var logLines: [LogCenter.LogLine] = []
    /// The latest milestone label from the running deploy (drives `DeployDrawerView`'s header
    /// caption, below the title).
    private(set) var currentMilestone: String?
    /// The stable milestone-phase id (`OperationProgress.phase`, e.g. `"deploying"`) behind
    /// `currentMilestone`'s human-readable label — set alongside it at every milestone.
    /// Deliberately NOT cleared at every site `currentMilestone` is: two mid-`.running` resets
    /// (after the build/deploy phase, and after the last post-deploy milestone) clear only the
    /// label, not the phase, so `DeployPanelProgress.filledCount(...)` — which `DeployDrawerView`
    /// feeds this to — never regresses the phase-progress strip while a deploy is still running.
    private(set) var currentMilestonePhase: String?
    /// On-device summary of the most recent *failed* deploy, or nil if none/unavailable.
    private(set) var failureSummary: DeployFailureSummary?
    /// "Code changes not yet deployed" status for the deployed-source bundle (#799). Refreshed
    /// after every successful deploy; `nil` before any deploy has completed this session or when
    /// the check couldn't be performed. `.notConfigured` (no `CF_SOURCE_BUCKET`) is the expected
    /// value for every site today — the drawer only renders a line for `.dirty`.
    private(set) var sourceBundleStatus: SourceBundleStatus?
    /// Outcome of attempting to attach this site's configured "Transfer an existing domain" host
    /// as a Workers Custom Domain (#1077), captured from the deploy's `onDomainAttach` observer.
    /// `nil` before any deploy has completed this session; only ever set on a `.succeeded` deploy.
    private(set) var domainAttachStatus: CustomDomainAttachCommand.Result?
    /// Outcome of applying the Markdown for Agents zone setting (#1247), captured from the
    /// deploy's `onMarkdownForAgents` observer. `nil` before any deploy has completed this
    /// session, or when the deploy never confirmed a custom domain (no zone to apply it to).
    private(set) var markdownForAgentsStatus: MarkdownForAgentsCommand.Result?
    /// Whether the deploy currently in flight (or most recently completed) is this site's first
    /// successful publish — captured from `.site-config`'s `CF_WORKER_DEPLOYED` *before* the
    /// deploy pipeline runs (#1180), so it reflects the site's history going into this attempt,
    /// not the flag `DeployCommand` writes as a side effect of this same deploy succeeding.
    /// `DeployDrawerView` reads this on `.succeeded` to show the one-time "connect a domain?"
    /// nudge — it can structurally never be true again for a site after its first successful
    /// deploy, since that deploy is what sets `CF_WORKER_DEPLOYED`.
    ///
    /// A background/automatic publish (`deployAutomatically`, `presentation: .background`) can
    /// also be a site's first successful deploy, and this flag flips correctly for it. But
    /// `drawerPresented` stays `false` for a background run, so the nudge never gets a chance to
    /// render — and since `wasFirstDeploy` can't be true again afterward, it's silently skipped
    /// forever for that site. Accepted, documented behavior: the permanent
    /// `Website ▸ Connect a Domain…` menu item remains the fallback.
    private(set) var wasFirstDeploy: Bool = false
    /// True while the failure summary is being generated (drives a spinner in the drawer).
    private(set) var summarizing: Bool = false

    /// Bound to a custom slide-up drawer in `SiteWindow`. The view sets this back to false
    /// when the user clicks "Dismiss" (we never auto-close — users want to read the URL).
    var drawerPresented: Bool = false
    /// Bound to a `.sheet` in `SiteWindow` for the `.blocked` outcome. The sheet has no
    /// override button — per CLAUDE.md, the app cannot bypass plugin security hooks.
    var blockedPresented: Bool = false
    /// Bound to a `.sheet` in `SiteWindow` for the first-deploy "paste your Cloudflare token"
    /// flow. Set when `deploy(...)` is invoked without a token in either the env or the
    /// Keychain; cleared when the user saves a token (which then retries the deploy) or cancels.
    var tokenPromptPresented: Bool = false
    /// Bound to a `.sheet` in `SiteWindow` for the first-publish license gate (#999). Set when
    /// `deploy(...)` is invoked and the site's `licensing.json` has never recorded an explicit
    /// license choice. Reuses `pendingDeploy` to park and retry, same as the token-prompt flow.
    /// Wired with `.interactiveDismissDisabled()` in `SiteWindow`: the design is a hard block, so
    /// Esc or a swipe must not bypass it. Backing out is a deliberate button press —
    /// `cancelLicenseGate()` — which abandons this deploy attempt without recording a choice, so
    /// the gate simply fires again next time.
    var licenseGatePresented: Bool = false
    /// Set when saving the chosen policy fails (e.g. an unsafe custom license URL). Cleared on
    /// every fresh presentation and on a successful `confirmLicenseChoice(_:)`.
    private(set) var licenseGateError: String?
    /// Bound to a `.sheet` in `SiteWindow` for the `.workerNameConflict` outcome — the Worker
    /// name is already taken on the connected Cloudflare account and this is the site's first
    /// deploy. Reuses `pendingDeploy` (below) to park and retry, same as the token-prompt flow.
    var workerNameConflictPresented: Bool = false
    /// Set when a rename attempt itself fails (invalid name, or no parked deploy). Cleared on
    /// every fresh presentation and on a successful rename-and-retry.
    private(set) var workerNameConflictError: String?
    /// Bound to a `.sheet` in `SiteWindow` for the `.webmentionPaidPlanConfirmationNeeded`
    /// outcome — inbound Webmention needs a Cloudflare Queue, which requires the Workers Paid
    /// plan. Reuses `pendingDeploy` to park and retry, same as the token-prompt and
    /// worker-name-conflict flows.
    var webmentionPaidPlanConfirmationPresented: Bool = false
    /// Bound to a `.sheet` in `SiteWindow` for the ActivityPub handle-rename confirmation (#1239)
    /// — the resolved handle differs from the last-deployed baseline and the actor has already
    /// federated. Reuses `pendingDeploy` to park and retry, same as the other confirmation
    /// flows; unlike them, `runDeploy` reuses the generic `.failed` `Phase` rather than a
    /// dedicated one (see `runDeploy`'s own comment on this check for why).
    var activityPubHandleRenameConfirmationPresented: Bool = false
    /// The handle change awaiting confirmation on ``activityPubHandleRenameConfirmationPresented``
    /// — `nil` outside that flow.
    private(set) var activityPubHandleRenameChange: (from: String, to: String)?
    /// Bound to a `.sheet` in `SiteWindow` for a `.conflict` domain-attach outcome (#1077) — the
    /// transfer domain is already attached to a *different* Worker. Dismiss-only; doesn't block
    /// the drawer or further deploys, since wrangler already succeeded by the time this runs.
    var domainConflictPresented: Bool = false
    /// Bound to a `.sheet` in `SiteWindow` for the `.domainConfigDrift` outcome (#1173) — the
    /// site's declared `anglesite.json` domain has drifted from its live Cloudflare state.
    /// Dismiss-only, like `blockedPresented`: remediation happens in the Domain Config Audit
    /// sheet (#1171), not here, so there's no `pendingDeploy` retry to park.
    var domainConfigDriftPresented: Bool = false

    /// Progress of the Cloudflare sign-in, consumed by `CloudflareOAuthSignInView`'s status line
    /// and button-enabled logic. The credential is only persisted once verification reaches
    /// `.connected`; a `.failed` state keeps the sheet open and leaves storage untouched. Shared
    /// with `BuyDomainModel` (`CloudflareTokenPromptView.swift`) since the case shape is identical.
    private(set) var tokenVerification: CloudflareTokenVerification = .idle

    /// Fires every time the deploy pipeline's preflight step resolves, with the
    /// `PreDeployCheck.Outcome` that was used to decide whether to continue.
    /// `SiteWindow` wires this to `HealthModel.ingestDeployOutcome` so the health
    /// badge updates whenever a deploy runs — including the .passed and warnings-only
    /// cases that don't surface through `phase`.
    var onScanComplete: ((PreDeployCheck.Outcome) -> Void)?

    /// Fires on every phase change — start and terminal alike — with the site id of the run the
    /// transition belongs to. The id is delivered per-run (not captured at wiring time) so a
    /// window replayed onto a different site can't mis-attribute a still-in-flight deploy's
    /// outcome. `SiteWindowModel` wires this to the completion notifier and Dock progress
    /// (#526); the model stays UserNotifications- and AppKit-free.
    @ObservationIgnored var onPhaseTransition: ((_ siteID: String, _ phase: Phase) -> Void)?
    /// Fires (on the main actor) for each structured milestone of the identified run, after
    /// `currentMilestone` updates. Drives the determinate Dock-tile progress bar (#526).
    @ObservationIgnored var onMilestone: ((_ siteID: String, _ progress: OperationProgress) -> Void)?

    private let command: DeployCommand
    private let webmentionCommand: WebmentionSendCommand
    private let standardSitePublishCommand: StandardSitePublishCommand
    private let standardSiteGraphPublishCommand: StandardSiteGraphPublishCommand
    private let posseCommand: POSSESyndicationCommand
    private let websubPing: WebSubPublishPing
    private let activityPubOutboxBackfill: ActivityPubOutboxBackfill
    private let logCenter: LogCenter
    private let keychain: any SecretStore
    private let onboarding: TokenOnboarding
    private let oauthSignIn: CloudflareOAuthSignIn
    private let summarizer: any DeployFailureSummarizing
    private let contentGraph: SiteContentGraph
    /// Returns the current `@dwk/workers` catalog. Defaults to `{ [] }` (no network, no active
    /// settings-activated workers ever computed) so existing tests that don't inject one keep
    /// deploying exactly as before — production wiring (`SiteWindowModel`) passes a real
    /// `WorkerCatalogFetcher(catalogURL: WorkerCatalogFetcher.productionCatalogURL).catalog`.
    private let workerCatalog: @Sendable () async -> [WorkerDescriptor]
    /// Bumped at the start of every `runDeploy`. The async failure-summarization captures the
    /// value at dispatch and only writes its result back if it still matches — so a summary from
    /// a superseded deploy can't stomp the current deploy's state, even though
    /// `generateStructured` doesn't honour cooperative cancellation.
    private var summarizationGeneration: UInt = 0
    private var inFlight: Task<Void, Never>?
    private let suddenTerminationController: SuddenTerminationController
    private let tokenAvailabilityOverride: (() -> Bool)?
    /// Site to retry once the user takes the action a parked deploy is waiting on — either
    /// signing in to Cloudflare via OAuth (`signInWithCloudflare`) or renaming a taken Worker name
    /// (`renameWorkerAndRetry`). `nil` outside both prompt flows. Carries the container control
    /// (if any) so the parked-then-retried deploy uses the same executor as the original dispatch.
    private var pendingDeploy: (
        siteID: String,
        siteDirectory: URL,
        configDirectory: URL,
        currentRoutes: [String],
        containerControlProvider: ContainerControlProvider,
        siteName: String?
    )?

    private enum Presentation: Equatable {
        case foreground
        case background
    }

    init(
        command: DeployCommand = DeployCommand(),
        webmentionCommand: WebmentionSendCommand = WebmentionSendCommand(),
        standardSitePublishCommand: StandardSitePublishCommand = StandardSitePublishCommand(),
        standardSiteGraphPublishCommand: StandardSiteGraphPublishCommand = StandardSiteGraphPublishCommand(),
        posseCommand: POSSESyndicationCommand = POSSESyndicationCommand(),
        websubPing: WebSubPublishPing = WebSubPublishPing(),
        activityPubOutboxBackfill: ActivityPubOutboxBackfill = ActivityPubOutboxBackfill(),
        logCenter: LogCenter = .shared,
        keychain: any SecretStore = KeychainStore(),
        verifier: TokenVerifying = CloudflareAPITokenVerifier(),
        oauthSignIn: CloudflareOAuthSignIn = CloudflareOAuthSignIn(
            client: CloudflareOAuthClient(scope: AnglesiteTokenTemplate.oauthScope),
            present: CloudflareOAuthSignIn.defaultPresenter),
        summarizer: any DeployFailureSummarizing = DeploySummarizerFactory.makeDefault(),
        suddenTerminationController: SuddenTerminationController = .shared,
        tokenAvailabilityOverride: (() -> Bool)? = nil,
        contentGraph: SiteContentGraph = SiteContentGraph(),
        workerCatalog: @escaping @Sendable () async -> [WorkerDescriptor] = { [] }
    ) {
        self.command = command
        self.webmentionCommand = webmentionCommand
        self.standardSitePublishCommand = standardSitePublishCommand
        self.standardSiteGraphPublishCommand = standardSiteGraphPublishCommand
        self.posseCommand = posseCommand
        self.websubPing = websubPing
        self.activityPubOutboxBackfill = activityPubOutboxBackfill
        self.logCenter = logCenter
        self.keychain = keychain
        self.onboarding = TokenOnboarding(verifier: verifier)
        self.oauthSignIn = oauthSignIn
        self.summarizer = summarizer
        self.suddenTerminationController = suddenTerminationController
        self.tokenAvailabilityOverride = tokenAvailabilityOverride
        self.contentGraph = contentGraph
        self.workerCatalog = workerCatalog
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// True while a foreground sheet is presented and awaiting the user's response to a prior
    /// deploy's outcome — a worker-name-conflict rename, a paid-plan confirmation, or the
    /// no-override security-block modal. `phase` leaves `.running` as soon as one of these is
    /// presented, so `isRunning` alone doesn't guard against a second deploy starting concurrently:
    /// `runDeploy` unconditionally resets `blockedPresented` to `false` at the very start of every
    /// run (foreground or background), and every terminal case in its result switch unconditionally
    /// writes `workerNameConflictPresented`/`webmentionPaidPlanConfirmationPresented` for *its own*
    /// outcome — so a second run's start or resolution would silently clobber a foreground sheet
    /// the user is still looking at (#1076). Most visibly, `deployAutomatically`'s invisible publish
    /// queue (#357) firing moments after a manual deploy parks on one of these dismisses it before
    /// the user can act, since the background run's own reset/outcome always presents as `false`.
    private var awaitingUserAction: Bool {
        workerNameConflictPresented || webmentionPaidPlanConfirmationPresented || blockedPresented
            || domainConfigDriftPresented || activityPubHandleRenameConfirmationPresented
    }

    /// Why calling `deploy(...)` right now would *not* run a deploy through to a terminal phase —
    /// `nil` when it would. Each case below is one of `deploy(...)`'s own silent early returns (or,
    /// for `awaitingUserAction`, a prompt already on screen that a second run would clobber): the
    /// call no-ops or parks in `pendingDeploy` behind a sheet, leaving `phase` where it was.
    ///
    /// Most callers don't need this — Deploy is a button in the window, so parking behind the
    /// token/license sheet *is* the flow. It exists for callers that show their own "starting…"
    /// state keyed off `phase` and would otherwise wait forever for a transition that never comes,
    /// and whose own sheet is what blocks the parked prompt from presenting (`ExperimentStatsModel`,
    /// #1518). The returned text is owner-facing.
    func deployUnavailableReason(siteDirectory: URL) -> String? {
        if isRunning || awaitingUserAction {
            return "Your site is already publishing. Wait for that to finish, then try again."
        }
        if !hasUsableToken() {
            return "Anglesite needs your Cloudflare sign-in before it can publish. Close this and choose Publish to sign in, then start your test."
        }
        if !hasChosenLicense(siteDirectory: siteDirectory) {
            return "Choose how visitors may reuse your content first. Close this and choose Publish to pick a license, then start your test."
        }
        return nil
    }

    /// Renders the captured log lines as plain text for the "Copy log" affordance on failure.
    var logText: String {
        logLines.map(\.text).joined(separator: "\n")
    }

    /// Kicks off a deploy. No-op if one is already running.
    ///
    /// `containerControlProvider` is invoked inside `runDeploy` at the moment the deploy actually
    /// runs (#823): when it resolves non-nil the deploy runs inside the already-started container
    /// via `ContainerDeployExecutor`; otherwise the default executor reports that the container
    /// runtime is required. The provider itself — not a resolved snapshot — is threaded through
    /// the pending-deploy flow, so a token-prompt retry re-resolves against the runtime's current
    /// state instead of an executor built from a possibly-stale earlier snapshot.
    ///
    /// First checks whether a Cloudflare token is available (env > OAuth > legacy Keychain). If
    /// none has one, the token-prompt sheet is presented and the deploy is parked until the user
    /// signs in via `signInWithCloudflare()` — at which point the parked site is dispatched
    /// without the user having to click Deploy again.
    func deploy(
        siteID: String,
        siteDirectory: URL,
        configDirectory: URL,
        currentRoutes: [String],
        containerControlProvider: @escaping ContainerControlProvider = { nil },
        siteName: String? = nil
    ) {
        guard !isRunning else { return }
        if !hasUsableToken() {
            pendingDeploy = (siteID, siteDirectory, configDirectory, currentRoutes, containerControlProvider, siteName)
            tokenVerification = .idle
            tokenPromptPresented = true
            return
        }
        if !hasChosenLicense(siteDirectory: siteDirectory) {
            pendingDeploy = (siteID, siteDirectory, configDirectory, currentRoutes, containerControlProvider, siteName)
            licenseGateError = nil
            licenseGatePresented = true
            return
        }
        // Flip `phase` synchronously, before scheduling the Task, so a second `deploy()` call
        // on the same actor hop (e.g. a rapid re-invocation before this Task starts running)
        // sees `isRunning == true` and bails via the guard above instead of racing runDeploy.
        phase = .running(siteID: siteID, since: Date())
        let suddenTerminationLease = suddenTerminationController.acquire()
        inFlight = Task { @MainActor [weak self, suddenTerminationLease] in
            _ = await self?.runDeploy(
                siteID: siteID, siteDirectory: siteDirectory,
                configDirectory: configDirectory, currentRoutes: currentRoutes,
                containerControlProvider: containerControlProvider,
                suddenTerminationLease: suddenTerminationLease,
                presentation: .foreground,
                siteName: siteName)
        }
    }

    /// Runs the same ordered publish pipeline without presenting foreground drawers, token sheets,
    /// or the security-block modal. The durable invisible-publish queue uses the returned result to
    /// decide whether its pending marker may be cleared. Terminal transitions still fire, so
    /// completion and security-block notifications use the normal app notification path.
    ///
    /// Also never raises the Keychain's own authorization dialog: the credential presence check
    /// runs through the store's `withoutUserInteraction` face, deferring instead when a stored
    /// credential would need the user's OK to read (#1717).
    func deployAutomatically(
        siteID: String,
        siteDirectory: URL,
        configDirectory: URL,
        currentRoutes: [String],
        containerControlProvider: @escaping ContainerControlProvider,
        siteName: String? = nil
    ) async -> InvisiblePublishQueue.Result {
        guard !isRunning else { return .deferred(reason: "another site operation is running") }
        guard !awaitingUserAction else { return .deferred(reason: "a deploy prompt is waiting for a response") }
        // Non-interactive on purpose: this runs after every `Source/` edit (the #357 invisible
        // publish queue), and a Keychain read that can raise the login-keychain authorization
        // dialog would turn each Duplicate/Delete/New Post into a system password prompt (#1717).
        // A credential the app isn't authorized to read silently is left for the user's next
        // Publish click, which reads interactively and may prompt — once, with "Always Allow".
        switch credentialAvailability(allowingUserInteraction: false) {
        case .available:
            break
        case .missing:
            return .deferred(reason: "Cloudflare credentials are not configured")
        case .needsUserInteraction:
            await logCenter.append(
                source: "deploy:\(siteID)", stream: .stderr,
                text: "Background publish skipped: reading the Cloudflare sign-in from the keychain would need your permission. Choose Publish to grant it once.")
            return .deferred(reason: "Anglesite needs your permission to read the Cloudflare sign-in from the keychain — choose Publish to grant it")
        }
        guard hasChosenLicense(siteDirectory: siteDirectory) else {
            return .deferred(reason: "a content license hasn't been chosen yet")
        }
        // Resolved once (there's no user-facing prompt gap on this background path to make a
        // second resolution meaningfully fresher) and reused both for the readiness guard and the
        // actual run, so the two can't disagree about whether a container is available.
        let resolvedContainerControl = await containerControlProvider()
        guard resolvedContainerControl != nil else { return .deferred(reason: "the site runtime is not ready") }

        phase = .running(siteID: siteID, since: Date.now)
        let lease = suddenTerminationController.acquire()
        let result = await runDeploy(
            siteID: siteID,
            siteDirectory: siteDirectory,
            configDirectory: configDirectory,
            currentRoutes: currentRoutes,
            containerControlProvider: { resolvedContainerControl },
            suddenTerminationLease: lease,
            presentation: .background,
            siteName: siteName
        )
        switch result {
        case .succeeded(let url, _):
            return .succeeded(url: url)
        case .blocked(let failures, _):
            return .blocked(failureCount: failures.count)
        case .workerNameConflict(let name):
            return .failed(reason: "Worker name \"\(name)\" is already in use on your Cloudflare account — rename it in the app and publish again.")
        case .domainConfigDrift(let findings):
            return .failed(reason: "\(findings.count) declared domain configuration item(s) don't match your live Cloudflare setup — review the Domain Config Audit in the app and deploy again.")
        case .failed(let reason, _):
            return .failed(reason: reason)
        }
    }

    /// Called by the sign-in sheet's "Sign in with Cloudflare" button. Runs the OAuth flow,
    /// verifies the resulting access token against Cloudflare exactly as a pasted token was
    /// verified — `TokenOnboarding` can't tell the two apart, since both are just Cloudflare API
    /// bearer tokens — then persists the full credential (access + refresh + expiry) and dispatches
    /// the parked deploy.
    func signInWithCloudflare() async {
        guard let pending = pendingDeploy else {
            tokenVerification = .failed(message: "Nothing is waiting to publish — close this and click Publish Site again.")
            return
        }

        tokenVerification = .checking
        let signInResult: CloudflareOAuthSignIn.Result
        do {
            signInResult = try await oauthSignIn.run()
        } catch CloudflareOAuthPresentationError.sessionFailedToStart {
            // The browser sheet never presented — not a user cancel. Most commonly a Debug build
            // signed without the Associated Domains entitlement that `.https(host:path:)` callback
            // matching needs (#1766). Unlike a real cancel, this is worth a developer-facing
            // message and a Debug-pane line, since there's otherwise no way to learn why sign-in
            // silently went nowhere.
            await logCenter.append(
                source: "cloudflare-oauth-sign-in", stream: .stderr,
                text: "Cloudflare sign-in session failed to start — this build likely lacks the "
                    + "Associated Domains entitlement (com.apple.developer.associated-domains) "
                    + "that OAuth callback matching needs.")
            tokenVerification = .failed(message: """
                Cloudflare sign-in needs the Associated Domains entitlement, which this build \
                doesn't carry (common on an ad-hoc Debug build). Sign the build with a real Team \
                (see xcconfig/Signing-Debug.local.xcconfig.example) or paste a legacy Cloudflare \
                API token in Settings ▸ Advanced ▸ Credentials.
                """)
            return
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // The user dismissed the browser sheet — same "no error banner" treatment a dismissed
            // paste sheet got.
            tokenVerification = .idle
            return
        } catch CloudflareOAuthError.callbackDenied {
            // The user declined on Cloudflare's own consent screen — same treatment as cancelling
            // the sheet itself, not a connection failure.
            tokenVerification = .idle
            return
        } catch {
            // Includes `.stateMismatch` — a hard, generic failure, never silently accepted. The
            // raw error can carry a Cloudflare API response body (e.g. `tokenExchangeFailed`'s
            // HTTP detail) that isn't fit to show a non-technical site owner, so only a
            // plain-language message reaches the UI; the real error goes to the log instead.
            await logCenter.append(
                source: "cloudflare-oauth-sign-in", stream: .stderr,
                text: "Cloudflare sign-in failed: \(error)")
            tokenVerification = .failed(message: "Couldn't sign in to Cloudflare. Try again in a moment.")
            return
        }

        let outcome = await onboarding.run(
            token: signInResult.token.accessToken,
            siteDirectory: pending.siteDirectory,
            persist: { _ in
                try keychain.writeCloudflareOAuthCredential(CloudflareOAuthCredential(
                    accessToken: signInResult.token.accessToken,
                    refreshToken: signInResult.token.refreshToken,
                    expiresAt: signInResult.token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
                    tokenEndpoint: signInResult.tokenEndpoint))
            },
            onConnected: { tokenVerification = .connected(accountName: $0.name) },
            delay: { try? await Task.sleep(for: .milliseconds(700)) },
            isCancelled: { Task.isCancelled || !tokenPromptPresented }
        )

        switch outcome {
        case .proceed:
            pendingDeploy = nil
            tokenPromptPresented = false
            tokenVerification = .idle
            deploy(
                siteID: pending.siteID, siteDirectory: pending.siteDirectory,
                configDirectory: pending.configDirectory, currentRoutes: pending.currentRoutes,
                containerControlProvider: pending.containerControlProvider, siteName: pending.siteName)
        case .stay(let message):
            tokenVerification = .failed(message: message)
        case .abort:
            tokenVerification = .idle
        }
    }

    func cancelTokenPrompt() {
        pendingDeploy = nil
        tokenPromptPresented = false
        tokenVerification = .idle
    }

    /// The licensing policy of the deploy currently parked on the license gate — `nil` when no
    /// deploy is parked. `LicenseGateSheetView` reads it on appear to seed its selection, so a
    /// license the site already records is re-affirmed by Continue rather than replaced by the
    /// sheet's own default. A missing or malformed `licensing.json` degrades to the empty policy,
    /// the same fail-safe `hasChosenLicense(siteDirectory:)` relies on.
    var pendingLicensingPolicy: LicensingPolicy? {
        guard let pending = pendingDeploy else { return nil }
        return (try? LicensingStore(sourceDirectory: pending.siteDirectory).load()) ?? LicensingPolicy()
    }

    /// Called by `LicenseGateSheetView`'s Continue button. Builds the policy from `license`
    /// (`nil` means "All rights reserved"), fills only unset AI-usage purposes via
    /// `LicenseCatalog.prefilled` (matching `ContentLicensingTab`'s own picker behavior, so this
    /// never clobbers a manual override made later), marks the choice made, and saves — then
    /// resumes the parked deploy. Owns its own `LicensingStore` directly rather than going
    /// through `PlistEditorModel`, so the gate works with no Settings window open.
    ///
    /// `async` only for the failure path's log write: the raw error is developer-facing (it can
    /// carry an unusable-URL payload), so the plain-language message goes to the sheet and the
    /// real error goes to the log — awaited before returning, exactly as the Cloudflare sign-in
    /// failure path does, so it can't be dropped by app termination.
    func confirmLicenseChoice(_ license: LicenseRef?) async {
        guard let pending = pendingDeploy else {
            licenseGateError = "Nothing is waiting to publish — close this and click Publish Site again."
            return
        }
        let store = LicensingStore(sourceDirectory: pending.siteDirectory)
        var policy = (try? store.load()) ?? LicensingPolicy()
        policy.defaultLicense = license
        policy.usage = LicenseCatalog.prefilled(policy.usage, for: license)
        policy.licenseChosen = true
        do {
            try store.save(policy)
        } catch let error as LicensingStore.ValidationError {
            // Mirrors `PlistEditorModel.saveLicensing()`'s treatment of the same error, so the
            // two paths that can write this policy say the same thing about a bad address.
            switch error {
            case .unsafeLicenseURL(let url):
                await logCenter.append(
                    source: "license-gate:\(pending.siteID)", stream: .stderr,
                    text: "Refused to save an unsafe license URL: \(error)")
                licenseGateError = "\"\(url)\" isn't a usable license address. Use an https:// URL or a path on this site starting with /."
            }
            return
        } catch {
            await logCenter.append(
                source: "license-gate:\(pending.siteID)", stream: .stderr,
                text: "Saving the content license failed: \(error)")
            licenseGateError = "Couldn't save your license choice: \(error.localizedDescription)"
            return
        }
        pendingDeploy = nil
        licenseGateError = nil
        licenseGatePresented = false
        deploy(
            siteID: pending.siteID, siteDirectory: pending.siteDirectory,
            configDirectory: pending.configDirectory, currentRoutes: pending.currentRoutes,
            containerControlProvider: pending.containerControlProvider, siteName: pending.siteName)
    }

    /// Called by the worker-name-conflict sheet's "Rename & retry" button. Applies the rename to
    /// `wrangler.toml`/`.site-config` via `WorkerNameRename.apply`, then retries the parked
    /// deploy — which re-runs the collision check against the new name and loops back to this
    /// same sheet if it's also taken.
    func renameWorkerAndRetry(_ newName: String) async {
        guard let pending = pendingDeploy else {
            workerNameConflictError = "Nothing is waiting to publish — close this and click Publish Site again."
            return
        }
        do {
            try WorkerNameRename.apply(newName: newName, siteDirectory: pending.siteDirectory)
        } catch let error as WorkerNameRename.RenameError {
            switch error {
            case .invalidName:
                workerNameConflictError = "Worker names can only contain lowercase letters, numbers, hyphens, and underscores."
            case .wranglerConfigMissing:
                workerNameConflictError = "Couldn't find this site's wrangler.toml — try publishing again."
            case .nameLineNotFound:
                workerNameConflictError = "This site's wrangler.toml is missing its Worker name — try publishing again."
            }
            return
        } catch {
            workerNameConflictError = "Couldn't rename the Worker: \(error)"
            return
        }
        pendingDeploy = nil
        workerNameConflictError = nil
        // Deliberately NOT clearing `workerNameConflictPresented` here — the sheet stays open
        // (showing its current content) while the retried deploy runs. `runDeploy`'s `.succeeded`/
        // `.failed`/`.blocked` cases dismiss it once the outcome is known; its `.workerNameConflict`
        // case leaves it presented with the new taken name. Clearing it eagerly here, before the
        // retry even starts, would dismiss-then-re-present the sheet on a loop-back (the new name
        // is also taken) — a visible flash instead of the taken-name text updating in place.
        deploy(
            siteID: pending.siteID, siteDirectory: pending.siteDirectory,
            configDirectory: pending.configDirectory, currentRoutes: pending.currentRoutes,
            containerControlProvider: pending.containerControlProvider, siteName: pending.siteName)
    }

    /// Abandons *this* deploy attempt without recording a license choice — the gate's Cancel
    /// button, for a Deploy pressed by mistake. Nothing is saved, so the gate fires again on the
    /// next Deploy: publishing still can't happen without an explicit choice, exactly as the
    /// token-prompt and worker-name-conflict sheets have Cancel without weakening what they gate.
    func cancelLicenseGate() {
        pendingDeploy = nil
        licenseGatePresented = false
        licenseGateError = nil
    }

    func cancelWorkerNameConflictPrompt() {
        pendingDeploy = nil
        workerNameConflictPresented = false
        workerNameConflictError = nil
    }

    /// Dismisses the domain-conflict sheet (#1077). The deploy already succeeded — this only
    /// clears the informational sheet, it doesn't retry or change anything.
    func dismissDomainConflict() {
        domainConflictPresented = false
    }

    /// Dismisses the domain-config-drift sheet (#1173). Like `dismissDomainConflict`, this only
    /// clears the informational sheet — reconciling the drift happens in the Domain Config Audit
    /// sheet, which the sheet's "Review" button opens directly (wired in `SiteWindow`).
    func dismissDomainConfigDrift() {
        domainConfigDriftPresented = false
    }

    /// Called by the paid-plan confirmation sheet's "Enable & retry" button. Persists the
    /// acknowledgment into `SiteSettings` (so future deploys never re-prompt) and retries the
    /// parked deploy — `runDeploy` re-reads settings and passes `acknowledgesPaidPlan: true`
    /// into `SocialWorkerProvisionCommand.provision`, which then creates the Queue.
    func acknowledgeWebmentionPaidPlanAndRetry() async {
        guard let pending = pendingDeploy else { return }
        let configStore = SiteConfigStore(configDirectory: pending.configDirectory)
        var settings = (try? await configStore.load()) ?? SiteSettings()
        settings.webmentionReceivePaidPlanAcknowledged = true
        try? await configStore.save(settings)
        pendingDeploy = nil
        // Deliberately NOT clearing webmentionPaidPlanConfirmationPresented here — mirrors
        // renameWorkerAndRetry's identical reasoning: the sheet stays open while the retried
        // deploy runs, and runDeploy's terminal cases dismiss it once the outcome is known.
        deploy(
            siteID: pending.siteID, siteDirectory: pending.siteDirectory,
            configDirectory: pending.configDirectory, currentRoutes: pending.currentRoutes,
            containerControlProvider: pending.containerControlProvider, siteName: pending.siteName)
    }

    func cancelWebmentionPaidPlanConfirmation() {
        pendingDeploy = nil
        webmentionPaidPlanConfirmationPresented = false
    }

    /// Called by the handle-rename confirmation sheet's "Keep `@old@…`" button (#1239). Reverts
    /// `.site-config`'s `AP_USERNAME` to the pre-change handle (removing the key entirely when
    /// that handle is just the hostname default, matching `PlistEditorModel.saveActivityPubUsername`'s
    /// own dedup), then retries the parked deploy — which re-resolves to the reverted handle, so
    /// `runDeploy`'s check passes without needing an acknowledgment.
    func keepCurrentActivityPubHandleAndRetry() async {
        guard let pending = pendingDeploy, let change = activityPubHandleRenameChange else { return }
        let defaultUsername = DeployCoordinator.defaultActivityPubUsername(siteDirectory: pending.siteDirectory)
        let configURL = pending.siteDirectory.appendingPathComponent(".site-config")
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updated = change.from == defaultUsername
            ? SiteConfigFile.remove(["AP_USERNAME"], from: existing)
            : SiteConfigFile.upsert([("AP_USERNAME", change.from)], into: existing)
        if updated != existing {
            try? updated.write(to: configURL, atomically: true, encoding: .utf8)
        }
        pendingDeploy = nil
        activityPubHandleRenameChange = nil
        // Deliberately NOT clearing activityPubHandleRenameConfirmationPresented here — mirrors
        // renameWorkerAndRetry's identical reasoning: the sheet stays open while the retried
        // deploy runs, and runDeploy's terminal cases dismiss it once the outcome is known.
        deploy(
            siteID: pending.siteID, siteDirectory: pending.siteDirectory,
            configDirectory: pending.configDirectory, currentRoutes: pending.currentRoutes,
            containerControlProvider: pending.containerControlProvider, siteName: pending.siteName)
    }

    /// Called by the handle-rename confirmation sheet's "Switch to `@new@…`" button (#1239).
    /// Persists the acknowledgment into `SiteSettings` (keyed to this exact handle — a
    /// *different* future rename still prompts) and retries the parked deploy.
    func useNewActivityPubHandleAndRetry() async {
        guard let pending = pendingDeploy, let change = activityPubHandleRenameChange else { return }
        let configStore = SiteConfigStore(configDirectory: pending.configDirectory)
        var settings = (try? await configStore.load()) ?? SiteSettings()
        settings.activityPubHandleRenameAcknowledged = change.to
        try? await configStore.save(settings)
        pendingDeploy = nil
        activityPubHandleRenameChange = nil
        // Deliberately NOT clearing activityPubHandleRenameConfirmationPresented here — same
        // reasoning as keepCurrentActivityPubHandleAndRetry above.
        deploy(
            siteID: pending.siteID, siteDirectory: pending.siteDirectory,
            configDirectory: pending.configDirectory, currentRoutes: pending.currentRoutes,
            containerControlProvider: pending.containerControlProvider, siteName: pending.siteName)
    }

    func cancelActivityPubHandleRenameConfirmation() {
        pendingDeploy = nil
        activityPubHandleRenameChange = nil
        activityPubHandleRenameConfirmationPresented = false
    }

    func dismissDrawer() {
        drawerPresented = false
    }

    func dismissBlocked() {
        blockedPresented = false
    }

    /// What `credentialAvailability(allowingUserInteraction:)` found. Split out from the plain
    /// `hasUsableToken()` Bool for the one caller that has to tell "nothing stored" apart from "a
    /// credential the app may not read without asking" (#1717).
    enum CredentialAvailability: Equatable {
        /// A usable credential is reachable right now.
        case available
        /// Nothing usable is stored or configured in the environment.
        case missing
        /// A credential slot exists but reading it would need the user's authorization (the
        /// login-keychain ACL dialog), which the caller didn't allow. Only produced with
        /// `allowingUserInteraction: false`.
        case needsUserInteraction
    }

    /// True if the env var, a stored OAuth credential, or the legacy pasted-token slot currently
    /// holds a usable Cloudflare credential. Keychain errors are treated as "no token" — the
    /// user can recover by signing in again. A stored OAuth credential counts as usable unless
    /// it's *definitely* unrefreshable (expired with no refresh token, e.g. because Cloudflare's
    /// OAuth doesn't issue one for this client) — in that dead-end case this falls through to the
    /// next check instead, so the sign-in sheet re-presents rather than deploys failing forever
    /// with a generic "no token" error. An expired credential that still has a refresh token is
    /// left to `CloudflareDeployTarget.keychainTokenSource` to actually refresh (this is a presence check
    /// only — no refresh attempted here, since it's synchronous).
    ///
    /// Interactive: the Keychain may raise its authorization dialog. That is right for the
    /// foreground callers (`deploy()`, `deployUnavailableReason`) — the user just clicked — and
    /// wrong for `deployAutomatically`, which uses `credentialAvailability(allowingUserInteraction:
    /// false)` instead.
    private func hasUsableToken() -> Bool {
        credentialAvailability(allowingUserInteraction: true) == .available
    }

    /// The presence check behind `hasUsableToken()`, with control over whether the Keychain may
    /// prompt. With `allowingUserInteraction: false` every read goes through the store's
    /// `withoutUserInteraction` face, and a read the user would have to authorize reports
    /// ``CredentialAvailability/needsUserInteraction`` rather than being mistaken for "nothing
    /// stored" (#1717). Any other Keychain failure still reads as `.missing`, as it always has.
    private func credentialAvailability(allowingUserInteraction: Bool) -> CredentialAvailability {
        if let tokenAvailabilityOverride {
            return tokenAvailabilityOverride() ? .available : .missing
        }
        if let env = ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"], !env.isEmpty {
            return .available
        }
        let store = allowingUserInteraction ? keychain : keychain.withoutUserInteraction
        var needsUserInteraction = false
        do {
            if let credential = try store.readCloudflareOAuthCredential() {
                let isDefinitelyUnrefreshable = credential.refreshToken == nil
                    && (credential.expiresAt.map { $0 <= Date() } ?? false)
                if !isDefinitelyUnrefreshable {
                    return .available
                }
            }
        } catch let error as KeychainStore.Error where error.requiresUserInteraction {
            needsUserInteraction = true
        } catch {
            // Every other Keychain failure reads as "no credential" — the user recovers by
            // signing in again.
        }
        do {
            if let stored = try store.readCloudflareToken(), !stored.isEmpty {
                return .available
            }
        } catch let error as KeychainStore.Error where error.requiresUserInteraction {
            needsUserInteraction = true
        } catch {
            // As above.
        }
        return needsUserInteraction ? .needsUserInteraction : .missing
    }

    /// Whether `siteDirectory`'s `licensing.json` records an explicit license choice (#999). A
    /// missing file or an unreadable/malformed document both read as "not chosen" —
    /// `LicensingStore.load()` already degrades every malformed shape to the empty policy, whose
    /// `licenseChosen` is `false`, so this mirrors that same fail-safe default rather than adding
    /// a second one.
    private func hasChosenLicense(siteDirectory: URL) -> Bool {
        (try? LicensingStore(sourceDirectory: siteDirectory).load())?.licenseChosen ?? false
    }

    /// Set `phase` and notify the transition hook. All of `runDeploy`'s phase changes route
    /// through here; the synchronous pre-Task `.running` set in `deploy(...)` intentionally does
    /// not (it exists only to close a re-entrancy race and is immediately superseded by
    /// `runDeploy`'s own `.running`), so consumers see exactly one start transition per run.
    private func transition(siteID: String, to newPhase: Phase) {
        phase = newPhase
        onPhaseTransition?(siteID, newPhase)
    }

    private func runDeploy(
        siteID: String,
        siteDirectory: URL,
        configDirectory: URL,
        currentRoutes: [String],
        containerControlProvider: @escaping ContainerControlProvider = { nil },
        suddenTerminationLease: SuddenTerminationController.Lease,
        presentation: Presentation,
        siteName: String? = nil
    ) async -> DeployCommand.Result {
        defer { suddenTerminationLease.release() }
        transition(siteID: siteID, to: .running(siteID: siteID, since: Date()))
        wasFirstDeploy = !CloudflareDeployTarget.hasDeployedBefore(siteDirectory: siteDirectory)
        logLines = []
        currentMilestone = nil
        currentMilestonePhase = nil
        failureSummary = nil
        summarizing = false
        summarizationGeneration &+= 1   // invalidate any still-in-flight summary from a prior deploy
        // Captured immediately after the bump — the authoritative "my generation" value for
        // this call's summarization branch. Must NOT be re-read later via the live field, which
        // may have moved on if a second `runDeploy` call started concurrently (see guard below).
        let myGeneration = summarizationGeneration
        drawerPresented = presentation == .foreground
        blockedPresented = false
        domainConflictPresented = false
        domainConfigDriftPresented = false

        let sources = DeployCoordinator.deployLogSources(siteID: siteID)

        // Subscribe BEFORE the deploy starts so we can't miss early build lines.
        let subscription = await logCenter.subscribe()
        let logTask = Task { @MainActor [weak self] in
            for await line in subscription.stream where sources.contains(line.source) {
                self?.logLines.append(line)
            }
        }

        // Resolved here, at the moment this deploy attempt actually runs, rather than threaded in
        // as a pre-resolved value (#823) — a token-prompt/rename retry re-invokes the same
        // provider, so it sees the runtime's current container state instead of a snapshot taken
        // back when the sheet was first presented.
        let containerControl = await containerControlProvider()

        // Where this site publishes (#1682) — resolved exactly once per deploy attempt, right
        // here, and then *pinned* into `activeCommand` below so every consumer downstream (the
        // `SocialWorkerProvisionCommand` closures built from the Cloudflare downcast, and
        // `DeployCommand.deploy`'s own authorize-then-publish pair) provably sees the same
        // conformer. The production resolver re-reads `anglesite.json` on every call and several
        // `await`s separate those consumers, so two independent reads could genuinely disagree if
        // the owner flipped Website Settings ▸ Publishing mid-deploy. Resolved at attempt time
        // rather than threaded in from `deploy(…)`, for the same reason `containerControl` is
        // (#823): a token-prompt/rename retry re-enters here and picks up the current declaration.
        let resolvedTarget = command.target(for: siteDirectory)

        // Select the executor: in-container when the runtime is a started container;
        // explicit unavailable result otherwise. The token source always comes from the
        // injected `command` so the test-injection path (a fully pre-built
        // `DeployCommand`) continues to work unmodified.
        let activeCommand: DeployCommand
        let containerRunner: SocialWorkerProvisionCommand.CommandRunner?
        let containerSecretRunner: SocialWorkerProvisionCommand.SecretRunner?
        if let cc = containerControl {
            activeCommand = DeployCommand(
                target: resolvedTarget,
                executor: ContainerDeployExecutor(
                    control: cc.control,
                    siteID: cc.siteID,
                    logCenter: logCenter
                )
            )
            let containerCommandRunner = ContainerCommandRunner(control: cc.control, siteID: cc.siteID, logCenter: logCenter)
            containerRunner = containerCommandRunner.runner
            containerSecretRunner = containerCommandRunner.secretRunner
        } else {
            activeCommand = command.pinning(target: resolvedTarget)
            containerRunner = nil
            containerSecretRunner = nil
        }

        // Effective active worker set (#709 design §4-5, #825): the content-graph snapshot build
        // and the `WorkerActivation` computation now live in `DeployCoordinator.planWorkerActivation`
        // (AnglesiteCore) so this orchestration is unit-tested outside a hosted app-target test.
        let configStore = SiteConfigStore(configDirectory: configDirectory)
        let settings = (try? await configStore.load()) ?? SiteSettings()
        let catalog = await workerCatalog()
        let activationPlan = await DeployCoordinator.planWorkerActivation(
            siteID: siteID, siteDirectory: siteDirectory, settings: settings, catalog: catalog, contentGraph: contentGraph
        )
        let effectiveActiveIDs = activationPlan.effectiveActiveIDs
        if !activationPlan.removedIDs.isEmpty {
            await logCenter.append(
                source: "deploy:\(siteID)",
                stream: .stdout,
                text: "Deactivating workers: \(activationPlan.removedIDs.sorted().joined(separator: ", "))"
            )
        }
        if let notice = DeployCoordinator.activeWorkerIDsFallbackNotice(source: activationPlan.activeWorkerIDsSource) {
            // Mirrors SiteOperations.deployWithWorkerComposition's identical notice — shared text
            // via DeployCoordinator so the two paths can't drift (#708 review feedback's idiom).
            await logCenter.append(source: "deploy:\(siteID)", stream: .stdout, text: notice)
        }
        let workers = activationPlan.workers
        if let warning = WorkerActivation.missingDescriptorWarning(unresolvedIDs: activationPlan.unresolvedIDs) {
            // Mirrors SiteOperations.deployWithWorkerComposition's identical warning — shared
            // text via WorkerActivation so the two paths can't drift (#708 review feedback).
            await logCenter.append(source: "deploy:\(siteID)", stream: .stderr, text: warning)
        }

        // Advisory-only (#359): surfaces @dwk/workers conformance status for the active set's
        // gated phase, if any. Never blocks — a fetch failure degrades to an empty status inside
        // WorkersConformanceFetcher, and conformanceAdvisory returning nil just skips the log.
        let conformanceStatus = await WorkersConformanceFetcher.productionBounded().status()
        if let advisory = WorkerActivation.conformanceAdvisory(
            activeIDs: effectiveActiveIDs, conformance: conformanceStatus
        ) {
            await logCenter.append(source: "deploy:\(siteID)", stream: .stdout, text: advisory)
        }

        // Dynamic-route claims of the effective active set (#746). Validation failures (a
        // malformed path, two active workers claiming overlapping routes) refuse the deploy
        // before any Cloudflare call — never silently drop a claim and deploy a Worker whose
        // routes don't match its catalog contract.
        let routeClaims: [WorkerRouteClaims.OwnedClaim]
        do {
            routeClaims = try WorkerRouteClaims.activeClaims(catalog: catalog, activeIDs: effectiveActiveIDs)
        } catch {
            let reason = "worker route claims are invalid: \(error)"
            await logCenter.append(source: "deploy:\(siteID)", stream: .stderr, text: reason)
            subscription.cancel()
            _ = await logTask.value
            currentMilestone = nil
            currentMilestonePhase = nil
            workerNameConflictPresented = false
            webmentionPaidPlanConfirmationPresented = false
            activityPubHandleRenameConfirmationPresented = false
            transition(siteID: siteID, to: .failed(reason: reason, exitCode: nil))
            return .failed(reason: reason, exitCode: nil)
        }
        // #1659: adds the app-owned RFC 9727 API Catalog claim whenever the social layer is
        // composed at all, before either downstream use below — see `withAPICatalogClaim`.
        let effectiveRouteClaims = WorkerComposition.withAPICatalogClaim(routeClaims, workers: workers)

        // ActivityPub handle-rename confirmation (#1239, design doc §"Owner-chosen username"):
        // once an actor has federated, a resolved-handle change from the last-deployed baseline
        // is asked about — phrased in consequences to the owner's followers — rather than
        // silently deployed. Placed here (after `workers`/`settings` are known, before any
        // Cloudflare call) so it never provisions or publishes anything under a handle the owner
        // hasn't confirmed. Mirrors the routeClaims-invalid early return above: reuses the
        // generic `.failed` phase/result rather than a dedicated `Phase` case, since several
        // views (`DeployDrawerView` et al.) match `Phase` exhaustively and a new case would need
        // updating all of them — this flow's shape (park + a park-and-retry sheet) doesn't need
        // one to work correctly, the same way `SocialWorkerProvisionCommand.Result`'s webmention
        // paid-plan case already folds into `.failed` for callers with no dedicated case.
        let hasActivityPub = workers.contains(where: { $0.id == WorkerComposition.activitypubWorkerID })
        if hasActivityPub, let lastDeployedHandle = settings.lastDeployedAPUsername {
            let resolvedHandle = DeployCoordinator.resolveEffectiveActivityPubUsername(siteDirectory: siteDirectory)
            // `siteURL` is nilable here (an unresolvable/malformed site URL doesn't skip the
            // check) — see `isActivityPubHandleLocked`'s own doc comment for why that matters.
            let siteURL = DeployCoordinator.resolveSiteURL(siteDirectory: siteDirectory).flatMap(URL.init(string:))
            let isHandleLocked = await DeployCoordinator.isActivityPubHandleLocked(
                siteURL: siteURL, configDirectory: configDirectory
            )
            if DeployCoordinator.activityPubHandleRenameNeedsConfirmation(
                lastDeployedUsername: lastDeployedHandle, resolvedUsername: resolvedHandle, isLocked: isHandleLocked,
                acknowledgedUsername: settings.activityPubHandleRenameAcknowledged
            ), let resolvedHandle {
                let reason = "Changing your Fediverse handle from @\(lastDeployedHandle) to @\(resolvedHandle) disconnects the people who already follow you — confirm to continue"
                subscription.cancel()
                _ = await logTask.value
                currentMilestone = nil
                currentMilestonePhase = nil
                workerNameConflictPresented = false
                webmentionPaidPlanConfirmationPresented = false
                pendingDeploy = (siteID, siteDirectory, configDirectory, currentRoutes, containerControlProvider, siteName)
                activityPubHandleRenameChange = (from: lastDeployedHandle, to: resolvedHandle)
                drawerPresented = false
                activityPubHandleRenameConfirmationPresented = presentation == .foreground
                transition(siteID: siteID, to: .failed(reason: reason, exitCode: nil))
                return .failed(reason: reason, exitCode: nil)
            }
        }

        // Both closures below only make sense against a Cloudflare target — `SocialWorkerProvisionCommand`
        // is itself entirely a Cloudflare Workers concept (out of scope to generalize in #1015
        // slice 1). Since #1682 the target is resolved per site from `anglesite.json`, so
        // `cloudflareTarget` really is `nil` for a site that publishes to GitHub Pages: both
        // closures then return `nil`/`[]` and `provision()` reports a missing Cloudflare token
        // rather than trapping. Making that degrade *legible* to the owner (and unreachable
        // through the Workers UI in the first place) is #1683's capability gating, deliberately
        // not this slice.
        //
        // `resolvedTarget`, not a fresh `target(for:)` read: `activeCommand` is pinned to this
        // same conformer, so what these closures authorize against and what `deploy(…)` publishes
        // through are the same object rather than two reads of a file the owner can edit between
        // them.
        let cloudflareTarget = resolvedTarget as? CloudflareDeployTarget
        let socialCommand = SocialWorkerProvisionCommand(
            tokenSource: {
                guard let cloudflareTarget else { return nil }
                return try await cloudflareTarget.tokenSource()
            },
            runner: containerRunner ?? SocialWorkerProvisionCommand.defaultRunner,
            secretRunner: containerSecretRunner ?? SocialWorkerProvisionCommand.defaultSecretRunner,
            deployer: { [weak self] _, deploySiteID, deploySiteDirectory, _ in
                await activeCommand.deploy(
                    siteID: deploySiteID,
                    siteDirectory: deploySiteDirectory,
                    configDirectory: configDirectory,
                    currentRoutes: currentRoutes,
                    // #744: feeds the same already-validated active route claims (#746, computed
                    // above) into DeployCommand's pre-build /.well-known/ collision check.
                    wellKnownDynamicClaims: WorkerRouteClaims.wellKnownClaims(effectiveRouteClaims),
                    onPreflight: { [weak self] outcome in
                        Task { @MainActor in self?.onScanComplete?(outcome) }
                    },
                    // Unlike `onPreflight`/`onProgress` (fire-and-forget display state), this
                    // value is read back synchronously in the `.succeeded` case below to decide
                    // the URL swap and the conflict sheet — so the MainActor hop here has an
                    // implicit happens-before dependency, not just a display one. It holds today
                    // only because MainActor drains equal-priority jobs FIFO and several real
                    // `await`s (`uploadSourceBundleIfConfigured`, `runPostDeploySequencing`, the
                    // `SiteConfigStore` load) sit between this closure firing and that read — there
                    // is no structural guarantee. If those intervening `await`s are ever shortened
                    // or removed, this needs an explicit wait instead of relying on scheduling.
                    onDomainAttach: { [weak self] outcome in
                        Task { @MainActor in self?.domainAttachStatus = outcome }
                    },
                    onMarkdownForAgents: { [weak self] outcome in
                        Task { @MainActor in self?.markdownForAgentsStatus = outcome }
                    },
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            self?.currentMilestone = progress.label
                            self?.currentMilestonePhase = progress.phase
                            self?.onMilestone?(siteID, progress)
                        }
                    }
                )
            },
            // Forwards the same seam `activeCommand` uses for its own end-of-pipeline check (both
            // are built from `cloudflareTarget.workerScriptNamesSource` above), so `provision()`'s
            // pre-provisioning check (#1075) agrees with `deployer`'s — and so a test's injected
            // fake `DeployCommand`/`CloudflareDeployTarget` governs both instead of this defaulting
            // to the real network implementation.
            workerScriptNamesSource: { token in
                guard let cloudflareTarget else { return [] }
                return try await cloudflareTarget.workerScriptNamesSource(token)
            }
        )

        // Worker-name resolution precedence (#740, #825): moved to
        // `DeployCoordinator.resolveWorkerSiteName` — prefers the site's already-established
        // Worker name (`.site-config`'s `CF_PROJECT_NAME`) over re-deriving one from the site's
        // display name, so a rename-and-retry isn't silently reverted on the next deploy.
        let workerSiteName = DeployCoordinator.resolveWorkerSiteName(
            siteDirectory: siteDirectory, siteID: siteID, siteName: siteName
        )
        let siteURL = DeployCoordinator.resolveSiteURL(siteDirectory: siteDirectory)
        let apUsername = DeployCoordinator.resolveActivityPubUsername(siteDirectory: siteDirectory)
        // The actor's avatar (#1771): the owner's `.site-config` AP_ICON override, else the
        // site's apple-touch-icon — the same file Settings ▸ Website Icon replaces.
        let apIcon = DeployCoordinator.resolveActivityPubIcon(siteDirectory: siteDirectory)
        // The handle this deploy will actually serve (override-or-hostname-default, #1239) — used
        // below to advance the `lastDeployedAPUsername` baseline, distinct from `apUsername`
        // (the raw `.site-config` override, `nil` unless the owner set one) threaded to
        // `provision()` for the wrangler.toml var.
        let resolvedApUsername = DeployCoordinator.resolveEffectiveActivityPubUsername(siteDirectory: siteDirectory)
        let acknowledgesPaidPlan = settings.webmentionReceivePaidPlanAcknowledged ?? false
        let isHostedCommunity = DeployCoordinator.resolveIsHostedCommunity(siteDirectory: siteDirectory)
        // #1515: a running experiment (declared in Source/anglesite.json, today only by a hand
        // edit or a future slice-5 UI) provisions its D1 database and composes into the Worker on
        // the very next ordinary deploy — mirrors resolveIsHostedCommunity's declared-config read
        // just above.
        let runningExperiments = DeployCoordinator.resolveRunningExperiments(sourceDirectory: siteDirectory)
        let mcpEnabled = DeployCoordinator.resolveMCPEnabled(sourceDirectory: siteDirectory)
        // #1570: reuses the owner's email address from EmailSetupPlanner/EmailSetupExecutor
        // (already "in the stack") so /inbox submissions additionally forward there, alongside
        // the existing KV→git capture — mirrors resolveRunningExperiments's identical
        // declared-config read just above.
        let inboxForwardEmail = DeployCoordinator.resolveInboxForwardEmail(sourceDirectory: siteDirectory)
        let provisionResult = await socialCommand.provision(
            siteID: siteID,
            siteDirectory: siteDirectory,
            siteName: workerSiteName,
            workers: workers,
            routeClaims: effectiveRouteClaims.map(\.claim),
            knownResources: settings.provisionedWorkerResources ?? .init(),
            siteURL: siteURL,
            displayName: settings.displayName,
            apUsername: apUsername,
            apIcon: apIcon,
            acknowledgesPaidPlan: acknowledgesPaidPlan,
            inboxCaptureEnabled: settings.inboxCaptureEnabled ?? false,
            inboxForwardEmail: inboxForwardEmail,
            activityPubActorType: isHostedCommunity ? "Group" : nil,
            moderators: isHostedCommunity ? settings.moderators : nil,
            experiments: runningExperiments,
            mcpEnabled: mcpEnabled
        )

        if case .webmentionPaidPlanConfirmationNeeded = provisionResult {
            pendingDeploy = (siteID, siteDirectory, configDirectory, currentRoutes, containerControlProvider, siteName)
            subscription.cancel()
            _ = await logTask.value
            currentMilestone = nil
            currentMilestonePhase = nil
            workerNameConflictPresented = false
            activityPubHandleRenameConfirmationPresented = false
            transition(siteID: siteID, to: .webmentionPaidPlanConfirmationNeeded)
            drawerPresented = false
            webmentionPaidPlanConfirmationPresented = presentation == .foreground
            return .failed(
                reason: "Inbound Webmention and WebSub require the Cloudflare Workers Paid plan — confirm to continue",
                exitCode: nil)
        }

        // Whether the WebSub hub is actually live after this provision (worker active AND its
        // Queue exists) — the gate for the post-deploy publish pings below. Computed from the
        // provision result's resources, not settings, so a hub provisioned in this very run
        // pings on its first deploy.
        let websubProvisioned: Bool
        // Gate for the ActivityPub outbox backfill below (#926) — mirrors `websubProvisioned`'s
        // shape, but only needs the worker to be active (unlike WebSub, backfill doesn't depend
        // on a specific provisioned resource). Computed before the persist call below too: it
        // also gates whether this deploy advances the `lastDeployedAPUsername` baseline (#1239).
        let activitypubProvisioned = workers.contains(where: { $0.id == WorkerComposition.activitypubWorkerID })
        if case .succeeded(let deployedURL, let resources, _) = provisionResult {
            // The actor IRI must be derived the same way `ModerationModel.ownActorURL` derives
            // "this site's own actor" (`DeployCoordinator.resolveSiteURL`), not from the
            // workers.dev URL this particular deploy happened to print — `resolveSiteURL`
            // deliberately prefers a confirmed-attached custom domain, and `persistSiteURL`
            // (called above, before `provision()` ran) has already recorded whatever domain state
            // is current by this point. Falls back to `deployedURL` only for the very first
            // deploy, before any URL has ever been recorded (#1263 final review finding 3).
            let communityActorSiteURL =
                DeployCoordinator.resolveSiteURL(siteDirectory: siteDirectory).flatMap { URL(string: $0) } ?? deployedURL
            await DeployCoordinator.persistProvisionedResources(
                configStore: configStore, settings: settings,
                effectiveActiveIDs: effectiveActiveIDs, resources: resources,
                apUsername: activitypubProvisioned ? resolvedApUsername : nil,
                communityActorURL: (isHostedCommunity && activitypubProvisioned)
                    ? ActivityPubActor.actorURL(siteURL: communityActorSiteURL) : nil
            )
            websubProvisioned = workers.contains(where: { $0.id == WorkerComposition.websubWorkerID })
                && resources.websubQueueName != nil
        } else {
            websubProvisioned = false
        }

        let result = provisionResult.asDeployCommandResult

        subscription.cancel()
        _ = await logTask.value

        currentMilestone = nil
        switch result {
        case .succeeded(let url, let duration):
            // Astro's build above regenerates RSS/Atom/JSON feeds. Social delivery is ordered
            // after the deployed canonical pages exist, and completion is notified only after
            // both best-effort passes finish. The ordering itself is
            // `DeployCoordinator.runPostDeploySequencing` (#825); this closure-composes it with
            // the concrete webmention/POSSE commands and the milestone hook.
            await DeployCoordinator.runPostDeploySequencing(
                onMilestone: { [weak self] progress in self?.emitPostDeployMilestone(progress, siteID: siteID) },
                sendWebmentions: { [weak self] in
                    guard let self else { return }
                    await self.webmentionCommand.send(
                        siteID: siteID, siteDirectory: siteDirectory, configDirectory: configDirectory, siteBase: url
                    )
                },
                publishStandardSite: { [weak self] in
                    guard let self else { return }
                    await self.standardSitePublishCommand.publish(
                        siteID: siteID, siteDirectory: siteDirectory, configDirectory: configDirectory
                    )
                },
                publishStandardSiteGraph: { [weak self] in
                    guard let self else { return }
                    await self.standardSiteGraphPublishCommand.publish(
                        siteID: siteID, siteDirectory: siteDirectory, configDirectory: configDirectory
                    )
                },
                syndicate: { [weak self] in
                    guard let self else { return }
                    await self.posseCommand.syndicate(
                        siteID: siteID, siteDirectory: siteDirectory, configDirectory: configDirectory, siteBase: url
                    )
                },
                notifySubscribers: { [weak self] in
                    // WebSub publish pings (#361): only when the hub is live for this site. The
                    // canonical site URL is preferred — the hub's allowed topics derive from the
                    // Worker's SITE_URL var, which resolveSiteURL also sourced — falling back to
                    // the deployed URL (whose request origin the un-var'd hub falls back to).
                    guard let self, websubProvisioned else { return }
                    _ = await self.websubPing.notify(
                        siteURL: siteURL ?? url.absoluteString,
                        source: "websub:\(siteID)"
                    )
                },
                backfillActivityPubOutbox: { [weak self] in
                    guard let self, activitypubProvisioned else { return }
                    _ = await self.activityPubOutboxBackfill.backfill(
                        siteID: siteID,
                        siteDirectory: siteDirectory,
                        configDirectory: configDirectory,
                        siteBase: url,
                        secretStore: self.keychain
                    )
                },
                pushContactsAllowlist: { [weak self] in
                    guard let self else { return }
                    await ContactsAllowlistSync.pushIfConfigured(
                        configDirectory: configDirectory, secretStore: self.keychain
                    )
                },
                pushVouchTrustList: { [weak self] in
                    guard let self else { return }
                    await BlogrollTrustSync.pushIfConfigured(
                        siteDirectory: siteDirectory, configDirectory: configDirectory, secretStore: self.keychain
                    )
                }
            )
            currentMilestone = nil
            workerNameConflictPresented = false
            webmentionPaidPlanConfirmationPresented = false
            activityPubHandleRenameConfirmationPresented = false
            if let settings = try? await SiteConfigStore(configDirectory: configDirectory).load() {
                sourceBundleStatus = await SourceBundleStatus.check(siteDirectory: siteDirectory, settings: settings)
            }
            // #1077: once the custom domain is actually attached, the deployed workers.dev URL is
            // no longer the "real" address — swap what the drawer shows/shares/opens to the domain
            // instead. `resolveSiteURL` already prefers `.site-config`'s DOMAIN unconditionally
            // (it's written at scaffold time regardless of attach status), so this must stay gated
            // on `domainAttachStatus == .confirmed` — otherwise a not-yet-connected domain would be
            // presented as if it were already live. This read relies on the `onDomainAttach`
            // ordering note above (its MainActor hop having already landed by the time execution
            // reaches here).
            var displayURL = url
            if case .confirmed = domainAttachStatus,
               let customHost = DeployCoordinator.resolveSiteURL(siteDirectory: siteDirectory),
               let customURL = URL(string: customHost) {
                displayURL = customURL
            }
            // `domainConflictPresented` only drives the one-time sheet, gated to foreground
            // deploys like `workerNameConflictPresented`. A background/automatic deploy's conflict
            // still needs to reach the user, though — `DeployDrawerView`'s `.conflict` caption
            // (mirroring the `.notConnected` one) reads `domainAttachStatus` directly and isn't
            // gated on `presentation`, so the outcome survives even when this sheet never fires.
            if case .conflict = domainAttachStatus {
                domainConflictPresented = presentation == .foreground
            }
            transition(siteID: siteID, to: .succeeded(url: displayURL, duration: duration))
        case .failed(let reason, let exit):
            workerNameConflictPresented = false
            webmentionPaidPlanConfirmationPresented = false
            activityPubHandleRenameConfirmationPresented = false
            transition(siteID: siteID, to: .failed(reason: reason, exitCode: exit))
            guard presentation == .foreground else { return result }
            let capturedLog = logText   // snapshot before the suspension; a later deploy clears logLines
            summarizing = true
            let summary = await DeployFailureSummaryRequest.run(
                logText: capturedLog,
                siteID: siteID,
                siteDirectory: siteDirectory,
                using: summarizer
            )
            // Drop the result if another deploy started while we were summarizing — it has already
            // reset failureSummary/summarizing and we must not clobber its state.
            guard summarizationGeneration == myGeneration else { return result }
            failureSummary = summary
            summarizing = false
        case .blocked(let failures, let warnings):
            transition(siteID: siteID, to: .blocked(failures: failures, warnings: warnings))
            // For the blocked outcome the modal sheet carries the actionable info; the
            // streaming-log drawer would just be noise.
            drawerPresented = false
            workerNameConflictPresented = false
            webmentionPaidPlanConfirmationPresented = false
            activityPubHandleRenameConfirmationPresented = false
            blockedPresented = presentation == .foreground
        case .workerNameConflict(let name):
            // Parks the provider, not the resolved `containerControl` snapshot above — the
            // rename-and-retry re-invokes it, so it sees the runtime's state at retry time.
            pendingDeploy = (siteID, siteDirectory, configDirectory, currentRoutes, containerControlProvider, siteName)
            transition(siteID: siteID, to: .workerNameConflict(name: name))
            drawerPresented = false
            workerNameConflictError = nil
            workerNameConflictPresented = presentation == .foreground
            webmentionPaidPlanConfirmationPresented = false
            activityPubHandleRenameConfirmationPresented = false
        case .domainConfigDrift(let findings):
            transition(siteID: siteID, to: .domainConfigDrift(findings: findings))
            // Same reasoning as `.blocked`: the modal sheet carries the actionable info, and
            // reconciling happens in the Domain Config Audit sheet, not by retrying this deploy
            // directly — no `pendingDeploy` park.
            drawerPresented = false
            workerNameConflictPresented = false
            webmentionPaidPlanConfirmationPresented = false
            activityPubHandleRenameConfirmationPresented = false
            domainConfigDriftPresented = presentation == .foreground
        }
        return result
    }

    private func emitPostDeployMilestone(_ progress: OperationProgress, siteID: String) {
        currentMilestone = progress.label
        currentMilestonePhase = progress.phase
        onMilestone?(siteID, progress)
    }
}

import Foundation

/// The gate in front of every push of `Source/` off-device that isn't a deploy — "Publish to
/// GitHub" (`RepoBootstrap.publish`) and every subsequent backup push (`BackupCommand`) — per
/// owner decision **D5** (2026-09-08; #1959). Before #1959 those pushes shipped all of `Source/`
/// after only a dotenv-filename refusal; the deploy's PII/token/restricted-content scan never
/// ran. Two halves, in order:
///
/// 1. **Integrity** — `AppOwnedScriptsGate.enforce` (#1958): the scan below is the site's own
///    copy of `scripts/pre-deploy-check.ts`, so it is only worth trusting once that copy — in the
///    host repo and in the runtime that will execute it — is verified against the app's. A
///    mismatch refuses the push, restores the app's copy, and commits it, exactly as a deploy
///    does.
/// 2. **Scan** — the source subset of the pre-deploy check (`pre-deploy-check.ts --json
///    --source`): `anglesite.json` validity, restricted (`visibility: contacts`) content in
///    `src/content/`, and secret/token patterns and dotenv files anywhere in the source tree.
///    `.blocked` refuses the push; `.error` (the scan couldn't run) refuses it too, since a gate
///    that can't run must not be mistaken for one that passed.
///
/// The scan runs where the deploy scan runs — in the site's container — reached through the
/// ``Runtime`` a site's open window registers in `SourcePublishGateRegistry`. A site with no
/// registered runtime (not open, or its preview still booting) is refused with an actionable
/// message, never skipped.
public struct SourcePublishGate: Sendable {
    /// What a site's live runtime offers the gate: the copy of the site it will run the scan
    /// from (for the integrity half), and the scan itself.
    public struct Runtime: Sendable {
        /// The runtime's own copy of the app-owned scripts, for `AppOwnedScriptsGate`; `nil`
        /// when the scan runs directly against the host directory.
        public let scriptsCopy: AppOwnedScriptsGate.RuntimeCopy?
        /// Runs the source scan against the site and returns the parsed outcome.
        public let scan: @Sendable (_ sourceDirectory: URL) async -> PreDeployCheck.Outcome

        /// Memberwise — production runtimes come from ``containerRuntime(control:siteID:syncFromHost:logCenter:)``,
        /// tests build one around a canned outcome.
        public init(
            scriptsCopy: AppOwnedScriptsGate.RuntimeCopy?,
            scan: @escaping @Sendable (_ sourceDirectory: URL) async -> PreDeployCheck.Outcome
        ) {
            self.scriptsCopy = scriptsCopy
            self.scan = scan
        }
    }

    /// Resolves the runtime for a site id at check time, or `nil` when the site has none.
    public typealias RuntimeProvider = @Sendable (_ siteID: String) async -> Runtime?

    /// The gate's decision for one push.
    public enum Outcome: Sendable, Equatable {
        /// The push may proceed; `warnings` are advisory and never block.
        case passed(warnings: [PreDeployCheck.ScanWarning])
        /// The push must not happen. Carries the same structures the deploy's blocked sheet
        /// renders (`BlockedDeploySheetView`), so both surfaces share one presentation.
        case blocked(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning])
        /// The gate couldn't run at all; the push must not happen either. `reason` is owner-facing.
        case error(reason: String)
    }

    private let templateDirectory: @Sendable () -> URL?
    private let runtime: RuntimeProvider
    private let logCenter: LogCenter
    private let gitCommitBatch: @Sendable (URL, [String], String) async -> String?

    /// Creates a gate. `templateDirectory` defaults to the running app's template
    /// (`TemplateRuntime.resolve()`, the same resolution the deploy gate and site-open sync use);
    /// `runtime` has no default on purpose — where the scan runs depends on the site's runtime,
    /// so every caller states it explicitly, the same rule `PreDeployCheck.init` follows.
    public init(
        templateDirectory: @escaping @Sendable () -> URL? = { TemplateRuntime.resolve().url },
        runtime: @escaping RuntimeProvider,
        logCenter: LogCenter = .shared,
        gitCommitBatch: @escaping @Sendable (URL, [String], String) async -> String? = InboxSubmissionCommitter.processGitCommitBatch
    ) {
        self.templateDirectory = templateDirectory
        self.runtime = runtime
        self.logCenter = logCenter
        self.gitCommitBatch = gitCommitBatch
    }

    /// The production gate: integrity against the running app's template, and a scan routed
    /// through `SourcePublishGateRegistry.shared` to whatever runtime the site's window
    /// registered. A site with no registered runtime is refused, never skipped.
    public static let live = SourcePublishGate(runtime: registryProvider(.shared))

    /// A provider that looks `siteID` up in `registry` at check time.
    public static func registryProvider(_ registry: SourcePublishGateRegistry) -> RuntimeProvider {
        { siteID in await registry.runtime(for: siteID) }
    }

    /// Integrity first, then the scan. `configDirectory` is threaded to the integrity restore's
    /// baseline and commit bookkeeping when known. Never throws.
    public func check(siteID: String, sourceDirectory: URL, configDirectory: URL?, source: String) async -> Outcome {
        guard let runtime = await runtime(siteID) else {
            await logCenter.append(
                source: source, stream: .stderr,
                text: "source scan could not run: no runtime is registered for \(siteID)")
            return .error(reason: "the site's runtime isn't running — open the site in Anglesite, wait for its preview to start, then try again")
        }

        let integrity = await AppOwnedScriptsGate.enforce(
            sourceDirectory: sourceDirectory, configDirectory: configDirectory,
            templateDirectory: templateDirectory(), runtimeCopy: runtime.scriptsCopy, source: source,
            logCenter: logCenter, gitCommitBatch: gitCommitBatch)
        if let failure = AppOwnedScriptsGate.scanFailure(for: integrity) {
            return .blocked(failures: [failure], warnings: [])
        }
        if let reason = AppOwnedScriptsGate.failureReason(for: integrity) {
            return .error(reason: reason)
        }

        switch await runtime.scan(sourceDirectory) {
        case .passed(let warnings):
            return .passed(warnings: warnings)
        case .blocked(let failures, let warnings):
            return .blocked(failures: failures, warnings: warnings)
        case .error(let reason):
            await logCenter.append(source: source, stream: .stderr, text: "source scan could not run: \(reason)")
            return .error(reason: "Anglesite couldn't run its safety check on this site (\(reason)).")
        }
    }

    /// The runtime behind a booted container: the guest's `/workspace/site` clone is the copy
    /// `AppOwnedScriptsGate` verifies (through `ContainerDeployExecutor`, the same seam a deploy
    /// uses), and the scan is `scripts/pre-deploy-check.ts --json --source` run there after
    /// `syncFromHost` has fast-forwarded the clone to the host's HEAD — the caller commits before
    /// gating, so the scan sees exactly the commit about to be pushed. A sync or exec failure is
    /// an `.error`, never a pass.
    public static func containerRuntime(
        control: any LocalContainerControl,
        siteID: String,
        syncFromHost: @escaping @Sendable () async throws -> Void,
        logCenter: LogCenter = .shared
    ) -> Runtime {
        let executor = ContainerDeployExecutor(control: control, siteID: siteID, logCenter: logCenter)
        let source = "publish:\(siteID):scan"
        return Runtime(
            scriptsCopy: AppOwnedScriptsGate.RuntimeCopy(executor: executor, source: source),
            scan: { _ in
                do {
                    try await syncFromHost()
                } catch {
                    return .error(reason: "couldn't bring the site's latest changes into its runtime: \(error)")
                }
                let check = PreDeployCheck(invoke: { _ in
                    let result = try await WranglerInvocation.exec(
                        control: control, siteID: siteID,
                        argv: ["npx", "tsx", "scripts/pre-deploy-check.ts", "--json", "--source"],
                        environment: [:], logCenter: logCenter, source: source)
                    return (stdout: result.stdout, exitCode: result.exitCode)
                })
                return await check.check(siteID: siteID, siteDirectory: URL(fileURLWithPath: "/workspace/site"))
            })
    }
}

/// Where a site's live runtime publishes the ``SourcePublishGate/Runtime`` that
/// `SourcePublishGate.live` checks through — keyed by site id, so a headless caller
/// (`SiteOperations.backup`, App Intents/Siri) and the window-bound models (`BackupModel`,
/// `PublishModel`) reach the same in-container scan without either holding a reference to the
/// other. `SiteWindowModel` registers a provider when a site opens and unregisters it when the
/// window closes; a site with nothing registered has no runtime to scan in, and the gate
/// refuses the push with an actionable message rather than skipping (#1959). Mirrors
/// `PreviewAnnotationProviderRegistry`'s shape.
public final class SourcePublishGateRegistry: @unchecked Sendable {
    /// Resolves a site's runtime at check time — `nil` while its container is still booting.
    public typealias Provider = @Sendable () async -> SourcePublishGate.Runtime?

    /// The process-wide registry every live gate consults.
    public static let shared = SourcePublishGateRegistry()

    private let lock = NSLock()
    private var providers: [String: Provider] = [:]

    /// Creates an empty registry — tests use their own instance; production uses ``shared``.
    public init() {}

    /// Publishes `provider` as the way to reach `siteID`'s runtime, replacing any prior one.
    public func register(_ provider: @escaping Provider, for siteID: String) {
        lock.lock(); defer { lock.unlock() }
        providers[siteID] = provider
    }

    /// Removes `siteID`'s provider; a later gate check for that site refuses the push.
    public func unregister(siteID: String) {
        lock.lock(); defer { lock.unlock() }
        providers[siteID] = nil
    }

    /// `siteID`'s runtime right now, or `nil` when none is registered or its provider has no
    /// runtime yet.
    public func runtime(for siteID: String) async -> SourcePublishGate.Runtime? {
        let provider: Provider?
        lock.lock(); provider = providers[siteID]; lock.unlock()
        guard let provider else { return nil }
        return await provider()
    }
}

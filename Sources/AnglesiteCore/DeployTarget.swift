import Foundation

/// Outcome of a `DeployTarget`'s pre-build gate (`authorize(siteDirectory:)`). `DeployCommand`
/// calls this before spending any time on the well-known scan or the build, so a deploy that
/// can't succeed fails fast — matches `DeployCommand.deploy`'s original pre-spawn-refusal
/// behavior exactly.
public enum DeployTargetAuthorization: Sendable {
    /// The target is ready to publish. `credential` is opaque to `DeployCommand` — only the
    /// target that produced it (via `publish(context:)`'s `DeployTargetContext.credential`) knows
    /// what to do with it (e.g. `CloudflareDeployTarget` treats it as a Cloudflare API token).
    case ready(credential: String)
    /// The deploy is refused before any build work happens — a missing/invalid credential, or a
    /// target-specific fail-fast check (e.g. Cloudflare's worker-name-conflict or
    /// domain-config-drift checks). `DeployCommand.deploy` returns this `Result` immediately.
    case blocked(DeployCommand.Result)
}

/// Everything a `DeployTarget` needs to publish one deploy, assembled by `DeployCommand.deploy`
/// after the shared build + `PreDeployCheck` spine has passed.
public struct DeployTargetContext: Sendable {
    public let siteID: String
    public let siteDirectory: URL
    /// The site's `Config/` directory, or `nil` when the caller didn't supply one (tests, and the
    /// two non-primary deploy paths in `SocialWorkerProvisionCommand`/`SiteOperations`) — mirrors
    /// `DeployCommand.deploy`'s own `configDirectory` parameter (#530).
    public let configDirectory: URL?
    /// The site's currently published route set, forwarded from `DeployCommand.deploy`'s
    /// `currentRoutes` parameter — only meaningful when `configDirectory` is non-nil.
    public let currentRoutes: [String]
    /// The credential `authorize(siteDirectory:)` resolved, forwarded verbatim from its
    /// `.ready(credential:)` case.
    public let credential: String
    /// The curated, secret-stripped environment `DeployCommand.hostDeployEnvironment()` produced
    /// for the build/preflight steps — the target adds its own credential to this (rather than
    /// receiving a pre-mixed environment) so the base environment's secret-stripping guarantee is
    /// visible at the target's own call site, not just asserted by the caller.
    public let baseEnvironment: [String: String]
    /// The same `DeployExecutor` `DeployCommand` used for the build/preflight steps — the target
    /// uses it to run its own steps (e.g. `CloudflareDeployTarget` runs `.wrangler` and
    /// `.bundleUpload` through it).
    public let executor: any DeployExecutor
    /// Forwarded verbatim from `DeployCommand.deploy`'s `onDomainAttach` parameter. Only
    /// `CloudflareDeployTarget` fires it today; a target with no equivalent concept simply never
    /// calls it.
    public let onDomainAttach: DeployCommand.DomainAttachObserver?
    /// Forwarded verbatim from `DeployCommand.deploy`'s `onMarkdownForAgents` parameter. Only
    /// `CloudflareDeployTarget` fires it today; a target with no equivalent concept simply never
    /// calls it.
    public let onMarkdownForAgents: DeployCommand.MarkdownForAgentsObserver?
    /// Forwarded verbatim from `DeployCommand.deploy`'s `onProgress` parameter, so the target can
    /// report its own publish-phase milestones (e.g. `.deployDeploying`/`.deployFinalizing`).
    public let onProgress: ProgressHandler?

    public init(
        siteID: String,
        siteDirectory: URL,
        configDirectory: URL?,
        currentRoutes: [String],
        credential: String,
        baseEnvironment: [String: String],
        executor: any DeployExecutor,
        onDomainAttach: DeployCommand.DomainAttachObserver?,
        onMarkdownForAgents: DeployCommand.MarkdownForAgentsObserver?,
        onProgress: ProgressHandler?
    ) {
        self.siteID = siteID
        self.siteDirectory = siteDirectory
        self.configDirectory = configDirectory
        self.currentRoutes = currentRoutes
        self.credential = credential
        self.baseEnvironment = baseEnvironment
        self.executor = executor
        self.onDomainAttach = onDomainAttach
        self.onMarkdownForAgents = onMarkdownForAgents
        self.onProgress = onProgress
    }
}

/// A publishable destination for a site's built static output — the seam that lets
/// `DeployCommand` support hosts beyond Cloudflare (#1015). Each conformer owns everything
/// specific to its provider: credential resolution, any target-specific pre-checks, the actual
/// upload, and post-publish effects. `CloudflareDeployTarget` is the only conformer today.
///
/// `DeployCommand.deploy` calls `authorize(siteDirectory:)` before the shared well-known-scan and
/// build steps run, then `publish(context:)` only after those and the non-bypassable
/// `PreDeployCheck` preflight have all passed — no conformer gets a hook into the preflight gate
/// itself.
public protocol DeployTarget: Sendable {
    /// Stable identifier persisted in `Source/anglesite.json`'s `deployTarget` field (e.g.
    /// `"cloudflare"`). Read by `DeployTargetSelection` to pick the conformer a site publishes
    /// through (#1682), so it's part of the on-disk contract: renaming one re-points every site
    /// that declared it back to the Cloudflare default.
    static var id: String { get }

    /// Pre-build gate: resolves this target's credential and runs any fail-fast checks against
    /// current deployed state. Called before the well-known scan and the build, so a deploy that
    /// can't succeed never pays for either.
    func authorize(siteDirectory: URL) async -> DeployTargetAuthorization

    /// Publishes the build produced by the shared spine and performs any post-publish effects.
    /// Only called after `authorize` returned `.ready`, the well-known scan passed, the build
    /// succeeded, and `PreDeployCheck` passed.
    func publish(context: DeployTargetContext) async -> DeployCommand.Result
}

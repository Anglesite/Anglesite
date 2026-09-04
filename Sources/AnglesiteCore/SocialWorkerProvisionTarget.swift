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
    public private(set) var resources: WorkerComposition.ProvisionedResources

    public init(
        cloudflareTarget: CloudflareDeployTarget,
        siteName: String,
        workers: [WorkerDescriptor],
        knownResources: WorkerComposition.ProvisionedResources
    ) {
        self.cloudflareTarget = cloudflareTarget
        self.siteName = siteName
        self.workers = workers
        self.resources = knownResources
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

    public func publish(context: DeployTargetContext) async -> DeployCommand.Result {
        fatalError("Task 13 implements this")
    }
}

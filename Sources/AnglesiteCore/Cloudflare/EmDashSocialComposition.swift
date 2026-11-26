import Foundation

/// Which of a site's social features run on an EmDash site (#2162). Its social endpoints are
/// composed into the EmDash Worker (`WorkerComposition.Host.emdash`), less the features that
/// depend on content in git or on bindings EmDash already holds.
public enum EmDashSocialComposition {
    /// The workers that run in the EmDash Worker: every active one but Micropub, which writes posts
    /// into the site's repository (an EmDash site's articles live in EmDash) and binds `MEDIA`,
    /// EmDash's media bucket.
    public static func composableWorkers(_ workers: [WorkerDescriptor]) -> [WorkerDescriptor] {
        workers.filter { $0.id != WorkerComposition.micropubWorkerID }
    }

    /// The worker ids a successful publish records as deployed (`SiteSettings.lastDeployedWorkerIDs`,
    /// the baseline route removal and drift detection read): `effectiveActiveIDs`, less the ids an
    /// EmDash site's Worker doesn't serve (#2165). Every other site's Worker serves its full set.
    public static func deployedIDs(effectiveActiveIDs: Set<String>, serverRenderedDeploy: Bool) -> Set<String> {
        serverRenderedDeploy ? effectiveActiveIDs.subtracting([WorkerComposition.micropubWorkerID]) : effectiveActiveIDs
    }

    /// The route claims of the workers that run: `claims` less those a left-off worker
    /// declared, so the pre-deploy inventory only counts endpoints the Worker serves.
    /// App-owned claims (`app:…`) are kept.
    public static func composableClaims(
        _ claims: [WorkerRouteClaims.OwnedClaim], workers: [WorkerDescriptor]
    ) -> [WorkerRouteClaims.OwnedClaim] {
        let composed = Set(composableWorkers(workers).map(\.id))
        let leftOff = Set(workers.map(\.id)).subtracting(composed)
        return claims.filter { !leftOff.contains($0.owner) }
    }

    /// The owner-facing names of the features left off an EmDash site, for the publish log:
    /// Micropub, and the Worker features that serve content from the static build (Inbox Capture,
    /// a running experiment, MCP). Empty when nothing is left off.
    public static func leftOff(
        workers: [WorkerDescriptor], inboxCaptureEnabled: Bool,
        experiments: [DomainConfig.Experiments.Experiment], mcpEnabled: Bool
    ) -> [String] {
        var names = workers.filter { $0.id == WorkerComposition.micropubWorkerID }.map(\.displayName)
        if inboxCaptureEnabled { names.append("Inbox Capture") }
        if experiments.contains(where: { $0.status == "running" }) { names.append("experiments") }
        if mcpEnabled { names.append("MCP") }
        return names
    }
}

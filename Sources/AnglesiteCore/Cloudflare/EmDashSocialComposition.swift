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

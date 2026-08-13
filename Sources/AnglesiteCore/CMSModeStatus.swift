/// Whether a site's typed content editors should save through `MicropubClient` (CMS mode)
/// instead of file+git — true once the site's composed Worker includes `@dwk/micropub`
/// (spec §C.6). Pure and I/O-free by design: callers that also need to know whether a usable
/// session exists right now (Keychain-backed) check that separately, so this type stays a
/// trivial fact about the site's *provisioning* state, not its *auth* state.
public enum CMSModeStatus {
    /// True once `settings.activeWorkerIDs` includes Micropub's catalog id.
    public static func isProvisioned(settings: SiteSettings) -> Bool {
        (settings.activeWorkerIDs ?? []).contains(WorkerComposition.micropubWorkerID)
    }
}

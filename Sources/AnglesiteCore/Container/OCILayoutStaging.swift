import Foundation

/// Stages a (possibly read-only, bundle-hosted) OCI layout into a writable directory.
///
/// This is the engine behind `BundledImage.stagedLayoutURL` in AnglesiteContainer.
/// `ImageStore.load(from:)` writes ingest-tracking files (e.g. `ingest/`) directly inside the
/// layout directory it reads from — not just into the destination store — so passing a bundled
/// layout straight in fails with EPERM on a real, read-only `.app`. The logic lives here (pure
/// Foundation, no Containerization dependency) so it stays covered by CI's `swift test`, which
/// never compiles the AnglesiteContainer module.
public enum OCILayoutStaging {
    /// Returns a writable staged copy of the OCI layout at `source`, staging it if needed.
    ///
    /// `name` identifies the artifact (e.g. "app-image", "vminit-initfs") and namespaces its
    /// staged copy under `storeRoot` so repeated launches reuse it instead of re-copying every
    /// time.
    ///
    /// A staged copy is reused only while its `index.json` byte-matches the source's. In an OCI
    /// layout `index.json` carries the manifest digest, so any change to the bundled image changes
    /// it — comparing it is an image-identity check without hashing the blobs. A mismatch means an
    /// app update shipped a new bundled image; the stale copy is then replaced atomically (via the
    /// safe-save `replaceItemAt`), so existing installs pick up the new image instead of booting
    /// the first-ever staged copy forever.
    ///
    /// `name` is shared across all sites (not site-scoped, unlike the ext4 rootfs/initfs), so two
    /// site windows cold-booting `LocalContainerSiteRuntime` around the same time can call this
    /// concurrently for the same artifact. Each caller copies into its own uniquely-named temp
    /// directory and re-checks before installing it — so a slower caller can never delete or
    /// observe a partial copy from a faster one; it just discards its own redundant copy and
    /// reuses the winner's result. (Concurrent callers always read the same bundled source, so a
    /// double-install is at worst a same-content replace.)
    public static func stagedLayoutURL(source: URL, name: String, storeRoot: URL) throws -> URL {
        let staged = storeRoot.appendingPathComponent("layout-staging/\(name)", isDirectory: true)
        let sourceIndex = OCILayoutIdentity.indexURL(of: source)
        // A missing/unreadable source index is a hard error (there is nothing valid to stage) —
        // unlike the staleness checks below, which fail soft toward re-staging.
        _ = try Data(contentsOf: sourceIndex)
        func stagedIsCurrent() -> Bool {
            OCILayoutIdentity.contentsMatch(OCILayoutIdentity.indexURL(of: staged), sourceIndex)
        }
        if stagedIsCurrent() {
            return staged
        }
        let parent = staged.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let tempDir = parent.appendingPathComponent(".staging-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        if stagedIsCurrent() {
            return staged  // another caller finished staging while we were copying
        }
        if FileManager.default.fileExists(atPath: staged.path) {
            // Stale copy from a previously-bundled image: swap the fresh copy in atomically so a
            // concurrent reader never observes a partially-replaced layout. `replaceItemAt` is
            // documented as possibly not replacing in place — honor the URL it reports the new
            // item at rather than assuming it landed at `staged`.
            if let replaced = try FileManager.default.replaceItemAt(staged, withItemAt: tempDir) {
                return replaced
            }
            return staged
        } else {
            do {
                try FileManager.default.moveItem(at: tempDir, to: staged)
            } catch {
                // Lost the race to a concurrent stager. If they succeeded, use their result;
                // otherwise this is a real failure (e.g. disk full) and should propagate.
                guard stagedIsCurrent() else { throw error }
            }
        }
        return staged
    }
}

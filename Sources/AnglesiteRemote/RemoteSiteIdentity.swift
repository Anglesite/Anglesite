import CryptoKit
import Foundation
import AnglesiteCore

/// Derives the stable per-site key the helper uses for its `RemoteSessionRegistry` claim and for
/// `LocalContainerControl`'s own container/artifact identity.
///
/// This has to be per-site *and* stable across runs, because both consumers key real state on it:
/// the registry writes one `<siteID>.json` claim file, and `ContainerizationControl` names its
/// on-disk boot artifacts (`rootfs-<siteID>.ext4` and friends) after it. The obvious shortcut —
/// the site directory's last path component — is neither: the helper is handed a site's `Source/`
/// git repo (`Foo.anglesite/Source`, per the package model), so `lastPathComponent` is the literal
/// string `"Source"` for every site on the machine, and two helper sessions for two different
/// sites would collide on both the claim registry and the container store.
public enum RemoteSiteIdentity {
    /// The site key for the `Source/` directory at `sourceDirectory`.
    ///
    /// Prefers the `.anglesite` package's own marker UUID — the same path-independent identity the
    /// main app uses, so a package that moves or is renamed keeps its key. Falls back to a stable
    /// digest of the resolved absolute path when the enclosing directory isn't a recognizable
    /// package (a bare git checkout, or a test fixture): not path-independent, but deterministic
    /// across runs and distinct per site, which is what the two consumers actually require.
    public static func siteID(forSourceDirectory sourceDirectory: URL) -> String {
        let resolved = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let packageRoot = AnglesitePackage.packageRoot(fromSourceURL: resolved)
        if AnglesitePackage.isPackage(at: packageRoot),
           let marker = try? AnglesitePackage(url: packageRoot).readMarker() {
            return marker.siteID.uuidString
        }
        return "path-" + digest(of: resolved.path)
    }

    /// First 16 hex characters of the path's SHA-256 — 64 bits, far more than enough to keep the
    /// handful of sites one Mac ever hosts distinct, and short enough to keep the artifact
    /// filenames it ends up in readable.
    private static func digest(of path: String) -> String {
        let hash = SHA256.hash(data: Data(path.utf8))
        return String(hash.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}

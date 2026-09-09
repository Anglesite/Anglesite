import Foundation

/// Per-test stand-in for a package's `Config/` directory, for suites that drive a deploy or a
/// provisioning run against a bare temporary `siteDirectory` rather than a full `.anglesite`
/// package (#1960). App-owned deploy state — `wrangler.toml`, `SiteSettings`'s deploy markers,
/// the deployed-routes snapshot — is written here, so every test gets its own isolated location
/// instead of sharing one: a `Config/` derived as a sibling of `$TMPDIR/<uuid>` would land in
/// `$TMPDIR/Config` for every test in the process and leak markers between suites.
public enum TestSiteLayout {
    /// `<siteDirectory>-Config`, a sibling of `siteDirectory` unique to it. Not created — every
    /// writer (`SiteConfigStore.save`, `WranglerConfigFile.write`) creates it on first write, so
    /// a read-only test sees the same "no app state yet" a fresh package would.
    public static func configDirectory(for siteDirectory: URL) -> URL {
        let name = siteDirectory.lastPathComponent
        return siteDirectory.deletingLastPathComponent()
            .appendingPathComponent("\(name)-Config", isDirectory: true)
    }
}

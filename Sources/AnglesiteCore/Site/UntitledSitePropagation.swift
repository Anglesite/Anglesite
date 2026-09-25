import Foundation

/// Best-effort propagation of a site's display-name rename into its `.site-config` and
/// `Config/wrangler.toml`, for as long as the site hasn't touched Cloudflare yet (#1182). Distinct
/// from `WorkerNameRename`, which handles the post-deploy, collision-triggered rename flow and
/// deliberately leaves `SITE_NAME` untouched — this is the pre-deploy counterpart that keeps
/// `SITE_NAME` and `CF_PROJECT_NAME` in sync with the display name shown in the UI, whether the
/// site started out as the scaffold-time "Untitled" default or was scaffolded with a real name
/// and renamed again before its first publish.
public enum UntitledSitePropagation {
    /// Propagates `newDisplayName` into `SITE_NAME`/`CF_PROJECT_NAME` (and `wrangler.toml`'s
    /// `name` line) when — and only when — the site hasn't touched Cloudflare yet (neither
    /// `SiteSettings.workerDeployed` nor `.workerProvisioned` is set in `Config/settings.plist`,
    /// #1960) and `CF_PROJECT_NAME` still equals the slug derived from the *current* `SITE_NAME`
    /// — i.e. nothing has hand-customized the project name away from what the display name would
    /// derive. Silently does nothing otherwise, or if any file is missing/unreadable/unwritable,
    /// or if `newDisplayName` is blank once sanitized — a display-name rename must never fail or
    /// throw because of this.
    public static func propagateIfUntitled(
        newDisplayName: String,
        siteDirectory: URL,
        configDirectory: URL,
        fileManager: FileManager = .default
    ) {
        let configURL = siteDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        guard fileManager.fileExists(atPath: configURL.path),
              let config = try? String(contentsOf: configURL, encoding: .utf8) else { return }

        let settings = (try? SiteConfigStore.read(from: configDirectory, fileManager: fileManager)) ?? SiteSettings()
        guard settings.workerDeployed != true, settings.workerProvisioned != true else { return }

        guard let currentSiteName = SiteConfigFile.value(forKey: "SITE_NAME", in: config),
              let currentProjectName = SiteConfigFile.value(forKey: "CF_PROJECT_NAME", in: config),
              currentProjectName == WorkerSiteName.derive(from: currentSiteName) else { return }

        // .site-config only stores single-line `KEY=value` entries — take the first line only, so
        // an embedded newline in newDisplayName (e.g. from a hand-edited plist string) can't
        // inject extra lines into this git-tracked file.
        let sanitizedName = (newDisplayName.components(separatedBy: .newlines).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedName.isEmpty else { return }

        let newSlug = WorkerSiteName.derive(from: sanitizedName)
        guard WorkerComposition.isValidSiteName(newSlug) else { return }

        // .site-config first: it's what DeployCoordinator.resolveWorkerSiteName actually reads at
        // publish time, so if the wrangler.toml write below fails, the site still deploys under
        // the new slug rather than silently keeping the stale one.
        let updatedConfig = SiteConfigFile.upsert(
            [("SITE_NAME", sanitizedName), ("CF_PROJECT_NAME", newSlug)],
            into: config
        )
        try? updatedConfig.write(to: configURL, atomically: true, encoding: .utf8)

        guard let toml = WranglerConfigFile.read(configDirectory: configDirectory),
              let renamed = WranglerConfigFile.rewritingName(newSlug, in: toml) else { return }
        try? WranglerConfigFile.write(renamed, configDirectory: configDirectory, fileManager: fileManager)
    }
}

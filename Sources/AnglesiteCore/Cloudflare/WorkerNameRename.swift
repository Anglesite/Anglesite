import Foundation

/// Applies a Worker-name change to an already-scaffolded site's `Config/wrangler.toml` and
/// `Source/.site-config`, after a Worker-name collision is detected at first deploy (#740).
///
/// Only the `name = "..."` line in `wrangler.toml` is rewritten — not a full regenerate via
/// `WorkerComposition.generateWranglerToml` — because there is no reader that reconstructs the
/// `[Feature]` list or provisioned D1/KV resource IDs from an already-written file, and a full
/// regenerate would silently drop any social-feature config a user provisioned (via
/// `SocialWorkerProvisionCommand`) before their first deploy.
public enum WorkerNameRename {
    /// Ways ``WorkerNameRename/apply(newName:siteDirectory:configDirectory:fileManager:)`` can
    /// refuse — all thrown before any write, so a failed rename never leaves the two files
    /// half-updated.
    public enum RenameError: Error, Equatable, Sendable {
        /// `newName` doesn't satisfy wrangler's `name` rule (`WorkerSiteName.isValidWorkerName`:
        /// lowercase alphanumerics, underscores, and dashes).
        case invalidName(String)
        /// No `Config/wrangler.toml` — the site was never scaffolded for deploy, so there is
        /// nothing to rename.
        case wranglerConfigMissing
        /// `wrangler.toml` exists but has no `name = "..."` line to rewrite — surfaced rather
        /// than appending one, since a hand-edited file shouldn't be silently restructured.
        case nameLineNotFound
    }

    /// Rewrites `Config/wrangler.toml`'s `name = "..."` line and `.site-config`'s
    /// `CF_PROJECT_NAME` to `newName`. Throws `.invalidName` before touching any file if
    /// `newName` doesn't satisfy wrangler's lowercase `name` rule
    /// (`WorkerComposition.isValidSiteName`), so a rejected name never gets partially written.
    public static func apply(
        newName: String, siteDirectory: URL, configDirectory: URL, fileManager: FileManager = .default
    ) throws {
        guard WorkerComposition.isValidSiteName(newName) else {
            throw RenameError.invalidName(newName)
        }

        guard let toml = WranglerConfigFile.read(configDirectory: configDirectory) else {
            throw RenameError.wranglerConfigMissing
        }
        guard let renamed = WranglerConfigFile.rewritingName(newName, in: toml) else {
            throw RenameError.nameLineNotFound
        }
        try WranglerConfigFile.write(renamed, configDirectory: configDirectory, fileManager: fileManager)

        let configURL = siteDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updated = SiteConfigFile.upsert([("CF_PROJECT_NAME", newName)], into: config)
        try updated.write(to: configURL, atomically: true, encoding: .utf8)
    }
}

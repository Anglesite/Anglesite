import Foundation

/// Moves app-owned deploy state out of a site's `Source/` repo into its package's `Config/`
/// (#1960, decision D6) — one of the existing-site migration steps `ExistingSiteMigration` and
/// `SiteWindowModel.loadAndStart()` run on every open, under the #745 mechanism (idempotent
/// check → silent apply → batch commit via `ExistingSiteMigrationCommitter`).
///
/// Three things relocate, each independently idempotent so a crash between steps is repaired by
/// the next open:
///
/// 1. `Source/wrangler.toml` → `Config/wrangler.toml` (`WranglerConfigFile`). If `Config/` already
///    has a copy (a site migrated on another Mac, or a stale `Source/` copy that came back through
///    a clone), `Config/`'s copy wins — it's the one the app has been regenerating — and the
///    `Source/` copy is just removed.
/// 2. `.site-config`'s `CF_WORKER_DEPLOYED` / `CF_WORKER_PROVISIONED` / `CF_SOURCE_BUCKET` →
///    `SiteSettings.workerDeployed` / `.workerProvisioned` / `.sourceBundleBucket`. Settings are
///    written *before* the keys are removed from `.site-config`, so an interruption leaves both
///    (re-copied harmlessly next time) rather than neither.
/// 3. `wrangler.toml` is added to `.gitignore` so a copy that reaches the working tree by any
///    other route never enters the repo again.
///
/// No decision is ever asked: the app knows where its own state belongs ("the app advises; it does
/// not delegate the decision"). The other keys in `.site-config` (`SITE_URL`, `CF_PROJECT_NAME`,
/// `ATPROTO_DID`, …) stay put — the template's build scripts read them, so they are build input,
/// not app-only state; see `docs/specs/2026-09-08-site-file-ownership-classification-decision.md`.
public enum DeployStateRelocation {
    /// The `.site-config` keys that move to `SiteSettings`, in the order they are migrated.
    public static let legacyMarkerKeys = ["CF_WORKER_DEPLOYED", "CF_WORKER_PROVISIONED", "CF_SOURCE_BUCKET"]

    /// What ``check(sourceDirectory:configDirectory:)`` found still living in `Source/`.
    public struct Plan: Equatable, Sendable {
        /// `Source/wrangler.toml` exists and must move (or, if `Config/` already has one, go).
        public var legacyWranglerConfigPresent = false
        /// The subset of ``legacyMarkerKeys`` still present in `.site-config`.
        public var legacyMarkerKeys: [String] = []
        /// `.gitignore` exists but doesn't list `wrangler.toml` yet. Only ever `true` when the file
        /// exists: a `Source/` with no `.gitignore` at all isn't a template site, and inventing one
        /// just to hold this line would be a change the owner never asked for.
        public var gitignoreEntryMissing = false

        /// `true` when nothing needs to move — the common case on every open after the first.
        public var isEmpty: Bool {
            !legacyWranglerConfigPresent && legacyMarkerKeys.isEmpty && !gitignoreEntryMissing
        }

        public init(legacyWranglerConfigPresent: Bool = false, legacyMarkerKeys: [String] = [], gitignoreEntryMissing: Bool = false) {
            self.legacyWranglerConfigPresent = legacyWranglerConfigPresent
            self.legacyMarkerKeys = legacyMarkerKeys
            self.gitignoreEntryMissing = gitignoreEntryMissing
        }
    }

    /// Read-only inspection — never touches disk beyond reading the three files involved.
    public static func check(sourceDirectory: URL, configDirectory: URL, fileManager: FileManager = .default) -> Plan {
        var plan = Plan()
        plan.legacyWranglerConfigPresent = fileManager.fileExists(
            atPath: WranglerConfigFile.legacyURL(sourceDirectory: sourceDirectory).path)

        let siteConfigURL = sourceDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
        if let config = try? String(contentsOf: siteConfigURL, encoding: .utf8) {
            plan.legacyMarkerKeys = legacyMarkerKeys.filter { SiteConfigFile.value(forKey: $0, in: config) != nil }
        }

        let gitignoreURL = sourceDirectory.appendingPathComponent(".gitignore")
        if let gitignore = try? String(contentsOf: gitignoreURL, encoding: .utf8) {
            plan.gitignoreEntryMissing = WranglerConfigFile.addingGitignoreEntry(to: gitignore) != gitignore
        }
        return plan
    }

    /// Applies every step ``check(sourceDirectory:configDirectory:fileManager:)`` finds and returns
    /// the `Source/`-relative paths it changed, for the caller to hand to
    /// `ExistingSiteMigrationCommitter.commit` (`wrangler.toml` appears there as a *deletion* —
    /// the committer stages tracked-but-missing paths as removals). Best-effort per step: a
    /// failure in one leaves the others to proceed and the failed one to retry on the next open.
    @discardableResult
    public static func apply(sourceDirectory: URL, configDirectory: URL, fileManager: FileManager = .default) -> [String] {
        let plan = check(sourceDirectory: sourceDirectory, configDirectory: configDirectory, fileManager: fileManager)
        var touched: [String] = []

        if plan.legacyWranglerConfigPresent {
            let legacyURL = WranglerConfigFile.legacyURL(sourceDirectory: sourceDirectory)
            var moved = WranglerConfigFile.read(configDirectory: configDirectory) != nil
            if !moved, let toml = try? String(contentsOf: legacyURL, encoding: .utf8),
               (try? WranglerConfigFile.write(toml, configDirectory: configDirectory, fileManager: fileManager)) != nil {
                moved = true
            }
            // Only remove the Source/ copy once Config/ verifiably holds one — losing the file
            // outright would strand the site's provisioned resource ids.
            if moved, (try? fileManager.removeItem(at: legacyURL)) != nil {
                touched.append(WranglerConfigFile.filename)
            }
        }

        if !plan.legacyMarkerKeys.isEmpty {
            let siteConfigURL = sourceDirectory.appendingPathComponent(WebsiteAnalyticsAsset.configRelativePath)
            if let config = try? String(contentsOf: siteConfigURL, encoding: .utf8) {
                var settings = (try? SiteConfigStore.read(from: configDirectory, fileManager: fileManager)) ?? SiteSettings()
                if SiteConfigFile.value(forKey: "CF_WORKER_DEPLOYED", in: config) != nil { settings.workerDeployed = true }
                if SiteConfigFile.value(forKey: "CF_WORKER_PROVISIONED", in: config) != nil { settings.workerProvisioned = true }
                if let bucket = SiteConfigFile.value(forKey: "CF_SOURCE_BUCKET", in: config)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !bucket.isEmpty {
                    settings.sourceBundleBucket = bucket
                }
                if (try? SiteConfigStore.write(settings, to: configDirectory, fileManager: fileManager)) != nil {
                    let stripped = SiteConfigFile.remove(plan.legacyMarkerKeys, from: config)
                    if (try? stripped.write(to: siteConfigURL, atomically: true, encoding: .utf8)) != nil {
                        touched.append(WebsiteAnalyticsAsset.configRelativePath)
                    }
                }
            }
        }

        if plan.gitignoreEntryMissing {
            let gitignoreURL = sourceDirectory.appendingPathComponent(".gitignore")
            if let gitignore = try? String(contentsOf: gitignoreURL, encoding: .utf8) {
                let updated = WranglerConfigFile.addingGitignoreEntry(to: gitignore)
                if updated != gitignore, (try? updated.write(to: gitignoreURL, atomically: true, encoding: .utf8)) != nil {
                    touched.append(".gitignore")
                }
            }
        }
        return touched
    }
}

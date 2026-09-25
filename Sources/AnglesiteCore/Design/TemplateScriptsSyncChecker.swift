import Foundation
// OSLog is Darwin-only; AnglesiteCore is part of the Linux-portable target set (Package.swift,
// cross-platform port design §9/§10), so logging falls back to stderr off-Darwin — same pattern
// as WorkerCatalogFetcher.swift/WorkersConformanceFetcher.swift.
#if canImport(OSLog)
import OSLog
#endif

/// Detects which app-owned files (`scripts/`, `src/lib/`) a site needs refreshed, and which have
/// been customized since their last baseline (design doc, #1053). Both are applied by the app
/// without asking (owner decision D1, #1962) — the split only changes how the owner is told.
/// Unlike `DependencySyncChecker`, this type performs its own `Config/`-only baseline bookkeeping
/// (backfilling a missing entry, initializing a first-encounter baseline) as it goes — see the
/// design doc's "Note on checker purity." It never writes anything under `Source/`; only
/// `TemplateScriptsSyncApplier` does that.
public enum TemplateScriptsSyncChecker {
    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "io.dwk.anglesite", category: "TemplateScriptsSyncChecker")
    #endif

    /// Portable off-Darwin (no OSLog on Linux — cross-platform port design §9/§10).
    private static func logUnreadableSiteFile(_ relativePath: String) {
        #if canImport(OSLog)
        logger.error("Skipping \(relativePath, privacy: .public): exists but couldn't be read as UTF-8")
        #else
        FileHandle.standardError.write(Data("[TemplateScriptsSyncChecker] Skipping \(relativePath): exists but couldn't be read as UTF-8\n".utf8))
        #endif
    }

    /// Compares every app-owned template file against the site's copy and the
    /// recorded baseline, classifying each as a plain create/refresh (missing, or unmodified-but-
    /// stale) vs. a divergence (customized, or never baselined, *and* the template moved on) —
    /// the latter is restored rather than refreshed, and reported as such.
    /// Side effects are `Config/`-only: matching or first-encounter files get their baseline
    /// entries recorded/backfilled here (design doc's legacy-site trade-off — a first
    /// encounter's current content is assumed untouched). An unreadable site file is skipped
    /// and logged, never overwritten. Returns the plan; never throws.
    public static func check(
        sourceDirectory: URL,
        configDirectory: URL,
        templateDirectory: URL
    ) -> TemplateScriptsSyncPlan {
        var baseline = TemplateScriptsBaseline.load(from: configDirectory)
        var baselineChanged = false
        var toApply: [TemplateScriptsSyncAction] = []
        var divergences: [TemplateScriptsDivergence] = []

        for relativePath in TemplateScriptsManifest.appOwnedRelativePaths(templateRoot: templateDirectory) {
            guard let templateContent = try? String(
                contentsOf: templateDirectory.appendingPathComponent(relativePath), encoding: .utf8
            ) else { continue }
            let templateHash = VectorMath.stableHash(templateContent)

            let siteURL = sourceDirectory.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: siteURL.path) else {
                // Genuinely absent — the template added this file since the site scaffolded.
                // Nothing of the owner's to lose, so this is safe to create silently.
                toApply.append(.create(relativePath: relativePath))
                continue
            }
            guard let siteContent = try? String(contentsOf: siteURL, encoding: .utf8) else {
                // The file exists but couldn't be read as UTF-8 — permissions, a transient I/O
                // error, or genuinely non-UTF-8 content. Unlike "doesn't exist," this is NOT safe
                // to silently overwrite (there may be something of the owner's to lose), so skip
                // it entirely rather than guessing; logged so it isn't invisible.
                logUnreadableSiteFile(relativePath)
                continue
            }
            let siteHash = VectorMath.stableHash(siteContent)

            if templateHash == siteHash {
                if baseline.files[relativePath]?.baselineHash != siteHash {
                    baseline.files[relativePath] = TemplateScriptsBaseline.Entry(baselineHash: siteHash)
                    baselineChanged = true
                }
                continue
            }

            let hadNoBaseline = baseline.files[relativePath] == nil
            if hadNoBaseline {
                // First encounter for this site (#745 changed this branch): its current content
                // is recorded as a *provisional* baseline so `restore()` has an entry to update,
                // but it is never treated as reconciled on this same pass. The app can't tell
                // "stale but untouched" from "this copy was changed" without a prior baseline,
                // so it falls through to the divergence list below — restored, and reported as
                // restored rather than merely refreshed.
                baseline.files[relativePath] = TemplateScriptsBaseline.Entry(baselineHash: siteHash)
                baselineChanged = true
            }
            let entry = baseline.files[relativePath]!

            // A pre-#1962 baseline may still carry an `acknowledgedTemplateHash` from a "keep my
            // version" the owner once chose. It is deliberately not consulted: owner decision D1
            // (2026-09-08) reaffirmed that app-owned files are the app's to keep current, and D5
            // forbids a keep-mine for the gate outright — so a formerly-declined divergence is
            // restored like any other on the next pass.
            if !hadNoBaseline && entry.baselineHash == siteHash {
                toApply.append(.refresh(relativePath: relativePath))
            } else {
                divergences.append(TemplateScriptsDivergence(relativePath: relativePath, templateHash: templateHash))
            }
        }

        if baselineChanged {
            try? baseline.save(to: configDirectory)
        }
        return TemplateScriptsSyncPlan(toApply: toApply, divergences: divergences)
    }
}

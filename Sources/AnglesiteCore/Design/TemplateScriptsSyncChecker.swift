import Foundation
// OSLog is Darwin-only; AnglesiteCore is part of the Linux-portable target set (Package.swift,
// cross-platform port design §9/§10), so logging falls back to stderr off-Darwin — same pattern
// as WorkerCatalogFetcher.swift/WorkersConformanceFetcher.swift.
#if canImport(OSLog)
import OSLog
#endif

/// Detects which app-owned files a site needs refreshed (`scripts/`, `src/lib/`, and on an EmDash
/// site its overlay's code and routes, #2177), and which have been customized since their last
/// baseline (design doc, #1053). Both are applied by the app without asking (owner decision D1,
/// #1962) — the split only changes how the owner is told.
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

        let appOwned = TemplateScriptsManifest.appOwnedFiles(templateRoot: templateDirectory, sourceDirectory: sourceDirectory)
        for file in appOwned {
            // Keyed on the site path; an EmDash site's overlay files are read from the overlay (#2177).
            let relativePath = file.sitePath
            guard let templateContent = try? String(
                contentsOf: templateDirectory.appendingPathComponent(file.templatePath), encoding: .utf8
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

        // Files a later template dropped (#2179): baselined once, no longer app-owned.
        var toRemove: [String] = []
        var releasedCustomized: [String] = []
        if canPrune(sourceDirectory: sourceDirectory) {
            let current = Set(appOwned.map(\.sitePath))
            let readRoots = templateRootsRead(appOwned)
            let emdash = SiteEditingSurfaces.forSourceDirectory(sourceDirectory).serverRenderedDeploy
            for (relativePath, entry) in baseline.files.sorted(by: { $0.key < $1.key }) where !current.contains(relativePath) {
                // A key that could reach outside `Source/` (a corrupted or hand-edited baseline):
                // never followed, only forgotten.
                guard isContainedRelativePath(relativePath) else {
                    baseline.files[relativePath] = nil
                    baselineChanged = true
                    continue
                }
                // Its root wasn't read whole (a template missing `src/lib/`, the overlay or
                // `worker/`): that it's absent says nothing, so it is left for a later pass.
                let roots = templateRoots(forSitePath: relativePath, emdash: emdash)
                guard !roots.isEmpty, roots.allSatisfy(readRoots.contains) else { continue }
                // Still shipped, just no longer the app's (an exclusion added, a file reclassified):
                // the site may import it, so it stays, and the app stops keeping it.
                if templateShips(relativePath, templateDirectory: templateDirectory, emdash: emdash) {
                    baseline.files[relativePath] = nil
                    baselineChanged = true
                    continue
                }
                let siteURL = sourceDirectory.appendingPathComponent(relativePath)
                guard FileManager.default.fileExists(atPath: siteURL.path) else {
                    // Already gone: nothing to remove, and nothing left to keep track of.
                    baseline.files[relativePath] = nil
                    baselineChanged = true
                    continue
                }
                // Unreadable: left alone, as above, rather than guessing whether it was changed.
                guard let siteContent = try? String(contentsOf: siteURL, encoding: .utf8) else {
                    logUnreadableSiteFile(relativePath)
                    continue
                }
                if VectorMath.stableHash(siteContent) == entry.baselineHash {
                    toRemove.append(relativePath)
                } else {
                    // Changed since the app wrote it: the owner's work now, so it stays, and the
                    // app stops keeping it (no later pass restores or removes it).
                    releasedCustomized.append(relativePath)
                    baseline.files[relativePath] = nil
                    baselineChanged = true
                }
            }
        }

        if baselineChanged {
            try? baseline.save(to: configDirectory)
        }
        return TemplateScriptsSyncPlan(
            toApply: toApply, divergences: divergences, toRemove: toRemove, releasedCustomized: releasedCustomized)
    }

    /// Whether a baselined file missing from the app-owned set can mean the template dropped it:
    /// only on a site whose kind is known. An unreadable or newer marker hides an EmDash site's
    /// overlay from the set, which would make every overlay file look dropped.
    static func canPrune(sourceDirectory: URL) -> Bool {
        switch SiteEditingSurfaces.forSourceDirectory(sourceDirectory).kind {
        case .anglesite, .emdash: return true
        case .unrecognized: return false
        }
    }

    /// The template directories the app-owned files come from (`TemplateScriptsManifest`), each
    /// paired with the site-path prefix it supplies.
    private static let scriptsRoot = "scripts"
    private static let libRoot = "src/lib"
    private static let workerRoot = "worker"
    private static var overlaySourceRoot: String { "\(EmDashScaffold.overlayDirectoryName)/src" }

    /// The roots that supplied at least one app-owned file this pass: the ones read whole enough
    /// to vouch that a file missing under them was dropped. A root missing from the template, or
    /// read empty, vouches for nothing.
    static func templateRootsRead(_ appOwned: [TemplateScriptsManifest.AppOwnedFile]) -> Set<String> {
        var read: Set<String> = []
        for root in [scriptsRoot, libRoot, workerRoot, overlaySourceRoot]
        where appOwned.contains(where: { $0.templatePath.hasPrefix(root + "/") }) {
            read.insert(root)
        }
        return read
    }

    /// The roots that must have been read before `sitePath`'s absence can be trusted; empty for a
    /// path no root supplies, which is never pruned. On an EmDash site a `src/lib/` file can come
    /// from the template or the overlay, so both must have been read.
    static func templateRoots(forSitePath sitePath: String, emdash: Bool) -> [String] {
        if sitePath.hasPrefix(scriptsRoot + "/") { return [scriptsRoot] }
        if sitePath.hasPrefix(libRoot + "/") { return emdash ? [libRoot, overlaySourceRoot] : [libRoot] }
        guard emdash else { return [] }
        if sitePath.hasPrefix(workerRoot + "/") { return [workerRoot] }
        // The overlay's routes, entry and config: vouched for by its `src/` having been read.
        if sitePath.hasPrefix("src/") || sitePath == "astro.config.ts" { return [overlaySourceRoot] }
        return []
    }

    /// Whether the template still has the file at either place it could supply it from.
    private static func templateShips(_ sitePath: String, templateDirectory: URL, emdash: Bool) -> Bool {
        var candidates = [sitePath]
        if emdash { candidates.append("\(EmDashScaffold.overlayDirectoryName)/\(sitePath)") }
        return candidates.contains {
            FileManager.default.fileExists(atPath: templateDirectory.appendingPathComponent($0).path)
        }
    }

    /// A relative path that stays inside the directory it is resolved against: no leading `/`, and
    /// no empty, `.` or `..` component.
    static func isContainedRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}

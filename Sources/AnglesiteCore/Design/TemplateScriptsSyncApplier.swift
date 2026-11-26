import Foundation

/// Applies what `TemplateScriptsSyncChecker` found (design doc §Apply). Two entry points:
/// `applyQueued` for the silent create/refresh actions, and `restore` for a divergence — a file
/// whose site copy had been changed. Neither asks the owner anything: app-owned files are the
/// app's own build/security machinery, so the app knows the right answer and applies it (#1053;
/// owner decision D1, #1962). There is deliberately no "keep mine" path in this type at all —
/// the gate script must never be left in a state the app didn't write (D5, #1958).
public enum TemplateScriptsSyncApplier {
    /// Why an apply/restore stopped. Both cases name the file so the caller can say which one —
    /// and, for `applyQueued`, everything written before it keeps its baseline (see that method).
    public enum ApplyError: Error, Equatable {
        /// The template's own copy couldn't be read — the bundled template is missing or
        /// unreadable, so there's nothing correct to write.
        case templateReadFailed(relativePath: String)
        /// The site-side write failed (permissions, disk); the baseline was not updated for this
        /// file, so the next check pass will retry it.
        case writeFailed(relativePath: String)
    }

    /// Writes each queued create/refresh into `sourceDirectory` and records the new baseline
    /// hash after every successful write — so a mid-batch failure leaves every file already
    /// written with its matching baseline entry intact (nothing gets re-flagged as divergent on
    /// the next pass). Throws on the first file that can't be read from the template or written
    /// to the site; earlier writes stand.
    public static func applyQueued(
        _ actions: [TemplateScriptsSyncAction],
        sourceDirectory: URL,
        configDirectory: URL,
        templateDirectory: URL
    ) throws {
        guard !actions.isEmpty else { return }
        var baseline = TemplateScriptsBaseline.load(from: configDirectory)
        for action in actions {
            try write(
                relativePath: action.relativePath, baseline: &baseline,
                sourceDirectory: sourceDirectory, configDirectory: configDirectory, templateDirectory: templateDirectory
            )
        }
    }

    /// Restores one divergent app-owned file to the app's copy and re-baselines it. Overwrites
    /// whatever the site had — git-recoverable, since `Source/` is a real repo (the design doc's
    /// resolution that no sibling backup file is needed) — and the caller commits the restore so
    /// the owner's history records it.
    public static func restore(
        _ divergence: TemplateScriptsDivergence,
        sourceDirectory: URL,
        configDirectory: URL,
        templateDirectory: URL
    ) throws {
        var baseline = TemplateScriptsBaseline.load(from: configDirectory)
        try write(
            relativePath: divergence.relativePath, baseline: &baseline,
            sourceDirectory: sourceDirectory, configDirectory: configDirectory, templateDirectory: templateDirectory
        )
    }

    /// Removes a file a later template dropped (`TemplateScriptsSyncPlan.toRemove`, #2179) and
    /// forgets its baseline entry. The checker only queues a file whose site copy is still the
    /// app's, so nothing of the owner's is lost; the caller commits the removal. Throws
    /// `writeFailed` when the file can't be removed, leaving its entry for the next pass.
    public static func remove(
        relativePath: String,
        sourceDirectory: URL,
        configDirectory: URL
    ) throws {
        // Never outside `Source/`, whatever the baseline key says.
        guard TemplateScriptsSyncChecker.isContainedRelativePath(relativePath) else {
            throw ApplyError.writeFailed(relativePath: relativePath)
        }
        let siteURL = sourceDirectory.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: siteURL.path) {
            do {
                try FileManager.default.removeItem(at: siteURL)
            } catch {
                throw ApplyError.writeFailed(relativePath: relativePath)
            }
            removeEmptyParents(of: siteURL, within: sourceDirectory)
        }
        var baseline = TemplateScriptsBaseline.load(from: configDirectory)
        baseline.files[relativePath] = nil
        try? baseline.save(to: configDirectory)
    }

    /// Removes the directories a removal left empty, up to (not including) `sourceDirectory`, so a
    /// dropped route doesn't leave an empty `src/pages/…` folder behind. A folder holding only
    /// Finder's `.DS_Store` counts as empty, as it does in the manifest.
    private static func removeEmptyParents(of url: URL, within sourceDirectory: URL) {
        let root = sourceDirectory.standardizedFileURL.path
        var directory = url.deletingLastPathComponent().standardizedFileURL
        while directory.path.hasPrefix(root + "/"),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              contents.allSatisfy({ $0 == ".DS_Store" }) {
            guard (try? FileManager.default.removeItem(at: directory)) != nil else { return }
            directory = directory.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// The one write path: template → site, then the baseline entry, persisted immediately so a
    /// later failure in the same batch can't lose it.
    private static func write(
        relativePath: String,
        baseline: inout TemplateScriptsBaseline,
        sourceDirectory: URL,
        configDirectory: URL,
        templateDirectory: URL
    ) throws {
        // An EmDash site's overlay files are read from the overlay (#2177).
        let templateURL = templateDirectory.appendingPathComponent(TemplateScriptsManifest.templatePath(
            forSitePath: relativePath, templateRoot: templateDirectory, sourceDirectory: sourceDirectory))
        guard let templateContent = try? String(contentsOf: templateURL, encoding: .utf8) else {
            throw ApplyError.templateReadFailed(relativePath: relativePath)
        }
        let siteURL = sourceDirectory.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: siteURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            try templateContent.write(to: siteURL, atomically: true, encoding: .utf8)
        } catch {
            throw ApplyError.writeFailed(relativePath: relativePath)
        }
        baseline.files[relativePath] = TemplateScriptsBaseline.Entry(
            baselineHash: VectorMath.stableHash(templateContent)
        )
        // Persisted after each successful write, not once at the end — if a later action in
        // the same batch throws, everything already written keeps its matching baseline entry.
        try? baseline.save(to: configDirectory)
    }
}

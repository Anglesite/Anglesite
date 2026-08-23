import Foundation

/// A phase the import transform has started, reported through `ImportTransform.run`'s `onStep`
/// callback so a caller can drive a progress UI without polling.
///
/// Every case except `.warning` is emitted exactly once, immediately before the phase it names
/// begins. `.warning` can be emitted any number of times during the content-writing phase, one
/// per per-item problem (an asset that couldn't be localized, or a file that couldn't be
/// written) — those problems never abort the run, they only ever add to the final
/// ``ImportReport/writeProblems``.
public enum ImportStep: Sendable, Equatable {
    /// Resolving the crawled snapshot into deduplicated import items (``ImportSourceResolver``).
    case resolvingContent
    /// Classifying `itemCount` resolved items into collection/page destinations
    /// (``ContentClassifier``).
    case classifying(itemCount: Int)
    /// About to render and write `fileCount` content files (one per classified item).
    case writingContent(fileCount: Int)
    /// About to localize up to `imageCount` referenced images into `public/images/`.
    case localizingAssets(imageCount: Int)
    /// About to compute and merge `count` redirects into `redirects.json`.
    case writingRedirects(count: Int)
    /// Applying homepage-derived seeds to `.site-config`.
    case seedingConfig
    /// Persisting the completed ``ImportReport`` to the site's `Config/` directory.
    case savingReport
    /// A non-fatal problem was encountered and recorded in the eventual report; the run
    /// continues.
    case warning(String)
}

/// A fatal precondition failure that stops ``ImportTransform/run`` before it writes anything.
public enum ImportTransformError: Error, Equatable {
    /// `sourceDirectory` (the site's scaffolded `Source/` tree) doesn't exist at the given path.
    /// The transform assumes scaffolding already ran — see the task-level scaffold step that
    /// must precede an import — and refuses to write into a tree that isn't there.
    case sourceDirectoryMissing(String)
}

/// Orchestrates the full website-import pipeline: turns a crawled ``ImportSnapshot`` into content
/// files, localized images, redirects, and seeded `.site-config` inside an already-scaffolded
/// `Source/` tree, and persists an ``ImportReport`` describing what happened.
///
/// This is pure wiring — every real decision (how to resolve, classify, render, localize, or
/// redirect) lives in the component it delegates to (``ImportSourceResolver``,
/// ``ContentClassifier``, ``ImportEmitter``, ``AssetLocalizer``, ``RedirectsEmitter``,
/// ``ImportSiteConfig``, ``ImportPlanBuilder``). `ImportTransform` only sequences those calls,
/// reports progress, and turns a per-item failure into a recorded problem instead of an aborted
/// run.
public enum ImportTransform {
    /// Runs the full transform against an already-scaffolded `Source/` tree.
    ///
    /// Sequence: verify `sourceDirectory` exists → resolve the snapshot → classify the resolved
    /// items → for each classified item, localize its images, render it, and write the result →
    /// merge redirects for changed paths into `redirects.json` → seed `.site-config` from the
    /// homepage → assemble and save an ``ImportReport``. Every phase reports its ``ImportStep``
    /// via `onStep` immediately before it starts.
    ///
    /// A per-item failure — an image that couldn't be localized, or a file that couldn't be
    /// written — is recorded as an ``ImportProblem`` in the returned report's `writeProblems`
    /// and reported as `.warning` through `onStep`; it never aborts the run. Only a missing
    /// `sourceDirectory` throws.
    ///
    /// - Parameters:
    ///   - snapshot: The crawled site snapshot to import.
    ///   - snapshotDirectory: The directory `snapshot`'s captured asset bytes live under —
    ///     forwarded to ``AssetLocalizer`` to resolve each asset's `relativePath`.
    ///   - sourceDirectory: The destination site's `Source/` directory. Must already exist
    ///     (already scaffolded); content files, `public/images/`, `redirects.json`, and
    ///     `.site-config` are all written relative to it.
    ///   - configDirectory: The destination site's `Config/` directory, where the completed
    ///     ``ImportReport`` is saved.
    ///   - now: The deterministic clock used everywhere a fallback date is needed — undated blog
    ///     items (``ContentClassifier``) and undated frontmatter (``ImportEmitter``) — so the
    ///     transform's output never depends on wall-clock time.
    ///   - onStep: Called synchronously with each ``ImportStep`` as the run progresses.
    /// - Returns: The completed, already-saved ``ImportReport``.
    /// - Throws: ``ImportTransformError/sourceDirectoryMissing(_:)`` if `sourceDirectory` doesn't
    ///   exist, or any error `ImportReport.save(to:)` raises persisting the final report.
    @discardableResult
    public static func run(
        snapshot: ImportSnapshot, snapshotDirectory: URL,
        sourceDirectory: URL, configDirectory: URL,
        now: Date, onStep: @Sendable (ImportStep) -> Void
    ) throws -> ImportReport {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw ImportTransformError.sourceDirectoryMissing(sourceDirectory.path)
        }

        onStep(.resolvingContent)
        let resolved = ImportSourceResolver.resolve(snapshot)

        onStep(.classifying(itemCount: resolved.items.count))
        let classified = ContentClassifier.classify(resolved, now: now)

        var writeProblems: [ImportProblem] = []
        let (writtenPaths, installedImagePaths) = writeContent(
            classified, snapshot: snapshot, snapshotDirectory: snapshotDirectory,
            sourceDirectory: sourceDirectory, now: now,
            writeProblems: &writeProblems, onStep: onStep)

        let redirectEntries = RedirectsEmitter.entries(for: classified)
        onStep(.writingRedirects(count: redirectEntries.count))
        writeRedirects(redirectEntries, sourceDirectory: sourceDirectory,
                       writeProblems: &writeProblems, onStep: onStep)

        let seeds = ImportSiteConfig.seeds(fromHomepage: resolved.homepage)
        onStep(.seedingConfig)
        writeSiteConfig(seeds, sourceDirectory: sourceDirectory,
                        writeProblems: &writeProblems, onStep: onStep)

        let plan = ImportPlanBuilder.plan(resolved: resolved, classified: classified, seeds: seeds)
        let report = ImportReport(plan: plan, writtenPaths: writtenPaths,
                                  installedImagePaths: installedImagePaths,
                                  redirects: redirectEntries, writeProblems: writeProblems)

        onStep(.savingReport)
        try report.save(to: configDirectory)
        return report
    }

    /// Localizes and writes every classified item's content file, in order.
    ///
    /// For each item: localizes its referenced images (``AssetLocalizer``) into `public/images/`
    /// under `sourceDirectory`, renders the localized item (``ImportEmitter``), then writes the
    /// result to `sourceDirectory`, creating any missing intermediate directories. A localization
    /// problem or a write failure is appended to `writeProblems` and reported as `.warning`
    /// through `onStep`; the item is otherwise skipped and the loop continues.
    ///
    /// - Parameters:
    ///   - classified: The classified items to localize, render, and write, in the order they
    ///     should be written.
    ///   - snapshot: The crawled site snapshot, forwarded to ``AssetLocalizer`` to resolve
    ///     captured assets.
    ///   - snapshotDirectory: The directory `snapshot`'s captured asset bytes live under.
    ///   - sourceDirectory: The destination site's `Source/` directory.
    ///   - now: The deterministic fallback clock for undated frontmatter.
    ///   - writeProblems: Accumulates one ``ImportProblem`` per localization or write failure.
    ///   - onStep: Called with `.warning` for each problem as it's recorded.
    /// - Returns: The site-relative paths of every content file actually written, and the
    ///   site-relative paths of every image actually installed, both in processing order.
    private static func writeContent(
        _ classified: [ClassifiedItem], snapshot: ImportSnapshot, snapshotDirectory: URL,
        sourceDirectory: URL, now: Date, writeProblems: inout [ImportProblem],
        onStep: @Sendable (ImportStep) -> Void
    ) -> (writtenPaths: [String], installedImagePaths: [String]) {
        onStep(.writingContent(fileCount: classified.count))
        let totalImageCount = classified.reduce(0) { $0 + $1.item.images.count }
        onStep(.localizingAssets(imageCount: totalImageCount))

        var writtenPaths: [String] = []
        var installedImagePaths: [String] = []

        for classifiedItem in classified {
            let slug = itemSlug(for: classifiedItem.destination)
            let localized = AssetLocalizer.localize(
                markdown: classifiedItem.item.markdown, imageURLs: classifiedItem.item.images,
                itemSlug: slug, snapshot: snapshot, snapshotDirectory: snapshotDirectory,
                siteDirectory: sourceDirectory)
            installedImagePaths.append(contentsOf: localized.installedPaths)
            for problem in localized.problems {
                writeProblems.append(problem)
                onStep(.warning(problem.message))
            }

            var localizedItem = classifiedItem.item
            localizedItem.markdown = localized.markdown
            // The body isn't the only place an image URL reaches the emitted file: `photos` builds
            // its required `image:` from the item's `.photo` hint and `bookmarks` its optional one
            // from `images.first`. Both go through frontmatter, which `AssetLocalizer` never sees,
            // so apply the same URL → served-path mapping here. An image that was refused isn't in
            // the mapping and keeps its remote URL — already reported as an `ImportProblem` above,
            // so it stays visible rather than being silently rewritten to a file that isn't there.
            localizedItem.images = localizedItem.images.map { localized.localizedURLs[$0] ?? $0 }
            if case .photo(let image) = localizedItem.hint, let localPath = localized.localizedURLs[image] {
                localizedItem.hint = .photo(image: localPath)
            }
            let localizedClassified = ClassifiedItem(item: localizedItem, destination: classifiedItem.destination)
            let emission = ImportEmitter.emission(for: localizedClassified, now: now)
            let fileURL = sourceDirectory.appendingPathComponent(emission.relativePath)

            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try emission.contents.write(to: fileURL, atomically: true, encoding: .utf8)
                writtenPaths.append(emission.relativePath)
            } catch {
                let message = "Could not write \(emission.relativePath): \(error.localizedDescription)"
                writeProblems.append(ImportProblem(sourceURL: classifiedItem.item.sourceURL, message: message))
                onStep(.warning(message))
            }
        }

        return (writtenPaths, installedImagePaths)
    }

    /// Merges `entries` into `sourceDirectory/redirects.json`.
    ///
    /// An *absent* file starts from an empty redirect set (`[]`) — the template's own scaffold
    /// ships one, but a defensive fallback keeps this robust if that assumption is ever violated.
    /// An *existing but unreadable* file is a different case entirely and is never treated as
    /// empty: doing so would overwrite the owner's redirects — the ones keeping their old inbound
    /// links alive — with only this import's entries, destroying data the app couldn't read but
    /// could still see was there. That case records an ``ImportProblem``, reports `.warning`, and
    /// leaves the file untouched. A merge or write failure is handled the same way.
    ///
    /// - Parameters:
    ///   - entries: The redirects computed for this run (``RedirectsEmitter/entries(for:)``).
    ///   - sourceDirectory: The destination site's `Source/` directory.
    ///   - writeProblems: Accumulates one ``ImportProblem`` if the file is unreadable, or if the
    ///     merge or write fails.
    ///   - onStep: Called with `.warning` if a problem is recorded.
    private static func writeRedirects(
        _ entries: [RedirectEntry], sourceDirectory: URL,
        writeProblems: inout [ImportProblem], onStep: @Sendable (ImportStep) -> Void
    ) {
        let redirectsURL = sourceDirectory.appendingPathComponent("redirects.json")
        let existingJSON: String
        if FileManager.default.fileExists(atPath: redirectsURL.path) {
            do {
                existingJSON = try String(contentsOf: redirectsURL, encoding: .utf8)
            } catch {
                let message = "Could not read redirects.json, so it was left unchanged: "
                    + error.localizedDescription
                writeProblems.append(ImportProblem(sourceURL: redirectsURL.path, message: message))
                onStep(.warning(message))
                return
            }
        } else {
            existingJSON = "[]"
        }

        do {
            let merged = try RedirectsEmitter.merge(existingJSON: existingJSON, adding: entries)
            try merged.write(to: redirectsURL, atomically: true, encoding: .utf8)
        } catch {
            let message = "Could not update redirects.json: \(error.localizedDescription)"
            writeProblems.append(ImportProblem(sourceURL: redirectsURL.path, message: message))
            onStep(.warning(message))
        }
    }

    /// Applies homepage-derived `seeds` to `sourceDirectory/.site-config`, creating the file if
    /// the scaffold hasn't (an absent file reads as empty text, and ``ImportSiteConfig/apply``
    /// appends every seeded key to it). A write failure is appended to `writeProblems` and
    /// reported as `.warning`.
    /// - Parameters:
    ///   - seeds: The homepage-derived seed values to apply.
    ///   - sourceDirectory: The destination site's `Source/` directory.
    ///   - writeProblems: Accumulates one ``ImportProblem`` if the write fails.
    ///   - onStep: Called with `.warning` if a problem is recorded.
    private static func writeSiteConfig(
        _ seeds: SiteConfigSeeds, sourceDirectory: URL,
        writeProblems: inout [ImportProblem], onStep: @Sendable (ImportStep) -> Void
    ) {
        let configURL = sourceDirectory.appendingPathComponent(".site-config")
        let existingText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updatedText = ImportSiteConfig.apply(seeds, toConfigText: existingText)
        do {
            try updatedText.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            let message = "Could not write .site-config: \(error.localizedDescription)"
            writeProblems.append(ImportProblem(sourceURL: configURL.path, message: message))
            onStep(.warning(message))
        }
    }

    /// The slug ``AssetLocalizer`` should use as an installed image's filename prefix for an
    /// item bound for `destination`: a collection entry's own slug, or a page's route reduced to
    /// a single slug-safe token via ``ContentScaffold/slugify(_:)`` (e.g. `/about` → `about`).
    private static func itemSlug(for destination: ImportDestination) -> String {
        switch destination {
        case .collection(_, let slug):
            return slug
        case .page(let route):
            return ContentScaffold.slugify(route)
        }
    }
}

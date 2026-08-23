import Foundation

/// A summary of an import run: destination counts, image count, extraction-rung breakdown, and
/// unresolved problems — the material a site owner reviews before an import is written to disk.
public struct ImportPlan: Codable, Sendable, Equatable {
    /// Destination → count, e.g. `["blog": 42, "pages": 6, "notes": 3]`.
    public var counts: [String: Int]

    /// Total image URLs referenced across every classified item.
    public var imageCount: Int

    /// URLs whose content could not be extracted or converted (owner checklist material).
    public var problems: [ImportProblem]

    /// URLs excluded as archive/index pages (tag/category/author/search/pagination/feed
    /// listings) rather than real content.
    public var skippedURLs: [String]

    /// Extraction rung raw value (`ImportItem.Rung`, e.g. `"wp-rest"`) → count of items that
    /// rung produced.
    public var rungBreakdown: [String: Int]

    /// Homepage-derived `.site-config` seed values.
    public var seeds: SiteConfigSeeds

    /// Creates an import plan summary.
    /// - Parameters:
    ///   - counts: Destination → count map.
    ///   - imageCount: Total image URLs referenced across every classified item.
    ///   - problems: Problems collected during extraction.
    ///   - skippedURLs: URLs excluded as archive/index pages.
    ///   - rungBreakdown: Extraction rung raw value → count.
    ///   - seeds: Homepage-derived `.site-config` seed values.
    public init(counts: [String: Int], imageCount: Int, problems: [ImportProblem],
                skippedURLs: [String], rungBreakdown: [String: Int], seeds: SiteConfigSeeds) {
        self.counts = counts
        self.imageCount = imageCount
        self.problems = problems
        self.skippedURLs = skippedURLs
        self.rungBreakdown = rungBreakdown
        self.seeds = seeds
    }
}

/// Builds an ``ImportPlan`` summary from resolved and classified import content.
public enum ImportPlanBuilder {
    /// Builds a plan summarizing a batch of classified import content.
    ///
    /// `counts` keys are the collection name for a `.collection` destination, or `"pages"` for a
    /// `.page` destination. `imageCount` sums `item.images.count` across every classified item.
    /// `rungBreakdown` tallies each item's `ImportItem.rung.rawValue`. `problems` and
    /// `skippedURLs` pass through from `resolved` unchanged — classification never resolves or
    /// discards them.
    ///
    /// - Parameters:
    ///   - resolved: The resolved content the classification was built from — supplies
    ///     `problems` and `skippedURLs`.
    ///   - classified: The classified items — supplies destination counts, image count, and rung
    ///     breakdown.
    ///   - seeds: Homepage-derived `.site-config` seed values.
    /// - Returns: The summary plan.
    public static func plan(resolved: ResolvedContent, classified: [ClassifiedItem],
                            seeds: SiteConfigSeeds) -> ImportPlan {
        var counts: [String: Int] = [:]
        var rungBreakdown: [String: Int] = [:]
        var imageCount = 0

        for classifiedItem in classified {
            let key: String
            switch classifiedItem.destination {
            case .collection(let name, _):
                key = name
            case .page:
                key = "pages"
            }
            counts[key, default: 0] += 1
            rungBreakdown[classifiedItem.item.rung.rawValue, default: 0] += 1
            imageCount += classifiedItem.item.images.count
        }

        return ImportPlan(counts: counts, imageCount: imageCount, problems: resolved.problems,
                          skippedURLs: resolved.skippedURLs, rungBreakdown: rungBreakdown,
                          seeds: seeds)
    }
}

/// A persisted record of a completed import: the plan it was built from, what was written to
/// disk, and any problems encountered while writing — saved to a site's `Config/` directory so
/// the app can show the owner what an import did after the fact.
public struct ImportReport: Codable, Sendable, Equatable {
    /// The filename ``save(to:)``/``load(from:)`` use within a site's `Config/` directory.
    public static let fileName = "import-report.json"

    /// The plan the report was generated from.
    public var plan: ImportPlan

    /// Site-relative paths of content files written by the import.
    public var writtenPaths: [String]

    /// Site-relative paths of images installed by the import.
    public var installedImagePaths: [String]

    /// Redirects emitted for content whose served path changed from its source URL.
    public var redirects: [RedirectEntry]

    /// Problems encountered while writing content or images — distinct from `plan.problems`,
    /// which covers extraction problems found before any write happened.
    public var writeProblems: [ImportProblem]

    /// Creates an import report.
    /// - Parameters:
    ///   - plan: The plan the report was generated from.
    ///   - writtenPaths: Site-relative paths of content files written by the import.
    ///   - installedImagePaths: Site-relative paths of images installed by the import.
    ///   - redirects: Redirects emitted for content whose served path changed.
    ///   - writeProblems: Problems encountered while writing content or images.
    public init(plan: ImportPlan, writtenPaths: [String], installedImagePaths: [String],
                redirects: [RedirectEntry], writeProblems: [ImportProblem]) {
        self.plan = plan
        self.writtenPaths = writtenPaths
        self.installedImagePaths = installedImagePaths
        self.redirects = redirects
        self.writeProblems = writeProblems
    }

    /// Saves the report as pretty-printed, sorted-keys JSON to
    /// `configDirectory/import-report.json`.
    /// - Parameter configDirectory: The site's `Config/` directory.
    /// - Throws: Any error `JSONEncoder` raises encoding the report, or from writing the file.
    public func save(to configDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: configDirectory.appendingPathComponent(Self.fileName))
    }

    /// Loads a previously saved report from `configDirectory/import-report.json`.
    /// - Parameter configDirectory: The site's `Config/` directory.
    /// - Returns: The decoded report.
    /// - Throws: Any error from reading the file, or `DecodingError` if its contents aren't a
    ///   valid encoded ``ImportReport``.
    public static func load(from configDirectory: URL) throws -> ImportReport {
        let data = try Data(contentsOf: configDirectory.appendingPathComponent(Self.fileName))
        return try JSONDecoder().decode(ImportReport.self, from: data)
    }
}

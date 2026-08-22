import Foundation

/// A single 301 redirect, matching the shape the template's `redirects.json` (and its
/// `anglesite-redirects` Astro integration) expects: `source`/`destination` are site-relative
/// paths starting with `/`, `code` is the HTTP status.
public struct RedirectEntry: Codable, Sendable, Equatable {
    /// The old, no-longer-served path a visitor might still request.
    public var source: String
    /// The path the site now serves that content at.
    public var destination: String
    /// The HTTP redirect status code (always `301` when emitted by ``RedirectsEmitter``).
    public var code: Int

    /// Initializes a redirect entry.
    /// - Parameters:
    ///   - source: The old, no-longer-served path a visitor might still request.
    ///   - destination: The path the site now serves that content at.
    ///   - code: The HTTP redirect status code.
    public init(source: String, destination: String, code: Int) {
        self.source = source
        self.destination = destination
        self.code = code
    }
}

/// Computes 301 redirects for content whose site-relative URL changed as part of an import, and
/// merges them into the template's `redirects.json`.
///
/// A site's imported URLs rarely match the destination the Anglesite template serves them at —
/// e.g. a WordPress dated permalink `/2024/05/01/hello/` becomes a `blog` collection entry served
/// at `/blog/hello/`. Without a redirect, every inbound link and search-engine index entry for the
/// old URL 404s the moment the import lands. `entries(for:)` computes the redirect set from the
/// same `ClassifiedItem`s `ImportEmitter` renders into content files, and `merge(existingJSON:adding:)`
/// folds them into the file the `anglesite-redirects` Astro integration (`scripts/redirects.ts`)
/// reads at build time.
public enum RedirectsEmitter {
    /// Where a classified item is now served, as a site-relative path.
    ///
    /// A collection entry serves at `/<collection>/<slug>/` — verified against every v1
    /// collection's actual route page: `blog` has a dedicated `blog/[...slug].astro`, and
    /// `notes`, `photos`, `bookmarks`, `replies`, and `likes` are all listed in
    /// `ENTRY_COLLECTIONS` (`Resources/Template/src/lib/collections.ts`), so they're all served
    /// by the generic `[collection]/[...slug].astro` at the same `/<collection>/<slug>/` shape. A
    /// page serves at its route, trailing-slash normalized via ``ContentScaffold/servedRoute(_:)``
    /// — Astro's directory-format routing always includes the trailing slash at request time.
    /// - Parameter destination: The classified item's destination.
    /// - Returns: The site-relative path the destination is served at, with a trailing slash.
    public static func servedPath(for destination: ImportDestination) -> String {
        switch destination {
        case .collection(let name, let slug):
            return "/\(name)/\(slug)/"
        case .page(let route):
            return ContentScaffold.servedRoute(route)
        }
    }

    /// Computes the 301 redirects needed for a batch of classified items.
    ///
    /// For each item, compares its source URL's path against ``servedPath(for:)`` after
    /// trailing-slash normalization: an unchanged path needs no redirect, and a changed path
    /// produces one from the old path to the new. Entries are deduplicated by `source` — the
    /// first item to claim an old path wins, later items with the same old path are dropped
    /// silently, since a redirect can only point a given source path at one destination.
    /// - Parameter classified: The items to compute redirects for, e.g. the same batch passed to
    ///   ``ImportEmitter/emission(for:now:)``.
    /// - Returns: One `RedirectEntry` per item whose served path changed, in input order, deduped
    ///   by `source`.
    public static func entries(for classified: [ClassifiedItem]) -> [RedirectEntry] {
        var seenSources = Set<String>()
        var result: [RedirectEntry] = []

        for classifiedItem in classified {
            let sourcePath = trailingSlashNormalized(path(of: classifiedItem.item.sourceURL))
            let destinationPath = trailingSlashNormalized(servedPath(for: classifiedItem.destination))

            guard sourcePath != destinationPath else { continue }
            guard !seenSources.contains(sourcePath) else { continue }

            seenSources.insert(sourcePath)
            result.append(RedirectEntry(source: sourcePath, destination: destinationPath, code: 301))
        }

        return result
    }

    /// Merges newly computed redirects into the template's existing `redirects.json` contents.
    ///
    /// Decodes `existingJSON` as a `RedirectEntry` array (the template ships `[]`), appends every
    /// entry in `adding` whose `source` isn't already present — existing entries always win, so a
    /// site owner's hand edit or an earlier import's redirect is never silently overwritten — and
    /// re-encodes the result. Re-encoding (rather than string-splicing) keeps the file's formatting
    /// stable regardless of how it was previously written.
    /// - Parameters:
    ///   - existingJSON: The current contents of `redirects.json` — a JSON array of redirect
    ///     entries, `[]` for a template that hasn't been touched yet.
    ///   - adding: The redirects to merge in, e.g. from ``entries(for:)``.
    /// - Returns: The complete new `redirects.json` contents: `.prettyPrinted`, `.sortedKeys`,
    ///   with a trailing newline.
    /// - Throws: `DecodingError` if `existingJSON` isn't a valid JSON array of `RedirectEntry`.
    public static func merge(existingJSON: String, adding: [RedirectEntry]) throws -> String {
        let existing = try JSONDecoder().decode([RedirectEntry].self, from: Data(existingJSON.utf8))
        var existingSources = Set(existing.map(\.source))

        var merged = existing
        for entry in adding where !existingSources.contains(entry.source) {
            merged.append(entry)
            existingSources.insert(entry.source)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(merged)
        let json = String(decoding: data, as: UTF8.self)
        return json + "\n"
    }

    /// Extracts the path component of a URL string, ignoring scheme/host/query/fragment.
    private static func path(of urlString: String) -> String {
        URLComponents(string: urlString)?.path ?? urlString
    }

    /// Appends a trailing slash if `path` doesn't already end with one, so the served-path
    /// comparison in ``entries(for:)`` isn't defeated by a bare path missing its slash.
    private static func trailingSlashNormalized(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}

import Foundation

/// Rewrites remote image URLs captured during import into local, first-party `/images/…` paths
/// (#1615).
///
/// The imported site's strict CSP (see `PreDeployCheck`) blocks remote image origins by default,
/// so an untouched `https://original-site.example/photo.jpg` reference would render broken once
/// deployed. This installs the bytes ``ImportSnapshot`` already captured into the new site's
/// `public/images/` (via ``LinkImageAsset``) and rewrites the markdown to point at the local copy
/// instead.
public enum AssetLocalizer {
    /// Rewrites remote image URLs in `markdown` to local `/images/…` paths, installing the
    /// captured bytes into the site's `public/images/`. Unmatched or refused images keep
    /// their remote URL and gain a problem entry (the strict CSP will block them at runtime).
    ///
    /// - Parameters:
    ///   - markdown: The item's Markdown body, containing zero or more occurrences of each URL in
    ///     `imageURLs`.
    ///   - imageURLs: The image URLs referenced by `markdown`, in the order they should be
    ///     numbered — each becomes slug `"<itemSlug>-<n>"` (1-based) on success.
    ///   - itemSlug: The importing item's slug, used as the installed image's filename prefix.
    ///   - snapshot: The crawl snapshot, used to resolve each URL to its captured asset record.
    ///   - snapshotDirectory: The directory the snapshot's asset bytes live under; each asset's
    ///     `relativePath` is relative to this.
    ///   - siteDirectory: The destination site's `Source/` directory, where `public/images/` is
    ///     created if needed.
    /// - Returns: The rewritten markdown, the site-relative paths of every image actually
    ///   installed (in `imageURLs` order), and one ``ImportProblem`` per URL that was refused or
    ///   couldn't be resolved.
    public static func localize(
        markdown: String, imageURLs: [String], itemSlug: String,
        snapshot: ImportSnapshot, snapshotDirectory: URL, siteDirectory: URL
    ) -> (markdown: String, installedPaths: [String], problems: [ImportProblem]) {
        var rewritten = markdown
        var installedPaths: [String] = []
        var problems: [ImportProblem] = []

        for (index, url) in imageURLs.enumerated() {
            let n = index + 1

            func refuse(_ reason: String) {
                problems.append(ImportProblem(sourceURL: url, message: "Image could not be imported: \(reason)"))
            }

            guard let asset = snapshot.asset(forURL: url) else {
                refuse("no captured asset for this URL")
                continue
            }
            let assetFile = snapshotDirectory.appendingPathComponent(asset.relativePath)
            guard let bytes = try? Data(contentsOf: assetFile) else {
                refuse("captured file is unreadable")
                continue
            }
            guard bytes.count <= LinkImageAsset.maximumImageBytes else {
                refuse("image exceeds the \(LinkImageAsset.maximumImageBytes)-byte limit")
                continue
            }
            guard let format = LinkImageAsset.format(sniffing: bytes) else {
                refuse("unrecognized or unsupported image format")
                continue
            }

            let slug = "\(itemSlug)-\(n)"
            guard let installedPath = try? LinkImageAsset.install(
                bytes: bytes, format: format, slug: slug, siteDirectory: siteDirectory
            ) else {
                refuse("could not write the image into the site")
                continue
            }

            installedPaths.append(installedPath)
            rewritten = Self.replacingURL(url, in: rewritten, with: LinkImageAsset.publicURLPath(slug: slug, format: format))
        }

        return (rewritten, installedPaths, problems)
    }

    /// Replaces every occurrence of `url` in `markdown` with `replacement`, but only where `url`
    /// isn't immediately followed by another URL-continuing character.
    ///
    /// A plain `replacingOccurrences(of:with:)` would treat `url` as a bare substring match, so
    /// replacing `https://e.com/photo.jpg` would also corrupt a longer, distinct reference like
    /// `https://e.com/photo.jpg?v=2` mid-string — silently smuggling an unvalidated URL fragment
    /// (`?v=2`) past the refusal path this function exists to enforce. Anchoring the match with a
    /// negative lookahead over the characters a URL can continue with (`[A-Za-z0-9?&=%._~/-]`)
    /// keeps replace-ALL semantics for exact matches while leaving longer URLs untouched.
    private static func replacingURL(_ url: String, in markdown: String, with replacement: String) -> String {
        let pattern = NSRegularExpression.escapedPattern(for: url) + "(?![A-Za-z0-9?&=%._~/-])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return markdown }
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return regex.stringByReplacingMatches(in: markdown, range: range, withTemplate: template)
    }
}

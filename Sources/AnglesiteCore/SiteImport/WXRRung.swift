import Foundation

/// Converts a fragment of rendered HTML into Markdown, extracting the image URLs it references.
/// The seam between the pure-Swift `SiteImport` pipeline and the platform-specific engine that
/// actually runs `JS/import-engine` — AnglesiteCore stays portable (no WebKit), so a concrete
/// conformance lives in `AnglesiteApp` (``OffscreenHTMLConverter``, offscreen `WKWebView`).
///
/// Implementations must never throw: a conversion failure should surface as empty output
/// (`("", [])`) so callers (``WXRRung``) can turn it into a recorded ``ImportProblem`` instead of
/// aborting the whole import — the same "never abort the run" convention every other stage in
/// this pipeline follows.
public protocol ImportHTMLConverter: Sendable {
    func convert(html: String) async -> (markdown: String, images: [String])
}

/// The WXR extraction rung: turns parsed WXR entries into ``ImportItem``s (#1636).
///
/// Unlike every other rung, WXR has no crawled ``ImportSnapshot`` to read from — it's a one-shot
/// file, not a live probe — so this doesn't fit the `items(from snapshot:)` shape the other rungs
/// share. It converts each entry's own `content:encoded`/`excerpt:encoded` HTML directly via the
/// injected ``ImportHTMLConverter``, the same "one converter for every ladder rung" approach the
/// transform-stage design doc specifies for WP REST/feed bodies that arrive as HTML strings.
public enum WXRRung {
    /// Extracts import items from parsed WXR entries.
    ///
    /// Filters to `wp:status == "publish"` and `wp:post_type` of `"post"`/`"page"` — every other
    /// status (draft, trash, private, …) or type (attachment, nav_menu_item, …) is silently
    /// skipped without even being converted, matching how a WordPress site itself never serves
    /// that content publicly. `post` maps to ``ImportItem/Hint/wpPost``, `page` to
    /// ``ImportItem/Hint/wpPage`` — the same hints ``WordPressRESTRung`` produces, so
    /// ``ContentClassifier`` needs no WXR-specific rule.
    ///
    /// - Parameters:
    ///   - entries: The parsed WXR entries (``WXRParser/parse(_:)``).
    ///   - convert: Converts a body's rendered HTML to Markdown + referenced image URLs.
    /// - Returns: One ``ImportItem`` per published post/page whose body converted to non-empty
    ///   Markdown, and one ``ImportProblem`` per entry that didn't (empty/failed conversion).
    public static func items(from entries: [WXREntry], convert: any ImportHTMLConverter) async
        -> (items: [ImportItem], problems: [ImportProblem]) {
        var items: [ImportItem] = []
        var problems: [ImportProblem] = []

        for entry in entries {
            guard entry.status == "publish" else { continue }
            let hint: ImportItem.Hint
            switch entry.postType {
            case "post": hint = .wpPost
            case "page": hint = .wpPage
            default: continue
            }

            let converted = await convert.convert(html: entry.contentEncoded)
            guard !converted.markdown.isEmpty else {
                problems.append(ImportProblem(sourceURL: entry.link,
                                              message: "Could not convert this entry's content to Markdown"))
                continue
            }

            var excerpt: String?
            if let excerptHTML = entry.excerptEncoded, !excerptHTML.isEmpty {
                let convertedExcerpt = await convert.convert(html: excerptHTML)
                excerpt = convertedExcerpt.markdown.isEmpty ? nil : convertedExcerpt.markdown
            }

            items.append(ImportItem(
                sourceURL: ImportSnapshot.normalizeURL(entry.link),
                title: entry.title, published: entry.published, markdown: converted.markdown,
                excerpt: excerpt, images: converted.images, rung: .wxr, hint: hint))
        }

        return (items, problems)
    }
}

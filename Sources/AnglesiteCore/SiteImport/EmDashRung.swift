import Foundation

/// The EmDash extraction rung: turns an ``EmDashExport`` into ``ImportItem``s (#2051).
///
/// EmDash stores a post as Portable Text in a schema-builder collection, with media in R2/S3.
/// Going out through WordPress's WXR flattens that to HTML and loses the block structure, custom
/// blocks, and every field the schema builder added, so this rung reads EmDash's own export —
/// the table dump its snapshot API and backup file both carry (``EmDashSnapshotDocument``) — and
/// converts each entry's Portable Text with ``PortableTextMarkdownConverter``, in pure Swift.
///
/// Like ``WXRRung``, it's a one-shot source without a live crawl, so it has two entry points:
/// ``items(from:siteURL:htmlConversions:)`` for an export the app fetched or the owner picked as
/// a file (feeding ``ImportTransform``'s `resolved:` overload), and ``items(from:)`` over an
/// ``ImportSnapshot`` whose probes captured the snapshot JSON, which is how
/// ``ImportSourceResolver`` runs it ahead of the WordPress rungs.
///
/// **Collection → content type.** EmDash has no fixed post types, so the mapping goes by the
/// collection's slug, onto the mf2 post types Anglesite's content model is built on (C.1,
/// `docs/specs/2026-06-29-c1-indieweb-content-model-decision.md`): `articles`/`posts`/`blog`
/// → article (the `blog` collection), `notes`/`statuses` → note, `photos` → photo, `bookmarks`/
/// `links` → bookmark, `likes` → like, `replies` → reply, `pages` → page. Any other collection —
/// a `recipes` the owner built — becomes articles when its entries have a title and notes when
/// they don't, and one ``ImportProblem`` per such collection says so, so the owner sees the
/// guess in the import summary. A collection's `urlPattern` gives each entry its source URL, so
/// ``RedirectsEmitter`` can keep EmDash's old links (`/articles/hello/`) pointing at the new
/// path (`/blog/hello/`). A collection EmDash doesn't route (`routable` off) is still imported,
/// but its entries were never served at any URL, so they get no redirect; `hidden` only hides a
/// collection from EmDash's admin navigation and doesn't affect the import. A collection slug
/// the dump repeats is read once and reported.
///
/// **Fields.** The title comes from the collection's `titleField` (or a `title` field), the
/// excerpt from `summary`/`excerpt`/`description`, the hero image from the first `image` field,
/// and the body from the first `portableText` field (`content`/`body` preferred). Every other
/// authored field would otherwise be lost — Anglesite's frontmatter schemas are `.strict()` —
/// so it's written into the body instead: a further `portableText`/`text` field under a heading
/// carrying its label, scalars as a trailing `**Label:** value` list, and structured fields
/// (`blocks`, `repeater`, `json`) as fenced JSON. Blocks the converter doesn't know are kept the
/// same way, and an entry that needed either fence gets an ``ImportProblem`` naming what was
/// kept as code, which is what surfaces in the import summary's attention line.
///
/// Only entries with `status == "published"` that aren't in the trash are imported, matching
/// what EmDash itself serves publicly — the same rule ``WXRRung`` applies to `wp:status`.
public enum EmDashRung {
    /// The route EmDash serves uploaded media from, relative to the site origin — the same
    /// constant the template's EmDash overlay uses (`EMDASH_MEDIA_ROUTE`).
    public static let mediaRoute = "/_emdash/api/media/file/"

    /// Extracts import items from an export.
    ///
    /// - Parameters:
    ///   - export: The parsed EmDash content.
    ///   - siteURL: The EmDash site's public URL (`https://blog.example`). Entry source URLs,
    ///     site-relative image URLs, and media storage keys are resolved against its origin.
    ///   - htmlConversions: Markdown for the `html` of any `htmlBlock`, keyed by the exact HTML
    ///     string; see ``PortableTextMarkdownConverter``. Prepare it with
    ///     ``htmlBlocks(in:)`` and an ``ImportHTMLConverter``, or use the async
    ///     ``items(from:siteURL:convert:)`` overload, which does both.
    /// - Returns: One ``ImportItem`` per published, untrashed entry with a non-empty body, and
    ///   the problems described above.
    public static func items(from export: EmDashExport, siteURL: String, htmlConversions: [String: String] = [:])
        -> (items: [ImportItem], problems: [ImportProblem]) {
        let site = SiteContext(siteURL: siteURL, export: export)
        var items: [ImportItem] = []
        var problems: [ImportProblem] = []
        var seenCollections: Set<String> = []

        func reportDuplicate(_ slug: String) {
            problems.append(ImportProblem(
                sourceURL: site.resolve("/\(slug)/"),
                message: "The export lists the “\(slug)” collection more than once; only the first copy was brought over"))
        }
        export.duplicateCollectionSlugs.forEach(reportDuplicate)
        let entriesByCollection = Dictionary(grouping: export.entries, by: \.collection)

        for collection in export.collections {
            guard seenCollections.insert(collection.slug).inserted else {
                reportDuplicate(collection.slug)
                continue
            }
            let shape = CollectionShape(collection: collection)
            if shape.isGuess {
                let noun = shape.hintsNote ? "notes" : "blog posts"
                problems.append(ImportProblem(
                    sourceURL: site.collectionURL(collection),
                    message: "“\(collection.label)” has no Anglesite equivalent, so its entries were brought over as \(noun)"))
            }

            for entry in entriesByCollection[collection.slug] ?? [] {
                guard entry.status == "published", !entry.trashed else { continue }
                let sourceURL = site.entryURL(entry, in: collection, shape: shape)
                let built = buildItem(entry: entry, collection: collection, shape: shape, site: site,
                                      sourceURL: sourceURL, htmlConversions: htmlConversions)
                guard let item = built.item else {
                    problems.append(ImportProblem(sourceURL: sourceURL, message: "This entry has no content to bring over"))
                    continue
                }
                if !built.keptAsCode.isEmpty {
                    problems.append(ImportProblem(
                        sourceURL: sourceURL,
                        message: "Kept as code for review: " + built.keptAsCode.joined(separator: "; ")))
                }
                items.append(item)
            }
        }
        return (items, problems)
    }

    /// Extracts import items from an export, converting embedded HTML blocks through `convert`
    /// first (one call per distinct HTML string across the whole export).
    ///
    /// - Parameters:
    ///   - export: The parsed EmDash content.
    ///   - siteURL: The EmDash site's public URL.
    ///   - convert: Converts an `htmlBlock`'s HTML to Markdown. An empty result leaves that
    ///     block's raw HTML in place, which Markdown renders as-is.
    /// - Returns: See ``items(from:siteURL:htmlConversions:)``.
    public static func items(from export: EmDashExport, siteURL: String, convert: any ImportHTMLConverter) async
        -> (items: [ImportItem], problems: [ImportProblem]) {
        var conversions: [String: String] = [:]
        for html in htmlBlocks(in: export) {
            let converted = await convert.convert(html: html)
            if !converted.markdown.isEmpty { conversions[html] = converted.markdown }
        }
        return items(from: export, siteURL: siteURL, htmlConversions: conversions)
    }

    /// Extracts import items from a crawled snapshot whose probes captured the site's EmDash
    /// snapshot JSON (``SiteProbes/emdashSnapshotJSON``).
    ///
    /// - Parameter snapshot: The crawled site snapshot.
    /// - Returns: Nothing when the probe is absent; otherwise the items and problems of
    ///   ``items(from:siteURL:htmlConversions:)`` (with `htmlBlock`s passed through as raw
    ///   HTML), or one problem if the captured JSON isn't a readable EmDash snapshot.
    public static func items(from snapshot: ImportSnapshot) -> (items: [ImportItem], problems: [ImportProblem]) {
        guard let json = snapshot.probes.emdashSnapshotJSON else { return ([], []) }
        do {
            let export = try EmDashSnapshotDocument.parse(Data(json.utf8))
            return items(from: export, siteURL: snapshot.siteURL)
        } catch {
            return ([], [ImportProblem(sourceURL: snapshot.siteURL, message: "Unreadable EmDash content export")])
        }
    }

    /// The HTML of every `htmlBlock` across every importable entry's Portable Text fields, in
    /// order, deduplicated — the input for preparing `htmlConversions`.
    /// - Parameter export: The parsed EmDash content.
    /// - Returns: Each distinct `htmlBlock` body.
    public static func htmlBlocks(in export: EmDashExport) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        let portableTextFields = Dictionary(export.collections.map {
            ($0.slug, $0.fields.filter { $0.type == "portableText" }.map(\.slug))
        }, uniquingKeysWith: { first, _ in first })
        for entry in export.entries where entry.status == "published" && !entry.trashed {
            for slug in portableTextFields[entry.collection] ?? [] {
                guard let value = entry.data[slug], let blocks = PortableTextMarkdownConverter.blockArray(value) else { continue }
                for html in PortableTextMarkdownConverter.htmlBlocks(in: blocks) where seen.insert(html).inserted {
                    result.append(html)
                }
            }
        }
        return result
    }

    /// A stand-in homepage record carrying EmDash's site title, tagline, and locale, so
    /// ``ImportSiteConfig/seeds(fromHomepage:)`` can seed `.site-config` for a one-shot import
    /// that has no crawled homepage (the `resolved:` path of ``ImportTransform``).
    /// - Parameters:
    ///   - export: The parsed EmDash content.
    ///   - siteURL: The EmDash site's public URL.
    /// - Returns: The record, or `nil` when the export carries no site title or tagline.
    public static func homepage(from export: EmDashExport, siteURL: String) -> CapturedPage? {
        guard export.siteTitle != nil || export.siteTagline != nil else { return nil }
        return CapturedPage(url: siteURL, extraction: ExtractionRecord(
            title: export.siteTitle, lang: export.siteLocale, markdown: "", excerpt: export.siteTagline))
    }

    // MARK: Building one item

    private struct BuiltItem {
        var item: ImportItem?
        /// Owner-facing descriptions of what was kept as fenced JSON, for the entry's problem.
        var keptAsCode: [String]
    }

    private static func buildItem(
        entry: EmDashExport.Entry, collection: EmDashExport.Collection, shape: CollectionShape,
        site: SiteContext, sourceURL: String, htmlConversions: [String: String]
    ) -> BuiltItem {
        var keptAsCode: [String] = []
        var consumed: Set<String> = []
        var images: [String] = []
        func noteImage(_ url: String) { if !images.contains(url) { images.append(url) } }

        let title = shape.titleField.flatMap { field -> String? in
            consumed.insert(field)
            return entry.data[field]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.flatMap { $0.isEmpty ? nil : $0 }

        let excerpt = shape.excerptField.flatMap { field -> String? in
            consumed.insert(field)
            return entry.data[field]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.flatMap { $0.isEmpty ? nil : $0 }

        var heroImage: String?
        if let field = shape.imageField {
            consumed.insert(field)
            // Escaped the way the converter spells body images, so the inventory and the
            // Markdown agree on one string for `AssetLocalizer` to rewrite.
            heroImage = site.imageURL(fromFieldValue: entry.data[field]).map(PortableTextMarkdownConverter.escapeURL)
            if let heroImage { noteImage(heroImage) }
        }

        var sections: [String] = []
        if let field = shape.bodyField {
            consumed.insert(field)
            if let value = entry.data[field], let blocks = PortableTextMarkdownConverter.blockArray(value) {
                let converted = PortableTextMarkdownConverter.convert(
                    blocks: blocks, htmlConversions: htmlConversions, resolveImageURL: site.imageURL(forAsset:))
                if !converted.markdown.isEmpty { sections.append(converted.markdown) }
                converted.images.forEach(noteImage)
                if !converted.unsupportedBlockTypes.isEmpty {
                    keptAsCode.append("blocks of kind " + converted.unsupportedBlockTypes.joined(separator: ", "))
                }
            }
        }

        // Every remaining authored field, in schema order, so nothing the schema builder added
        // is silently dropped.
        var scalars: [String] = []
        for field in collection.fields where !consumed.contains(field.slug) {
            guard let value = entry.data[field.slug], value != .null else { continue }
            switch field.type {
            case "portableText":
                guard let blocks = PortableTextMarkdownConverter.blockArray(value) else { continue }
                let converted = PortableTextMarkdownConverter.convert(
                    blocks: blocks, htmlConversions: htmlConversions, resolveImageURL: site.imageURL(forAsset:))
                guard !converted.markdown.isEmpty else { continue }
                sections.append("## \(PortableTextMarkdownConverter.escapeInline(field.label))\n\n" + converted.markdown)
                converted.images.forEach(noteImage)
                if !converted.unsupportedBlockTypes.isEmpty {
                    keptAsCode.append("blocks of kind " + converted.unsupportedBlockTypes.joined(separator: ", "))
                }
            case "text":
                guard let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                sections.append("## \(PortableTextMarkdownConverter.escapeInline(field.label))\n\n"
                                + PortableTextMarkdownConverter.escapeInline(text))
            case "image":
                guard let url = site.imageURL(fromFieldValue: value).map(PortableTextMarkdownConverter.escapeURL) else { continue }
                noteImage(url)
                let alt = value.objectValue?["alt"]?.stringValue ?? field.label
                sections.append("![\(PortableTextMarkdownConverter.escapeInline(alt))](\(url))")
            case "file":
                guard let url = site.imageURL(fromFieldValue: value) else { continue }
                scalars.append("- **\(PortableTextMarkdownConverter.escapeInline(field.label)):** [\(PortableTextMarkdownConverter.escapeInline(url))](\(PortableTextMarkdownConverter.escapeURL(url)))")
            case "reference":
                // A relation to another entry only means something inside EmDash.
                continue
            case "blocks", "repeater", "json":
                sections.append(fencedJSON(value, info: "json emdash-field=\(field.slug)"))
                keptAsCode.append("field “\(field.label)”")
            default:
                guard let rendered = scalarText(value, fieldType: field.type) else { continue }
                scalars.append("- **\(PortableTextMarkdownConverter.escapeInline(field.label)):** "
                               + PortableTextMarkdownConverter.escapeInline(rendered))
            }
        }
        if !scalars.isEmpty { sections.append(scalars.joined(separator: "\n")) }
        // Anglesite's `blog`/`notes`/page frontmatter has no hero-image field, so for every type
        // but photos (whose `image:` the emitter writes from the hint) the hero leads the body —
        // otherwise it would be localized into `public/images/` and referenced by nothing.
        if shape.kind != .photo, let heroImage {
            let alt = shape.imageField.flatMap { entry.data[$0]?.objectValue?["alt"]?.stringValue } ?? ""
            sections.insert("![\(PortableTextMarkdownConverter.escapeInline(alt))](\(heroImage))", at: 0)
        }

        let markdown = sections.joined(separator: "\n\n")
        guard !markdown.isEmpty || heroImage != nil else { return BuiltItem(item: nil, keptAsCode: keptAsCode) }

        let hint: ImportItem.Hint
        switch shape.kind {
        case .article: hint = .article
        case .note: hint = .note
        case .page: hint = .page
        case .photo: hint = heroImage.map { .photo(image: $0) } ?? images.first.map { .photo(image: $0) } ?? .note
        case .bookmark: hint = shape.targetURL(in: entry).map { .bookmark(of: $0) } ?? .article
        case .like: hint = shape.targetURL(in: entry).map { .like(of: $0) } ?? .note
        case .reply: hint = shape.targetURL(in: entry).map { .reply(to: $0) } ?? .note
        }

        let published = parseDate(entry.publishedAt)
            ?? collection.dateField.flatMap { entry.data[$0]?.stringValue }.flatMap(parseDate)
            ?? parseDate(entry.createdAt)

        let item = ImportItem(
            sourceURL: ImportSnapshot.normalizeURL(sourceURL), title: title, published: published,
            lang: entry.locale ?? site.export.siteLocale, markdown: markdown, excerpt: excerpt,
            images: images, tags: site.tags(for: entry), rung: .emdash, hint: hint)
        return BuiltItem(item: item, keptAsCode: keptAsCode)
    }

    /// A scalar field's display text: strings as-is, numbers and booleans spelled out, a
    /// `multiSelect` array joined with commas. `nil` for anything with no sensible text form.
    /// A `boolean` field arrives as the `0`/`1` its INTEGER column stores, so the field type
    /// decides whether a number reads as a number or as yes/no.
    private static func scalarText(_ value: JSONValue, fieldType: String = "") -> String? {
        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .int(let number) where fieldType == "boolean": return number != 0 ? "yes" : "no"
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let flag): return flag ? "yes" : "no"
        case .array(let values):
            let parts = values.compactMap { scalarText($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .object, .null: return nil
        }
    }

    private static func fencedJSON(_ value: JSONValue, info: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "```\(info)\n\(json)\n```"
    }

    /// Parses the timestamp forms EmDash writes: ISO 8601 with or without fractional seconds,
    /// SQLite's `YYYY-MM-DD HH:MM:SS` (UTC), and a bare `YYYY-MM-DD`.
    static func parseDate(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let date = iso8601Formatter.date(from: text) ?? iso8601FractionalFormatter.date(from: text) {
            return date
        }
        for formatter in plainFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// The non-ISO forms, built once: SQLite's `CURRENT_TIMESTAMP`, a `T`-separated local
    /// datetime without zone, and a bare date. Read-only after setup, like the ISO ones below.
    private nonisolated(unsafe) static let plainFormatters: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd",
    ].map { format in
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    private nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private nonisolated(unsafe) static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: Collection shape

    /// Which Anglesite content type a collection maps to, and which of its fields play which
    /// role — decided once per collection, not per entry.
    struct CollectionShape {
        enum Kind { case article, note, page, photo, bookmark, like, reply }

        let kind: Kind
        /// Whether `kind` was a fallback for a collection slug this rung doesn't recognize.
        let isGuess: Bool
        let titleField: String?
        let excerptField: String?
        let imageField: String?
        let bodyField: String?
        /// The field holding the bookmarked/liked/replied-to URL, for the response types.
        let targetField: String?

        var hintsNote: Bool { kind == .note }

        /// The Anglesite collection ``ContentClassifier`` sends this kind to (`nil` for a page,
        /// which is served at its own route) — the path a non-routable entry is given as its
        /// source URL so no redirect is written for it.
        var servedCollection: String? {
            switch kind {
            case .article: return "blog"
            case .note: return "notes"
            case .photo: return "photos"
            case .bookmark: return "bookmarks"
            case .like: return "likes"
            case .reply: return "replies"
            case .page: return nil
            }
        }

        init(collection: EmDashExport.Collection) {
            let fields = collection.fields
            func first(ofType type: String) -> String? { fields.first { $0.type == type }?.slug }
            func first(named names: [String], types: Set<String>) -> String? {
                for name in names {
                    if let field = fields.first(where: { $0.slug.lowercased() == name.lowercased() && types.contains($0.type) }) {
                        return field.slug
                    }
                }
                return nil
            }

            titleField = collection.titleField.flatMap { slug in fields.first { $0.slug == slug }?.slug }
                ?? first(named: ["title", "name", "headline"], types: ["string", "text"])
            excerptField = first(named: ["summary", "excerpt", "description", "subtitle", "teaser", "caption"], types: ["text", "string"])
            imageField = first(named: ["image", "cover", "coverImage", "cover_image", "featuredImage", "featured_image", "photo", "hero"],
                               types: ["image"]) ?? first(ofType: "image")
            bodyField = first(named: ["content", "body", "text"], types: ["portableText"]) ?? first(ofType: "portableText")
            targetField = first(named: ["bookmarkOf", "bookmark_of", "likeOf", "like_of", "inReplyTo", "in_reply_to", "url", "link", "href"],
                                types: ["url", "string"]) ?? first(ofType: "url")

            switch collection.slug.lowercased() {
            case "articles", "article", "posts", "post", "blog", "essays":
                kind = .article; isGuess = false
            case "notes", "note", "statuses", "status", "microblog":
                kind = .note; isGuess = false
            case "pages", "page":
                kind = .page; isGuess = false
            case "photos", "photo", "pictures":
                kind = .photo; isGuess = false
            case "bookmarks", "bookmark", "links", "link":
                kind = .bookmark; isGuess = false
            case "likes", "like", "favorites", "favourites":
                kind = .like; isGuess = false
            case "replies", "reply", "responses":
                kind = .reply; isGuess = false
            default:
                kind = titleField == nil ? .note : .article
                isGuess = true
            }
        }

        func targetURL(in entry: EmDashExport.Entry) -> String? {
            guard let targetField, let value = entry.data[targetField]?.stringValue?.trimmingCharacters(in: .whitespaces),
                  !value.isEmpty else { return nil }
            return value
        }
    }

    // MARK: Site context

    /// URL resolution against the EmDash site, plus the term and media lookups every entry needs.
    struct SiteContext {
        let export: EmDashExport
        /// `scheme://host[:port]`, no trailing slash.
        let origin: String
        private let termsByID: [String: EmDashExport.Term]
        private let termsByGroup: [String: EmDashExport.Term]
        private let mediaByID: [String: EmDashExport.Media]

        init(siteURL: String, export: EmDashExport) {
            self.export = export
            var origin = siteURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if var components = URLComponents(string: origin), components.host != nil {
                components.path = ""
                components.query = nil
                components.fragment = nil
                origin = components.string ?? origin
            }
            while origin.hasSuffix("/") { origin.removeLast() }
            self.origin = origin
            termsByID = Dictionary(export.terms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            termsByGroup = Dictionary(export.terms.compactMap { term in term.translationGroup.map { ($0, term) } },
                                      uniquingKeysWith: { first, _ in first })
            mediaByID = Dictionary(export.media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        /// The entry's source URL. A routable collection's comes from its `urlPattern`, which
        /// is where EmDash served the entry and so where old links point. A non-routable
        /// collection's entries were never served anywhere, so there's nothing to redirect
        /// from: they get the path Anglesite will serve them at, which ``RedirectsEmitter``
        /// then sees as unchanged.
        func entryURL(_ entry: EmDashExport.Entry, in collection: EmDashExport.Collection,
                      shape: CollectionShape) -> String {
            // Each substituted value is one path segment: a slug with a `/`, `?` or `#` in it
            // (EmDash validates slugs, but a dump is just JSON) must not add segments, a query or
            // a fragment to the source URL — and so to the redirect written from it.
            let slug = Self.pathSegment(entry.slug ?? entry.id)
            var path: String
            if collection.routable {
                path = (collection.urlPattern ?? "/\(collection.slug)/{slug}")
                    .replacingOccurrences(of: "{slug}", with: slug)
                    .replacingOccurrences(of: "{id}", with: Self.pathSegment(entry.id))
                    .replacingOccurrences(of: "{collection}", with: Self.pathSegment(collection.slug))
                    .replacingOccurrences(of: "{locale}", with: Self.pathSegment(entry.locale ?? export.siteLocale ?? ""))
            } else {
                path = shape.servedCollection.map { "/\($0)/\(slug)" } ?? "/\(slug)"
            }
            return resolve(collapsingSlashes(path))
        }

        /// The characters allowed unencoded in one path segment: `urlPathAllowed` minus the
        /// segment separator (`?` and `#` are already outside it).
        private static let segmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

        /// `value` percent-encoded as a single path segment.
        static func pathSegment(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? value
        }

        /// `//about` (a `{locale}` that was empty) would read as a protocol-relative URL, so
        /// repeated slashes collapse before resolution.
        private func collapsingSlashes(_ path: String) -> String {
            path.replacingOccurrences(of: "/{2,}", with: "/", options: .regularExpression)
        }

        /// The listing URL for a collection: its pattern with the entry segment removed.
        func collectionURL(_ collection: EmDashExport.Collection) -> String {
            guard collection.routable, let pattern = collection.urlPattern, let range = pattern.range(of: "{") else {
                return resolve("/\(collection.slug)/")
            }
            return resolve(collapsingSlashes(String(pattern[..<range.lowerBound])))
        }

        /// `path` as an absolute URL: already-absolute URLs pass through, site-relative paths are
        /// joined to the origin.
        func resolve(_ path: String) -> String {
            if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
            if path.hasPrefix("//") { return (origin.hasPrefix("http://") ? "http:" : "https:") + path }
            return origin + (path.hasPrefix("/") ? path : "/" + path)
        }

        func mediaURL(storageKey: String) -> String {
            let encoded = storageKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? storageKey
            return origin + EmDashRung.mediaRoute + encoded
        }

        /// A URL for a Portable Text image: its `asset.url` resolved against the site origin when
        /// present, else its `asset._ref` through `imageURL(forMediaRef:)`.
        func imageURL(forAsset asset: PortableTextMarkdownConverter.ImageAsset) -> String? {
            if let url = asset.url { return resolve(url) }
            if let ref = asset.ref { return imageURL(forMediaRef: ref) }
            return nil
        }

        /// A URL for a Portable Text image's `asset._ref`: a known media id resolves through its
        /// storage key; a URL-shaped ref is used as-is; anything else is treated as a storage key.
        func imageURL(forMediaRef ref: String) -> String? {
            if let media = mediaByID[ref] { return mediaURL(storageKey: media.storageKey) }
            if ref.hasPrefix("http://") || ref.hasPrefix("https://") || ref.hasPrefix("/") { return resolve(ref) }
            return mediaURL(storageKey: ref)
        }

        /// A URL for an `image`/`file` field value: EmDash's `{id, src, alt, meta}` object (a
        /// `src` first, else `meta.storageKey`, else the media record for `id`), or a bare string
        /// (a URL or a media id).
        func imageURL(fromFieldValue value: JSONValue?) -> String? {
            switch value {
            case .string(let text)?:
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : imageURL(forMediaRef: trimmed)
            case .object(let object)?:
                if let src = object["src"]?.stringValue, !src.isEmpty { return resolve(src) }
                if let url = object["url"]?.stringValue, !url.isEmpty { return resolve(url) }
                if let key = object["meta"]?.objectValue?["storageKey"]?.stringValue, !key.isEmpty {
                    return mediaURL(storageKey: key)
                }
                if let id = object["id"]?.stringValue, !id.isEmpty { return imageURL(forMediaRef: id) }
                return nil
            default:
                return nil
            }
        }

        /// The labels of every term assigned to `entry`, in assignment order, deduplicated.
        func tags(for entry: EmDashExport.Entry) -> [String] {
            var keys: Set<String> = [entry.id]
            if let group = entry.translationGroup { keys.insert(group) }
            var labels: [String] = []
            for assignment in export.termAssignments
            where assignment.collection == entry.collection && keys.contains(assignment.entryID) {
                guard let term = termsByID[assignment.termID] ?? termsByGroup[assignment.termID] else { continue }
                if !labels.contains(term.label) { labels.append(term.label) }
            }
            return labels
        }
    }
}

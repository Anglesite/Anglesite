import Foundation

/// A normalized read of an EmDash site's content (#2051): the collections and their schema, the
/// entries, the taxonomy terms assigned to them, and the media records their images reference —
/// the shape ``EmDashRung`` maps to ``ImportItem``s.
///
/// Both of EmDash's export surfaces produce it: the JSON its `/_emdash/api/snapshot` endpoint
/// serves and the `emdash-backup` file its Backups page downloads carry the same table dump
/// (``EmDashSnapshotDocument``). A raw SQLite/D1 database file is not read — the owner can turn
/// one into the backup JSON from EmDash's own admin, and parsing SQLite would mean a new
/// dependency.
public struct EmDashExport: Sendable, Equatable {
    /// One schema-builder field of a collection.
    public struct Field: Sendable, Equatable {
        /// The field's key in an entry's data (e.g. `content`).
        public var slug: String
        /// The field's human label (e.g. `Content`).
        public var label: String
        /// EmDash's field type: `string`, `text`, `portableText`, `image`, `datetime`, `url`, …
        public var type: String
        /// Whether EmDash requires a value.
        public var required: Bool

        /// Creates a field record.
        /// - Parameters:
        ///   - slug: The field's key in an entry's data.
        ///   - label: The field's human label.
        ///   - type: EmDash's field type name.
        ///   - required: Whether EmDash requires a value.
        public init(slug: String, label: String, type: String, required: Bool = false) {
            self.slug = slug
            self.label = label
            self.type = type
            self.required = required
        }
    }

    /// A collection and its declared fields, in schema order.
    public struct Collection: Sendable, Equatable {
        /// The collection's slug (`articles`); its entries live in the `ec_<slug>` table.
        public var slug: String
        /// The collection's human label (`Articles`).
        public var label: String
        /// EmDash's public URL pattern for an entry (`/articles/{slug}`), when the collection is
        /// routable.
        public var urlPattern: String?
        /// The field slug EmDash shows as the entry's title, if the collection names one.
        public var titleField: String?
        /// The field slug EmDash sorts the collection by, if it names one.
        public var dateField: String?
        /// Whether EmDash serves the collection's entries at `urlPattern` (`routable`). A
        /// non-routable collection's entries have no public URL to redirect from.
        public var routable: Bool
        /// The schema-builder fields, in `sort_order`.
        public var fields: [Field]

        /// Creates a collection record.
        /// - Parameters:
        ///   - slug: The collection's slug.
        ///   - label: The collection's human label.
        ///   - urlPattern: EmDash's public URL pattern for an entry.
        ///   - titleField: The field slug EmDash shows as the entry's title.
        ///   - dateField: The field slug EmDash sorts the collection by.
        ///   - routable: Whether EmDash serves the entries at `urlPattern`.
        ///   - fields: The schema-builder fields, in order.
        public init(slug: String, label: String, urlPattern: String? = nil, titleField: String? = nil,
                    dateField: String? = nil, routable: Bool = true, fields: [Field]) {
            self.slug = slug
            self.label = label
            self.urlPattern = urlPattern
            self.titleField = titleField
            self.dateField = dateField
            self.routable = routable
            self.fields = fields
        }
    }

    /// One content entry.
    public struct Entry: Sendable, Equatable {
        /// The slug of the collection the entry belongs to.
        public var collection: String
        /// EmDash's entry id.
        public var id: String
        /// The entry's URL slug, if it has one (an entry without a slug has no public URL).
        public var slug: String?
        /// `published`, `draft`, `scheduled`, …
        public var status: String
        /// Whether EmDash has moved the entry to the trash (`deleted_at` set).
        public var trashed: Bool
        /// The entry's locale code (`en`), if recorded.
        public var locale: String?
        /// The id shared by every translation of one entry — what term assignments point at.
        public var translationGroup: String?
        /// Publication timestamp as EmDash stored it (ISO 8601 or SQLite `YYYY-MM-DD HH:MM:SS`).
        public var publishedAt: String?
        /// Creation timestamp, in the same forms.
        public var createdAt: String?
        /// The authored field values keyed by field slug, with JSON-typed columns decoded.
        public var data: [String: JSONValue]

        /// Creates an entry record.
        /// - Parameters:
        ///   - collection: The slug of the entry's collection.
        ///   - id: EmDash's entry id.
        ///   - slug: The entry's URL slug.
        ///   - status: EmDash's status string.
        ///   - trashed: Whether the entry is in the trash.
        ///   - locale: The entry's locale code.
        ///   - translationGroup: The id shared by the entry's translations.
        ///   - publishedAt: Publication timestamp as stored.
        ///   - createdAt: Creation timestamp as stored.
        ///   - data: The authored field values keyed by field slug.
        public init(collection: String, id: String, slug: String?, status: String, trashed: Bool = false,
                    locale: String? = nil, translationGroup: String? = nil, publishedAt: String? = nil,
                    createdAt: String? = nil, data: [String: JSONValue]) {
            self.collection = collection
            self.id = id
            self.slug = slug
            self.status = status
            self.trashed = trashed
            self.locale = locale
            self.translationGroup = translationGroup
            self.publishedAt = publishedAt
            self.createdAt = createdAt
            self.data = data
        }
    }

    /// A taxonomy term (a tag, a category, …).
    public struct Term: Sendable, Equatable {
        /// The term's id.
        public var id: String
        /// The taxonomy the term belongs to (`tag`, `category`).
        public var taxonomy: String
        /// The term's URL slug.
        public var slug: String
        /// The term's display label.
        public var label: String
        /// The id shared by the term's translations, when EmDash's i18n schema is in use.
        public var translationGroup: String?

        /// Creates a term record.
        /// - Parameters:
        ///   - id: The term's id.
        ///   - taxonomy: The taxonomy the term belongs to.
        ///   - slug: The term's URL slug.
        ///   - label: The term's display label.
        ///   - translationGroup: The id shared by the term's translations.
        public init(id: String, taxonomy: String, slug: String, label: String, translationGroup: String? = nil) {
            self.id = id
            self.taxonomy = taxonomy
            self.slug = slug
            self.label = label
            self.translationGroup = translationGroup
        }
    }

    /// One term assigned to one entry (a `content_taxonomies` row).
    public struct TermAssignment: Sendable, Equatable {
        /// The entry's collection slug.
        public var collection: String
        /// The entry's id or translation group — EmDash writes either depending on schema
        /// version, so ``EmDashRung`` matches both.
        public var entryID: String
        /// The term's id or translation group, likewise.
        public var termID: String

        /// Creates an assignment record.
        /// - Parameters:
        ///   - collection: The entry's collection slug.
        ///   - entryID: The entry's id or translation group.
        ///   - termID: The term's id or translation group.
        public init(collection: String, entryID: String, termID: String) {
            self.collection = collection
            self.entryID = entryID
            self.termID = termID
        }
    }

    /// A media record (an uploaded file in EmDash's R2/S3 storage).
    public struct Media: Sendable, Equatable {
        /// The media id — what an image field or Portable Text image's `asset._ref` names.
        public var id: String
        /// The storage key EmDash serves the file under (`/_emdash/api/media/file/<key>`).
        public var storageKey: String
        /// The alt text recorded on upload, if any.
        public var alt: String?

        /// Creates a media record.
        /// - Parameters:
        ///   - id: The media id.
        ///   - storageKey: The storage key EmDash serves the file under.
        ///   - alt: The alt text recorded on upload.
        public init(id: String, storageKey: String, alt: String? = nil) {
            self.id = id
            self.storageKey = storageKey
            self.alt = alt
        }
    }

    /// The site title from EmDash's settings (`site:title`), if exported.
    public var siteTitle: String?
    /// The site tagline from EmDash's settings (`site:tagline`), if exported.
    public var siteTagline: String?
    /// The site's default locale from EmDash's settings (`emdash:locale`/`site:locale`), if
    /// exported.
    public var siteLocale: String?
    /// Every collection, in EmDash's admin order.
    public var collections: [Collection]
    /// Every entry, in table order per collection.
    public var entries: [Entry]
    /// Every taxonomy term.
    public var terms: [Term]
    /// Every term assignment.
    public var termAssignments: [TermAssignment]
    /// Every media record.
    public var media: [Media]
    /// Collection slugs that appeared more than once in the dump (a hand-merged backup); only
    /// the first row of each was read. ``EmDashRung`` reports each as an `ImportProblem`.
    public var duplicateCollectionSlugs: [String]

    /// Creates an export.
    /// - Parameters:
    ///   - siteTitle: The site title from EmDash's settings.
    ///   - siteTagline: The site tagline from EmDash's settings.
    ///   - siteLocale: The site's default locale.
    ///   - collections: Every collection, in admin order.
    ///   - entries: Every entry.
    ///   - terms: Every taxonomy term.
    ///   - termAssignments: Every term assignment.
    ///   - media: Every media record.
    ///   - duplicateCollectionSlugs: Collection slugs the dump repeated.
    public init(siteTitle: String? = nil, siteTagline: String? = nil, siteLocale: String? = nil,
                collections: [Collection], entries: [Entry], terms: [Term] = [],
                termAssignments: [TermAssignment] = [], media: [Media] = [],
                duplicateCollectionSlugs: [String] = []) {
        self.siteTitle = siteTitle
        self.siteTagline = siteTagline
        self.siteLocale = siteLocale
        self.collections = collections
        self.entries = entries
        self.terms = terms
        self.termAssignments = termAssignments
        self.media = media
        self.duplicateCollectionSlugs = duplicateCollectionSlugs
    }
}

/// Why an EmDash snapshot/backup document couldn't be read.
public enum EmDashSnapshotError: Error, Equatable {
    /// The bytes aren't a JSON object.
    case invalidJSON
    /// The JSON is an object but has no `tables` dump — it isn't an EmDash snapshot or backup
    /// (`format` wasn't `emdash-backup`, and neither the top level nor `data` carries `tables`).
    case notASnapshot
    /// EmDash's API answered with an error envelope (`success: false`), carrying this code.
    case apiError(code: String, message: String)
}

/// Reads EmDash's table-dump JSON into an ``EmDashExport`` (#2051).
///
/// The dump is what EmDash's `generateSnapshot` produces: `tables` maps each table name to its
/// rows, with JSON-typed columns (`portableText`, `json`, `multiSelect`, …) serialized as strings.
/// Three wrappers carry it — the backup file (`{"format": "emdash-backup", "tables": …}`), the
/// snapshot API's envelope (`{"success": true, "data": {"tables": …}}`), and the bare
/// `{"tables": …}` the API returns inside that envelope — and all three are accepted. Only the
/// tables the import needs are read: `_emdash_collections`, `_emdash_fields`, each `ec_<slug>`
/// content table, `taxonomies`, `content_taxonomies`, `media`, and the `site:` rows of `options`.
public enum EmDashSnapshotDocument {
    /// Parses snapshot or backup JSON.
    /// - Parameter data: The UTF-8 JSON document.
    /// - Returns: The normalized export.
    /// - Throws: ``EmDashSnapshotError``.
    public static func parse(_ data: Data) throws -> EmDashExport {
        guard let raw = try? JSONSerialization.jsonObject(with: data), let root = raw as? [String: Any] else {
            throw EmDashSnapshotError.invalidJSON
        }
        if let success = root["success"] as? Bool, !success {
            let error = root["error"] as? [String: Any]
            throw EmDashSnapshotError.apiError(code: error?["code"] as? String ?? "UNKNOWN",
                                               message: error?["message"] as? String ?? "")
        }
        let container = (root["data"] as? [String: Any]) ?? root
        guard let tables = container["tables"] as? [String: Any] else {
            throw EmDashSnapshotError.notASnapshot
        }
        return export(fromTables: tables)
    }

    private static func rows(_ tables: [String: Any], _ name: String) -> [[String: Any]] {
        (tables[name] as? [[String: Any]]) ?? []
    }

    private static func string(_ row: [String: Any], _ key: String) -> String? {
        if let value = row[key] as? String { return value.isEmpty ? nil : value }
        if let number = row[key] as? NSNumber { return number.stringValue }
        return nil
    }

    private static func flag(_ row: [String: Any], _ key: String) -> Bool {
        if let number = row[key] as? NSNumber { return number.intValue != 0 }
        if let bool = row[key] as? Bool { return bool }
        return false
    }

    private static func export(fromTables tables: [String: Any]) -> EmDashExport {
        var fieldsByCollectionID: [String: [(order: Int, field: EmDashExport.Field)]] = [:]
        for row in rows(tables, "_emdash_fields") {
            guard let collectionID = string(row, "collection_id"), let slug = string(row, "slug") else { continue }
            let field = EmDashExport.Field(slug: slug, label: string(row, "label") ?? slug,
                                           type: string(row, "type") ?? "string", required: flag(row, "required"))
            let order = (row["sort_order"] as? NSNumber)?.intValue ?? 0
            fieldsByCollectionID[collectionID, default: []].append((order, field))
        }

        var collections: [EmDashExport.Collection] = []
        var seenSlugs: Set<String> = []
        var duplicateSlugs: [String] = []
        for row in rows(tables, "_emdash_collections") {
            guard let slug = string(row, "slug") else { continue }
            // `slug` is unique in EmDash's own schema; a hand-merged backup can repeat one, and
            // two collections with one slug would read one `ec_<slug>` table twice.
            guard seenSlugs.insert(slug).inserted else {
                if !duplicateSlugs.contains(slug) { duplicateSlugs.append(slug) }
                continue
            }
            let fields = (fieldsByCollectionID[string(row, "id") ?? ""] ?? [])
                .enumerated()
                .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
                .map(\.element.field)
            collections.append(EmDashExport.Collection(
                slug: slug, label: string(row, "label") ?? slug, urlPattern: string(row, "url_pattern"),
                titleField: string(row, "title_field"), dateField: string(row, "date_field"),
                routable: row["routable"] == nil || flag(row, "routable"), fields: fields))
        }
        let sortOrder = rows(tables, "_emdash_collections").enumerated().reduce(into: [String: (Int, Int)]()) { acc, pair in
            if let slug = string(pair.element, "slug") {
                acc[slug] = ((pair.element["sort_order"] as? NSNumber)?.intValue ?? 0, pair.offset)
            }
        }
        collections.sort { (sortOrder[$0.slug] ?? (0, 0)) < (sortOrder[$1.slug] ?? (0, 0)) }

        var entries: [EmDashExport.Entry] = []
        for collection in collections {
            for row in rows(tables, "ec_\(collection.slug)") {
                guard let id = string(row, "id") else { continue }
                var data: [String: JSONValue] = [:]
                for (column, value) in row where !systemColumns.contains(column) {
                    if value is NSNull { continue }
                    data[column] = decodeColumn(value)
                }
                entries.append(EmDashExport.Entry(
                    collection: collection.slug, id: id, slug: string(row, "slug"),
                    status: string(row, "status") ?? "draft", trashed: string(row, "deleted_at") != nil,
                    locale: string(row, "locale"), translationGroup: string(row, "translation_group"),
                    publishedAt: string(row, "published_at"), createdAt: string(row, "created_at"), data: data))
            }
        }

        let terms = rows(tables, "taxonomies").compactMap { row -> EmDashExport.Term? in
            guard let id = string(row, "id"), let taxonomy = string(row, "name") else { return nil }
            let slug = string(row, "slug") ?? id
            return EmDashExport.Term(id: id, taxonomy: taxonomy, slug: slug, label: string(row, "label") ?? slug,
                                     translationGroup: string(row, "translation_group"))
        }
        let assignments = rows(tables, "content_taxonomies").compactMap { row -> EmDashExport.TermAssignment? in
            guard let collection = string(row, "collection"), let entryID = string(row, "entry_id"),
                  let termID = string(row, "taxonomy_id") else { return nil }
            return EmDashExport.TermAssignment(collection: collection, entryID: entryID, termID: termID)
        }
        let media = rows(tables, "media").compactMap { row -> EmDashExport.Media? in
            guard let id = string(row, "id"), let key = string(row, "storage_key") else { return nil }
            return EmDashExport.Media(id: id, storageKey: key, alt: string(row, "alt"))
        }

        var options: [String: String] = [:]
        for row in rows(tables, "options") {
            guard let name = string(row, "name"), let value = row["value"] else { continue }
            // Option values are JSON-encoded scalars (`"\"My Site\""`); a bare string is accepted too.
            if let text = value as? String {
                if let decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) as? String {
                    options[name] = decoded
                } else {
                    options[name] = text
                }
            }
        }

        return EmDashExport(
            siteTitle: options["site:title"] ?? options["emdash:site_title"],
            siteTagline: options["site:tagline"] ?? options["emdash:site_tagline"],
            siteLocale: options["site:locale"] ?? options["emdash:locale"],
            collections: collections, entries: entries, terms: terms, termAssignments: assignments, media: media,
            duplicateCollectionSlugs: duplicateSlugs)
    }

    /// The `ec_*` columns EmDash manages itself; every other column is an authored field.
    static let systemColumns: Set<String> = [
        "id", "slug", "status", "author_id", "primary_byline_id", "created_at", "updated_at",
        "published_at", "scheduled_at", "deleted_at", "version", "live_revision_id",
        "draft_revision_id", "locale", "translation_group",
    ]

    /// Decodes one authored column the way EmDash's `deserializeValue` does: a string that starts
    /// with `{` or `[` is a serialized JSON column (Portable Text, an image field, a repeater) and
    /// is parsed; anything else is kept as the scalar it is.
    private static func decodeColumn(_ value: Any) -> JSONValue {
        if let text = value as? String, text.hasPrefix("{") || text.hasPrefix("["),
           let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
           let json = JSONValue.from(parsed) {
            return json
        }
        return JSONValue.from(value) ?? .null
    }
}

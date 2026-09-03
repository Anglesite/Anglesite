// Sources/AnglesiteCore/ContentScaffold.swift
import Foundation

/// Pure, side-effect-free scaffolding for new pages and posts. Byte-faithful to the Node
/// sidecar's `create-content.mjs` so switching the create backend produces no git churn.
public enum ContentScaffold {
    /// A page-scaffold variant for New Page. A struct rather than an enum so the list can grow
    /// beyond ``builtIns`` without a source-breaking change; identity and rendering both key off
    /// the `id` string (an unknown id falls back to the standard body in `renderPage`).
    public struct PageTemplate: Sendable, Equatable, Hashable, Identifiable {
        /// Stable template id that ``ContentScaffold/renderPage(title:layoutImport:template:description:)``
        /// dispatches on.
        public let id: String
        /// User-facing name shown in the New Page template picker.
        public let displayName: String

        /// Memberwise initializer — public so future template sources beyond ``builtIns`` don't
        /// need this file changed.
        public init(id: String, displayName: String) {
            self.id = id
            self.displayName = displayName
        }

        /// Title plus a placeholder paragraph — the default when no template is chosen.
        public static let standard = PageTemplate(id: "standard", displayName: "Standard Page")
        /// Hero section plus a highlights list.
        public static let landing = PageTemplate(id: "landing", displayName: "Landing Page")
        /// Contact prompt with a placeholder `mailto:` address for the owner to replace.
        public static let contact = PageTemplate(id: "contact", displayName: "Contact Page")

        /// The templates the New Page UI offers, in menu order.
        public static let builtIns: [PageTemplate] = [.standard, .landing, .contact]
    }

    /// lowercase → NFKD → strip combining marks → drop `'` and `"` → non-alphanumerics to `-` → trim `-`.
    public static func slugify(_ value: String) -> String {
        let lowered = value.lowercased()
        let decomposed = lowered.decomposedStringWithCompatibilityMapping // NFKD
        let stripped = String(decomposed.unicodeScalars.filter { !(0x0300...0x036F ~= $0.value) })
        let noQuotes = stripped
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
        let hyphenated = noQuotes.replacingOccurrences(
            of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return hyphenated.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Slugify each `/`-separated segment, drop empties, rejoin with a leading slash.
    public static func normalizeRoute(_ route: String) -> String {
        let segments = route
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { slugify(String($0)) }
            .filter { !$0.isEmpty }
        return "/" + segments.joined(separator: "/")
    }

    /// Where a scaffolded page lands, relative to the site root: `/about` →
    /// `src/pages/about.astro`. Expects a route already through ``normalizeRoute(_:)``.
    ///
    /// The argument is a *file-path* route (no trailing slash), not the served route
    /// ``servedRoute(_:)`` produces — a trailing slash here would yield `src/pages/about/.astro`.
    ///
    /// `extension` defaults to `"astro"` for fresh scaffolds; a caller duplicating an existing
    /// page passes its source extension (e.g. `"md"`) so the copy keeps compiling as the same
    /// content type instead of Astro trying to parse Markdown frontmatter as component script (#1786).
    public static func pageRelativePath(normalizedRoute: String, extension ext: String = "astro") -> String {
        "src/pages" + normalizedRoute + "." + ext
    }

    /// The trailing-slash *served* form of a page route: `/about` → `/about/`, `/` → `/`.
    ///
    /// The template builds pages in Astro's directory format, so a page route's runtime request
    /// path always carries a trailing slash: it is what `Astro.url.pathname` reports at render
    /// time, what `src/lib/sitemap.ts` emits, and what `worker.ts`/`BaseLayout.astro` match a
    /// stored path against *exactly*. `scripts/pre-deploy-check.ts` enforces the same shape on
    /// every `experiments.active` entry's `page`, `variant.page`, and pageview-goal `path`
    /// (`experimentPathProblem(_, { requireTrailingSlash: true })`), for draft and running entries
    /// alike — so a slash-less route written into `anglesite.json` fails the gate and blocks every
    /// subsequent deploy of the site, not just the experiment (#1518).
    ///
    /// `ContentScanner.routeFromPagePath(_:)` and ``normalizeRoute(_:)`` both produce the
    /// slash-less file-path form, so anything crossing into a served-route position goes through
    /// here. Idempotent.
    public static func servedRoute(_ route: String) -> String {
        route.hasSuffix("/") ? route : route + "/"
    }

    /// The inverse of ``servedRoute(_:)`` composed with ``pageRelativePath(normalizedRoute:extension:)``:
    /// where the `.astro` file behind a served page route lives. `/` → `src/pages/index.astro`,
    /// `/pricing/` → `src/pages/pricing.astro`. Accepts either slash form.
    public static func pageRelativePath(servedRoute: String) -> String {
        let trimmed = servedRoute.hasSuffix("/") ? String(servedRoute.dropLast()) : servedRoute
        return trimmed.isEmpty || trimmed == "/"
            ? "src/pages/index.astro"
            : pageRelativePath(normalizedRoute: trimmed)
    }

    /// Where a scaffolded collection entry lands, relative to the site root:
    /// `src/content/<collection>/<slug>.md`.
    ///
    /// `extension` defaults to `"md"` for fresh scaffolds; a caller duplicating an existing entry
    /// passes its source extension (e.g. `"mdx"`/`"astro"`) so the copy keeps its original format (#1786).
    public static func postRelativePath(collection: String, slug: String, extension ext: String = "md") -> String {
        "src/content/\(collection)/\(slug).\(ext)"
    }

    /// Derive a slug from a target URL, for content types with no title field to slugify — `reply`
    /// and `like` are identified by what they point at, not by a name (#916).
    ///
    /// `yyyy-MM-dd` (UTC, same clock and formatter family `renderEntry` uses) + the host with a
    /// leading `www.` dropped + the last non-empty path component, all through `slugify`. Query and
    /// fragment are ignored. The date prefix keeps entries chronologically sortable and makes
    /// collisions practically impossible — two replies to the same URL on the same day — while
    /// keeping the permalink descriptive; it matches the IndieWeb convention for replies and likes.
    ///
    /// Returns `""` when `value` has no host, so callers fall back to their own default rather than
    /// producing a date-only slug that says nothing about the entry.
    public static func slugFromURL(_ value: String, now: Date) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let host = components.host, !host.isEmpty
        else { return "" }

        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let lastSegment = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let day = String(formatter.string(from: now).prefix(10))

        return slugify([day, bareHost, lastSegment].filter { !$0.isEmpty }.joined(separator: "-"))
    }

    /// Where a per-site singleton data record lands, relative to the site root:
    /// `src/data/<slot>.json` — a data module the template imports, not a routable page.
    public static func singletonRelativePath(slot: String) -> String {
        "src/data/\(slot).json"
    }

    /// `/about` → `../layouts/BaseLayout.astro`; `/a/b` → `../../layouts/BaseLayout.astro`.
    public static func layoutImport(normalizedRoute: String) -> String {
        let trimmed = normalizedRoute.hasPrefix("/") ? String(normalizedRoute.dropFirst()) : normalizedRoute
        let depth = trimmed.split(separator: "/", omittingEmptySubsequences: false).count
        return String(repeating: "../", count: depth) + "layouts/BaseLayout.astro"
    }

    /// Full `.astro` source for a new page: `BaseLayout` import plus the template's body. A `nil`
    /// `description` defaults to `"\(title)."` so every scaffolded page ships with a non-empty
    /// meta description. The body deliberately has no `<main>` wrapper — `BaseLayout` owns the
    /// page's single main landmark (#1012), so pages contribute content only.
    public static func renderPage(
        title: String,
        layoutImport: String,
        template: PageTemplate = .standard,
        description: String? = nil
    ) -> String {
        let description = description ?? "\(title)."
        let body: String
        switch template.id {
        // No `<main>` wrapper: BaseLayout owns the page's single main landmark (#1012), so a
        // scaffolded page contributes content only — a second `<main>` would nest invalidly.
        case PageTemplate.landing.id:
            body = """
              <section>
                <p>Welcome</p>
                <h1>\(escapeHTML(title))</h1>
                <p>Add a short promise for this page.</p>
              </section>
              <section>
                <h2>Highlights</h2>
                <ul>
                  <li>First thing visitors should know.</li>
                  <li>Second thing visitors should know.</li>
                  <li>Next step visitors can take.</li>
                </ul>
              </section>
            """
        case PageTemplate.contact.id:
            body = """
              <h1>\(escapeHTML(title))</h1>
              <p>Tell visitors how to reach you.</p>
              <address>
                <a href="mailto:hello@example.com">hello@example.com</a>
              </address>
            """
        default:
            body = """
              <h1>\(escapeHTML(title))</h1>
              <p>Add your content here.</p>
            """
        }
        return """
        ---
        import BaseLayout from "\(layoutImport)";
        ---

        <BaseLayout title="\(escapeAttr(title))" description="\(escapeAttr(description))">
        \(body)
        </BaseLayout>
        """ + "\n"
    }

    /// Markdown source for a new post: quoted, escaped frontmatter with the publish date set to
    /// `now` (ISO-8601 with fractional seconds, matching the sidecar's `toISOString()` output
    /// byte-for-byte) and `draft: true` — new entries start unpublished.
    ///
    /// `declaredFields` is the target collection's schema field list from
    /// ``FrontmatterSchemaReader`` (#1716). When known, only declared keys are emitted and the
    /// date goes under whichever key the schema uses (`pubDate` for the template's `blog`
    /// collection, else `publishDate`, else `date`), and the description falls back to `summary`
    /// — the collection schemas are `.strict()`, so an undeclared `tags:` or a `publishDate:`
    /// where `pubDate:` is required makes Astro reject the whole entry. `nil` (no readable
    /// schema) keeps the legacy `posts` shape unchanged — as does an empty list, which would
    /// otherwise render a frontmatter block with no `title` and no date at all. The reader never
    /// reports an empty list (a zero-field reading is omitted as unreadable), so that guard is for
    /// other callers of this public API.
    public static func renderPost(
        title: String, now: Date, description: String = "", declaredFields: [String]? = nil
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let publishDate = formatter.string(from: now)

        var lines: [String] = []
        if let declaredFields, !declaredFields.isEmpty {
            let declared = Set(declaredFields)
            if declared.contains("title") { lines.append("title: \"\(escapeYAML(title))\"") }
            if let key = ["description", "summary"].first(where: declared.contains) {
                lines.append("\(key): \"\(escapeYAML(description))\"")
            }
            if let key = ["pubDate", "publishDate", "date"].first(where: declared.contains) {
                lines.append("\(key): \(publishDate)")
            }
            if declared.contains("draft") { lines.append("draft: true") }
            if declared.contains("tags") { lines.append("tags: []") }
        } else {
            lines = [
                "title: \"\(escapeYAML(title))\"",
                "description: \"\(escapeYAML(description))\"",
                "publishDate: \(publishDate)",
                "draft: true",
                "tags: []",
            ]
        }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n\nWrite your post here.\n"
    }

    /// Render a new content entry's file contents from its descriptor: a YAML frontmatter block
    /// (one line per non-markdown field, in declaration order) followed by a placeholder body for
    /// the type's `markdown` field, if any. Pure; mirrors `renderPost`'s ISO8601 date format.
    /// `fieldValues` supplies caller-collected values by field name for the scalar-string kinds
    /// (`.string`, `.text`, `.url`, `.image`) and, since #531, the `.markdown` body and `.bool`
    /// fields (exact `"true"`/`"false"`); an absent key falls back to the title-like/empty default.
    /// Still pure — an empty `fieldValues` renders exactly what it rendered before (#916).
    public static func renderEntry(
        descriptor: ContentTypeDescriptor,
        title: String?,
        now: Date,
        fieldValues: [String: String] = [:]
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateTime = formatter.string(from: now)

        var lines: [String] = ["---"]
        var bodyPlaceholder: String?
        for field in descriptor.fields {
            switch field.kind {
            case .markdown:
                // A supplied value replaces the placeholder; supplied-but-empty means "no body"
                // (quick capture publishing without commentary must not publish placeholder text,
                // #531). Absent key keeps the placeholder — the #916 purity contract.
                if let supplied = fieldValues[field.name] {
                    bodyPlaceholder = supplied.isEmpty ? nil : supplied
                } else {
                    bodyPlaceholder = "Write your \(descriptor.displayName.lowercased()) here."
                }
            // Optional datetime/date fields scaffold commented-out: an emitted value is a valid
            // truthy Date under `z.coerce.date()`, so a live default (e.g. an unset event `end`)
            // would render a bogus `dt-end`. Commenting keeps the field as a format hint the user
            // can uncomment. Required ones stay live (the entry is invalid without them).
            case .datetime:
                lines.append("\(field.required ? "" : "# ")\(field.name): \(dateTime)")
            case .date:
                lines.append("\(field.required ? "" : "# ")\(field.name): \(String(dateTime.prefix(10)))")
            // New entries are drafts by default (#798); a caller-supplied exact "true"/"false"
            // overrides (quick capture's Publish writes draft: false, #531). Anything else —
            // including a typo'd value — keeps the safe default rather than guessing.
            case .bool:
                let supplied = fieldValues[field.name].flatMap { $0 == "true" || $0 == "false" ? $0 : nil }
                lines.append("\(field.name): \(supplied ?? (field.name == "draft" ? "true" : "false"))")
            case .number:
                lines.append("\(field.name): 0")
            case .stringArray, .imageArray, .objectArray:
                lines.append("\(field.name): []")
            case .enum(let cases):
                let value = fieldValues[field.name] ?? cases.first ?? ""
                lines.append("\(field.name): \"\(escapeYAML(value))\"")
            case .string, .language, .text, .image:
                lines.append("\(field.name): \"\(escapeYAML(scalarValue(field, title: title, fieldValues: fieldValues)))\"")
            // A `.url` line is commented out only when the field is optional *and* nothing was
            // supplied: an emitted `""` is not a valid URL under `z.string().url()`, unlike
            // `.string`/`.text`/`.image`'s bare `z.string()`, which accepts an empty string.
            // Mirrors the `.datetime`/`.date` comment-out rationale above (#913). A supplied value
            // always renders live — that is how the create path pre-fills the required
            // `bookmarkOf`/`inReplyTo`/`likeOf` so a new entry is schema-valid on first write
            // (#916). Required fields with nothing supplied still render an empty live line; the
            // create path refuses to write that, keeping this function a pure formatter.
            case .url:
                let value = scalarValue(field, title: title, fieldValues: fieldValues)
                let isLive = field.required || !value.isEmpty
                lines.append("\(isLive ? "" : "# ")\(field.name): \"\(escapeYAML(value))\"")
            }
        }
        lines.append("---")

        var output = lines.joined(separator: "\n") + "\n"
        if let bodyPlaceholder {
            output += "\n\(bodyPlaceholder)\n"
        }
        return output
    }

    /// The value for a scalar-string field: the caller's supplied value if there is one, otherwise
    /// the entry title for a title-like field, otherwise empty.
    ///
    /// The title fallback is deliberately skipped for `.url` fields: `titleLikeFieldNames` (`title`,
    /// `name`, `itemReviewed`) is a name-based heuristic that assumes those names carry a
    /// human-facing label, but a custom descriptor (via `ContentTypeRegistry.register(_:)`) could
    /// declare an *optional* `.url` field named e.g. `name`. Falling back to the title there would
    /// render a non-URL string into a `z.string().url()` slot as a *live* line — the field's
    /// `isLive` rule in `renderEntry` treats any non-empty value as supplied — which is exactly the
    /// kind of schema-invalid write this file exists to prevent. A caller-supplied `fieldValues`
    /// entry still wins for `.url` fields; only the title fallback is suppressed.
    private static func scalarValue(
        _ field: ContentTypeField,
        title: String?,
        fieldValues: [String: String]
    ) -> String {
        if let supplied = fieldValues[field.name] { return supplied }
        guard field.kind != .url else { return "" }
        return ContentTypeDescriptor.titleLikeFieldNames.contains(field.name) ? (title ?? "") : ""
    }

    /// Render a per-site singleton (e.g. the representative h-card) as a JSON data module:
    /// `"type"` first, then one key per non-`markdown` field in descriptor order, with empty/zero
    /// defaults and the name-like field filled from `name`. Pure; hand-rendered for deterministic
    /// key order (unlike `JSONEncoder`). The template imports this file to render the identity.
    public static func renderSingleton(descriptor: ContentTypeDescriptor, name: String?) -> String {
        var entries: [String] = ["\"type\": \"\(escapeJSON(descriptor.id))\""]
        for field in descriptor.fields {
            let value: String
            switch field.kind {
            case .markdown:
                continue // a data record has no body
            case .bool:
                value = "false"
            case .number:
                value = "0"
            case .stringArray, .imageArray, .objectArray:
                value = "[]"
            case .string, .language, .text, .url, .image, .date, .datetime, .enum:
                let filled = ContentTypeDescriptor.titleLikeFieldNames.contains(field.name) ? (name ?? "") : ""
                value = "\"\(escapeJSON(filled))\""
            }
            entries.append("\"\(field.name)\": \(value)")
        }
        return "{\n" + entries.map { "  \($0)" }.joined(separator: ",\n") + "\n}\n"
    }

    /// A minimal blank `.astro` component scaffold (V-1 of New Component…, #516). No props, no
    /// markup beyond a placeholder — semantic authoring arrives with the Component Editor (#496).
    public static func renderComponent(name: String) -> String {
        """
        ---
        export interface Props {}
        ---

        <div>
          <!-- \(escapeHTML(name)) -->
        </div>
        """ + "\n"
    }

    // MARK: - Escaping (order matters: `&` first)

    static func escapeAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Escape a string for a double-quoted YAML scalar. Every scalar this renders sits on one
    /// frontmatter line, so an unescaped newline (or other control character) would split the
    /// block and produce unparseable frontmatter — mirrors `escapeJSON`'s reasoning, using YAML's
    /// own named escapes (`\0`, `\a`, `\v`, `\e`, `\xXX`) in place of JSON's.
    static func escapeYAML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{00}": out += "\\0"
            case "\u{07}": out += "\\a"
            case "\u{08}": out += "\\b"
            case "\u{0B}": out += "\\v"
            case "\u{0C}": out += "\\f"
            case "\u{1B}": out += "\\e"
            case let c where c.value < 0x20:
                out += String(format: "\\x%02x", c.value)
            case "\u{2028}": out += "\\L"
            case "\u{2029}": out += "\\P"
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Escape a string for use as a JSON string value. Covers `\` and `"`, the named control
    /// escapes, every remaining C0 control character as `\uXXXX`, and U+2028/U+2029. The rendered
    /// file is imported as a JS module, so an unescaped control char would be invalid JSON and
    /// hard-fail the whole site build. U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR are
    /// valid in standalone JSON but break JS parsers if the data is ever inlined into a `<script>`
    /// (e.g. V-1.8 JSON-LD), so they are escaped pre-emptively.
    static func escapeJSON(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

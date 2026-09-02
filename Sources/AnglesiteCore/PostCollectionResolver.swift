import Foundation

/// Decides which content collection a "New Post" with no explicit collection lands in (#1716).
///
/// The literal default used to be `posts`, which is only wired up on sites whose
/// `content.config.ts` happens to declare a `posts` collection. The shipped template (and the
/// Business/Classic family built on it) declares its blog as `blog` and has no `posts` collection
/// at all, so every New Post… landed in `src/content/posts/` — a directory no Astro `glob()`
/// loader covers, invisible to the Navigator and the preview alike.
///
/// Resolution reads the site's declared collections (``FrontmatterSchemaReader``) as ground truth:
///
/// 1. The first of ``candidates`` the config declares wins (`posts` over `blog` over `articles`,
///    so an IndieWeb-style site keeps `posts`).
/// 2. That collection's schema must also be *readable* — present in
///    ``FrontmatterSchemaReader/read(siteDirectory:)``, not merely declared. A collection whose
///    schema is imported (the shipped template's own `articles: articlesSchema`) or composed
///    entirely from spreads is declared but yields no field list to shape the frontmatter to, and
///    its `.strict()` schema rejects a guessed one (`articlesSchema` takes `summary`, not
///    `description`). That resolves to ``PostCollectionResolver/Resolution/unreadableSchema(name:)``
///    so the caller refuses; it does not fall through to a lower-ranked candidate, which would
///    silently file the post somewhere other than the site's own blog.
/// 3. A config that declares collections but none of them blog-like resolves to
///    ``PostCollectionResolver/Resolution/noBlogCollection`` — the caller refuses rather than
///    silently writing to an unwired directory.
/// 4. With no readable config, an existing `src/content/<candidate>/` directory decides, and an
///    empty site keeps the legacy `posts` default so a bare scaffold still works.
public enum PostCollectionResolver {
    /// Blog-like collection names, in preference order.
    public static let candidates: [String] = ["posts", "blog", "articles"]

    /// The default for a site with no `content.config.ts` and no collection directories — the
    /// pre-#1716 behavior, kept for bare scaffolds and the sidecar's `create-content.mjs` parity.
    public static let legacyDefault = "posts"

    /// The outcome of ``resolve(siteDirectory:)``.
    public enum Resolution: Equatable, Sendable {
        /// File the post in `name`, shaping its frontmatter to `declaredFields` — the collection's
        /// schema field list as ``FrontmatterSchemaReader`` read it, or `nil` for a site with no
        /// content config at all (the legacy `posts` shape).
        case collection(name: String, declaredFields: [String]?)
        /// `name` is the site's blog collection, but its schema can't be read (imported, or
        /// spread-only), so the frontmatter a new post needs is unknown. Refuse rather than guess.
        case unreadableSchema(name: String)
        /// The config declares collections, but none of ``candidates`` is among them.
        case noBlogCollection
    }

    /// Resolves against `siteDirectory` (`Source/`): the declared collections and readable schemas
    /// in its `content.config.ts` plus which candidate directories exist under `src/content/`.
    public static func resolve(siteDirectory: URL) -> Resolution {
        let declared = FrontmatterSchemaReader.declaredCollectionNames(siteDirectory: siteDirectory)
        let readable = FrontmatterSchemaReader.read(siteDirectory: siteDirectory)
        let contentDir = siteDirectory.appendingPathComponent("src/content", isDirectory: true)
        let existing = candidates.filter { name in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: contentDir.appendingPathComponent(name, isDirectory: true).path, isDirectory: &isDir)
                && isDir.boolValue
        }
        return resolve(declared: declared, readableSchemas: readable, existingDirectories: existing)
    }

    /// Pure resolution over already-gathered facts — see the type doc for the order. Split out
    /// from ``resolve(siteDirectory:)`` so the policy is unit-testable without a site on disk.
    /// `readableSchemas` is ``FrontmatterSchemaReader/read(siteDirectory:)``'s map; an entry that
    /// is missing *or empty* counts as unreadable, so a caller handing in a zero-field reading
    /// can't slip an empty frontmatter past the check.
    static func resolve(
        declared: [String], readableSchemas: [String: [String]], existingDirectories: [String]
    ) -> Resolution {
        if !declared.isEmpty {
            guard let name = candidates.first(where: declared.contains) else { return .noBlogCollection }
            guard let fields = readableSchemas[name], !fields.isEmpty else { return .unreadableSchema(name: name) }
            return .collection(name: name, declaredFields: fields)
        }
        let name = candidates.first { existingDirectories.contains($0) } ?? legacyDefault
        return .collection(name: name, declaredFields: nil)
    }
}

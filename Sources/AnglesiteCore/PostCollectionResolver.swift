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
/// 2. A config that declares collections but none of them blog-like resolves to `nil` — the
///    caller refuses rather than silently writing to an unwired directory.
/// 3. With no readable config, an existing `src/content/<candidate>/` directory decides, and an
///    empty site keeps the legacy `posts` default so a bare scaffold still works.
public enum PostCollectionResolver {
    /// Blog-like collection names, in preference order.
    public static let candidates: [String] = ["posts", "blog", "articles"]

    /// The default for a site with no `content.config.ts` and no collection directories — the
    /// pre-#1716 behavior, kept for bare scaffolds and the sidecar's `create-content.mjs` parity.
    public static let legacyDefault = "posts"

    /// Resolves against `siteDirectory` (`Source/`): the declared collections in its
    /// `content.config.ts` plus which candidate directories exist under `src/content/`. Returns
    /// `nil` only when the config declares collections and none is blog-like.
    public static func resolve(siteDirectory: URL) -> String? {
        let declared = FrontmatterSchemaReader.declaredCollectionNames(siteDirectory: siteDirectory)
        let contentDir = siteDirectory.appendingPathComponent("src/content", isDirectory: true)
        let existing = candidates.filter { name in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: contentDir.appendingPathComponent(name, isDirectory: true).path, isDirectory: &isDir)
                && isDir.boolValue
        }
        return resolve(declared: declared, existingDirectories: existing)
    }

    /// Pure resolution over already-gathered facts — see the type doc for the order. Split out
    /// from ``resolve(siteDirectory:)`` so the policy is unit-testable without a site on disk.
    static func resolve(declared: [String], existingDirectories: [String]) -> String? {
        if !declared.isEmpty {
            return candidates.first { declared.contains($0) }
        }
        return candidates.first { existingDirectories.contains($0) } ?? legacyDefault
    }
}

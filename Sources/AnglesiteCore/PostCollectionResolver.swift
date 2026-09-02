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
        resolve(
            declared: FrontmatterSchemaReader.declaredCollectionNames(siteDirectory: siteDirectory),
            existingDirectories: existingCandidateDirectories(siteDirectory: siteDirectory))
    }

    /// Every blog-like collection the site has — the set-valued sibling of
    /// ``resolve(siteDirectory:)`` for classifiers that need to recognize *all* of a site's post
    /// collections rather than pick one to write into (``SiteKnowledgeIndex``, #1725). Same
    /// facts, same fallbacks: the declared ``candidates`` when the config declares anything, else
    /// the candidate directories that exist plus ``legacyDefault``. Whatever
    /// ``resolve(siteDirectory:)`` returns is always a member; the set is empty exactly when it
    /// returns `nil`.
    public static func postCollections(siteDirectory: URL) -> Set<String> {
        postCollections(
            declared: FrontmatterSchemaReader.declaredCollectionNames(siteDirectory: siteDirectory),
            existingDirectories: existingCandidateDirectories(siteDirectory: siteDirectory))
    }

    /// Pure resolution over already-gathered facts — see the type doc for the order. Split out
    /// from ``resolve(siteDirectory:)`` so the policy is unit-testable without a site on disk.
    static func resolve(declared: [String], existingDirectories: [String]) -> String? {
        if !declared.isEmpty {
            return candidates.first { declared.contains($0) }
        }
        return candidates.first { existingDirectories.contains($0) } ?? legacyDefault
    }

    /// Pure counterpart of ``postCollections(siteDirectory:)``.
    static func postCollections(declared: [String], existingDirectories: [String]) -> Set<String> {
        if !declared.isEmpty {
            return Set(candidates.filter { declared.contains($0) })
        }
        return Set(candidates.filter { existingDirectories.contains($0) }).union([legacyDefault])
    }

    /// Which of ``candidates`` exist as directories under `src/content/` — the no-config fallback
    /// signal shared by both resolvers.
    private static func existingCandidateDirectories(siteDirectory: URL) -> [String] {
        let contentDir = siteDirectory.appendingPathComponent("src/content", isDirectory: true)
        return candidates.filter { name in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: contentDir.appendingPathComponent(name, isDirectory: true).path, isDirectory: &isDir)
                && isDir.boolValue
        }
    }
}

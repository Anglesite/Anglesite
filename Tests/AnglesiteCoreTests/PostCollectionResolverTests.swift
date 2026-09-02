import Testing
import Foundation
@testable import AnglesiteCore

@Suite("PostCollectionResolver")
struct PostCollectionResolverTests {
    private typealias Resolution = PostCollectionResolver.Resolution

    /// Readable inline schemas for every candidate, so the declared-name tests isolate the
    /// preference order from the readable-schema requirement.
    private let inlineSchemas: [String: [String]] = [
        "posts": ["title", "publishDate"],
        "blog": ["title", "pubDate"],
        "articles": ["title", "summary"],
    ]

    private func resolve(
        declared: [String], readableSchemas: [String: [String]]? = nil, existingDirectories: [String] = []
    ) -> Resolution {
        PostCollectionResolver.resolve(
            declared: declared, readableSchemas: readableSchemas ?? inlineSchemas, existingDirectories: existingDirectories)
    }

    @Test("a config declaring only `blog` resolves to blog (#1716)")
    func blogOnly() {
        #expect(resolve(declared: ["blog", "notes", "events"])
                == .collection(name: "blog", declaredFields: ["title", "pubDate"]))
    }

    @Test("`posts` wins over `blog` when both are declared")
    func postsBeatsBlog() {
        #expect(resolve(declared: ["blog", "posts"]) == .collection(name: "posts", declaredFields: ["title", "publishDate"]))
    }

    @Test("`articles` is the last blog-like fallback")
    func articlesFallback() {
        #expect(resolve(declared: ["notes", "articles"]) == .collection(name: "articles", declaredFields: ["title", "summary"]))
    }

    @Test("a config that declares collections but no blog-like one refuses rather than orphaning")
    func declaredButNoneBlogLike() {
        #expect(resolve(declared: ["events", "members"], existingDirectories: ["posts"]) == .noBlogCollection)
    }

    @Test("a declared blog collection whose schema is imported refuses rather than guessing its frontmatter")
    func importedSchemaRefuses() {
        // The shipped template's `articles`: declared, blog-like, schema imported from
        // `lib/content-schemas.ts` — so `read(...)` has no entry for it.
        #expect(resolve(declared: ["notes", "articles"], readableSchemas: [:]) == .unreadableSchema(name: "articles"))
    }

    @Test("an unreadable schema on the preferred candidate refuses instead of falling through to a lower-ranked one")
    func unreadablePreferredCandidateDoesNotFallThrough() {
        // `posts` is the site's blog by preference order; silently filing in `blog` because its
        // schema happened to be readable would put the post somewhere the owner didn't expect.
        #expect(resolve(declared: ["posts", "blog"], readableSchemas: ["blog": ["title", "pubDate"]])
                == .unreadableSchema(name: "posts"))
    }

    @Test("a zero-field schema reading counts as unreadable")
    func emptyFieldListIsUnreadable() {
        #expect(resolve(declared: ["blog"], readableSchemas: ["blog": []]) == .unreadableSchema(name: "blog"))
    }

    @Test("with no config, an existing collection directory decides")
    func noConfigUsesDirectories() {
        #expect(resolve(declared: [], readableSchemas: [:], existingDirectories: ["blog"])
                == .collection(name: "blog", declaredFields: nil))
    }

    @Test("with no config and no directories, the legacy `posts` default stands")
    func legacyDefault() {
        #expect(resolve(declared: [], readableSchemas: [:]) == .collection(name: "posts", declaredFields: nil))
    }

    private func makeSiteRoot(contentSubdirectory: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("post-collection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(contentSubdirectory), withIntermediateDirectories: true)
        return root
    }

    @Test("resolve(siteDirectory:) reads src/content.config.ts from disk")
    func readsConfigFromDisk() throws {
        let root = try makeSiteRoot(contentSubdirectory: "src/content/posts")
        defer { try? FileManager.default.removeItem(at: root) }
        // A stray `posts/` directory must not outrank the declared collection.
        try """
        import { defineCollection } from "astro:content";
        import { articlesSchema } from "./lib/content-schemas.ts";
        const blog = defineCollection({ loader: collectionLoader("blog"), schema: z.object({ title: z.string() }) });
        const articles = defineCollection({ loader: glob({ base: "./src/content/articles" }), schema: articlesSchema });
        export const collections = { blog, articles };
        """.write(to: root.appendingPathComponent("src/content.config.ts"), atomically: true, encoding: .utf8)

        #expect(PostCollectionResolver.resolve(siteDirectory: root) == .collection(name: "blog", declaredFields: ["title"]))
    }

    @Test("resolve(siteDirectory:) reports an imported-schema blog collection as unreadable (#1716)")
    func readsImportedSchemaFromDisk() throws {
        let root = try makeSiteRoot(contentSubdirectory: "src/content/articles")
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        import { defineCollection } from "astro:content";
        import { articlesSchema } from "./lib/content-schemas.ts";
        const articles = defineCollection({ loader: glob({ base: "./src/content/articles" }), schema: articlesSchema });
        export const collections = { articles };
        """.write(to: root.appendingPathComponent("src/content.config.ts"), atomically: true, encoding: .utf8)

        #expect(PostCollectionResolver.resolve(siteDirectory: root) == .unreadableSchema(name: "articles"))
    }

    @Test("resolve(siteDirectory:) honors Astro's legacy src/content/config.ts location")
    func readsLegacyConfigLocation() throws {
        let root = try makeSiteRoot(contentSubdirectory: "src/content")
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        const blog = defineCollection({ type: "content", schema: z.object({ title: z.string() }) });
        export const collections = { blog };
        """.write(to: root.appendingPathComponent("src/content/config.ts"), atomically: true, encoding: .utf8)

        #expect(PostCollectionResolver.resolve(siteDirectory: root) == .collection(name: "blog", declaredFields: ["title"]))
    }

    // MARK: - postCollections (#1725)

    @Test("postCollections returns every declared blog-like collection, not just the winner")
    func postCollectionsDeclared() {
        #expect(PostCollectionResolver.postCollections(declared: ["blog", "notes", "articles", "products"], existingDirectories: ["posts"])
            == ["blog", "articles"])
    }

    @Test("postCollections is empty when the config declares nothing blog-like")
    func postCollectionsDeclaredNoneBlogLike() {
        #expect(PostCollectionResolver.postCollections(declared: ["events", "members"], existingDirectories: ["posts"]).isEmpty)
    }

    @Test("with no config, postCollections is the existing candidate directories plus the legacy default")
    func postCollectionsNoConfig() {
        #expect(PostCollectionResolver.postCollections(declared: [], existingDirectories: ["blog"]) == ["blog", "posts"])
        #expect(PostCollectionResolver.postCollections(declared: [], existingDirectories: []) == ["posts"])
    }

    @Test("resolve(siteDirectory:) always picks a member of postCollections(siteDirectory:)")
    func resolveIsMemberOfPostCollections() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("post-collection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/content/articles"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        const blog = defineCollection({ type: "content", schema: z.object({ title: z.string() }) });
        const articles = defineCollection({ type: "content", schema: z.object({ title: z.string() }) });
        export const collections = { blog, articles };
        """.write(to: root.appendingPathComponent("src/content.config.ts"), atomically: true, encoding: .utf8)

        let set = PostCollectionResolver.postCollections(siteDirectory: root)
        #expect(set == ["blog", "articles"])
        #expect(set.contains(try #require(namedCollection(PostCollectionResolver.resolve(siteDirectory: root)))))
    }

    @Test("a declared blog collection with an unreadable schema still counts as a post collection (#1725)")
    func unreadableSchemaStillClassifiesAsPost() throws {
        // New Post… refuses to write into the template's imported-schema `articles`, but the
        // knowledge index only needs to know the collection is declared to rank its entries as posts.
        let root = try makeSiteRoot(contentSubdirectory: "src/content/articles")
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        import { articlesSchema } from "./lib/content-schemas.ts";
        const articles = defineCollection({ loader: glob({ base: "./src/content/articles" }), schema: articlesSchema });
        export const collections = { articles };
        """.write(to: root.appendingPathComponent("src/content.config.ts"), atomically: true, encoding: .utf8)

        let resolution = PostCollectionResolver.resolve(siteDirectory: root)
        #expect(resolution == .unreadableSchema(name: "articles"))
        #expect(PostCollectionResolver.postCollections(siteDirectory: root) == ["articles"])
        #expect(PostCollectionResolver.postCollections(siteDirectory: root).contains(try #require(namedCollection(resolution))))
    }

    /// The collection a resolution names, whether or not New Post… would write there — `nil`
    /// only for `.noBlogCollection`, the one outcome with no collection behind it.
    private func namedCollection(_ resolution: Resolution) -> String? {
        switch resolution {
        case .collection(let name, _), .unreadableSchema(let name): return name
        case .noBlogCollection: return nil
        }
    }
}

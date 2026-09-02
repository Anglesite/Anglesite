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
}

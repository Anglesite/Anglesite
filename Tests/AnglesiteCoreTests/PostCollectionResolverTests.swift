import Testing
import Foundation
@testable import AnglesiteCore

@Suite("PostCollectionResolver")
struct PostCollectionResolverTests {
    @Test("a config declaring only `blog` resolves to blog (#1716)")
    func blogOnly() {
        #expect(PostCollectionResolver.resolve(declared: ["blog", "notes", "events"], existingDirectories: []) == "blog")
    }

    @Test("`posts` wins over `blog` when both are declared")
    func postsBeatsBlog() {
        #expect(PostCollectionResolver.resolve(declared: ["blog", "posts"], existingDirectories: []) == "posts")
    }

    @Test("`articles` is the last blog-like fallback")
    func articlesFallback() {
        #expect(PostCollectionResolver.resolve(declared: ["notes", "articles"], existingDirectories: []) == "articles")
    }

    @Test("a config that declares collections but no blog-like one refuses rather than orphaning")
    func declaredButNoneBlogLike() {
        #expect(PostCollectionResolver.resolve(declared: ["events", "members"], existingDirectories: ["posts"]) == nil)
    }

    @Test("with no config, an existing collection directory decides")
    func noConfigUsesDirectories() {
        #expect(PostCollectionResolver.resolve(declared: [], existingDirectories: ["blog"]) == "blog")
    }

    @Test("with no config and no directories, the legacy `posts` default stands")
    func legacyDefault() {
        #expect(PostCollectionResolver.resolve(declared: [], existingDirectories: []) == "posts")
    }

    @Test("resolve(siteDirectory:) reads src/content.config.ts from disk")
    func readsConfigFromDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("post-collection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/content/posts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A stray `posts/` directory must not outrank the declared collection.
        try """
        import { defineCollection } from "astro:content";
        import { articlesSchema } from "./lib/content-schemas.ts";
        const blog = defineCollection({ loader: collectionLoader("blog"), schema: z.object({ title: z.string() }) });
        const articles = defineCollection({ loader: glob({ base: "./src/content/articles" }), schema: articlesSchema });
        export const collections = { blog, articles };
        """.write(to: root.appendingPathComponent("src/content.config.ts"), atomically: true, encoding: .utf8)

        #expect(PostCollectionResolver.resolve(siteDirectory: root) == "blog")
    }

    @Test("resolve(siteDirectory:) honors Astro's legacy src/content/config.ts location")
    func readsLegacyConfigLocation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("post-collection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/content"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        const blog = defineCollection({ type: "content", schema: z.object({ title: z.string() }) });
        export const collections = { blog };
        """.write(to: root.appendingPathComponent("src/content/config.ts"), atomically: true, encoding: .utf8)

        #expect(PostCollectionResolver.resolve(siteDirectory: root) == "blog")
    }
}

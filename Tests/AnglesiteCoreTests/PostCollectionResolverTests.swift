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
        #expect(set.contains(try #require(PostCollectionResolver.resolve(siteDirectory: root))))
    }
}

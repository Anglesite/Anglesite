import Foundation
import Testing
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("SiteKnowledgeIndex")
struct SiteKnowledgeIndexTests {

    @Test("rebuild indexes pages, components, layouts, config, and skips build artifacts")
    func rebuildIndexesProjectKnowledge() async {
        let root = try! writeSiteTree(prefix: "knowledge-index", [
            "src/pages/pricing.astro": "---\ntitle: Pricing\n---\n# Plans\n<a href=\"/contact\">Talk to sales</a>",
            "src/components/CTA.astro": "<button>Talk to sales</button>",
            "src/layouts/BaseLayout.astro": "<slot />",
            "astro.config.mjs": "export default {}",
            "node_modules/pkg/index.js": "should not be indexed",
            "dist/index.html": "built output",
        ])
        let index = SiteKnowledgeIndex()

        await index.rebuild(siteID: "site-1", projectRoot: root)

        let docs = await index.documents(siteID: "site-1")
        #expect(docs.map(\.path) == [
            "astro.config.mjs",
            "src/components/CTA.astro",
            "src/layouts/BaseLayout.astro",
            "src/pages/pricing.astro",
        ])
        #expect(docs.first { $0.path == "src/pages/pricing.astro" }?.kind == .page)
        #expect(docs.first { $0.path == "src/pages/pricing.astro" }?.title == "Pricing")
        #expect(docs.first { $0.path == "src/pages/pricing.astro" }?.internalLinks == ["/contact"])
    }

    @Test("search ranks title and path matches above body-only matches")
    func searchRanksUsefulMatches() async {
        let root = try! writeSiteTree(prefix: "knowledge-index", [
            "src/pages/pricing.astro": "---\ntitle: Pricing\n---\n# Pricing\nSimple plans for teams.",
            "src/components/Footer.astro": "<footer>See pricing for details.</footer>",
            "src/pages/about.astro": "# About\nNothing relevant.",
        ])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site-1", projectRoot: root)

        let results = await index.search(siteID: "site-1", query: "pricing", options: .init(limit: 3))

        #expect(results.first?.document.path == "src/pages/pricing.astro")
        #expect(results.first?.excerpt.contains("Pricing") == true)
        #expect(results.first?.lineRange?.lowerBound != nil)
        #expect(results.map(\.document.path).contains("src/components/Footer.astro"))
        #expect(!results.map(\.document.path).contains("src/pages/about.astro"))
    }

    @Test("formatted context includes citations and line numbers")
    func formattedContextIncludesCitations() async {
        let root = try! writeSiteTree(prefix: "knowledge-index", [
            "src/content/docs/about.md": "# About\n\nOur docs explain the launch checklist.",
        ])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site-1", projectRoot: root)

        let context = await index.formattedContext(siteID: "site-1", query: "launch checklist docs")

        #expect(context?.contains("Relevant project context") == true)
        #expect(context?.contains("[src/content/docs/about.md:") == true)
        #expect(context?.contains("launch checklist") == true)
    }

    @Test("upsert and remove update a single indexed file")
    func upsertAndRemove() async {
        let root = try! writeSiteTree(prefix: "knowledge-index", [
            "src/pages/index.astro": "# Home",
        ])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site-1", projectRoot: root)

        let newFile = root.appendingPathComponent("src/components/Hero.astro")
        try! FileManager.default.createDirectory(at: newFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("<section>Summer launch CTA</section>".utf8).write(to: newFile)
        await index.upsertFile(siteID: "site-1", projectRoot: root, relativePath: "src/components/Hero.astro")

        var results = await index.search(siteID: "site-1", query: "summer launch")
        #expect(results.first?.document.path == "src/components/Hero.astro")

        await index.removeFile(siteID: "site-1", relativePath: "src/components/Hero.astro")
        results = await index.search(siteID: "site-1", query: "summer launch")
        #expect(results.isEmpty)
    }

    @Test("rebuild stores bounded excerpts instead of full source")
    func rebuildStoresBoundedExcerpts() async {
        let longBody = String(repeating: "a", count: 9_000)
        let root = try! writeSiteTree(prefix: "knowledge-index", [
            "src/pages/long.astro": "# Long\n\(longBody)",
        ])
        let index = SiteKnowledgeIndex()

        await index.rebuild(siteID: "site-1", projectRoot: root)

        let document = await index.documents(siteID: "site-1").first
        #expect(document?.excerptText.count == 8_192)
    }

    @Test("search scores frontmatter separately from body text")
    func searchDoesNotDoubleCountFrontmatter() async {
        let root = try! writeSiteTree(prefix: "knowledge-index", [
            "src/content/example.md": "---\nsummary: launchword\n---\nNo body match here.",
        ])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site-1", projectRoot: root)

        let result = await index.search(siteID: "site-1", query: "launchword").first

        #expect(result?.score == 3)
        #expect(result?.excerpt.contains("summary: launchword") == false)
    }

    // MARK: - Post classification (#1725)

    /// A template-style `content.config.ts`: `blog` is the blog collection, `notes` and
    /// `articles` exist too, and `products` is a declared-but-not-blog-like collection.
    private static let templateStyleContentConfig = """
    import { defineCollection, z } from "astro:content";
    import { articlesSchema } from "./lib/content-schemas.ts";
    const blog = defineCollection({ loader: collectionLoader("blog"), schema: z.object({ title: z.string() }).strict() });
    const notes = defineCollection({ loader: glob({ base: "./src/content/notes" }), schema: notesSchema });
    const articles = defineCollection({ loader: glob({ base: "./src/content/articles" }), schema: articlesSchema });
    const products = defineCollection({ loader: glob({ base: "./src/content/products" }), schema: z.object({ name: z.string() }) });
    export const collections = { blog, notes, articles, products };
    """

    @Test("blog/ entries on a template-style config are classified as posts (#1725)")
    func classifiesDeclaredBlogCollectionAsPost() async {
        let root = try! writeSiteTree(prefix: "knowledge-index", [
            "src/content.config.ts": Self.templateStyleContentConfig,
            "src/content/blog/welcome.md": "---\ntitle: Welcome\n---\nFirst post.",
            "src/content/notes/quick.md": "A quick note.",
            "src/content/articles/deep-dive.md": "---\ntitle: Deep dive\n---\nLong form.",
            "src/content/products/widget.md": "---\nname: Widget\n---\nA product.",
        ])
        let index = SiteKnowledgeIndex()

        await index.rebuild(siteID: "site-1", projectRoot: root)

        let docs = await index.documents(siteID: "site-1")
        func kind(_ path: String) -> SiteKnowledgeIndex.Document.Kind? { docs.first { $0.path == path }?.kind }
        #expect(kind("src/content/blog/welcome.md") == .post)
        #expect(kind("src/content/notes/quick.md") == .post)
        #expect(kind("src/content/articles/deep-dive.md") == .post)
        #expect(kind("src/content/products/widget.md") == .content)
        #expect(kind("src/content.config.ts") == .script)
    }

    @Test("posts/ and notes/ stay post-like on a site with no content config")
    func classifiesLegacyPostsWithoutConfig() async {
        let root = try! writeSiteTree(prefix: "knowledge-index", [
            "src/content/posts/hello.md": "---\ntitle: Hello\n---\nLegacy layout.",
            "src/content/notes/quick.md": "A quick note.",
            "src/content/docs/guide.md": "# Guide",
        ])
        let index = SiteKnowledgeIndex()

        await index.rebuild(siteID: "site-1", projectRoot: root)

        let docs = await index.documents(siteID: "site-1")
        func kind(_ path: String) -> SiteKnowledgeIndex.Document.Kind? { docs.first { $0.path == path }?.kind }
        #expect(kind("src/content/posts/hello.md") == .post)
        #expect(kind("src/content/notes/quick.md") == .post)
        #expect(kind("src/content/docs/guide.md") == .content)
    }

    @Test("with no content config, an existing blog/ directory is post-like")
    func classifiesExistingBlogDirectoryWithoutConfig() async {
        let root = try! writeSiteTree(prefix: "knowledge-index", [
            "src/content/blog/welcome.md": "---\ntitle: Welcome\n---\nFirst post.",
        ])
        let index = SiteKnowledgeIndex()

        await index.rebuild(siteID: "site-1", projectRoot: root)

        let doc = await index.documents(siteID: "site-1").first { $0.path == "src/content/blog/welcome.md" }
        #expect(doc?.kind == .post)
    }

    @Test("a config that declares posts but not blog keeps blog/ as plain content")
    func declaredPostsCollectionExcludesUndeclaredBlog() async {
        let root = try! writeSiteTree(prefix: "knowledge-index", [
            "src/content.config.ts": """
            const posts = defineCollection({ type: "content", schema: z.object({ title: z.string() }) });
            export const collections = { posts };
            """,
            "src/content/posts/hello.md": "---\ntitle: Hello\n---\nIndieWeb-style.",
            "src/content/blog/stray.md": "Not wired up in this site's config.",
        ])
        let index = SiteKnowledgeIndex()

        await index.rebuild(siteID: "site-1", projectRoot: root)

        let docs = await index.documents(siteID: "site-1")
        #expect(docs.first { $0.path == "src/content/posts/hello.md" }?.kind == .post)
        #expect(docs.first { $0.path == "src/content/blog/stray.md" }?.kind == .content)
    }

    @Test("upsertFile classifies a new blog/ entry with the same collection rules")
    func upsertClassifiesDeclaredBlogCollection() async {
        let root = try! writeSiteTree(prefix: "knowledge-index", [
            "src/content.config.ts": Self.templateStyleContentConfig,
            "src/pages/index.astro": "# Home",
        ])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "site-1", projectRoot: root)

        let newFile = root.appendingPathComponent("src/content/blog/second.md")
        try! FileManager.default.createDirectory(at: newFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("---\ntitle: Second\n---\nAnother post.".utf8).write(to: newFile)
        await index.upsertFile(siteID: "site-1", projectRoot: root, relativePath: "src/content/blog/second.md")

        let doc = await index.document(siteID: "site-1", relativePath: "src/content/blog/second.md")
        #expect(doc?.kind == .post)
    }

    @Test("upsertFile(postCollections:) classifies with the caller's set instead of re-resolving")
    func upsertHonorsPrecomputedPostCollections() async {
        // No config plus an existing blog/ directory: resolving from disk yields a set that
        // contains "blog", so a classification that follows only the passed-in set proves the
        // batch variant never re-reads the site.
        let root = try! writeSiteTree(prefix: "knowledge-index", [
            "src/content/blog/welcome.md": "---\ntitle: Welcome\n---\nFirst post.",
        ])
        #expect(SiteKnowledgeIndex.postCollections(projectRoot: root) == ["blog", "posts", "notes"])
        let index = SiteKnowledgeIndex()
        let path = "src/content/blog/welcome.md"

        await index.upsertFile(siteID: "site-1", projectRoot: root, relativePath: path, postCollections: [])
        #expect(await index.document(siteID: "site-1", relativePath: path)?.kind == .content)

        await index.upsertFile(siteID: "site-1", projectRoot: root, relativePath: path, postCollections: ["blog"])
        #expect(await index.document(siteID: "site-1", relativePath: path)?.kind == .post)
    }

    @Test("unload removes only the requested site")
    func unloadRemovesOnlyRequestedSite() async {
        let rootA = try! writeSiteTree(prefix: "knowledge-index", ["src/pages/a.astro": "# Alpha"])
        let rootB = try! writeSiteTree(prefix: "knowledge-index", ["src/pages/b.astro": "# Beta"])
        let index = SiteKnowledgeIndex()
        await index.rebuild(siteID: "a", projectRoot: rootA)
        await index.rebuild(siteID: "b", projectRoot: rootB)

        await index.unload(siteID: "a")

        #expect(await index.search(siteID: "a", query: "alpha").isEmpty)
        #expect(await index.search(siteID: "b", query: "beta").count == 1)
    }
}

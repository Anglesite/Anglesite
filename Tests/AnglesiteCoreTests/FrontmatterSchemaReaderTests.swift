import Testing
import Foundation
@testable import AnglesiteCore

@Suite("FrontmatterSchemaReader")
struct FrontmatterSchemaReaderTests {
    @Test("extracts collection names and field names from a content.config.ts-shaped source")
    func extractsCollectionsAndFields() {
        let source = """
        import { defineCollection } from "astro:content";
        import { glob } from "astro/loaders";
        import { z } from "astro/zod";

        const blog = defineCollection({
          loader: glob({ pattern: "**/*.md", base: "./src/content/blog" }),
          schema: z.object({
            title: z.string(),
            pubDate: z.coerce.date(),
            description: z.string().optional(),
            draft: z.boolean().default(false),
          }).strict(),
        });

        const events = defineCollection({
          loader: glob({ pattern: "**/*.md", base: "./src/content/events" }),
          schema: z.object({
            name: z.string(),
            start: z.coerce.date(),
          }).strict(),
        });

        export const collections = { blog, events };
        """

        let collections = FrontmatterSchemaReader.collections(fromContentConfig: source)

        #expect(collections["blog"] == ["title", "pubDate", "description", "draft"])
        #expect(collections["events"] == ["name", "start"])
    }

    @Test("collectionNames lists every defineCollection, including ones whose schema is imported")
    func collectionNamesIncludesImportedSchemas() {
        let source = """
        const blog = defineCollection({ loader: collectionLoader("blog"), schema: z.object({ title: z.string() }) });
        const articles = defineCollection({ loader: glob({ base: "./src/content/articles" }), schema: articlesSchema });
        export const collections = { blog, articles };
        """
        #expect(FrontmatterSchemaReader.collectionNames(fromContentConfig: source) == ["blog", "articles"])
        // The field map still omits the collection it can't read a schema for.
        #expect(FrontmatterSchemaReader.collections(fromContentConfig: source)["articles"] == nil)
    }

    @Test("a schema composed entirely from spreads is omitted rather than reported as having no fields (#1716)")
    func spreadOnlySchemaIsOmitted() {
        let source = """
        const blog = defineCollection({ loader: collectionLoader("blog"), schema: z.object({ ...sharedBlogFields }).strict() });
        const notes = defineCollection({ loader: collectionLoader("notes"), schema: z.object({ ...socialFields, content: z.string() }) });
        export const collections = { blog, notes };
        """
        let collections = FrontmatterSchemaReader.collections(fromContentConfig: source)
        // `[]` would claim the schema has no fields — a guess, not a reading — so `blog` is left
        // out like an imported schema, while a spread plus real keys still reads normally.
        #expect(collections["blog"] == nil)
        #expect(collections["notes"] == ["content"])
        // It is still a declared collection.
        #expect(FrontmatterSchemaReader.collectionNames(fromContentConfig: source) == ["blog", "notes"])
    }

    @Test("returns an empty map for unrecognized shapes rather than guessing")
    func returnsEmptyForUnrecognizedShape() {
        let collections = FrontmatterSchemaReader.collections(fromContentConfig: "export const collections = {};")
        #expect(collections.isEmpty)
    }

    @Test("read(siteDirectory:) returns empty when content.config.ts is missing")
    func readReturnsEmptyWhenFileMissing() {
        let missingRoot = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)", isDirectory: true)
        #expect(FrontmatterSchemaReader.read(siteDirectory: missingRoot).isEmpty)
    }
}

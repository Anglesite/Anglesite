import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportEmitterTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func emitsBlogPostWithStrictFrontmatter() {
        let item = ImportItem(sourceURL: "https://e.com/one", title: "Hello: World",
                              published: Date(timeIntervalSince1970: 1_714_557_600), // 2024-05-01
                              markdown: "Body", excerpt: "A teaser", rung: .wpREST, hint: .wpPost)
        let emission = ImportEmitter.emission(for:
            ClassifiedItem(item: item, destination: .collection(name: "blog", slug: "one")), now: Self.now)
        #expect(emission.relativePath == "src/content/blog/one.md")
        #expect(emission.contents == """
        ---
        title: "Hello: World"
        pubDate: 2024-05-01
        description: A teaser
        draft: false
        ---

        Body
        """)
    }

    @Test func emitsBookmarkWithTarget() {
        let item = ImportItem(sourceURL: "https://e.com/b", title: nil,
                              published: Date(timeIntervalSince1970: 1_714_557_600),
                              markdown: "Why I saved this", rung: .microformats,
                              hint: .bookmark(of: "https://other.example/post"))
        let emission = ImportEmitter.emission(for:
            ClassifiedItem(item: item, destination: .collection(name: "bookmarks", slug: "b")), now: Self.now)
        #expect(emission.contents.contains("bookmarkOf: https://other.example/post"))
        #expect(emission.contents.contains("publishDate: 2024-05-01"))
        #expect(!emission.contents.contains("title:"))
    }

    @Test func emitsMarkdownPageWithLayout() {
        let item = ImportItem(sourceURL: "https://e.com/about", title: "About",
                              markdown: "Hi", rung: .readability, hint: .none)
        let emission = ImportEmitter.emission(for:
            ClassifiedItem(item: item, destination: .page(route: "/about")), now: Self.now)
        #expect(emission.relativePath == "src/pages/about.md")
        #expect(emission.contents.contains("layout: ../layouts/BaseLayout.astro"))
        #expect(emission.contents.contains("title: About"))
    }

    @Test func emitsBlogLang() {
        let item = ImportItem(sourceURL: "https://e.com/fr-post", title: "Bonjour",
                              published: Date(timeIntervalSince1970: 1_714_557_600),
                              lang: "fr", markdown: "Corps", rung: .wpREST, hint: .wpPost)
        let emission = ImportEmitter.emission(for:
            ClassifiedItem(item: item, destination: .collection(name: "blog", slug: "fr-post")), now: Self.now)
        #expect(emission.contents.contains("lang: fr"))
    }

    @Test func emitsNotesPublishDateFallsBackToNow() {
        // Self.now (1_700_000_000) is 2023-11-14 22:13:20 UTC.
        let item = ImportItem(sourceURL: "https://e.com/note", published: nil,
                              markdown: "A note", rung: .microformats, hint: .note)
        let emission = ImportEmitter.emission(for:
            ClassifiedItem(item: item, destination: .collection(name: "notes", slug: "note")), now: Self.now)
        #expect(emission.contents.contains("publishDate: 2023-11-14"))
    }
}

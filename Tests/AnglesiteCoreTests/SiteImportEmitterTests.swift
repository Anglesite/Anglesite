import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportEmitterTests {
    @Test func emitsBlogPostWithStrictFrontmatter() {
        let item = ImportItem(sourceURL: "https://e.com/one", title: "Hello: World",
                              published: Date(timeIntervalSince1970: 1_714_557_600), // 2024-05-01
                              markdown: "Body", excerpt: "A teaser", rung: .wpREST, hint: .wpPost)
        let emission = ImportEmitter.emission(for:
            ClassifiedItem(item: item, destination: .collection(name: "blog", slug: "one")))
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
            ClassifiedItem(item: item, destination: .collection(name: "bookmarks", slug: "b")))
        #expect(emission.contents.contains("bookmarkOf: https://other.example/post"))
        #expect(emission.contents.contains("publishDate: 2024-05-01"))
        #expect(!emission.contents.contains("title:"))
    }

    @Test func emitsMarkdownPageWithLayout() {
        let item = ImportItem(sourceURL: "https://e.com/about", title: "About",
                              markdown: "Hi", rung: .readability, hint: .none)
        let emission = ImportEmitter.emission(for:
            ClassifiedItem(item: item, destination: .page(route: "/about")))
        #expect(emission.relativePath == "src/pages/about.md")
        #expect(emission.contents.contains("layout: ../layouts/BaseLayout.astro"))
        #expect(emission.contents.contains("title: About"))
    }
}

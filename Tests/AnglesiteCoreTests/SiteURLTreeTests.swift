import Testing
import Foundation
@testable import AnglesiteCore

struct SiteURLTreeTests {
    private func page(_ route: String, title: String?) -> SiteContentGraph.Page {
        SiteContentGraph.Page(id: "s:page:\(route)", siteID: "s", route: route,
            filePath: "src/pages\(route == "/" ? "/index" : route).astro",
            title: title, lastModified: Date(timeIntervalSince1970: 0))
    }
    private func post(_ collection: String, _ slug: String, _ title: String,
                      date: Date? = nil) -> SiteContentGraph.Post {
        SiteContentGraph.Post(id: "s:post:\(slug)", siteID: "s", collection: collection,
            slug: slug, title: title, draft: false, publishDate: date, tags: [],
            filePath: "src/content/\(collection)/\(slug).md",
            lastModified: Date(timeIntervalSince1970: 0))
    }
    private func build(pages: [SiteContentGraph.Page] = [],
                       posts: [SiteContentGraph.Post] = [],
                       feeds: Set<String> = []) -> [URLTreeNode] {
        buildSiteURLTree(pages: pages, posts: posts, feedCollections: feeds)
    }

    @Test("empty site produces an empty tree (sidebar shows its empty state)")
    func emptySite() {
        #expect(build() == [])
    }

    @Test func treeHasNoWebsiteRow() {
        let home = page("/", title: "Home")
        let tree = buildSiteURLTree(pages: [home], posts: [], feedCollections: [])
        #expect(tree.allSatisfy { $0.id != "website" })
        #expect(tree.first?.kind == .home)
    }

    @Test("home is pinned first, before other pages, before directories")
    func topLevelOrder() {
        let nodes = build(
            pages: [page("/zebra", title: "Zebra"), page("/", title: "Home"),
                    page("/about", title: "About")],
            posts: [post("notes", "n1", "First note")])
        #expect(nodes.map(\.id) ==
            ["s:page:/", "s:page:/about", "s:page:/zebra", "dir:/notes/"])
        #expect(nodes[0].kind == .home)
        #expect(nodes[0].target == .route("/"))
    }

    @Test("collection directory carries hasFeed from the probe set and its collection name")
    func feedBadge() throws {
        let nodes = build(posts: [post("notes", "n1", "A"), post("photos", "p1", "B")],
                          feeds: ["notes"])
        let notes = try #require(nodes.first { $0.id == "dir:/notes/" })
        let photos = try #require(nodes.first { $0.id == "dir:/photos/" })
        #expect(notes.kind == .directory(collection: "notes", hasFeed: true))
        #expect(photos.kind == .directory(collection: "photos", hasFeed: false))
        #expect(notes.target == .directory(collection: "notes", route: "/notes/"))
    }

    @Test("directory titles use the registry displayName, else the capitalized segment")
    func directoryTitles() {
        let nodes = build(posts: [post("notes", "n1", "A"), post("mixtapes", "m1", "B")])
        // "notes" is a registered content type whose descriptor displayName is "Note" (see the
        // `note` ContentTypeDescriptor in ContentTypeRegistry.swift); "mixtapes" is not registered,
        // so it falls back to the capitalized URL segment.
        #expect(nodes.first { $0.id == "dir:/notes/" }?.title == "Note")
        #expect(nodes.first { $0.id == "dir:/mixtapes/" }?.title == "Mixtapes")
    }

    @Test("entries sort reverse-chronologically; undated entries follow, sorted by title")
    func entryOrder() throws {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let nodes = build(posts: [
            post("notes", "b-undated", "Bravo"),
            post("notes", "old", "Old", date: old),
            post("notes", "a-undated", "Alpha"),
            post("notes", "new", "New", date: new),
        ])
        let dir = try #require(nodes.first { $0.id == "dir:/notes/" })
        #expect(dir.children?.map(\.title) == ["New", "Old", "Alpha", "Bravo"])
    }

    @Test("a directory's own index page is pinned before its entries")
    func directoryIndexPinned() throws {
        let nodes = build(
            pages: [page("/", title: "Home"), page("/notes", title: "All Notes")],
            posts: [post("notes", "n1", "First", date: Date(timeIntervalSince1970: 1))])
        let dir = try #require(nodes.first { $0.id == "dir:/notes/" })
        #expect(dir.children?.map(\.title) == ["All Notes", "First"])
        // The merged /notes page is a child, not a top-level sibling.
        #expect(!nodes.contains { $0.id == "s:page:/notes" })
    }

    @Test("nested src/pages folders form directory chains")
    func nestedPageFolders() throws {
        let nodes = build(pages: [
            page("/", title: "Home"),
            page("/docs/guides/setup", title: "Setup"),
        ])
        let docs = try #require(nodes.first { $0.id == "dir:/docs/" })
        #expect(docs.kind == .directory(collection: nil, hasFeed: false))
        let guides = try #require(docs.children?.first { $0.id == "dir:/docs/guides/" })
        #expect(guides.children?.map(\.title) == ["Setup"])
    }

    @Test("entry leaf routes are the percent-encoded postRoute")
    func entryRoutes() throws {
        let nodes = build(posts: [post("notes", "héllo wörld", "Hello")])
        let dir = try #require(nodes.first { $0.id == "dir:/notes/" })
        #expect(dir.children?.first?.target == .route(postRoute(for: post("notes", "héllo wörld", "Hello"))))
    }

    @Test("a directory index page merges correctly even when the segment needs percent-encoding")
    func directoryIndexPinnedWithEncodedSegment() throws {
        let nodes = build(
            pages: [page("/", title: "Home"), page("/my notes", title: "All My Notes")],
            posts: [post("my notes", "n1", "First", date: Date(timeIntervalSince1970: 1))])
        let dir = try #require(nodes.first { $0.id == "dir:/my notes/" })
        #expect(dir.children?.map(\.title) == ["All My Notes", "First"])
        // The merged /my notes page is a child, not a top-level sibling.
        #expect(!nodes.contains { $0.id == "s:page:/my notes" })
    }

    @Test("leaf ids are graph entity ids")
    func leafIDs() throws {
        let nodes = build(pages: [page("/", title: "Home")],
                          posts: [post("notes", "n1", "First")])
        #expect(nodes.contains { $0.id == "s:page:/" })
        let dir = try #require(nodes.first { $0.id == "dir:/notes/" })
        #expect(dir.children?.first?.id == "s:post:n1")
    }
}

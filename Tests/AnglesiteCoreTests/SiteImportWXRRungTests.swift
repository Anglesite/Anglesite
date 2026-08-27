import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportWXRRungTests {
    /// Returns fixed Markdown/images for every call, recording what it was asked to convert —
    /// stands in for `OffscreenHTMLConverter` (Task 5, which needs a real `WKWebView`).
    private final class FakeConverter: ImportHTMLConverter, @unchecked Sendable {
        var responses: [String: (markdown: String, images: [String])] = [:]
        private(set) var converted: [String] = []

        func convert(html: String) async -> (markdown: String, images: [String]) {
            converted.append(html)
            return responses[html] ?? ("", [])
        }
    }

    private func makeEntry(title: String? = "Hello", link: String = "https://example.com/hello/",
                           postType: String = "post", status: String = "publish",
                           content: String = "<p>Hi</p>", excerpt: String? = nil) -> WXREntry {
        WXREntry(title: title, link: link, postType: postType, status: status,
                 published: Date(timeIntervalSince1970: 1_700_000_000),
                 contentEncoded: content, excerptEncoded: excerpt)
    }

    @Test func convertsPostContentToAnImportItem() async {
        let converter = FakeConverter()
        converter.responses["<p>Hi</p>"] = ("Hi", ["https://example.com/cat.jpg"])
        let (items, problems) = await WXRRung.items(from: [makeEntry()], convert: converter)

        #expect(problems.isEmpty)
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.sourceURL == "https://example.com/hello")
        #expect(item.title == "Hello")
        #expect(item.markdown == "Hi")
        #expect(item.images == ["https://example.com/cat.jpg"])
        #expect(item.rung == .wxr)
        #expect(item.hint == .wpPost)
        #expect(item.published == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func postTypePageGetsPageHint() async {
        let converter = FakeConverter()
        converter.responses["<p>About us</p>"] = ("About us", [])
        let (items, _) = await WXRRung.items(
            from: [makeEntry(link: "https://example.com/about/", postType: "page", content: "<p>About us</p>")],
            convert: converter)
        #expect(items.first?.hint == .wpPage)
    }

    @Test func nonPublishedStatusIsSkipped() async {
        let converter = FakeConverter()
        let (items, problems) = await WXRRung.items(
            from: [makeEntry(status: "draft"), makeEntry(link: "https://example.com/t/", status: "trash")],
            convert: converter)
        #expect(items.isEmpty)
        #expect(problems.isEmpty)
        #expect(converter.converted.isEmpty) // never even asked to convert skipped content
    }

    @Test func nonPostPageTypeIsSkipped() async {
        let converter = FakeConverter()
        let (items, _) = await WXRRung.items(
            from: [makeEntry(postType: "attachment"), makeEntry(link: "https://example.com/n/", postType: "nav_menu_item")],
            convert: converter)
        #expect(items.isEmpty)
    }

    @Test func emptyConvertedMarkdownBecomesAProblemNotAnItem() async {
        let converter = FakeConverter() // no response registered → ("", [])
        let (items, problems) = await WXRRung.items(from: [makeEntry()], convert: converter)
        #expect(items.isEmpty)
        #expect(problems.count == 1)
        #expect(problems.first?.sourceURL == "https://example.com/hello/")
    }

    @Test func excerptIsConvertedSeparatelyWhenPresent() async {
        let converter = FakeConverter()
        converter.responses["<p>Hi</p>"] = ("Hi", [])
        converter.responses["<p>Short</p>"] = ("Short", [])
        let (items, _) = await WXRRung.items(from: [makeEntry(excerpt: "<p>Short</p>")], convert: converter)
        #expect(items.first?.excerpt == "Short")
        #expect(converter.converted == ["<p>Hi</p>", "<p>Short</p>"])
    }

    @Test func titlePassesThroughUnchanged() async {
        let converter = FakeConverter()
        converter.responses["<p>Hi</p>"] = ("Hi", [])
        let (items, _) = await WXRRung.items(from: [makeEntry(title: "Tom & Jerry")], convert: converter)
        #expect(items.first?.title == "Tom & Jerry")
    }
}

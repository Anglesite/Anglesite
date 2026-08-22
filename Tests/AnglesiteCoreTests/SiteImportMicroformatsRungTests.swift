import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportMicroformatsRungTests {
    private func page(mf2: String, url: String = "https://example.com/x/") -> CapturedPage {
        CapturedPage(url: url, extraction: ExtractionRecord(markdown: "fallback", mf2JSON: mf2))
    }
    private func snapshot(_ pages: [CapturedPage], conversions: [String: String] = [:]) -> ImportSnapshot {
        ImportSnapshot(siteURL: "https://example.com", probes: SiteProbes(),
                       pages: pages, assets: [], conversions: conversions)
    }

    @Test func titleLessEntryIsANote() {
        let mf2 = """
        {"items":[{"type":["h-entry"],"properties":{
          "content":[{"html":"<p>hi</p>","value":"hi"}],
          "published":["2024-05-01T10:00:00Z"],
          "url":["https://example.com/note-1/"]}}]}
        """
        let result = MicroformatsRung.items(from: snapshot(
            [page(mf2: mf2)], conversions: [ImportSnapshot.htmlKey("<p>hi</p>"): "hi"]))
        #expect(result.items.first?.hint == .note)
        #expect(result.items.first?.markdown == "hi")
        #expect(result.items.first?.sourceURL == "https://example.com/note-1")
    }

    @Test func bookmarkOfWins() {
        let mf2 = """
        {"items":[{"type":["h-entry"],"properties":{
          "name":["Cool link"],"bookmark-of":["https://other.example/post"],
          "content":[{"html":"<p>c</p>","value":"c"}],"url":["https://example.com/b-1/"]}}]}
        """
        let result = MicroformatsRung.items(from: snapshot(
            [page(mf2: mf2)], conversions: [ImportSnapshot.htmlKey("<p>c</p>"): "c"]))
        #expect(result.items.first?.hint == .bookmark(of: "https://other.example/post"))
        #expect(result.items.first?.title == "Cool link")
    }

    @Test func photoEntryCarriesImage() {
        let mf2 = """
        {"items":[{"type":["h-entry"],"properties":{
          "photo":["https://example.com/images/p.jpg"],
          "url":["https://example.com/p-1/"]}}]}
        """
        let result = MicroformatsRung.items(from: snapshot([page(mf2: mf2)]))
        #expect(result.items.first?.hint == .photo(image: "https://example.com/images/p.jpg"))
        #expect(result.items.first?.markdown == "fallback")
    }
}

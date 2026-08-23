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
        // The hint alone isn't enough: `AssetLocalizer` only localizes what `images` lists.
        #expect(result.items.first?.images == ["https://example.com/images/p.jpg"])
    }

    @Test("photo properties lead, page images follow only on a body fallback, deduplicated")
    func threadsPhotoAndPageImages() {
        let mf2 = """
        {"items":[{"type":["h-entry"],"properties":{
          "photo":["https://example.com/a.jpg",{"value":"https://example.com/b.jpg","alt":"B"}],
          "url":["https://example.com/g-1/"]}}]}
        """
        let fellBack = CapturedPage(
            url: "https://example.com/x/",
            extraction: ExtractionRecord(
                markdown: "fallback", images: ["https://example.com/b.jpg", "https://example.com/c.jpg"],
                mf2JSON: mf2))
        #expect(MicroformatsRung.items(from: snapshot([fellBack])).items.first?.images == [
            "https://example.com/a.jpg", "https://example.com/b.jpg", "https://example.com/c.jpg",
        ])

        // With its own content the entry never reads the page body, so the page's images —
        // navigation chrome, sidebar thumbnails — aren't this entry's to claim.
        let ownBody = """
        {"items":[{"type":["h-entry"],"properties":{
          "photo":["https://example.com/a.jpg"],
          "content":[{"html":"<p>hi</p>","value":"hi"}],
          "url":["https://example.com/g-2/"]}}]}
        """
        let independent = CapturedPage(
            url: "https://example.com/y/",
            extraction: ExtractionRecord(
                markdown: "fallback", images: ["https://example.com/c.jpg"], mf2JSON: ownBody))
        let result = MicroformatsRung.items(from: snapshot(
            [independent], conversions: [ImportSnapshot.htmlKey("<p>hi</p>"): "hi"]))
        #expect(result.items.first?.images == ["https://example.com/a.jpg"])
    }
}

import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportSnapshotTests {
    @Test func normalizeURLDropsFragmentAndTrailingSlash() {
        #expect(ImportSnapshot.normalizeURL("HTTPS://Example.COM/Blog/Post/#x")
            == "https://example.com/Blog/Post")
        #expect(ImportSnapshot.normalizeURL("https://example.com/") == "https://example.com/")
        #expect(ImportSnapshot.normalizeURL("https://example.com/p?p=12") == "https://example.com/p?p=12")
    }

    @Test func htmlKeyIsStableSHA256Hex() {
        // echo -n "<p>hi</p>" | shasum -a 256
        #expect(ImportSnapshot.htmlKey("<p>hi</p>")
            == "0a4735281db700223af63abc387c351f64ea6961a1ef955631df08d96169e772")
    }

    @Test func conversionLookupAndPageLookupRoundTrip() throws {
        let html = "<p>Body</p>"
        let page = CapturedPage(
            url: "https://example.com/about/",
            extraction: ExtractionRecord(title: "About", markdown: "Body"))
        let snapshot = ImportSnapshot(
            siteURL: "https://example.com", probes: SiteProbes(), pages: [page],
            assets: [CapturedAsset(sourceURL: "https://example.com/a.jpg", relativePath: "assets/a.jpg")],
            conversions: [ImportSnapshot.htmlKey(html): "Body"])
        #expect(snapshot.markdown(forHTML: html) == "Body")
        #expect(snapshot.page(forURL: "https://example.com/about") != nil)
        #expect(snapshot.asset(forURL: "https://example.com/a.jpg")?.relativePath == "assets/a.jpg")
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(ImportSnapshot.self, from: data) == snapshot)
    }
}

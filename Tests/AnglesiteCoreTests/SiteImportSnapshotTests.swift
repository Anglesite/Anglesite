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

    @Test func portableSHA256MatchesKnownVectorsAndCryptoKit() {
        // PortableSHA256 is the Linux fallback for ImportSnapshot.htmlKey(_:) (CryptoKit isn't
        // available on the Linux AnglesiteCore build); it must reproduce SHA-256 exactly, not
        // merely be internally consistent. Pin it against known test vectors, then confirm it
        // agrees with CryptoKit's own output on this (Darwin) platform.
        #expect(PortableSHA256.hexDigest(of: Array("".utf8))
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(PortableSHA256.hexDigest(of: Array("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        // >64 bytes (two SHA-256 blocks), to exercise the multi-chunk padding/processing path.
        // echo -n '<input>' | shasum -a 256
        let multiBlock = "The quick brown fox jumps over the lazy dog. "
            + "The quick brown fox jumps over the lazy dog again for good measure."
        #expect(multiBlock.utf8.count > 64)
        #expect(PortableSHA256.hexDigest(of: Array(multiBlock.utf8))
            == "91292f84fa2a6a1eb96de6bc59f72677741a8f221ece84e7f9931cb44638f6e6")

        #expect(PortableSHA256.hexDigest(of: Array(multiBlock.utf8)) == ImportSnapshot.htmlKey(multiBlock))
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

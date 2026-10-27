import Foundation
import Testing
@testable import AnglesiteCore

@Suite("SharePreviewCard")
struct SharePreviewCardTests {
    private let pageURL = URL(string: "http://localhost:4321/about")!

    @Test("full metadata carries through title, description, image, and domain")
    func fullMetadata() {
        let metadata = LinkMetadata(
            title: "About Us", description: "Who we are.", siteName: "Example",
            imageURL: "https://cdn.example.com/card.jpg")
        let card = SharePreviewCard.make(from: metadata, pageURL: pageURL)
        #expect(card.title == "About Us")
        #expect(card.description == "Who we are.")
        #expect(card.imageURL == URL(string: "https://cdn.example.com/card.jpg"))
        #expect(card.domain == "localhost:4321")
    }

    @Test("missing title surfaces as nil, not an invented value")
    func missingTitle() {
        let metadata = LinkMetadata(title: nil, description: "Who we are.")
        let card = SharePreviewCard.make(from: metadata, pageURL: pageURL)
        #expect(card.title == nil)
    }

    @Test("missing description surfaces as nil, not an invented value")
    func missingDescription() {
        let metadata = LinkMetadata(title: "About Us", description: nil)
        let card = SharePreviewCard.make(from: metadata, pageURL: pageURL)
        #expect(card.description == nil)
    }

    @Test("missing image surfaces as nil — never substitute artwork")
    func missingImage() {
        let metadata = LinkMetadata(title: "About Us", description: "Who we are.", imageURL: nil)
        let card = SharePreviewCard.make(from: metadata, pageURL: pageURL)
        #expect(card.imageURL == nil)
    }

    @Test("a relative og:image is resolved to absolute against the page URL")
    func relativeImageResolved() {
        let metadata = LinkMetadata(title: "About Us", imageURL: "/card.png")
        let card = SharePreviewCard.make(from: metadata, pageURL: pageURL)
        #expect(card.imageURL == URL(string: "http://localhost:4321/card.png"))
    }

    @Test("a non-http(s) og:image (e.g. data:) is dropped, never passed through")
    func nonHTTPImageDropped() {
        let metadata = LinkMetadata(title: "About Us", imageURL: "javascript:alert(1)")
        let card = SharePreviewCard.make(from: metadata, pageURL: pageURL)
        #expect(card.imageURL == nil)
    }

    @Test("display domain is the page URL's host, plus its port when it has one")
    func displayDomainWithPort() {
        #expect(SharePreviewCard.displayDomain(for: URL(string: "http://localhost:4321/about")!) == "localhost:4321")
        #expect(SharePreviewCard.displayDomain(for: URL(string: "https://example.com/about")!) == "example.com")
        #expect(SharePreviewCard.displayDomain(for: URL(string: "https://example.com:8443/about")!) == "example.com:8443")
    }
}

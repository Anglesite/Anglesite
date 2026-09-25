// Tests for the share extension's request parsing (#1968): what Safari hands over — an
// `NSExtensionItem` with a URL attachment and the page title as content text — and every way
// that can be missing. Real `NSItemProvider`s, so the URL round-trips through the same
// `loadObject(ofClass:)` path the extension uses.
import Foundation
import Testing
@testable import AnglesiteShareExtensionCore

@Suite("ShareExtensionInputExtractor")
struct ShareExtensionInputExtractorTests {
    private static func item(url: URL?, text: String? = nil, extraProviders: [NSItemProvider] = []) -> NSExtensionItem {
        let item = NSExtensionItem()
        var attachments = extraProviders
        if let url {
            attachments.append(NSItemProvider(object: url as NSURL))
        }
        item.attachments = attachments
        if let text {
            item.attributedContentText = NSAttributedString(string: text)
        }
        return item
    }

    @Test("a URL attachment plus content text yields the URL and the trimmed title")
    func urlAndTitle() async {
        let input = await ShareExtensionInputExtractor.extract(fromItems: [
            Self.item(url: URL(string: "https://example.com/a?b=1")!, text: "  Example Page \n")
        ])
        #expect(input == ShareExtensionInput(urlString: "https://example.com/a?b=1", title: "Example Page"))
    }

    @Test("no content text means an empty title, which the model fills from metadata")
    func missingTitleIsEmpty() async {
        let input = await ShareExtensionInputExtractor.extract(fromItems: [
            Self.item(url: URL(string: "https://example.com/")!)
        ])
        #expect(input?.title == "")
        #expect(input?.urlString == "https://example.com/")
    }

    @Test("a non-URL attachment ahead of the URL is skipped, not mistaken for the page")
    func skipsNonURLAttachments() async {
        let text = NSItemProvider(object: "just text" as NSString)
        let input = await ShareExtensionInputExtractor.extract(fromItems: [
            Self.item(url: URL(string: "https://example.com/page")!, text: "Page", extraProviders: [text])
        ])
        #expect(input?.urlString == "https://example.com/page")
    }

    @Test("no items, no attachments, or only non-URL attachments yield nil")
    func missingURLYieldsNil() async {
        #expect(await ShareExtensionInputExtractor.extract(fromItems: []) == nil)
        #expect(await ShareExtensionInputExtractor.extract(fromItems: [Self.item(url: nil, text: "Title")]) == nil)
        let textOnly = NSItemProvider(object: "text" as NSString)
        #expect(await ShareExtensionInputExtractor.extract(fromItems: [Self.item(url: nil, extraProviders: [textOnly])]) == nil)
        #expect(await ShareExtensionInputExtractor.extract(fromItems: ["not an extension item"]) == nil)
    }
}

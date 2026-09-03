import Testing
import Foundation
@testable import AnglesiteCore

// Gated like the type under test — `WYSIWYGAltTextProposer` references `GeneratedAltText`
// (`@Generable`, Xcode-27 only). The logic here is model-free: the vision call is injected as a
// closure.
#if compiler(>=6.4) && canImport(FoundationModels)

@Suite("WYSIWYGAltTextProposer")
struct WYSIWYGAltTextProposerTests {
    private let context = AssistantContext(
        siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/my-site", isDirectory: true))
    private let imageURL = URL(fileURLWithPath: "/tmp/my-site/public/images/hero.jpg")

    private actor LogRecorder {
        private(set) var messages: [String] = []
        func record(_ message: String) { messages.append(message) }
    }

    @Test("returns the produced alt text on success")
    func returnsProducedAltText() async {
        let proposer = WYSIWYGAltTextProposer(produce: { _, _ in
            GeneratedAltText(altText: "A white circle on a blue square", isDecorative: false)
        })
        let result = await proposer.propose(imageURL: imageURL, context: context)
        #expect(result?.altText == "A white circle on a blue square")
        #expect(result?.isDecorative == false)
    }

    @Test("passes the image URL and context straight through to produce")
    func passesArgumentsThrough() async {
        var seenURL: URL?
        var seenSiteID: String?
        let proposer = WYSIWYGAltTextProposer(produce: { url, ctx in
            seenURL = url
            seenSiteID = ctx.siteID
            return GeneratedAltText(altText: "x", isDecorative: false)
        })
        _ = await proposer.propose(imageURL: imageURL, context: context)
        #expect(seenURL == imageURL)
        #expect(seenSiteID == "site-1")
    }

    @Test("returns nil and logs when the vision call throws")
    func returnsNilAndLogsOnFailure() async {
        struct Boom: Error {}
        let logs = LogRecorder()
        let proposer = WYSIWYGAltTextProposer(
            produce: { _, _ in throw Boom() },
            log: { text in await logs.record(text) }
        )
        let result = await proposer.propose(imageURL: imageURL, context: context)
        #expect(result == nil)
        let recorded = await logs.messages
        #expect(recorded.count == 1)
        #expect(recorded.first?.contains("alt-text proposal failed") == true)
    }

    @Test("defaults to a no-op logger when none is given")
    func defaultLoggerIsNoOp() async {
        struct Boom: Error {}
        let proposer = WYSIWYGAltTextProposer(produce: { _, _ in throw Boom() })
        let result = await proposer.propose(imageURL: imageURL, context: context)
        #expect(result == nil)
    }
}
#endif

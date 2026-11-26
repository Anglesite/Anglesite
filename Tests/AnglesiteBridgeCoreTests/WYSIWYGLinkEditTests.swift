import Testing
import Foundation
@testable import AnglesiteBridgeCore

@Suite("WYSIWYGLinkEdit")
struct WYSIWYGLinkEditTests {
    @Test("decodes beginLinkEdit's reply, with and without an existing link")
    func decodesContext() {
        let reply: [String: Any] = [
            "href": "/old", "text": "world",
            "rect": ["x": NSNumber(value: 10.5), "y": 20, "width": 30.0, "height": 12],
        ]
        #expect(WYSIWYGLinkEdit.Context(jsReply: reply) == .init(
            href: "/old", text: "world", rect: .init(x: 10.5, y: 20, width: 30, height: 12)))

        var noLink = reply
        noLink["href"] = NSNull() // JS null arrives as NSNull
        #expect(WYSIWYGLinkEdit.Context(jsReply: noLink)?.href == nil)
    }

    @Test("JS null, or an unexpected shape, decodes to nil")
    func rejectsOtherReplies() {
        #expect(WYSIWYGLinkEdit.Context(jsReply: nil) == nil)
        #expect(WYSIWYGLinkEdit.Context(jsReply: NSNull()) == nil)
        #expect(WYSIWYGLinkEdit.Context(jsReply: ["text": "x"]) == nil)
        #expect(WYSIWYGLinkEdit.Context(jsReply: ["text": "x", "rect": ["x": "1", "y": 0, "width": 1, "height": 1]]) == nil)
    }

    @Test("only an invalid address keeps the popover open")
    func commitResultClosesPopover() {
        #expect(WYSIWYGLinkEdit.CommitResult(rawValue: "applied")?.closesPopover == true)
        #expect(WYSIWYGLinkEdit.CommitResult(rawValue: "removed")?.closesPopover == true)
        #expect(WYSIWYGLinkEdit.CommitResult(rawValue: "stale")?.closesPopover == true)
        #expect(WYSIWYGLinkEdit.CommitResult(rawValue: "invalid")?.closesPopover == false)
        #expect(WYSIWYGLinkEdit.CommitResult(rawValue: "other") == nil)
    }

    @Test("anchor rect scales by zoom and keeps the page's top-down y in a flipped view")
    func anchorRectFlipped() {
        let rect = WYSIWYGLinkEdit.anchorRect(
            for: .init(x: 10, y: 20, width: 30, height: 12), zoom: 2, viewHeight: 500, isFlipped: true)
        #expect(rect == CGRect(x: 20, y: 40, width: 60, height: 24))
    }

    @Test("anchor rect flips y for a bottom-up view")
    func anchorRectUnflipped() {
        let rect = WYSIWYGLinkEdit.anchorRect(
            for: .init(x: 10, y: 20, width: 30, height: 12), zoom: 1, viewHeight: 500, isFlipped: false)
        #expect(rect == CGRect(x: 10, y: 468, width: 30, height: 12))
    }

    @Test("an empty selection rect still yields something to anchor to")
    func anchorRectMinimumSize() {
        let rect = WYSIWYGLinkEdit.anchorRect(
            for: .init(x: 5, y: 5, width: 0, height: 0), zoom: 1, viewHeight: 100, isFlipped: true)
        #expect(rect.size == CGSize(width: 1, height: 1))
    }
}

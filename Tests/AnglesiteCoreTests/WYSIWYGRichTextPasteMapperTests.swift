import Testing
import Foundation
#if canImport(AppKit)
import AppKit
@testable import AnglesiteCore

@Suite("WYSIWYGRichTextPasteMapper")
struct WYSIWYGRichTextPasteMapperTests {
    @Test("splits multiple paragraphs into separate run lists")
    func splitsParagraphs() {
        let attributed = NSAttributedString(string: "First\nSecond")
        let paragraphs = WYSIWYGRichTextPasteMapper.map(attributed)
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].first?.text == "First")
        #expect(paragraphs[1].first?.text == "Second")
    }

    @Test("maps a bold run to strong and a plain run to text")
    func mapsBoldRun() {
        let attributed = NSMutableAttributedString(string: "bold plain")
        attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 12), range: NSRange(location: 0, length: 4))
        let paragraphs = WYSIWYGRichTextPasteMapper.map(attributed)
        #expect(paragraphs[0].contains { $0.kind == .strong && $0.text == "bold" })
        #expect(paragraphs[0].contains { $0.kind == .text && $0.text == " plain" })
    }

    @Test("maps a link attribute to a link run carrying href")
    func mapsLinkRun() {
        let attributed = NSMutableAttributedString(string: "click here")
        attributed.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 0, length: 10))
        let paragraphs = WYSIWYGRichTextPasteMapper.map(attributed)
        #expect(paragraphs[0].first?.kind == .link)
        #expect(paragraphs[0].first?.href == "https://example.com")
    }

    @Test("plainTextOnly collapses every run to plain text runs (Paste and Match Style)")
    func plainTextOnlyCollapsesFormatting() {
        let attributed = NSMutableAttributedString(string: "bold")
        attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 12), range: NSRange(location: 0, length: 4))
        let paragraphs = WYSIWYGRichTextPasteMapper.map(attributed, plainTextOnly: true)
        #expect(paragraphs[0] == [RichTextRun(kind: .text, text: "bold")])
    }
}
#endif

import Testing
@testable import AnglesiteCore

@Suite("WYSIWYGBlockClipboardWriter")
struct WYSIWYGBlockClipboardWriterTests {
    @Test("renders rich text runs to matching HTML tags and plain text")
    func rendersRichTextRuns() {
        let node = BlockNode(
            id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0],
            richText: [RichTextRun(kind: .text, text: "Hello "), RichTextRun(kind: .strong, text: "world")])

        let (html, plain) = WYSIWYGBlockClipboardWriter.render(node)

        #expect(html == "<p>Hello <strong>world</strong></p>")
        #expect(plain == "Hello world")
    }

    @Test("falls back to componentName for a block with no rich text")
    func fallsBackForNonTextBlock() {
        let node = BlockNode(id: "b1", kind: .astro, componentName: "Callout", props: [:], slots: [:], sourceSpan: [0, 0])

        let (html, plain) = WYSIWYGBlockClipboardWriter.render(node)

        #expect(html == "<div>Callout</div>")
        #expect(plain == "Callout")
    }

    @Test("escapes HTML-significant characters in run text")
    func escapesHTML() {
        let node = BlockNode(
            id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0],
            richText: [RichTextRun(kind: .text, text: "<script>")])

        let (html, _) = WYSIWYGBlockClipboardWriter.render(node)

        #expect(html == "<p>&lt;script&gt;</p>")
    }

    @Test("escapes & before < and > so a literal entity in source text is not double-escaped")
    func escapesAmpersandFirstWithoutDoubleEscaping() {
        let node = BlockNode(
            id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0],
            richText: [RichTextRun(kind: .text, text: "<a & b> &lt;")])

        let (html, plain) = WYSIWYGBlockClipboardWriter.render(node)

        #expect(html == "<p>&lt;a &amp; b&gt; &amp;lt;</p>")
        #expect(plain == "<a & b> &lt;")
    }

    @Test("escapes quotes in a link href so it cannot break out of the attribute")
    func escapesQuotesInLinkHref() {
        let node = BlockNode(
            id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0],
            richText: [RichTextRun(kind: .link, text: "click", href: "https://example.com/a\" onmouseover=\"alert(1)")])

        let (html, _) = WYSIWYGBlockClipboardWriter.render(node)

        #expect(html == "<p><a href=\"https://example.com/a&quot; onmouseover=&quot;alert(1)\">click</a></p>")
        // The only `"` characters left in the output are the two that delimit the href attribute
        // itself — anything from the href's own bytes is escaped, so nothing can close it early.
        #expect(html.filter { $0 == "\"" }.count == 2)
        #expect(!html.contains("onmouseover=\""))
    }

    @Test("escapes quotes and apostrophes in run text")
    func escapesQuotesInRunText() {
        let node = BlockNode(
            id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0],
            richText: [RichTextRun(kind: .text, text: "she said \"hi\" & it's fine")])

        let (html, plain) = WYSIWYGBlockClipboardWriter.render(node)

        #expect(html == "<p>she said &quot;hi&quot; &amp; it&#39;s fine</p>")
        #expect(plain == "she said \"hi\" & it's fine")
    }
}

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
}

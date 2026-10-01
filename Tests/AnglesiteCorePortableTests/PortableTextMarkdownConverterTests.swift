// Lives in the portable target (not AnglesiteCoreTests, where the other SiteImport rung suites
// are) because the converter is pure Foundation and this is the only AnglesiteCore test target
// the Linux CI leg executes — the same reasoning as EmDashNewSiteTests (#2050). The kitchen-sink
// fixture is EmDash's own Portable Text dialect (its `src/content/converters/types.ts`), and the
// golden `.md` beside it pins the exact output.
import Foundation
import Testing
@testable import AnglesiteCore

@Suite("Portable Text → Markdown (#2051)")
struct PortableTextMarkdownConverterTests {
    private static func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/EmDash"))
        return try Data(contentsOf: url)
    }

    private static func blocks(_ json: String) throws -> [JSONValue] {
        let raw = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(JSONValue.from(raw)?.arrayValue)
    }

    /// The site-aware resolver the rung supplies in production: site-relative `asset.url`s join
    /// the origin, and a bare `_ref` goes through the media table.
    private static func resolve(_ asset: PortableTextMarkdownConverter.ImageAsset) -> String? {
        if let url = asset.url {
            return url.hasPrefix("/") ? "https://blog.example" + url : url
        }
        return asset.ref == "media-2" ? "https://blog.example/_emdash/api/media/file/2026/09/dog.jpg" : nil
    }

    @Test("the kitchen-sink document renders byte-for-byte like its golden Markdown")
    func kitchenSinkMatchesGolden() throws {
        let json = try Self.fixture("portable-text-kitchen-sink", "json")
        let golden = try String(decoding: Self.fixture("portable-text-kitchen-sink", "md"), as: UTF8.self)
        let result = try #require(PortableTextMarkdownConverter.convert(
            json: json,
            htmlConversions: ["<p class=\"note\">Converted elsewhere</p>": "Converted elsewhere"],
            resolveImageURL: Self.resolve))

        // The golden file ends with a newline (editors insist); the converter's body doesn't.
        let expected = golden.hasSuffix("\n") ? String(golden.dropLast()) : golden
        if result.markdown != expected {
            let got = result.markdown.split(separator: "\n", omittingEmptySubsequences: false)
            let want = expected.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, pair) in zip(got, want).enumerated() where pair.0 != pair.1 {
                Issue.record("first difference at line \(index + 1):\n  got:  \(pair.0)\n  want: \(pair.1)")
                break
            }
            if got.count != want.count { Issue.record("got \(got.count) lines, want \(want.count)") }
        }
        #expect(result.markdown == expected)
        #expect(result.images == [
            "https://blog.example/_emdash/api/media/file/2026/09/cat.jpg",
            "https://blog.example/_emdash/api/media/file/2026/09/dog.jpg",
            "https://cdn.example.com/a%20b.png",
        ])
        #expect(result.unsupportedBlockTypes == ["callout", "embed"])
    }

    @Test("a wrapped document and a bare array both convert; non-JSON doesn't")
    func inputShapes() throws {
        let bare = Data(#"[{"_type":"block","_key":"a","children":[{"_type":"span","_key":"b","text":"Hi","marks":[]}]}]"#.utf8)
        #expect(PortableTextMarkdownConverter.convert(json: bare)?.markdown == "Hi")
        let wrapped = Data(#"{"blocks":[{"_type":"block","_key":"a","children":[{"_type":"span","_key":"b","text":"Hi","marks":[]}]}]}"#.utf8)
        #expect(PortableTextMarkdownConverter.convert(json: wrapped)?.markdown == "Hi")
        #expect(PortableTextMarkdownConverter.convert(json: Data("not json".utf8)) == nil)
        #expect(PortableTextMarkdownConverter.convert(json: Data(#"{"nope":1}"#.utf8)) == nil)
    }

    @Test("a table without a header row gets an empty header so it stays a table")
    func tableWithoutHeader() throws {
        let blocks = try Self.blocks(#"""
        [{"_type":"table","_key":"t","rows":[
          {"_type":"tableRow","_key":"r1","cells":[
            {"_type":"tableCell","_key":"c1","content":[{"_type":"block","_key":"b","children":[{"_type":"span","_key":"s","text":"a","marks":[]}]}]},
            {"_type":"tableCell","_key":"c2","content":[{"_type":"block","_key":"b","children":[{"_type":"span","_key":"s","text":"b","marks":[]}]}]}]},
          {"_type":"tableRow","_key":"r2","cells":[
            {"_type":"tableCell","_key":"c3","content":[{"_type":"block","_key":"b","children":[{"_type":"span","_key":"s","text":"c","marks":[]}]}]}]}
        ]}]
        """#)
        let result = PortableTextMarkdownConverter.convert(blocks: blocks)
        #expect(result.markdown == "|  |  |\n| --- | --- |\n| a | b |\n| c |  |")
    }

    @Test("an image with neither url nor ref is dropped without being reported")
    func imageWithoutSource() throws {
        let blocks = try Self.blocks(#"[{"_type":"image","_key":"i","asset":{"_ref":""},"alt":"x"}]"#)
        let result = PortableTextMarkdownConverter.convert(blocks: blocks)
        #expect(result.markdown.isEmpty)
        #expect(result.images.isEmpty)
        #expect(result.unsupportedBlockTypes.isEmpty)
    }

    @Test("an htmlBlock is passed through unless a conversion is supplied")
    func htmlBlocks() throws {
        let blocks = try Self.blocks(#"[{"_type":"htmlBlock","_key":"h","html":"<b>raw</b>"},{"_type":"htmlBlock","_key":"h2","html":"<b>raw</b>"},{"_type":"htmlBlock","_key":"h3","html":""}]"#)
        #expect(PortableTextMarkdownConverter.htmlBlocks(in: blocks) == ["<b>raw</b>"])
        #expect(PortableTextMarkdownConverter.convert(blocks: blocks).markdown == "<b>raw</b>\n\n<b>raw</b>")
        #expect(PortableTextMarkdownConverter.convert(blocks: blocks, htmlConversions: ["<b>raw</b>": "**raw**"]).markdown
                == "**raw**\n\n**raw**")
    }

    @Test("inline escaping keeps Markdown syntax characters literal")
    func escaping() {
        #expect(PortableTextMarkdownConverter.escapeInline("a*b_c`d[e]f<g>h\\i~j") == "a\\*b\\_c\\`d\\[e\\]f\\<g>h\\\\i\\~j")
        #expect(PortableTextMarkdownConverter.escapeLineStart("     deep") == "   deep") // never an indented code block
        #expect(PortableTextMarkdownConverter.escapeHeadingTail("Title #") == "Title \\#")
        #expect(PortableTextMarkdownConverter.escapeHeadingTail("Title ##  ") == "Title \\##") // trailing spaces are inert
        #expect(PortableTextMarkdownConverter.escapeHeadingTail("###") == "\\###")
        #expect(PortableTextMarkdownConverter.escapeHeadingTail("C# rocks") == "C# rocks")
        #expect(PortableTextMarkdownConverter.escapeLineStart("# heading") == "\\# heading")
        #expect(PortableTextMarkdownConverter.escapeLineStart("- item") == "\\- item")
        #expect(PortableTextMarkdownConverter.escapeLineStart("12. twelve") == "12\\. twelve")
        #expect(PortableTextMarkdownConverter.escapeLineStart("12) twelve") == "12\\) twelve")
        #expect(PortableTextMarkdownConverter.escapeLineStart("1984 was a year") == "1984 was a year")
        #expect(PortableTextMarkdownConverter.escapeLineStart("3.14 is pi") == "3.14 is pi")
        #expect(PortableTextMarkdownConverter.escapeLineStart("plain") == "plain")
        #expect(PortableTextMarkdownConverter.escapeLineStart("") == "")
        #expect(PortableTextMarkdownConverter.escapeURL("https://x.example/a b(c)") == "https://x.example/a%20b%28c%29")
    }

    @Test("a code span's fence outgrows the backticks inside it")
    func codeSpans() throws {
        let blocks = try Self.blocks(#"[{"_type":"block","_key":"a","children":[{"_type":"span","_key":"b","text":"a``b","marks":["code"]}]}]"#)
        #expect(PortableTextMarkdownConverter.convert(blocks: blocks).markdown == "```a``b```")
    }

    @Test("numbered lists count on from listStart and restart per nesting level")
    func numberedLists() throws {
        func item(_ text: String, level: Int, start: Int? = nil) -> String {
            #"{"_type":"block","_key":"\#(text)","listItem":"number","level":\#(level)\#(start.map { ",\"listStart\":\($0)" } ?? ""),"children":[{"_type":"span","_key":"s","text":"\#(text)","marks":[]}]}"#
        }
        let blocks = try Self.blocks("[\(item("a", level: 1, start: 5)),\(item("b", level: 2)),\(item("c", level: 2)),\(item("d", level: 1)),\(item("e", level: 2))]")
        #expect(PortableTextMarkdownConverter.convert(blocks: blocks).markdown
                == "5. a\n    1. b\n    2. c\n6. d\n    1. e")
    }

    @Test("a hard break inside a list item continues the item")
    func listItemHardBreak() throws {
        let blocks = try Self.blocks(#"[{"_type":"block","_key":"a","listItem":"bullet","level":1,"children":[{"_type":"span","_key":"s","text":"one\ntwo","marks":[]}]}]"#)
        #expect(PortableTextMarkdownConverter.convert(blocks: blocks).markdown == "- one  \n  two")
    }

    // MARK: Review hardening (#2051)

    private static func paragraph(_ text: String, style: String = "normal", listItem: String? = nil) -> String {
        #"{"_type":"block","_key":"k","style":"\#(style)"\#(listItem.map { ",\"listItem\":\"\($0)\",\"level\":1" } ?? ""),"children":[{"_type":"span","_key":"s","text":"\#(text)","marks":[]}]}"#
    }

    @Test("every line of a paragraph, quote or list item is protected from starting a block")
    func escapesEveryLineStart() throws {
        let setext = try Self.blocks("[\(Self.paragraph("Line one\\n==="))]")
        #expect(PortableTextMarkdownConverter.convert(blocks: setext).markdown == "Line one  \n\\===")
        let list = try Self.blocks("[\(Self.paragraph("x\\n- two"))]")
        #expect(PortableTextMarkdownConverter.convert(blocks: list).markdown == "x  \n\\- two")
        let bullet = try Self.blocks("[\(Self.paragraph("- foo\\n# bar", listItem: "bullet"))]")
        #expect(PortableTextMarkdownConverter.convert(blocks: bullet).markdown == "- \\- foo  \n  \\# bar")
        let quote = try Self.blocks("[\(Self.paragraph("Q\\n# x", style: "blockquote"))]")
        #expect(PortableTextMarkdownConverter.convert(blocks: quote).markdown == "> Q\n> \\# x")
        let heading = try Self.blocks("[\(Self.paragraph("Title #", style: "h2"))]")
        #expect(PortableTextMarkdownConverter.convert(blocks: heading).markdown == "## Title \\#")
        let strike = try Self.blocks("[\(Self.paragraph("not ~~gone~~"))]")
        #expect(PortableTextMarkdownConverter.convert(blocks: strike).markdown == "not \\~\\~gone\\~\\~")
    }

    @Test("emphasis closes even when the mark carries edge whitespace, and works mid-word")
    func emphasisDelimiters() throws {
        func span(_ text: String, _ marks: [String] = []) -> String {
            #"{"_type":"span","_key":"s","text":"\#(text)","marks":[\#(marks.map { "\"\($0)\"" }.joined(separator: ","))]}"#
        }
        func block(_ spans: [String]) -> String {
            #"{"_type":"block","_key":"k","style":"normal","children":[\#(spans.joined(separator: ","))]}"#
        }
        let edges = try Self.blocks("[\(block([span("bold ", ["strong"]), span("text"), span(" tail", ["em"])]))]")
        #expect(PortableTextMarkdownConverter.convert(blocks: edges).markdown == "**bold** text *tail*")
        let intraword = try Self.blocks("[\(block([span("a"), span("b", ["em"]), span("c")]))]")
        #expect(PortableTextMarkdownConverter.convert(blocks: intraword).markdown == "a*b*c")
        let onlySpace = try Self.blocks("[\(block([span("x"), span(" ", ["strong"]), span("y")]))]")
        #expect(PortableTextMarkdownConverter.convert(blocks: onlySpace).markdown == "x y")
        let code = try Self.blocks("[\(block([span(" x ", ["code"])]))]")
        #expect(PortableTextMarkdownConverter.convert(blocks: code).markdown == " `x` ")
    }

    @Test("an inline child that isn't a span keeps its text or its JSON, and is reported")
    func inlineNonSpanChildren() throws {
        let blocks = try Self.blocks(#"""
        [{"_type":"block","_key":"k","style":"normal","children":[
          {"_type":"span","_key":"a","text":"Hi ","marks":[]},
          {"_type":"mention","_key":"m","text":"@ada","userId":"u1"},
          {"_type":"span","_key":"b","text":", see ","marks":[]},
          {"_type":"inlineImage","_key":"i","alt":"a diagram","asset":{"_ref":"m9"}},
          {"_type":"footnote","_key":"f","note":[]}
        ]}]
        """#)
        let result = PortableTextMarkdownConverter.convert(blocks: blocks)
        #expect(result.markdown == #"Hi @ada, see a diagram`{"_key":"f","_type":"footnote","note":[]}`"#)
        #expect(result.unsupportedBlockTypes == ["mention", "inlineImage", "footnote"])
    }

    @Test("a pipe inside a table cell's code span is escaped too")
    func tableCellPipes() throws {
        let blocks = try Self.blocks(#"""
        [{"_type":"table","_key":"t","hasHeaderRow":true,"rows":[
          {"_type":"tableRow","_key":"r","cells":[
            {"_type":"tableCell","_key":"c","content":[{"_type":"block","_key":"b","children":[{"_type":"span","_key":"s","text":"a | b","marks":["code"]}]}]}]}]}]
        """#)
        #expect(PortableTextMarkdownConverter.convert(blocks: blocks).markdown == "| `a \\| b` |\n| --- |")
    }
}

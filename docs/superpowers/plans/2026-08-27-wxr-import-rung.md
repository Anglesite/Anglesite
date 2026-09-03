# WXR (WordPress Export) Import Rung Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an owner import a WordPress site from a WXR (`.xml`) export file — for offline
WordPress sites, or ones with the REST API disabled — reusing the existing import pipeline
(`ContentClassifier`, `ImportEmitter`, `AssetLocalizer`, `ImportTransform`) unchanged wherever
possible.

**Architecture:** A new, independent extraction rung (`WXRParser` + `WXRRung`) turns a WXR file
directly into `[ImportItem]`, converting each entry's rendered HTML body through the same
`JS/import-engine` bundle the (not-yet-built) crawl-stage rungs will use for full-content
strings — via a new offscreen-`WKWebView` converter in `AnglesiteApp`, since AnglesiteCore stays
portable and can't import WebKit. Because WXR has no live crawl, a small asset downloader fetches
the images referenced in post bodies directly, and a new `ImportTransform` entry point accepts
already-resolved content instead of a crawled `ImportSnapshot`. A new File-menu command
(`SiteActions.importWXR`) ties it together: pick a `.xml` file, scaffold a fresh site (reusing
`SiteScaffolder`/`NewSiteDraft`, no new scaffolding logic), run the pipeline into it, commit.

**Tech Stack:** Swift 6.4, `Foundation.XMLParser` (no new dependency), WebKit (`WKWebView`,
already a project dependency), Swift Testing (`AnglesiteCoreTests`/`AnglesiteAppTests`).

**Spec:** [`docs/superpowers/specs/2026-08-21-website-import-transform-design.md`](../specs/2026-08-21-website-import-transform-design.md)
(the transform-stage design WXR reuses) and issue [#1636](https://github.com/Anglesite/Anglesite/issues/1636).

## Global Constraints

- Swift 6.4 / Xcode 27+; `AnglesiteCore` changes must stay portable (buildable on Linux via
  `swift test --package-path .` with no WebKit/AppKit import) — new WebKit-dependent code goes in
  `Sources/AnglesiteApp/` (compiled into the Darwin-gated `AnglesiteAppCore` SwiftPM target).
- No new dependency: WXR parsing uses `Foundation.XMLParser`, already available on every target.
- Conventional commits, subject ≤72 characters, reference `#1636`. Don't use `fix(#1636): …`/
  `feat(#1636): …` as a *closing* form on interim commits if this plan's PR won't close the issue
  in one shot — see `CONTRIBUTING.md` ▸ "Commits and pull requests" on the commit-scope/closing-
  keyword collision. The final PR body uses `Closes #1636`.
- Run `swift test --package-path .` and (for the two AnglesiteApp-side tasks) `scripts/build-app.sh
  -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` before the PR —
  `swift test --filter` still compiles the whole package, so a broken unrelated target blocks a
  scoped run too.
- Existing `ImportTransform.run(snapshot:...)` behavior and public signature must not change —
  verified by the existing `SiteImportTransformTests.swift` golden tests continuing to pass
  unmodified.
- Deliberate, documented deviation from issue #1636's own "no changes expected to ContentClassifier,
  ImportEmitter, AssetLocalizer, or ImportTransform": `ImportTransform` gets one new, additive
  overload (Task 4) because its existing entry point hard-codes resolving from a crawled
  `ImportSnapshot`, which WXR has no equivalent of. `ContentClassifier`, `ImportEmitter`, and
  `AssetLocalizer` genuinely stay untouched. Call this out explicitly in the PR body.

---

### Task 1: WXR XML parser

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/WXRDocument.swift`
- Test: `Tests/AnglesiteCoreTests/SiteImportWXRParserTests.swift`

**Interfaces:**
- Produces: `WXREntry` (`title: String?`, `link: String`, `postType: String`, `status: String`,
  `published: Date?`, `contentEncoded: String`, `excerptEncoded: String?`), `WXRChannel`
  (`title: String?`, `link: String?`), `WXRParseError: Error, Equatable` (`message: String`),
  `WXRParser.parse(_ data: Data) throws -> (channel: WXRChannel, entries: [WXREntry])`. Later
  tasks (2, 7) consume these types and this function by name.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportWXRParserTests {
    private static let sample = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <rss version="2.0"
      xmlns:excerpt="http://wordpress.org/export/1.1/excerpt/"
      xmlns:content="http://purl.org/rss/1.0/modules/content/"
      xmlns:wp="http://wordpress.org/export/1.2/">
    <channel>
      <title>Sample Blog</title>
      <link>https://example.com</link>
      <item>
        <title>Hello &amp; Welcome</title>
        <link>https://example.com/2024/05/01/hello/</link>
        <content:encoded><![CDATA[<p>Hello <em>world</em></p>]]></content:encoded>
        <excerpt:encoded><![CDATA[<p>Hello</p>]]></excerpt:encoded>
        <wp:post_date_gmt>2024-05-01 10:00:00</wp:post_date_gmt>
        <pubDate>Wed, 01 May 2024 10:00:00 +0000</pubDate>
        <wp:status>publish</wp:status>
        <wp:post_type>post</wp:post_type>
      </item>
      <item>
        <title>About</title>
        <link>https://example.com/about/</link>
        <content:encoded><![CDATA[<p>About us.</p>]]></content:encoded>
        <excerpt:encoded><![CDATA[]]></excerpt:encoded>
        <wp:post_date_gmt>0000-00-00 00:00:00</wp:post_date_gmt>
        <pubDate>Thu, 02 May 2024 00:00:00 +0000</pubDate>
        <wp:status>publish</wp:status>
        <wp:post_type>page</wp:post_type>
      </item>
      <item>
        <title>A draft</title>
        <link>https://example.com/?p=99</link>
        <content:encoded><![CDATA[<p>Not ready.</p>]]></content:encoded>
        <excerpt:encoded><![CDATA[]]></excerpt:encoded>
        <wp:post_date_gmt>0000-00-00 00:00:00</wp:post_date_gmt>
        <pubDate>Thu, 02 May 2024 00:00:00 +0000</pubDate>
        <wp:status>draft</wp:status>
        <wp:post_type>post</wp:post_type>
      </item>
      <item>
        <title>cat.jpg</title>
        <link>https://example.com/cat-jpg/</link>
        <content:encoded><![CDATA[]]></content:encoded>
        <excerpt:encoded><![CDATA[]]></excerpt:encoded>
        <wp:post_date_gmt>0000-00-00 00:00:00</wp:post_date_gmt>
        <pubDate>Thu, 02 May 2024 00:00:00 +0000</pubDate>
        <wp:status>inherit</wp:status>
        <wp:post_type>attachment</wp:post_type>
      </item>
    </channel>
    </rss>
    """

    @Test func parsesChannelHeader() throws {
        let result = try WXRParser.parse(Data(Self.sample.utf8))
        #expect(result.channel.title == "Sample Blog")
        #expect(result.channel.link == "https://example.com")
    }

    @Test func parsesEveryItemRegardlessOfTypeOrStatus() throws {
        let result = try WXRParser.parse(Data(Self.sample.utf8))
        #expect(result.entries.count == 4)
    }

    @Test func decodesCDATAWrappedContentAndExcerpt() throws {
        let result = try WXRParser.parse(Data(Self.sample.utf8))
        let hello = try #require(result.entries.first { $0.link.hasSuffix("/hello/") })
        #expect(hello.contentEncoded == "<p>Hello <em>world</em></p>")
        #expect(hello.excerptEncoded == "<p>Hello</p>")
        #expect(hello.title == "Hello & Welcome")
        #expect(hello.postType == "post")
        #expect(hello.status == "publish")
    }

    @Test func emptyExcerptBecomesNil() throws {
        let result = try WXRParser.parse(Data(Self.sample.utf8))
        let about = try #require(result.entries.first { $0.link.hasSuffix("/about/") })
        #expect(about.excerptEncoded == nil)
    }

    @Test func prefersPostDateGMTOverPubDate() throws {
        let result = try WXRParser.parse(Data(Self.sample.utf8))
        let hello = try #require(result.entries.first { $0.link.hasSuffix("/hello/") })
        let expected = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
            year: 2024, month: 5, day: 1, hour: 10, minute: 0, second: 0
        ).date!
        #expect(hello.published == expected)
    }

    @Test func fallsBackToPubDateWhenGMTIsTheNeverPublishedSentinel() throws {
        let result = try WXRParser.parse(Data(Self.sample.utf8))
        let about = try #require(result.entries.first { $0.link.hasSuffix("/about/") })
        let expected = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
            year: 2024, month: 5, day: 2, hour: 0, minute: 0, second: 0
        ).date!
        #expect(about.published == expected)
    }

    @Test func draftAndAttachmentEntriesStillParse() throws {
        // WXRParser is pure structural decoding — filtering by status/post_type is WXRRung's job
        // (Task 2), so drafts and attachments still come through here.
        let result = try WXRParser.parse(Data(Self.sample.utf8))
        #expect(result.entries.contains { $0.status == "draft" })
        #expect(result.entries.contains { $0.postType == "attachment" })
    }

    @Test func malformedXMLThrows() {
        #expect(throws: WXRParseError.self) {
            try WXRParser.parse(Data("<rss><channel><item>".utf8))
        }
    }

    @Test func nonWXRXMLThrows() {
        #expect(throws: WXRParseError.self) {
            try WXRParser.parse(Data("<html><body>Not a feed</body></html>".utf8))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter SiteImportWXRParserTests`
Expected: FAIL — `WXRParser`, `WXREntry`, `WXRChannel`, `WXRParseError` don't exist yet.

- [ ] **Step 3: Write the parser**

```swift
import Foundation

/// One `<item>` from a WordPress eXtended RSS (WXR) export — the file WordPress's own "Export"
/// screen and Cloudflare's EmDash Exporter plugin both produce (#1636). `WXRParser` decodes every
/// `<item>` regardless of type or status; filtering to published posts/pages and mapping to
/// ``ImportItem/Hint`` is ``WXRRung``'s job, mirroring how the other rungs keep structural
/// decoding separate from classification.
public struct WXREntry: Sendable, Equatable {
    /// The post/page title (`<title>`), HTML-entity-decoded the same way `WordPressRESTRung`
    /// decodes REST titles.
    public var title: String?
    /// The canonical URL of the post/page (`<link>`).
    public var link: String
    /// WordPress's post type (`<wp:post_type>`): `"post"`, `"page"`, `"attachment"`,
    /// `"nav_menu_item"`, etc.
    public var postType: String
    /// WordPress's publish status (`<wp:status>`): `"publish"`, `"draft"`, `"private"`,
    /// `"trash"`, `"inherit"` (attachments), etc.
    public var status: String
    /// The publish date, parsed from `<wp:post_date_gmt>` (preferred) or `<pubDate>` (fallback)
    /// — `nil` if neither parses. WordPress writes the sentinel `"0000-00-00 00:00:00"` for
    /// `post_date_gmt` on content that was never actually published with a real date.
    public var published: Date?
    /// The rendered post/page body (`<content:encoded>`), unwrapped from its CDATA section.
    public var contentEncoded: String
    /// The rendered excerpt (`<excerpt:encoded>`), unwrapped from its CDATA section — `nil` if
    /// absent or empty.
    public var excerptEncoded: String?

    public init(title: String?, link: String, postType: String, status: String,
                published: Date?, contentEncoded: String, excerptEncoded: String?) {
        self.title = title
        self.link = link
        self.postType = postType
        self.status = status
        self.published = published
        self.contentEncoded = contentEncoded
        self.excerptEncoded = excerptEncoded
    }
}

/// The parsed `<channel>` header of a WXR file: the site-level metadata WordPress's exporter
/// writes once, above the per-item `<item>` elements.
public struct WXRChannel: Sendable, Equatable {
    /// The exporting site's title (`<channel><title>`) — a candidate name for the new package.
    public var title: String?
    /// The exporting site's URL (`<channel><link>`).
    public var link: String?

    public init(title: String?, link: String?) {
        self.title = title
        self.link = link
    }
}

/// A file couldn't be parsed as WXR — malformed XML, or well-formed XML with no `<channel>`
/// (not a WordPress export at all).
public struct WXRParseError: Error, Equatable {
    public var message: String
    public init(message: String) { self.message = message }
}

/// Parses a WordPress eXtended RSS (WXR) export file into its channel header and item entries
/// (#1636). Pure structural decoding over `Foundation.XMLParser` — no XML library dependency,
/// portable to the Linux `AnglesiteCore` target.
public enum WXRParser {
    /// Parses `data` as a WXR document.
    /// - Parameter data: The raw bytes of the `.xml` export file.
    /// - Returns: The channel header and every `<item>`, in document order.
    /// - Throws: ``WXRParseError`` if the data isn't well-formed XML, or has no `<channel>`.
    public static func parse(_ data: Data) throws -> (channel: WXRChannel, entries: [WXREntry]) {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let underlying = delegate.parseError ?? parser.parserError
            throw WXRParseError(message: underlying?.localizedDescription ?? "Malformed XML")
        }
        guard delegate.sawChannel else {
            throw WXRParseError(message: "No <channel> element — this doesn't look like a WXR export")
        }
        return (delegate.channel, delegate.entries)
    }

    /// SQL-datetime format WordPress writes `<wp:post_date_gmt>` in, e.g. `"2024-05-01 10:00:00"`
    /// — always UTC, no timezone marker in the text itself.
    private static let gmtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// RFC 822 format `<pubDate>` is written in, e.g. `"Wed, 01 May 2024 10:00:00 +0000"`.
    private static let rfc822Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Parses `gmtText`/`pubDateText` in that preference order, treating WordPress's
    /// never-published sentinel (`"0000-00-00 00:00:00"`) as absent.
    fileprivate static func published(gmtText: String?, pubDateText: String?) -> Date? {
        if let gmtText, gmtText != "0000-00-00 00:00:00", let date = gmtFormatter.date(from: gmtText) {
            return date
        }
        if let pubDateText, let date = rfc822Formatter.date(from: pubDateText) {
            return date
        }
        return nil
    }

    /// `XMLParserDelegate` accumulator. WXR's `<content:encoded>`/`<excerpt:encoded>` fields
    /// arrive CDATA-wrapped, which `Foundation.XMLParser` only delivers via `foundCDATA` — NOT
    /// `foundCharacters` — so both must feed the same buffer or every CDATA-wrapped field would
    /// silently come back empty. Matches elements by (tag, immediate parent) rather than tracking
    /// an ad hoc "inside item" flag, so a channel-level `<title>`/`<link>` never collides with an
    /// item's, and neither collides with an RSS `<image>` block's own nested `<title>`/`<link>`.
    private final class Delegate: NSObject, XMLParserDelegate {
        var channel = WXRChannel(title: nil, link: nil)
        var sawChannel = false
        var entries: [WXREntry] = []
        var parseError: Error?

        private var path: [String] = []
        private var buffer = ""
        private var current: (title: String?, link: String?, postType: String?, status: String?,
                              gmt: String?, pubDate: String?, content: String, excerpt: String)?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                   qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            path.append(elementName)
            buffer = ""
            if elementName == "channel" { sawChannel = true }
            if elementName == "item" { current = (nil, nil, nil, nil, nil, nil, "", "") }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            buffer += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                   qualifiedName qName: String?) {
            defer { path.removeLast() }
            let parent = path.dropLast().last
            switch (elementName, parent) {
            case ("title", "channel"): channel.title = buffer
            case ("link", "channel"): channel.link = buffer
            case ("title", "item"): current?.title = buffer
            case ("link", "item"): current?.link = buffer
            case ("wp:post_type", "item"): current?.postType = buffer
            case ("wp:status", "item"): current?.status = buffer
            case ("pubDate", "item"): current?.pubDate = buffer
            case ("wp:post_date_gmt", "item"): current?.gmt = buffer
            case ("content:encoded", "item"): current?.content = buffer
            case ("excerpt:encoded", "item"): current?.excerpt = buffer
            case ("item", _):
                if let c = current, let link = c.link, !link.isEmpty,
                   let postType = c.postType, let status = c.status {
                    entries.append(WXREntry(
                        title: c.title.map(decodeHTMLEntities), link: link, postType: postType,
                        status: status,
                        published: WXRParser.published(gmtText: c.gmt, pubDateText: c.pubDate),
                        contentEncoded: c.content,
                        excerptEncoded: (c.excerpt.isEmpty ? nil : c.excerpt)))
                }
                current = nil
            default: break
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            self.parseError = parseError
        }
    }
}
```

`decodeHTMLEntities` is the free function already defined (and used across the module) in
`WordPressRESTRung.swift` — no import needed, same target.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter SiteImportWXRParserTests`
Expected: PASS (all 9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/WXRDocument.swift Tests/AnglesiteCoreTests/SiteImportWXRParserTests.swift
git commit -m "feat(#1636): parse WXR exports into structured entries"
```

---

### Task 2: `ImportHTMLConverter` protocol + `WXRRung`

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/WXRRung.swift`
- Modify: `Sources/AnglesiteCore/SiteImport/ImportItem.swift:20-25` (add `.wxr` rung case)
- Test: `Tests/AnglesiteCoreTests/SiteImportWXRRungTests.swift`

**Interfaces:**
- Consumes: `WXREntry`, `WXRParser` (Task 1); `ImportItem`, `ImportItem.Rung`, `ImportItem.Hint`,
  `ImportProblem`, `ImportSnapshot.normalizeURL(_:)`, `decodeHTMLEntities(_:)` (all existing).
- Produces: `public protocol ImportHTMLConverter: Sendable { func convert(html: String) async ->
  (markdown: String, images: [String]) }` — Task 5's `OffscreenHTMLConverter` conforms to this;
  `WXRRungTests` below uses a fake. `WXRRung.items(from entries: [WXREntry], convert: any
  ImportHTMLConverter) async -> (items: [ImportItem], problems: [ImportProblem])` — Task 7
  calls this by name.

- [ ] **Step 1: Add the `.wxr` rung case**

In `Sources/AnglesiteCore/SiteImport/ImportItem.swift`, extend the existing enum:

```swift
    public enum Rung: String, Codable, Sendable {
        case wpREST = "wp-rest"
        case feed
        case microformats
        case readability
        case wxr
    }
```

(No other file has an exhaustive `switch` over `ImportItem.Rung` — verified via
`grep -rn "case \.wpREST\|case \.feed\b\|case \.microformats\b\|case \.readability\b" Sources/`
returning only `WordPressRESTRung.swift`'s own non-exhaustive usage — so this is a safe,
source-compatible addition.)

- [ ] **Step 2: Write the failing tests**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportWXRRungTests {
    /// Returns fixed Markdown/images for every call, recording what it was asked to convert —
    /// stands in for `OffscreenHTMLConverter` (Task 5, which needs a real `WKWebView`).
    private final class FakeConverter: ImportHTMLConverter, @unchecked Sendable {
        var responses: [String: (markdown: String, images: [String])] = [:]
        private(set) var converted: [String] = []

        func convert(html: String) async -> (markdown: String, images: [String]) {
            converted.append(html)
            return responses[html] ?? ("", [])
        }
    }

    private func entry(title: String? = "Hello", link: String = "https://example.com/hello/",
                       postType: String = "post", status: String = "publish",
                       content: String = "<p>Hi</p>", excerpt: String? = nil) -> WXREntry {
        WXREntry(title: title, link: link, postType: postType, status: status,
                 published: Date(timeIntervalSince1970: 1_700_000_000),
                 contentEncoded: content, excerptEncoded: excerpt)
    }

    @Test func convertsPostContentToAnImportItem() async {
        let converter = FakeConverter()
        converter.responses["<p>Hi</p>"] = ("Hi", ["https://example.com/cat.jpg"])
        let (items, problems) = await WXRRung.items(from: [entry()], convert: converter)

        #expect(problems.isEmpty)
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.sourceURL == "https://example.com/hello")
        #expect(item.title == "Hello")
        #expect(item.markdown == "Hi")
        #expect(item.images == ["https://example.com/cat.jpg"])
        #expect(item.rung == .wxr)
        #expect(item.hint == .wpPost)
        #expect(item.published == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func postTypePageGetsPageHint() async {
        let converter = FakeConverter()
        converter.responses["<p>About us</p>"] = ("About us", [])
        let (items, _) = await WXRRung.items(
            from: [entry(link: "https://example.com/about/", postType: "page", content: "<p>About us</p>")],
            convert: converter)
        #expect(items.first?.hint == .wpPage)
    }

    @Test func nonPublishedStatusIsSkipped() async {
        let converter = FakeConverter()
        let (items, problems) = await WXRRung.items(
            from: [entry(status: "draft"), entry(status: "trash", link: "https://example.com/t/")],
            convert: converter)
        #expect(items.isEmpty)
        #expect(problems.isEmpty)
        #expect(converter.converted.isEmpty) // never even asked to convert skipped content
    }

    @Test func nonPostPageTypeIsSkipped() async {
        let converter = FakeConverter()
        let (items, _) = await WXRRung.items(
            from: [entry(postType: "attachment"), entry(postType: "nav_menu_item", link: "https://example.com/n/")],
            convert: converter)
        #expect(items.isEmpty)
    }

    @Test func emptyConvertedMarkdownBecomesAProblemNotAnItem() async {
        let converter = FakeConverter() // no response registered → ("", [])
        let (items, problems) = await WXRRung.items(from: [entry()], convert: converter)
        #expect(items.isEmpty)
        #expect(problems.count == 1)
        #expect(problems.first?.sourceURL == "https://example.com/hello/")
    }

    @Test func excerptIsConvertedSeparatelyWhenPresent() async {
        let converter = FakeConverter()
        converter.responses["<p>Hi</p>"] = ("Hi", [])
        converter.responses["<p>Short</p>"] = ("Short", [])
        let (items, _) = await WXRRung.items(from: [entry(excerpt: "<p>Short</p>")], convert: converter)
        #expect(items.first?.excerpt == "Short")
        #expect(converter.converted == ["<p>Hi</p>", "<p>Short</p>"])
    }

    @Test func titleIsHTMLEntityDecoded() async {
        let converter = FakeConverter()
        converter.responses["<p>Hi</p>"] = ("Hi", [])
        let (items, _) = await WXRRung.items(from: [entry(title: "Tom &amp; Jerry")], convert: converter)
        #expect(items.first?.title == "Tom & Jerry")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --package-path . --filter SiteImportWXRRungTests`
Expected: FAIL — `ImportHTMLConverter`/`WXRRung` don't exist yet (and `.wxr` from Step 1 should
already compile cleanly on its own).

- [ ] **Step 4: Write `WXRRung.swift`**

```swift
import Foundation

/// Converts a fragment of rendered HTML into Markdown, extracting the image URLs it references.
/// The seam between the pure-Swift `SiteImport` pipeline and the platform-specific engine that
/// actually runs `JS/import-engine` — AnglesiteCore stays portable (no WebKit), so a concrete
/// conformance lives in `AnglesiteApp` (``OffscreenHTMLConverter``, offscreen `WKWebView`).
///
/// Implementations must never throw: a conversion failure should surface as empty output
/// (`("", [])`) so callers (``WXRRung``) can turn it into a recorded ``ImportProblem`` instead of
/// aborting the whole import — the same "never abort the run" convention every other stage in
/// this pipeline follows.
public protocol ImportHTMLConverter: Sendable {
    func convert(html: String) async -> (markdown: String, images: [String])
}

/// The WXR extraction rung: turns parsed WXR entries into ``ImportItem``s (#1636).
///
/// Unlike every other rung, WXR has no crawled ``ImportSnapshot`` to read from — it's a one-shot
/// file, not a live probe — so this doesn't fit the `items(from snapshot:)` shape the other rungs
/// share. It converts each entry's own `content:encoded`/`excerpt:encoded` HTML directly via the
/// injected ``ImportHTMLConverter``, the same "one converter for every ladder rung" approach the
/// transform-stage design doc specifies for WP REST/feed bodies that arrive as HTML strings.
public enum WXRRung {
    /// Extracts import items from parsed WXR entries.
    ///
    /// Filters to `wp:status == "publish"` and `wp:post_type` of `"post"`/`"page"` — every other
    /// status (draft, trash, private, …) or type (attachment, nav_menu_item, …) is silently
    /// skipped without even being converted, matching how a WordPress site itself never serves
    /// that content publicly. `post` maps to ``ImportItem/Hint/wpPost``, `page` to
    /// ``ImportItem/Hint/wpPage`` — the same hints ``WordPressRESTRung`` produces, so
    /// ``ContentClassifier`` needs no WXR-specific rule.
    ///
    /// - Parameters:
    ///   - entries: The parsed WXR entries (``WXRParser/parse(_:)``).
    ///   - convert: Converts a body's rendered HTML to Markdown + referenced image URLs.
    /// - Returns: One ``ImportItem`` per published post/page whose body converted to non-empty
    ///   Markdown, and one ``ImportProblem`` per entry that didn't (empty/failed conversion).
    public static func items(from entries: [WXREntry], convert: any ImportHTMLConverter) async
        -> (items: [ImportItem], problems: [ImportProblem]) {
        var items: [ImportItem] = []
        var problems: [ImportProblem] = []

        for entry in entries {
            guard entry.status == "publish" else { continue }
            let hint: ImportItem.Hint
            switch entry.postType {
            case "post": hint = .wpPost
            case "page": hint = .wpPage
            default: continue
            }

            let converted = await convert.convert(html: entry.contentEncoded)
            guard !converted.markdown.isEmpty else {
                problems.append(ImportProblem(sourceURL: entry.link,
                                              message: "Could not convert this entry's content to Markdown"))
                continue
            }

            var excerpt: String?
            if let excerptHTML = entry.excerptEncoded, !excerptHTML.isEmpty {
                let convertedExcerpt = await convert.convert(html: excerptHTML)
                excerpt = convertedExcerpt.markdown.isEmpty ? nil : convertedExcerpt.markdown
            }

            items.append(ImportItem(
                sourceURL: ImportSnapshot.normalizeURL(entry.link),
                title: entry.title, published: entry.published, markdown: converted.markdown,
                excerpt: excerpt, images: converted.images, rung: .wxr, hint: hint))
        }

        return (items, problems)
    }
}
```

(`entry.title` is already HTML-entity-decoded by `WXRParser` in Task 1 — no double-decode here.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path . --filter SiteImportWXRRungTests`
Expected: PASS (7 tests).

- [ ] **Step 6: Run the full AnglesiteCore suite to confirm the new `.wxr` case broke nothing**

Run: `swift test --package-path . --filter AnglesiteCoreTests`
Expected: PASS, same as before this task.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/WXRRung.swift Sources/AnglesiteCore/SiteImport/ImportItem.swift Tests/AnglesiteCoreTests/SiteImportWXRRungTests.swift
git commit -m "feat(#1636): map WXR entries to import items"
```

---

### Task 3: `WXRAssetDownloader`

**Files:**
- Create: `Sources/AnglesiteCore/SiteImport/WXRAssetDownloader.swift`
- Test: `Tests/AnglesiteCoreTests/SiteImportWXRAssetDownloaderTests.swift`

**Interfaces:**
- Consumes: `CapturedAsset`, `ImportProblem` (existing).
- Produces: `public struct WXRAssetDownloader: Sendable { init(session: URLSession? = nil);
  func download(imageURLs: [String], into directory: URL) async -> (assets: [CapturedAsset],
  problems: [ImportProblem]) }`. Task 7 calls this by name.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct SiteImportWXRAssetDownloaderTests {
    private final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responses: [String: (status: Int, data: Data)] = [:]

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let key = request.url!.absoluteString
            guard let stub = Self.responses[key] else {
                client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wxr-assets-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    @Test func downloadsEachURLIntoTheDirectory() async throws {
        StubURLProtocol.responses = ["https://example.com/a.jpg": (200, Data("A".utf8))]
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = WXRAssetDownloader(session: makeSession())

        let result = await downloader.download(imageURLs: ["https://example.com/a.jpg"], into: dir)
        #expect(result.problems.isEmpty)
        #expect(result.assets.count == 1)
        #expect(result.assets[0].sourceURL == "https://example.com/a.jpg")
        let bytes = try Data(contentsOf: dir.appendingPathComponent(result.assets[0].relativePath))
        #expect(bytes == Data("A".utf8))
    }

    @Test func duplicateURLsAreDownloadedOnce() async throws {
        StubURLProtocol.responses = ["https://example.com/a.jpg": (200, Data("A".utf8))]
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = WXRAssetDownloader(session: makeSession())

        let result = await downloader.download(
            imageURLs: ["https://example.com/a.jpg", "https://example.com/a.jpg"], into: dir)
        #expect(result.assets.count == 1)
    }

    @Test func nonHTTPStatusBecomesAProblemNotAnAsset() async throws {
        StubURLProtocol.responses = ["https://example.com/missing.jpg": (404, Data())]
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = WXRAssetDownloader(session: makeSession())

        let result = await downloader.download(imageURLs: ["https://example.com/missing.jpg"], into: dir)
        #expect(result.assets.isEmpty)
        #expect(result.problems.count == 1)
    }

    @Test func nonHTTPSchemeIsRefusedWithoutAnyRequest() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = WXRAssetDownloader(session: makeSession())

        let result = await downloader.download(imageURLs: ["file:///etc/passwd"], into: dir)
        #expect(result.assets.isEmpty)
        #expect(result.problems.count == 1)
    }

    @Test func literalPrivateAndLoopbackAddressesAreRefused() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = WXRAssetDownloader(session: makeSession())

        for url in ["http://127.0.0.1/x.jpg", "http://10.0.0.5/x.jpg", "http://192.168.1.1/x.jpg",
                    "http://172.16.0.1/x.jpg", "http://169.254.169.254/x.jpg", "http://localhost/x.jpg"] {
            let result = await downloader.download(imageURLs: [url], into: dir)
            #expect(result.assets.isEmpty, "\(url) should have been refused")
            #expect(result.problems.count == 1, "\(url) should have produced one problem")
        }
    }

    @Test func publicIPLiteralIsAllowedThrough() async throws {
        StubURLProtocol.responses = ["http://93.184.216.34/x.jpg": (200, Data("X".utf8))]
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = WXRAssetDownloader(session: makeSession())

        let result = await downloader.download(imageURLs: ["http://93.184.216.34/x.jpg"], into: dir)
        #expect(result.assets.count == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter SiteImportWXRAssetDownloaderTests`
Expected: FAIL — `WXRAssetDownloader` doesn't exist yet.

- [ ] **Step 3: Write `WXRAssetDownloader.swift`**

```swift
import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// (AnglesiteCore is in the Linux portable target set — see LinkMetadataFetcher.swift).
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads the remote images a WXR import's post/page content references (#1636).
///
/// Every other rung's images already have their bytes on disk because a live crawl fetched them
/// during capture — WXR is a one-shot file with no crawl, so nothing has fetched anything yet.
/// This writes raw bytes to disk and returns ``CapturedAsset`` records in exactly the shape
/// ``AssetLocalizer/localize(markdown:imageURLs:itemSlug:snapshot:snapshotDirectory:siteDirectory:)``
/// already consumes, so format-sniffing/size-cap validation stays in that one place instead of
/// being duplicated here — this only fetches and writes.
public struct WXRAssetDownloader: Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            // Ephemeral: no cookies, no credentials, no cache — a one-off fetch of images
            // referenced by an imported file, not a browsing session.
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
    }

    /// Downloads every URL in `imageURLs` into `directory`, skipping exact duplicates.
    ///
    /// Refuses any URL whose scheme isn't `http`/`https`, or whose host is a literal
    /// loopback/private/link-local address or `localhost`. A WXR file is a local, owner-picked
    /// artifact rather than something crawled from an untrusted remote site, but a tampered one
    /// could still reference an internal address to probe the machine's own network — and unlike
    /// the (not yet built) live-crawl rungs, there's no earlier network-gating step here to have
    /// already caught that. This is a narrower check than the crawl-stage design's planned
    /// DNS-resolution-based guard (`scripts/embeds/net-guard.ts`'s Swift port) — it only rejects
    /// the address appearing as a literal IP in the URL itself, not a hostname that *resolves* to
    /// one — which is why it belongs here rather than claiming to replace that guard.
    ///
    /// - Parameters:
    ///   - imageURLs: The image URLs to fetch, in any order; duplicates are downloaded once.
    ///   - directory: Where to write each successfully downloaded file — created if missing.
    /// - Returns: One ``CapturedAsset`` per successful download (`relativePath` is relative to
    ///   `directory`), and one ``ImportProblem`` per URL that was refused or failed to download.
    public func download(imageURLs: [String], into directory: URL) async
        -> (assets: [CapturedAsset], problems: [ImportProblem]) {
        var assets: [CapturedAsset] = []
        var problems: [ImportProblem] = []
        var seen: Set<String> = []
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (index, url) in imageURLs.enumerated() {
            guard seen.insert(url).inserted else { continue }

            guard let parsed = URL(string: url), Self.isSafe(parsed) else {
                problems.append(ImportProblem(sourceURL: url,
                                              message: "Image URL was refused (unsafe scheme or address)"))
                continue
            }

            do {
                let (data, response) = try await session.data(for: URLRequest(url: parsed))
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    problems.append(ImportProblem(sourceURL: url, message: "Image download failed"))
                    continue
                }
                let relativePath = "image-\(index).bin"
                try data.write(to: directory.appendingPathComponent(relativePath))
                assets.append(CapturedAsset(sourceURL: url, relativePath: relativePath))
            } catch {
                problems.append(ImportProblem(sourceURL: url,
                                              message: "Image download failed: \(error.localizedDescription)"))
            }
        }

        return (assets, problems)
    }

    /// `true` when `url` is safe to fetch: `http`/`https` scheme, and a host that isn't
    /// `localhost` or a literal loopback/private/link-local IPv4 or IPv6 address.
    static func isSafe(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return !isPrivateOrLoopbackLiteral(host)
    }

    private static func isPrivateOrLoopbackLiteral(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" { return true }

        let octets = lowered.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            if octets[0] == 127 { return true }                            // 127.0.0.0/8 loopback
            if octets[0] == 10 { return true }                             // 10.0.0.0/8
            if octets[0] == 192 && octets[1] == 168 { return true }        // 192.168.0.0/16
            if octets[0] == 172 && (16...31).contains(octets[1]) { return true } // 172.16.0.0/12
            if octets[0] == 169 && octets[1] == 254 { return true }        // 169.254.0.0/16 link-local
            if octets[0] == 0 { return true }                              // 0.0.0.0/8
            return false
        }

        if lowered == "::1" { return true }                                // IPv6 loopback
        if lowered.hasPrefix("fe80:") { return true }                      // IPv6 link-local
        if lowered.hasPrefix("fc") || lowered.hasPrefix("fd") { return true } // IPv6 unique local
        return false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter SiteImportWXRAssetDownloaderTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/WXRAssetDownloader.swift Tests/AnglesiteCoreTests/SiteImportWXRAssetDownloaderTests.swift
git commit -m "feat(#1636): download images referenced by WXR content"
```

---

### Task 4: `ImportTransform` entry point for already-resolved content

**Files:**
- Modify: `Sources/AnglesiteCore/SiteImport/ImportTransform.swift`
- Modify (test): `Tests/AnglesiteCoreTests/SiteImportTransformTests.swift`

**Interfaces:**
- Consumes: `ResolvedContent`, `CapturedAsset`, `ImportSnapshot` (existing).
- Produces: `public static func run(resolved: ResolvedContent, assets: [CapturedAsset],
  assetsDirectory: URL, sourceDirectory: URL, configDirectory: URL, now: Date, onStep: @Sendable
  (ImportStep) -> Void) throws -> ImportReport` — Task 7 calls this by name. The existing
  `run(snapshot:...)` keeps its exact signature and behavior.

- [ ] **Step 1: Write the failing test**

Append to `Tests/AnglesiteCoreTests/SiteImportTransformTests.swift` (inside the existing
`SiteImportTransformTests` suite, after `wpSiteGoldenRun`):

```swift
    @Test func runFromResolvedContentSkipsSourceResolution() throws {
        let item = ImportItem(sourceURL: "https://example.com/hello", title: "Hello",
                              published: Date(timeIntervalSince1970: 1_700_000_000),
                              markdown: "Hi there.", images: ["https://example.com/cat.jpg"],
                              rung: .wxr, hint: .wpPost)
        let resolved = ResolvedContent(items: [item], homepage: nil, skippedURLs: [], problems: [])

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let assetsDirectory = work.appendingPathComponent("assets", isDirectory: true)
        let source = work.appendingPathComponent("Source", isDirectory: true)
        let config = work.appendingPathComponent("Config", isDirectory: true)
        for directory in [assetsDirectory, source, config] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: work) }
        try Self.pngBytes.write(to: assetsDirectory.appendingPathComponent("cat.png"))
        let assets = [CapturedAsset(sourceURL: "https://example.com/cat.jpg", relativePath: "cat.png")]

        var steps: [ImportStep] = []
        let report = try ImportTransform.run(
            resolved: resolved, assets: assets, assetsDirectory: assetsDirectory,
            sourceDirectory: source, configDirectory: config,
            now: Date(timeIntervalSince1970: 1_700_000_000), onStep: { steps.append($0) })

        // No `.resolvingContent` step — there's nothing to resolve, this content already is.
        #expect(steps.first == .classifying(itemCount: 1))
        #expect(report.writeProblems.isEmpty)
        #expect(report.writtenPaths == ["src/content/blog/hello.md"])
        #expect(report.installedImagePaths == ["public/images/hello-1.png"])
        #expect(try ImportReport.load(from: config) == report)
    }

    @Test func runFromResolvedContentThrowsOnMissingSourceDirectory() {
        let resolved = ResolvedContent(items: [], homepage: nil, skippedURLs: [], problems: [])
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: ImportTransformError.sourceDirectoryMissing(missing.path)) {
            try ImportTransform.run(
                resolved: resolved, assets: [], assetsDirectory: missing,
                sourceDirectory: missing, configDirectory: missing,
                now: Date(), onStep: { _ in })
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter SiteImportTransformTests`
Expected: FAIL — no `run(resolved:assets:assetsDirectory:...)` overload exists yet (existing
tests in this file should still pass).

- [ ] **Step 3: Refactor `ImportTransform.run` into a shared body + the new overload**

Replace the existing `public static func run(snapshot:...)` in `ImportTransform.swift` (lines
83–124) with:

```swift
    @discardableResult
    public static func run(
        snapshot: ImportSnapshot, snapshotDirectory: URL,
        sourceDirectory: URL, configDirectory: URL,
        now: Date, onStep: @Sendable (ImportStep) -> Void
    ) throws -> ImportReport {
        try preflight(sourceDirectory: sourceDirectory)
        onStep(.resolvingContent)
        let resolved = ImportSourceResolver.resolve(snapshot)
        return try runResolved(resolved, assetSnapshot: snapshot, snapshotDirectory: snapshotDirectory,
                               sourceDirectory: sourceDirectory, configDirectory: configDirectory,
                               now: now, onStep: onStep)
    }

    /// Runs the transform from already-resolved content, skipping ``ImportSourceResolver`` (#1636).
    ///
    /// For sources that build their own ``ImportItem``s directly rather than through a crawled
    /// ``ImportSnapshot`` — the WXR rung has no live crawl to resolve against, since it reads a
    /// one-shot export file instead. `assets`/`assetsDirectory` stand in for a crawl snapshot's
    /// asset inventory purely so ``AssetLocalizer`` needs no changes: it only ever reads
    /// `snapshot.asset(forURL:)` and `snapshotDirectory`, never a snapshot's `pages` or `probes`,
    /// so a snapshot built from just `assets` satisfies it completely.
    ///
    /// - Parameters:
    ///   - resolved: The already-resolved, already-deduplicated content to classify and write.
    ///   - assets: Downloaded asset records for every image `resolved`'s items reference (see
    ///     ``WXRAssetDownloader``).
    ///   - assetsDirectory: The directory `assets`' `relativePath`s are relative to.
    ///   - sourceDirectory: The destination site's `Source/` directory. Must already exist.
    ///   - configDirectory: The destination site's `Config/` directory.
    ///   - now: The deterministic fallback clock (see the `snapshot:` overload's doc comment).
    ///   - onStep: Called synchronously with each ``ImportStep`` as the run progresses. Never
    ///     receives `.resolvingContent` — there is nothing to resolve.
    /// - Returns: The completed, already-saved ``ImportReport``.
    /// - Throws: ``ImportTransformError/sourceDirectoryMissing(_:)`` if `sourceDirectory` doesn't
    ///   exist, or any error `ImportReport.save(to:)` raises persisting the final report.
    @discardableResult
    public static func run(
        resolved: ResolvedContent, assets: [CapturedAsset], assetsDirectory: URL,
        sourceDirectory: URL, configDirectory: URL,
        now: Date, onStep: @Sendable (ImportStep) -> Void
    ) throws -> ImportReport {
        try preflight(sourceDirectory: sourceDirectory)
        let assetSnapshot = ImportSnapshot(siteURL: "", probes: SiteProbes(), pages: [],
                                           assets: assets, conversions: [:])
        return try runResolved(resolved, assetSnapshot: assetSnapshot, snapshotDirectory: assetsDirectory,
                               sourceDirectory: sourceDirectory, configDirectory: configDirectory,
                               now: now, onStep: onStep)
    }

    /// Verifies `sourceDirectory` exists — shared precondition for both `run` overloads above.
    private static func preflight(sourceDirectory: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw ImportTransformError.sourceDirectoryMissing(sourceDirectory.path)
        }
    }

    /// The shared body of both `run` overloads: classify → write content/images → redirects →
    /// seed config → save report. `assetSnapshot`/`snapshotDirectory` are only ever read by
    /// ``AssetLocalizer`` inside `writeContent`.
    @discardableResult
    private static func runResolved(
        _ resolved: ResolvedContent, assetSnapshot: ImportSnapshot, snapshotDirectory: URL,
        sourceDirectory: URL, configDirectory: URL,
        now: Date, onStep: @Sendable (ImportStep) -> Void
    ) throws -> ImportReport {
        onStep(.classifying(itemCount: resolved.items.count))
        let classified = ContentClassifier.classify(resolved, now: now)

        var writeProblems: [ImportProblem] = []
        let (writtenPaths, installedImagePaths) = writeContent(
            classified, snapshot: assetSnapshot, snapshotDirectory: snapshotDirectory,
            sourceDirectory: sourceDirectory, now: now,
            writeProblems: &writeProblems, onStep: onStep)

        let redirectEntries = RedirectsEmitter.entries(for: classified)
        onStep(.writingRedirects(count: redirectEntries.count))
        writeRedirects(redirectEntries, sourceDirectory: sourceDirectory,
                       writeProblems: &writeProblems, onStep: onStep)

        let seeds = ImportSiteConfig.seeds(fromHomepage: resolved.homepage)
        onStep(.seedingConfig)
        writeSiteConfig(seeds, sourceDirectory: sourceDirectory,
                        writeProblems: &writeProblems, onStep: onStep)

        let plan = ImportPlanBuilder.plan(resolved: resolved, classified: classified, seeds: seeds)
        let report = ImportReport(plan: plan, writtenPaths: writtenPaths,
                                  installedImagePaths: installedImagePaths,
                                  redirects: redirectEntries, writeProblems: writeProblems)

        onStep(.savingReport)
        try report.save(to: configDirectory)
        return report
    }
```

Leave `writeContent`, `writeRedirects`, `writeSiteConfig`, and `itemSlug(for:)` exactly as they
are — only the two top-level `run` entry points and the new `preflight`/`runResolved` helpers
change.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter SiteImportTransformTests`
Expected: PASS — both new tests, and every pre-existing test in this file (the `snapshot:`
overload's behavior must be byte-for-byte unchanged).

- [ ] **Step 5: Run the full AnglesiteCore suite**

Run: `swift test --package-path .`
Expected: PASS, no regressions anywhere else in the package.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/SiteImport/ImportTransform.swift Tests/AnglesiteCoreTests/SiteImportTransformTests.swift
git commit -m "feat(#1636): let ImportTransform run from pre-resolved content"
```

---

### Task 5: `OffscreenHTMLConverter` (WKWebView-backed `ImportHTMLConverter`)

**Files:**
- Create: `Sources/AnglesiteApp/OffscreenHTMLConverter.swift`
- Test: `Tests/AnglesiteAppTests/OffscreenHTMLConverterTests.swift`

**Interfaces:**
- Consumes: `ImportHTMLConverter` (Task 2); `ExtractionRecord` (existing, in
  `ImportSnapshot.swift`); `Resources/ImportEngine/import-engine.js` (already built by
  `scripts/build-import-engine.sh`, wired into the Xcode target via `project.yml`).
- Produces: `@MainActor final class OffscreenHTMLConverter: NSObject, ImportHTMLConverter,
  WKNavigationDelegate` — Task 7 constructs and passes this to `WXRRung.items(from:convert:)`.

This task's actual `loadHTMLString`/`evaluateJavaScript` round-trip needs a real `WKWebView` and
so isn't exercised by `swift test` — split the document-shell and script-string construction into
pure `static` functions (mirroring `WYSIWYGCanvasController.mountScript(for:)`'s own split, which
exists for exactly this reason) so those pieces are still unit-tested, and verify the live
round-trip with a manual smoke test in the final step of Task 7.

- [ ] **Step 1: Write the failing tests for the pure helpers**

```swift
import Foundation
import Testing
@testable import AnglesiteAppCore

@Suite("OffscreenHTMLConverter")
struct OffscreenHTMLConverterTests {
    @Test func wrapsAFragmentInAMinimalDocumentShell() {
        let wrapped = OffscreenHTMLConverter.wrap("<p>Hi</p>")
        #expect(wrapped == "<!doctype html><html><body><p>Hi</p></body></html>")
    }

    @Test func wrapsAnEmptyFragmentWithoutCrashing() {
        #expect(OffscreenHTMLConverter.wrap("") == "<!doctype html><html><body></body></html>")
    }

    @Test func extractScriptCallsTheInjectedGlobalWithAFallback() {
        // `?? ""` matters: before the injected script has run (e.g. a load that errored), the
        // global is undefined, and evaluateJavaScript must still resolve to a string, not throw.
        #expect(OffscreenHTMLConverter.extractScript.contains("__anglesiteImportExtract"))
        #expect(OffscreenHTMLConverter.extractScript.contains("??"))
    }

    @Test func decodesAWellFormedExtractionRecord() {
        let json = """
        {"title":"Hi","byline":null,"publishedISO":null,"lang":null,"canonical":null,
         "markdown":"Hi there.","excerpt":null,"images":["https://example.com/cat.jpg"],
         "mf2JSON":null,"feedLinks":[]}
        """
        let decoded = OffscreenHTMLConverter.decodeExtraction(json)
        #expect(decoded?.markdown == "Hi there.")
        #expect(decoded?.images == ["https://example.com/cat.jpg"])
    }

    @Test func malformedJSONDecodesToNil() {
        #expect(OffscreenHTMLConverter.decodeExtraction("not json") == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter OffscreenHTMLConverterTests`
Expected: FAIL — `OffscreenHTMLConverter` doesn't exist yet.

- [ ] **Step 3: Write `OffscreenHTMLConverter.swift`**

```swift
import Foundation
import WebKit
import AnglesiteCore

/// Converts a fragment of rendered HTML (a WXR entry's `content:encoded`/`excerpt:encoded`) into
/// Markdown + referenced image URLs by running the same `JS/import-engine` bundle the design doc
/// specifies for every HTML-string body in the import pipeline — "one converter for every ladder
/// rung" (`docs/superpowers/specs/2026-08-21-website-import-transform-design.md`). `AnglesiteCore`
/// stays portable (no WebKit), so this — the concrete `ImportHTMLConverter` — lives here (#1636).
///
/// Owns one reusable, offscreen `WKWebView`: never added to a window or view hierarchy, created
/// lazily on first use. A `WKWebView` can't run two navigations concurrently, so `convert(html:)`
/// calls must be serialized by the caller — `WXRRung.items(from:convert:)`'s own `for` loop with
/// `await` already does this naturally; nothing here enforces it independently.
@MainActor
final class OffscreenHTMLConverter: NSObject, ImportHTMLConverter, WKNavigationDelegate {
    private let bundle: Bundle
    private var pendingLoadContinuation: CheckedContinuation<Void, Never>?

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        super.init()
    }

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        if let scriptSource = Self.importEngineSource(bundle: bundle) {
            configuration.userContentController.addUserScript(
                WKUserScript(source: scriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        return view
    }()

    /// Reads `Resources/ImportEngine/import-engine.js` from `bundle` — `nil` if the resource is
    /// missing (an unlikely but non-fatal build issue; conversion then always yields `("", [])`,
    /// which `WXRRung` already turns into a per-entry `ImportProblem` rather than crashing).
    private static func importEngineSource(bundle: Bundle) -> String? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        return try? String(contentsOf: resourceURL.appendingPathComponent("ImportEngine/import-engine.js"),
                           encoding: .utf8)
    }

    func convert(html: String) async -> (markdown: String, images: [String]) {
        await withCheckedContinuation { continuation in
            pendingLoadContinuation = continuation
            webView.loadHTMLString(Self.wrap(html), baseURL: nil)
        }
        guard let raw = try? await webView.evaluateJavaScript(Self.extractScript) as? String,
              let record = Self.decodeExtraction(raw)
        else {
            return ("", [])
        }
        return (record.markdown, record.images)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            pendingLoadContinuation?.resume()
            pendingLoadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            pendingLoadContinuation?.resume()
            pendingLoadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            pendingLoadContinuation?.resume()
            pendingLoadContinuation = nil
        }
    }

    /// Wraps a bare content fragment in a minimal document shell so `loadHTMLString` has
    /// something well-formed to parse. Factored out so it's testable without a real `WKWebView` —
    /// same reasoning as `WYSIWYGCanvasController.mountScript(for:)`'s split.
    static func wrap(_ html: String) -> String {
        "<!doctype html><html><body>\(html)</body></html>"
    }

    /// The `evaluateJavaScript` call string. `?? ""` guards the case the injected `WKUserScript`
    /// never ran (e.g. `importEngineSource` returned `nil`, or the load errored before the
    /// document script phase) — `window.__anglesiteImportExtract` would be `undefined`, and
    /// calling it directly would throw instead of resolving to a decodable value.
    static let extractScript = "window.__anglesiteImportExtract?.() ?? \"\""

    /// Decodes the JSON string `__anglesiteImportExtract()` returns into an ``ExtractionRecord``
    /// — `nil` for the empty-string fallback above, or any malformed payload.
    static func decodeExtraction(_ json: String) -> ExtractionRecord? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExtractionRecord.self, from: data)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter OffscreenHTMLConverterTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/OffscreenHTMLConverter.swift Tests/AnglesiteAppTests/OffscreenHTMLConverterTests.swift
git commit -m "feat(#1636): add offscreen WKWebView HTML-to-Markdown converter"
```

---

### Task 6: Extract `resolveScaffoldingContext()` into `SiteActions`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteActions.swift`
- Modify: `Sources/AnglesiteApp/SitesLauncherView.swift:485-593`
- Test: `Tests/AnglesiteAppTests/SiteActionsScaffoldingContextTests.swift`

**Interfaces:**
- Produces: `@MainActor struct SiteActions.ScaffoldingContext { let catalog: ThemeCatalog; let
  scaffolder: SiteScaffolder; let templateURL: URL; let isNameTaken: (String) -> Bool; let
  sitesRootAccess: URL? }`, `@MainActor static func SiteActions.resolveScaffoldingContext() async
  -> ScaffoldingContext?`. Task 7 calls this by name.

This is a pure refactor (moving existing logic, not changing it) so `SitesLauncherView`'s two
existing callers keep working identically — the only behavior change is *where* the
security-scoped-bookmark URL ends up: previously `resolveScaffoldingContext()` stashed it
directly into `SitesLauncherView`'s own `@State sitesRootScopedURL`; now it's returned as
`ScaffoldingContext.sitesRootAccess` and each caller decides its own lifetime (the launcher keeps
storing it on `@State` for the wizard sheet's duration; Task 7's `importWXR()` closes it with a
local `defer` once its own bounded async function returns).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteAppCore

@Suite("SiteActions scaffolding context")
@MainActor
struct SiteActionsScaffoldingContextTests {
    @Test("resolveScaffoldingContext loads the bundled theme catalog")
    func loadsCatalog() async throws {
        // TemplateRuntime.resolve() finds the real Resources/Template in the test bundle's
        // containing app/tool bundle — same assumption ThemeCatalogTests already makes.
        let context = await SiteActions.resolveScaffoldingContext()
        let unwrapped = try #require(context, "Template/catalog should resolve in a normal dev checkout")
        #expect(!unwrapped.catalog.themes.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --filter SiteActionsScaffoldingContextTests`
Expected: FAIL — `SiteActions.resolveScaffoldingContext()` doesn't exist yet.

- [ ] **Step 3: Move `resolveScaffoldingContext()` and `ScaffoldingContext` into `SiteActions`**

In `Sources/AnglesiteApp/SitesLauncherView.swift`, delete the `private struct ScaffoldingContext`
(lines 485–490) and the `resolveScaffoldingContext()` method (lines 496–573) entirely. Replace
every call site (`presentNewSite()`, `presentNewCommunity()`) of
`await resolveScaffoldingContext()` with `await SiteActions.resolveScaffoldingContext()`, and
assign the MAS scope from the returned context instead of a side effect:

```swift
    @MainActor
    private func presentNewSite() async {
        guard newSiteSession == nil, !preparingNewSite else { return }
        preparingNewSite = true
        defer { preparingNewSite = false }
        guard let context = await SiteActions.resolveScaffoldingContext() else { return }
        sitesRootScopedURL = context.sitesRootAccess
        let model = NewSiteWizardModel(catalog: context.catalog, isNameTaken: context.isNameTaken)
        newSiteSession = NewSiteSession(model: model, scaffolder: context.scaffolder, templateURL: context.templateURL)
    }

    @MainActor
    private func presentNewCommunity() async {
        guard newCommunitySession == nil, !preparingNewCommunity else { return }
        preparingNewCommunity = true
        defer { preparingNewCommunity = false }
        guard let context = await SiteActions.resolveScaffoldingContext() else { return }
        sitesRootScopedURL = context.sitesRootAccess
        let model = NewCommunityWizardModel(isNameTaken: context.isNameTaken)
        newCommunitySession = NewCommunitySession(model: model, scaffolder: context.scaffolder)
    }
```

Add to `Sources/AnglesiteApp/SiteActions.swift` (inside the existing `enum SiteActions`):

```swift
    /// Everything a scaffolding flow needs before it can build a site: template/theme catalog,
    /// sites-root resolution (with MAS security-scope handling), a name-uniqueness check, and a
    /// ready ``SiteScaffolder``. Shared by `SitesLauncherView`'s New Site/New Community flows and
    /// `importWXR()` (#1636) so the MAS-bookmark-sensitive setup exists in exactly one place.
    @MainActor
    struct ScaffoldingContext {
        let catalog: ThemeCatalog
        let scaffolder: SiteScaffolder
        let templateURL: URL
        let isNameTaken: (String) -> Bool
        /// The security-scoped sites-root URL this call started accessing, under MAS, when the
        /// sites root isn't the app's own iCloud container — `nil` otherwise (iCloud container,
        /// or non-MAS build). The caller owns stopping access on this URL once it's done with it;
        /// `resolveScaffoldingContext()` doesn't stop it itself, since callers need it to outlive
        /// this one call (a wizard sheet stays open across several scaffolding steps).
        let sitesRootAccess: URL?
    }

    /// Resolves everything `ScaffoldingContext` needs: loads the template/theme catalog, resolves
    /// (and, under MAS, grants access to) the sites root, and builds a `SiteScaffolder` wired to
    /// production `ProcessSupervisor`/`GitInitRunner`/`RepoBootstrap`/`SiteStore`.
    /// - Returns: The context, or `nil` if the template is missing, the catalog fails to load, or
    ///   (under MAS, outside the iCloud container) the user cancels the access-grant panel.
    @MainActor
    static func resolveScaffoldingContext() async -> ScaffoldingContext? {
        let resolution = TemplateRuntime.resolve()
        guard let templateURL = resolution.url else { return nil }
        guard let catalog = try? ThemeCatalog.load(templateURL: templateURL) else { return nil }

        let sitesRoot = AppSettings.shared.sitesRoot
        var sitesRootAccess: URL?
        #if ANGLESITE_MAS
        if AppSettings.shared.sitesRootSource != .iCloudContainer {
            guard let rootScope = await ensureSitesRootAccess(sitesRoot) else { return nil }
            sitesRootAccess = rootScope
        }
        #endif
        try? FileManager.default.createDirectory(at: sitesRoot, withIntermediateDirectories: true)

        try? await SiteStore.shared.load()
        let knownSites = await SiteStore.shared.sites
        let takenSlugs = Set(knownSites.map { SiteSlug.derive(from: $0.name) })
        let isNameTaken: (String) -> Bool = { name in
            takenSlugs.contains(SiteSlug.derive(from: name))
                || FileManager.default.fileExists(atPath: sitesRoot.appendingPathComponent("\(name).anglesite").path)
        }

        let scaffolder = SiteScaffolder(
            sitesRoot: sitesRoot, templateURL: templateURL, catalog: catalog,
            run: { exe, args, cwd in
                try await ProcessSupervisor.shared.run(executable: exe, arguments: args, currentDirectoryURL: cwd)
            },
            gitInit: { sourceDir in try GitInitRunner.run(in: sourceDir) },
            gitCommit: { sourceDir in try await RepoBootstrap.live().commitAll(source: sourceDir) },
            register: { package in
                let site = try await SiteStore.shared.record(package)
                #if ANGLESITE_MAS
                let bm = try SecurityScopedBookmark.create(for: site.packageURL)
                try await SiteStore.shared.setBookmark(bm, for: site.id)
                #endif
                return site
            }
        )
        return ScaffoldingContext(catalog: catalog, scaffolder: scaffolder, templateURL: templateURL,
                                  isNameTaken: isNameTaken, sitesRootAccess: sitesRootAccess)
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path . --filter SiteActionsScaffoldingContextTests`
Expected: PASS.

- [ ] **Step 5: Confirm the app target still builds (this touched two files' worth of call sites)**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED, no errors in `SitesLauncherView.swift`.

- [ ] **Step 6: Run the full test suite**

Run: `swift test --package-path .`
Expected: PASS — in particular, no `SitesLauncherView`-adjacent test regresses (New Site / New
Community flows still resolve a scaffolding context identically).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/SiteActions.swift Sources/AnglesiteApp/SitesLauncherView.swift Tests/AnglesiteAppTests/SiteActionsScaffoldingContextTests.swift
git commit -m "refactor(#1636): share scaffolding-context setup via SiteActions"
```

---

### Task 7: `SiteActions.importWXR` + File-menu command + final verification

**Files:**
- Modify: `Sources/AnglesiteApp/SiteActions.swift`
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift:250-262`
- Test: `Tests/AnglesiteAppTests/SiteActionsImportWXRTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–6 (`WXRParser`, `WXRRung`, `ImportHTMLConverter`,
  `WXRAssetDownloader`, `ImportTransform.run(resolved:...)`, `OffscreenHTMLConverter`,
  `SiteActions.ScaffoldingContext`/`resolveScaffoldingContext()`), plus existing
  `ImportSummaryModel`, `NewSiteDraft`, `SiteType.blog`, `ThemeCatalog.defaultThemeID(for:)`.
- Produces: `static func SiteActions.importWXR(data: Data, fileName: String, context:
  ScaffoldingContext, converter: any ImportHTMLConverter, assetDownloader: WXRAssetDownloader =
  WXRAssetDownloader(), commitGit: ... = ..., now: Date = Date()) async throws -> SiteStore.Site`
  (the testable core) and `static func SiteActions.importWXR() async throws -> SiteStore.Site?`
  (the panel-driving wrapper the menu command calls) — mirrors `importDirectory`/`importPackage`'s
  existing split.

- [ ] **Step 1: Write the failing tests for the testable core**

```swift
import Testing
import Foundation
import AnglesiteCore
import AnglesiteSiteModel
@testable import AnglesiteAppCore

@Suite("SiteActions importWXR")
@MainActor
struct SiteActionsImportWXRTests {
    private final class StubConverter: ImportHTMLConverter, @unchecked Sendable {
        var responses: [String: (markdown: String, images: [String])] = [:]
        func convert(html: String) async -> (markdown: String, images: [String]) {
            responses[html] ?? ("", [])
        }
    }

    private static let sampleWXR = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <rss version="2.0"
      xmlns:content="http://purl.org/rss/1.0/modules/content/"
      xmlns:excerpt="http://wordpress.org/export/1.1/excerpt/"
      xmlns:wp="http://wordpress.org/export/1.2/">
    <channel>
      <title>My Old Blog</title>
      <link>https://old-blog.example</link>
      <item>
        <title>Hello</title>
        <link>https://old-blog.example/hello/</link>
        <content:encoded><![CDATA[<p>Hi there.</p>]]></content:encoded>
        <excerpt:encoded><![CDATA[]]></excerpt:encoded>
        <wp:post_date_gmt>2024-05-01 10:00:00</wp:post_date_gmt>
        <pubDate>Wed, 01 May 2024 10:00:00 +0000</pubDate>
        <wp:status>publish</wp:status>
        <wp:post_type>post</wp:post_type>
      </item>
    </channel>
    </rss>
    """

    private func tempSitesRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wxr-import-sites-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A minimal, real `SiteScaffolder` against a temp sites root and a stub register — exercises
    /// the actual scaffolding pipeline (this repo has no lighter test double for it; every other
    /// `SiteActions`/`NewSiteWizardModel` test does the same).
    private func makeScaffolder(sitesRoot: URL, registered: @escaping @Sendable (AnglesitePackage) -> Void)
        throws -> SiteScaffolder {
        let templateURL = try #require(TemplateRuntime.resolve().url)
        let catalog = try ThemeCatalog.load(templateURL: templateURL)
        return SiteScaffolder(
            sitesRoot: sitesRoot, templateURL: templateURL, catalog: catalog,
            run: { exe, args, cwd in try await ProcessSupervisor.shared.run(executable: exe, arguments: args, currentDirectoryURL: cwd) },
            gitInit: { sourceDir in try GitInitRunner.run(in: sourceDir) },
            gitCommit: { _ in },
            register: { package in
                registered(package)
                return SiteStore.Site(id: UUID().uuidString, name: package.url.deletingPathExtension().lastPathComponent,
                                      packageURL: package.url, isValid: true, missingSentinels: [])
            })
    }

    @Test func importsAWXRFileIntoAFreshlyScaffoldedSite() async throws {
        let root = try tempSitesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var registeredPackage: AnglesitePackage?
        let scaffolder = try makeScaffolder(sitesRoot: root) { registeredPackage = $0 }
        let catalog = try ThemeCatalog.load(templateURL: try #require(TemplateRuntime.resolve().url))
        let context = SiteActions.ScaffoldingContext(
            catalog: catalog, scaffolder: scaffolder, templateURL: try #require(TemplateRuntime.resolve().url),
            isNameTaken: { _ in false }, sitesRootAccess: nil)

        let converter = StubConverter()
        converter.responses["<p>Hi there.</p>"] = ("Hi there.", [])

        var committed: URL?
        let site = try await SiteActions.importWXR(
            data: Data(Self.sampleWXR.utf8), fileName: "export.xml", context: context, converter: converter,
            commitGit: { sourceDirectory in committed = sourceDirectory },
            now: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(site.name == "My Old Blog")
        #expect(registeredPackage != nil)
        #expect(committed == site.sourceDirectory)
        let written = try String(
            contentsOf: site.sourceDirectory.appendingPathComponent("src/content/blog/hello.md"), encoding: .utf8)
        #expect(written.contains("Hi there."))
    }

    @Test func numbersTheChannelTitleWhenAlreadyTaken() async throws {
        let root = try tempSitesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scaffolder = try makeScaffolder(sitesRoot: root) { _ in }
        let catalog = try ThemeCatalog.load(templateURL: try #require(TemplateRuntime.resolve().url))
        let context = SiteActions.ScaffoldingContext(
            catalog: catalog, scaffolder: scaffolder, templateURL: try #require(TemplateRuntime.resolve().url),
            isNameTaken: { $0 == "My Old Blog" }, sitesRootAccess: nil)

        let converter = StubConverter()
        converter.responses["<p>Hi there.</p>"] = ("Hi there.", [])

        let site = try await SiteActions.importWXR(
            data: Data(Self.sampleWXR.utf8), fileName: "old-blog-export.xml", context: context, converter: converter,
            commitGit: { _ in }, now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(site.name == "My Old Blog 2")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter SiteActionsImportWXRTests`
Expected: FAIL — `SiteActions.importWXR` doesn't exist yet.

- [ ] **Step 3: Add `importWXR` to `SiteActions.swift`**

```swift
extension SiteActions {
    /// Surfaced when importing a WXR export fails at any stage — parse, scaffold, or write.
    struct WXRImportError: LocalizedError {
        let fileName: String
        let underlying: Error
        var errorDescription: String? {
            String(localized: "Couldn't import “\(fileName)”: \(underlying.localizedDescription)")
        }
    }

    private struct ScaffoldFailure: LocalizedError {
        let step: String
        let message: String
        var errorDescription: String? { "\(step): \(message)" }
    }

    /// Parses a WXR (WordPress export) file, scaffolds a fresh site for its content, and writes
    /// the imported posts/pages into it (#1636). Panel-free core — `importWXR()` below drives the
    /// file picker and calls this, mirroring `importDirectory`/`importPackage`'s existing split so
    /// the actual import logic is unit-testable without driving AppKit.
    ///
    /// - Parameters:
    ///   - data: The raw bytes of the `.xml` export file.
    ///   - fileName: The picked file's display name — used as a site-name fallback and in error
    ///     messages.
    ///   - context: A scaffolding context (``resolveScaffoldingContext()``).
    ///   - converter: Converts each entry's HTML body to Markdown (production:
    ///     ``OffscreenHTMLConverter``).
    ///   - assetDownloader: Fetches the images referenced in imported content.
    ///   - commitGit: Lands the initial commit for the imported content, injectable for tests.
    ///   - now: The deterministic clock forwarded to ``ImportTransform``.
    /// - Returns: The newly created, already-registered site.
    /// - Throws: ``WXRImportError`` wrapping whatever stage failed.
    static func importWXR(
        data: Data, fileName: String, context: ScaffoldingContext, converter: any ImportHTMLConverter,
        assetDownloader: WXRAssetDownloader = WXRAssetDownloader(),
        commitGit: @escaping @Sendable (_ sourceDirectory: URL) async throws -> Void = { sourceDirectory in
            try await RepoBootstrap.live().commitAll(source: sourceDirectory)
        },
        now: Date = Date()
    ) async throws -> SiteStore.Site {
        do {
            let (channel, entries) = try WXRParser.parse(data)
            let (items, extractionProblems) = await WXRRung.items(from: entries, convert: converter)

            var draft = NewSiteDraft(siteType: .blog,
                                     name: Self.candidateSiteName(channel: channel, fileName: fileName,
                                                                  isNameTaken: context.isNameTaken))
            draft.themeID = context.catalog.defaultThemeID(for: .blog)

            var completedSiteID: String?
            for await step in context.scaffolder.scaffold(draft) {
                if case .failed(let stepName, let message) = step {
                    throw ScaffoldFailure(step: stepName, message: message)
                }
                if case .done(let id) = step { completedSiteID = id }
            }
            guard let siteID = completedSiteID,
                  let site = await SiteStore.shared.sites.first(where: { $0.id == siteID })
            else {
                throw ScaffoldFailure(step: "registering", message: "Scaffolding finished with no site")
            }

            let imageURLs = items.flatMap(\.images)
            let assetsDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("wxr-import-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: assetsDirectory) }
            let (assets, downloadProblems) = await assetDownloader.download(imageURLs: imageURLs, into: assetsDirectory)

            let resolved = ResolvedContent(items: items, homepage: nil, skippedURLs: [],
                                           problems: extractionProblems + downloadProblems)
            try ImportTransform.run(
                resolved: resolved, assets: assets, assetsDirectory: assetsDirectory,
                sourceDirectory: site.sourceDirectory, configDirectory: site.configDirectory,
                now: now, onStep: { _ in })

            try await commitGit(site.sourceDirectory)
            return site
        } catch {
            throw WXRImportError(fileName: fileName, underlying: error)
        }
    }

    /// Site name for the freshly scaffolded package: the WXR channel's title when present,
    /// non-empty, and not already taken; the picked file's basename otherwise; a numbered suffix
    /// (`"Name 2"`, `"Name 3"`, …) if even that collides.
    private static func candidateSiteName(channel: WXRChannel, fileName: String,
                                          isNameTaken: (String) -> Bool) -> String {
        let trimmedTitle = channel.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (trimmedTitle?.isEmpty == false ? trimmedTitle! : nil)
            ?? (fileName as NSString).deletingPathExtension
        guard isNameTaken(base) else { return base }
        var suffix = 2
        while isNameTaken("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    /// Picks a `.xml` file, resolves a scaffolding context, and imports it — the File ▸ Import
    /// WordPress Export (WXR)… menu command's target.
    /// - Returns: the newly created site, or `nil` if the panel was cancelled or the user
    ///   cancelled a MAS sites-root access grant (both silent, non-error dismissals).
    /// - Throws: ``WXRImportError`` if the template is missing, the theme catalog fails to load,
    ///   or parsing/scaffolding/writing the import fails.
    static func importWXR() async throws -> SiteStore.Site? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a WordPress export (WXR) file to import.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        // `onFailure` distinguishes a real setup problem (template missing, catalog load failed —
        // worth an alert) from the MAS access-grant panel simply being cancelled (silent, like the
        // panel above) — `resolveScaffoldingContext` returns `nil` for both, but only calls
        // `onFailure` for the former. Without this, a broken install would make File ▸ Import
        // WordPress Export… silently do nothing, the same gap Task 6's review caught and fixed for
        // the New Site/New Community launcher flows.
        var setupFailureMessage: String?
        guard let context = await resolveScaffoldingContext(onFailure: { setupFailureMessage = $0 })
        else {
            if let setupFailureMessage {
                throw WXRImportError(fileName: url.lastPathComponent,
                                     underlying: ScaffoldFailure(step: "setup", message: setupFailureMessage))
            }
            return nil
        }
        defer { context.sitesRootAccess?.stopAccessingSecurityScopedResource() }

        do {
            let data = try Data(contentsOf: url)
            return try await importWXR(data: data, fileName: url.lastPathComponent, context: context,
                                       converter: OffscreenHTMLConverter())
        } catch let error as WXRImportError {
            throw error
        } catch {
            throw WXRImportError(fileName: url.lastPathComponent, underlying: error)
        }
    }
}
```

- [ ] **Step 4: Wire the File-menu command**

In `Sources/AnglesiteApp/AnglesiteApp.swift`, next to the existing `Button("Import Site…")`
(around line 251), add:

```swift
                Button("Import Site…") {
                    Task { @MainActor in
                        do {
                            if let site = try await SiteActions.importPackage() {
                                openWindow(value: site.id)
                            }
                        } catch {
                            NSAlert(error: error).runModal()
                        }
                    }
                }
                Button("Import WordPress Export (WXR)…") {
                    Task { @MainActor in
                        do {
                            if let site = try await SiteActions.importWXR() {
                                openWindow(value: site.id)
                            }
                        } catch {
                            NSAlert(error: error).runModal()
                        }
                    }
                }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path . --filter SiteActionsImportWXRTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Run the full test suite**

Run: `swift test --package-path .`
Expected: PASS across every SwiftPM target — no regressions from Tasks 1–7.

- [ ] **Step 7: Build the app target**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Manual smoke test (the one thing `swift test` can't cover — the live WKWebView round-trip)**

Follow `docs/testing-macos-app.md` to launch the built Debug app. Create (or find) a small real
WXR export — WordPress's own **Tools ▸ Export** screen on any test site produces one; a handful
of posts is enough. Then:

1. **File ▸ Import WordPress Export (WXR)…**, pick that file.
2. Confirm a new site window opens.
3. Open the Navigator and confirm the imported posts appear under **Blog** (and any WordPress
   "page" entries under Pages), with real Markdown bodies (not empty).
4. Confirm any post that had an in-body image now shows a `public/images/…` local path in its
   Markdown rather than the original WordPress media URL (check via the file's raw content, or
   the rendered preview if the image downloaded successfully).
5. Confirm `Config/import-report.json` inside the new package exists and its `plan.rungBreakdown`
   shows `"wxr"` counts.

Record the result in the PR body's Test plan section; if no real WXR file is available in this
environment, say so explicitly rather than claiming this step passed.

- [ ] **Step 9: Commit**

```bash
git add Sources/AnglesiteApp/SiteActions.swift Sources/AnglesiteApp/AnglesiteApp.swift Tests/AnglesiteAppTests/SiteActionsImportWXRTests.swift
git commit -m "feat(#1636): add File ▸ Import WordPress Export (WXR)… command"
```

---

## Final PR

Per `CONTRIBUTING.md` ▸ "Commits and pull requests": build the PR body from
`.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan — plus
whatever else the template specifies), with `Closes #1636` in the template's `Closes #` line.
Call out explicitly in Summary or a Design notes section:

- This adds one new, additive `ImportTransform` overload (Task 4) — the only exception to issue
  #1636's "no changes expected to ContentClassifier, ImportEmitter, AssetLocalizer, or
  ImportTransform," discovered necessary because the existing entry point hard-codes resolving
  from a crawled `ImportSnapshot`, which a one-shot WXR file has no equivalent of.
- The narrower-than-planned SSRF guard in `WXRAssetDownloader` (literal-IP/scheme checks, not a
  full DNS-resolution-based port of `net-guard.ts`) — the real guard is scoped to the crawl-stage
  design (#1615), not yet built.
- Whether the manual WXR smoke test (Task 7 Step 8) actually ran, and against what kind of export
  file, per `docs/testing-macos-app.md`'s guidance on reporting checks that couldn't be run.

No paired sidecar PR is needed — nothing here touches the MCP message schema.

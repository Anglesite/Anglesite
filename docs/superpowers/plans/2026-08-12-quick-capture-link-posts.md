# Quick-Capture Link Posts (#531) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pasted/dragged URL becomes a published link post (an entry in the template's existing `bookmarks` collection) in seconds — via a compose sheet, drag/paste entry points, a menu command, and a new App Intent.

**Architecture:** New `LinkMetadataParser`/`LinkMetadataFetcher` in AnglesiteCore fetch page metadata (`og:` tags). `ContentScaffold.renderEntry` gains `fieldValues` overrides for its `.markdown` body and `.bool` draft fields, which flow through the **existing** `createTyped` path (`NativeContentOperations` → validation → slug-from-URL → write → git commit) untouched. App layer adds a `QuickCaptureSheet` presented from the site window, the launcher, and a File ▸ New Link Post… command; AnglesiteIntents adds `AddLinkPostIntent`.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27), Swift Testing, Foundation URLSession. Apple frameworks only — no new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-12-quick-capture-link-posts-design.md` (approved). One refinement vs. the spec: there is no separate `QuickCaptureModel` type — the sheet follows the codebase's established sheet pattern (`NewCollectionEntrySheet`: `@State` + `onCreate` closure), and `LinkMetadataFetcher` is a `Sendable` struct rather than an actor (it is stateless). All logic that needs tests lives in Core/Intents, per the spec's testing section.

## Global Constraints

- **Worktree:** all work happens in `.claude/worktrees/issue-531-quick-capture/` (already created, branch `worktree-issue-531-quick-capture`). `cd` there before every command. `xcodegen generate` has already been run.
- **Apple frameworks only**; never call `Process()` outside `ProcessSupervisor` (this plan spawns nothing).
- **Purity contract (#916):** `ContentScaffold.renderEntry` with empty `fieldValues` must render byte-identical output to today.
- **Error copy house rule:** user-facing failure text describes consequences to the owner's site — never git/diff/file-layout jargon.
- **Commits:** conventional format, subject ≤72 chars, issue number in subject, e.g. `feat(#531): add link metadata parser`.
- **Tests:** `swift test --package-path .` runs the SwiftPM suites. Scope to one suite with `--filter` while iterating. App-target changes are verified by `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`.
- The bookmark content type already exists: `ContentTypeRegistry.bookmark` (`Sources/AnglesiteCore/ContentTypeRegistry.swift:401`) — fields `lang`, `bookmarkOf` (.url, required), `title` (.string), `body` (.markdown), `publishDate` (.datetime, required), `tags` (.stringArray), `draft` (.bool). Do NOT add a new content type or template schema.

---

### Task 1: `LinkMetadata` + `LinkMetadataParser` (pure HTML-head scanner)

**Files:**
- Create: `Sources/AnglesiteCore/LinkMetadata.swift`
- Test: `Tests/AnglesiteCoreTests/LinkMetadataParserTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces: `public struct LinkMetadata: Sendable, Equatable { var title: String?; var description: String?; var siteName: String? }` with memberwise `public init(title:description:siteName:)` (all defaulted to nil); `public enum LinkMetadataParser { public static func parse(html: String) -> LinkMetadata }`. Task 2's fetcher and Task 4's intent consume both.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import AnglesiteCore

@Suite("LinkMetadataParser")
struct LinkMetadataParserTests {
    @Test("parses og:title, og:description, og:site_name")
    func parsesOpenGraph() {
        let html = """
        <html><head>
        <meta property="og:title" content="Interesting Thing" />
        <meta property="og:description" content="Why it matters." />
        <meta property="og:site_name" content="Example Blog" />
        <title>Interesting Thing — Example Blog</title>
        </head><body></body></html>
        """
        let meta = LinkMetadataParser.parse(html: html)
        #expect(meta.title == "Interesting Thing")
        #expect(meta.description == "Why it matters.")
        #expect(meta.siteName == "Example Blog")
    }

    @Test("falls back to <title> when og:title is absent")
    func titleFallback() {
        let meta = LinkMetadataParser.parse(html: "<head><title>Plain Page</title></head>")
        #expect(meta.title == "Plain Page")
        #expect(meta.description == nil)
    }

    @Test("attribute order and quote style don't matter; name= works like property=")
    func attributeVariants() {
        let html = """
        <meta content='Reversed' property='og:title'>
        <meta name="og:description" content="Named, not property.">
        """
        let meta = LinkMetadataParser.parse(html: html)
        #expect(meta.title == "Reversed")
        #expect(meta.description == "Named, not property.")
    }

    @Test("decodes HTML entities, named and numeric")
    func entityDecoding() {
        let html = #"<meta property="og:title" content="Q&amp;A: 5 &lt; 6 &#39;quoted&#x2019;">"#
        #expect(LinkMetadataParser.parse(html: html).title == "Q&A: 5 < 6 'quoted’")
    }

    @Test("whitespace-trimmed; empty values become nil; garbage input is empty metadata")
    func normalization() {
        #expect(LinkMetadataParser.parse(html: #"<meta property="og:title" content="  ">"#).title == nil)
        #expect(LinkMetadataParser.parse(html: "<title>  Padded  </title>").title == "Padded")
        let binaryish = String(repeating: "\u{0}garbage<>&", count: 100)
        #expect(LinkMetadataParser.parse(html: binaryish) == LinkMetadata())
    }

    @Test("first matching meta wins")
    func firstWins() {
        let html = """
        <meta property="og:title" content="First">
        <meta property="og:title" content="Second">
        """
        #expect(LinkMetadataParser.parse(html: html).title == "First")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path . --filter LinkMetadataParserTests`
Expected: FAIL to compile — `LinkMetadata`/`LinkMetadataParser` not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Page metadata scraped from an HTML document's head, used to pre-fill the quick-capture
/// link-post compose sheet and `AddLinkPostIntent` (#531). All fields optional — a page with
/// no usable metadata yields an empty value, never a failure.
public struct LinkMetadata: Sendable, Equatable {
    public var title: String?
    public var description: String?
    public var siteName: String?

    public init(title: String? = nil, description: String? = nil, siteName: String? = nil) {
        self.title = title
        self.description = description
        self.siteName = siteName
    }
}

/// Pure scanner from HTML text to ``LinkMetadata``: `og:title` / `og:description` /
/// `og:site_name` (via `property=` or `name=`), falling back to `<title>`. Deliberately not a
/// full HTML parser — article pages carry server-rendered `og:` tags in the head, and a regex
/// scan over `<meta>` tags is robust to attribute order and quote style without a WebKit
/// dependency (spec §3.1's case against `LPMetadataProvider`). Chosen over `NSAttributedString`'s
/// HTML importer, which spins up WebKit machinery and must run on the main thread.
public enum LinkMetadataParser {
    public static func parse(html: String) -> LinkMetadata {
        LinkMetadata(
            title: normalized(metaContent(in: html, key: "og:title") ?? titleText(in: html)),
            description: normalized(metaContent(in: html, key: "og:description")),
            siteName: normalized(metaContent(in: html, key: "og:site_name"))
        )
    }

    /// The decoded `content` of the first `<meta>` whose `property` or `name` equals `key`.
    private static func metaContent(in html: String, key: String) -> String? {
        guard let tagRegex = try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: [.caseInsensitive]) else {
            return nil
        }
        let fullRange = NSRange(html.startIndex..., in: html)
        var result: String?
        tagRegex.enumerateMatches(in: html, range: fullRange) { match, _, stop in
            guard let match, let tagRange = Range(match.range, in: html) else { return }
            let tag = String(html[tagRange])
            let keyValue = attribute("property", in: tag) ?? attribute("name", in: tag)
            guard keyValue?.lowercased() == key else { return }
            if let content = attribute("content", in: tag) {
                result = content
                stop.pointee = true
            }
        }
        return result
    }

    private static func titleText(in html: String) -> String? {
        firstCapture(pattern: "<title[^>]*>(.*?)</title>", in: html).map(decodeEntities)
    }

    /// The decoded value of `name="…"` / `name='…'` inside one tag, regardless of attribute order.
    private static func attribute(_ name: String, in tag: String) -> String? {
        firstCapture(pattern: "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", in: tag)
            .map(decodeEntities)
    }

    /// First non-empty capture group of `pattern`'s first match, or nil.
    private static func firstCapture(pattern: String, in text: String) -> String? {
        let options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        for group in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: group), in: text) { return String(text[range]) }
        }
        return nil
    }

    /// Minimal HTML entity decoder: the named entities that actually appear in titles/descriptions
    /// plus numeric (`&#39;`) and hex (`&#x2019;`) forms. Unknown entities pass through verbatim.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            // Entity names are short; a far-away `;` means this `&` is literal.
            guard let semi = rest.firstIndex(of: ";"),
                  rest.distance(from: rest.startIndex, to: semi) <= 10,
                  let decoded = decodeEntity(rest[rest.index(after: rest.startIndex)..<semi])
            else {
                out += "&"
                rest = rest.dropFirst()
                continue
            }
            out += decoded
            rest = rest[rest.index(after: semi)...]
        }
        out += rest
        return out
    }

    private static func decodeEntity(_ entity: Substring) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default:
            guard entity.hasPrefix("#") else { return nil }
            let digits = entity.dropFirst()
            let value: UInt32? = digits.hasPrefix("x") || digits.hasPrefix("X")
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
    }

    /// Trimmed; empty → nil.
    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path . --filter LinkMetadataParserTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LinkMetadata.swift Tests/AnglesiteCoreTests/LinkMetadataParserTests.swift
git commit -m "feat(#531): add LinkMetadataParser for og: tag scraping"
```

---

### Task 2: `LinkMetadataFetcher`

**Files:**
- Create: `Sources/AnglesiteCore/LinkMetadataFetcher.swift`
- Test: `Tests/AnglesiteCoreTests/LinkMetadataFetcherTests.swift`

**Interfaces:**
- Consumes: `LinkMetadataParser.parse(html:)`, `LinkMetadata` (Task 1).
- Produces: `public struct LinkMetadataFetcher: Sendable { public init(session: URLSession? = nil); public func fetch(url: URL) async throws -> LinkMetadata }` and `public struct LinkMetadataFetchError: Error, Sendable, Equatable { public let reason: String }`. Tasks 4–6 consume `fetch(url:)`.

- [ ] **Step 1: Write the failing tests**

Stub `URLProtocol` mirrors `WorkerCatalogStubURLProtocol` in `Tests/AnglesiteCoreTests/WorkerCatalogFetcherTests.swift` — read that file's stub before writing this one.

```swift
import Foundation
import Testing
@testable import AnglesiteCore

/// Canned-response URLProtocol so the fetcher runs with no network — mirrors
/// `WorkerCatalogFetcherTests`' `WorkerCatalogStubURLProtocol`.
private final class LinkStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var mimeType: String? = "text/html"
    nonisolated(unsafe) static var shouldFailToLoad = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.shouldFailToLoad {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        var headers: [String: String] = [:]
        if let mime = Self.mimeType { headers["Content-Type"] = mime }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LinkStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite("LinkMetadataFetcher", .serialized)  // stub state is static; keep cases sequential
struct LinkMetadataFetcherTests {
    private func reset(status: Int = 200, body: String = "", mime: String? = "text/html", fail: Bool = false) {
        LinkStubURLProtocol.statusCode = status
        LinkStubURLProtocol.body = body
        LinkStubURLProtocol.mimeType = mime
        LinkStubURLProtocol.shouldFailToLoad = fail
    }

    @Test("returns parsed metadata for an HTML page")
    func success() async throws {
        reset(body: #"<head><meta property="og:title" content="Hello"></head>"#)
        let fetcher = LinkMetadataFetcher(session: LinkStubURLProtocol.makeSession())
        let meta = try await fetcher.fetch(url: URL(string: "https://example.com/a")!)
        #expect(meta.title == "Hello")
    }

    @Test("non-2xx status throws")
    func httpError() async {
        reset(status: 404)
        let fetcher = LinkMetadataFetcher(session: LinkStubURLProtocol.makeSession())
        await #expect(throws: LinkMetadataFetchError.self) {
            _ = try await fetcher.fetch(url: URL(string: "https://example.com/missing")!)
        }
    }

    @Test("non-HTML content type throws")
    func nonHTML() async {
        reset(body: "%PDF-1.4", mime: "application/pdf")
        let fetcher = LinkMetadataFetcher(session: LinkStubURLProtocol.makeSession())
        await #expect(throws: LinkMetadataFetchError.self) {
            _ = try await fetcher.fetch(url: URL(string: "https://example.com/doc.pdf")!)
        }
    }

    @Test("transport failure propagates as an error")
    func transportFailure() async {
        reset(fail: true)
        let fetcher = LinkMetadataFetcher(session: LinkStubURLProtocol.makeSession())
        await #expect(throws: (any Error).self) {
            _ = try await fetcher.fetch(url: URL(string: "https://example.com/x")!)
        }
    }

    @Test("body beyond the byte cap is ignored, head metadata still parses")
    func byteCap() async throws {
        let head = #"<head><meta property="og:title" content="Capped"></head>"#
        reset(body: head + String(repeating: "x", count: LinkMetadataFetcher.maximumBodyBytes))
        let fetcher = LinkMetadataFetcher(session: LinkStubURLProtocol.makeSession())
        let meta = try await fetcher.fetch(url: URL(string: "https://example.com/big")!)
        #expect(meta.title == "Capped")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path . --filter LinkMetadataFetcherTests`
Expected: FAIL to compile — `LinkMetadataFetcher` not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Why a metadata fetch failed — surfaced as a quiet inline note in the compose sheet, never a
/// blocking error (spec §6: capture always proceeds with the bare URL).
public struct LinkMetadataFetchError: Error, Sendable, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Fetches a web page and scrapes ``LinkMetadata`` out of its head via ``LinkMetadataParser``.
/// Host-side URLSession (the app sandbox already holds `com.apple.security.network.client`) so
/// capture works with no site runtime running — the launcher flow's requirement (spec §3.1).
/// Stateless, so a `Sendable` struct; `session` is injectable for `URLProtocol`-stubbed tests.
public struct LinkMetadataFetcher: Sendable {
    /// Read cap: link metadata lives in the document head; bounding what we hand the parser
    /// keeps memory flat on hostile or enormous pages.
    public static let maximumBodyBytes = 2 * 1024 * 1024

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            // Ephemeral: no cookies, no credentials, no cache — this is a metadata peek at an
            // arbitrary URL, not a browsing session.
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: config)
        }
    }

    public func fetch(url: URL) async throws -> LinkMetadata {
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LinkMetadataFetchError(reason: "Not an HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw LinkMetadataFetchError(reason: "The page responded with HTTP \(http.statusCode)")
        }
        if let mime = http.mimeType, !mime.localizedCaseInsensitiveContains("html") {
            throw LinkMetadataFetchError(reason: "That link isn't a web page (\(mime))")
        }
        let html = Self.decode(data.prefix(Self.maximumBodyBytes), textEncodingName: http.textEncodingName)
        return LinkMetadataParser.parse(html: html)
    }

    /// Decode using the response's declared charset when it names one, else UTF-8, else lossy
    /// UTF-8 — a wrong-charset decode still yields scannable ASCII `<meta>` markup.
    static func decode(_ data: Data, textEncodingName: String?) -> String {
        if let name = textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let decoded = String(data: data, encoding: encoding) { return decoded }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path . --filter LinkMetadataFetcherTests`
Expected: PASS (5 tests). Also run `swift test --package-path . --filter LinkMetadataParserTests` — still PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LinkMetadataFetcher.swift Tests/AnglesiteCoreTests/LinkMetadataFetcherTests.swift
git commit -m "feat(#531): add LinkMetadataFetcher (URLSession + og: scrape)"
```

---

### Task 3: `renderEntry` body + draft overrides through `fieldValues`

**Files:**
- Modify: `Sources/AnglesiteCore/ContentScaffold.swift` (the `.markdown` and `.bool` cases inside `renderEntry`, currently near lines 206–221, plus the function's doc comment)
- Test: `Tests/AnglesiteCoreTests/ContentScaffoldTests.swift` (append), `Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift` (append)

**Interfaces:**
- Consumes: existing `ContentScaffold.renderEntry(descriptor:title:now:fieldValues:)` and `NativeContentOperations.createTyped(siteID:typeID:title:slug:fieldValues:registry:onProgress:)` — **no signature changes anywhere**; only the two `switch` cases learn to read `fieldValues`.
- Produces: `fieldValues["body"]` (any `.markdown` field's name) replaces the placeholder body — supplied-but-empty means "no body"; `fieldValues["draft"]` (any `.bool` field's name) with exactly `"true"`/`"false"` overrides the default — anything else falls back. Tasks 4–6 rely on these two keys.

- [ ] **Step 1: Write the failing tests**

Append to `ContentScaffoldTests.swift` (read the file's existing helpers first — it has a fixed `now` Date and uses `ContentTypeRegistry()` descriptors):

```swift
@Test("renderEntry uses a supplied markdown body and bool override (#531)")
func renderEntryBodyAndDraftOverrides() {
    let bookmark = ContentTypeRegistry().descriptor(id: "bookmark")!
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let out = ContentScaffold.renderEntry(
        descriptor: bookmark, title: "Example", now: now,
        fieldValues: [
            "bookmarkOf": "https://example.com/post",
            "body": "Two sentences of commentary.",
            "draft": "false",
        ])
    #expect(out.contains("draft: false"))
    #expect(out.hasSuffix("\nTwo sentences of commentary.\n"))
    #expect(!out.contains("Write your bookmark here."))
}

@Test("renderEntry: supplied-but-empty body means no body; bad bool falls back (#531)")
func renderEntryEmptyBodyAndBadBool() {
    let bookmark = ContentTypeRegistry().descriptor(id: "bookmark")!
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let out = ContentScaffold.renderEntry(
        descriptor: bookmark, title: "Example", now: now,
        fieldValues: ["bookmarkOf": "https://example.com/post", "body": "", "draft": "yes"])
    #expect(out.hasSuffix("---\n"))          // frontmatter block only, no body text
    #expect(out.contains("draft: true"))     // non-"true"/"false" keeps the #798 default
}

@Test("renderEntry purity: empty fieldValues is byte-identical to no fieldValues (#916/#531)")
func renderEntryPurityHolds() {
    let bookmark = ContentTypeRegistry().descriptor(id: "bookmark")!
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let a = ContentScaffold.renderEntry(descriptor: bookmark, title: "T", now: now)
    let b = ContentScaffold.renderEntry(descriptor: bookmark, title: "T", now: now, fieldValues: [:])
    #expect(a == b)
    #expect(a.contains("draft: true"))
    #expect(a.contains("Write your bookmark here."))
}
```

Append to `NativeContentOperationsTests.swift` an end-to-end write (read the file's existing fixtures first — it has a temp-site-directory helper and constructs `NativeContentOperations` with a `siteDirectory` resolver; mirror the nearest existing `createTyped` test's setup exactly, changing only `typeID`/`fieldValues`/assertions):

```swift
@Test("createTyped writes a bookmark with commentary body and draft override (#531)")
func createTypedBookmarkWithBodyAndDraft() async throws {
    // Use this file's existing temp-site fixture; the assertions are what matter:
    let ops = /* same construction as the neighboring createTyped tests */
    let result = await ops.createTyped(
        siteID: siteID, typeID: "bookmark", title: "Example",
        slug: nil,
        fieldValues: [
            "bookmarkOf": "https://example.com/post",
            "body": "Worth reading.",
            "draft": "false",
        ])
    guard case .created(let filePath, _) = result else {
        Issue.record("expected .created, got \(result)")
        return
    }
    let contents = try String(contentsOf: root.appendingPathComponent(filePath), encoding: .utf8)
    #expect(contents.contains(#"bookmarkOf: "https://example.com/post""#))
    #expect(contents.contains("draft: false"))
    #expect(contents.hasSuffix("\nWorth reading.\n"))
}
```

(The `/* same construction */` is resolved by copying the setup lines from the adjacent `createTyped` test in that file — the fixture helper names are file-local, so copy them verbatim rather than inventing new ones.)

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path . --filter ContentScaffoldTests`
Expected: FAIL — `renderEntryBodyAndDraftOverrides` and `renderEntryEmptyBodyAndBadBool` fail (placeholder body rendered, `draft: true` emitted). `renderEntryPurityHolds` PASSES already (it pins current behavior).

- [ ] **Step 3: Implement**

In `ContentScaffold.renderEntry`, replace the `.markdown` and `.bool` cases:

```swift
case .markdown:
    // A supplied value replaces the placeholder; supplied-but-empty means "no body"
    // (quick capture publishing without commentary must not publish placeholder text,
    // #531). Absent key keeps the placeholder — the #916 purity contract.
    if let supplied = fieldValues[field.name] {
        bodyPlaceholder = supplied.isEmpty ? nil : supplied
    } else {
        bodyPlaceholder = "Write your \(descriptor.displayName.lowercased()) here."
    }
// New entries are drafts by default (#798); a caller-supplied exact "true"/"false"
// overrides (quick capture's Publish writes draft: false, #531). Anything else —
// including a typo'd value — keeps the safe default rather than guessing.
case .bool:
    let supplied = fieldValues[field.name].flatMap { $0 == "true" || $0 == "false" ? $0 : nil }
    lines.append("\(field.name): \(supplied ?? (field.name == "draft" ? "true" : "false"))")
```

Also update `renderEntry`'s doc comment: extend the `fieldValues` sentence to say it supplies values for the scalar-string kinds **and, since #531, the `.markdown` body and `.bool` fields (exact `"true"`/`"false"`)**; the empty-`fieldValues` purity sentence stays.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path . --filter ContentScaffoldTests && swift test --package-path . --filter NativeContentOperationsTests`
Expected: PASS, including all pre-existing tests in both suites (the purity contract means zero behavior change for existing callers).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ContentScaffold.swift Tests/AnglesiteCoreTests/ContentScaffoldTests.swift Tests/AnglesiteCoreTests/NativeContentOperationsTests.swift
git commit -m "feat(#531): renderEntry accepts markdown body + bool overrides"
```

---

### Task 4: `AddLinkPostIntent` + seams + `WindowRouter` quick-capture request

**Files:**
- Create: `Sources/AnglesiteIntents/LinkPostIntent.swift`
- Modify: `Sources/AnglesiteIntents/Bootstrap.swift` (register the concrete workflow), `Sources/AnglesiteIntents/WindowRouter.swift` (add `quickCaptureRequested`)
- Test: `Tests/AnglesiteIntentsTests/LinkPostIntentTests.swift` (create), `Tests/AnglesiteIntentsTests/WindowRouterTests.swift` (append)

**Interfaces:**
- Consumes: `LinkMetadataFetcher`/`LinkMetadata` (Tasks 1–2), `ContentCreationWorkflow.createTyped(siteID:typeID:title:slug:fieldValues:onProgress:)` and its `TypedSlugCreator` typealias, `ContentFieldValidation.isAbsoluteURL`, `SiteEntity`, `PostEntity` (all existing).
- Produces:
  - `AddLinkPostIntent` — parameters `site: SiteEntity`, `url: URL`, `title2: String?` ("Title"), `commentary: String?`, `publish: Bool` (default false).
  - `public enum TypedContentOverride { @TaskLocal public static var scoped: ContentCreationWorkflow.TypedSlugCreator? }`
  - `public enum LinkMetadataOverride { @TaskLocal public static var scoped: (@Sendable (URL) async throws -> LinkMetadata)? }`
  - `public enum LinkPostDialogs { static func created(_:siteName:published:) -> String; static let invalidURL: String }`
  - `WindowRouter.quickCaptureRequested: Bool`, `requestQuickCapture()`, `clearQuickCaptureRequest()` — Task 6's launcher consumes these.
  - Bootstrap additionally registers `ContentCreationWorkflow` (concrete) with `AppDependencyManager`, sharing the instance already registered as `any ContentOperationsService`.

- [ ] **Step 1: Write the failing tests**

`Tests/AnglesiteIntentsTests/LinkPostIntentTests.swift` — mirror `ContentIntentsTests`' structure (it builds `SiteEntity` via `SiteEntity(TestStore.site(id:name:))`; read `Tests/AnglesiteIntentsTests/ContentIntentsTests.swift:1-40` and `Support/` for the exact helpers before writing):

```swift
import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteIntents

@Suite("AddLinkPostIntent")
struct LinkPostIntentTests {
    private static let aSite = "site-1"

    private func entity() -> SiteEntity {
        SiteEntity(TestStore.site(id: Self.aSite, name: "My Site"))
    }

    /// Records the createTyped call the intent makes.
    private final class Recorder: @unchecked Sendable {
        var calls: [(siteID: String, typeID: String, title: String, slug: String?, fieldValues: [String: String])] = []
    }

    @Test("forwards bookmarkOf, body, draft=true by default; fetches title when absent")
    func forwardsAndFetches() async throws {
        let recorder = Recorder()
        let creator: ContentCreationWorkflow.TypedSlugCreator = { siteID, typeID, title, slug, fieldValues, _ in
            recorder.calls.append((siteID, typeID, title, slug, fieldValues))
            return .created(filePath: "src/content/bookmarks/example.md", identifier: "example")
        }
        try await TypedContentOverride.$scoped.withValue(creator) {
            try await LinkMetadataOverride.$scoped.withValue({ _ in LinkMetadata(title: "Fetched Title") }) {
                var intent = AddLinkPostIntent()
                intent.site = entity()
                intent.url = URL(string: "https://example.com/post")!
                intent.commentary = "Neat."
                intent.publish = false
                _ = try await intent.perform()
            }
        }
        let call = try #require(recorder.calls.first)
        #expect(call.typeID == "bookmark")
        #expect(call.title == "Fetched Title")
        #expect(call.fieldValues["bookmarkOf"] == "https://example.com/post")
        #expect(call.fieldValues["body"] == "Neat.")
        #expect(call.fieldValues["draft"] == "true")
    }

    @Test("publish=true writes draft=false; explicit title skips the fetch")
    func publishAndExplicitTitle() async throws {
        let recorder = Recorder()
        let creator: ContentCreationWorkflow.TypedSlugCreator = { siteID, typeID, title, slug, fieldValues, _ in
            recorder.calls.append((siteID, typeID, title, slug, fieldValues))
            return .created(filePath: "src/content/bookmarks/x.md", identifier: "x")
        }
        try await TypedContentOverride.$scoped.withValue(creator) {
            try await LinkMetadataOverride.$scoped.withValue({ _ in
                Issue.record("must not fetch when a title is supplied")
                return LinkMetadata()
            }) {
                var intent = AddLinkPostIntent()
                intent.site = entity()
                intent.url = URL(string: "https://example.com/post")!
                intent.title2 = "My Title"
                intent.publish = true
                _ = try await intent.perform()
            }
        }
        let call = try #require(recorder.calls.first)
        #expect(call.title == "My Title")
        #expect(call.fieldValues["draft"] == "false")
        #expect(call.fieldValues["body"] == "")  // no commentary → explicit empty body, never the placeholder
    }

    @Test("fetch failure still creates, with an empty title")
    func fetchFailureProceeds() async throws {
        let recorder = Recorder()
        let creator: ContentCreationWorkflow.TypedSlugCreator = { siteID, typeID, title, slug, fieldValues, _ in
            recorder.calls.append((siteID, typeID, title, slug, fieldValues))
            return .created(filePath: "src/content/bookmarks/y.md", identifier: "y")
        }
        try await TypedContentOverride.$scoped.withValue(creator) {
            try await LinkMetadataOverride.$scoped.withValue({ _ in
                throw LinkMetadataFetchError(reason: "offline")
            }) {
                var intent = AddLinkPostIntent()
                intent.site = entity()
                intent.url = URL(string: "https://example.com/post")!
                _ = try await intent.perform()
            }
        }
        #expect(recorder.calls.first?.title == "")
    }

    @Test("dialog wording is honest about draft vs published-pending-deploy")
    func dialogs() {
        let ok = ContentCreateResult.created(filePath: "src/content/bookmarks/z.md", identifier: "z")
        #expect(LinkPostDialogs.created(ok, siteName: "My Site", published: false)
            == "Saved a link post draft on My Site.")
        #expect(LinkPostDialogs.created(ok, siteName: "My Site", published: true)
            == "Published a link post to My Site — it goes live with the site’s next deploy.")
        #expect(LinkPostDialogs.created(.failed(reason: "boom"), siteName: "My Site", published: false)
            == "Couldn’t add that link post to My Site: boom")
    }
}
```

Append to `WindowRouterTests.swift` (mirror its existing request/clear test shape):

```swift
@Test("quick-capture request sets and clears")
func quickCaptureRequest() {
    let router = WindowRouter()
    #expect(router.quickCaptureRequested == false)
    router.requestQuickCapture()
    #expect(router.quickCaptureRequested == true)
    router.clearQuickCaptureRequest()
    #expect(router.quickCaptureRequested == false)
}
```

(If `WindowRouter`'s initializer is not accessible to tests, follow whatever the existing tests in that file do — they exist, so mirror their construction exactly.)

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path . --filter LinkPostIntentTests`
Expected: FAIL to compile — `AddLinkPostIntent`, `TypedContentOverride`, `LinkMetadataOverride`, `LinkPostDialogs` not defined.

- [ ] **Step 3: Implement `LinkPostIntent.swift`**

```swift
import AppIntents
import Foundation
import AnglesiteCore

/// Test-only escape hatch for the typed create path, mirroring `ContentOperationsOverride` —
/// which can't carry `fieldValues` (its protocol witness is title-only), so the link-post intent
/// gets its own seam typed as the workflow's `TypedSlugCreator`.
public enum TypedContentOverride {
    @TaskLocal public static var scoped: ContentCreationWorkflow.TypedSlugCreator?
}

/// Test-only escape hatch for the metadata fetch, so intent tests never touch the network.
public enum LinkMetadataOverride {
    @TaskLocal public static var scoped: (@Sendable (URL) async throws -> LinkMetadata)?
}

/// Creates a link post — an entry in the site's `bookmarks` collection — from a URL (#531).
/// "Post link to <site>" from Shortcuts/Siri; also the interim share-sheet story until the
/// real share extension lands (spec §5).
public struct AddLinkPostIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add Link Post"
    public static let description = IntentDescription(
        "Create a link post (bookmark) for a web page on a site with Anglesite.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "URL", description: "The web page the link post points at.")
    public var url: URL
    /// Named `title2` because `title` collides with the `AppIntent.title` static — same
    /// workaround as `AddPostIntent`; presents as "Title".
    @Parameter(title: "Title", description: "Optional title. Fetched from the page when omitted.")
    public var title2: String?
    @Parameter(title: "Commentary", description: "Optional commentary shown as the post body.")
    public var commentary: String?
    @Parameter(title: "Publish", description: "Publish immediately instead of saving a draft.", default: false)
    public var publish: Bool

    @Dependency private var content: ContentCreationWorkflow

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Add link post for \(\.$url) to \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<PostEntity?> {
        let urlString = url.absoluteString
        guard ContentFieldValidation.isAbsoluteURL(urlString) else {
            return .result(value: nil, dialog: IntentDialog(stringLiteral: LinkPostDialogs.invalidURL))
        }

        var resolvedTitle = (title2 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedTitle.isEmpty {
            // Best-effort: a page with no reachable metadata still captures (spec §6).
            let fetch = LinkMetadataOverride.scoped
                ?? { try await LinkMetadataFetcher().fetch(url: $0) }
            resolvedTitle = (try? await fetch(url))?.title ?? ""
        }

        // `body` is always supplied — commentary text, or "" meaning "no body" — so a published
        // link post never contains the scaffold's placeholder text (Task 3's supplied-but-empty
        // rule; same contract as the app path's `QuickCapture.fieldValues`).
        let fieldValues = [
            "bookmarkOf": urlString,
            "draft": publish ? "false" : "true",
            "body": (commentary ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
        ]

        // Native in-process write — fast, no server spawn — so no LongRunningIntent gating is
        // needed here, unlike AddPage/AddPost (whose comment predates the native path).
        let result: ContentCreateResult
        if let scoped = TypedContentOverride.scoped {
            result = await scoped(site.id, "bookmark", resolvedTitle, nil, fieldValues, nil)
        } else {
            result = await content.createTyped(
                siteID: site.id, typeID: "bookmark", title: resolvedTitle,
                slug: nil, fieldValues: fieldValues)
        }
        return .result(
            value: Self.createdLinkPost(result, siteID: site.id, title: resolvedTitle),
            dialog: IntentDialog(stringLiteral: LinkPostDialogs.created(
                result, siteName: site.displayName, published: publish))
        )
    }

    /// Reconstruct the created entry as a ``PostEntity`` in the bookmarks collection.
    static func createdLinkPost(_ result: ContentCreateResult, siteID: String, title: String) -> PostEntity? {
        guard case let .created(_, identifier) = result else { return nil }
        return PostEntity(
            id: "\(siteID):post:\(identifier)",
            displayName: title.isEmpty ? identifier : title,
            slug: identifier, collection: "bookmarks", siteID: siteID)
    }
}

/// Spoken/dialog strings for the link-post intent — pure static formatters, unit-testable
/// without the AppIntents runtime, matching `ContentDialogs`' pattern.
public enum LinkPostDialogs {
    public static let invalidURL =
        "That doesn’t look like a web address. Try a full link like https://example.com/post."

    public static func created(_ result: ContentCreateResult, siteName: String, published: Bool) -> String {
        switch result {
        case .created:
            return published
                ? "Published a link post to \(siteName) — it goes live with the site’s next deploy."
                : "Saved a link post draft on \(siteName)."
        case .siteNotFound:
            return "\(siteName) isn’t available right now."
        case .failed(let reason):
            return "Couldn’t add that link post to \(siteName): \(reason)"
        }
    }
}
```

- [ ] **Step 4: Register the concrete workflow in `Bootstrap.swift`**

Replace the existing `ContentOperationsService` registration block:

```swift
// Before:
AppDependencyManager.shared.add { () -> any ContentOperationsService in
    let siteDirectory: ContentCreationWorkflow.SiteDirectoryResolver = { id in
        await SiteStore.shared.find(id: id)?.sourceDirectory
    }
    return ContentCreationWorkflow.native(
        contentGraph: contentGraph,
        siteDirectory: siteDirectory
    )
}

// After — one shared instance, registered under both types so `AddLinkPostIntent`'s
// `@Dependency var content: ContentCreationWorkflow` can reach the fieldValues-capable
// createTyped that the title-only protocol witness can't express (#531):
let contentSiteDirectory: ContentCreationWorkflow.SiteDirectoryResolver = { id in
    await SiteStore.shared.find(id: id)?.sourceDirectory
}
let contentWorkflow = ContentCreationWorkflow.native(
    contentGraph: contentGraph,
    siteDirectory: contentSiteDirectory
)
AppDependencyManager.shared.add { () -> any ContentOperationsService in contentWorkflow }
AppDependencyManager.shared.add { () -> ContentCreationWorkflow in contentWorkflow }
```

(Keep the existing "Content create intents (A.5 #139)…" comment above the block.)

- [ ] **Step 5: Add the quick-capture request to `WindowRouter.swift`**

Next to `newSiteRequested` (line ~70), following its exact pattern and comment style:

```swift
/// True while a File ▸ New Link Post… issued with no site window focused is waiting for the
/// launcher to present the quick-capture sheet (#531). Same request/clear contract as
/// `newSiteRequested` above.
public private(set) var quickCaptureRequested = false
public func requestQuickCapture() { quickCaptureRequested = true }
public func clearQuickCaptureRequest() { quickCaptureRequested = false }
```

- [ ] **Step 6: Run to verify pass**

Run: `swift test --package-path . --filter LinkPostIntentTests && swift test --package-path . --filter WindowRouterTests`
Expected: PASS. Then run the whole intents suite: `swift test --package-path . --filter AnglesiteIntentsTests` — no regressions (the bootstrap change keeps the same instance semantics).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteIntents/LinkPostIntent.swift Sources/AnglesiteIntents/Bootstrap.swift Sources/AnglesiteIntents/WindowRouter.swift Tests/AnglesiteIntentsTests/LinkPostIntentTests.swift Tests/AnglesiteIntentsTests/WindowRouterTests.swift
git commit -m "feat(#531): add AddLinkPostIntent + quick-capture router request"
```

---

### Task 5: `QuickCaptureSheet` + site-window wiring + menu commands

**Files:**
- Create: `Sources/AnglesiteApp/QuickCaptureSheet.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift` (presentation state + `createLinkPost`), `Sources/AnglesiteApp/SiteWindow.swift` (sheet + focused-value action), `Sources/AnglesiteApp/FocusedSite.swift` (`NewContentActions` + File-menu item), `Sources/AnglesiteApp/PageCommands.swift` (Page-menu item)

**Interfaces:**
- Consumes: `LinkMetadataFetcher.fetch(url:)`, `LinkMetadata`, `ContentFieldValidation.isAbsoluteURL`, `SiteWindowModel.contentCreation.createTyped(...fieldValues:)`, `registerContentUndo`/`refreshAfterContentMutation`/`createdContents` (existing, see `createCollectionEntry` at `SiteWindowModel.swift:1649-1670`), `ContentUndoCoordinator.createActionName`, `WindowRouter.requestQuickCapture()` (Task 4).
- Produces (Task 6 consumes all of these):
  - `struct QuickCaptureSheet: View` with `init(pickerSites: [SiteStore.Site]?, defaultSiteID: String?, initialURLString: String, fetchMetadata: @escaping @Sendable (URL) async throws -> LinkMetadata, onCreate: @escaping (_ siteID: String?, _ title: String, _ urlString: String, _ commentary: String, _ draft: Bool) async -> ContentCreateResult)`
  - `enum QuickCapture` with `@MainActor static func clipboardURLString() -> String?`, `static func webURL(from urls: [URL]) -> URL?`, `static func fieldValues(urlString:commentary:draft:) -> [String: String]`, `static func createLinkPost(siteID:title:urlString:commentary:draft:) async -> ContentCreateResult` (windowless).
  - `SiteWindowModel.quickCapturePresented: Bool`, `quickCaptureURL: String?`, `func createLinkPost(title:urlString:commentary:draft:) async -> ContentCreateResult`
  - `NewContentActions.newLinkPost: @MainActor () -> Void`

- [ ] **Step 1: Create `QuickCaptureSheet.swift`**

```swift
import SwiftUI
import AppKit
import AnglesiteCore

/// Quick-capture compose sheet (#531): URL + fetched title + commentary become an entry in the
/// site's `bookmarks` collection, saved as a draft or published. Presented from a site window
/// (fixed site), the launcher (site picker), or File ▸ New Link Post….
struct QuickCaptureSheet: View {
    /// Sites for the picker, or nil when the sheet is bound to one site (site-window flow).
    let pickerSites: [SiteStore.Site]?
    let fetchMetadata: @Sendable (URL) async throws -> LinkMetadata
    /// `siteID` is the picker selection (nil in the site-window flow, which ignores it).
    let onCreate: (_ siteID: String?, _ title: String, _ urlString: String, _ commentary: String, _ draft: Bool) async -> ContentCreateResult

    @Environment(\.dismiss) private var dismiss
    @State private var urlString: String
    @State private var title = ""
    @State private var commentary = ""
    @State private var selectedSiteID: String?
    @State private var isFetching = false
    @State private var fetchFailed = false
    /// The URL whose fetch already ran (successfully or not) — dedupes the `.task(id:)` restart.
    @State private var fetchedURLString: String?
    @State private var isCreating = false
    @State private var errorMessage: String?

    init(
        pickerSites: [SiteStore.Site]?,
        defaultSiteID: String?,
        initialURLString: String,
        fetchMetadata: @escaping @Sendable (URL) async throws -> LinkMetadata,
        onCreate: @escaping (_ siteID: String?, _ title: String, _ urlString: String, _ commentary: String, _ draft: Bool) async -> ContentCreateResult
    ) {
        self.pickerSites = pickerSites
        self.fetchMetadata = fetchMetadata
        self.onCreate = onCreate
        _urlString = State(initialValue: initialURLString)
        _selectedSiteID = State(initialValue: defaultSiteID ?? pickerSites?.first?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Link Post") {
                    TextField("URL", text: $urlString, prompt: Text(verbatim: "https://example.com/article"))
                    HStack {
                        TextField("Title", text: $title, prompt: Text("optional"))
                        if isFetching {
                            ProgressView().controlSize(.small)
                        }
                    }
                    TextField("Commentary", text: $commentary, axis: .vertical)
                        .lineLimit(3...8)
                    if let pickerSites {
                        Picker("Site", selection: $selectedSiteID) {
                            ForEach(pickerSites, id: \.id) { site in
                                Text(site.name).tag(Optional(site.id))
                            }
                        }
                    }
                    if hasMalformedURL {
                        Text("Enter an absolute URL, e.g. https://example.com/article")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if fetchFailed {
                        Text("Couldn't fetch the page's info — you can still add your own title.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 460, minHeight: 300)
            .navigationTitle("New Link Post")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Save Draft") { create(draft: true) }
                        .disabled(!canCreate)
                    Button(isCreating ? "Working…" : "Publish") { create(draft: false) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canCreate)
                }
            }
        }
        // Fetch (debounced) whenever the URL settles on a new valid value; the title stays
        // editable throughout and a user-typed title is never overwritten (spec §4.1/§4.2).
        .task(id: urlString) {
            let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ContentFieldValidation.isAbsoluteURL(trimmed),
                  trimmed != fetchedURLString,
                  let url = URL(string: trimmed) else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isFetching = true
            fetchFailed = false
            defer { isFetching = false }
            do {
                let metadata = try await fetchMetadata(url)
                fetchedURLString = trimmed
                if title.isEmpty, let fetched = metadata.title { title = fetched }
            } catch {
                fetchedURLString = trimmed
                fetchFailed = true
            }
        }
    }

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasMalformedURL: Bool {
        !trimmedURL.isEmpty && !ContentFieldValidation.isAbsoluteURL(trimmedURL)
    }

    private var canCreate: Bool {
        !isCreating
            && ContentFieldValidation.isAbsoluteURL(trimmedURL)
            && (pickerSites == nil || selectedSiteID != nil)
    }

    private func create(draft: Bool) {
        let cleanURL = trimmedURL
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCommentary = commentary.trimmingCharacters(in: .whitespacesAndNewlines)
        isCreating = true
        errorMessage = nil
        Task {
            let result = await onCreate(selectedSiteID, cleanTitle, cleanURL, cleanCommentary, draft)
            await MainActor.run {
                isCreating = false
                switch result {
                case .created:
                    dismiss()
                case .siteNotFound:
                    errorMessage = "This site is no longer available."
                case .failed(let reason):
                    errorMessage = reason
                }
            }
        }
    }
}

/// Shared quick-capture plumbing used by the sheet's presenters (#531).
enum QuickCapture {
    /// A web URL currently on the general pasteboard, or nil. Only http(s) — a file path or
    /// mailto: on the clipboard must not open the compose sheet.
    @MainActor
    static func clipboardURLString() -> String? {
        let pasteboard = NSPasteboard.general
        let candidate = (pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate,
              candidate.hasPrefix("http://") || candidate.hasPrefix("https://"),
              ContentFieldValidation.isAbsoluteURL(candidate) else { return nil }
        return candidate
    }

    /// First http(s) URL in a drop payload, or nil (lets `.anglesite` package drops pass through).
    static func webURL(from urls: [URL]) -> URL? {
        urls.first { $0.scheme == "http" || $0.scheme == "https" }
    }

    /// The `fieldValues` a link post writes through `createTyped`. `body` is always supplied —
    /// the commentary text, or "" meaning "no body" — because an *absent* key keeps
    /// `renderEntry`'s "Write your bookmark here." placeholder, which must never reach a
    /// published post (Task 3's supplied-but-empty rule).
    static func fieldValues(urlString: String, commentary: String, draft: Bool) -> [String: String] {
        [
            "bookmarkOf": urlString,
            "draft": draft ? "true" : "false",
            // Always supplied: commentary text, or "" meaning "no body" — never the
            // "Write your bookmark here." placeholder (Task 3's supplied-but-empty rule).
            "body": commentary,
        ]
    }

    /// Windowless create for the launcher flow: same native path the intents use
    /// (`Bootstrap.swift`'s resolver), no content graph (the site has no open window to
    /// refresh; an open window's file watcher picks the new file up on its own).
    static func createLinkPost(
        siteID: String, title: String, urlString: String, commentary: String, draft: Bool
    ) async -> ContentCreateResult {
        let workflow = ContentCreationWorkflow.native(
            contentGraph: nil,
            siteDirectory: { id in await SiteStore.shared.find(id: id)?.sourceDirectory }
        )
        return await workflow.createTyped(
            siteID: siteID, typeID: "bookmark", title: title, slug: nil,
            fieldValues: fieldValues(urlString: urlString, commentary: commentary, draft: draft))
    }
}
```

Note the `fieldValues` decision embedded above: **`body` is always supplied** (commentary or `""`), so a published link post never contains the scaffold placeholder. The intent (Task 4) follows the same rule.

- [ ] **Step 2: Add model state + `createLinkPost` to `SiteWindowModel.swift`**

Next to `newPostPresented` (line ~225):

```swift
var quickCapturePresented = false
/// URL pre-fill for the quick-capture sheet — set by the drop/paste/menu entry points
/// immediately before flipping `quickCapturePresented` (#531).
var quickCaptureURL: String?
```

Next to `createCollectionEntry` (line ~1649), following its exact shape:

```swift
/// See `createPage`'s force-refresh note (#586) — same race, same fix.
func createLinkPost(title: String, urlString: String, commentary: String, draft: Bool) async -> ContentCreateResult {
    guard let site else { return .siteNotFound }
    let result = await contentCreation.createTyped(
        siteID: site.id,
        typeID: "bookmark",
        title: title,
        slug: nil,
        fieldValues: QuickCapture.fieldValues(urlString: urlString, commentary: commentary, draft: draft)
    )
    if case .created(let filePath, _) = result {
        await refreshAfterContentMutation()
        registerContentUndo(
            actionName: ContentUndoCoordinator.createActionName("Link Post"),
            relativePath: filePath, before: nil, after: createdContents(at: filePath))
    }
    return result
}
```

- [ ] **Step 3: Wire the sheet + focused action in `SiteWindow.swift`**

After the `newComponentPresented` sheet (line ~958):

```swift
.sheet(isPresented: $bindableModel.quickCapturePresented) {
    QuickCaptureSheet(
        pickerSites: nil,
        defaultSiteID: nil,
        initialURLString: model.quickCaptureURL ?? "",
        fetchMetadata: { try await LinkMetadataFetcher().fetch(url: $0) },
        onCreate: { _, title, urlString, commentary, draft in
            let result = await model.createLinkPost(
                title: title, urlString: urlString, commentary: commentary, draft: draft)
            // Publish = create + the normal deploy path. deploySite() no-ops via its
            // canRunDeploy guard when the runtime isn't available — the entry is already
            // written draft: false and goes live with the next deploy (spec §3.3).
            if case .created = result, !draft { model.deploySite() }
            return result
        }
    )
}
```

In `focusedValues(for:)` (line ~946), extend the `NewContentActions` construction:

```swift
.focusedSceneValue(\.newContentActions, model.site == nil ? nil : NewContentActions(
    newPage: { model.newPagePresented = true },
    newCollection: { model.newCollectionPresented = true },
    newPost: { model.newPostPresented = true },
    newComponent: { model.newComponentPresented = true },
    newLinkPost: {
        model.quickCaptureURL = QuickCapture.clipboardURLString()
        model.quickCapturePresented = true
    }
))
```

`LinkMetadataFetcher` requires `import AnglesiteCore` — already imported in `SiteWindow.swift`.

- [ ] **Step 4: `NewContentActions` + menus in `FocusedSite.swift` and `PageCommands.swift`**

`FocusedSite.swift` — add the field (struct at line ~11):

```swift
struct NewContentActions {
    let newPage: @MainActor () -> Void
    let newCollection: @MainActor () -> Void
    let newPost: @MainActor () -> Void
    let newComponent: @MainActor () -> Void
    let newLinkPost: @MainActor () -> Void
}
```

`FocusedSite.swift` — in `NewContentCommands` (line ~68), add a focused-value property and the always-available File-menu item after "New Community…":

```swift
struct NewContentCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.newContentActions) private var newContentActions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Site…") {
                openWindow(id: "sites")
                WindowRouter.shared.requestNewSite()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("New Community…") {
                openWindow(id: "sites")
                WindowRouter.shared.requestNewCommunity()
            }

            // Quick capture (#531): with a site window focused, open its compose sheet;
            // with none, route through the launcher, which shows the site picker. Always
            // enabled — capture is the app's highest-frequency verb for link bloggers.
            Button("New Link Post…") {
                if let actions = newContentActions {
                    actions.newLinkPost()
                } else {
                    openWindow(id: "sites")
                    WindowRouter.shared.requestQuickCapture()
                }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("Open Site…") {
                Task { await openSiteFromMenu() }
            }
            .keyboardShortcut("o")
        }
    }
    // openSiteFromMenu() unchanged
}
```

`PageCommands.swift` — after the "New Post…" button:

```swift
Button("New Link Post…") {
    actions?.newLinkPost()
}
.disabled(actions == nil)
```

(No shortcut here — ⇧⌘L belongs to the always-available File item; a duplicate shortcut on two menu items is an AppKit conflict.)

- [ ] **Step 5: Build to verify**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`. Compile errors about the `NewContentActions` memberwise init mean another construction site exists — grep `NewContentActions(` and add `newLinkPost:` there too.

Also run: `swift test --package-path .` — the app target isn't in SwiftPM, but this confirms no Core/Intents regressions.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/QuickCaptureSheet.swift Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/FocusedSite.swift Sources/AnglesiteApp/PageCommands.swift
git commit -m "feat(#531): quick-capture compose sheet + menu commands"
```

---

### Task 6: Drag/paste entry points — site window + launcher

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (drop + paste), `Sources/AnglesiteApp/SitesLauncherView.swift` (drop + paste + router request + sheet)

**Interfaces:**
- Consumes: everything Task 5 produced, `WindowRouter.quickCaptureRequested`/`clearQuickCaptureRequest()` (Task 4), the launcher's existing `sites` state and `.dropDestination` handler (`SitesLauncherView.swift:241`), `AppSettings.shared` (verify the exact last-opened-site property name with `grep -n "lastOpened" Sources/AnglesiteCore/AppSettings.swift` before using it).
- Produces: user-visible entry points; no new API.

- [ ] **Step 1: Site-window drop + paste (`SiteWindow.swift`)**

On the same view chain that carries the sheets (immediately after the `.sheet(isPresented: $bindableModel.quickCapturePresented)` modifier from Task 5):

```swift
// Drag a link anywhere onto the site window → quick capture for this site (#531).
// File URLs (image drops onto the preview, .anglesite packages) don't match and
// fall through to their existing handlers.
.dropDestination(for: URL.self) { urls, _ in
    guard let web = QuickCapture.webURL(from: urls) else { return false }
    model.quickCaptureURL = web.absoluteString
    model.quickCapturePresented = true
    return true
}
// Edit ▸ Paste with a URL on the clipboard, while focus sits in the navigator/preview
// chrome (not a text field — those take their own paste). Scoped to the URL flavor so
// pasting prose never hijacks (#531). Reads the pasteboard directly: the provider
// payload and the pasteboard agree here, and clipboardURLString is the one gate.
.onPasteCommand(of: [.url]) { _ in
    guard let urlString = QuickCapture.clipboardURLString() else { return }
    model.quickCaptureURL = urlString
    model.quickCapturePresented = true
}
```

`UTType.url` needs `import UniformTypeIdentifiers` if `SiteWindow.swift` lacks it (check the imports; `.url` in `onPasteCommand(of:)` is `UTType.url`).

- [ ] **Step 2: Launcher drop + paste + router + sheet (`SitesLauncherView.swift`)**

Add state next to `isDropTargeted` (line ~26):

```swift
/// Non-nil while the quick-capture compose sheet is up (launcher flow, #531); carries the
/// dropped/pasted URL pre-fill ("" for the menu path with no URL on the clipboard).
@State private var quickCaptureRequest: QuickCaptureRequest?

private struct QuickCaptureRequest: Identifiable {
    let id = UUID()
    let urlString: String
}
```

Extend the existing `.dropDestination` handler (line ~241) — web URLs first, packages unchanged:

```swift
.dropDestination(for: URL.self) { urls, _ in
    // A link dragged from a browser → quick capture with the site picker (#531).
    if let web = QuickCapture.webURL(from: urls) {
        quickCaptureRequest = QuickCaptureRequest(urlString: web.absoluteString)
        return true
    }
    let packages = urls.filter { $0.pathExtension == AnglesitePackage.packageExtension }
    guard !packages.isEmpty else { return false }
    // … existing package-registration body unchanged …
}
```

Add alongside the other modifiers on the same chain as the `.onChange(of: router.newSiteRequested)` (line ~84):

```swift
.onChange(of: router.quickCaptureRequested) { _, requested in
    guard requested else { return }
    router.clearQuickCaptureRequest()
    quickCaptureRequest = QuickCaptureRequest(urlString: QuickCapture.clipboardURLString() ?? "")
}
.onPasteCommand(of: [.url]) { _ in
    guard let urlString = QuickCapture.clipboardURLString() else { return }
    quickCaptureRequest = QuickCaptureRequest(urlString: urlString)
}
.sheet(item: $quickCaptureRequest) { request in
    QuickCaptureSheet(
        pickerSites: sites,
        defaultSiteID: AppSettings.shared.lastOpenedSiteID,  // verify property name first
        initialURLString: request.urlString,
        fetchMetadata: { try await LinkMetadataFetcher().fetch(url: $0) },
        onCreate: { siteID, title, urlString, commentary, draft in
            guard let siteID else { return .failed(reason: "Choose a site for this link post.") }
            // Windowless: the entry is written and committed; a Publish here saves it
            // draft: false and it goes live with the site's next deploy (spec §3.3 —
            // capture never boots a container).
            return await QuickCapture.createLinkPost(
                siteID: siteID, title: title, urlString: urlString,
                commentary: commentary, draft: draft)
        }
    )
}
```

Before using `AppSettings.shared.lastOpenedSiteID`, verify: `grep -n "lastOpened" Sources/AnglesiteCore/AppSettings.swift Sources/AnglesiteApp/*.swift` — use whatever property the launcher's own MRU autoopen reads (`onFirstAppear()` in this same file uses it); pass `nil` if it's an ID type mismatch. `import AnglesiteCore` is already present; add `import UniformTypeIdentifiers` if `.url` doesn't resolve.

- [ ] **Step 3: Build to verify**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Manual smoke test (run the app)**

Launch the built app (or via Xcode). Verify:
1. File ▸ New Link Post… (⇧⌘L) opens the compose sheet — from a site window (no picker) and from the launcher-only state (picker shown).
2. Drag a link from Safari onto a site window and onto the launcher → sheet opens pre-filled; title populates after a beat.
3. Save Draft on a real site → `Source/src/content/bookmarks/<slug>.md` exists with `draft: true`, `bookmarkOf`, and the commentary body; the navigator shows it; ⌘Z removes it.
4. Publish with the runtime up → deploy drawer activity starts.
5. Paste (⌘V) with a copied link while the navigator has focus → sheet opens. Paste inside the editor still pastes text normally.

Record any deviations; fix before committing.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/SitesLauncherView.swift
git commit -m "feat(#531): URL drag/paste entry points on window + launcher"
```

---

### Task 7: Localization catalog, full verification, build-plan note

**Files:**
- Modify: `Sources/AnglesiteApp/Localizable.xcstrings` (generated merge — review, don't hand-edit), `docs/build-plan.md` (move #531 out of the deferred list; one line)

**Interfaces:** none — verification and bookkeeping.

- [ ] **Step 1: Sync the String Catalog**

New user-visible strings were added (sheet labels, menu items, error copy). Per CONTRIBUTING ▸ "Commit String Catalog updates" — CLI builds don't merge the catalog, so run the documented recipe, **scoped to this worktree's own BUILD_DIR**:

```bash
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
BUILD_DIR=$(xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILD_DIR =/{print $3}')
xcrun xcstringstool sync Sources/AnglesiteApp/Localizable.xcstrings \
  --stringsdata $(find "$(dirname "$BUILD_DIR")/Intermediates.noindex/Anglesite.build/Debug/Anglesite.build/Objects-normal/arm64" -name "*.stringsdata") \
  --skip-marking-strings-stale
git diff --stat Sources/AnglesiteApp/Localizable.xcstrings
```

Review the diff: it must contain **only keys added by this branch** (New Link Post…, URL, Title, Commentary, Save Draft, Publish, the two inline hints, the three error strings). Keys you didn't add → discard the diff and re-run scoped correctly (see CONTRIBUTING's warning about sibling-worktree contamination).

- [ ] **Step 2: Update `docs/build-plan.md`**

Find the deferred/v2.0 line listing `#531` (around line 173) and move/annotate it as landed, matching the file's existing phrasing for completed items.

- [ ] **Step 3: Full verification**

```bash
swift test --package-path . 2>&1 | tail -5
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -5
```

Expected: all suites pass; BUILD SUCCEEDED. If `swift test` hangs silently, check `pgrep -fl swift-test` for a stale lock-holder (per CLAUDE.md).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/Localizable.xcstrings docs/build-plan.md
git commit -m "chore(#531): sync string catalog + build-plan note"
```

---

## After the plan

- Use superpowers:finishing-a-development-branch. The PR body must use `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (**Summary**, **Paired PR check**, **Test plan**) with `Closes #531`. Paired-PR check: **none needed** — no MCP schema change; template untouched.
- File the two follow-up issues from spec §8 (share extension; og:image capture) referencing #531 and the spec.

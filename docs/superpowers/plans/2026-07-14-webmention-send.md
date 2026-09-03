# Webmention Send on Publish Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send webmentions for a site's outbound links automatically after every successful deploy, without depending on the still-unpublished `@dwk/workers` package.

**Architecture:** Four new pure/testable types in `AnglesiteCore` — `WebmentionEndpointDiscovery` (fetch + parse a target's declared endpoint), `WebmentionSender` (discover + POST one pair), `WebmentionSentLog` (per-site `Config/webmention-sent.json` persistence + pending-pair diff), `WebmentionSendCommand` (actor orchestrator tying the above to the existing `SocialPublishPlan`) — wired into `DeployModel.runDeploy`'s `.succeeded` case as a fire-and-forget background task.

**Tech Stack:** Swift 6 / Foundation only (`URLSession`, `NSRegularExpression`) — no new package dependencies, matching CLAUDE.md's "no frameworks beyond Apple's" rule. Swift Testing (`@Suite`/`@Test`/`#expect`), matching the rest of `AnglesiteCoreTests`.

## Global Constraints

- No new SwiftPM dependencies — hand-roll HTML/Link-header parsing with `NSRegularExpression`, matching `SocialPublishPlan.swift`'s existing style.
- All networking goes through an injectable `@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)` closure (named `Transport`), matching `CloudflareAPITokenVerifier.Transport` exactly — no real network calls in the unit test suite.
- Every file that imports `URLSession`/`URLRequest`/`HTTPURLResponse` must guard the Linux import: `#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif` (see `HTTPTransport.swift`, `CloudflareAPITokenVerifier.swift`).
- `Config/webmention-sent.json` is app-owned, per-site state — never write it anywhere but the `configDirectory` passed in, and never add it to the site's git repo.
- A failed send must never be recorded as sent, so it is retried automatically on the next deploy — no separate retry/backoff logic.
- The webmention send pass must never affect deploy success/failure or block the `.succeeded` phase transition users see.
- Full spec: [`docs/superpowers/specs/2026-07-14-webmention-send-design.md`](../specs/2026-07-14-webmention-send-design.md).

---

### Task 1: `WebmentionEndpointDiscovery`

**Files:**
- Create: `Sources/AnglesiteCore/WebmentionEndpointDiscovery.swift`
- Test: `Tests/AnglesiteCoreTests/WebmentionEndpointDiscoveryTests.swift`

**Interfaces:**
- Produces: `WebmentionEndpointDiscovery.Transport` (`public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)`), `WebmentionEndpointDiscovery.discover(target: URL, transport: Transport) async throws -> URL?`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/WebmentionEndpointDiscoveryTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WebmentionEndpointDiscovery")
struct WebmentionEndpointDiscoveryTests {
    private let target = URL(string: "https://target.example/post")!

    private func transport(
        status: Int = 200,
        headers: [String: String] = [:],
        html: String = "",
        responseURL: URL? = nil
    ) -> WebmentionEndpointDiscovery.Transport {
        let url = responseURL ?? target
        return { _ in
            let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(html.utf8), http)
        }
    }

    @Test("discovers via a simple Link header")
    func linkHeaderSimple() async throws {
        let endpoint = try await WebmentionEndpointDiscovery.discover(
            target: target,
            transport: transport(headers: ["Link": "<https://target.example/webmention>; rel=\"webmention\""])
        )
        #expect(endpoint?.absoluteString == "https://target.example/webmention")
    }

    @Test("Link header: webmention rel among multiple link-values")
    func linkHeaderMultipleValues() async throws {
        let endpoint = try await WebmentionEndpointDiscovery.discover(
            target: target,
            transport: transport(headers: [
                "Link": "<https://target.example/pgp>; rel=\"pgp-key\", <https://target.example/wm>; rel=\"webmention\"",
            ])
        )
        #expect(endpoint?.absoluteString == "https://target.example/wm")
    }

    @Test("Link header: unquoted rel value")
    func linkHeaderUnquotedRel() async throws {
        let endpoint = try await WebmentionEndpointDiscovery.discover(
            target: target,
            transport: transport(headers: ["Link": "</test/1/webmention?head=true>; rel=webmention"])
        )
        #expect(endpoint?.absoluteString == "https://target.example/test/1/webmention?head=true")
    }

    @Test("Link header: legacy rel=\"http://webmention.org/\" form")
    func linkHeaderLegacyRel() async throws {
        let endpoint = try await WebmentionEndpointDiscovery.discover(
            target: target,
            transport: transport(headers: ["Link": "<https://target.example/wm>; rel=\"http://webmention.org/\""])
        )
        #expect(endpoint?.absoluteString == "https://target.example/wm")
    }

    @Test("Link header endpoint relative to the response URL")
    func linkHeaderRelative() async throws {
        let endpoint = try await WebmentionEndpointDiscovery.discover(
            target: target,
            transport: transport(headers: ["Link": "</webmention-endpoint>; rel=\"webmention\""])
        )
        #expect(endpoint?.absoluteString == "https://target.example/webmention-endpoint")
    }

    @Test("falls back to an HTML <link rel=webmention> element")
    func htmlLinkElement() async throws {
        let html = """
        <html><head><link rel="stylesheet" href="/style.css">
        <link href="https://target.example/wm-html" rel="webmention"></head></html>
        """
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport(html: html))
        #expect(endpoint?.absoluteString == "https://target.example/wm-html")
    }

    @Test("falls back to an HTML <a rel=webmention> element")
    func htmlAnchorElement() async throws {
        let html = """
        <html><body><a href="https://target.example/wm-a" rel="webmention">webmention</a></body></html>
        """
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport(html: html))
        #expect(endpoint?.absoluteString == "https://target.example/wm-a")
    }

    @Test("HTML: first webmention element in document order wins")
    func htmlDocumentOrder() async throws {
        let html = """
        <html><head><link rel="webmention" href="https://target.example/first"></head>
        <body><a href="https://target.example/second" rel="webmention">webmention</a></body></html>
        """
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport(html: html))
        #expect(endpoint?.absoluteString == "https://target.example/first")
    }

    @Test("HTML endpoint resolved relative to the redirected response URL")
    func htmlRelativeAfterRedirect() async throws {
        let redirected = URL(string: "https://target.example/moved/post")!
        let html = "<link rel=\"webmention\" href=\"../webmention\">"
        let endpoint = try await WebmentionEndpointDiscovery.discover(
            target: target,
            transport: transport(html: html, responseURL: redirected)
        )
        #expect(endpoint?.absoluteString == "https://target.example/webmention")
    }

    @Test("no endpoint declared returns nil")
    func noEndpoint() async throws {
        let html = "<html><body>No webmention here. <a href=\"/other\" rel=\"nofollow\">link</a></body></html>"
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport(html: html))
        #expect(endpoint == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter WebmentionEndpointDiscoveryTests`
Expected: FAIL to compile — `WebmentionEndpointDiscovery` does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/WebmentionEndpointDiscovery.swift`:

```swift
import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Discovers a target URL's declared Webmention receiver endpoint per the webmention.org spec:
/// fetch the target once, prefer an HTTP `Link` header with `rel=webmention` (or the legacy
/// `rel="http://webmention.org/"` form), falling back to the first `<link>` or `<a>` element (in
/// document order) with `rel=webmention` in the HTML body. A relative endpoint URL is resolved
/// against the *final* response URL (after redirects), not the originally-requested target —
/// required for pages like webmention.rocks' redirect test.
public enum WebmentionEndpointDiscovery {
    /// Performs one HTTP request and returns its body + response. Throws on connection failure.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// `nil` means the target declares no Webmention endpoint — not an error condition.
    public static func discover(target: URL, transport: Transport) async throws -> URL? {
        var request = URLRequest(url: target)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, http) = try await transport(request)
        let finalURL = http.url ?? target

        if let linkHeader = http.value(forHTTPHeaderField: "Link"),
           let endpoint = endpoint(fromLinkHeader: linkHeader, relativeTo: finalURL) {
            return endpoint
        }
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        return endpoint(fromHTML: html, relativeTo: finalURL)
    }

    // MARK: Link header

    static func endpoint(fromLinkHeader header: String, relativeTo baseURL: URL) -> URL? {
        for value in splitLinkHeaderValues(header) {
            guard let start = value.firstIndex(of: "<"),
                  let end = value.firstIndex(of: ">"),
                  start < end
            else { continue }
            let urlString = String(value[value.index(after: start)..<end])
            let params = String(value[value.index(after: end)...])
            guard let rel = attributeValue("rel", in: params), isWebmentionRel(rel) else { continue }
            return URL(string: urlString, relativeTo: baseURL)?.absoluteURL
        }
        return nil
    }

    /// Splits a `Link` header on top-level commas — commas inside `<...>` (the URL itself) don't
    /// separate link-values.
    private static func splitLinkHeaderValues(_ header: String) -> [String] {
        var values: [String] = []
        var depth = 0
        var current = ""
        for char in header {
            switch char {
            case "<":
                depth += 1
                current.append(char)
            case ">":
                depth -= 1
                current.append(char)
            case "," where depth == 0:
                values.append(current)
                current = ""
            default:
                current.append(char)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { values.append(current) }
        return values
    }

    // MARK: HTML

    /// Matches `<link ...>` and `<a ...>` tags in document order; the first with a `webmention`
    /// rel wins, per the spec ("the first link or a element ... in document order").
    private static let tagPattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"<(?:link|a)\b([^>]*)>"#, options: [.caseInsensitive])
        } catch {
            fatalError("Invalid webmention discovery tag regex: \(error)")
        }
    }()

    static func endpoint(fromHTML html: String, relativeTo baseURL: URL) -> URL? {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in tagPattern.matches(in: html, range: range) {
            guard let attrsRange = Range(match.range(at: 1), in: html) else { continue }
            let attrs = String(html[attrsRange])
            guard let rel = attributeValue("rel", in: attrs), isWebmentionRel(rel) else { continue }
            guard let href = attributeValue("href", in: attrs) else { continue }
            if let url = URL(string: href, relativeTo: baseURL)?.absoluteURL {
                return url
            }
        }
        return nil
    }

    // MARK: Shared attribute/rel helpers

    private static let legacyWebmentionRels: Set<String> = [
        "http://webmention.org/", "https://webmention.org/",
        "http://webmention.org", "https://webmention.org",
    ]

    private static func isWebmentionRel(_ rel: String) -> Bool {
        rel.split(whereSeparator: { $0.isWhitespace }).contains { token in
            token.caseInsensitiveCompare("webmention") == .orderedSame
                || legacyWebmentionRels.contains(String(token).lowercased())
        }
    }

    /// Extracts `name="value"` / `name='value'` / `name=value` from an HTML tag's attribute
    /// string or an HTTP Link-header parameter string. `\b` before `name` prevents matching
    /// inside a longer attribute name (e.g. `data-rel=` must not match a lookup for `rel`).
    private static func attributeValue(_ name: String, in source: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range) else { return nil }
        for groupIndex in [2, 3, 4] {
            let group = match.range(at: groupIndex)
            if group.location != NSNotFound, let r = Range(group, in: source) {
                return String(source[r])
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter WebmentionEndpointDiscoveryTests`
Expected: PASS (all 10 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WebmentionEndpointDiscovery.swift Tests/AnglesiteCoreTests/WebmentionEndpointDiscoveryTests.swift
git commit -m "$(cat <<'EOF'
Add WebmentionEndpointDiscovery for #354

Discovers a target URL's declared Webmention endpoint via HTTP Link
header or HTML <link>/<a rel=webmention>, per the webmention.org spec.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `WebmentionSender`

**Files:**
- Create: `Sources/AnglesiteCore/WebmentionSender.swift`
- Test: `Tests/AnglesiteCoreTests/WebmentionSenderTests.swift`

**Interfaces:**
- Consumes: `WebmentionEndpointDiscovery.Transport`, `WebmentionEndpointDiscovery.discover(target:transport:)` (Task 1).
- Produces: `WebmentionSendOutcome` (`.sent(endpoint: URL, statusCode: Int)`, `.noEndpointDiscovered`, `.requestFailed(reason: String)`), `WebmentionSender.send(source: URL, target: URL, transport: WebmentionEndpointDiscovery.Transport) async -> WebmentionSendOutcome`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/WebmentionSenderTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WebmentionSender")
struct WebmentionSenderTests {
    private let source = URL(string: "https://mysite.test/posts/hello/")!
    private let target = URL(string: "https://target.example/post")!
    private let endpoint = URL(string: "https://target.example/webmention")!

    private actor CallRecorder {
        private(set) var requests: [URLRequest] = []
        func record(_ request: URLRequest) { requests.append(request) }
    }

    @Test("discovers the endpoint and POSTs source+target, reporting the status code")
    func successfulSend() async throws {
        let recorder = CallRecorder()
        let endpointURL = endpoint
        let targetURL = target
        let outcome = await WebmentionSender.send(source: source, target: target, transport: { request in
            await recorder.record(request)
            if request.httpMethod == "POST" {
                let http = HTTPURLResponse(url: endpointURL, statusCode: 202, httpVersion: nil, headerFields: nil)!
                return (Data(), http)
            }
            let http = HTTPURLResponse(
                url: targetURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Link": "<\(endpointURL.absoluteString)>; rel=\"webmention\""]
            )!
            return (Data(), http)
        })

        #expect(outcome == .sent(endpoint: endpoint, statusCode: 202))
        let requests = await recorder.requests
        #expect(requests.count == 2)
        #expect(requests[1].httpMethod == "POST")
        #expect(requests[1].url == endpoint)
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(data: requests[1].httpBody ?? Data(), encoding: .utf8)
        #expect(body == "source=https%3A%2F%2Fmysite.test%2Fposts%2Fhello%2F&target=https%3A%2F%2Ftarget.example%2Fpost")
    }

    @Test("no discovered endpoint sends no POST")
    func noEndpointSendsNothing() async throws {
        let recorder = CallRecorder()
        let targetURL = target
        let outcome = await WebmentionSender.send(source: source, target: target, transport: { request in
            await recorder.record(request)
            let http = HTTPURLResponse(url: targetURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("<html>no endpoint</html>".utf8), http)
        })
        #expect(outcome == .noEndpointDiscovered)
        let requests = await recorder.requests
        #expect(requests.count == 1) // only the discovery GET, no POST
    }

    @Test("a non-2xx endpoint response maps to .requestFailed")
    func failedPost() async throws {
        let endpointURL = endpoint
        let targetURL = target
        let outcome = await WebmentionSender.send(source: source, target: target, transport: { request in
            if request.httpMethod == "POST" {
                let http = HTTPURLResponse(url: endpointURL, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (Data(), http)
            }
            let http = HTTPURLResponse(
                url: targetURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Link": "<\(endpointURL.absoluteString)>; rel=\"webmention\""]
            )!
            return (Data(), http)
        })
        guard case .requestFailed = outcome else {
            Issue.record("expected .requestFailed, got \(outcome)")
            return
        }
    }

    @Test("a discovery-phase network error maps to .requestFailed")
    func discoveryThrows() async throws {
        struct Boom: Error {}
        let outcome = await WebmentionSender.send(source: source, target: target, transport: { _ in throw Boom() })
        guard case .requestFailed = outcome else {
            Issue.record("expected .requestFailed, got \(outcome)")
            return
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter WebmentionSenderTests`
Expected: FAIL to compile — `WebmentionSendOutcome`/`WebmentionSender` do not exist yet.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/WebmentionSender.swift`:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Outcome of one webmention send attempt for a single (source, target) pair.
public enum WebmentionSendOutcome: Equatable, Sendable {
    case sent(endpoint: URL, statusCode: Int)
    case noEndpointDiscovered
    case requestFailed(reason: String)
}

/// Sends one Webmention: discovers `target`'s declared endpoint via `WebmentionEndpointDiscovery`,
/// then POSTs `source`+`target` form-encoded per the webmention.org spec. No retry logic here —
/// a caller that doesn't record a `.requestFailed` pair as sent gets a free retry on its next
/// pass (see `WebmentionSendCommand`).
public enum WebmentionSender {
    public static func send(
        source: URL,
        target: URL,
        transport: WebmentionEndpointDiscovery.Transport
    ) async -> WebmentionSendOutcome {
        let endpoint: URL?
        do {
            endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport)
        } catch {
            return .requestFailed(reason: "endpoint discovery failed: \(error)")
        }
        guard let endpoint else { return .noEndpointDiscovered }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "source=\(formEncode(source.absoluteString))&target=\(formEncode(target.absoluteString))"
        request.httpBody = Data(body.utf8)

        let http: HTTPURLResponse
        do {
            (_, http) = try await transport(request)
        } catch {
            return .requestFailed(reason: "POST to \(endpoint.absoluteString) failed: \(error)")
        }
        guard (200..<300).contains(http.statusCode) else {
            return .requestFailed(reason: "\(endpoint.absoluteString) returned HTTP \(http.statusCode)")
        }
        return .sent(endpoint: endpoint, statusCode: http.statusCode)
    }

    /// Percent-encodes everything but RFC 3986 unreserved characters, so a source/target URL's
    /// own `:`, `/`, `?`, `&`, `=` can't be mistaken for the outer form body's delimiters.
    private static func formEncode(_ value: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter WebmentionSenderTests`
Expected: PASS (all 4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WebmentionSender.swift Tests/AnglesiteCoreTests/WebmentionSenderTests.swift
git commit -m "$(cat <<'EOF'
Add WebmentionSender for #354

Discovers a target's endpoint and POSTs source+target form-encoded,
per the webmention.org spec. Failures aren't retried here — the
caller's persistence layer decides what to retry.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `WebmentionTargetPair` + `WebmentionSentLog`

**Files:**
- Create: `Sources/AnglesiteCore/WebmentionSentLog.swift`
- Test: `Tests/AnglesiteCoreTests/WebmentionSentLogTests.swift`

**Interfaces:**
- Consumes: `SocialPublishPlan.Plan`, `SocialPublishPlan.Entry` (existing, `Sources/AnglesiteCore/SocialPublishPlan.swift`) — `Plan.entries: [Entry]`, `Entry.canonicalURL: URL`, `Entry.webmentionTargets: [URL]`.
- Produces: `WebmentionTargetPair` (`public struct` with `source: URL`, `target: URL`, `public init(source:target:)`), `WebmentionSentLog` (`public struct`, `Equatable`, `Sendable`) with `Entry` (`source: URL`, `target: URL`, `sentAt: Date`), `static let filename`, `static func load(from: URL) -> WebmentionSentLog?`, `func save(to: URL) throws`, `func pending(in: SocialPublishPlan.Plan) -> [WebmentionTargetPair]`, `func recording(_: [WebmentionTargetPair], now: @escaping () -> Date = Date.init) -> WebmentionSentLog`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/WebmentionSentLogTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WebmentionSentLog")
struct WebmentionSentLogTests {
    private func tempConfigDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebmentionSentLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let source1 = URL(string: "https://mysite.test/posts/a/")!
    private let source2 = URL(string: "https://mysite.test/posts/b/")!
    private let target1 = URL(string: "https://target.example/1")!
    private let target2 = URL(string: "https://target.example/2")!

    @Test("load on a missing file returns nil")
    func loadMissingReturnsNil() throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(WebmentionSentLog.load(from: dir) == nil)
    }

    @Test("save then load round-trips entries")
    func saveLoadRoundTrips() throws {
        let dir = try tempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sentAt = Date(timeIntervalSince1970: 1_782_777_600) // 2026-06-30T00:00:00Z
        let log = WebmentionSentLog(sent: [.init(source: source1, target: target1, sentAt: sentAt)])
        try log.save(to: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("webmention-sent.json").path))
        #expect(WebmentionSentLog.load(from: dir) == log)
    }

    @Test("pending(in:) excludes already-sent pairs and includes new ones")
    func pendingExcludesSentPairs() throws {
        let log = WebmentionSentLog(sent: [
            .init(source: source1, target: target1, sentAt: Date(timeIntervalSince1970: 0)),
        ])
        let plan = SocialPublishPlan.Plan(entries: [
            .init(sourceFile: "a.md", canonicalURL: source1, webmentionTargets: [target1, target2], posseTargets: []),
            .init(sourceFile: "b.md", canonicalURL: source2, webmentionTargets: [target1], posseTargets: []),
        ])
        let pending = log.pending(in: plan)
        #expect(pending == [
            WebmentionTargetPair(source: source1, target: target2),
            WebmentionTargetPair(source: source2, target: target1),
        ])
    }

    @Test("recording(_:now:) appends new entries stamped with the given time")
    func recordingAppendsEntries() throws {
        let stamp = Date(timeIntervalSince1970: 1_782_777_600)
        let log = WebmentionSentLog()
        let updated = log.recording([WebmentionTargetPair(source: source1, target: target1)], now: { stamp })
        #expect(updated.sent == [.init(source: source1, target: target1, sentAt: stamp)])
        #expect(log.sent.isEmpty) // original is untouched — recording() returns a new value
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter WebmentionSentLogTests`
Expected: FAIL to compile — `WebmentionTargetPair`/`WebmentionSentLog` do not exist yet.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/WebmentionSentLog.swift`:

```swift
import Foundation

/// A `(source, target)` webmention pair — the unit `WebmentionSentLog` tracks and
/// `WebmentionSendCommand` sends.
public struct WebmentionTargetPair: Equatable, Sendable {
    public let source: URL
    public let target: URL

    public init(source: URL, target: URL) {
        self.source = source
        self.target = target
    }
}

/// Per-site record of `(source, target)` webmention pairs already sent successfully, persisted at
/// `Config/webmention-sent.json` — app-owned state, never committed to the site's git repo (same
/// place as `DeployedRoutesSnapshot`'s `last-deployed-routes.json`). Lets `WebmentionSendCommand`
/// skip pairs it already notified on a prior deploy, instead of re-pinging every target's
/// endpoint on every redeploy.
public struct WebmentionSentLog: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let source: URL
        public let target: URL
        public let sentAt: Date

        public init(source: URL, target: URL, sentAt: Date) {
            self.source = source
            self.target = target
            self.sentAt = sentAt
        }
    }

    public let sent: [Entry]

    public init(sent: [Entry] = []) {
        self.sent = sent
    }

    public static let filename = "webmention-sent.json"

    private struct Envelope: Codable {
        let sent: [Entry]
    }

    /// `nil` when the file is absent or unreadable — the normal "no prior sends yet" case.
    public static func load(from configDirectory: URL) -> WebmentionSentLog? {
        let url = configDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
        return WebmentionSentLog(sent: envelope.sent)
    }

    public func save(to configDirectory: URL) throws {
        let url = configDirectory.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Envelope(sent: sent))
        try data.write(to: url, options: .atomic)
    }

    /// Pairs from `plan`'s entries not already recorded as sent.
    public func pending(in plan: SocialPublishPlan.Plan) -> [WebmentionTargetPair] {
        let sentKeys = Set(sent.map { pairKey(source: $0.source, target: $0.target) })
        var result: [WebmentionTargetPair] = []
        for entry in plan.entries {
            for target in entry.webmentionTargets {
                let key = pairKey(source: entry.canonicalURL, target: target)
                if !sentKeys.contains(key) {
                    result.append(WebmentionTargetPair(source: entry.canonicalURL, target: target))
                }
            }
        }
        return result
    }

    /// A new log with `pairs` appended, all stamped with the same `now()` timestamp.
    public func recording(
        _ pairs: [WebmentionTargetPair],
        now: @escaping () -> Date = Date.init
    ) -> WebmentionSentLog {
        let timestamp = now()
        let newEntries = pairs.map { Entry(source: $0.source, target: $0.target, sentAt: timestamp) }
        return WebmentionSentLog(sent: sent + newEntries)
    }

    private func pairKey(source: URL, target: URL) -> String {
        "\(source.absoluteString)\n\(target.absoluteString)"
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter WebmentionSentLogTests`
Expected: PASS (all 4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WebmentionSentLog.swift Tests/AnglesiteCoreTests/WebmentionSentLogTests.swift
git commit -m "$(cat <<'EOF'
Add WebmentionSentLog for #354

Per-site Config/webmention-sent.json tracking which (source, target)
webmention pairs already sent successfully, so a redeploy only sends
new pairs instead of re-pinging every target every time.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `WebmentionSendCommand`

**Files:**
- Create: `Sources/AnglesiteCore/WebmentionSendCommand.swift`
- Test: `Tests/AnglesiteCoreTests/WebmentionSendCommandTests.swift`

**Interfaces:**
- Consumes: `SocialPublishPlan.build(projectRoot:siteBase:referenceDate:) throws -> SocialPublishPlan.Plan` (existing), `WebmentionSentLog.load(from:)`/`.pending(in:)`/`.recording(_:now:)`/`.save(to:)` (Task 3), `WebmentionSender.send(source:target:transport:)` (Task 2), `WebmentionEndpointDiscovery.Transport` (Task 1), `LogCenter.append(source:stream:text:timestamp:) async` (existing, `Sources/AnglesiteCore/LogCenter.swift:72`), `LogCenter.snapshot() async -> [LogLine]` (existing, for tests).
- Produces: `WebmentionSendCommand` (`public actor`), `public init(transport: @escaping WebmentionEndpointDiscovery.Transport = WebmentionSendCommand.defaultTransport, logCenter: LogCenter = .shared, now: @escaping () -> Date = Date.init)`, `public func send(siteID: String, siteDirectory: URL, configDirectory: URL, siteBase: URL) async`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/WebmentionSendCommandTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("WebmentionSendCommand")
struct WebmentionSendCommandTests {
    private func makeSite() throws -> (root: URL, siteDirectory: URL, configDirectory: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webmention-send-command-\(UUID().uuidString)", isDirectory: true)
        let siteDirectory = root.appendingPathComponent("Source", isDirectory: true)
        let configDirectory = root.appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let post = siteDirectory.appendingPathComponent("src/content/posts/hello.md")
        try FileManager.default.createDirectory(at: post.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        ---
        publishDate: 2026-06-29
        ---
        Links to https://one.example/target and https://two.example/target.
        """.utf8).write(to: post)
        return (root, siteDirectory, configDirectory)
    }

    /// A transport that reports every target's endpoint as `<target>/webmention`, and accepts
    /// every POST with 202 unless the endpoint's target is listed in `failing`.
    private func transport(failing: Set<String> = []) -> WebmentionEndpointDiscovery.Transport {
        { request in
            let url = request.url!
            if request.httpMethod == "POST" {
                let targetForEndpoint = url.deletingLastPathComponent().absoluteString
                let status = failing.contains(targetForEndpoint) ? 500 : 202
                return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            let endpoint = url.appendingPathComponent("webmention")
            let http = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Link": "<\(endpoint.absoluteString)>; rel=\"webmention\""]
            )!
            return (Data(), http)
        }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    @Test("sends every pending target and persists them to the sent log")
    func sendsAndPersists() async throws {
        let (root, siteDirectory, configDirectory) = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        let logCenter = LogCenter()
        let command = WebmentionSendCommand(
            transport: transport(),
            logCenter: logCenter,
            now: { Date(timeIntervalSince1970: 1_782_777_600) }
        )

        await command.send(
            siteID: "site1",
            siteDirectory: siteDirectory,
            configDirectory: configDirectory,
            siteBase: URL(string: "https://mysite.test")!
        )

        let log = WebmentionSentLog.load(from: configDirectory)
        #expect(log?.sent.count == 2)
        #expect(Set(log?.sent.map(\.target.absoluteString) ?? []) == [
            "https://one.example/target", "https://two.example/target",
        ])

        let lines = await logCenter.snapshot()
        #expect(lines.contains { $0.source == "webmention:site1" && $0.text.contains("sending 2 webmention") })
        #expect(lines.filter { $0.source == "webmention:site1" && $0.text.contains("sent ") }.count == 2)
    }

    @Test("a second run does not resend already-sent pairs")
    func skipsAlreadySentPairs() async throws {
        let (root, siteDirectory, configDirectory) = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = Counter()
        let baseTransport = transport()
        let counting: WebmentionEndpointDiscovery.Transport = { request in
            if request.httpMethod == "POST" { await counter.increment() }
            return try await baseTransport(request)
        }
        let command = WebmentionSendCommand(transport: counting, logCenter: LogCenter())
        let siteBase = URL(string: "https://mysite.test")!

        await command.send(siteID: "site1", siteDirectory: siteDirectory, configDirectory: configDirectory, siteBase: siteBase)
        var count = await counter.value
        #expect(count == 2)

        await command.send(siteID: "site1", siteDirectory: siteDirectory, configDirectory: configDirectory, siteBase: siteBase)
        count = await counter.value
        #expect(count == 2) // no new POSTs on the second run
    }

    @Test("a failed send is not persisted, so it's retried on the next run")
    func failedSendIsRetried() async throws {
        let (root, siteDirectory, configDirectory) = try makeSite()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = WebmentionSendCommand(
            transport: transport(failing: ["https://one.example/target"]),
            logCenter: LogCenter()
        )

        await command.send(
            siteID: "site1", siteDirectory: siteDirectory, configDirectory: configDirectory,
            siteBase: URL(string: "https://mysite.test")!
        )

        let log = WebmentionSentLog.load(from: configDirectory)
        #expect(log?.sent.map(\.target.absoluteString) == ["https://two.example/target"])
    }

    @Test("a site with no outbound links sends nothing and writes no log")
    func noPlanEntriesIsANoop() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webmention-empty-\(UUID().uuidString)", isDirectory: true)
        let siteDirectory = root.appendingPathComponent("Source", isDirectory: true)
        let configDirectory = root.appendingPathComponent("Config", isDirectory: true)
        try FileManager.default.createDirectory(at: siteDirectory.appendingPathComponent("src/content"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let command = WebmentionSendCommand(transport: transport(), logCenter: LogCenter())
        await command.send(
            siteID: "site1", siteDirectory: siteDirectory, configDirectory: configDirectory,
            siteBase: URL(string: "https://mysite.test")!
        )

        #expect(WebmentionSentLog.load(from: configDirectory) == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter WebmentionSendCommandTests`
Expected: FAIL to compile — `WebmentionSendCommand` does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/WebmentionSendCommand.swift`:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Actor orchestrator for one site's webmention-send pass, run after a successful deploy.
/// Builds the site's `SocialPublishPlan` (siteBase = the just-deployed URL), diffs it against the
/// site's `WebmentionSentLog`, sends each pending pair, persists successes, and streams
/// progress/results into `LogCenter` under source `"webmention:<siteID>"`. Best-effort — never
/// throws; failures are logged, not surfaced as a thrown error, since this runs detached from the
/// deploy result the user actually watches (`DeployModel.runDeploy`).
public actor WebmentionSendCommand {
    private let transport: WebmentionEndpointDiscovery.Transport
    private let logCenter: LogCenter
    private let now: () -> Date

    public init(
        transport: @escaping WebmentionEndpointDiscovery.Transport = WebmentionSendCommand.defaultTransport,
        logCenter: LogCenter = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.logCenter = logCenter
        self.now = now
    }

    public func send(siteID: String, siteDirectory: URL, configDirectory: URL, siteBase: URL) async {
        let logSource = "webmention:\(siteID)"

        let plan: SocialPublishPlan.Plan
        do {
            plan = try SocialPublishPlan.build(projectRoot: siteDirectory, siteBase: siteBase)
        } catch {
            await logCenter.append(
                source: logSource, stream: .stderr,
                text: "webmention: couldn't build publish plan: \(error)"
            )
            return
        }
        guard plan.webmentionCount > 0 else { return }

        let log = WebmentionSentLog.load(from: configDirectory) ?? WebmentionSentLog()
        let pending = log.pending(in: plan)
        guard !pending.isEmpty else { return }

        await logCenter.append(
            source: logSource, stream: .stdout,
            text: "webmention: sending \(pending.count) webmention(s)"
        )

        var sentPairs: [WebmentionTargetPair] = []
        for pair in pending {
            let outcome = await WebmentionSender.send(source: pair.source, target: pair.target, transport: transport)
            switch outcome {
            case .sent(let endpoint, let statusCode):
                await logCenter.append(
                    source: logSource, stream: .stdout,
                    text: "webmention: sent \(pair.source.absoluteString) -> \(pair.target.absoluteString) via \(endpoint.absoluteString) (HTTP \(statusCode))"
                )
                sentPairs.append(pair)
            case .noEndpointDiscovered:
                await logCenter.append(
                    source: logSource, stream: .stdout,
                    text: "webmention: no endpoint declared by \(pair.target.absoluteString), skipping"
                )
            case .requestFailed(let reason):
                await logCenter.append(
                    source: logSource, stream: .stderr,
                    text: "webmention: \(pair.source.absoluteString) -> \(pair.target.absoluteString) failed: \(reason)"
                )
            }
        }

        guard !sentPairs.isEmpty else { return }
        let updated = log.recording(sentPairs, now: now)
        do {
            try updated.save(to: configDirectory)
        } catch {
            await logCenter.append(
                source: logSource, stream: .stderr,
                text: "webmention: couldn't persist sent log: \(error)"
            )
        }
    }

    /// Production transport: a plain `URLSession` request.
    public static let defaultTransport: WebmentionEndpointDiscovery.Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter WebmentionSendCommandTests`
Expected: PASS (all 4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WebmentionSendCommand.swift Tests/AnglesiteCoreTests/WebmentionSendCommandTests.swift
git commit -m "$(cat <<'EOF'
Add WebmentionSendCommand orchestrator for #354

Ties SocialPublishPlan + WebmentionSentLog + WebmentionSender together
into one per-site send pass, logging progress to LogCenter under
"webmention:<siteID>".

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire into `DeployModel`

**Files:**
- Modify: `Sources/AnglesiteApp/DeployModel.swift:71` (property), `:93-105` (init), `:306-308` (`.succeeded` case in `runDeploy`)

**Interfaces:**
- Consumes: `WebmentionSendCommand` (Task 4) — `public init(transport:logCenter:now:)` (all defaulted), `public func send(siteID:siteDirectory:configDirectory:siteBase:) async`.

No new test file — `DeployModel` has no existing test target coverage today (`Tests/AnglesiteAppTests` doesn't yet cover it), and per CLAUDE.md's build notes, app-target logic that needs CI coverage belongs in a testable `AnglesiteCore` type rather than being tested through the app target. `WebmentionSendCommand` itself is fully covered by Task 4; this task is deliberately thin wiring. Verification is Task 7's `xcodebuild build`.

- [ ] **Step 1: Add the `webmentionCommand` property**

In `Sources/AnglesiteApp/DeployModel.swift`, find:

```swift
    private let command: DeployCommand
    private let logCenter: LogCenter
```

Replace with:

```swift
    private let command: DeployCommand
    private let webmentionCommand: WebmentionSendCommand
    private let logCenter: LogCenter
```

- [ ] **Step 2: Add the init parameter and assignment**

Find:

```swift
    init(
        command: DeployCommand = DeployCommand(),
        logCenter: LogCenter = .shared,
        keychain: KeychainStore = KeychainStore(),
        verifier: TokenVerifying = CloudflareAPITokenVerifier(),
        summarizer: any DeployFailureSummarizing = DeploySummarizerFactory.makeDefault()
    ) {
        self.command = command
        self.logCenter = logCenter
        self.keychain = keychain
        self.onboarding = TokenOnboarding(verifier: verifier)
        self.summarizer = summarizer
    }
```

Replace with:

```swift
    init(
        command: DeployCommand = DeployCommand(),
        webmentionCommand: WebmentionSendCommand = WebmentionSendCommand(),
        logCenter: LogCenter = .shared,
        keychain: KeychainStore = KeychainStore(),
        verifier: TokenVerifying = CloudflareAPITokenVerifier(),
        summarizer: any DeployFailureSummarizing = DeploySummarizerFactory.makeDefault()
    ) {
        self.command = command
        self.webmentionCommand = webmentionCommand
        self.logCenter = logCenter
        self.keychain = keychain
        self.onboarding = TokenOnboarding(verifier: verifier)
        self.summarizer = summarizer
    }
```

- [ ] **Step 3: Fire the webmention send pass after a successful deploy**

Find, inside `runDeploy`:

```swift
        switch result {
        case .succeeded(let url, let duration):
            transition(siteID: siteID, to: .succeeded(url: url, duration: duration))
        case .failed(let reason, let exit):
```

Replace with:

```swift
        switch result {
        case .succeeded(let url, let duration):
            transition(siteID: siteID, to: .succeeded(url: url, duration: duration))
            // Fire-and-forget: webmention sends are best-effort and must never block or affect
            // the deploy result the user watches. Progress/failures surface only in LogCenter.
            Task.detached { [webmentionCommand] in
                await webmentionCommand.send(
                    siteID: siteID,
                    siteDirectory: siteDirectory,
                    configDirectory: configDirectory,
                    siteBase: url
                )
            }
        case .failed(let reason, let exit):
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build --target AnglesiteAppCore`
Expected: Build succeeds with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/DeployModel.swift
git commit -m "$(cat <<'EOF'
Wire WebmentionSendCommand into DeployModel for #354

Fires a best-effort webmention send pass after every successful
deploy, using the deployed URL as siteBase. Runs detached so a slow
or unreachable target endpoint can't stall the deploy UI.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Gated live e2e test against webmention.rocks

**Files:**
- Create: `Tests/AnglesiteCoreTests/WebmentionRocksLiveTests.swift`

**Interfaces:**
- Consumes: `WebmentionEndpointDiscovery.discover(target:transport:)` (Task 1), `WebmentionSender.send(source:target:transport:)` (Task 2), `WebmentionEndpointDiscovery.Transport` (Task 1).

This test hits the real `webmention.rocks` and is gated off by default via `ANGLESITE_WEBMENTION_E2E`, mirroring `PodmanContainerControlIntegrationTests`'s `ANGLESITE_PODMAN_TESTS` gate (`Tests/AnglesiteCoreTests/PodmanContainerControlIntegrationTests.swift:22-24,52-55`). The three target pages below were confirmed live (2026-07-14) against `https://webmention.rocks/`'s own test index:
- `/test/1` = "HTTP Link header, unquoted rel, relative URL" (confirmed header: `link: </test/1/webmention?head=true>; rel=webmention`)
- `/test/4` = "HTML `<link>` tag, absolute URL" (confirmed body: `<link href="https://webmention.rocks/test/4/webmention" rel="webmention">`)
- `/test/23/page` = "Webmention target is a redirect and the endpoint is relative" (confirmed: 302s to a session-specific `/test/23/page/<token>` URL)

- [ ] **Step 1: Write the test**

Create `Tests/AnglesiteCoreTests/WebmentionRocksLiveTests.swift`:

```swift
// Real-network integration test against webmention.rocks — gated behind ANGLESITE_WEBMENTION_E2E
// so CI and everyday `swift test` runs never depend on a third-party site's availability.
// Exercises WebmentionEndpointDiscovery's Link-header/HTML/redirect logic against real markup,
// and confirms WebmentionSender's POST is accepted, using webmention.rocks' own documented test
// pages (https://webmention.rocks/about).
//
// Run locally with:
//   ANGLESITE_WEBMENTION_E2E=1 swift test --filter WebmentionRocksLiveTests
//
// webmention.rocks' full pass/fail dashboard (green checkmarks per test) requires visiting their
// site and using a session-specific source-URL token they crawl back to verify — that's an
// interactive, one-time manual step (see the PR description), not something this automated test
// attempts. This test only confirms discovery + POST-accepted against real pages, as ongoing
// regression coverage for the parsing logic.
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("Webmention send against webmention.rocks (live)")
struct WebmentionRocksLiveTests {
    private static var liveTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["ANGLESITE_WEBMENTION_E2E"] == "1"
    }

    private let transport: WebmentionEndpointDiscovery.Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    @Test(
        "test 1 (HTTP Link header) discovers a real endpoint and accepts a POST",
        .enabled(if: liveTestsEnabled, "hits the real webmention.rocks — set ANGLESITE_WEBMENTION_E2E=1 to opt in")
    )
    func linkHeaderTestPage() async throws {
        let target = URL(string: "https://webmention.rocks/test/1")!
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport)
        #expect(endpoint != nil)

        let outcome = await WebmentionSender.send(
            source: URL(string: "https://anglesite.example/webmention-e2e-source")!,
            target: target,
            transport: transport
        )
        guard case .sent(_, let statusCode) = outcome else {
            Issue.record("expected .sent, got \(outcome)")
            return
        }
        #expect((200..<300).contains(statusCode))
    }

    @Test(
        "test 4 (HTML <link> tag, absolute URL) discovers a real endpoint",
        .enabled(if: liveTestsEnabled, "hits the real webmention.rocks — set ANGLESITE_WEBMENTION_E2E=1 to opt in")
    )
    func htmlLinkElementTestPage() async throws {
        let target = URL(string: "https://webmention.rocks/test/4")!
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport)
        #expect(endpoint?.absoluteString == "https://webmention.rocks/test/4/webmention")
    }

    @Test(
        "test 23 (redirect target, relative endpoint) discovers a real endpoint via the post-redirect URL",
        .enabled(if: liveTestsEnabled, "hits the real webmention.rocks — set ANGLESITE_WEBMENTION_E2E=1 to opt in")
    )
    func redirectTestPage() async throws {
        let target = URL(string: "https://webmention.rocks/test/23/page")!
        let endpoint = try await WebmentionEndpointDiscovery.discover(target: target, transport: transport)
        #expect(endpoint != nil)
    }
}
```

- [ ] **Step 2: Run gated (opt-in) to verify it passes against the real site**

Run: `ANGLESITE_WEBMENTION_E2E=1 swift test --filter WebmentionRocksLiveTests`
Expected: PASS (all 3 tests) — requires network access to webmention.rocks.

- [ ] **Step 3: Run ungated to verify it's skipped by default**

Run: `swift test --filter WebmentionRocksLiveTests`
Expected: all 3 tests report as skipped ("hits the real webmention.rocks — set ANGLESITE_WEBMENTION_E2E=1 to opt in"), 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Tests/AnglesiteCoreTests/WebmentionRocksLiveTests.swift
git commit -m "$(cat <<'EOF'
Add gated webmention.rocks live e2e test for #354

Opt-in via ANGLESITE_WEBMENTION_E2E=1, mirroring the
ANGLESITE_PODMAN_TESTS pattern — never runs in CI by default, gives
ongoing regression coverage for discovery against real-world markup.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Full verification + manual webmention.rocks acceptance check

**Files:** none (verification only)

- [ ] **Step 1: Run the full AnglesiteCore/AnglesiteApp test suites**

Run: `swift test --package-path .`
Expected: all suites pass, including the four new ones from Tasks 1-4 and the (skipped-by-default) Task 6 suite.

- [ ] **Step 2: Confirm the app target actually links the change**

`swift test` alone doesn't prove `AnglesiteAppCore`'s change links into the real `.app` — build the Xcode target directly:

```bash
ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite \
  xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the gated live e2e test once**

Run: `ANGLESITE_WEBMENTION_E2E=1 swift test --filter WebmentionRocksLiveTests`
Expected: PASS (all 3 tests) — confirms discovery + POST-accepted against the real webmention.rocks pages.

- [ ] **Step 4: Manual webmention.rocks dashboard check (one-time acceptance step)**

webmention.rocks' full pass/fail dashboard needs an interactive session:
1. Visit `https://webmention.rocks/` in a browser, follow "Get Started" to obtain a personal source-URL token.
2. Point a temporary test site's content at a couple of the numbered target pages (e.g. `/test/1`, `/test/4`, `/test/23/page`) using that source URL, or manually invoke `WebmentionSender.send(source:target:transport:)` with the session source URL against those targets (e.g. via a Swift REPL or a scratch script using `WebmentionSendCommand.defaultTransport`).
3. Confirm webmention.rocks' dashboard shows green checkmarks for the tests exercised.
4. Note the result in the PR description — this is documentation of a one-time manual check, not a re-runnable automated step (see the design doc's "Manual acceptance step").

- [ ] **Step 5: Update the issue and open the PR**

```bash
gh issue edit 354 --remove-label status:in-progress
git push -u origin claude/issue-354-8adbe9
gh pr create --title "Send webmentions on publish (#354)" --body "$(cat <<'EOF'
## Summary
- Adds a pure-Swift webmention sender (WebmentionEndpointDiscovery + WebmentionSender +
  WebmentionSentLog + WebmentionSendCommand) that fires automatically after every successful
  deploy, independent of the still-unpublished @dwk/workers gate — see the design doc for why
  sending doesn't need the per-site Worker, unlike receiving (V-3).
- Wires it into DeployModel as a fire-and-forget background task after .succeeded.
- Per-site Config/webmention-sent.json avoids re-pinging already-notified targets on redeploy.

Design: docs/superpowers/specs/2026-07-14-webmention-send-design.md

## Test plan
- [x] swift test --package-path . (all suites, including 4 new ones)
- [x] xcodebuild build (Anglesite scheme) — confirms DeployModel change links
- [x] ANGLESITE_WEBMENTION_E2E=1 swift test --filter WebmentionRocksLiveTests (live discovery + POST against webmention.rocks)
- [x] Manual webmention.rocks dashboard verification — <fill in pass/fail summary here>

Closes #354

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR opens against `main`; report the PR URL back to the user.

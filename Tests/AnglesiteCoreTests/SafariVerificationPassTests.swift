import Testing
import Foundation
@testable import AnglesiteCore

/// A dedicated `URLProtocol` stub for this suite — its own type/instance, per the same
/// cross-suite-concurrency rationale as `SafariMCPBridgeClientStubURLProtocol`
/// (`Tests/AnglesiteCoreTests/SafariMCPBridgeClientTests.swift:5-10`). Unlike that stub, this one
/// rewrites each queued response's `"id"` to match the incoming request's id before answering —
/// `SafariVerificationPass` calls a variable subset of tools per test (some capabilities are
/// deliberately absent from `tools/list`), so hand-tracking exact JSON-RPC ids per scenario would
/// make every test fragile to reordering. It also records each `tools/call`'s tool name, for the
/// read-only-by-construction assertion (issue #1944's resolved default 7).
final class SafariVerificationPassStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response { let status: Int; let headers: [String: String]; let body: Data }
    nonisolated(unsafe) static var queue: [Response] = []
    nonisolated(unsafe) static var capturedToolCallNames: [String] = []

    static func reset() { queue = []; capturedToolCallNames = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession strips httpBody for custom protocols unless read via stream; capture both,
        // matching `StubURLProtocol`'s identical fallback in `HTTPTransportTests.swift`.
        let bodyData: Data
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            bodyData = data
        } else {
            bodyData = request.httpBody ?? Data()
        }

        let requestObject = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
        if let method = requestObject?["method"] as? String, method == "tools/call",
           let params = requestObject?["params"] as? [String: Any],
           let name = params["name"] as? String {
            Self.capturedToolCallNames.append(name)
        }

        var response = Self.queue.isEmpty ? Response(status: 500, headers: [:], body: Data()) : Self.queue.removeFirst()
        if let requestID = requestObject?["id"], !response.body.isEmpty,
           var responseObject = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] {
            responseObject["id"] = requestID
            if let rewritten = try? JSONSerialization.data(withJSONObject: responseObject) {
                response = Response(status: response.status, headers: response.headers, body: rewritten)
            }
        }

        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty { client?.urlProtocol(self, didLoad: response.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct SafariVerificationPassTests {
    private func makePass(logCenter: LogCenter = LogCenter()) -> (SafariVerificationPass, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SafariVerificationPassStubURLProtocol.self]
        let session = URLSession(configuration: config)
        let pass = SafariVerificationPass(urlSession: session, logCenter: logCenter)
        return (pass, session)
    }

    /// Queues the `initialize` → `notifications/initialized` → `tools/list` handshake, advertising
    /// exactly `tools` as the server's catalog.
    private func enqueueHandshake(tools: [String]) {
        let initBody = try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1,
            "result": ["protocolVersion": "2024-11-05", "serverInfo": ["name": "Safari"]],
        ])
        SafariVerificationPassStubURLProtocol.queue.append(.init(
            status: 200, headers: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-1"], body: initBody
        ))
        SafariVerificationPassStubURLProtocol.queue.append(.init(status: 202, headers: [:], body: Data()))
        let toolsBody = try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2,
            "result": ["tools": tools.map { ["name": $0] }],
        ])
        SafariVerificationPassStubURLProtocol.queue.append(.init(
            status: 200, headers: ["Content-Type": "application/json"], body: toolsBody
        ))
    }

    private func toolCallResponse(content: [[String: Any]], isError: Bool = false) -> SafariVerificationPassStubURLProtocol.Response {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": 0, "result": ["isError": isError, "content": content]]
        let body = try! JSONSerialization.data(withJSONObject: object)
        return .init(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    private func textContent(_ text: String) -> [String: Any] { ["type": "text", "text": text] }
    private func imageContent(base64: String, mimeType: String = "image/png") -> [String: Any] {
        ["type": "image", "data": base64, "mimeType": mimeType]
    }

    /// JSON-encodes `items` to a string — the pass decodes each list tool's single `text` content
    /// block as a JSON array (this file's + `SafariVerificationPass`'s shared wire-format
    /// assumption), so tests build that inner payload the same way.
    private func jsonArrayText(_ items: [[String: Any]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: items)
        return String(data: data, encoding: .utf8)!
    }

    private let previewURL = URL(string: "http://localhost:4321/")!

    /// The stub answers every request synchronously and in-memory, so this only needs to be
    /// generous enough to survive Swift Testing's own scheduling latency on a heavily parallel CI
    /// run (which — unlike the default `NetworkTimeouts.safariMCPBridgeProbe` production reachability
    /// probe this overrides — has no reason to stay tight): CI's `build-test` job runs several
    /// thousand tests across hundreds of concurrently-scheduled suites, and that contention alone
    /// was enough to blow through the 3-second production default and fail two of these tests with
    /// `ClientError.timeout` even though every response here is already queued before the request
    /// is ever sent.
    private let ciConnectTimeout: TimeInterval = 30

    @Test("happy path: all five sections populated from stubbed tools/call responses") func happyPath() async throws {
        SafariVerificationPassStubURLProtocol.reset()
        enqueueHandshake(tools: [
            "navigate_to_url", "browser_console_messages", "list_network_requests", "get_page_content", "screenshot",
        ])
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: []))  // navigate
        let consoleItems: [[String: Any]] = [["level": "error", "text": "boom"], ["level": "log", "text": "hi"]]
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: [textContent(jsonArrayText(consoleItems))]))
        let networkItems: [[String: Any]] = [
            ["url": "https://example.com/a.js", "method": "GET", "status": 200],
            ["url": "https://example.com/missing.js", "method": "GET", "status": 404],
        ]
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: [textContent(jsonArrayText(networkItems))]))
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: [textContent("<html>hello</html>")]))
        let screenshotData = Data("hello".utf8)
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: [imageContent(base64: screenshotData.base64EncodedString())]))

        let (pass, _) = makePass()
        let report = try await pass.run(previewURL: previewURL, port: 4399, connectTimeout: ciConnectTimeout)

        guard case .available(let console) = report.console else { Issue.record("console unavailable"); return }
        #expect(console.entries == [.init(level: "error", text: "boom"), .init(level: "log", text: "hi")])
        #expect(!console.truncated)

        guard case .available(let network) = report.network else { Issue.record("network unavailable"); return }
        #expect(network.entries == [
            .init(url: "https://example.com/a.js", method: "GET", status: 200, failed: false),
            .init(url: "https://example.com/missing.js", method: "GET", status: 404, failed: true),
        ])
        #expect(!network.truncated)

        guard case .available(let page) = report.pageContent else { Issue.record("pageContent unavailable"); return }
        #expect(page == "<html>hello</html>")

        guard case .available(let screenshot) = report.screenshot else { Issue.record("screenshot unavailable"); return }
        #expect(screenshot == screenshotData)
    }

    @Test("a capability absent from tools/list records .unavailable and the pass still succeeds") func missingCapabilityDegrades() async throws {
        SafariVerificationPassStubURLProtocol.reset()
        enqueueHandshake(tools: ["navigate_to_url", "browser_console_messages", "get_page_content", "screenshot"])  // no network tool
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: []))  // navigate
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: [textContent("[]")]))  // console
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: [textContent("page")]))  // pageContent
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: [imageContent(base64: Data("x".utf8).base64EncodedString())]))  // screenshot

        let (pass, _) = makePass()
        let report = try await pass.run(previewURL: previewURL, port: 4399, connectTimeout: ciConnectTimeout)

        guard case .unavailable(let reason) = report.network else { Issue.record("expected network unavailable"); return }
        #expect(reason.contains("no network tool"))
        guard case .available = report.pageContent else { Issue.record("expected pageContent available"); return }
        guard case .available = report.screenshot else { Issue.record("expected screenshot available"); return }
    }

    @Test("navigate tool missing from tools/list throws PassError.navigateToolUnavailable") func navigateToolMissingThrows() async throws {
        SafariVerificationPassStubURLProtocol.reset()
        enqueueHandshake(tools: ["browser_console_messages"])

        let (pass, _) = makePass()
        do {
            _ = try await pass.run(previewURL: previewURL, port: 4399, connectTimeout: ciConnectTimeout)
            Issue.record("expected PassError.navigateToolUnavailable to be thrown")
        } catch SafariVerificationPass.PassError.navigateToolUnavailable {
            // expected
        }
    }

    @Test("navigate call failing throws PassError.navigateFailed") func navigateCallFailingThrows() async throws {
        SafariVerificationPassStubURLProtocol.reset()
        enqueueHandshake(tools: ["navigate_to_url"])
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: [textContent("boom")], isError: true))

        let (pass, _) = makePass()
        do {
            _ = try await pass.run(previewURL: previewURL, port: 4399, connectTimeout: ciConnectTimeout)
            Issue.record("expected PassError.navigateFailed to be thrown")
        } catch SafariVerificationPass.PassError.navigateFailed {
            // expected
        }
    }

    @Test("an over-8-MiB screenshot records .unavailable and is not retained") func oversizedScreenshotDropped() async throws {
        SafariVerificationPassStubURLProtocol.reset()
        enqueueHandshake(tools: ["navigate_to_url", "screenshot"])
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: []))  // navigate
        let oversized = Data(count: 8 * 1024 * 1024 + 1)
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: [imageContent(base64: oversized.base64EncodedString())]))

        let (pass, _) = makePass()
        let report = try await pass.run(previewURL: previewURL, port: 4399, connectTimeout: ciConnectTimeout)

        guard case .unavailable(let reason) = report.screenshot else { Issue.record("expected screenshot unavailable"); return }
        #expect(reason.contains("cap"))
    }

    @Test(">200 console entries are capped with truncated == true") func consoleEntriesCapped() async throws {
        SafariVerificationPassStubURLProtocol.reset()
        enqueueHandshake(tools: ["navigate_to_url", "browser_console_messages"])
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: []))  // navigate
        let items = (0..<250).map { ["level": "log", "text": "message \($0)"] }
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: [textContent(jsonArrayText(items))]))

        let (pass, _) = makePass()
        let report = try await pass.run(previewURL: previewURL, port: 4399, connectTimeout: ciConnectTimeout)

        guard case .available(let console) = report.console else { Issue.record("expected console available"); return }
        #expect(console.entries.count == 200)
        #expect(console.truncated)
    }

    @Test("only the five allowlisted tool names are ever called") func readOnlyByConstruction() async throws {
        SafariVerificationPassStubURLProtocol.reset()
        let allowed = ["navigate_to_url", "browser_console_messages", "list_network_requests", "get_page_content", "screenshot"]
        enqueueHandshake(tools: allowed)
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: []))  // navigate
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: [textContent("[]")]))  // console
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: [textContent("[]")]))  // network
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: [textContent("page")]))  // pageContent
        SafariVerificationPassStubURLProtocol.queue.append(toolCallResponse(content: [imageContent(base64: Data("x".utf8).base64EncodedString())]))  // screenshot

        let (pass, _) = makePass()
        _ = try await pass.run(previewURL: previewURL, port: 4399, connectTimeout: ciConnectTimeout)

        let allowedSet = Set(allowed)
        #expect(!SafariVerificationPassStubURLProtocol.capturedToolCallNames.isEmpty)
        #expect(SafariVerificationPassStubURLProtocol.capturedToolCallNames.allSatisfy { allowedSet.contains($0) })
    }
}

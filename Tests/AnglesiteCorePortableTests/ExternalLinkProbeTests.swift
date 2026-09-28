import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AnglesiteCore

/// Fake server for the probe (#2027): answers per URL with a scripted status sequence (HEAD
/// first, then any GET fallback), optionally after a delay, and records every request plus the
/// peak number in flight. Never touches the network. A delayed response sleeps cooperatively,
/// so cancellation unwinds it the way `URLSession` would.
private actor FakeServer {
    struct Script {
        var statuses: [Int]
        var delay: Duration = .zero
        var error: URLError? = nil
    }

    private var scripts: [URL: Script]
    private var fallback: Script
    private(set) var requests: [URLRequest] = []
    private(set) var inFlight = 0
    private(set) var peakInFlight = 0

    init(_ scripts: [URL: Script] = [:], fallback: Script = Script(statuses: [200])) {
        self.scripts = scripts
        self.fallback = fallback
    }

    nonisolated var transport: CloudflareTransport {
        { request in try await self.handle(request) }
    }

    private func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        defer { inFlight -= 1 }
        let url = try #require(request.url)
        var script = scripts[url] ?? fallback
        if script.delay > .zero { try await Task.sleep(for: script.delay) }
        if let error = script.error { throw error }
        let status = script.statuses.isEmpty ? 200 : script.statuses.removeFirst()
        if scripts[url] != nil { scripts[url] = script }
        return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func requests(for url: URL) -> [URLRequest] { requests.filter { $0.url == url } }
}

private func url(_ path: String) -> URL { URL(string: "https://other.example/\(path)")! }

private func probe(_ server: FakeServer, budget: Duration = .seconds(60)) -> HTTPExternalLinkProbe {
    HTTPExternalLinkProbe(
        transport: server.transport, maxConcurrent: HTTPExternalLinkProbe.defaultMaxConcurrent,
        requestTimeout: HTTPExternalLinkProbe.defaultRequestTimeout, totalBudget: budget)
}

@Suite("ExternalLinkProbe (#2027)")
struct ExternalLinkProbeTests {
    @Test("the production defaults are 6 in flight, 10 s per request and a 60 s budget")
    func defaults() {
        #expect(HTTPExternalLinkProbe.defaultMaxConcurrent == 6)
        #expect(HTTPExternalLinkProbe.defaultRequestTimeout == 10)
        #expect(HTTPExternalLinkProbe.defaultTotalBudget == .seconds(60))
    }

    @Test("status mapping: 2xx reachable, 404/410 unreachable, everything else indeterminate",
          arguments: [
              (200, LinkReachability.reachable), (204, .reachable), (299, .reachable),
              (404, .unreachable), (410, .unreachable),
              (301, .indeterminate), (400, .indeterminate), (401, .indeterminate), (403, .indeterminate),
              (429, .indeterminate), (500, .indeterminate), (503, .indeterminate), (522, .indeterminate),
          ])
    func statusMapping(status: Int, expected: LinkReachability) async {
        let target = url("page")
        let server = FakeServer([target: .init(statuses: [status])])
        let result = await probe(server).probe([target])
        #expect(result == [target: expected])
    }

    @Test("a HEAD with a 10 s timeout and no User-Agent is the first request")
    func headRequestShape() async throws {
        let target = url("page")
        let server = FakeServer()
        _ = await probe(server).probe([target])
        let request = try #require(await server.requests.first)
        #expect(request.httpMethod == "HEAD")
        #expect(request.timeoutInterval == 10)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == nil)
    }

    @Test("405 and 501 retry exactly once as a one-byte ranged GET", arguments: [405, 501])
    func headNotAllowedFallsBackToRangedGet(status: Int) async throws {
        let target = url("page")
        let server = FakeServer([target: .init(statuses: [status, 206])])
        let result = await probe(server).probe([target])
        #expect(result == [target: .reachable])
        let requests = await server.requests(for: target)
        #expect(requests.count == 2)
        #expect(requests[1].httpMethod == "GET")
        #expect(requests[1].value(forHTTPHeaderField: "Range") == "bytes=0-0")
        #expect(requests[1].timeoutInterval == 10)
    }

    @Test("the GET fallback's own status is what counts")
    func fallbackStatusMapped() async {
        let target = url("page")
        let server = FakeServer([target: .init(statuses: [405, 404])])
        #expect(await probe(server).probe([target]) == [target: .unreachable])
    }

    @Test("no other status retries", arguments: [403, 404, 429, 500, 503])
    func noRetryOtherwise(status: Int) async {
        let target = url("page")
        let server = FakeServer([target: .init(statuses: [status, 200])])
        _ = await probe(server).probe([target])
        #expect(await server.requests(for: target).count == 1)
    }

    @Test("a transport error (timeout, DNS, TLS) is indeterminate",
          arguments: [URLError.Code.timedOut, .cannotFindHost, .secureConnectionFailed, .badServerResponse])
    func transportErrorIsIndeterminate(code: URLError.Code) async {
        let target = url("page")
        let server = FakeServer([target: .init(statuses: [], error: URLError(code))])
        #expect(await probe(server).probe([target]) == [target: .indeterminate])
    }

    @Test("never more than 6 requests in flight, and the window is actually used")
    func boundedConcurrency() async {
        let targets = (0..<25).map { url("p\($0)") }
        let server = FakeServer(fallback: .init(statuses: [200], delay: .milliseconds(20)))
        let result = await probe(server).probe(targets)
        #expect(result.count == 25)
        #expect(result.values.allSatisfy { $0 == .reachable })
        #expect(await server.peakInFlight == 6)
        #expect(await server.requests.count == 25)
    }

    @Test("every input URL gets an entry and duplicates are probed once")
    func duplicatesCollapse() async {
        let a = url("a"), b = url("b")
        let server = FakeServer([b: .init(statuses: [404])])
        let result = await probe(server).probe([a, b, a, a, b])
        #expect(result == [a: .reachable, b: .unreachable])
        #expect(await server.requests.count == 2)
    }

    @Test("empty input returns an empty map without any transport call")
    func emptyInput() async {
        let server = FakeServer()
        #expect(await probe(server).probe([]) == [:])
        #expect(await server.requests.isEmpty)
    }

    @Test("the total budget bounds a run whose transport never answers; unresolved URLs are indeterminate")
    func budgetBoundsAHungRun() async {
        let fast = url("fast")
        let hung = (0..<10).map { url("hung\($0)") }
        var scripts = [fast: FakeServer.Script(statuses: [200])]
        for target in hung { scripts[target] = .init(statuses: [200], delay: .seconds(3600)) }
        let server = FakeServer(scripts)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await probe(server, budget: .milliseconds(200)).probe([fast] + hung)
        let elapsed = clock.now - start
        #expect(elapsed < .seconds(5))
        #expect(result.count == 11)
        #expect(result[fast] == .reachable)
        #expect(hung.allSatisfy { result[$0] == .indeterminate })
        // The first window of 6, plus the one refill after `fast` finished; the rest stayed unprobed.
        #expect(await server.requests.count == 7)
    }

    @Test("cancelling the caller returns promptly with a partial map instead of throwing")
    func cancellationReturnsPartialMap() async {
        let fast = url("fast")
        let slow = (0..<10).map { url("slow\($0)") }
        var scripts = [fast: FakeServer.Script(statuses: [404])]
        for target in slow { scripts[target] = .init(statuses: [200], delay: .seconds(3600)) }
        let server = FakeServer(scripts)
        let prober = probe(server)
        let task = Task { await prober.probe([fast] + slow) }
        // Let the first window start (and `fast` finish) before cancelling.
        while await server.requests.count < 6 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        let result = await task.value
        #expect(clock.now - start < .seconds(5))
        #expect(result.count == 11)
        #expect(result[fast] == .unreachable)
        #expect(slow.allSatisfy { result[$0] == .indeterminate })
        #expect(await server.requests.count <= 7)
    }
}

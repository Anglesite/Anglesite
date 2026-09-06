import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

struct LogCenterTests {
    @Test("Append retains lines in order") func appendRetainsLinesInOrder() async {
        let center = LogCenter()
        await center.append(source: "astro", stream: .stdout, text: "first")
        await center.append(source: "astro", stream: .stderr, text: "second")
        let snapshot = await center.snapshot()
        #expect(snapshot.count == 2)
        #expect(snapshot.map(\.text) == ["first", "second"])
        #expect(snapshot.map(\.stream) == [.stdout, .stderr])
        #expect(snapshot.map(\.id) == [0, 1])
    }

    @Test("Ring buffer evicts oldest lines") func ringBufferEvictsOldestLines() async {
        let center = LogCenter(bufferCapacity: 3)
        for i in 0..<5 {
            await center.append(source: "x", stream: .stdout, text: "line\(i)")
        }
        let snapshot = await center.snapshot()
        #expect(snapshot.map(\.text) == ["line2", "line3", "line4"])
        // IDs are monotonic regardless of eviction — they're a global sequence, not an index.
        #expect(snapshot.map(\.id) == [2, 3, 4])
    }

    @Test("Subscriber receives subsequent appends") func subscriberReceivesSubsequentAppends() async {
        let center = LogCenter()
        let sub = await center.subscribe()
        await center.append(source: "a", stream: .stdout, text: "one")
        await center.append(source: "b", stream: .stderr, text: "two")

        var collected: [String] = []
        var iterator = sub.stream.makeAsyncIterator()
        for _ in 0..<2 {
            guard let line = await iterator.next() else { break }
            collected.append(line.text)
        }
        #expect(collected == ["one", "two"])
    }

    @Test("Multiple subscribers each receive every line") func multipleSubscribersEachReceiveEveryLine() async {
        let center = LogCenter()
        let a = await center.subscribe()
        let b = await center.subscribe()
        let initialCount = await center.subscriberCount()
        #expect(initialCount == 2)

        await center.append(source: "s", stream: .stdout, text: "hello")

        var aIter = a.stream.makeAsyncIterator()
        var bIter = b.stream.makeAsyncIterator()
        let aLine = await aIter.next()
        let bLine = await bIter.next()
        #expect(aLine?.text == "hello")
        #expect(bLine?.text == "hello")
    }

    // MARK: Debug-pane helpers

    private func sampleLines() -> [LogCenter.LogLine] {
        [
            LogCenter.LogLine(id: 0, timestamp: Date(timeIntervalSince1970: 0), source: "astro", stream: .stdout, text: "Local http://localhost:4321/"),
            LogCenter.LogLine(id: 1, timestamp: Date(timeIntervalSince1970: 1), source: "astro", stream: .stderr, text: "warning: slow build"),
            LogCenter.LogLine(id: 2, timestamp: Date(timeIntervalSince1970: 2), source: "mcp", stream: .stdout, text: "{\"jsonrpc\":\"2.0\"}"),
            LogCenter.LogLine(id: 3, timestamp: Date(timeIntervalSince1970: 3), source: "mcp", stream: .stderr, text: "server ready"),
        ]
    }

    @Test("Filtered by source only") func filteredBySourceOnly() {
        let out = sampleLines().filtered(source: "astro", stream: nil, query: "")
        #expect(out.map(\.id) == [0, 1])
    }

    @Test("Filtered by stream only") func filteredByStreamOnly() {
        let out = sampleLines().filtered(source: nil, stream: .stderr, query: "")
        #expect(out.map(\.id) == [1, 3])
    }

    @Test("Filtered by query matches source and text, case-insensitive") func filteredByQueryMatchesSourceAndTextCaseInsensitive() {
        // "ready" matches the mcp/stderr text; "ASTRO" matches the astro source.
        #expect(sampleLines().filtered(source: nil, stream: nil, query: "ready").map(\.id) == [3])
        #expect(sampleLines().filtered(source: nil, stream: nil, query: "ASTRO").map(\.id) == [0, 1])
    }

    @Test("Filtered combines all predicates") func filteredCombinesAllPredicates() {
        let out = sampleLines().filtered(source: "mcp", stream: .stdout, query: "jsonrpc")
        #expect(out.map(\.id) == [2])
    }

    @Test("Filtered nil source and empty query returns all") func filteredNilSourceAndEmptyQueryReturnsAll() {
        #expect(sampleLines().filtered(source: nil, stream: nil, query: "  ").map(\.id) == [0, 1, 2, 3])
    }

    @Test("Export text formats each line") func exportTextFormatsEachLine() {
        let text = sampleLines().exportText(timestampFormat: "ss")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0] == "00  [astro/stdout]  Local http://localhost:4321/")
        #expect(lines[3] == "03  [mcp/stderr]  server ready")
    }

    @Test("Cancel ends iteration and unregisters") func cancelEndsIterationAndUnregisters() async throws {
        let center = LogCenter()
        let sub = await center.subscribe()
        let initial = await center.subscriberCount()
        #expect(initial == 1)

        sub.cancel()
        // onTermination → removeSubscriber hops through a Task; wait for it to land.
        try await waitUntil("removeSubscriber to land") { await center.subscriberCount() == 0 }

        var iterator = sub.stream.makeAsyncIterator()
        let next = await iterator.next()
        #expect(next == nil)
    }
}

import Testing
import Foundation
@testable import AnglesiteCore

/// `SidecarWYSIWYGHostTransport.refreshModel(knownVersion:)` (#2215) — portable, so it runs on
/// the Linux lane too.
@Suite("SidecarWYSIWYGHostTransport.refreshModel")
struct SidecarWYSIWYGRefreshTests {
    struct UnusedEditRouter: EditRouter {
        func apply(_ message: EditMessage) async -> EditReply {
            EditReply(id: message.id, status: .failed, message: "not expected in a refresh")
        }
    }

    /// Serves `get_page_model` from a mutable version, and counts calls.
    final class PageSource: @unchecked Sendable {
        private let lock = NSLock()
        private var _version: String
        private var _calls = 0
        var fails = false

        init(version: String) { _version = version }

        var version: String {
            get { lock.withLock { _version } }
            set { lock.withLock { _version = newValue } }
        }
        var calls: Int { lock.withLock { _calls } }

        func client() -> PageModelClient {
            PageModelClient(toolCaller: { [self] name, _ in
                #expect(name == "get_page_model")
                let (version, fails) = lock.withLock { () -> (String, Bool) in
                    _calls += 1
                    return (_version, self.fails)
                }
                if fails {
                    return MCPClient.ToolCallResult(
                        content: [.init(type: "text", text: #"{"type":"error","reason":"io","detail":"boom"}"#)],
                        isError: true)
                }
                let model = PageModel(version: version, path: "src/pages/index.astro", tree: .init(
                    id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 0),
                    loc: nil, text: nil, children: [], block: nil))
                let data = try JSONEncoder().encode(model)
                return MCPClient.ToolCallResult(content: [.init(type: "text", text: String(data: data, encoding: .utf8))], isError: false)
            })
        }
    }

    /// Collects listener notifications across the transport's actor boundary.
    final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var _versions: [String] = []
        func append(_ version: String) { lock.withLock { _versions.append(version) } }
        var versions: [String] { lock.withLock { _versions } }
    }

    private func makeTransport(_ source: PageSource) -> SidecarWYSIWYGHostTransport {
        SidecarWYSIWYGHostTransport(
            path: "src/pages/index.astro", pageModelClient: source.client(), editRouter: UnusedEditRouter(), rootId: "n0")
    }

    @Test("returns the fresh model and notifies listeners when the source changed")
    func changedSourceNotifies() async {
        let source = PageSource(version: "sha256:outside00001")
        let transport = makeTransport(source)
        let received = Received()
        _ = await transport.onModelUpdate { received.append($0.version) }

        let fresh = await transport.refreshModel(knownVersion: "sha256:canvas000001")

        #expect(fresh?.version == "sha256:outside00001")
        #expect(received.versions == ["sha256:outside00001"])
    }

    @Test("returns nil and stays quiet when the source is the version the caller already has")
    func unchangedSourceIsQuiet() async {
        let source = PageSource(version: "sha256:same00000001")
        let transport = makeTransport(source)
        let received = Received()
        _ = await transport.onModelUpdate { received.append($0.version) }

        #expect(await transport.refreshModel(knownVersion: "sha256:same00000001") == nil)
        #expect(received.versions.isEmpty)
        #expect(source.calls == 1)
    }

    @Test("a failed fetch is reported as no change")
    func failedFetchIsNoChange() async {
        let source = PageSource(version: "sha256:whatever0001")
        source.fails = true
        let transport = makeTransport(source)
        let received = Received()
        _ = await transport.onModelUpdate { received.append($0.version) }

        #expect(await transport.refreshModel(knownVersion: "sha256:canvas000001") == nil)
        #expect(received.versions.isEmpty)
    }

    @Test("an unsubscribed listener isn't notified")
    func unsubscribedListenerIsQuiet() async throws {
        let source = PageSource(version: "sha256:outside00001")
        let transport = makeTransport(source)
        let received = Received()
        let unsubscribe = await transport.onModelUpdate { received.append($0.version) }
        unsubscribe()
        // Unsubscribing hops onto the actor; give that hop a turn before refreshing.
        for _ in 0..<50 where await transport.listenerCountForTesting > 0 { await Task.yield() }

        _ = await transport.refreshModel(knownVersion: "sha256:canvas000001")
        #expect(received.versions.isEmpty)
    }
}

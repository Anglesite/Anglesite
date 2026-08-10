import Testing
import Foundation
// URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin platforms
// (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AnglesiteIOS
@testable import AnglesiteCore

/// Drives `PostListModel` (#869's browse surface — the `q=source` list, drafts included)
/// against a faked transport: row mapping, per-collection filtering, and the auth/failure states.
@MainActor
struct PostListModelTests {
    nonisolated private static let endpoint = URL(string: "https://owner.example/micropub")!

    nonisolated private static func client(
        _ handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) -> MicropubClient {
        MicropubClient(
            endpoint: endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
            transport: handler)
    }

    nonisolated private static func response(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: endpoint, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    nonisolated private static func listJSON(_ items: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["items": items])
    }

    @Test("rows map title, collection, and draft state from each listed post")
    func mapsRows() async throws {
        let model = PostListModel(client: Self.client { _ in
            (
                Self.listJSON([
                    [
                        "type": ["h-entry"],
                        "properties": [
                            "name": ["Hello World"],
                            "url": ["https://owner.example/articles/hello-world"],
                        ],
                    ],
                    [
                        "type": ["h-entry"],
                        "properties": [
                            "content": ["First line of a note\nSecond line"],
                            "url": ["https://owner.example/notes/first-note"],
                            "post-status": ["draft"],
                        ],
                    ],
                ]),
                Self.response(200)
            )
        })

        await model.refresh()

        let items = model.items
        #expect(items.count == 2)
        let article = try #require(items.first)
        #expect(article.title == "Hello World")
        #expect(article.collection == "articles")
        #expect(article.isDraft == false)
        let note = try #require(items.last)
        // Title-less note: the row falls back to the content's first line.
        #expect(note.title == "First line of a note")
        #expect(note.collection == "notes")
        #expect(note.isDraft == true)
    }

    @Test("filtering by collection narrows to that content type's rows")
    func filtersByCollection() async {
        let model = PostListModel(client: Self.client { _ in
            (
                Self.listJSON([
                    [
                        "type": ["h-entry"],
                        "properties": [
                            "name": ["A"], "url": ["https://owner.example/articles/a"],
                        ],
                    ],
                    [
                        "type": ["h-entry"],
                        "properties": [
                            "content": ["b"], "url": ["https://owner.example/notes/b"],
                        ],
                    ],
                ]),
                Self.response(200)
            )
        })
        await model.refresh()

        let notes = model.items(inCollection: "notes")
        #expect(notes.map(\.title) == ["b"])
        let all = model.items(inCollection: nil)
        #expect(all.count == 2)
    }

    @Test("a rejected token reads as authRequired, not a generic failure")
    func unauthorizedState() async {
        let model = PostListModel(client: Self.client { _ in (Data(), Self.response(401)) })

        await model.refresh()

        let state = model.state
        #expect(state == .authRequired)
    }

    @Test("a failed refresh keeps the previously loaded rows on screen")
    func failedRefreshKeepsRows() async {
        let box = FailableHandler(healthy: Self.listJSON([
            [
                "type": ["h-entry"],
                "properties": ["name": ["Keep Me"], "url": ["https://owner.example/notes/keep"]],
            ],
        ]))
        let model = PostListModel(client: Self.client { request in
            try await box.handle(request)
        })
        await model.refresh()
        #expect(model.items.count == 1)

        await box.fail()
        await model.refresh()

        guard case .failed(_, let previous) = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }
        #expect(previous.map(\.title) == ["Keep Me"])
        let stillShowable = model.items
        #expect(stillShowable.map(\.title) == ["Keep Me"])
    }
}

/// Serves a healthy list until told to fail — the refresh-after-success fixture.
private actor FailableHandler {
    private let healthy: Data
    private var failing = false

    init(healthy: Data) {
        self.healthy = healthy
    }

    func fail() {
        failing = true
    }

    func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        if failing { throw URLError(.notConnectedToInternet) }
        return (
            healthy,
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

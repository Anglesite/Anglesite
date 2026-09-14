// Tests for the composer pane's loading rules (#1968): which draft a new composition may
// restore, when reopening an existing post uses its pending edit instead of the server copy,
// and how each failure is classified — against a faked Micropub transport.
import Foundation
import Testing
import AnglesiteCore
import AnglesiteIOS
@testable import AnglesiteMobileCore

@Suite("ComposerLoader")
@MainActor
struct ComposerLoaderTests {
    private static let endpoint = URL(string: "https://owner.example/micropub")!
    private static let postURL = URL(string: "https://owner.example/notes/hello")!

    /// Counts transport calls and serves a canned `q=source` reply (or a failure).
    private final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        let status: Int
        init(status: Int = 200) { self.status = status }
        var calls: Int { lock.withLock { _calls } }
        var handler: MicropubClient.Transport {
            { [self] request in
                lock.withLock { _calls += 1 }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
                guard status == 200 else { return (Data(), response) }
                let body = try JSONSerialization.data(withJSONObject: [
                    "type": ["h-entry"], "properties": ["content": ["from the server"]],
                ])
                return (body, response)
            }
        }
    }

    private static func scratchStore() -> ComposerDraftStore {
        ComposerDraftStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-loader-tests-\(UUID().uuidString)", isDirectory: true))
    }

    private static func loader(siteID: UUID, store: ComposerDraftStore, transport: Transport) -> ComposerLoader {
        ComposerLoader(siteID: siteID, registry: .default, draftStore: store) {
            MicropubClient(endpoint: endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(), transport: transport.handler)
        }
    }

    private static var note: ContentTypeDescriptor { ContentTypeRegistry.default.descriptor(id: "note")! }

    @Test("a new composition of a known type opens empty, without touching the network")
    func newCompositionOpensEmpty() async throws {
        let transport = Transport()
        let loader = Self.loader(siteID: UUID(), store: Self.scratchStore(), transport: transport)
        let model = try (await loader.load(.new(typeID: "note"))).get()
        #expect(model.descriptor.id == "note")
        #expect(model.postURL == nil)
        #expect(model.phase == .editing)
        #expect(transport.calls == 0)
    }

    @Test("an unknown type id is reported, not crashed on")
    func unknownTypeFails() async {
        let loader = Self.loader(siteID: UUID(), store: Self.scratchStore(), transport: Transport())
        let result = await loader.load(.new(typeID: "no-such-type"))
        #expect(result.failure == .unavailableContentType)
    }

    @Test("a new composition restores the site's in-progress new draft of the same type")
    func newCompositionRestoresNewDraft() async throws {
        let siteID = UUID()
        let store = Self.scratchStore()
        try store.save(ComposerDraft(siteID: siteID, typeID: "note", values: ["body": .init(.text("resumed"))]))
        let loader = Self.loader(siteID: siteID, store: store, transport: Transport())
        let model = try (await loader.load(.new(typeID: "note"))).get()
        #expect(model.values["body"] == .text("resumed"))
    }

    @Test("a queued update to an existing post never resumes from the New Post entry point")
    func newCompositionIgnoresQueuedUpdate() async throws {
        let siteID = UUID()
        let store = Self.scratchStore()
        try store.save(ComposerDraft(
            siteID: siteID, typeID: "note", postURL: Self.postURL,
            values: ["body": .init(.text("pending edit"))], queuedStatus: "draft"))
        let loader = Self.loader(siteID: siteID, store: store, transport: Transport())
        let model = try (await loader.load(.new(typeID: "note"))).get()
        #expect(model.postURL == nil)
        #expect(model.values["body"] != .text("pending edit"))
        #expect(model.phase == .editing)
    }

    @Test("an existing post with no resolvable type is uneditable here")
    func existingWithoutDescriptorFails() async {
        let loader = Self.loader(siteID: UUID(), store: Self.scratchStore(), transport: Transport())
        let result = await loader.load(.existing(postURL: Self.postURL, descriptor: nil))
        #expect(result.failure == .uneditablePostType)
    }

    @Test("reopening a post with a pending edit of the same type restores it without a fetch")
    func existingPrefersPendingEdit() async throws {
        let siteID = UUID()
        let store = Self.scratchStore()
        try store.save(ComposerDraft(
            siteID: siteID, typeID: "note", postURL: Self.postURL,
            values: ["body": .init(.text("pending edit"))], queuedStatus: "draft"))
        let transport = Transport()
        let loader = Self.loader(siteID: siteID, store: store, transport: transport)
        let model = try (await loader.load(.existing(postURL: Self.postURL, descriptor: Self.note))).get()
        #expect(model.postURL == Self.postURL)
        #expect(model.values["body"] == .text("pending edit"))
        #expect(model.phase == .waitingForNetwork, "the queued send's state must be discoverable on reopen")
        #expect(transport.calls == 0)
    }

    @Test("a pending edit of a different type is ignored and the post is fetched")
    func existingIgnoresMismatchedPendingEdit() async throws {
        let siteID = UUID()
        let store = Self.scratchStore()
        try store.save(ComposerDraft(
            siteID: siteID, typeID: "article", postURL: Self.postURL,
            values: ["body": .init(.text("wrong type"))], queuedStatus: "draft"))
        let transport = Transport()
        let loader = Self.loader(siteID: siteID, store: store, transport: transport)
        let model = try (await loader.load(.existing(postURL: Self.postURL, descriptor: Self.note))).get()
        #expect(model.values["body"] == .text("from the server"))
        #expect(model.postURL == Self.postURL)
        #expect(transport.calls == 1)
    }

    @Test("a failed source fetch is reported as postFetchFailed")
    func existingFetchFailure() async {
        let loader = Self.loader(siteID: UUID(), store: Self.scratchStore(), transport: Transport(status: 500))
        let result = await loader.load(.existing(postURL: Self.postURL, descriptor: Self.note))
        #expect(result.failure == .postFetchFailed)
    }

    @Test("a list selection maps to a request, resolving an existing row's type through the list")
    func requestFromSelection() {
        let item = PostListModel.Item(id: Self.postURL, title: "Hello", collection: "notes", isDraft: false)
        let list = PostListModel(client: MicropubClient(
            endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
            transport: { _ in throw URLError(.notConnectedToInternet) }))

        #expect(ComposerLoadRequest(selection: .new(typeID: "note"), postList: list) == .new(typeID: "note"))
        #expect(ComposerLoadRequest(selection: .existing(item), postList: list)
                == .existing(postURL: Self.postURL, descriptor: Self.note))
        #expect(ComposerLoadRequest(selection: .existing(item), postList: nil)
                == .existing(postURL: Self.postURL, descriptor: nil))
    }

    @Test("a selection persists as its portable form: the type id, or just the post URL")
    func persistedSelectionMapping() {
        let item = PostListModel.Item(id: Self.postURL, title: "Hello", collection: "notes", isDraft: true)
        #expect(PersistedSelection(.new(typeID: "note")) == .new(typeID: "note"))
        #expect(PersistedSelection(.existing(item)) == .existing(postURL: Self.postURL))
    }
}

private extension Result where Failure == ComposerLoadFailure {
    var failure: ComposerLoadFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

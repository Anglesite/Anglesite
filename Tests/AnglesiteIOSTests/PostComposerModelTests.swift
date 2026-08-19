import Testing
import Foundation
// URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin platforms
// (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AnglesiteIOS
@testable import AnglesiteCore

/// A swappable `MicropubClient.Transport`: tests route requests by method/query and swap the
/// handler mid-test (e.g. heal the network after a failure) — the same faked-seam style as
/// `MicropubClientTests`, one level up.
private final class TransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(_ handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        _handler = handler
    }

    var handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    var transport: MicropubClient.Transport {
        { [self] request in try await handler(request) }
    }
}

/// Drives `PostComposerModel`'s publish state machine (#869) against a faked transport: the
/// foreground-first send, the retryable-failure → queued-draft → retry path, the auth and
/// terminal failures, and compare-and-swap conflict resolution.
@MainActor
struct PostComposerModelTests {
    nonisolated private static let endpoint = URL(string: "https://owner.example/micropub")!
    nonisolated private static let postURL = URL(string: "https://owner.example/notes/first-note")!

    nonisolated private static func response(
        _ code: Int, url: URL = endpoint, headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!
    }

    nonisolated private static func sourceJSON(properties: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "type": ["h-entry"], "properties": properties,
        ])
    }

    nonisolated private static func isSourceFetch(_ request: URLRequest) -> Bool {
        request.httpMethod == "GET"
            && request.url?.query()?.contains("q=source") == true
    }

    private static func scratchStore() -> ComposerDraftStore {
        ComposerDraftStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("composer-tests-\(UUID().uuidString)", isDirectory: true))
    }

    private static func noteDescriptor() -> ContentTypeDescriptor {
        ContentTypeRegistry.default.descriptor(id: "note")!
    }

    private static func model(
        transport: @escaping MicropubClient.Transport,
        store: ComposerDraftStore = scratchStore(),
        siteID: UUID = UUID()
    ) -> PostComposerModel {
        PostComposerModel(
            descriptor: noteDescriptor(),
            siteID: siteID,
            client: MicropubClient(
                endpoint: endpoint, mediaEndpoint: URL(string: "https://owner.example/media"),
                accessToken: "tok", dpopKeyPair: DPoPKeyPair(), transport: transport),
            draftStore: store
        )
    }

    // MARK: - Foreground-first send

    @Test("a successful save lands savedDraft with the created post's URL")
    func saveDraftCreates() async throws {
        // A create is exactly one POST — the CAS baseline is constructed locally, no refetch.
        let box = TransportBox { request in
            #expect(request.httpMethod == "POST")
            return (Data(), Self.response(201, headers: ["Location": Self.postURL.absoluteString]))
        }
        let model = Self.model(transport: box.transport)
        model.values["body"] = .text("hi")

        await model.saveDraft()

        let phase = model.phase
        #expect(phase == .savedDraft(Self.postURL))
        let url = model.postURL
        #expect(url == Self.postURL)
    }

    @Test("a restricted composition stamps visibility: contacts on create")
    func saveDraftStampsContactsVisibility() async throws {
        nonisolated(unsafe) var capturedProperties: [String: [Any]]?
        let box = TransportBox { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            capturedProperties = body?["properties"] as? [String: [Any]]
            return (Data(), Self.response(201, headers: ["Location": Self.postURL.absoluteString]))
        }
        let model = Self.model(transport: box.transport)
        model.values["body"] = .text("hi")
        model.visibility = .contacts

        await model.saveDraft()

        let properties = try #require(capturedProperties)
        #expect(properties["visibility"] as? [String] == ["contacts"])
    }

    @Test("opening an existing restricted post reads its visibility back")
    func openExistingReadsVisibility() async throws {
        let box = TransportBox { request in
            (Self.sourceJSON(properties: ["content": ["hi"], "visibility": ["contacts"]]), Self.response(200))
        }
        let model = try await PostComposerModel.openExisting(
            url: Self.postURL, descriptor: Self.noteDescriptor(), siteID: UUID(),
            client: MicropubClient(
                endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                transport: box.transport))
        #expect(model.visibility == .contacts)
    }

    @Test("an untouched visibility picker sends no visibility at all on update")
    func updateOmitsUntouchedVisibility() async throws {
        // The stored tier is one this client's enum doesn't model (the Worker's vocabulary is
        // wider), so `MicropubPost.visibility` reads it back as `.public`. Re-stamping that lossy
        // read would republish a restricted post to the world — the update must omit the property.
        let stored: [String: Any] = ["content": ["original"], "visibility": ["unlisted"]]
        nonisolated(unsafe) var updateBody: [String: Any]?
        let box = TransportBox { request in
            if Self.isSourceFetch(request) {
                return (Self.sourceJSON(properties: stored), Self.response(200))
            }
            updateBody = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: Any]
            return (Data(), Self.response(204))
        }
        let model = try await Self.existingModel(box: box)
        #expect(model.visibility == .public)  // the lossy read this fix must not act on
        model.values["body"] = .text("an edit that has nothing to do with audience")

        await model.saveDraft()

        let phase = model.phase
        #expect(phase == .savedDraft(Self.postURL))
        let replace = try #require(updateBody?["replace"] as? [String: [Any]])
        #expect(replace["visibility"] == nil)
        #expect(replace["content"] as? [String] == ["an edit that has nothing to do with audience"])
        // Nor may it be deleted — `visibility` isn't a descriptor-mapped property, so the
        // cleared-property pass must leave it alone too; the server's `unlisted` survives intact.
        let deleted = updateBody?["delete"] as? [String] ?? []
        #expect(!deleted.contains("visibility"))
    }

    @Test("deliberately changing the picker on an existing post does send the new value")
    func updateSendsChangedVisibility() async throws {
        let stored: [String: Any] = ["content": ["original"], "visibility": ["public"]]
        nonisolated(unsafe) var capturedReplace: [String: [Any]]?
        let box = TransportBox { request in
            if Self.isSourceFetch(request) {
                return (Self.sourceJSON(properties: stored), Self.response(200))
            }
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: Any]
            capturedReplace = body?["replace"] as? [String: [Any]]
            return (Data(), Self.response(204))
        }
        let model = try await Self.existingModel(box: box)
        model.visibility = .contacts

        await model.saveDraft()

        let replace = try #require(capturedReplace)
        #expect(replace["visibility"] as? [String] == ["contacts"])
    }

    @Test("a queued restricted composition's visibility survives a persisted draft restore")
    func draftRestoresVisibility() {
        let store = Self.scratchStore()
        let siteID = UUID()
        let model = Self.model(transport: { _ in fatalError("no network expected") }, store: store, siteID: siteID)
        model.values["body"] = .text("hi")
        model.visibility = .contacts
        model.persistDraft()

        let restoredDraft = store.loadNewDraft(forSite: siteID, typeID: Self.noteDescriptor().id)
        let restored = try! #require(restoredDraft)
        #expect(restored.visibility == "contacts")

        let restoredModel = PostComposerModel(
            descriptor: Self.noteDescriptor(), siteID: siteID,
            client: MicropubClient(
                endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                transport: { _ in fatalError("no network expected") }),
            draftStore: store, restoringDraft: restored)
        #expect(restoredModel.visibility == .contacts)
    }

    @Test("publish lands publishedRebuilding — the bake-in-flight state, no faked live URL")
    func publishShowsRebuilding() async {
        let box = TransportBox { request in
            if Self.isSourceFetch(request) {
                return (Self.sourceJSON(properties: ["content": ["hi"]]), Self.response(200))
            }
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: Any]
            let properties = body?["properties"] as? [String: [Any]]
            #expect(properties?["post-status"] as? [String] == ["published"])
            return (Data(), Self.response(201, headers: ["Location": Self.postURL.absoluteString]))
        }
        let model = Self.model(transport: box.transport)
        model.values["body"] = .text("hi")

        await model.publish()

        let phase = model.phase
        #expect(phase == .publishedRebuilding(Self.postURL))
    }

    // MARK: - Failure routing (#867's taxonomy, surfaced as phases)

    @Test("a 401 routes to authRequired — an IndieAuth matter, not a network failure")
    func unauthorizedRoutesToReauth() async {
        let box = TransportBox { _ in (Data(), Self.response(401)) }
        let model = Self.model(transport: box.transport)
        model.values["body"] = .text("hi")

        await model.saveDraft()

        let phase = model.phase
        #expect(phase == .authRequired)
    }

    @Test("a terminal 4xx routes to failed, not the offline queue")
    func terminalFailureNotQueued() async {
        let store = Self.scratchStore()
        let siteID = UUID()
        let box = TransportBox { _ in (Data(), Self.response(422)) }
        let model = Self.model(transport: box.transport, store: store, siteID: siteID)
        model.values["body"] = .text("hi")

        await model.saveDraft()

        guard case .failed = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        let queued = store.loadNewDraft(forSite: siteID, typeID: "note")
        #expect(queued == nil)
    }

    @Test("a 5xx queues the draft locally with the explicit waiting-for-network state")
    func retryableFailureQueuesDraft() async throws {
        let store = Self.scratchStore()
        let siteID = UUID()
        let box = TransportBox { _ in (Data(), Self.response(503)) }
        let model = Self.model(transport: box.transport, store: store, siteID: siteID)
        model.values["body"] = .text("composed offline")

        await model.publish()

        let phase = model.phase
        #expect(phase == .waitingForNetwork)
        let queued = try #require(store.loadNewDraft(forSite: siteID, typeID: "note"))
        #expect(queued.queuedStatus == "published")
        let body = queued.editorValues["body"]
        #expect(body == .text("composed offline"))
    }

    @Test("an unreachable network queues the same way")
    func unreachableQueuesDraft() async {
        let box = TransportBox { _ in throw URLError(.notConnectedToInternet) }
        let model = Self.model(transport: box.transport)
        model.values["body"] = .text("hi")

        await model.saveDraft()

        let phase = model.phase
        #expect(phase == .waitingForNetwork)
    }

    @Test("retry after the network heals sends the queued status and clears the local draft")
    func retryAfterHealing() async {
        let store = Self.scratchStore()
        let siteID = UUID()
        let box = TransportBox { _ in (Data(), Self.response(503)) }
        let model = Self.model(transport: box.transport, store: store, siteID: siteID)
        model.values["body"] = .text("hi")
        await model.publish()

        box.handler = { request in
            if Self.isSourceFetch(request) {
                return (Self.sourceJSON(properties: ["content": ["hi"]]), Self.response(200))
            }
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: Any]
            let properties = body?["properties"] as? [String: [Any]]
            // The retried send must carry the status that was queued, not a default.
            #expect(properties?["post-status"] as? [String] == ["published"])
            return (Data(), Self.response(201, headers: ["Location": Self.postURL.absoluteString]))
        }
        await model.retry()

        let phase = model.phase
        #expect(phase == .publishedRebuilding(Self.postURL))
        let queued = store.loadNewDraft(forSite: siteID, typeID: "note")
        #expect(queued == nil)
    }

    @Test("a queued draft restores into waitingForNetwork across a relaunch")
    func queuedDraftRestores() {
        let siteID = UUID()
        let draft = ComposerDraft(
            siteID: siteID, typeID: "note", postURL: nil,
            values: ["body": .text("restored body")], queuedStatus: "draft")
        let box = TransportBox { _ in (Data(), Self.response(500)) }
        let model = PostComposerModel(
            descriptor: Self.noteDescriptor(), siteID: siteID,
            client: MicropubClient(
                endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                transport: box.transport),
            draftStore: Self.scratchStore(),
            restoringDraft: draft)

        let phase = model.phase
        #expect(phase == .waitingForNetwork)
        let body = model.values["body"]
        #expect(body == .text("restored body"))
    }

    // MARK: - Editing an existing post (q=source + compare-and-swap)

    private static func existingModel(box: TransportBox) async throws -> PostComposerModel {
        try await PostComposerModel.openExisting(
            url: postURL,
            descriptor: noteDescriptor(),
            siteID: UUID(),
            client: MicropubClient(
                endpoint: endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                transport: box.transport),
            draftStore: scratchStore()
        )
    }

    @Test("openExisting decodes the q=source post into form values")
    func openExistingDecodes() async throws {
        let box = TransportBox { request in
            #expect(Self.isSourceFetch(request))
            return (
                Self.sourceJSON(properties: [
                    "content": ["the body"], "category": ["one", "two"],
                    "post-status": ["draft"],
                ]),
                Self.response(200)
            )
        }
        let model = try await Self.existingModel(box: box)

        let body = model.values["body"]
        #expect(body == .text("the body"))
        let tags = model.values["tags"]
        #expect(tags == .list(["one", "two"]))
        let url = model.postURL
        #expect(url == Self.postURL)
    }

    @Test("a server copy that changed since the baseline surfaces as a conflict, not an update")
    func concurrentEditConflicts() async throws {
        let baseline: [String: Any] = ["content": ["original"]]
        let box = TransportBox { _ in
            (Self.sourceJSON(properties: baseline), Self.response(200))
        }
        let model = try await Self.existingModel(box: box)
        model.values["body"] = .text("my edit")

        // Another device edited the post: the pre-update CAS re-fetch now sees a new copy.
        let theirs: [String: Any] = ["content": ["their newer edit"]]
        box.handler = { request in
            #expect(Self.isSourceFetch(request), "no update may be sent on a conflict")
            return (Self.sourceJSON(properties: theirs), Self.response(200))
        }
        await model.saveDraft()

        guard case .conflict(let theirPost) = model.phase else {
            Issue.record("expected .conflict, got \(model.phase)")
            return
        }
        let theirContent = theirPost.firstString("content")
        #expect(theirContent == "their newer edit")
    }

    @Test("takeTheirs adopts the site's version and returns to editing")
    func takeTheirsAdopts() async throws {
        let box = TransportBox { _ in
            (Self.sourceJSON(properties: ["content": ["original"]]), Self.response(200))
        }
        let model = try await Self.existingModel(box: box)
        model.values["body"] = .text("my edit")
        box.handler = { _ in
            (Self.sourceJSON(properties: ["content": ["their newer edit"]]), Self.response(200))
        }
        await model.saveDraft()

        model.takeTheirs()

        let phase = model.phase
        #expect(phase == .editing)
        let body = model.values["body"]
        #expect(body == .text("their newer edit"))
    }

    @Test("keepMine re-sends over the site's version after re-baselining")
    func keepMineOverwrites() async throws {
        let box = TransportBox { _ in
            (Self.sourceJSON(properties: ["content": ["original"]]), Self.response(200))
        }
        let model = try await Self.existingModel(box: box)
        model.values["body"] = .text("my edit")
        let theirs: [String: Any] = ["content": ["their newer edit"]]
        box.handler = { _ in (Self.sourceJSON(properties: theirs), Self.response(200)) }
        await model.saveDraft()

        // The site still holds "theirs"; keeping mine must now update straight over it.
        nonisolated(unsafe) var updateBody: [String: Any]?
        box.handler = { request in
            if Self.isSourceFetch(request) {
                return (Self.sourceJSON(properties: theirs), Self.response(200))
            }
            updateBody = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: Any]
            return (Data(), Self.response(204))
        }
        await model.keepMine()

        let phase = model.phase
        #expect(phase == .savedDraft(Self.postURL))
        let action = updateBody?["action"] as? String
        #expect(action == "update")
        let replaced = (updateBody?["replace"] as? [String: [Any]])?["content"] as? [String]
        #expect(replaced == ["my edit"])
    }

    @Test("clearing a mapped field deletes its property; unmapped properties stay untouched")
    func clearedFieldsDelete() async throws {
        let box = TransportBox { _ in
            (
                Self.sourceJSON(properties: [
                    "content": ["body"], "category": ["old-tag"],
                    "syndication": ["https://social.example/123"],   // another client's property
                ]),
                Self.response(200)
            )
        }
        let model = try await Self.existingModel(box: box)
        model.values["tags"] = .list([])   // owner cleared the tags in the form

        nonisolated(unsafe) var updateBody: [String: Any]?
        box.handler = { request in
            if Self.isSourceFetch(request) {
                return (
                    Self.sourceJSON(properties: [
                        "content": ["body"], "category": ["old-tag"],
                        "syndication": ["https://social.example/123"],
                    ]),
                    Self.response(200)
                )
            }
            updateBody = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: Any]
            return (Data(), Self.response(204))
        }
        await model.saveDraft()

        let deleted = updateBody?["delete"] as? [String]
        #expect(deleted == ["category"])
        let replace = updateBody?["replace"] as? [String: [Any]]
        #expect(replace?["syndication"] == nil)
    }

    // MARK: - Media guard (§7: error handling before the upload, not compression UX)

    @Test("the media guard rejects before any request; a passing image uploads")
    func mediaGuardAndUpload() async throws {
        nonisolated(unsafe) var requestCount = 0
        let box = TransportBox { _ in
            requestCount += 1
            return (Data(), Self.response(
                201, headers: ["Location": "https://owner.example/media/a.jpg"]))
        }
        let model = Self.model(transport: box.transport)

        await #expect(throws: PostComposerModel.MediaUploadError.rejected(.empty)) {
            _ = try await model.uploadImage(data: Data(), filename: "a.jpg", mimeType: "image/jpeg")
        }
        await #expect(throws: PostComposerModel.MediaUploadError.rejected(
            .unsupportedFormat(mimeType: "image/heic"))
        ) {
            _ = try await model.uploadImage(
                data: Data([1]), filename: "a.heic", mimeType: "image/heic")
        }
        let oversized = Data(count: MediaUploadGuard.maximumBytes + 1)
        await #expect(throws: PostComposerModel.MediaUploadError.rejected(
            .tooLarge(bytes: oversized.count))
        ) {
            _ = try await model.uploadImage(
                data: oversized, filename: "a.jpg", mimeType: "image/jpeg")
        }
        #expect(requestCount == 0, "rejections must never reach the network")

        let url = try await model.uploadImage(
            data: Data([0xFF, 0xD8]), filename: "a.jpg", mimeType: "image/jpeg")
        #expect(url == URL(string: "https://owner.example/media/a.jpg")!)
        #expect(requestCount == 1)
    }

    // MARK: - #1370 review regressions

    @Test("a terminal 4xx on retry clears the previously queued draft")
    func terminalRetryClearsQueuedDraft() async {
        let store = Self.scratchStore()
        let siteID = UUID()
        let box = TransportBox { _ in (Data(), Self.response(503)) }
        let model = Self.model(transport: box.transport, store: store, siteID: siteID)
        model.values["body"] = .text("hi")
        await model.saveDraft()
        #expect(store.loadNewDraft(forSite: siteID, typeID: "note") != nil)

        // The retry is answered with a validation rejection: the payload can never succeed,
        // so the on-disk draft must not resurrect it as "waiting for network" next launch.
        box.handler = { _ in (Data(), Self.response(422)) }
        await model.retry()

        guard case .failed = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        let queued = store.loadNewDraft(forSite: siteID, typeID: "note")
        #expect(queued == nil)
    }

    @Test("CAS survives a completed update — no refetch, baseline constructed locally")
    func casSurvivesCompletedUpdate() async throws {
        let original: [String: Any] = ["content": ["original"], "category": ["keep-me"]]
        nonisolated(unsafe) var capturedReplace: [String: [Any]]?
        let box = TransportBox { request in
            if Self.isSourceFetch(request) {
                return (Self.sourceJSON(properties: original), Self.response(200))
            }
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: Any]
            capturedReplace = body?["replace"] as? [String: [Any]]
            return (Data(), Self.response(204))
        }
        let model = try await Self.existingModel(box: box)
        model.values["body"] = .text("first edit")
        await model.saveDraft()
        let firstPhase = model.phase
        #expect(firstPhase == .savedDraft(Self.postURL))

        // The server now holds exactly what the update wrote. The next save's CAS fetch
        // returns that state — it must match the locally-constructed baseline (which the old
        // `try?`-refetch code silently nulled on any blip), so no conflict fires...
        var serverNow = original
        for (name, values) in capturedReplace ?? [:] { serverNow[name] = values }
        model.resumeEditing()
        model.values["body"] = .text("second edit")
        box.handler = { request in
            if Self.isSourceFetch(request) {
                return (Self.sourceJSON(properties: serverNow), Self.response(200))
            }
            return (Data(), Self.response(204))
        }
        await model.saveDraft()
        let secondPhase = model.phase
        #expect(secondPhase == .savedDraft(Self.postURL))

        // ...while a genuinely concurrent edit still does.
        model.resumeEditing()
        model.values["body"] = .text("third edit")
        box.handler = { request in
            #expect(Self.isSourceFetch(request), "no update may be sent on a conflict")
            return (
                Self.sourceJSON(properties: ["content": ["their concurrent edit"]]),
                Self.response(200)
            )
        }
        await model.saveDraft()
        guard case .conflict = model.phase else {
            Issue.record("expected .conflict, got \(model.phase)")
            return
        }
    }

    @Test("cleared fields still delete on the save after a completed save")
    func clearedFieldsDeleteAfterPriorSave() async throws {
        let original: [String: Any] = ["content": ["body"], "category": ["old-tag"]]
        nonisolated(unsafe) var capturedReplace: [String: [Any]]?
        let box = TransportBox { request in
            if Self.isSourceFetch(request) {
                return (Self.sourceJSON(properties: original), Self.response(200))
            }
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: Any]
            capturedReplace = body?["replace"] as? [String: [Any]]
            return (Data(), Self.response(204))
        }
        let model = try await Self.existingModel(box: box)
        await model.saveDraft()

        // Clear the tags only on the SECOND save: the delete is computed against the
        // locally-updated baseline, which must still know `category` exists server-side.
        var serverNow = original
        for (name, values) in capturedReplace ?? [:] { serverNow[name] = values }
        model.resumeEditing()
        model.values["tags"] = .list([])
        nonisolated(unsafe) var capturedDelete: [String]?
        box.handler = { request in
            if Self.isSourceFetch(request) {
                return (Self.sourceJSON(properties: serverNow), Self.response(200))
            }
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: Any]
            capturedDelete = body?["delete"] as? [String]
            return (Data(), Self.response(204))
        }
        await model.saveDraft()

        #expect(capturedDelete == ["category"])
    }

    @Test("a restored queued update keeps its CAS baseline — retry over a concurrent edit conflicts")
    func restoredQueuedUpdateKeepsCASBaseline() async {
        let siteID = UUID()
        let baseline = MicropubPost(properties: ["content": [.string("original")]])
        let draft = ComposerDraft(
            siteID: siteID, typeID: "note", postURL: Self.postURL,
            values: ["body": .text("my queued edit")], queuedStatus: "draft",
            baselineJSON: ComposerDraft.encodeBaseline(baseline))
        let box = TransportBox { request in
            #expect(Self.isSourceFetch(request), "no update may be sent on a conflict")
            return (
                Self.sourceJSON(properties: ["content": ["their concurrent edit"]]),
                Self.response(200)
            )
        }
        let model = PostComposerModel(
            descriptor: Self.noteDescriptor(), siteID: siteID,
            client: MicropubClient(
                endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                transport: box.transport),
            draftStore: Self.scratchStore(),
            restoringDraft: draft)
        let restoredPhase = model.phase
        #expect(restoredPhase == .waitingForNetwork)

        await model.retry()

        guard case .conflict(let theirs) = model.phase else {
            Issue.record("expected .conflict, got \(model.phase)")
            return
        }
        let theirContent = theirs.firstString("content")
        #expect(theirContent == "their concurrent edit")
    }

    @Test("openExisting throws for a post whose required field can't be decoded")
    func openExistingUndecodableThrows() async {
        // `photo` requires its `image` field, which has no decode fallback — a source post
        // without `photo` must fail the open, never silently blank the form over a live
        // baseline (whose delete pass would then wipe the post server-side).
        let box = TransportBox { _ in
            (Self.sourceJSON(properties: ["summary": ["a caption, no image"]]), Self.response(200))
        }
        let photo = ContentTypeRegistry.default.descriptor(id: "photo")!
        do {
            _ = try await PostComposerModel.openExisting(
                url: URL(string: "https://owner.example/photos/p1")!,
                descriptor: photo,
                siteID: UUID(),
                client: MicropubClient(
                    endpoint: Self.endpoint, accessToken: "tok", dpopKeyPair: DPoPKeyPair(),
                    transport: box.transport))
            Issue.record("expected openExisting to throw")
        } catch let error as MicropubError {
            guard case .decodingFailed = error else {
                Issue.record("expected .decodingFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("expected MicropubError, got \(error)")
        }
    }

    @Test("queued-update and new-composition drafts coexist per site, each behind its own key")
    func draftStoreKeysByIdentity() throws {
        let store = Self.scratchStore()
        let siteID = UUID()
        let newNote = ComposerDraft(
            siteID: siteID, typeID: "note", postURL: nil,
            values: ["body": .text("fresh note")])
        let queuedUpdate = ComposerDraft(
            siteID: siteID, typeID: "article", postURL: Self.postURL,
            values: ["body": .text("queued update")], queuedStatus: "published")
        try store.save(newNote)
        try store.save(queuedUpdate)

        // Neither overwrote the other, and neither entry point sees the wrong one: "New Post"
        // never surfaces a queued update, and the post's own reopen path finds its edit.
        let restoredNew = store.loadNewDraft(forSite: siteID, typeID: "note")
        #expect(restoredNew == newNote)
        let restoredQueued = store.loadDraft(forSite: siteID, postURL: Self.postURL)
        #expect(restoredQueued == queuedUpdate)
        let noArticleNew = store.loadNewDraft(forSite: siteID, typeID: "article")
        #expect(noArticleNew == nil)

        store.clear(queuedUpdate)
        let cleared = store.loadDraft(forSite: siteID, postURL: Self.postURL)
        #expect(cleared == nil)
        let survivor = store.loadNewDraft(forSite: siteID, typeID: "note")
        #expect(survivor == newNote)
    }
}

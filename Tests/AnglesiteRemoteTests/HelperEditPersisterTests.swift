import Testing
import Foundation
import AnglesiteCore
import AnglesiteP2P
import AnglesiteTestSupport
@testable import AnglesiteRemote

@Suite struct HelperEditPersisterTests {
    /// A `tools/call` JSON-RPC response carrying `apply_edit`'s structured content body.
    static func applyEditReply(id: Int, commit: String?, isError: Bool = false) -> JSONValue {
        var body: [String: JSONValue] = ["file": .string("src/pages/index.astro")]
        if let commit { body["commit"] = .string(commit) }
        let bodyText = String(decoding: try! JSONSerialization.data(withJSONObject: JSONValue.object(body).rawValue), as: UTF8.self)
        return .object([
            "jsonrpc": .string("2.0"), "id": .int(id),
            "result": .object([
                "content": .array([.object(["type": .string("text"), "text": .string(bodyText)])]),
                "isError": .bool(isError),
            ]),
        ])
    }

    @Test func passesThroughAReplyWithNoCommitUnchanged() async {
        let reply = Self.applyEditReply(id: 1, commit: nil)
        var exportCalled = false
        let persister = HelperEditPersister(
            wrapping: { _ in reply }, siteID: "site-1", control: FakeLocalContainerControl(),
            sourceDirectory: URL(fileURLWithPath: "/tmp/source"), onLog: { _, _ in },
            exportAndImport: { _, _, _, _, _ in exportCalled = true })
        let result = await persister.handle(.object(["jsonrpc": .string("2.0"), "id": .int(1)]))
        #expect(result == reply)
        #expect(!exportCalled)
    }

    @Test func persistsAndPassesThroughUnchangedOnSuccess() async {
        let reply = Self.applyEditReply(id: 2, commit: "abcdef0")
        var capturedCommit: String?
        let persister = HelperEditPersister(
            wrapping: { _ in reply }, siteID: "site-1", control: FakeLocalContainerControl(),
            sourceDirectory: URL(fileURLWithPath: "/tmp/source"), onLog: { _, _ in },
            exportAndImport: { commit, siteID, _, source, _ in
                capturedCommit = commit
                #expect(siteID == "site-1")
                #expect(source == URL(fileURLWithPath: "/tmp/source"))
            })
        let result = await persister.handle(.object(["jsonrpc": .string("2.0"), "id": .int(2)]))
        #expect(result == reply)
        #expect(capturedCommit == "abcdef0")
    }

    @Test func synthesizesAnErrorReplyWhenPersistFails() async {
        let reply = Self.applyEditReply(id: 3, commit: "abcdef0")
        var loggedFailure = false
        let persister = HelperEditPersister(
            wrapping: { _ in reply }, siteID: "site-1", control: FakeLocalContainerControl(),
            sourceDirectory: URL(fileURLWithPath: "/tmp/source"),
            onLog: { line, stream in if stream == .stderr { loggedFailure = true } },
            exportAndImport: { _, _, _, _, _ in throw SiteRuntimePersistenceError.syncFailed("disk full") })
        let result = await persister.handle(.object(["jsonrpc": .string("2.0"), "id": .int(3)]))
        guard case .object(let obj)? = result, case .object(let errorObj)? = obj["error"] else {
            Issue.record("expected a JSON-RPC error object, got \(String(describing: result))")
            return
        }
        #expect(obj["id"] == .int(3))
        if case .string(let message)? = errorObj["message"] {
            #expect(message.contains("disk full"))
        } else {
            Issue.record("error object had no message")
        }
        #expect(loggedFailure)
    }

    @Test func ignoresErrorRepliesEvenIfTheyCarryACommitLikeString() async {
        // isError:true replies never trigger persistence — a tool-level failure has nothing valid
        // to export, regardless of what its content text happens to contain.
        let reply = Self.applyEditReply(id: 4, commit: "abcdef0", isError: true)
        var exportCalled = false
        let persister = HelperEditPersister(
            wrapping: { _ in reply }, siteID: "site-1", control: FakeLocalContainerControl(),
            sourceDirectory: URL(fileURLWithPath: "/tmp/source"), onLog: { _, _ in },
            exportAndImport: { _, _, _, _, _ in exportCalled = true })
        _ = await persister.handle(.object(["jsonrpc": .string("2.0"), "id": .int(4)]))
        #expect(!exportCalled)
    }

    @Test func notificationsPassThroughWithoutInspection() async {
        let persister = HelperEditPersister(
            wrapping: { _ in nil }, siteID: "site-1", control: FakeLocalContainerControl(),
            sourceDirectory: URL(fileURLWithPath: "/tmp/source"), onLog: { _, _ in },
            exportAndImport: { _, _, _, _, _ in Issue.record("must not be called") })
        let result = await persister.handle(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/x")]))
        #expect(result == nil)
    }
}

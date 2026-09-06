import Testing
import AnglesiteTestSupport
@testable import AnglesiteCore

struct MCPApplyEditRouterTests {
    private static let sampleSelector: JSONValue = .object([
        "tag": .string("P"),
        "classes": .array([]),
        "nthChild": .int(2),
    ])

    private let sampleMessage = EditMessage(
        id: "e-1",
        type: .applyEdit,
        path: "/about/",
        selector: MCPApplyEditRouterTests.sampleSelector,
        op: "replace-text",
        value: .string("Hello, world.")
    )

    @Test("Calls apply-edit tool with edit message as arguments") func callsApplyEditToolWithEditMessageAsArguments() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(content: [], isError: false)))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        _ = await router.apply(sampleMessage)

        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.name == "apply_edit")
        #expect(
            calls.first?.arguments == .object([
                "id": .string("e-1"),
                "type": .string("anglesite:apply-edit"),
                "path": .string("/about/"),
                "selector": MCPApplyEditRouterTests.sampleSelector,
                "op": .string("replace-text"),
                "value": .string("Hello, world."),
            ])
        )
    }

    @Test("Successful tool result maps to applied") func successfulToolResultMapsToApplied() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "patched /about.mdoc range 12-25")],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.id == "e-1")
        #expect(reply.status == .applied)
        #expect(reply.message == "patched /about.mdoc range 12-25")
    }

    @Test("Is-error result maps to failed with tool message") func isErrorResultMapsToFailedWithToolMessage() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "selector resolved to two nodes")],
            isError: true
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.status == .failed)
        #expect(reply.message == "selector resolved to two nodes")
    }

    @Test("Thrown error maps to failed") func thrownErrorMapsToFailed() async {
        let recorder = ToolCallRecorder(result: .failure(MCPClient.MCPError.notInitialized))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.status == .failed)
        #expect(reply.message != nil)
    }

    @Test("unsupportedOp maps to a clear message and machine-readable reason, not the raw error dump")
    func unsupportedOpMapsToClearMessage() async {
        // #1415: a stale vendored sidecar's tools/list schema doesn't list this op. The router
        // must not fall through to its generic `"\(error)"` catch, which would surface the raw
        // `unsupportedOp(op: "insert-image")` Swift enum dump as the toast text.
        let recorder = ToolCallRecorder(result: .failure(MCPClient.MCPError.unsupportedOp(op: "insert-image")))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.status == .failed)
        #expect(reply.reason == "unsupported-op")
        #expect(reply.message?.contains("insert-image") == true)
        #expect(reply.message?.contains("unsupportedOp") == false)
    }

    // MARK: structured reply parse

    @Test("Successful reply with structured body exposes structured fields") func successfulReplyWithStructuredBodyExposesStructuredFields() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345"}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.status == .applied)
        #expect(reply.file == "src/pages/about.astro")
        #expect(reply.commit == "abc1234567890abcdef1234567890abcdef12345")
        #expect(reply.result == nil)
    }

    @Test("Successful reply with result exposes image result") func successfulReplyWithResultExposesImageResult() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345","result":{"src":"/images/hero.webp","srcset":"/images/hero-480w.webp 480w"}}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.result?.src == "/images/hero.webp")
        #expect(reply.result?.srcset == "/images/hero-480w.webp 480w")
    }

    @Test("Successful reply with a top-level newFile exposes newFile, no result object") func successfulReplyWithNewFileExposesNewFile() async {
        // `extract-component` reports the created file as a plain top-level `newFile` string
        // (sibling to `file`/`commit`), with NO `result` object at all.
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/components/Card.astro","range":{"start":40,"end":120},"commit":"abc1234567890abcdef1234567890abcdef12345","newFile":"src/components/Hero.astro"}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.status == .applied)
        #expect(reply.file == "src/components/Card.astro")
        #expect(reply.newFile == "src/components/Hero.astro")
        #expect(reply.result == nil)
    }

    @Test("Structured reply with inverse exposes inverseNodeId and postWriteVersion")
    func structuredReplyWithInverseExposesInverseFields() async {
        // insertBlock's reply carries a computed `inverse: {op: "deleteBlock", component: {path,
        // nodeId, baseVersion}}` — `baseVersion` here is the POST-write hash the dispatcher
        // stamps in (see server/apply-edit-dispatcher.mjs). The router must decode just
        // `nodeId`/`baseVersion` out of it, narrowly, without adopting the rest of `inverse` as a
        // general mechanism (see EditRouter.swift's EditReply doc comments).
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345","inverse":{"op":"deleteBlock","component":{"path":"src/pages/about.astro","nodeId":"n42","baseVersion":"sha256:postwrite111"}}}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.status == .applied)
        #expect(reply.inverseNodeId == "n42")
        #expect(reply.postWriteVersion == "sha256:postwrite111")
    }

    @Test("Structured reply with no inverse key decodes nil inverseNodeId/postWriteVersion")
    func structuredReplyWithNoInverseDecodesNilInverseFields() async {
        // Most ops' replies (and this one, a plain edit-applied body) carry no `inverse` key at
        // all — the decode must not throw or misbehave, and the reply's other structured fields
        // (`commit` here) must still decode normally alongside the nil inverse fields.
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345"}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.status == .applied)
        #expect(reply.commit == "abc1234567890abcdef1234567890abcdef12345")
        #expect(reply.inverseNodeId == nil)
        #expect(reply.postWriteVersion == nil)
    }

    @Test("Structured reply with inverse exposes the full inverseOp/inverseComponent")
    func structuredReplyWithInverseExposesFullInverse() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345","inverse":{"op":"deleteBlock","component":{"path":"src/pages/about.astro","nodeId":"n42","baseVersion":"sha256:postwrite111"}}}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.inverseOp == "deleteBlock")
        guard case .object(let component)? = reply.inverseComponent else {
            Issue.record("expected inverseComponent to decode as an object"); return
        }
        #expect(component["nodeId"] == .string("n42"))
        #expect(component["baseVersion"] == .string("sha256:postwrite111"))
    }

    @Test("Structured reply with no inverse key decodes nil inverseOp/inverseComponent")
    func structuredReplyWithNoInverseDecodesNilFullInverse() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345"}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.inverseOp == nil)
        #expect(reply.inverseComponent == nil)
    }

    @Test("Malformed reply text falls back to message string") func malformedReplyTextFallsBackToMessageString() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "not valid json {")],
            isError: false
        )))
        let router = MCPApplyEditRouter(toolCaller: { try await recorder.call(name: $0, arguments: $1) })
        let reply = await router.apply(sampleMessage)
        #expect(reply.status == .applied)
        #expect(reply.message == "not valid json {")
        #expect(reply.file == nil)
        #expect(reply.commit == nil)
    }

    @Test("On edit fires for applied reply with commit") func onEditFiresForAppliedReplyWithCommit() async throws {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","range":{"start":12,"end":25},"commit":"abc1234567890abcdef1234567890abcdef12345"}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let observed = ObservedReplies()
        let router = MCPApplyEditRouter(
            toolCaller: { try await recorder.call(name: $0, arguments: $1) },
            onEdit: { reply in Task { await observed.record(reply) } }
        )
        _ = await router.apply(sampleMessage)
        try await waitUntil("onEdit's detached Task to record the reply") { await !observed.replies.isEmpty }
        let captured = await observed.replies
        #expect(captured.count == 1)
        #expect(captured.first?.commit == "abc1234567890abcdef1234567890abcdef12345")
    }

    @Test("Successful edit is persisted before it is reported as applied")
    func successfulEditAwaitsPersistence() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","commit":"abc1234567890abcdef1234567890abcdef12345"}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let persisted = ObservedReplies()
        let router = MCPApplyEditRouter(
            toolCaller: { try await recorder.call(name: $0, arguments: $1) },
            persistEdit: { await persisted.record($0) }
        )

        let reply = await router.apply(sampleMessage)

        #expect(reply.status == .applied)
        #expect(await persisted.replies.map(\.commit) == ["abc1234567890abcdef1234567890abcdef12345"])
    }

    @Test("Persistence failure turns the edit reply into a visible failure")
    func persistenceFailureIsNotAcknowledgedAsApplied() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","commit":"abc1234567890abcdef1234567890abcdef12345"}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let observed = ObservedReplies()
        let router = MCPApplyEditRouter(
            toolCaller: { try await recorder.call(name: $0, arguments: $1) },
            onEdit: { reply in Task { await observed.record(reply) } },
            persistEdit: { _ in throw SiteRuntimePersistenceError.syncFailed("canonical repo is dirty") }
        )

        let reply = await router.apply(sampleMessage)

        #expect(reply.status == .failed)
        #expect(reply.message?.contains("couldn't be saved to Source") == true)
        #expect(reply.message?.contains("canonical repo is dirty") == true)
        // Not persisted — a consumer keying off `commit != nil` instead of `status` must not
        // mistake this for a landed edit.
        #expect(reply.commit == nil)
        #expect(await observed.replies.isEmpty)
    }

    @Test("On edit does not fire when reply has no commit") func onEditDoesNotFireWhenReplyHasNoCommit() async {
        // No JSON in the content — parser gives up; reply has nil commit; observer must NOT fire.
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "stub edit response")],
            isError: false
        )))
        let observed = ObservedReplies()
        let router = MCPApplyEditRouter(
            toolCaller: { try await recorder.call(name: $0, arguments: $1) },
            onEdit: { reply in Task { await observed.record(reply) } }
        )
        _ = await router.apply(sampleMessage)
        // Negative assertion (onEdit must not fire): there's no event to wait for, so this
        // settles briefly and confirms nothing landed, rather than polling for absence.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let captured = await observed.replies
        #expect(captured.isEmpty)
    }

    @Test("postProcess fires with reply and message for an applied edit") func postProcessFiresForAppliedEdit() async {
        let body = #"{"type":"anglesite:edit-applied","id":"e-1","file":"src/pages/about.astro","commit":"deadbeef"}"#
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: body)],
            isError: false
        )))
        let observed = ObservedPostProcess()
        let router = MCPApplyEditRouter(
            toolCaller: { try await recorder.call(name: $0, arguments: $1) },
            // The closure records directly (no inner Task); `next()` rendezvouses with the router's
            // detached post-process task, so the test needs no sleep.
            postProcess: { reply, message in await observed.record(reply: reply, message: message) }
        )
        _ = await router.apply(sampleMessage)
        let call = await observed.next()
        #expect(call.reply.status == .applied)
        #expect(call.message.id == "e-1")
    }

    @Test("postProcess does not fire for a failed edit") func postProcessSkipsFailedEdit() async {
        let recorder = ToolCallRecorder(result: .success(MCPClient.ToolCallResult(
            content: [.init(type: "text", text: "boom")],
            isError: true
        )))
        let observed = ObservedPostProcess()
        let router = MCPApplyEditRouter(
            toolCaller: { try await recorder.call(name: $0, arguments: $1) },
            postProcess: { reply, message in await observed.record(reply: reply, message: message) }
        )
        _ = await router.apply(sampleMessage)
        // `isError` ⇒ the router returns `.failed` before reaching postProcess, so no detached task is
        // ever scheduled — the count is settled the moment `apply` returns (no sleep, no race).
        #expect(await observed.count == 0)
    }
}

/// Rendezvous collector for the router's post-process hook: `record` hands the call to a waiting
/// `next()` (or buffers it), so tests await the hook deterministically instead of sleeping.
private actor ObservedPostProcess {
    struct Call: Sendable { let reply: EditReply; let message: EditMessage }
    private var calls: [Call] = []
    private var waiters: [CheckedContinuation<Call, Never>] = []

    func record(reply: EditReply, message: EditMessage) {
        let call = Call(reply: reply, message: message)
        if waiters.isEmpty {
            calls.append(call)
        } else {
            waiters.removeFirst().resume(returning: call)
        }
    }

    /// Awaits the next recorded call, suspending until `record` runs.
    func next() async -> Call {
        if !calls.isEmpty { return calls.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    var count: Int { calls.count }
}

/// Thread-safe collector for the `onEdit` callback fired from the router's async context.
private actor ObservedReplies {
    private(set) var replies: [EditReply] = []
    func record(_ reply: EditReply) { replies.append(reply) }
}

private actor ToolCallRecorder {
    struct Call: Sendable, Equatable { let name: String; let arguments: JSONValue }
    private(set) var calls: [Call] = []
    private let result: Result<MCPClient.ToolCallResult, Error>

    init(result: Result<MCPClient.ToolCallResult, Error>) { self.result = result }

    func call(name: String, arguments: JSONValue) async throws -> MCPClient.ToolCallResult {
        calls.append(Call(name: name, arguments: arguments))
        switch result {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
}

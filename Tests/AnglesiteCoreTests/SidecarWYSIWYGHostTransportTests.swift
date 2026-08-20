import Testing
import Foundation
@testable import AnglesiteCore

@Suite("SidecarWYSIWYGHostTransport")
struct SidecarWYSIWYGHostTransportTests {
    struct FakeEditRouter: EditRouter {
        let reply: EditReply
        func apply(_ message: EditMessage) async -> EditReply { reply }
    }

    /// Captures the last `EditMessage` it was asked to apply — lets a test inspect the actual
    /// wire payload `SidecarWYSIWYGHostTransport` built, not just the canned reply it gets back.
    final class CapturingEditRouter: EditRouter, @unchecked Sendable {
        let reply: EditReply
        private(set) var lastMessage: EditMessage?
        init(reply: EditReply) { self.reply = reply }
        func apply(_ message: EditMessage) async -> EditReply {
            lastMessage = message
            return reply
        }
    }

    /// Returns a canned reply for each successive `apply` call, in order, and records every
    /// message it was asked to apply — lets a test drive a multi-call sequence (insert, then N
    /// `setAttr` follow-ups) and inspect each wire payload in turn.
    final class SequencedEditRouter: EditRouter, @unchecked Sendable {
        private var replies: [EditReply]
        private(set) var messages: [EditMessage] = []
        init(replies: [EditReply]) { self.replies = replies }
        func apply(_ message: EditMessage) async -> EditReply {
            messages.append(message)
            guard !replies.isEmpty else {
                return EditReply(id: message.id, status: .failed, message: "SequencedEditRouter ran out of canned replies")
            }
            return replies.removeFirst()
        }
    }

    private func emptyPageModel(version: String) -> PageModel {
        PageModel(version: version, path: "src/pages/index.astro",
            tree: .init(id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 0), loc: nil, text: nil, children: [], block: nil))
    }

    private func attrValue(_ message: EditMessage, _ key: String) -> JSONValue? {
        guard case .object(let component)? = message.component else { return nil }
        return component[key]
    }

    @Test func appliedOpRefetchesAndAdaptsFreshModel() async {
        let pageModelClient = PageModelClient(toolCaller: { name, _ in
            #expect(name == "get_page_model")
            let data = try! JSONEncoder().encode(emptyPageModel(version: "sha256:fresh111111"))
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: String(data: data, encoding: .utf8))], isError: false)
        })
        let editRouter = FakeEditRouter(reply: EditReply(id: "req-1", status: .applied, message: nil))
        let transport = SidecarWYSIWYGHostTransport(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: editRouter, rootId: "n0")

        let op = Op.setDesignToken(tokenName: "--color-primary", value: "#111", previousValue: "#000")
        let result = await transport.sendOp(OpEnvelope(id: "req-1", targetVersion: "sha256:stale000000", op: op))

        guard case .applied(let model) = result else { Issue.record("expected .applied, got \(result)"); return }
        #expect(model.version == "sha256:fresh111111")
    }

    @Test func staleReasonMapsToVersionMismatch() async {
        let pageModelClient = PageModelClient(toolCaller: { _, _ in
            MCPClient.ToolCallResult(content: [], isError: false) // never reached — apply fails first
        })
        let editRouter = FakeEditRouter(reply: EditReply(id: "req-2", status: .failed, message: "stale", reason: "stale"))
        let transport = SidecarWYSIWYGHostTransport(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: editRouter, rootId: "n0")

        let op = Op.setDesignToken(tokenName: "--color-primary", value: "#111", previousValue: "#000")
        let result = await transport.sendOp(OpEnvelope(id: "req-2", targetVersion: "sha256:stale000000", op: op))

        guard case .rejected(let reason, _, _) = result else { Issue.record("expected .rejected, got \(result)"); return }
        #expect(reason == .versionMismatch)
    }

    @Test func otherFailureReasonMapsToHostError() async {
        let pageModelClient = PageModelClient(toolCaller: { _, _ in MCPClient.ToolCallResult(content: [], isError: false) })
        let editRouter = FakeEditRouter(reply: EditReply(id: "req-3", status: .failed, message: "not found", reason: "invalid-input"))
        let transport = SidecarWYSIWYGHostTransport(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: editRouter, rootId: "n0")

        let op = Op.setDesignToken(tokenName: "--color-primary", value: "#111", previousValue: "#000")
        let result = await transport.sendOp(OpEnvelope(id: "req-3", targetVersion: "sha256:stale000000", op: op))

        guard case .rejected(let reason, let message, _) = result else { Issue.record("expected .rejected, got \(result)"); return }
        #expect(reason == .hostError)
        #expect(message == "not found")
    }

    // Finding 1 (Critical), end-to-end: proves the real root id the transport was constructed
    // with actually reaches the wire message handed to the `EditRouter` — not just that the pure
    // translator function substitutes correctly in isolation.
    @Test func sendOpSubstitutesRealRootIdForSentinelOnTheWire() async {
        let pageModelClient = PageModelClient(toolCaller: { _, _ in
            let data = try! JSONEncoder().encode(emptyPageModel(version: "sha256:fresh111111"))
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: String(data: data, encoding: .utf8))], isError: false)
        })
        let editRouter = CapturingEditRouter(reply: EditReply(id: "req-4", status: .applied, message: nil))
        let transport = SidecarWYSIWYGHostTransport(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: editRouter, rootId: "n0")

        let content = BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: nil)
        let op = Op.insertBlock(parentId: rootParentID, slot: "default", index: 0, newId: "n9", block: content)
        _ = await transport.sendOp(OpEnvelope(id: "req-4", targetVersion: "sha256:stale000000", op: op))

        guard case .object(let component)? = editRouter.lastMessage?.component else {
            Issue.record("expected a captured component payload"); return
        }
        #expect(component["parentId"] == .string("n0"))
        #expect(component["parentId"] != .string(rootParentID))
    }

    // Confirmed bug (WYSIWYGOpTranslator.swift line 114 review comment): `ComponentStructureEditBuilder.NodeSpec`
    // carries no attributes field, so an insertBlock's `block.props` was silently dropped on the
    // wire. The sidecar's insert schema has no attributes field either (server/apply-edit-schema.mjs's
    // componentEditSchema) — the only fix is a `setAttr` follow-up per prop, addressed at the real
    // node id the insert reply's `inverse.component.nodeId` reveals.
    @Test func insertBlockWithPropsIssuesOneSetAttrFollowUpPerProp() async {
        let pageModelClient = PageModelClient(toolCaller: { _, _ in
            let data = try! JSONEncoder().encode(emptyPageModel(version: "sha256:fresh999999"))
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: String(data: data, encoding: .utf8))], isError: false)
        })
        let insertReply = EditReply(id: "req-5", status: .applied, message: nil, inverseNodeId: "n42", postWriteVersion: "sha256:postwrite1")
        let classReply = EditReply(id: "req-5-attr-0", status: .applied, message: nil, postWriteVersion: "sha256:postwrite2")
        let idReply = EditReply(id: "req-5-attr-1", status: .applied, message: nil, postWriteVersion: "sha256:postwrite3")
        let editRouter = SequencedEditRouter(replies: [insertReply, classReply, idReply])
        let transport = SidecarWYSIWYGHostTransport(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: editRouter, rootId: "n0")

        let content = BlockNodeContent(
            kind: .element, componentName: "section", props: ["class": .string("hero"), "id": .string("top")],
            slots: [:], sourceSpan: [0, 0], richText: nil)
        let op = Op.insertBlock(parentId: rootParentID, slot: "default", index: 0, newId: "n9", block: content)
        let result = await transport.sendOp(OpEnvelope(id: "req-5", targetVersion: "sha256:stale000000", op: op))

        guard case .applied = result else { Issue.record("expected .applied, got \(result)"); return }
        #expect(editRouter.messages.count == 3)
        #expect(editRouter.messages[0].op == EditMessage.Op.insertBlock)

        let followUps = Array(editRouter.messages.dropFirst())
        #expect(followUps.allSatisfy { $0.op == EditMessage.Op.setAttr })
        // Every follow-up targets the REAL node id from the insert reply's inverse, not the
        // app-side `newId` sentinel from the op.
        #expect(followUps.allSatisfy { attrValue($0, "nodeId") == .string("n42") })

        let names = Set(followUps.compactMap { message -> String? in
            if case .string(let name)? = attrValue(message, "name") { return name }
            return nil
        })
        #expect(names == ["class", "id"])

        // baseVersion chains forward through each successive reply's own postWriteVersion rather
        // than reusing the insert's version for every follow-up.
        let versions = followUps.compactMap { message -> String? in
            if case .string(let v)? = attrValue(message, "baseVersion") { return v }
            return nil
        }
        #expect(versions.first == "sha256:postwrite1")
        #expect(versions.last == "sha256:postwrite2")
    }

    @Test func insertBlockAppliedButMissingInverseNodeIdRejectsWithoutFollowUp() async {
        let pageModelClient = PageModelClient(toolCaller: { _, _ in
            Issue.record("should not re-fetch when attribute follow-up cannot proceed")
            return MCPClient.ToolCallResult(content: [], isError: false)
        })
        // Applied, but no inverseNodeId/postWriteVersion — the sidecar didn't give us enough to
        // address the new node.
        let insertReply = EditReply(id: "req-6", status: .applied, message: nil)
        let editRouter = SequencedEditRouter(replies: [insertReply])
        let transport = SidecarWYSIWYGHostTransport(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: editRouter, rootId: "n0")

        let content = BlockNodeContent(kind: .element, componentName: "section", props: ["class": .string("hero")], slots: [:], sourceSpan: [0, 0], richText: nil)
        let op = Op.insertBlock(parentId: rootParentID, slot: "default", index: 0, newId: "n9", block: content)
        let result = await transport.sendOp(OpEnvelope(id: "req-6", targetVersion: "sha256:stale000000", op: op))

        guard case .rejected(let reason, let message, let freshModel) = result else { Issue.record("expected .rejected, got \(result)"); return }
        #expect(reason == .hostError)
        #expect(message?.isEmpty == false)
        #expect(freshModel == nil)
        // Only the insert call happened — no follow-up was attempted with a missing node id.
        #expect(editRouter.messages.count == 1)
    }

    @Test func insertBlockFollowUpSetAttrFailureRejectsAndStopsImmediately() async {
        let pageModelClient = PageModelClient(toolCaller: { _, _ in
            Issue.record("should not re-fetch when a follow-up setAttr fails")
            return MCPClient.ToolCallResult(content: [], isError: false)
        })
        let insertReply = EditReply(id: "req-7", status: .applied, message: nil, inverseNodeId: "n42", postWriteVersion: "sha256:postwrite1")
        let failedSetAttr = EditReply(id: "req-7-attr-0", status: .failed, message: "stale")
        // A second canned reply that must NEVER be consumed if the transport really stops
        // immediately after the first follow-up fails.
        let neverReached = EditReply(id: "req-7-attr-1", status: .applied, message: nil, postWriteVersion: "sha256:unreached")
        let editRouter = SequencedEditRouter(replies: [insertReply, failedSetAttr, neverReached])
        let transport = SidecarWYSIWYGHostTransport(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: editRouter, rootId: "n0")

        let content = BlockNodeContent(
            kind: .element, componentName: "section", props: ["only-prop": .string("value")],
            slots: [:], sourceSpan: [0, 0], richText: nil)
        let op = Op.insertBlock(parentId: rootParentID, slot: "default", index: 0, newId: "n9", block: content)
        let result = await transport.sendOp(OpEnvelope(id: "req-7", targetVersion: "sha256:stale000000", op: op))

        guard case .rejected(let reason, let message, let freshModel) = result else { Issue.record("expected .rejected, got \(result)"); return }
        #expect(reason == .hostError)
        #expect(message?.contains("only-prop") == true)
        #expect(freshModel == nil)
        // Insert + the one failed follow-up — the second prop's setAttr must never be sent.
        #expect(editRouter.messages.count == 2)
    }

    // Regression guard: an insertBlock with EMPTY props must behave exactly as before this fix —
    // a single insert call, no setAttr follow-ups, straight through to the re-fetch.
    @Test func insertBlockWithEmptyPropsIssuesNoFollowUp() async {
        let pageModelClient = PageModelClient(toolCaller: { _, _ in
            let data = try! JSONEncoder().encode(emptyPageModel(version: "sha256:fresh222222"))
            return MCPClient.ToolCallResult(content: [.init(type: "text", text: String(data: data, encoding: .utf8))], isError: false)
        })
        let insertReply = EditReply(id: "req-8", status: .applied, message: nil)
        let editRouter = SequencedEditRouter(replies: [insertReply])
        let transport = SidecarWYSIWYGHostTransport(path: "src/pages/index.astro", pageModelClient: pageModelClient, editRouter: editRouter, rootId: "n0")

        let content = BlockNodeContent(kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0], richText: nil)
        let op = Op.insertBlock(parentId: rootParentID, slot: "default", index: 0, newId: "n9", block: content)
        let result = await transport.sendOp(OpEnvelope(id: "req-8", targetVersion: "sha256:stale000000", op: op))

        guard case .applied(let model) = result else { Issue.record("expected .applied, got \(result)"); return }
        #expect(model.version == "sha256:fresh222222")
        #expect(editRouter.messages.count == 1)
        #expect(editRouter.messages[0].op == EditMessage.Op.insertBlock)
    }
}

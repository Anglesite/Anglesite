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

    private func emptyPageModel(version: String) -> PageModel {
        PageModel(version: version, path: "src/pages/index.astro",
            tree: .init(id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: 0, end: 0), loc: nil, text: nil, children: [], block: nil))
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
}

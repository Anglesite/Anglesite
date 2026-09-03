import Foundation
import Testing
@testable import AnglesiteBridgeCore
@testable import AnglesiteCore

@Suite("WYSIWYGOpsDispatcher")
struct WYSIWYGOpsDispatcherTests {
    actor RecordingTransport: WYSIWYGHostTransport {
        private(set) var received: [OpEnvelope] = []
        private let reply: OpResult
        init(reply: OpResult) { self.reply = reply }
        func sendOp(_ envelope: OpEnvelope) async -> OpResult {
            received.append(envelope)
            return reply
        }
        func onModelUpdate(_ listener: @escaping @Sendable (BlockModel) -> Void) async -> () -> Void { {} }
        // note: brief's sample was `func onModelUpdate(...) -> () -> Void` (non-async); the real
        // protocol (Sources/AnglesiteCore/WYSIWYG/WYSIWYGHostTransport.swift) declares this async,
        // so this conformance is `async` to match.
    }

    static func validSubmitOpBody() -> [String: Any] {
        [
            "type": "submit-op",
            "envelope": [
                "id": "req-1",
                "targetVersion": "v0",
                "op": ["kind": "setDesignToken", "tokenName": "color.primary", "value": "#000", "previousValue": "#fff"],
            ],
        ]
    }

    @Test("dispatch routes submit-op to the transport and returns the result")
    func routesSubmitOp() async {
        let model = BlockModel(path: "src/pages/index.astro", version: "v1", rootIds: [], blocks: [:])
        let transport = RecordingTransport(reply: .applied(model: model))
        let result = await WYSIWYGOpsDispatcher.dispatch(body: Self.validSubmitOpBody(), via: transport)
        guard case .opResult(let requestId, let opResult) = result else {
            Issue.record("expected .opResult, got \(result)")
            return
        }
        #expect(requestId == "req-1")
        #expect(opResult == .applied(model: model))
        let received = await transport.received
        #expect(received.first?.id == "req-1")
    }

    @Test("dispatch rejects an unrecognized type")
    func rejectsUnknownType() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let result = await WYSIWYGOpsDispatcher.dispatch(body: ["type": "nope"], via: transport)
        guard case .rejected(.unknownType(let type)) = result else {
            Issue.record("expected .rejected(.unknownType), got \(result)")
            return
        }
        #expect(type == "nope")
    }

    @Test("dispatch routes context-menu to .contextMenu with the reported block and point")
    func routesContextMenu() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let body: [String: Any] = ["type": "context-menu", "blockId": "b1", "x": 12.5, "y": 34.0]
        let result = await WYSIWYGOpsDispatcher.dispatch(body: body, via: transport)
        guard case .contextMenu(let blockId, let point) = result else {
            Issue.record("expected .contextMenu, got \(result)")
            return
        }
        #expect(blockId == "b1")
        #expect(point.x == 12.5)
        #expect(point.y == 34.0)
    }

    @Test("dispatch rejects a context-menu body missing required fields")
    func rejectsIncompleteContextMenu() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let result = await WYSIWYGOpsDispatcher.dispatch(body: ["type": "context-menu", "blockId": "b1"], via: transport)
        guard case .rejected(.envelopeDecode) = result else {
            Issue.record("expected .rejected(.envelopeDecode), got \(result)")
            return
        }
    }

    @Test("dispatch decodes a selection-changed message with a block id")
    func decodesSelectionChangedWithBlock() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let result = await WYSIWYGOpsDispatcher.dispatch(body: ["type": "selection-changed", "blockId": "b1"], via: transport)
        guard case .selectionChanged(let blockId) = result else {
            Issue.record("expected .selectionChanged, got \(result)")
            return
        }
        #expect(blockId == "b1")
    }

    @Test("dispatch decodes a selection-changed message clearing the selection")
    func decodesSelectionChangedCleared() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let result = await WYSIWYGOpsDispatcher.dispatch(body: ["type": "selection-changed", "blockId": NSNull()], via: transport)
        guard case .selectionChanged(let blockId) = result else {
            Issue.record("expected .selectionChanged, got \(result)")
            return
        }
        #expect(blockId == nil)
    }

    @Test("dispatch decodes a focus-inspector message requesting forward direction (#1616)")
    func decodesFocusInspectorForward() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let result = await WYSIWYGOpsDispatcher.dispatch(body: ["type": "focus-inspector", "direction": "forward", "blockId": "b1"], via: transport)
        guard case .focusInspector(let direction, let blockId) = result else {
            Issue.record("expected .focusInspector, got \(result)")
            return
        }
        #expect(direction == .forward)
        #expect(blockId == "b1")
    }

    @Test("dispatch decodes a focus-inspector message requesting backward direction (#1616)")
    func decodesFocusInspectorBackward() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let result = await WYSIWYGOpsDispatcher.dispatch(body: ["type": "focus-inspector", "direction": "backward", "blockId": "b1"], via: transport)
        guard case .focusInspector(let direction, let blockId) = result else {
            Issue.record("expected .focusInspector, got \(result)")
            return
        }
        #expect(direction == .backward)
        #expect(blockId == "b1")
    }

    @Test("dispatch rejects a focus-inspector message with an unrecognized direction (#1616)")
    func rejectsInvalidFocusInspectorDirection() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let result = await WYSIWYGOpsDispatcher.dispatch(body: ["type": "focus-inspector", "direction": "sideways", "blockId": "b1"], via: transport)
        guard case .rejected(.envelopeDecode) = result else {
            Issue.record("expected .rejected(.envelopeDecode), got \(result)")
            return
        }
    }

    @Test("dispatch rejects a focus-inspector message missing blockId (#1616)")
    func rejectsFocusInspectorMissingBlockId() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let result = await WYSIWYGOpsDispatcher.dispatch(body: ["type": "focus-inspector", "direction": "forward"], via: transport)
        guard case .rejected(.envelopeDecode) = result else {
            Issue.record("expected .rejected(.envelopeDecode), got \(result)")
            return
        }
    }

    @Test("dispatch routes writing-help-request to the assistant and returns the reply")
    func routesWritingHelpRequest() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let body: [String: Any] = ["type": "writing-help-request", "requestId": "wh-1", "text": "Original text.", "instruction": "Tighten this."]
        let result = await WYSIWYGOpsDispatcher.dispatch(
            body: body, via: transport,
            writingHelp: { text, instruction in
                #expect(text == "Original text.")
                #expect(instruction == "Tighten this.")
                return .rewritten("Shorter version.")
            })
        guard case .writingHelpReply(let requestId, let outcome) = result else {
            Issue.record("expected .writingHelpReply, got \(result)")
            return
        }
        #expect(requestId == "wh-1")
        #expect(outcome == .rewritten("Shorter version."))
    }

    @Test("dispatch replies .unavailable for writing-help-request when no assistant is wired")
    func writingHelpRequestWithoutAssistant() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let body: [String: Any] = ["type": "writing-help-request", "requestId": "wh-2", "text": "x", "instruction": "y"]
        let result = await WYSIWYGOpsDispatcher.dispatch(body: body, via: transport, writingHelp: nil)
        guard case .writingHelpReply(let requestId, let outcome) = result else {
            Issue.record("expected .writingHelpReply, got \(result)")
            return
        }
        #expect(requestId == "wh-2")
        guard case .unavailable = outcome else {
            Issue.record("expected .unavailable, got \(outcome)")
            return
        }
    }

    @Test("dispatch rejects a writing-help-request missing required fields")
    func rejectsMalformedWritingHelpRequest() async {
        let transport = RecordingTransport(reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))
        let result = await WYSIWYGOpsDispatcher.dispatch(body: ["type": "writing-help-request"], via: transport)
        guard case .rejected(.envelopeDecode) = result else {
            Issue.record("expected .rejected(.envelopeDecode), got \(result)")
            return
        }
    }
}

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
}

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
            handlers: .init(writingHelp: { text, instruction in
                #expect(text == "Original text.")
                #expect(instruction == "Tighten this.")
                return .rewritten("Shorter version.")
            }))
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
        let result = await WYSIWYGOpsDispatcher.dispatch(body: body, via: transport, handlers: .init(writingHelp: nil))
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

/// `replace-image` (#1957): a file dropped onto an existing `<img>` on the live page, the block
/// editor's replacement for the retired overlay's `anglesite:apply-edit` / `replace-image-src`
/// round trip. The dispatcher re-shapes the request into that same `EditMessage` so the sidecar
/// path (optimize, strip metadata, one commit) is unchanged.
@Suite("WYSIWYGOpsDispatcher replace-image (#1957)")
struct WYSIWYGOpsDispatcherImageReplaceTests {
    private static let transport = WYSIWYGOpsDispatcherTests.RecordingTransport(
        reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))

    private static func validBody(requestId: String = "img-1") -> [String: Any] {
        [
            "type": "replace-image",
            "requestId": requestId,
            "request": [
                "path": "/about/",
                "selector": ["tag": "IMG", "classes": ["hero"], "nthChild": 2, "id": "hero"],
                "filename": "vacation.jpg",
                "mimeType": "image/jpeg",
                "dataURL": "data:image/jpeg;base64,AAAA",
            ],
        ]
    }

    @Test("routes replace-image to the replacer as a replace-image-src EditMessage and returns its reply")
    func routesToReplacer() async {
        let result = await WYSIWYGOpsDispatcher.dispatch(
            body: Self.validBody(), via: Self.transport,
            handlers: .init(imageReplace: { message in
                #expect(message.id == "img-1")
                #expect(message.path == "/about/")
                #expect(message.op == EditMessage.Op.replaceImageSrc)
                #expect(message.selector == .object(["tag": .string("IMG"), "classes": .array([.string("hero")]), "nthChild": .int(2), "id": .string("hero")]))
                #expect(message.value == .object([
                    "filename": .string("vacation.jpg"), "mimeType": .string("image/jpeg"), "dataURL": .string("data:image/jpeg;base64,AAAA"),
                ]))
                return EditReply(
                    id: message.id, status: .applied, message: nil, file: "src/pages/about.astro", commit: "abc",
                    result: .init(src: "/images/vacation.webp", srcset: nil))
            }))
        guard case .imageReplaceReply(let requestId, let reply) = result else {
            Issue.record("expected .imageReplaceReply, got \(result)")
            return
        }
        #expect(requestId == "img-1")
        #expect(reply.status == .applied)
        #expect(reply.result?.src == "/images/vacation.webp")
    }

    @Test("replies .failed, keyed by the request id, when no replacer is wired")
    func failsWithoutReplacer() async {
        let result = await WYSIWYGOpsDispatcher.dispatch(body: Self.validBody(requestId: "img-2"), via: Self.transport)
        guard case .imageReplaceReply(let requestId, let reply) = result else {
            Issue.record("expected .imageReplaceReply, got \(result)")
            return
        }
        #expect(requestId == "img-2")
        #expect(reply.id == "img-2")
        #expect(reply.status == .failed)
        #expect(reply.message?.isEmpty == false)
    }

    @Test("rejects a replace-image body missing request fields", arguments: ["path", "selector", "filename", "mimeType", "dataURL"])
    func rejectsMissingField(field: String) async {
        var body = Self.validBody()
        var request = body["request"] as! [String: Any]
        request.removeValue(forKey: field)
        body["request"] = request
        let result = await WYSIWYGOpsDispatcher.dispatch(body: body, via: Self.transport, handlers: .init(imageReplace: { _ in
            Issue.record("replacer must not run for a malformed request")
            return EditReply(id: "x", status: .failed, message: "unreachable")
        }))
        guard case .rejected(.envelopeDecode) = result else {
            Issue.record("expected .rejected(.envelopeDecode), got \(result)")
            return
        }
    }

    @Test("rejects a replace-image body with no requestId")
    func rejectsMissingRequestId() async {
        var body = Self.validBody()
        body.removeValue(forKey: "requestId")
        let result = await WYSIWYGOpsDispatcher.dispatch(body: body, via: Self.transport)
        guard case .rejected(.envelopeDecode) = result else {
            Issue.record("expected .rejected(.envelopeDecode), got \(result)")
            return
        }
    }
}


/// The page-bridge messages (#1957): what used to ride the overlay's `anglesite` namespace
/// through `AnglesiteMessageDispatcher` — Siri's visible-elements reports, the Component Editor
/// canvas's selection/computed-styles, and the Effects/experiment pick modes — now arrive on the
/// single `wysiwyg` namespace. Ported from `AnglesiteMessageDispatcherTests`, which went with it.
@Suite("WYSIWYGOpsDispatcher page-bridge messages (#1957)")
struct WYSIWYGOpsDispatcherPageBridgeTests {
    private static let transport = WYSIWYGOpsDispatcherTests.RecordingTransport(
        reply: .applied(model: BlockModel(path: "p", version: "v", rootIds: [], blocks: [:])))

    private static func validVisibleElementsBody() -> [String: Any] {
        [
            "type": "anglesite:visible-elements",
            "elements": [
                [
                    "id": "v-1",
                    "tag": "H1",
                    "selector": ["tag": "H1", "classes": [] as [String], "nthChild": 1] as [String: Any],
                    "rect": ["x": 0, "y": 0, "width": 100, "height": 40] as [String: Any],
                    "text": "Heading",
                ] as [String: Any]
            ] as [Any],
        ]
    }

    @Test("submit-op with no transport is rejected as noTransport, not silently applied")
    func submitOpWithoutTransport() async {
        let result = await WYSIWYGOpsDispatcher.dispatch(body: WYSIWYGOpsDispatcherTests.validSubmitOpBody(), via: nil)
        guard case .rejected(.noTransport) = result else {
            Issue.record("expected .rejected(.noTransport), got \(result)")
            return
        }
    }

    @Test("rejects a body that is not an object") func rejectsNonObject() async {
        let result = await WYSIWYGOpsDispatcher.dispatch(body: "string", via: nil)
        guard case .rejected(.notAnObject) = result else {
            Issue.record("expected .rejected(.notAnObject), got \(result)")
            return
        }
    }

    @Test("reports a missing type as missingType") func reportsMissingType() async {
        let result = await WYSIWYGOpsDispatcher.dispatch(body: ["elements": [] as [Any]], via: nil)
        guard case .rejected(.missingType) = result else {
            Issue.record("expected .rejected(.missingType), got \(result)")
            return
        }
    }

    @Test("forwards visible-elements to its handler") func forwardsVisibleElements() async {
        let collector = ElementCollector()
        let result = await WYSIWYGOpsDispatcher.dispatch(
            body: Self.validVisibleElementsBody(), via: nil,
            handlers: .init(onVisibleElements: { elements in await collector.append(elements) }))
        guard case .visibleElementsHandled = result else {
            Issue.record("expected .visibleElementsHandled, got \(result)")
            return
        }
        let captured = await collector.batches
        #expect(captured.count == 1)
        #expect(captured.first?.first?.id == "v-1")
    }

    @Test("drops visible-elements when no handler is installed") func dropsVisibleElementsWithoutHandler() async {
        let result = await WYSIWYGOpsDispatcher.dispatch(body: Self.validVisibleElementsBody(), via: Self.transport)
        guard case .visibleElementsDropped = result else {
            Issue.record("expected .visibleElementsDropped, got \(result)")
            return
        }
        let received = await Self.transport.received
        #expect(received.isEmpty, "the transport must not see a page-bridge message")
    }

    @Test("surfaces visible-elements decode failures") func surfacesVisibleElementsDecodeFailure() async {
        var body = Self.validVisibleElementsBody()
        body.removeValue(forKey: "elements")
        let collector = ElementCollector()
        let result = await WYSIWYGOpsDispatcher.dispatch(
            body: body, via: nil, handlers: .init(onVisibleElements: { elements in await collector.append(elements) }))
        guard case .rejected(.visibleElementsDecode(.missingField("elements"))) = result else {
            Issue.record("expected .rejected(.visibleElementsDecode(.missingField(elements))), got \(result)")
            return
        }
        #expect(await collector.batches.isEmpty)
    }

    @Test("routes canvas-selection to its handler") func routesCanvasSelection() async {
        let received = LockIsolated<CanvasSelectionMessage?>(nil)
        let result = await WYSIWYGOpsDispatcher.dispatch(
            body: ["type": "anglesite:canvas-selection", "file": "/f.astro", "line": 7, "column": 1], via: nil,
            handlers: .init(onCanvasSelection: { msg in received.setValue(msg) }))
        guard case .canvasSelectionHandled = result else {
            Issue.record("expected .canvasSelectionHandled, got \(result)")
            return
        }
        #expect(received.value?.line == 7)
    }

    @Test("routes computed-styles to its handler") func routesComputedStyles() async {
        let received = LockIsolated<ComputedStylesReport?>(nil)
        let result = await WYSIWYGOpsDispatcher.dispatch(
            body: ["type": "anglesite:computed-styles", "styles": ["display": "block"]], via: nil,
            handlers: .init(onComputedStyles: { report in received.setValue(report) }))
        guard case .computedStylesHandled = result else {
            Issue.record("expected .computedStylesHandled, got \(result)")
            return
        }
        #expect(received.value?.styles["display"] == "block")
    }

    @Test("canvas messages without a handler are dropped, not rejected") func dropsUnhandledCanvas() async {
        let result = await WYSIWYGOpsDispatcher.dispatch(
            body: ["type": "anglesite:computed-styles", "styles": ["display": "block"]], via: nil)
        guard case .computedStylesDropped = result else {
            Issue.record("expected .computedStylesDropped, got \(result)")
            return
        }
    }

    @Test("routes pick-placement to its handler") func routesPlacementPick() async {
        let received = LockIsolated<PlacementPickMessage?>(nil)
        let body: [String: Any] = [
            "type": "anglesite:pick-placement", "path": "/about/",
            "selector": ["tag": "SECTION", "nthChild": 1, "ancestors": [] as [[String: Any]]],
        ]
        let result = await WYSIWYGOpsDispatcher.dispatch(
            body: body, via: nil, handlers: .init(onPlacementPick: { msg in received.setValue(msg) }))
        guard case .placementPickHandled = result else {
            Issue.record("expected .placementPickHandled, got \(result)")
            return
        }
        #expect(received.value?.path == "/about/")
    }

    @Test("pick-placement without a handler is dropped, not rejected") func placementPickDropped() async {
        let body: [String: Any] = [
            "type": "anglesite:pick-placement", "path": "/",
            "selector": ["tag": "DIV", "nthChild": 1, "ancestors": [] as [[String: Any]]],
        ]
        let result = await WYSIWYGOpsDispatcher.dispatch(body: body, via: nil)
        guard case .placementPickDropped = result else {
            Issue.record("expected .placementPickDropped, got \(result)")
            return
        }
    }

    @Test("routes pick-goal-element to its handler") func routesGoalElementPick() async {
        let received = LockIsolated<GoalElementPickMessage?>(nil)
        let body: [String: Any] = [
            "type": "anglesite:pick-goal-element", "path": "/about/",
            "selector": ["tag": "SECTION", "nthChild": 1, "ancestors": [] as [[String: Any]]],
        ]
        let result = await WYSIWYGOpsDispatcher.dispatch(
            body: body, via: nil, handlers: .init(onGoalElementPick: { msg in received.setValue(msg) }))
        guard case .goalElementPickHandled = result else {
            Issue.record("expected .goalElementPickHandled, got \(result)")
            return
        }
        #expect(received.value?.path == "/about/")
    }

    @Test("pick-goal-element without a handler is dropped, not rejected") func goalElementPickDropped() async {
        let body: [String: Any] = [
            "type": "anglesite:pick-goal-element", "path": "/",
            "selector": ["tag": "DIV", "nthChild": 1, "ancestors": [] as [[String: Any]]],
        ]
        let result = await WYSIWYGOpsDispatcher.dispatch(body: body, via: nil)
        guard case .goalElementPickDropped = result else {
            Issue.record("expected .goalElementPickDropped, got \(result)")
            return
        }
    }

    @Test("a malformed pick body is rejected with its decoder's error") func rejectsMalformedPick() async {
        let result = await WYSIWYGOpsDispatcher.dispatch(
            body: ["type": "anglesite:pick-goal-element", "path": "/"], via: nil,
            handlers: .init(onGoalElementPick: { _ in Issue.record("handler must not run for a malformed pick") }))
        guard case .rejected(.goalElementPickDecode(.malformed)) = result else {
            Issue.record("expected .rejected(.goalElementPickDecode(.malformed)), got \(result)")
            return
        }
    }
}

private actor ElementCollector {
    private(set) var batches: [[VisibleElement]] = []
    func append(_ batch: [VisibleElement]) { batches.append(batch) }
}

private final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { self._value = value }
    var value: Value {
        lock.withLock { _value }
    }
    func setValue(_ new: Value) {
        lock.withLock { _value = new }
    }
}

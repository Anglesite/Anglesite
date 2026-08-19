import Foundation
import Testing
@testable import AnglesiteBridgeCore
import AnglesiteCore

struct AnglesiteMessageDispatcherTests {
    private func validEditBody() -> [String: Any] {
        [
            "id": "e-99",
            "type": "anglesite:apply-edit",
            "path": "/contact/",
            "selector": [
                "tag": "H1",
                "classes": [] as [String],
                "nthChild": 1,
            ] as [String: Any],
            "op": "replace-text",
            "value": "New heading",
        ]
    }

    private func validVisibleElementsBody() -> [String: Any] {
        [
            "type": "anglesite:visible-elements",
            "elements": [
                [
                    "id": "v-1",
                    "tag": "H1",
                    "selector": [
                        "tag": "H1",
                        "classes": [] as [String],
                        "nthChild": 1,
                    ] as [String: Any],
                    "rect": ["x": 0, "y": 0, "width": 100, "height": 40] as [String: Any],
                    "text": "Heading",
                ] as [String: Any]
            ] as [Any],
        ]
    }

    @Test("Dispatch routes apply-edit and returns reply") func dispatchRoutesApplyEdit() async {
        let router = RecordingRouter(reply: EditReply(id: "e-99", status: .applied, message: "done"))
        let result = await AnglesiteMessageDispatcher.dispatch(body: validEditBody(), via: router)
        guard case .editReply(let reply) = result else {
            Issue.record("expected .editReply, got \(result)")
            return
        }
        #expect(reply.id == "e-99")
        #expect(reply.status == .applied)
        let received = await router.received
        #expect(received.count == 1)
        #expect(received.first?.id == "e-99")
        #expect(received.first?.op == "replace-text")
    }

    @Test("Dispatch rejects unknown message type") func dispatchRejectsUnknownType() async {
        var bad = validEditBody()
        bad["type"] = "anglesite:not-real"
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let result = await AnglesiteMessageDispatcher.dispatch(body: bad, via: router)
        guard case .rejected(.unknownType(let t)) = result else {
            Issue.record("expected .rejected(.unknownType), got \(result)")
            return
        }
        #expect(t == "anglesite:not-real")
        let received = await router.received
        #expect(received.isEmpty, "router must not see undecodable input")
    }

    @Test("Dispatch rejects body that is not an object") func dispatchRejectsNonObject() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let result = await AnglesiteMessageDispatcher.dispatch(body: "string", via: router)
        guard case .rejected(.notAnObject) = result else {
            Issue.record("expected .rejected(.notAnObject), got \(result)")
            return
        }
    }

    @Test("Dispatch reports missing type as missingType") func dispatchReportsMissingType() async {
        var body = validEditBody()
        body.removeValue(forKey: "type")
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let result = await AnglesiteMessageDispatcher.dispatch(body: body, via: router)
        guard case .rejected(.missingType) = result else {
            Issue.record("expected .rejected(.missingType), got \(result)")
            return
        }
    }

    @Test("Dispatch forwards visible-elements to handler") func dispatchForwardsVisibleElements() async {
        let collector = ElementCollector()
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let result = await AnglesiteMessageDispatcher.dispatch(
            body: validVisibleElementsBody(),
            via: router,
            onVisibleElements: { elements in await collector.append(elements) }
        )
        guard case .visibleElementsHandled = result else {
            Issue.record("expected .visibleElementsHandled, got \(result)")
            return
        }
        let captured = await collector.batches
        #expect(captured.count == 1)
        #expect(captured.first?.count == 1)
        #expect(captured.first?.first?.id == "v-1")
        let received = await router.received
        #expect(received.isEmpty, "router must not see a visible-elements message")
    }

    @Test("Dispatch drops visible-elements when no handler is installed") func dispatchDropsVisibleElementsWithoutHandler() async {
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let result = await AnglesiteMessageDispatcher.dispatch(
            body: validVisibleElementsBody(),
            via: router,
            onVisibleElements: nil
        )
        guard case .visibleElementsDropped = result else {
            Issue.record("expected .visibleElementsDropped, got \(result)")
            return
        }
    }

    @Test("Dispatch surfaces visible-elements decode failures") func dispatchSurfacesVisibleElementsDecodeFailure() async {
        var body = validVisibleElementsBody()
        body.removeValue(forKey: "elements")
        let collector = ElementCollector()
        let router = RecordingRouter(reply: EditReply(id: "x", status: .applied, message: nil))
        let result = await AnglesiteMessageDispatcher.dispatch(
            body: body,
            via: router,
            onVisibleElements: { elements in await collector.append(elements) }
        )
        guard case .rejected(.visibleElementsDecode(.missingField("elements"))) = result else {
            Issue.record("expected .rejected(.visibleElementsDecode(.missingField(elements))), got \(result)")
            return
        }
        let captured = await collector.batches
        #expect(captured.isEmpty)
    }

    @Test("Dispatch routes canvas-selection to its handler") func dispatchRoutesCanvasSelection() async {
        let router = RecordingRouter(reply: EditReply(id: "-", status: .failed, message: "unused"))
        let received = LockIsolated<CanvasSelectionMessage?>(nil)
        let result = await AnglesiteMessageDispatcher.dispatch(
            body: ["type": "anglesite:canvas-selection", "file": "/f.astro", "line": 7, "column": 1],
            via: router,
            onCanvasSelection: { msg in received.setValue(msg) }
        )
        guard case .canvasSelectionHandled = result else {
            Issue.record("expected .canvasSelectionHandled, got \(result)")
            return
        }
        #expect(received.value?.line == 7)
    }

    @Test("Canvas messages without a handler are dropped, not rejected") func dispatchDropsUnhandledCanvas() async {
        let router = RecordingRouter(reply: EditReply(id: "-", status: .failed, message: "unused"))
        let result = await AnglesiteMessageDispatcher.dispatch(
            body: ["type": "anglesite:computed-styles", "styles": ["display": "block"]],
            via: router
        )
        guard case .computedStylesDropped = result else {
            Issue.record("expected .computedStylesDropped, got \(result)")
            return
        }
    }

    @Test("Dispatch routes pick-placement to its handler") func routesPlacementPickToHandler() async {
        let router = RecordingRouter(reply: EditReply(id: "-", status: .failed, message: "unused"))
        let received = LockIsolated<PlacementPickMessage?>(nil)
        let body: [String: Any] = [
            "type": "anglesite:pick-placement", "path": "/about/",
            "selector": ["tag": "SECTION", "nthChild": 1, "ancestors": [] as [[String: Any]]],
        ]
        let result = await AnglesiteMessageDispatcher.dispatch(
            body: body, via: router,
            onPlacementPick: { msg in received.setValue(msg) })
        guard case .placementPickHandled = result else {
            Issue.record("expected .placementPickHandled, got \(result)")
            return
        }
        #expect(received.value?.path == "/about/")
    }

    @Test("Pick-placement messages without a handler are dropped, not rejected") func placementPickDroppedWithoutHandler() async {
        let router = RecordingRouter(reply: EditReply(id: "-", status: .failed, message: "unused"))
        let body: [String: Any] = [
            "type": "anglesite:pick-placement", "path": "/",
            "selector": ["tag": "DIV", "nthChild": 1, "ancestors": [] as [[String: Any]]],
        ]
        let result = await AnglesiteMessageDispatcher.dispatch(body: body, via: router)
        guard case .placementPickDropped = result else {
            Issue.record("expected .placementPickDropped, got \(result)")
            return
        }
    }

    @Test("Dispatch routes pick-goal-element to its handler") func routesGoalElementPickToHandler() async {
        let router = RecordingRouter(reply: EditReply(id: "-", status: .failed, message: "unused"))
        let received = LockIsolated<GoalElementPickMessage?>(nil)
        let body: [String: Any] = [
            "type": "anglesite:pick-goal-element", "path": "/about/",
            "selector": ["tag": "SECTION", "nthChild": 1, "ancestors": [] as [[String: Any]]],
        ]
        let result = await AnglesiteMessageDispatcher.dispatch(
            body: body, via: router,
            onGoalElementPick: { msg in received.setValue(msg) })
        guard case .goalElementPickHandled = result else {
            Issue.record("expected .goalElementPickHandled, got \(result)")
            return
        }
        #expect(received.value?.path == "/about/")
    }

    @Test("Pick-goal-element messages without a handler are dropped, not rejected") func goalElementPickDroppedWithoutHandler() async {
        let router = RecordingRouter(reply: EditReply(id: "-", status: .failed, message: "unused"))
        let body: [String: Any] = [
            "type": "anglesite:pick-goal-element", "path": "/",
            "selector": ["tag": "DIV", "nthChild": 1, "ancestors": [] as [[String: Any]]],
        ]
        let result = await AnglesiteMessageDispatcher.dispatch(body: body, via: router)
        guard case .goalElementPickDropped = result else {
            Issue.record("expected .goalElementPickDropped, got \(result)")
            return
        }
    }
}

private actor RecordingRouter: EditRouter {
    private(set) var received: [EditMessage] = []
    private let reply: EditReply
    init(reply: EditReply) { self.reply = reply }
    func apply(_ message: EditMessage) async -> EditReply {
        received.append(message)
        return reply
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

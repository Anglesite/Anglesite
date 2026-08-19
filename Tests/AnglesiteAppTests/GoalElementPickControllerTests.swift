// Tests/AnglesiteAppTests/GoalElementPickControllerTests.swift
import Testing
import Foundation
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@MainActor
@Suite struct GoalElementPickControllerTests {
    private func elementInfo(id: String?) -> ElementInfo {
        ElementInfo(tag: "SECTION", id: id, classes: [], nthChild: 1, ancestors: [],
                    dataAnglesiteId: nil, dataTestId: nil, role: nil, ariaLabel: nil, textContent: nil)
    }

    @Test func startPickingEntersOverlayModeAndSetsPicking() {
        let controller = GoalElementPickController()
        var entered = false
        controller.startPicking(enterOverlayMode: { entered = true }, exitOverlayMode: {})
        #expect(entered)
        #expect(controller.state == .picking)
    }

    @Test func startPickingIsANoOpWhenAlreadyPicking() {
        let controller = GoalElementPickController()
        var enterCount = 0
        controller.startPicking(enterOverlayMode: { enterCount += 1 }, exitOverlayMode: {})
        controller.startPicking(enterOverlayMode: { enterCount += 1 }, exitOverlayMode: {})
        #expect(enterCount == 1)
    }

    @Test func cancelExitsOverlayModeAndReturnsToIdle() {
        let controller = GoalElementPickController()
        var exited = false
        controller.startPicking(enterOverlayMode: {}, exitOverlayMode: { exited = true })
        controller.cancel()
        #expect(exited)
        #expect(controller.state == .idle)
    }

    @Test func handlePickBuildsASelectorAndExitsOverlayMode() {
        let controller = GoalElementPickController()
        var exited = false
        controller.startPicking(enterOverlayMode: {}, exitOverlayMode: { exited = true })
        controller.handlePick(GoalElementPickMessage(path: "/", element: elementInfo(id: "reviews")))
        #expect(exited)
        #expect(controller.state == .succeeded(selector: "#reviews"))
    }

    @Test func handlePickIsANoOpWhenNotPicking() {
        let controller = GoalElementPickController()
        controller.handlePick(GoalElementPickMessage(path: "/", element: elementInfo(id: "reviews")))
        #expect(controller.state == .idle)
    }

    @Test func acknowledgeReturnsATerminalStateToIdle() {
        let controller = GoalElementPickController()
        controller.startPicking(enterOverlayMode: {}, exitOverlayMode: {})
        controller.handlePick(GoalElementPickMessage(path: "/", element: elementInfo(id: "reviews")))
        controller.acknowledge()
        #expect(controller.state == .idle)
    }
}

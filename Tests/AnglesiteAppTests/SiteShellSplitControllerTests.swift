import Testing
import AppKit
import SwiftUI
@testable import AnglesiteAppCore

/// Freezes the shell controller's crash-class invariants (#1699 slice 1, design doc §"Why
/// this fixes the crash"): no column may publish sizing constraints, thicknesses are the
/// legacy chrome's constants, and collapse setters are idempotent. The crash itself is only
/// provable in the windowed 5× harness (plan Task 6); these tests pin what makes the shell
/// negotiation-free by construction.
@MainActor
@Suite("SiteShellSplitController invariants (#1699)")
struct SiteShellSplitControllerTests {
    private func makeController() -> SiteShellSplitController<Text, Text, Text> {
        let controller = SiteShellSplitController(
            sidebar: Text("s"), content: Text("c"), inspector: Text("i"))
        _ = controller.view // force viewDidLoad
        return controller
    }

    @Test("no hosting column publishes sizing constraints")
    func sizingOptionsEmpty() {
        let controller = makeController()
        #expect(controller.sidebarHost.sizingOptions == [])
        #expect(controller.contentHost.sizingOptions == [])
        #expect(controller.inspectorHost.sizingOptions == [])
    }

    @Test("three items with sidebar/inspector behaviors and legacy thicknesses")
    func itemsAndThicknesses() {
        let controller = makeController()
        #expect(controller.splitViewItems.count == 3)
        #expect(controller.sidebarItem.behavior == .sidebar)
        #expect(controller.inspectorItem.behavior == .inspector)
        #expect(controller.sidebarItem.minimumThickness == 200)
        #expect(controller.sidebarItem.maximumThickness == 360)
        #expect(controller.inspectorItem.minimumThickness == 260)
        #expect(controller.inspectorItem.maximumThickness == 420)
        #expect(controller.splitView.autosaveName == "site-shell")
    }

    @Test("collapse setters converge and are idempotent")
    func collapseSetters() {
        let controller = makeController()
        controller.setSidebarCollapsed(true, animated: false)
        #expect(controller.sidebarItem.isCollapsed)
        controller.setSidebarCollapsed(true, animated: false) // no-op, must not throw/toggle
        #expect(controller.sidebarItem.isCollapsed)
        controller.setInspectorCollapsed(true, animated: false)
        #expect(controller.inspectorItem.isCollapsed)
        controller.setInspectorCollapsed(false, animated: false)
        #expect(!controller.inspectorItem.isCollapsed)
    }

    @Test("update replaces the hosted root views")
    func updateReplacesRoots() {
        let controller = makeController()
        controller.update(sidebar: Text("s2"), content: Text("c2"), inspector: Text("i2"))
        // No public accessor for rootView equality on Text; the contract here is just that
        // update() executes without touching the split structure.
        #expect(controller.splitViewItems.count == 3)
    }
}

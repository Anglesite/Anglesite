import Testing
@testable import AnglesiteAppCore

/// Freezes the shell's SwiftUI↔AppKit convergence rules (#1699 slice 1): mutations fire only
/// when the sides disagree, and KVO echoes of our own mutations produce no write-back — the
/// re-entrancy guarantee the whole bridge leans on.
@Suite("SiteShellState convergence (#1699)")
struct SiteShellStateTests {
    @Test("collapse mutation fires only on disagreement")
    func collapseMutation() {
        #expect(SiteShellState.collapseMutation(visible: true, isCollapsed: true) == false)
        #expect(SiteShellState.collapseMutation(visible: false, isCollapsed: false) == true)
        #expect(SiteShellState.collapseMutation(visible: true, isCollapsed: false) == nil)
        #expect(SiteShellState.collapseMutation(visible: false, isCollapsed: true) == nil)
    }

    @Test("write-back fires only when the binding disagrees (KVO echo is a no-op)")
    func visibilityWriteBack() {
        #expect(SiteShellState.visibilityWriteBack(isCollapsed: true, bindingVisible: true) == false)
        #expect(SiteShellState.visibilityWriteBack(isCollapsed: false, bindingVisible: false) == true)
        #expect(SiteShellState.visibilityWriteBack(isCollapsed: true, bindingVisible: false) == nil)
        #expect(SiteShellState.visibilityWriteBack(isCollapsed: false, bindingVisible: true) == nil)
    }
}

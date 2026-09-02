import Foundation

/// Pure convergence rules for the AppKit shell bridge (#1699 slice 1, design doc
/// §Architecture): given SwiftUI's desired visibility and AppKit's observed collapse state,
/// decide the one mutation (or write-back) needed — or nothing when already converged.
/// Factored out of the controller/representable so SwiftPM tests can freeze the re-entrancy
/// behavior without a window: our own programmatic collapse produces a KVO echo whose
/// write-back must be a no-op, or the bridge would oscillate.
enum SiteShellState {
    /// The `isCollapsed` value to set to honor `visible`, or nil when already converged.
    static func collapseMutation(visible: Bool, isCollapsed: Bool) -> Bool? {
        let target = !visible
        return target == isCollapsed ? nil : target
    }

    /// The visibility value to write back for an observed collapse change, or nil when the
    /// binding already agrees (which is exactly the KVO echo of our own mutation).
    static func visibilityWriteBack(isCollapsed: Bool, bindingVisible: Bool) -> Bool? {
        let observedVisible = !isCollapsed
        return observedVisible == bindingVisible ? nil : observedVisible
    }
}

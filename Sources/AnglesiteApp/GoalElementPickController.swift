// Sources/AnglesiteApp/GoalElementPickController.swift
import Foundation
import Observation
import AnglesiteCore

/// Drives the click-to-select flow for an A/B experiment's "visible" goal (#1270 slice 5):
/// enters the overlay's goal-pick mode, waits for a click, and builds a CSS selector from it via
/// `GoalSelectorBuilder`. Simpler than `EffectPlacementController` — no page-model fetch or
/// applied edit, just a synchronous pure computation on the reported `ElementInfo`. One instance
/// per `ExperimentStatsModel` (Task 12).
@MainActor
@Observable
public final class GoalElementPickController {
    public enum State: Equatable {
        case idle
        case picking
        case succeeded(selector: String)
        case failed(String)
    }

    public private(set) var state: State = .idle
    private var exitOverlayMode: (() -> Void)?

    public init() {}

    public func startPicking(enterOverlayMode: @escaping () -> Void, exitOverlayMode: @escaping () -> Void) {
        guard case .idle = state else { return }
        self.exitOverlayMode = exitOverlayMode
        state = .picking
        enterOverlayMode()
    }

    public func cancel() {
        guard case .picking = state else { return }
        exitOverlayMode?()
        exitOverlayMode = nil
        state = .idle
    }

    /// Dismisses a terminal state (`.succeeded`/`.failed`) back to `.idle` — mirrors
    /// `EffectPlacementController.acknowledge()`'s reasoning: without this, `startPicking`'s
    /// `.idle` guard would refuse every pick after the first for the rest of this instance's life.
    public func acknowledge() {
        switch state {
        case .succeeded, .failed: state = .idle
        case .idle, .picking: return
        }
    }

    public func handlePick(_ message: GoalElementPickMessage) {
        guard case .picking = state else { return }
        exitOverlayMode?()
        exitOverlayMode = nil
        switch GoalSelectorBuilder.build(for: message.element) {
        case .success(let selector): state = .succeeded(selector: selector)
        }
    }
}

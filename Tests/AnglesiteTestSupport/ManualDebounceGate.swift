import Foundation

/// A manually-released stand-in for a production debounce timer, for models that expose a
/// `Sleep`-style seam (`@Sendable (Duration) async throws -> Void`, as `ComponentEditorModel`,
/// `InvisiblePublishQueue`, and `SyncScheduler` do). Each debounced operation parks in
/// `sleep()` instead of racing a real `Task.sleep` against the test's own wall-clock waits —
/// under concurrent-agent load on one Mac that race left a timer still pending when the test's
/// "settled" assertion ran (#1721), the same class of flake #762 fixed for the publish queue.
///
/// A test drives it by waiting (`waitUntil`) for `armedCount()` to reach the number of timers it
/// expects, then calling `release()` to "elapse" them all at once.
///
/// Cancellation is modelled the way the real `Task.sleep` behaves: a parked timer whose task is
/// cancelled throws `CancellationError` at once, and a timer whose task was cancelled *before* it
/// parked throws without ever arming. Either way the cancellation is counted in
/// `cancelledCount()` — the count is taken on the thrown path inside `sleep()` itself rather
/// than in the cancellation handler, so it cannot be lost when the handler's hop onto the actor
/// races ahead of `park` (a gap the first, file-private version of this gate had). That lets a
/// test assert "the first timer was cancelled" directly instead of waiting a window out and
/// checking nothing happened.
public actor ManualDebounceGate {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var cancelled = 0

    public init() {}

    /// Parks until `release()` — or throws `CancellationError` as soon as the calling task is
    /// cancelled, whether that happens while parked or before the timer ever armed.
    public func sleep() async throws {
        let id = UUID()
        do {
            try await withTaskCancellationHandler {
                try await park(id)
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        } catch is CancellationError {
            // Counted here, on the sleeping task after the throw has propagated, so the tally is
            // exact regardless of whether `cancelWaiter` (the handler's hop onto this actor) or
            // `park`'s own `Task.isCancelled` check was what threw.
            cancelled += 1
            throw CancellationError()
        }
    }

    private func park(_ id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // The cancellation flag is set before any handler runs, so a cancel that landed
            // before this point is always visible here — the timer throws without arming.
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters[id] = continuation
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Timers currently parked (armed and not yet released or cancelled).
    public func armedCount() -> Int { waiters.count }

    /// Timers torn down by task cancellation since the gate was created, including ones whose
    /// task was cancelled before they parked.
    public func cancelledCount() -> Int { cancelled }

    /// "Elapses" every armed timer at once.
    public func release() {
        let pending = Array(waiters.values)
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

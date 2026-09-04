import Foundation

/// Relays one conversational turn's ``AssistantEvent`` values to a consumer `AsyncStream`, so
/// ``FoundationModelAssistant`` can stop *delivering* on cancel without cancelling the model stream
/// (cancelling Apple's `streamResponse` mid-flight traps the process). Terminal transitions
/// (`complete`/`cancel`/`detach`) are once-only and thread-safe — the draining task and `cancel()`
/// race to end the same turn. Ungated, so it unit-tests on any toolchain (incl. CI without the model).
final class TurnRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: AsyncStream<AssistantEvent>.Continuation

    init(_ continuation: AsyncStream<AssistantEvent>.Continuation) {
        self.continuation = continuation
    }

    /// Forward a non-terminal event (`.started`, `.textDelta`) to the consumer, unless the turn has
    /// already ended (cancelled, detached, or completed). A no-op after the turn ends — so deltas
    /// from the still-draining model stream after a cancel are silently dropped.
    func deliver(_ event: AssistantEvent) {
        // Hold the lock across the `yield`: it serializes this delivery against `end`'s terminal
        // `yield`, guaranteeing the terminal event is the last thing the consumer sees. Releasing
        // the lock before yielding (as an earlier version did) lets a `deliver` land *between*
        // `end`'s terminal yield and its `finish()`, leaving a non-terminal event after the
        // terminal one. `yield` is non-blocking (per the `AsyncStream.Continuation` docs it
        // enqueues into the stream buffer and returns immediately, never calling back into user
        // code on this thread), so locking across it cannot deadlock; `finish()` *can* re-enter
        // (via `onTermination`), which is why `end` releases the lock before calling it.
        lock.withLock {
            if !finished { continuation.yield(event) }
        }
    }

    /// End the turn with a terminal event the model produced (`.turnComplete`/`.failed`).
    /// Ignored if the turn already ended (e.g. the consumer cancelled first).
    func complete(_ event: AssistantEvent) { end(emitting: event) }

    /// Consumer-initiated cancel: end the turn with `.cancelled`. Ignored if already ended.
    func cancel() { end(emitting: .cancelled) }

    /// The consumer dropped the stream: end silently with no terminal event. Ignored if already ended.
    func detach() { end(emitting: nil) }

    /// Once-only terminal transition: the draining task (`complete`) and the actor (`cancel`/`detach`)
    /// race to end the same turn; the first wins and emits its event, the rest are no-ops.
    private func end(emitting event: AssistantEvent?) {
        // Critical section: claim the once-only terminal transition and yield the terminal event
        // under the lock, so a concurrent `deliver` (which checks `finished` and yields under the
        // same lock) cannot interleave a non-terminal event after it — the terminal stays last in
        // the buffer. Returns whether *this* call won the race and therefore owns the `finish()`.
        let didFinish = lock.withLock { () -> Bool in
            if finished { return false }
            finished = true
            if let event { continuation.yield(event) }
            return true
        }
        guard didFinish else { return }
        // `finish()` runs *outside* the lock: it synchronously invokes the consumer's
        // `onTermination`, which re-enters this relay via `detach()`, so locking across it would
        // deadlock the non-recursive `NSLock`. `finished` is already set, so any racing `deliver`
        // that next acquires the lock sees it and skips — no stray yield lands after the terminal.
        continuation.finish()
    }
}

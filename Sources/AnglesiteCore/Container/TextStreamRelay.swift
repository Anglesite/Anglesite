import Foundation

/// Relays one one-shot generation's text chunks to a consumer `AsyncThrowingStream<String, Error>`,
/// so ``FoundationModelAssistant``'s `generate`/`textStream` path can stop *delivering* when the
/// consumer drops the stream without cancelling the model iteration (cancelling Apple's
/// `streamResponse` mid-flight traps the process — `brk 1`; see ``TurnRelay`` and #200/#201).
///
/// The throwing-`String` sibling of ``TurnRelay``: where `TurnRelay` carries an in-band terminal
/// ``AssistantEvent``, a text stream's terminal is just the stream ending (`complete`/`detach`) or
/// ending with an error (`fail`). Terminal transitions are once-only and thread-safe — the draining
/// task and the consumer's `onTermination` race to end the same stream. Ungated, so it unit-tests on
/// any toolchain (incl. CI without the model).
final class TextStreamRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: AsyncThrowingStream<String, Error>.Continuation

    init(_ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    /// Forward a text chunk to the consumer, unless the stream has already ended (completed, failed,
    /// or detached). A no-op after the stream ends — so chunks from the still-draining model stream
    /// after a detach are silently dropped.
    func deliver(_ text: String) {
        lock.lock()
        let done = finished
        lock.unlock()
        // Releasing the lock before `yield` is safe: if `end(throwing:)` races in on another thread
        // between the unlock and this line, a stale `yield` after `continuation.finish()` is
        // documented as a no-op. The lock only guards `finished`'s memory visibility.
        if !done { continuation.yield(text) }
    }

    /// End the stream normally (the drain reached the model's end-of-response). Ignored if the
    /// stream already ended (e.g. the consumer dropped it first).
    func complete() { end(throwing: nil) }

    /// End the stream with an error the model produced. Ignored if the stream already ended.
    func fail(_ error: Error) { end(throwing: error) }

    /// The consumer dropped the stream: end delivery without surfacing an error, never cancelling the
    /// model iteration. Ignored if already ended. Distinct from ``complete()`` only in intent — both
    /// finish without throwing — so a detach can't leak a late `fail` to a consumer that already left.
    func detach() { end(throwing: nil) }

    /// Once-only terminal transition: the draining task (`complete`/`fail`) and the consumer's
    /// `onTermination` (`detach`) race to end the same stream; the first wins, the rest are no-ops.
    private func end(throwing error: Error?) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        continuation.finish(throwing: error)
    }
}

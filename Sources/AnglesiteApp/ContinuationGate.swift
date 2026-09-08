import Foundation

/// Resume-at-most-once guard around a `CheckedContinuation`, with cancellation, for bridging a
/// callback-style system API that may report back zero, one, or two times.
///
/// Built for `CloudflareOAuthSignIn.defaultPresenter`'s `ASWebAuthenticationSession`, which has
/// been observed to do all three: complete normally; fail `start()` *and* still complete for the
/// same attempt (#1766 — so a second resume must be ignored, since resuming a
/// `CheckedContinuation` twice traps); and, when macOS hasn't verified the app's Associated
/// Domains, start successfully and then never call back at all (#1951 — so the waiting task must
/// be able to bail out through Swift cancellation instead of hanging forever).
///
/// Thread-safe: the session's completion handler runs nonisolated, and a `withTaskCancellationHandler`
/// `onCancel` block runs on whatever thread cancels the task, so every transition takes `lock`.
/// A `Result` delivered before `attach(_:)` is parked and delivered on attach, which keeps the
/// ordering between `withCheckedThrowingContinuation`'s setup closure and an early cancel
/// irrelevant to callers.
final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var settled = false
    private var cancelled = false
    private var cancelHandler: (@Sendable () -> Void)?

    /// Whether `cancel()` has run. Callers check this after `attach(_:)` so they don't start the
    /// underlying session for a task that was cancelled before the continuation even existed.
    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Registers the continuation. If a result (including a cancellation) was delivered first,
    /// the continuation is resumed with it immediately.
    func attach(_ continuation: CheckedContinuation<Value, Error>) {
        let parked: Result<Value, Error>? = lock.withLock {
            if let pendingResult {
                self.pendingResult = nil
                return pendingResult
            }
            self.continuation = continuation
            return nil
        }
        if let parked { continuation.resume(with: parked) }
    }

    /// Delivers `result` to the continuation. Only the first call takes effect; returns whether
    /// this call was that first one, so callers can log a late duplicate if they care.
    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        let (won, continuationToResume): (Bool, CheckedContinuation<Value, Error>?) = lock.withLock {
            guard !settled else { return (false, nil) }
            settled = true
            if let continuation {
                self.continuation = nil
                return (true, continuation)
            }
            pendingResult = result
            return (true, nil)
        }
        continuationToResume?.resume(with: result)
        return won
    }

    /// Cancels: resumes the continuation with `CancellationError` (unless a result already won)
    /// and runs the cancel handler once. A cancel after `finish` is a no-op — the session already
    /// reported back, so there's nothing left to tear down.
    func cancel() {
        let (proceed, handler): (Bool, (@Sendable () -> Void)?) = lock.withLock {
            guard !cancelled, !settled else { return (false, nil) }
            cancelled = true
            return (true, cancelHandler)
        }
        guard proceed else { return }
        finish(.failure(CancellationError()))
        handler?()
    }

    /// Installs the tear-down that `cancel()` runs (e.g. `ASWebAuthenticationSession.cancel()`).
    /// If the gate was already cancelled — the task was cancelled before the session was created —
    /// the handler runs immediately instead, so the session is never left running.
    func setCancelHandler(_ handler: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if cancelled { return true }
            cancelHandler = handler
            return false
        }
        if runNow { handler() }
    }
}

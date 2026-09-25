import Foundation
import Network

/// The one thing ``NetworkWait`` needs from a path monitor: a callback when the network is
/// satisfied, and a way to stop watching. `NWPathMonitor` conforms below; tests substitute a
/// hand-driven fake so the wait's resume/cancel behavior is checked without a real interface.
public protocol NetworkPathMonitoring: AnyObject {
    /// Starts watching; `onSatisfied` may fire any number of times, from any queue.
    func startWatching(onSatisfied: @escaping @Sendable () -> Void)
    /// Stops watching; no further callbacks.
    func cancelWatching()
}

extension NWPathMonitor: NetworkPathMonitoring {
    public func startWatching(onSatisfied: @escaping @Sendable () -> Void) {
        pathUpdateHandler = { path in
            if path.status == .satisfied { onSatisfied() }
        }
        start(queue: DispatchQueue(label: "io.dwk.anglesite.network-wait"))
    }

    public func cancelWatching() {
        cancel()
    }
}

/// The composer's automatic-retry trigger for the waiting-for-network state: resolves when
/// the network path is satisfied, or promptly on task cancellation. (OS-scheduled background
/// retry after the app exits is the design's noted follow-up; the queued draft persists either
/// way.)
public enum NetworkWait {
    /// Suspends until `monitor` reports a satisfied path, or the current task is cancelled.
    ///
    /// Honors task cancellation: SwiftUI cancels the enclosing `.task` when the composer goes
    /// away, and a bare `withCheckedContinuation` would leave the monitor and a suspended
    /// continuation alive until the device's network actually returned (#1370 review). The
    /// caller re-checks `Task.isCancelled` after this returns, so an early cancel-resume never
    /// triggers a retry.
    ///
    /// - Parameter monitor: The path monitor to watch; a fresh `NWPathMonitor` by default.
    public static func untilSatisfied(monitor: any NetworkPathMonitoring = NWPathMonitor()) async {
        defer { monitor.cancelWatching() }
        let gate = ContinuationGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate.arm(continuation)
                monitor.startWatching { gate.resume() }
            }
        } onCancel: {
            gate.resume()
        }
    }
}

/// Resumes a `Void` continuation exactly once, from whichever of the path-satisfied callback or
/// the cancellation handler fires first — both race on background queues, and a double resume
/// is a crash while a dropped one is a leak.
final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    /// Set when `resume()` ran before `arm(_:)` — cancellation can fire before the
    /// continuation exists; arming after that resumes immediately.
    private var resumedEarly = false

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if resumedEarly {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume() {
        lock.lock()
        guard let continuation else {
            resumedEarly = true
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume()
    }
}

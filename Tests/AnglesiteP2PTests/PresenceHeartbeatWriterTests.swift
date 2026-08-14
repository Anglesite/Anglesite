import Testing
import Foundation
@testable import AnglesiteP2P

@Suite
struct PresenceHeartbeatWriterTests {
    @Test func writesImmediatelyOnStart() async throws {
        // A 3600s interval means there is zero risk of a second write sneaking into any
        // human-scale wait window, no matter how loaded the CI runner is — unlike
        // `writesAgainAfterInterval` below, widening this margin can't introduce flakiness in
        // either direction, so a generous plain sleep (rather than event-driven waiting) is both
        // simpler and safe here.
        let writes = LockedArray<Date>()
        let writer = PresenceHeartbeatWriter(save: { date in writes.append(date) }, interval: .seconds(3600))
        let task = Task { await writer.run() }
        try await Task.sleep(for: .seconds(2))
        task.cancel()
        #expect(writes.count == 1)
    }

    @Test func writesAgainAfterInterval() async throws {
        // Waits for the writer's actual `save` calls via an AsyncStream instead of sleeping a
        // fixed wall-clock duration and then checking a count. A widened sleep margin (50ms/200ms,
        // then 10ms/500ms — ~50x nominal headroom) still flaked in CI's `build-test` job, which
        // runs this inside the full, unsharded 3800+-test suite rather than the isolated
        // timing-sensitive lane: scheduling jitter under that contention can exceed any sleep
        // window chosen in advance. Waiting on the real event has no such ceiling — it only fails
        // if the writer genuinely never calls `save` a second time, which is the actual behavior
        // under test. `iterator` is touched only here, sequentially, with no concurrent capture —
        // unlike a race-against-timeout, no task group is needed since we're always willing to
        // wait as long as it takes (bounded only by the suite's own time limit).
        let (stream, continuation) = AsyncStream<Date>.makeStream()
        let writer = PresenceHeartbeatWriter(save: { date in continuation.yield(date) }, interval: .milliseconds(1))
        let task = Task { await writer.run() }
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        task.cancel()
        #expect(first != nil)
        #expect(second != nil)
    }
}

/// Thread-safe append-only collector for `writesImmediatelyOnStart`'s timing assertion.
final class LockedArray<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [T] = []
    func append(_ value: T) { lock.lock(); values.append(value); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

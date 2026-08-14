import Testing
import Foundation
@testable import AnglesiteP2P

@Suite
struct PresenceHeartbeatWriterTests {
    @Test func writesImmediatelyOnStart() async throws {
        let writes = LockedArray<Date>()
        let writer = PresenceHeartbeatWriter(save: { date in writes.append(date) }, interval: .seconds(3600))
        let task = Task { await writer.run() }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(writes.count == 1)
    }

    @Test func writesAgainAfterInterval() async throws {
        let writes = LockedArray<Date>()
        let writer = PresenceHeartbeatWriter(save: { date in writes.append(date) }, interval: .milliseconds(50))
        let task = Task { await writer.run() }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        #expect(writes.count >= 2)
    }
}

/// Thread-safe append-only collector for the writer's timing assertions.
final class LockedArray<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [T] = []
    func append(_ value: T) { lock.lock(); values.append(value); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

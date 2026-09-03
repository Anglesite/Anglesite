import Foundation
import Testing
import AnglesiteTestSupport
@testable import AnglesiteCore

private actor PublishProbe {
    private(set) var calls = 0
    var result: InvisiblePublishQueue.Result

    init(result: InvisiblePublishQueue.Result = .succeeded(url: URL(string: "https://example.com") ?? URL(fileURLWithPath: "/"))) {
        self.result = result
    }

    func publish() -> InvisiblePublishQueue.Result {
        calls += 1
        return result
    }
}

private actor GatedPublishProbe {
    private(set) var calls = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func publish() async -> InvisiblePublishQueue.Result {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { firstContinuation = $0 }
        }
        return .succeeded(url: URL(string: "https://example.com") ?? URL(fileURLWithPath: "/"))
    }

    func waitUntilFirstPublishStarts() async {
        while calls == 0 { await Task.yield() }
    }

    func finishFirstPublish() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

// Serialized: each test drives the queue's debounce scheduling, and running them concurrently
// with each other amplifies scheduler starvation under `swift test --parallel` on loaded CI
// runners (#762).
@Suite("Invisible publish queue", .serialized)
struct InvisiblePublishQueueTests {
    @Test("idle edits debounce into one publish")
    func debouncesEdits() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = PublishProbe()
        let gate = ManualDebounceGate()
        let queue = InvisiblePublishQueue(
            configDirectory: directory,
            debounce: .milliseconds(250),
            publisher: { await probe.publish() },
            sleep: { _ in try await gate.sleep() }
        )

        await queue.start(isOnline: true)
        await queue.recordEdit()
        await queue.recordEdit()
        await queue.recordEdit()
        // Each recordEdit() cancels the previous debounce timer before arming a fresh one
        // (`scheduleDebounce()`), and the shared `ManualDebounceGate` — unlike this suite's old
        // file-private one — models that cancellation, so only the last edit's timer stays armed
        // while the first two settle as cancelled. Wait for that steady state rather than racing
        // real sleeps against actor scheduling (#762).
        try await waitUntil {
            let armed = await gate.armedCount()
            let cancelled = await gate.cancelledCount()
            return armed == 1 && cancelled == 2
        }
        await gate.release()
        try await waitUntil {
            let calls = await probe.calls
            let pending = await queue.hasPendingPublish()
            return calls == 1 && !pending
        }

        #expect(await probe.calls == 1)
        #expect(await queue.currentState() == .idle)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(InvisiblePublishQueue.filename).path
        ))
    }

    @Test("offline edits persist and drain after reconnect, including across queue recreation")
    func offlineQueueDrains() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstProbe = PublishProbe()
        let first = InvisiblePublishQueue(
            configDirectory: directory,
            debounce: .milliseconds(10),
            publisher: { await firstProbe.publish() }
        )
        await first.start(isOnline: false)
        await first.recordEdit()

        #expect(await firstProbe.calls == 0)
        #expect(await first.currentState() == .queuedOffline)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(InvisiblePublishQueue.filename).path
        ))
        await first.stop()

        let secondProbe = PublishProbe()
        let restored = InvisiblePublishQueue(
            configDirectory: directory,
            debounce: .milliseconds(10),
            publisher: { await secondProbe.publish() }
        )
        await restored.start(isOnline: false)
        #expect(await restored.hasPendingPublish())
        await restored.setOnline(true)
        try await waitUntil {
            let calls = await secondProbe.calls
            let pending = await restored.hasPendingPublish()
            return calls == 1 && !pending
        }

        #expect(await restored.currentState() == .idle)
    }

    @Test("security blocks remain durably queued")
    func securityBlockStaysPending() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = PublishProbe(result: .blocked(failureCount: 2))
        let gate = ManualDebounceGate()
        let queue = InvisiblePublishQueue(
            configDirectory: directory,
            debounce: .milliseconds(10),
            publisher: { await probe.publish() },
            sleep: { _ in try await gate.sleep() }
        )
        await queue.start(isOnline: true)
        await queue.recordEdit()
        try await waitUntil { await gate.armedCount() == 1 }
        await gate.release()
        try await waitUntil { await queue.currentState() == .blocked(failureCount: 2) }

        #expect(await queue.hasPendingPublish())
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(InvisiblePublishQueue.filename).path
        ))
    }

    @Test("an edit during publishing schedules a second generation")
    func editDuringPublishRunsAgain() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = GatedPublishProbe()
        let gate = ManualDebounceGate()
        let queue = InvisiblePublishQueue(
            configDirectory: directory,
            debounce: .milliseconds(20),
            publisher: { await probe.publish() },
            sleep: { _ in try await gate.sleep() }
        )
        await queue.start(isOnline: true)
        await queue.recordEdit()
        try await waitUntil { await gate.armedCount() == 1 }
        await gate.release()
        await probe.waitUntilFirstPublishStarts()
        await queue.recordEdit()
        await probe.finishFirstPublish()

        // The completed publish covered the pre-edit generation, so it schedules a second
        // debounce for the edit that landed mid-publish — release that one too.
        try await waitUntil { await gate.armedCount() == 1 }
        await gate.release()

        try await waitUntil {
            let calls = await probe.calls
            let pending = await queue.hasPendingPublish()
            return calls == 2 && !pending
        }
        #expect(await queue.currentState() == .idle)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InvisiblePublishQueueTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

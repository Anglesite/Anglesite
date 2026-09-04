// Exercises the Darwin SiteFileWatching implementation; compiles out with it off-Darwin.
#if canImport(CoreServices)
import Foundation
import Testing
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("FSEventsFileWatcher")
struct SiteFileWatcherTests {
    @Test("watcher reports a file write under the watched root", .timeLimit(.minutes(1)))
    func reportsFileWrite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fswatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Collect changed paths the watcher reports, guarded by a lock (callback runs off-thread).
        final class Box: @unchecked Sendable { let lock = NSLock(); var seen: Set<String> = [] }
        let box = Box()
        let watcher = FSEventsFileWatcher()
        try watcher.start(root: root) { batch in
            box.lock.lock(); defer { box.lock.unlock() }
            for url in batch.paths { box.seen.insert(url.standardizedFileURL.lastPathComponent) }
        }
        defer { watcher.stop() }

        // Give the stream a beat to arm, then write a file.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let target = root.appendingPathComponent("hello.astro")
        try Data("hi".utf8).write(to: target)

        try await waitUntil("the write to be reported", timeout: .seconds(10)) {
            box.lock.lock(); defer { box.lock.unlock() }
            return box.seen.contains("hello.astro")
        }
    }
}
#endif

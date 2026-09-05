// Exercises the Linux SiteFileWatching implementation; compiles out off-Linux.
#if canImport(Glibc)
import Foundation
import Testing
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite("InotifyFileWatcher")
struct InotifyFileWatcherTests {
    private final class BatchBox: @unchecked Sendable {
        let lock = NSLock()
        private var batches: [FileChangeBatch] = []
        func add(_ batch: FileChangeBatch) { lock.lock(); batches.append(batch); lock.unlock() }
        func all() -> [FileChangeBatch] { lock.lock(); defer { lock.unlock() }; return batches }
    }

    @Test("watcher reports a file write under the watched root", .timeLimit(.minutes(1)))
    func reportsFileWrite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inotify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let box = BatchBox()
        let watcher = InotifyFileWatcher()
        try watcher.start(root: root) { box.add($0) }
        defer { watcher.stop() }

        try? await Task.sleep(nanoseconds: 200_000_000)
        try Data("hi".utf8).write(to: root.appendingPathComponent("hello.astro"))

        try await waitUntil("the write to be reported", timeout: .seconds(10)) {
            box.all().contains { $0.paths.contains { $0.lastPathComponent == "hello.astro" } && !$0.needsFullRescan }
        }
    }

    @Test("a new subdirectory is watched for its own subsequent changes", .timeLimit(.minutes(1)))
    func tracksNewSubdirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inotify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let box = BatchBox()
        let watcher = InotifyFileWatcher()
        try watcher.start(root: root) { box.add($0) }
        defer { watcher.stop() }

        try? await Task.sleep(nanoseconds: 200_000_000)
        let sub = root.appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        // The directory's own creation is reported as a conservative rescan (its initial
        // contents can't be trusted to have been captured file-by-file).
        try await waitUntil("the new subdirectory to be reported as a rescan", timeout: .seconds(10)) {
            box.all().contains { $0.needsFullRescan }
        }

        // But a change written into it *after* that settles is tracked precisely, proving the
        // watcher armed a watch on the new subdirectory rather than only on the original root.
        try Data("hi".utf8).write(to: sub.appendingPathComponent("first-post.md"))
        try await waitUntil("the targeted write to be reported", timeout: .seconds(10)) {
            box.all().contains { $0.paths.contains { $0.lastPathComponent == "first-post.md" } && !$0.needsFullRescan }
        }
    }

    @Test("changes inside a skipped directory name never surface", .timeLimit(.minutes(1)))
    func ignoresSkippedDirectories() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inotify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let box = BatchBox()
        let watcher = InotifyFileWatcher()
        try watcher.start(root: root) { box.add($0) }
        defer { watcher.stop() }

        try? await Task.sleep(nanoseconds: 200_000_000)
        let nodeModules = root.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try Data("noise".utf8).write(to: nodeModules.appendingPathComponent("pkg.js"))

        // Give it as long as the other tests wait for a positive signal, then assert nothing
        // arrived — a skipped directory should never be watched, so it should never produce
        // a batch (rescan or otherwise).
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(box.all().isEmpty)
    }

    @Test("moving a watched subdirectory outside root releases its watch instead of leaking it", .timeLimit(.minutes(1)))
    func releasesWatchOnMoveOutOfTree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inotify-\(UUID().uuidString)", isDirectory: true)
        let sub = root.appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("f.txt"))

        let box = BatchBox()
        let watcher = InotifyFileWatcher()
        try watcher.start(root: root) { box.add($0) }
        defer { watcher.stop() }

        try? await Task.sleep(nanoseconds: 200_000_000)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("inotify-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: sub, to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        try? await waitUntil("the move to be reported as a rescan", timeout: .seconds(10)) {
            box.all().contains { $0.needsFullRescan }
        }
        let countAfterMove = box.all().count

        // Editing the file at its new, out-of-tree location must not surface here: if the old
        // watch on `posts` leaked (IN_MOVE_SELF doesn't auto-remove the kernel watch, unlike
        // deletion), this edit would show up as a batch reporting a path under the stale,
        // no-longer-existent `root/posts` — see the review that caught this.
        try Data("y".utf8).write(to: outside.appendingPathComponent("f.txt"))
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(box.all().count == countAfterMove)
    }

    @Test("a symlinked subdirectory is not recursed into", .timeLimit(.minutes(1)))
    func skipsSymlinkedSubdirectories() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inotify-\(UUID().uuidString)", isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        // A symlink back to `root` would send an unfiltered recursive walk into an infinite
        // cycle; `start()` returning promptly (within the test's time limit) is the assertion.
        try FileManager.default.createSymbolicLink(
            at: child.appendingPathComponent("loop"), withDestinationURL: root
        )

        let watcher = InotifyFileWatcher()
        try watcher.start(root: root) { _ in }
        watcher.stop()
    }
}
#endif

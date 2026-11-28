import Testing
import Foundation
@testable import AnglesiteCore

/// `HostSourceSync` (#2242): edits made outside Anglesite reach the container's working copy.
/// The pure planning is tested directly; the guest scripts run for real against a git clone
/// standing in for `/workspace/site` (its `origin` is the "host" repo, as in the container).
@Suite("HostSourceSync")
struct HostSourceSyncTests {
    // MARK: Pure

    @Test("relevant paths skip .git, generated directories and anything outside the site")
    func relevantPaths() {
        let root = URL(fileURLWithPath: "/sites/Foo.anglesite/Source")
        let batch = FileChangeBatch(paths: [
            root.appendingPathComponent("src/pages/about.md"),
            root.appendingPathComponent("src/pages/about.md"),
            root.appendingPathComponent(".git/index"),
            root.appendingPathComponent("node_modules/astro/x.js"),
            root.appendingPathComponent("dist/index.html"),
            URL(fileURLWithPath: "/elsewhere/file.txt"),
            root.appendingPathComponent("public/logo.png"),
        ], needsFullRescan: false)

        #expect(HostSourceSync.relevantPaths(in: batch, sourceDirectory: root) == ["public/logo.png", "src/pages/about.md"])
        #expect(HostSourceSync.relevantPaths(in: FileChangeBatch(paths: [], needsFullRescan: true), sourceDirectory: root) == nil)
    }

    @Test("parses the probe's output, and rejects anything else")
    func parseProbe() throws {
        let parsed = try #require(HostSourceSync.parseProbe("ahead 0 behind 2\nabc\tdef\tsrc/a b.md\n-\t-\tnew.md\n"))
        #expect(parsed.ahead == 0)
        #expect(parsed.behind == 2)
        #expect(parsed.files == [
            .init(path: "src/a b.md", current: "abc", committed: "def"),
            .init(path: "new.md", current: nil, committed: nil),
        ])
        #expect(HostSourceSync.parseProbe("") == nil)
        #expect(HostSourceSync.parseProbe("hello\n") == nil)
        #expect(HostSourceSync.parseProbe("ahead 0\n") == nil)
    }

    @Test("plans a copy only over an untouched guest file")
    func plan() {
        let new = Data("new".utf8)
        let newHash = HostSourceSync.sha256(new)
        let actions = HostSourceSync.plan(
            host: [
                .init(path: "clean.md", contents: new),
                .init(path: "synced.md", contents: new),
                .init(path: "edited-in-guest.md", contents: new),
                .init(path: "same.md", contents: new),
                .init(path: "created.md", contents: new),
                .init(path: "removed.md", contents: nil),
            ],
            guest: [
                .init(path: "clean.md", current: "head1", committed: "head1"),
                .init(path: "synced.md", current: "fromLastSync", committed: "head2"),
                .init(path: "edited-in-guest.md", current: "guestEdit", committed: "head3"),
                .init(path: "same.md", current: newHash, committed: "old"),
                .init(path: "created.md", current: nil, committed: nil),
                .init(path: "removed.md", current: "head4", committed: "head4"),
            ],
            lastSynced: ["synced.md": "fromLastSync"])

        #expect(actions == [
            .write(path: "clean.md", sha256: newHash),
            .write(path: "synced.md", sha256: newHash),
            .conflict(path: "edited-in-guest.md"),
            .unchanged(path: "same.md"),
            .write(path: "created.md", sha256: newHash),
            .delete(path: "removed.md"),
        ])
    }

    // MARK: Real scripts

    /// A "host" repo and a "guest" clone of it, with `exec` running argv in the guest like
    /// `LocalContainerControl.exec` does.
    struct Fixture {
        let host: URL
        let guest: URL

        init(files: [String: String]) throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("host-sync-\(UUID().uuidString)")
            host = base.appendingPathComponent("Source")
            guest = base.appendingPathComponent("guest")
            try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
            for (path, text) in files { try Self.write(text, to: host.appendingPathComponent(path)) }
            try Self.git(["init", "-q", "-b", "main"], in: host)
            try Self.git(["add", "-A"], in: host)
            try Self.git(["commit", "-q", "-m", "init"], in: host)
            try Self.git(["clone", "-q", host.path, guest.path], in: base)
        }

        static func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        @discardableResult
        static func git(_ args: [String], in dir: URL) throws -> String {
            try run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.com"] + args, in: dir).stdout
        }

        static func run(_ argv: [String], in dir: URL) throws -> ContainerExecResult {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
            process.currentDirectoryURL = dir
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            process.environment = environment
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ContainerExecResult(
                exitCode: process.terminationStatus,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self))
        }

        func sync(_ paths: [String], lastSynced: [String: String] = [:]) async throws -> HostSourceSync.Outcome {
            try await HostSourceSync.run(paths: paths, sourceDirectory: host, lastSynced: lastSynced) { argv in
                try Self.run(argv, in: guest)
            }
        }

        func guestText(_ path: String) -> String? {
            (try? Data(contentsOf: guest.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    @Test("an uncommitted host edit reaches the guest, and a second one does too")
    func carriesEdits() async throws {
        let fixture = try Fixture(files: ["src/pages/about.md": "# About\n"])
        try Fixture.write("# About us\n", to: fixture.host.appendingPathComponent("src/pages/about.md"))

        let first = try await fixture.sync(["src/pages/about.md"])
        #expect(first.written == ["src/pages/about.md"])
        #expect(fixture.guestText("src/pages/about.md") == "# About us\n")

        // The guest file now differs from its HEAD only because of the sync, so it still counts
        // as untouched for the next edit.
        try Fixture.write("# About our shop\n", to: fixture.host.appendingPathComponent("src/pages/about.md"))
        let second = try await fixture.sync(["src/pages/about.md"], lastSynced: first.lastSynced)
        #expect(second.written == ["src/pages/about.md"])
        #expect(fixture.guestText("src/pages/about.md") == "# About our shop\n")

        // Nothing changed: nothing written.
        let third = try await fixture.sync(["src/pages/about.md"], lastSynced: second.lastSynced)
        #expect(third.written.isEmpty)
    }

    @Test("a guest file being edited in the guest is kept")
    func keepsGuestEdits() async throws {
        let fixture = try Fixture(files: ["src/pages/about.md": "# About\n"])
        try Fixture.write("# Guest edit\n", to: fixture.guest.appendingPathComponent("src/pages/about.md"))
        try Fixture.write("# Host edit\n", to: fixture.host.appendingPathComponent("src/pages/about.md"))

        let outcome = try await fixture.sync(["src/pages/about.md"])
        #expect(outcome.conflicts == ["src/pages/about.md"])
        #expect(fixture.guestText("src/pages/about.md") == "# Guest edit\n")
    }

    @Test("new files get their folders, deleted files go, binary and multi-chunk content survives")
    func createsDeletesAndRoundTrips() async throws {
        let fixture = try Fixture(files: ["src/pages/old.md": "old\n"])
        try FileManager.default.removeItem(at: fixture.host.appendingPathComponent("src/pages/old.md"))
        try Fixture.write("# New\n", to: fixture.host.appendingPathComponent("src/pages/deep/new.md"))
        // Larger than one argv chunk once base64-encoded, and not valid UTF-8.
        var bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        bytes.append(contentsOf: [0xff, 0xfe, 0x00])
        try FileManager.default.createDirectory(at: fixture.host.appendingPathComponent("public"), withIntermediateDirectories: true)
        try bytes.write(to: fixture.host.appendingPathComponent("public/photo.jpg"))

        let outcome = try await fixture.sync(["public/photo.jpg", "src/pages/deep/new.md", "src/pages/old.md"])
        #expect(outcome.written == ["public/photo.jpg", "src/pages/deep/new.md"])
        #expect(outcome.deleted == ["src/pages/old.md"])
        #expect(outcome.failed.isEmpty)
        #expect(fixture.guestText("src/pages/deep/new.md") == "# New\n")
        #expect(fixture.guestText("src/pages/old.md") == nil)
        #expect(try Data(contentsOf: fixture.guest.appendingPathComponent("public/photo.jpg")) == bytes)
        // No temp files left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.guest.appendingPathComponent("public").path)
        #expect(leftovers == ["photo.jpg"])
    }

    @Test("nothing is copied while the guest has commits the host doesn't")
    func waitsForUnsavedGuestWork() async throws {
        let fixture = try Fixture(files: ["src/pages/about.md": "# About\n", "src/pages/index.md": "# Home\n"])
        try Fixture.write("# Home, edited in the editor\n", to: fixture.guest.appendingPathComponent("src/pages/index.md"))
        try Fixture.git(["commit", "-q", "-am", "editor edit"], in: fixture.guest)
        try Fixture.write("# About us\n", to: fixture.host.appendingPathComponent("src/pages/about.md"))

        let outcome = try await fixture.sync(["src/pages/about.md"])
        #expect(outcome.skippedUnsavedGuestWork)
        #expect(outcome.written.isEmpty)
        #expect(fixture.guestText("src/pages/about.md") == "# About\n")
    }

    @Test("host commits fast-forward the guest, even over files an earlier sync wrote")
    func catchesUpWithHostCommits() async throws {
        let fixture = try Fixture(files: ["src/pages/about.md": "# About\n", "src/pages/index.md": "# Home\n"])
        // 1. An uncommitted host edit is synced: the guest's about.md now differs from its HEAD.
        try Fixture.write("# About us\n", to: fixture.host.appendingPathComponent("src/pages/about.md"))
        let first = try await fixture.sync(["src/pages/about.md"])
        #expect(first.written == ["src/pages/about.md"])

        // 2. The owner commits it in VS Code, plus a change to index.md, then keeps editing about.md.
        try Fixture.write("# Home, updated\n", to: fixture.host.appendingPathComponent("src/pages/index.md"))
        try Fixture.git(["commit", "-q", "-am", "edits"], in: fixture.host)
        try Fixture.write("# About us, again\n", to: fixture.host.appendingPathComponent("src/pages/about.md"))

        let second = try await fixture.sync(["src/pages/index.md"], lastSynced: first.lastSynced)
        #expect(second.caughtUpWithHostCommits)
        // The guest's HEAD is the host's, so the app's later `git pull --ff-only` has nothing to
        // refuse, and the still-uncommitted host edit to about.md came across too.
        #expect(try Fixture.git(["rev-parse", "HEAD"], in: fixture.guest) == Fixture.git(["rev-parse", "HEAD"], in: fixture.host))
        #expect(fixture.guestText("src/pages/index.md") == "# Home, updated\n")
        #expect(fixture.guestText("src/pages/about.md") == "# About us, again\n")
        #expect(second.written == ["src/pages/about.md"])
    }

    @Test("the catch-up alone does what syncFromHost's git pull --ff-only did, plus restoring sync copies")
    func catchUpReplacesPull() async throws {
        let fixture = try Fixture(files: ["src/pages/about.md": "# About\n"])
        try Fixture.write("# About us\n", to: fixture.host.appendingPathComponent("src/pages/about.md"))
        let synced = try await fixture.sync(["src/pages/about.md"])
        // The app's own content operation commits on the host, then calls syncFromHost.
        try Fixture.git(["commit", "-q", "-am", "native edit"], in: fixture.host)

        let result = try Fixture.run(HostSourceSync.catchUpArgv(lastSynced: synced.lastSynced), in: fixture.guest)
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(result.stdout == "src/pages/about.md\n")
        #expect(try Fixture.git(["rev-parse", "HEAD"], in: fixture.guest) == Fixture.git(["rev-parse", "HEAD"], in: fixture.host))
        #expect(try Fixture.git(["status", "--porcelain"], in: fixture.guest).isEmpty)
    }

    @Test("a path with spaces and shell characters is carried literally")
    func awkwardPath() async throws {
        let path = "src/pages/it's a $test.md"
        let fixture = try Fixture(files: [path: "one\n"])
        try Fixture.write("two\n", to: fixture.host.appendingPathComponent(path))

        let outcome = try await fixture.sync([path])
        #expect(outcome.written == [path])
        #expect(fixture.guestText(path) == "two\n")
    }
}

// Tests/AnglesiteTestSupport/TemporaryUserDefaults.swift
// A throwaway `UserDefaults` suite that never touches ~/Library/Preferences (#1727).
import Foundation

/// A uniquely named, throwaway `UserDefaults` suite for tests that need an `AppSettings` (or any
/// other defaults-backed type) isolated from `.standard` and from every other concurrently
/// running test.
///
/// Call `cleanup()` once the suite is no longer needed — from a `deinit` on a class-based suite,
/// a `defer`, or via ``withTemporaryUserDefaults(label:_:)-6ym9d``.
///
/// ## Why this isn't just `UserDefaults(suiteName: "test-anglesite-<UUID>")`
///
/// A plain suite name is materialized by cfprefsd as `~/Library/Preferences/<suite>.plist` on the
/// first write, and nothing a test can do reclaims that file: `removePersistentDomain(forName:)`
/// rewrites it as an empty dictionary rather than unlinking it, and unlinking it by hand only
/// lasts until the test process exits, when cfprefsd writes the (empty) domain back out. That is
/// how developer Macs accumulated tens of thousands of 42-byte `test-anglesite-*.plist` files —
/// even from suites that dutifully removed their domain in `deinit` (#1727).
///
/// So on Darwin the suite name is instead an **absolute path** inside a per-suite scratch
/// directory under the user's temporary directory — CFPreferences treats a path-shaped
/// application ID as "persist to exactly this plist". Nothing ever lands in
/// `~/Library/Preferences`, and `cleanup()` removes the whole directory. Deleting the
/// *directory* is the load-bearing step: `removePersistentDomain(forName:)` on a path-shaped
/// domain still rewrites the plist as an empty dictionary, exactly like a named one, but cfprefsd
/// never recreates a missing parent directory — not synchronously, and not when the process
/// exits, even if the domain still held cached values at that point (verified from a second
/// process after the writing process had exited, macOS 27 — see PR #1731). A suite that crashes
/// before cleanup leaks only into `$TMPDIR`, which the OS purges on its own. Names keep the
/// `test-anglesite-` prefix so any leftover — old or new — stays recognizable, and
/// `scripts/check-test-userdefaults-leak.sh` (CI runs it after `swift test`) fails on one.
public struct TemporaryUserDefaults: @unchecked Sendable {
    /// Prefix shared by every suite this helper creates. Nothing but tests writes it.
    public static let suitePrefix = "test-anglesite-"

    /// The suite's leaf name, `test-anglesite-[<label>-]<UUID>`.
    public let name: String

    /// What was handed to `UserDefaults(suiteName:)`: on Darwin the absolute path
    /// `<directory>/<name>`, elsewhere just ``name``.
    public let suiteName: String

    /// The per-suite scratch directory backing the suite on Darwin; `nil` where the suite is a
    /// plain named domain instead (Linux, whose Foundation has no cfprefsd to work around).
    public let directory: URL?

    /// The suite itself. `UserDefaults` is thread-safe, hence the `@unchecked Sendable` above.
    public let defaults: UserDefaults

    /// - Parameter label: Optional human-readable marker baked into the suite name (e.g.
    ///   `"startup"`) so a leftover can be traced back to its suite.
    public init(label: String? = nil) {
        var name = Self.suitePrefix
        if let label, !label.isEmpty { name += "\(label)-" }
        name += UUID().uuidString
        self.name = name

        #if canImport(Darwin)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("could not create scratch directory for \(name): \(error)")
        }
        self.directory = directory
        self.suiteName = directory.appendingPathComponent(name).path
        #else
        self.directory = nil
        self.suiteName = name
        #endif

        // `UserDefaults(suiteName:)` only returns nil for the global domain or the main bundle
        // identifier — neither of which a `test-anglesite-<UUID>` name can collide with.
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName:) refused \(suiteName)")
        }
        self.defaults = defaults
    }

    /// Where the suite is persisted once a value has been written (`<directory>/<name>.plist`),
    /// or `nil` on platforms without a backing ``directory``.
    public var plistURL: URL? {
        directory?.appendingPathComponent("\(name).plist")
    }

    /// Removes the persistent domain, flushes it, and deletes the backing scratch directory —
    /// the directory deletion is what keeps cfprefsd from writing an empty plist back (see the
    /// type's documentation). Idempotent — safe to call more than once.
    public func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults.synchronize()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// Runs `body` against a fresh ``TemporaryUserDefaults`` suite and cleans it up afterwards —
/// including when `body` throws or an expectation inside it fails.
public func withTemporaryUserDefaults<T>(
    label: String? = nil, _ body: (UserDefaults) throws -> T
) rethrows -> T {
    let scratch = TemporaryUserDefaults(label: label)
    defer { scratch.cleanup() }
    return try body(scratch.defaults)
}

/// Async variant of ``withTemporaryUserDefaults(label:_:)-6ym9d``.
public func withTemporaryUserDefaults<T>(
    label: String? = nil, _ body: (UserDefaults) async throws -> T
) async rethrows -> T {
    let scratch = TemporaryUserDefaults(label: label)
    defer { scratch.cleanup() }
    return try await body(scratch.defaults)
}

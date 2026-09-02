import Testing
import Foundation
import AnglesiteTestSupport

/// Proves the `AnglesiteTestSupport` scratch-suite helper keeps test defaults out of
/// `~/Library/Preferences` and reclaims what it does write (#1727). Lives here rather than in a
/// dedicated target because `AnglesiteTestSupport` has no test target of its own and
/// `AnglesiteCoreTests` already depends on it.
@Suite("TemporaryUserDefaults (#1727)")
struct TemporaryUserDefaultsTests {
    private struct Boom: Error {}

    @Test("suite names carry the test-anglesite- prefix and the optional label")
    func suiteNaming() {
        let plain = TemporaryUserDefaults()
        defer { plain.cleanup() }
        #expect(plain.name.hasPrefix(TemporaryUserDefaults.suitePrefix))
        #expect(plain.suiteName.hasSuffix(plain.name))

        let labeled = TemporaryUserDefaults(label: "startup")
        defer { labeled.cleanup() }
        #expect(labeled.name.hasPrefix("test-anglesite-startup-"))
        #expect(labeled.name != plain.name)
    }

    @Test("withTemporaryUserDefaults hands the body a suite isolated from .standard")
    func isolatedFromStandard() {
        let key = "temporaryUserDefaultsTests.\(UUID().uuidString)"
        withTemporaryUserDefaults { defaults in
            defaults.set("scratch", forKey: key)
            #expect(defaults.string(forKey: key) == "scratch")
            #expect(UserDefaults.standard.string(forKey: key) == nil)
        }
    }

    @Test("withTemporaryUserDefaults removes the domain even when the body throws")
    func cleanupOnThrow() {
        var captured: UserDefaults?
        #expect(throws: Boom.self) {
            try withTemporaryUserDefaults { defaults in
                captured = defaults
                defaults.set("value", forKey: "key")
                throw Boom()
            }
        }
        #expect(captured != nil)
        #expect(captured?.object(forKey: "key") == nil, "cleanup() should have removed the domain")
    }

    @Test("the async variant runs the body and still cleans up")
    func asyncVariant() async {
        var captured: UserDefaults?
        let written: Bool = await withTemporaryUserDefaults { defaults in
            captured = defaults
            defaults.set(true, forKey: "written")
            await Task.yield()
            return defaults.bool(forKey: "written")
        }
        #expect(written)
        #expect(captured?.object(forKey: "written") == nil, "cleanup() should have removed the domain")
    }

#if canImport(Darwin)
    /// The leak regression itself: a written suite must be persisted under the scratch directory,
    /// never as `~/Library/Preferences/<suite>.plist`, and `cleanup()` must leave nothing behind.
    @Test("a written suite lives in its scratch directory, not ~/Library/Preferences, and cleanup() reclaims it")
    func persistsOutsideLibraryPreferences() throws {
        let scratch = TemporaryUserDefaults(label: "plist-reclaim")
        let directory = try #require(scratch.directory)
        let plistURL = try #require(scratch.plistURL)
        #expect(plistURL.lastPathComponent == "\(scratch.name).plist")
        #expect(plistURL.deletingLastPathComponent() == directory)

        scratch.defaults.set("value", forKey: "key")
        scratch.defaults.synchronize()
        #expect(FileManager.default.fileExists(atPath: plistURL.path),
                "cfprefsd should have materialized the suite in its scratch directory")
        #expect(UserDefaults(suiteName: scratch.suiteName)?.string(forKey: "key") == "value",
                "a second instance of the same suite should read the persisted value back")
        #expect(Self.libraryPreferencesEntries(containing: scratch.name).isEmpty,
                "the suite must not be materialized in ~/Library/Preferences")

        scratch.cleanup()
        #expect(!FileManager.default.fileExists(atPath: plistURL.path))
        #expect(!FileManager.default.fileExists(atPath: directory.path),
                "cleanup() must remove the whole scratch directory")
        #expect(Self.libraryPreferencesEntries(containing: scratch.name).isEmpty)
    }

    /// Entries in `~/Library/Preferences` whose name contains `fragment` — the directory the
    /// leaked `test-anglesite-*.plist` files of #1727 accumulated in.
    private static func libraryPreferencesEntries(containing fragment: String) -> [String] {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        else { return [] }
        let preferences = library.appendingPathComponent("Preferences", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        return entries.filter { $0.contains(fragment) }
    }
#endif
}

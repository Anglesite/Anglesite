import Testing
import Foundation
@testable import AnglesiteCore

@Suite("CodableFileStore")
struct CodableFileStoreTests {
    private struct Fixture: Codable, Equatable, Sendable {
        var name: String
        var count: Int
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodableFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("load on a missing file returns nil, not a throw")
    func loadMissingReturnsNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CodableFileStore<Fixture>.json(fileURL: dir.appendingPathComponent("fixture.json"))
        #expect(try store.load() == nil)
    }

    @Test("save then load round-trips through JSON")
    func jsonRoundTrips() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("fixture.json")
        let store = CodableFileStore<Fixture>.json(fileURL: fileURL)
        let value = Fixture(name: "site", count: 3)
        try store.save(value)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try store.load() == value)
    }

    @Test("save then load round-trips through plist")
    func plistRoundTrips() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("fixture.plist")
        let store = CodableFileStore<Fixture>.plist(fileURL: fileURL)
        let value = Fixture(name: "site", count: 3)
        try store.save(value)
        #expect(try store.load() == value)
    }

    @Test("save creates the parent directory if needed")
    func saveCreatesParentDirectory() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("Config", isDirectory: true)
        let store = CodableFileStore<Fixture>.json(fileURL: nested.appendingPathComponent("fixture.json"))
        try store.save(Fixture(name: "nested", count: 1))
        #expect(try store.load() == Fixture(name: "nested", count: 1))
    }

    @Test("save writes atomically (no partial file visible mid-write)")
    func saveWritesAtomically() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("fixture.json")
        let store = CodableFileStore<Fixture>.json(fileURL: fileURL)
        try store.save(Fixture(name: "first", count: 1))
        try store.save(Fixture(name: "second", count: 2))
        // No stray temp files from the atomic-write dance should remain in the directory.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(siblings == ["fixture.json"])
        #expect(try store.load() == Fixture(name: "second", count: 2))
    }

    @Test("loadOrDefault falls back on a missing file")
    func loadOrDefaultMissingFallsBack() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CodableFileStore<Fixture>.json(fileURL: dir.appendingPathComponent("fixture.json"))
        #expect(store.loadOrDefault(Fixture(name: "default", count: 0)) == Fixture(name: "default", count: 0))
    }

    @Test("loadOrDefault falls back on a corrupt file instead of throwing")
    func loadOrDefaultCorruptFallsBack() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("fixture.json")
        try Data("not valid json".utf8).write(to: fileURL)
        let store = CodableFileStore<Fixture>.json(fileURL: fileURL)
        #expect(store.loadOrDefault(Fixture(name: "default", count: 0)) == Fixture(name: "default", count: 0))
    }

    @Test("load throws on a corrupt existing file")
    func loadThrowsOnCorruptFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("fixture.json")
        try Data("not valid json".utf8).write(to: fileURL)
        let store = CodableFileStore<Fixture>.json(fileURL: fileURL)
        #expect(throws: (any Error).self) {
            try store.load()
        }
    }

    @Test("migrate rewrites old-shaped bytes before decode")
    func migrateRewritesOldShape() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("fixture.json")
        // Legacy on-disk shape: a bare string where the current format expects {"name":...,"count":...}.
        try Data("\"legacy-name\"".utf8).write(to: fileURL)
        let store = CodableFileStore<Fixture>.json(fileURL: fileURL, migrate: { data in
            guard let legacyName = try? JSONDecoder().decode(String.self, from: data) else { return data }
            return try JSONEncoder().encode(Fixture(name: legacyName, count: 0))
        })
        #expect(try store.load() == Fixture(name: "legacy-name", count: 0))
    }

    @Test("migrate failure falls back to default in loadOrDefault")
    func migrateFailureFallsBackToDefault() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("fixture.json")
        try Data("{}".utf8).write(to: fileURL)
        struct MigrationError: Error {}
        let store = CodableFileStore<Fixture>.json(fileURL: fileURL, migrate: { _ in throw MigrationError() })
        #expect(store.loadOrDefault(Fixture(name: "default", count: 0)) == Fixture(name: "default", count: 0))
    }

    @Test("exists reflects the backing file's presence")
    func existsReflectsPresence() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CodableFileStore<Fixture>.json(fileURL: dir.appendingPathComponent("fixture.json"))
        #expect(!store.exists())
        try store.save(Fixture(name: "x", count: 1))
        #expect(store.exists())
    }

    @Test("merge receives nil existing bytes when the file doesn't exist yet")
    func mergeReceivesNilForNewFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("fixture.json")
        nonisolated(unsafe) var observedExisting: Data??
        let store = CodableFileStore<Fixture>.json(fileURL: fileURL, merge: { new, existing in
            observedExisting = existing
            return new
        })
        try store.save(Fixture(name: "first", count: 1))
        #expect(observedExisting == .some(nil))
        #expect(try store.load() == Fixture(name: "first", count: 1))
    }

    @Test("merge combines freshly-encoded bytes with the file's existing bytes")
    func mergeCombinesWithExistingBytes() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("fixture.json")
        // Merge hook that always keeps the existing file's `count`, ignoring the new value —
        // exercises that `merge` sees both the fresh bytes and whatever is already on disk.
        let store = CodableFileStore<Fixture>.json(fileURL: fileURL, merge: { new, existing in
            guard let existing else { return new }
            var newValue = try JSONDecoder().decode(Fixture.self, from: new)
            let existingValue = try JSONDecoder().decode(Fixture.self, from: existing)
            newValue.count = existingValue.count
            return try JSONEncoder().encode(newValue)
        })
        try store.save(Fixture(name: "first", count: 1))
        try store.save(Fixture(name: "second", count: 99))
        #expect(try store.load() == Fixture(name: "second", count: 1))
    }

    @Test("passing no merge hook is a no-op — save behaves exactly as before")
    func noMergeHookIsNoOp() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("fixture.json")
        let store = CodableFileStore<Fixture>.json(fileURL: fileURL)
        try store.save(Fixture(name: "first", count: 1))
        try store.save(Fixture(name: "second", count: 2))
        #expect(try store.load() == Fixture(name: "second", count: 2))
    }
}

import Testing
import Foundation
@testable import AnglesiteCore

@Suite("RedirectsStore")
struct RedirectsStoreTests {
    private func tempSourceDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedirectsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("load on a missing file returns an empty array, not a throw")
    func loadMissingReturnsEmpty() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        #expect(try store.load() == [])
    }

    @Test("save then load round-trips entries through redirects.json")
    func saveLoadRoundTrips() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent)]
        try store.save(entries)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("redirects.json").path))
        #expect(try store.load() == entries)
    }

    @Test("save rejects a source that doesn't start with /")
    func rejectsMissingLeadingSlash() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [RedirectsStore.RedirectEntry(source: "old", destination: "/new", code: .permanent)]
        #expect(throws: RedirectsStore.ValidationError.sourceMustStartWithSlash("old")) {
            try store.save(entries)
        }
    }

    @Test("save rejects a duplicate source")
    func rejectsDuplicateSource() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [
            RedirectsStore.RedirectEntry(source: "/a", destination: "/b", code: .permanent),
            RedirectsStore.RedirectEntry(source: "/a", destination: "/c", code: .permanent),
        ]
        #expect(throws: RedirectsStore.ValidationError.duplicateSource("/a")) {
            try store.save(entries)
        }
    }

    @Test("save rejects a source equal to its own destination")
    func rejectsSelfCycle() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [RedirectsStore.RedirectEntry(source: "/a", destination: "/a", code: .permanent)]
        #expect(throws: RedirectsStore.ValidationError.cycle("/a", "/a")) {
            try store.save(entries)
        }
    }

    @Test("save rejects a two-hop A→B, B→A cycle")
    func rejectsTwoHopCycle() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [
            RedirectsStore.RedirectEntry(source: "/a", destination: "/b", code: .permanent),
            RedirectsStore.RedirectEntry(source: "/b", destination: "/a", code: .permanent),
        ]
        #expect(throws: RedirectsStore.ValidationError.cycle("/a", "/b")) {
            try store.save(entries)
        }
    }

    @Test("a rejected save leaves the previously-saved file untouched")
    func rejectedSaveDoesNotOverwrite() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let good = [RedirectsStore.RedirectEntry(source: "/a", destination: "/b", code: .permanent)]
        try store.save(good)
        let bad = [RedirectsStore.RedirectEntry(source: "/a", destination: "/a", code: .permanent)]
        #expect(throws: (any Error).self) { try store.save(bad) }
        #expect(try store.load() == good)
    }

    @Test("save rejects a source containing an embedded space")
    func rejectsSourceWithEmbeddedSpace() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [RedirectsStore.RedirectEntry(source: "/old page", destination: "/new", code: .permanent)]
        #expect(throws: RedirectsStore.ValidationError.sourceContainsWhitespace("/old page")) {
            try store.save(entries)
        }
    }

    @Test("save rejects a destination containing an embedded space")
    func rejectsDestinationWithEmbeddedSpace() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [RedirectsStore.RedirectEntry(source: "/old", destination: "/new page", code: .permanent)]
        #expect(throws: RedirectsStore.ValidationError.destinationContainsWhitespace("/new page")) {
            try store.save(entries)
        }
    }

    @Test("save rejects a destination containing a newline")
    func rejectsDestinationWithNewline() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [RedirectsStore.RedirectEntry(source: "/old", destination: "/new\n/injected 302", code: .permanent)]
        #expect(throws: RedirectsStore.ValidationError.destinationContainsWhitespace("/new\n/injected 302")) {
            try store.save(entries)
        }
    }

    @Test("save rejects an empty-string destination")
    func rejectsEmptyDestination() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [RedirectsStore.RedirectEntry(source: "/old", destination: "", code: .permanent)]
        #expect(throws: RedirectsStore.ValidationError.destinationMustBeAbsolutePathOrURL("")) {
            try store.save(entries)
        }
    }

    @Test("save rejects a destination with no leading slash and no scheme")
    func rejectsDestinationWithoutSlashOrScheme() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [RedirectsStore.RedirectEntry(source: "/old", destination: "new", code: .permanent)]
        #expect(throws: RedirectsStore.ValidationError.destinationMustBeAbsolutePathOrURL("new")) {
            try store.save(entries)
        }
    }

    @Test("save accepts an absolute https:// URL destination")
    func acceptsAbsoluteHTTPSDestination() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RedirectsStore(sourceDirectory: dir)
        let entries = [RedirectsStore.RedirectEntry(source: "/old", destination: "https://example.com/new", code: .permanent)]
        try store.save(entries)
        #expect(try store.load() == entries)
    }

    @Test("re-saving a fixture written with the pre-CodableFileStore encoder produces identical bytes")
    func byteCompatibleWithPreMigrationEncoder() throws {
        let dir = try tempSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = [
            RedirectsStore.RedirectEntry(source: "/old", destination: "/new", code: .permanent),
            RedirectsStore.RedirectEntry(source: "/temp", destination: "https://example.com", code: .temporary),
        ]
        // Reproduces RedirectsStore.save()'s encoder configuration before the CodableFileStore migration.
        let legacyEncoder = JSONEncoder()
        legacyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let legacyBytes = try legacyEncoder.encode(entries)
        let fileURL = dir.appendingPathComponent("redirects.json")
        try legacyBytes.write(to: fileURL)

        let store = RedirectsStore(sourceDirectory: dir)
        try store.save(try store.load())

        #expect(try Data(contentsOf: fileURL) == legacyBytes)
    }
}

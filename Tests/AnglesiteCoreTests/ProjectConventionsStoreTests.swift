import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ProjectConventionsStore")
struct ProjectConventionsStoreTests {
    private func makeConfigDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("conventions-store-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("load returns nil when no file exists yet")
    func loadReturnsNilWhenMissing() async {
        let store = ProjectConventionsStore(configDirectory: makeConfigDirectory())
        #expect(await store.load() == nil)
    }

    @Test("save then load round-trips a value, including overrides")
    func saveThenLoadRoundTrips() async {
        let store = ProjectConventionsStore(configDirectory: makeConfigDirectory())
        var conventions = ProjectConventions.empty
        conventions.apply(.brandTerms(["Anglesite"]))

        await store.save(conventions)
        let loaded = await store.load()

        #expect(loaded?.writing.brandTerms.value == ["Anglesite"])
        #expect(loaded?.writing.brandTerms.isOverridden == true)
    }

    @Test("save creates the config directory if it doesn't exist yet")
    func saveCreatesConfigDirectory() async {
        let configDirectory = makeConfigDirectory()
        let store = ProjectConventionsStore(configDirectory: configDirectory)

        await store.save(.empty)

        #expect(FileManager.default.fileExists(atPath: configDirectory.appendingPathComponent("conventions.json").path))
    }

    // MARK: - Byte-compatibility with the pre-`CodableFileStore` encoder (#1917)

    @Test("an old-encoder conventions.json round-trips to identical, non-pretty-printed bytes")
    func byteCompatibilityRoundTrip() async throws {
        let configDirectory = makeConfigDirectory()
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDirectory) }
        let fileURL = configDirectory.appendingPathComponent("conventions.json")

        var conventions = ProjectConventions.empty
        conventions.apply(.brandTerms(["Anglesite"]))

        let oldEncoder = JSONEncoder()
        oldEncoder.dateEncodingStrategy = .iso8601
        oldEncoder.outputFormatting = [.sortedKeys]
        let fixtureBytes = try oldEncoder.encode(conventions)
        try fixtureBytes.write(to: fileURL)

        let store = ProjectConventionsStore(configDirectory: configDirectory)
        let loaded = await store.load()
        #expect(loaded == conventions)
        await store.save(loaded ?? .empty)

        let resavedBytes = try Data(contentsOf: fileURL)
        #expect(resavedBytes == fixtureBytes)

        // A future default-formatting change must not silently reformat this file.
        let text = try #require(String(data: resavedBytes, encoding: .utf8))
        #expect(!text.contains("\n  "))
    }
}

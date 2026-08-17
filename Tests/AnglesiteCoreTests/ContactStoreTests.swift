import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ContactStore")
struct ContactStoreTests {
    private static func makeConfigDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContactStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func contact(
        me: String = "https://alice.example", name: String = "Alice"
    ) -> Contact {
        Contact(
            me: URL(string: me)!, displayName: name,
            addedDate: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("returns empty when no file exists yet")
    func returnsEmptyForMissingFile() async throws {
        let directory = try Self.makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactStore(configDirectory: directory)
        #expect(try await store.load() == [])
    }

    @Test("round-trips a contact through add and load")
    func roundTrips() async throws {
        let directory = try Self.makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactStore(configDirectory: directory)
        let contact = Self.contact()
        try await store.add(contact)

        let loaded = try await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == contact.id)
        #expect(loaded.first?.displayName == "Alice")
    }

    @Test("adding a contact with a matching me URL replaces the existing entry")
    func addReplacesOnMatchingIdentity() async throws {
        let directory = try Self.makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactStore(configDirectory: directory)
        try await store.add(Self.contact(me: "https://alice.example", name: "Alice"))
        try await store.add(Self.contact(me: "https://alice.example/", name: "Alice Renamed"))

        let loaded = try await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.displayName == "Alice Renamed")
    }

    @Test("update rekeys a contact whose me URL changed")
    func updateRekeys() async throws {
        let directory = try Self.makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactStore(configDirectory: directory)
        var contact = Self.contact(me: "https://old.example")
        try await store.add(contact)

        contact.me = URL(string: "https://new.example")!
        try await store.update(contact)

        let loaded = try await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.me.absoluteString == "https://new.example")
    }

    @Test("remove deletes by id")
    func removeDeletes() async throws {
        let directory = try Self.makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactStore(configDirectory: directory)
        let contact = Self.contact()
        try await store.add(contact)
        try await store.remove(id: contact.id)

        #expect(try await store.load() == [])
    }

    @Test("throws instead of silently discarding a corrupt file")
    func throwsOnCorruptFile() async throws {
        let directory = try Self.makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{ not json".utf8).write(
            to: directory.appendingPathComponent(ContactStore.filename))
        let store = ContactStore(configDirectory: directory)

        await #expect(throws: (any Error).self) {
            try await store.load()
        }
    }

    @Test("knownMeURLs normalizes scheme and trailing slash")
    func knownMeURLsNormalizes() async throws {
        let directory = try Self.makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactStore(configDirectory: directory)
        try await store.add(Self.contact(me: "https://alice.example/"))

        let known = try await store.knownMeURLs()
        #expect(known.contains(normalizedIdentityKey(for: URL(string: "http://alice.example")!)))
    }
}

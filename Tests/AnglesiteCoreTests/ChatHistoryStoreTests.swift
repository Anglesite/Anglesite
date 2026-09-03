import Testing
import Foundation
@testable import AnglesiteCore

final class ChatHistoryStoreTests {
    private let tmpDir: URL

    init() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("chat-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test("load returns empty when file missing")
    func loadReturnsEmptyWhenFileMissing() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        let entries = try await store.load()
        #expect(entries == [])
    }

    @Test("append creates the directory and file")
    func appendCreatesDirectoryAndFile() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        try await store.append(.init(role: .user, content: "Hello"))
        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("chat-history.jsonl").path))
    }

    @Test("append then load round trips")
    func appendThenLoadRoundTrips() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        let entries: [ChatHistoryStore.Entry] = [
            .init(role: .user, content: "Hi"),
            .init(role: .assistant, content: "Hello there."),
            .init(role: .tool, content: "file contents", metadata: ["toolUseID": "t1", "name": "Read"])
        ]
        for entry in entries { try await store.append(entry) }
        let loaded = try await store.load()
        #expect(loaded.count == 3)
        #expect(loaded.map(\.role) == [.user, .assistant, .tool])
        #expect(loaded.map(\.content) == ["Hi", "Hello there.", "file contents"])
        #expect(loaded[2].metadata?["toolUseID"] == "t1")
    }

    @Test("a corrupt line does not destroy the rest of the history")
    func corruptLineDoesNotDestroyHistory() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        try await store.append(.init(role: .user, content: "good"))
        // Inject a junk line between two good ones.
        let url = await store.fileURL
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{this is not valid json}\n".utf8))
        try handle.close()
        try await store.append(.init(role: .assistant, content: "bye"))

        let loaded = try await store.load()
        #expect(loaded.map(\.content) == ["good", "bye"], "corrupt line skipped, valid entries preserved")
    }

    @Test("clear empties the file")
    func clearEmptiesTheFile() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        try await store.append(.init(role: .user, content: "transient"))
        try await store.clear()
        let loaded = try await store.load()
        #expect(loaded == [])
    }

    @Test("clear is a no-op when the file is missing")
    func clearIsNoOpWhenFileMissing() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        try await store.clear()  // should not throw
        let loaded = try await store.load()
        #expect(loaded == [])
    }

    // MARK: edit rows + undone records

    @Test("an edit entry round trips with metadata")
    func editEntryRoundTripsWithMetadata() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        let edit = ChatHistoryStore.Entry(
            role: .edit,
            content: "Edited src/pages/about.astro",
            metadata: ["file": "src/pages/about.astro", "commit": "abc123"]
        )
        try await store.append(edit)
        let loaded = try await store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].role == .edit)
        #expect(loaded[0].metadata?["file"] == "src/pages/about.astro")
        #expect(loaded[0].metadata?["commit"] == "abc123")
    }

    @Test("an undone record flips the referenced edit's undone flag")
    func undoneRecordFlipsTheReferencedEditsUndoneFlag() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        let editID = UUID()
        let edit = ChatHistoryStore.Entry(
            role: .edit,
            content: "Edited src/pages/about.astro",
            metadata: ["file": "src/pages/about.astro", "commit": "abc123", "messageID": editID.uuidString]
        )
        try await store.append(edit)
        try await store.appendUndone(messageID: editID, newCommit: "def456")

        let loaded = try await store.load()
        #expect(loaded.count == 1, "undone records collapse onto the referenced edit, not as separate rows")
        #expect(loaded[0].metadata?["undone"] == "true")
        #expect(loaded[0].metadata?["undoneNewCommit"] == "def456")
    }

    @Test("an undone record without a matching edit is ignored")
    func undoneRecordWithoutMatchingEditIsIgnored() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        try await store.appendUndone(messageID: UUID(), newCommit: "orphan")
        let loaded = try await store.load()
        #expect(loaded == [])
    }

    @Test("mixed history preserves order and applies undone")
    func mixedHistoryPreservesOrderAndAppliesUndone() async throws {
        let store = ChatHistoryStore(configDirectory: tmpDir)
        let editID = UUID()
        try await store.append(.init(role: .user, content: "Hi"))
        try await store.append(.init(
            role: .edit,
            content: "Edited src/pages/about.astro",
            metadata: ["file": "src/pages/about.astro", "commit": "abc123", "messageID": editID.uuidString]
        ))
        try await store.append(.init(role: .assistant, content: "OK."))
        try await store.appendUndone(messageID: editID, newCommit: "def456")

        let loaded = try await store.load()
        #expect(loaded.count == 3)
        #expect(loaded.map(\.role) == [.user, .edit, .assistant])
        #expect(loaded[1].metadata?["undone"] == "true")
    }
}

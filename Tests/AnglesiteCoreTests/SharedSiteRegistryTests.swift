import Testing
import Foundation
@testable import AnglesiteCore

struct SharedSiteRegistryTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anglesite-shared-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("read returns empty array when nothing has been published")
    func readEmptyByDefault() throws {
        let dir = try tempDir()
        #expect(SharedSiteRegistry.read(from: dir).isEmpty)
    }

    @Test("publish then read round-trips, sorted most-recently-seen first")
    func publishReadRoundTrip() throws {
        let dir = try tempDir()
        let older = SharedSite(id: "a", name: "Alpha", bookmarkData: Data([1]), lastSeen: Date(timeIntervalSince1970: 100))
        let newer = SharedSite(id: "b", name: "Bravo", bookmarkData: Data([2]), lastSeen: Date(timeIntervalSince1970: 200))
        SharedSiteRegistry.publish([older, newer], to: dir)
        let read = SharedSiteRegistry.read(from: dir)
        #expect(read.map(\.id) == ["b", "a"])
        #expect(read.first?.bookmarkData == Data([2]))
    }

    @Test("publish overwrites a previous manifest rather than appending")
    func publishOverwrites() throws {
        let dir = try tempDir()
        SharedSiteRegistry.publish([SharedSite(id: "a", name: "Alpha", bookmarkData: Data(), lastSeen: Date())], to: dir)
        SharedSiteRegistry.publish([SharedSite(id: "b", name: "Bravo", bookmarkData: Data(), lastSeen: Date())], to: dir)
        #expect(SharedSiteRegistry.read(from: dir).map(\.id) == ["b"])
    }

    @Test("publish to an unwritable directory does not throw")
    func publishBestEffort() throws {
        // A file (not a directory) at this path makes createDirectory fail — publish must swallow it.
        let dir = try tempDir()
        let blocker = dir.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let blockedDir = blocker.appendingPathComponent("nested", isDirectory: true)
        SharedSiteRegistry.publish([SharedSite(id: "a", name: "Alpha", bookmarkData: Data(), lastSeen: Date())], to: blockedDir)
        // No crash/throw reaching here is the assertion.
    }

    @Test("SharedContainer.url returns nil without the App Group entitlement")
    func containerURLNilInTests() {
        // Test/CI processes never carry the application-groups entitlement.
        #expect(SharedContainer.url() == nil)
    }
}

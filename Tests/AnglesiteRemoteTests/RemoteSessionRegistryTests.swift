import Testing
import Foundation
@testable import AnglesiteRemote

@Suite struct RemoteSessionRegistryTests {
    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func publishThenLookupRoundTrips() async throws {
        let registry = RemoteSessionRegistry(directory: try Self.makeTempDir())
        let claim = RemoteSessionClaim(
            siteID: "abc", previewURL: URL(string: "http://127.0.0.1:4321")!,
            mcpURL: URL(string: "http://127.0.0.1:4399")!, ownerPID: 42)
        try await registry.publish(claim)
        #expect(try await registry.lookup(siteID: "abc") == claim)
    }

    @Test func lookupMissingReturnsNil() async throws {
        let registry = RemoteSessionRegistry(directory: try Self.makeTempDir())
        #expect(try await registry.lookup(siteID: "nope") == nil)
    }

    @Test func withdrawRemovesClaim() async throws {
        let registry = RemoteSessionRegistry(directory: try Self.makeTempDir())
        let claim = RemoteSessionClaim(
            siteID: "abc", previewURL: URL(string: "http://127.0.0.1:4321")!,
            mcpURL: URL(string: "http://127.0.0.1:4399")!, ownerPID: 42)
        try await registry.publish(claim)
        try await registry.withdraw(siteID: "abc")
        #expect(try await registry.lookup(siteID: "abc") == nil)
    }

    @Test func withdrawMissingIsNoOp() async throws {
        let registry = RemoteSessionRegistry(directory: try Self.makeTempDir())
        try await registry.withdraw(siteID: "nope")  // must not throw
    }

    @Test func publishReplacesExistingClaimForSameSite() async throws {
        let registry = RemoteSessionRegistry(directory: try Self.makeTempDir())
        let first = RemoteSessionClaim(
            siteID: "abc", previewURL: URL(string: "http://127.0.0.1:1111")!,
            mcpURL: URL(string: "http://127.0.0.1:2222")!, ownerPID: 1)
        let second = RemoteSessionClaim(
            siteID: "abc", previewURL: URL(string: "http://127.0.0.1:3333")!,
            mcpURL: URL(string: "http://127.0.0.1:4444")!, ownerPID: 2)
        try await registry.publish(first)
        try await registry.publish(second)
        #expect(try await registry.lookup(siteID: "abc") == second)
    }
}

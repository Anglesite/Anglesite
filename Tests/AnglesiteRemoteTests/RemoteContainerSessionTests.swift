import Testing
import Foundation
@testable import AnglesiteRemote
import AnglesiteCore

@Suite struct RemoteContainerSessionTests {
    static func makeRegistry() throws -> RemoteSessionRegistry {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RemoteSessionRegistry(directory: dir)
    }

    @Test func bootsFreshWhenNoExistingClaim() async throws {
        let control = FakeLocalContainerControl()
        let registry = try Self.makeRegistry()
        let session = RemoteContainerSession(control: control, registry: registry, pid: 111)
        let result = try await session.ensureRunning(
            siteID: "site-1", sourceRepo: URL(fileURLWithPath: "/tmp/site"), ref: "HEAD", onOutput: { _, _ in })
        #expect(await control.startCallCount == 1)
        let claim = try await registry.lookup(siteID: "site-1")
        #expect(claim?.previewURL == result.previewURL)
        #expect(claim?.ownerPID == 111)
    }

    @Test func reusesExistingClaimWithoutBooting() async throws {
        let registry = try Self.makeRegistry()
        try await registry.publish(RemoteSessionClaim(
            siteID: "site-1", previewURL: URL(string: "http://127.0.0.1:9001")!,
            mcpURL: URL(string: "http://127.0.0.1:9002")!, ownerPID: 999))
        let control = FakeLocalContainerControl()
        let session = RemoteContainerSession(control: control, registry: registry, pid: 111)
        let result = try await session.ensureRunning(
            siteID: "site-1", sourceRepo: URL(fileURLWithPath: "/tmp/site"), ref: "HEAD", onOutput: { _, _ in })
        #expect(await control.startCallCount == 0)
        #expect(result.previewURL == URL(string: "http://127.0.0.1:9001")!)
    }

    @Test func tearDownWithdrawsOwnClaimOnlyWhenOwner() async throws {
        let control = FakeLocalContainerControl()
        let registry = try Self.makeRegistry()
        let owner = RemoteContainerSession(control: control, registry: registry, pid: 111)
        _ = try await owner.ensureRunning(
            siteID: "site-1", sourceRepo: URL(fileURLWithPath: "/tmp/site"), ref: "HEAD", onOutput: { _, _ in })
        let borrower = RemoteContainerSession(control: control, registry: registry, pid: 222)
        _ = try await borrower.ensureRunning(
            siteID: "site-1", sourceRepo: URL(fileURLWithPath: "/tmp/site"), ref: "HEAD", onOutput: { _, _ in })
        await borrower.tearDown(siteID: "site-1")
        #expect(try await registry.lookup(siteID: "site-1") != nil)  // borrower didn't withdraw the owner's claim
        await owner.tearDown(siteID: "site-1")
        #expect(try await registry.lookup(siteID: "site-1") == nil)
        #expect(await control.stopCallCount == 1)  // only the real owner's teardown stopped the container
    }
}

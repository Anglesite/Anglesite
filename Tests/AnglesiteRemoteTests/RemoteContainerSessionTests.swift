import Testing
import Foundation
@testable import AnglesiteRemote
import AnglesiteCore
import AnglesiteTestSupport

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
        // Must be a genuinely live PID — RemoteContainerSession's liveness check (see
        // reusesClaimWhoseOwnerProcessIsAlive) discards a claim whose owner is dead, and a fixed
        // magic number isn't guaranteed alive on every machine (it happened to be a real
        // long-lived process locally but not on a fresh CI runner).
        let livePID = ProcessInfo.processInfo.processIdentifier
        try await registry.publish(RemoteSessionClaim(
            siteID: "site-1", previewURL: URL(string: "http://127.0.0.1:9001")!,
            mcpURL: URL(string: "http://127.0.0.1:9002")!, ownerPID: livePID))
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
        // The owner's pid becomes the published claim's ownerPID, which the borrower's lookup
        // liveness-checks — must be genuinely alive (see reusesExistingClaimWithoutBooting).
        let owner = RemoteContainerSession(control: control, registry: registry, pid: ProcessInfo.processInfo.processIdentifier)
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

    /// Nothing withdraws a claim when its owner is SIGKILLed, so a claim is only worth trusting
    /// while `ownerPID` is still alive. A dead owner must be treated exactly like no claim at all
    /// — otherwise every future session for this site bridges to ports nobody is listening on.
    @Test func discardsClaimWhoseOwnerProcessIsGone() async throws {
        let registry = try Self.makeRegistry()
        let deadPID = try Self.reapedProcessIdentifier()
        try await registry.publish(RemoteSessionClaim(
            siteID: "site-1", previewURL: URL(string: "http://127.0.0.1:9001")!,
            mcpURL: URL(string: "http://127.0.0.1:9002")!, ownerPID: deadPID))
        let control = FakeLocalContainerControl()
        let session = RemoteContainerSession(control: control, registry: registry, pid: 111)
        let result = try await session.ensureRunning(
            siteID: "site-1", sourceRepo: URL(fileURLWithPath: "/tmp/site"), ref: "HEAD", onOutput: { _, _ in })
        #expect(await control.startCallCount == 1)  // booted fresh rather than reusing the corpse
        #expect(result.previewURL == URL(string: "http://127.0.0.1:4321")!)
        let claim = try await registry.lookup(siteID: "site-1")
        #expect(claim?.ownerPID == 111)  // and the stale claim was replaced by this session's own
    }

    /// A live owner's claim is still honoured — the liveness check above must not turn every
    /// reuse into a second boot. This session's own PID stands in for "a process that exists".
    @Test func reusesClaimWhoseOwnerProcessIsAlive() async throws {
        let registry = try Self.makeRegistry()
        let livePID = ProcessInfo.processInfo.processIdentifier
        try await registry.publish(RemoteSessionClaim(
            siteID: "site-1", previewURL: URL(string: "http://127.0.0.1:9001")!,
            mcpURL: URL(string: "http://127.0.0.1:9002")!, ownerPID: livePID))
        let control = FakeLocalContainerControl()
        let session = RemoteContainerSession(control: control, registry: registry, pid: 111)
        let result = try await session.ensureRunning(
            siteID: "site-1", sourceRepo: URL(fileURLWithPath: "/tmp/site"), ref: "HEAD", onOutput: { _, _ in })
        #expect(await control.startCallCount == 0)
        #expect(result.previewURL == URL(string: "http://127.0.0.1:9001")!)
    }

    /// A registry write that fails AFTER a successful boot must not lose the container: ownership
    /// is recorded before `publish` runs, so `tearDown` still stops the VM. The publish failure is
    /// logged, not rethrown — reporting a "boot failure" that didn't happen while abandoning a
    /// running VM is strictly worse than an unpublished claim.
    @Test func publishFailureAfterBootStillLeavesTheContainerOwned() async throws {
        // A registry directory that doesn't exist: `lookup` reads it as "no claim" and `publish`'s
        // write throws — the real type, no fake seam needed.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-missing-\(UUID().uuidString)", isDirectory: true)
        let registry = RemoteSessionRegistry(directory: missing)
        let control = FakeLocalContainerControl()
        let session = RemoteContainerSession(control: control, registry: registry, pid: 111)

        let result = try await session.ensureRunning(
            siteID: "site-1", sourceRepo: URL(fileURLWithPath: "/tmp/site"), ref: "HEAD", onOutput: { _, _ in })
        #expect(result.previewURL == URL(string: "http://127.0.0.1:4321")!)
        #expect(await control.startCallCount == 1)
        #expect(try await registry.lookup(siteID: "site-1") == nil)  // the claim really didn't land

        await session.tearDown(siteID: "site-1")
        #expect(await control.stopCallCount == 1, "the container leaked — ownership wasn't recorded")
    }

    /// A PID guaranteed not to name a live process: spawn a trivial command, wait for it to exit,
    /// and reuse its (now reaped) identifier. More reliable than picking a large number and hoping.
    private static func reapedProcessIdentifier() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    @Test func isOwnerTrueAfterBootingFresh() async throws {
        let control = FakeLocalContainerControl()
        let registry = try Self.makeRegistry()
        let session = RemoteContainerSession(control: control, registry: registry, pid: 111)
        _ = try await session.ensureRunning(
            siteID: "site-1", sourceRepo: URL(fileURLWithPath: "/tmp/site"), ref: "HEAD", onOutput: { _, _ in })
        #expect(await session.isOwner(siteID: "site-1"))
    }

    @Test func isOwnerFalseWhenBorrowingAnExistingClaim() async throws {
        let registry = try Self.makeRegistry()
        let livePID = ProcessInfo.processInfo.processIdentifier
        try await registry.publish(RemoteSessionClaim(
            siteID: "site-1", previewURL: URL(string: "http://127.0.0.1:9001")!,
            mcpURL: URL(string: "http://127.0.0.1:9002")!, ownerPID: livePID))
        let control = FakeLocalContainerControl()
        let session = RemoteContainerSession(control: control, registry: registry, pid: 111)
        _ = try await session.ensureRunning(
            siteID: "site-1", sourceRepo: URL(fileURLWithPath: "/tmp/site"), ref: "HEAD", onOutput: { _, _ in })
        #expect(!(await session.isOwner(siteID: "site-1")))
    }

    @Test func isOwnerFalseForUnknownSite() async throws {
        let session = RemoteContainerSession(control: FakeLocalContainerControl(), registry: try Self.makeRegistry(), pid: 111)
        #expect(!(await session.isOwner(siteID: "never-booted")))
    }
}

import Testing
import Foundation
import AnglesiteTestSupport
#if canImport(CloudKit)
import CloudKit
@testable import AnglesiteP2P

/// Offline coverage of the `CKRecord` ↔ `DeviceAnnounceRecord` mapping. A `CKRecord` is a plain
/// in-memory object until something saves it, so this half of `CloudKitPairingService` needs
/// neither a signed-in iCloud account nor the CloudKit entitlement — which is exactly why it is
/// *not* gated behind `ANGLESITE_CK_TESTS`: it is the part CI can actually run.
@Suite
struct DeviceAnnounceRecordMappingTests {
    @Test func recordRoundTripsThroughCloudKitRepresentation() throws {
        let createdAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let original = DeviceAnnounceRecord(
            deviceID: "device-abc", publicKeyData: Data([0x04, 0x01, 0x02]),
            displayName: "Studio Mac", createdAt: createdAt)

        let record = original.makeCloudKitRecord()
        let decoded = try #require(DeviceAnnounceRecord(record: record))

        #expect(decoded == original)
    }

    /// The record name is the `deviceID`, so a re-announce overwrites rather than accumulating a
    /// second row for the same device.
    @Test func recordNameIsTheDeviceID() {
        let record = DeviceAnnounceRecord(
            deviceID: "device-abc", publicKeyData: Data([0x04]),
            displayName: "Studio Mac", createdAt: Date()
        ).makeCloudKitRecord()

        #expect(record.recordID.recordName == "device-abc")
        #expect(record.recordType == DeviceAnnounceRecord.cloudKitRecordType)
    }

    /// A peer (or a stale schema) can put anything in the owner's private database, so decoding is
    /// "drop, don't throw" — matching `SignedSignalingChannel`'s posture for untrusted input.
    @Test func decodingRejectsRecordsMissingRequiredFields() {
        let record = CKRecord(
            recordType: DeviceAnnounceRecord.cloudKitRecordType,
            recordID: CKRecord.ID(recordName: "device-abc"))
        record["deviceID"] = "device-abc" as CKRecordValue
        // No publicKey / displayName / createdAt.

        #expect(DeviceAnnounceRecord(record: record) == nil)
    }

    @Test func decodingRejectsAWrongRecordType() {
        let record = CKRecord(recordType: "SomethingElse", recordID: CKRecord.ID(recordName: "x"))
        record["deviceID"] = "x" as CKRecordValue
        record["publicKey"] = Data([0x04]) as CKRecordValue
        record["displayName"] = "x" as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue

        #expect(DeviceAnnounceRecord(record: record) == nil)
    }

    /// The X9.63 uncompressed point `DevicePairingKeyPair.publicKeyData` produces is 65 bytes —
    /// three orders of magnitude below CloudKit's 1 MB per-record ceiling, so a plain `Data`
    /// field is correct here and `CKAsset` would be wrong (see the type's doc comment).
    @Test func publicKeySurvivesAFullSizeX963Key() throws {
        let key = Data([0x04]) + Data(repeating: 0xAB, count: 64)
        let record = DeviceAnnounceRecord(
            deviceID: "device-abc", publicKeyData: key, displayName: "Mac", createdAt: Date()
        ).makeCloudKitRecord()

        let decoded = try #require(DeviceAnnounceRecord(record: record))
        #expect(decoded.publicKeyData == key)
        #expect(decoded.publicKeyData.count == 65)
    }
}

/// Observation-lifecycle coverage, offline — the poll loop's start/stop/termination behavior,
/// which is where a leaked timer would hide.
///
/// These build the service through its offline initializer rather than with a real container
/// **because `CKContainer(identifier:)` traps the process when the binary lacks the CloudKit
/// entitlement.** That was verified directly in this checkout: a binary calling it dies with
/// SIGTRAP before reaching the next statement. An ungated test that constructed one would not fail,
/// it would take down the whole `AnglesiteP2PTests` process — which is also why the suite below
/// stays gated.
@Suite
struct CloudKitPairingServiceLifecycleTests {
    /// The race that `stopped` closes: `announcedDevices()` starts observation from an unstructured
    /// `Task`, so that task can land *after* a `stopObserving()` that beat it. Before the fix it
    /// would pass the `observationTask == nil` guard and start a fresh 15-second poll loop feeding
    /// an already-finished continuation — forever, with no consumer and no second stop coming.
    /// Calling `startObserving()` directly reproduces that ordering deterministically.
    @Test func startingObservationAfterStopIsANoOp() async {
        let service = CloudKitPairingService(offlinePollInterval: .milliseconds(5))
        await service.stopObserving()

        await service.startObserving()

        #expect(await service.isObserving == false)
        #expect(await service.pollCount == 0)
    }

    /// `stopObserving()` must actually halt polling, not merely detach the handle — so this asserts
    /// the poll count stops advancing, which a leaked loop would keep incrementing.
    @Test func stopObservingHaltsThePollLoop() async throws {
        let service = CloudKitPairingService(offlinePollInterval: .milliseconds(5))
        await service.startObserving()
        try await waitUntil("the poll loop to tick at least once") { await service.pollCount > 0 }
        #expect(await service.isObserving == true)

        await service.stopObserving()
        // Let any in-flight iteration finish before sampling, so the baseline isn't racy.
        try await Task.sleep(for: .milliseconds(50))
        let settled = await service.pollCount
        try await Task.sleep(for: .milliseconds(100))

        #expect(await service.isObserving == false)
        #expect(await service.pollCount == settled)
    }

    /// A consumer that is cancelled (or breaks out of `for await`) terminates the stream without
    /// ever calling `stopObserving()`. Without the `onTermination` hook the loop would go on
    /// hitting CloudKit for the life of the process, yielding into a continuation nobody reads.
    @Test func consumerCancellationStopsThePollLoop() async throws {
        let service = CloudKitPairingService(offlinePollInterval: .milliseconds(5))
        let consumer = Task { for await _ in service.announcedDevices() {} }
        try await waitUntil("observation to start") { await service.isObserving == true }

        consumer.cancel()
        // `onTermination` hops back onto the actor; wait for that hop to land instead of
        // guessing how long it takes under load.
        try await waitUntil("cancellation to stop the poll loop") { await service.isObserving == false }
        let settled = await service.pollCount
        try await Task.sleep(for: .milliseconds(100))

        #expect(await service.isObserving == false)
        #expect(await service.pollCount == settled)
    }

    /// The retain cycle: the actor owns `observationTask`, so if that task captured the actor
    /// strongly, the pair would keep each other alive for the life of the process unless someone
    /// remembered to call `stopObserving()` by hand. Dropping the last external reference without
    /// stopping must therefore still let the service deallocate — the poll loop holds it only for
    /// the duration of each `refresh()`, never across the sleep, and a `nil` self ends the loop.
    @Test func droppingTheServiceWithoutStoppingDeallocatesIt() async throws {
        weak var weakService: CloudKitPairingService?
        do {
            let service = CloudKitPairingService(offlinePollInterval: .milliseconds(5))
            weakService = service
            await service.startObserving()
            try await waitUntil("the poll loop to tick at least once") { await service.pollCount > 0 }
        }

        try await waitUntil("the service to deallocate once dropped") { weakService == nil }
    }

    /// Stopping twice must be harmless — `continuation.finish()` itself re-enters `stopObserving()`
    /// through the `onTermination` hook, so non-idempotence here would recurse.
    @Test func stopObservingIsIdempotent() async {
        let service = CloudKitPairingService(offlinePollInterval: .milliseconds(5))
        await service.startObserving()
        await service.stopObserving()
        await service.stopObserving()

        #expect(await service.isObserving == false)
    }
}

/// End-to-end coverage against the real `iCloud.io.dwk.anglesite` container. Opt-in via
/// `ANGLESITE_CK_TESTS=1`, mirroring `AnglesiteContainerLocalTests`' "real infrastructure,
/// explicitly requested" posture: this needs live network I/O, a signed-in iCloud account on the
/// running machine, and the `com.apple.developer.icloud-services` CloudKit entitlement on the
/// test host — none of which CI (or a sandboxed agent) has.
///
/// The gate is load-bearing for more than correctness: `CKContainer(identifier:)` traps with
/// SIGTRAP on an unentitled binary, so running these without the entitlement would crash the test
/// process rather than report failures. Do not ungate them to "see what happens".
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ANGLESITE_CK_TESTS"] == "1"))
struct CloudKitPairingServiceTests {
    /// CloudKit propagation is not instant, so every wait here is bounded — an unbounded
    /// `await iterator.next()` would hang the whole suite on a misconfigured container rather
    /// than failing. Mirrors the race-against-timeout shape used elsewhere in this target.
    static func firstAnnounce(
        from service: CloudKitPairingService,
        matching deviceID: String,
        timeout: Duration = .seconds(60)
    ) async -> DeviceAnnounceRecord? {
        await withTaskGroup(of: DeviceAnnounceRecord?.self) { group in
            group.addTask {
                for await announce in service.announcedDevices() where announce.deviceID == deviceID {
                    return announce
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Test func announceThenAnnouncedDevicesReceivesIt() async throws {
        let container = CKContainer(identifier: "iCloud.io.dwk.anglesite")
        let service = CloudKitPairingService(container: container, pollInterval: .seconds(2))
        let deviceID = "test-device-\(UUID().uuidString)"
        let waiter = Task { await Self.firstAnnounce(from: service, matching: deviceID) }

        try await service.announce(
            deviceID: deviceID, publicKeyData: Data([0x04, 0x01, 0x02]), displayName: "Test Device")

        let received = try #require(await waiter.value)
        #expect(received.deviceID == deviceID)
        #expect(received.publicKeyData == Data([0x04, 0x01, 0x02]))
        #expect(received.displayName == "Test Device")

        await service.stopObserving()
        try await service.withdrawAnnounce(deviceID: deviceID)
    }

    /// Re-announcing the same `deviceID` must overwrite, not accumulate — the record name is the
    /// device ID and the save policy is `.allKeys` precisely so a device rotating its display name
    /// or key doesn't leave a stale second row behind.
    @Test func reAnnouncingOverwritesRatherThanDuplicating() async throws {
        let container = CKContainer(identifier: "iCloud.io.dwk.anglesite")
        let service = CloudKitPairingService(container: container, pollInterval: .seconds(2))
        let deviceID = "test-device-\(UUID().uuidString)"

        try await service.announce(
            deviceID: deviceID, publicKeyData: Data([0x04, 0x01]), displayName: "First Name")
        try await service.announce(
            deviceID: deviceID, publicKeyData: Data([0x04, 0x02]), displayName: "Second Name")

        let received = try #require(await Self.firstAnnounce(from: service, matching: deviceID))
        #expect(received.displayName == "Second Name")

        await service.stopObserving()
        try await service.withdrawAnnounce(deviceID: deviceID)
    }

    /// `registerSubscription()` is safe to repeat, which every helper launch relies on. Per Apple's
    /// QA1917 a subscription saved under an explicit ID is idempotent server-side — no duplicate is
    /// created and the call normally succeeds — so this asserts the *second* call is not an error.
    /// The `serverRejectedRequest` catch in the implementation is defensive backup, not the
    /// expected path.
    @Test func registerSubscriptionIsIdempotent() async throws {
        let container = CKContainer(identifier: "iCloud.io.dwk.anglesite")
        let service = CloudKitPairingService(container: container)
        try await service.registerSubscription()
        try await service.registerSubscription()
    }
}
#endif

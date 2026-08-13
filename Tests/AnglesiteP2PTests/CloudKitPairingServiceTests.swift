import Testing
import Foundation
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

/// End-to-end coverage against the real `iCloud.io.dwk.anglesite` container. Opt-in via
/// `ANGLESITE_CK_TESTS=1`, mirroring `AnglesiteContainerLocalTests`' "real infrastructure,
/// explicitly requested" posture: this needs live network I/O, a signed-in iCloud account on the
/// running machine, and the `com.apple.developer.icloud-services` CloudKit entitlement on the
/// test host — none of which CI (or a sandboxed agent) has.
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

    /// `registerSubscription()` is idempotent: the second call hits CloudKit's duplicate-ID
    /// rejection and must swallow it, since every helper launch re-registers on startup.
    @Test func registerSubscriptionIsIdempotent() async throws {
        let container = CKContainer(identifier: "iCloud.io.dwk.anglesite")
        let service = CloudKitPairingService(container: container)
        try await service.registerSubscription()
        try await service.registerSubscription()
    }
}
#endif

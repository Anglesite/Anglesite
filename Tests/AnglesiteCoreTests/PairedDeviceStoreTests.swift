import Testing
import Foundation
@testable import AnglesiteCore

@Suite
struct PairedDeviceStoreTests {
    static func makeStore() -> PairedDeviceStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paired-devices-\(UUID().uuidString)")
        return PairedDeviceStore(persistenceURL: dir.appendingPathComponent("paired-devices.json"))
    }

    @Test func loadOnMissingFileReturnsEmpty() throws {
        #expect(try Self.makeStore().load() == [])
    }

    @Test func addThenLoadRoundTrips() throws {
        let store = Self.makeStore()
        let device = PairedDevice(deviceID: "phone-1", displayName: "David's iPhone", pinnedPublicKey: Data([0x04, 0x01]), pairedAt: Date(timeIntervalSince1970: 1000))
        try store.add(device)
        #expect(try store.load() == [device])
    }

    @Test func updateReplacesMatchingID() throws {
        let store = Self.makeStore()
        var device = PairedDevice(deviceID: "phone-1", displayName: "David's iPhone", pinnedPublicKey: Data([0x04]), pairedAt: Date(timeIntervalSince1970: 1000))
        try store.add(device)
        device.lastConnectedAt = Date(timeIntervalSince1970: 2000)
        try store.update(device)
        #expect(try store.load() == [device])
    }

    @Test func updateIsNoOpForUnknownID() throws {
        let store = Self.makeStore()
        try store.update(PairedDevice(deviceID: "ghost", displayName: "Ghost", pinnedPublicKey: Data(), pairedAt: Date()))
        #expect(try store.load() == [])
    }

    @Test func removeDeletesMatchingID() throws {
        let store = Self.makeStore()
        let device = PairedDevice(deviceID: "phone-1", displayName: "David's iPhone", pinnedPublicKey: Data([0x04]), pairedAt: Date())
        try store.add(device)
        try store.remove(id: device.id)
        #expect(try store.load() == [])
    }

    /// The revocation half of `remove(id:)` (#1208 P2): dropping the row is not enough, because the
    /// peer's `DeviceAnnounceRecord` outlives it in CloudKit and the helper's pairing loop would
    /// re-pin from that stale record on the next session. See `PairedDeviceStore.remove(id:)`.
    @Test func removeRecordsARevocationTombstone() throws {
        let store = Self.makeStore()
        let device = PairedDevice(deviceID: "phone-1", displayName: "David's iPhone", pinnedPublicKey: Data([0x04]), pairedAt: Date())
        try store.add(device)
        #expect(try store.revocationDate(deviceID: "phone-1") == nil)

        let before = Date()
        try store.remove(id: device.id)
        let recorded = try #require(try store.revocationDate(deviceID: "phone-1"))
        #expect(recorded >= before)
        // An announce written before the revoke is the stale record being defended against; one
        // written after it is a deliberate re-pairing. Both comparisons are the caller's, so this
        // asserts the tombstone actually supports them.
        #expect(before.addingTimeInterval(-60) <= recorded)
        #expect(recorded < Date().addingTimeInterval(60))
    }

    /// A removal that matches nothing must not tombstone anything — otherwise a stray `remove`
    /// could quietly block a device that was never revoked.
    @Test func removeOfUnknownIDRecordsNoTombstone() throws {
        let store = Self.makeStore()
        let device = PairedDevice(deviceID: "phone-1", displayName: "David's iPhone", pinnedPublicKey: Data([0x04]), pairedAt: Date())
        try store.add(device)
        try store.remove(id: UUID())
        #expect(try store.load() == [device])
        #expect(try store.revocationDate(deviceID: "phone-1") == nil)
    }

    /// Tombstones survive a fresh store instance — the whole point is that they outlive the process
    /// that wrote them, since the helper re-reads them on every launch.
    @Test func tombstonesPersistAcrossStoreInstances() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paired-devices-\(UUID().uuidString)")
            .appendingPathComponent("paired-devices.json")
        let device = PairedDevice(deviceID: "phone-1", displayName: "David's iPhone", pinnedPublicKey: Data([0x04]), pairedAt: Date())
        let writer = PairedDeviceStore(persistenceURL: url)
        try writer.add(device)
        try writer.remove(id: device.id)

        let reader = PairedDeviceStore(persistenceURL: url)
        #expect(try reader.revocationDate(deviceID: "phone-1") != nil)
        #expect(try reader.revocationDate(deviceID: "never-paired") == nil)
    }

    /// `remove(id:)` writes two files, and each write is atomic but the pair is not — so this pins
    /// the property that decides which way an interruption between them fails: **the tombstone is
    /// written first**, so a failure leaves the device still listed rather than silently un-revoked.
    ///
    /// The failure is injected by putting a *directory* where `revoked-devices.json` belongs, which
    /// makes the tombstone step throw while leaving `paired-devices.json` perfectly writable. That
    /// asymmetry is what makes this test discriminating: under the old row-first order,
    /// `paired-devices.json` would already have been rewritten without the device before the throw,
    /// and the assertion below would fail.
    ///
    /// The retry half matters just as much. Under the old order the row was already gone, so a
    /// second `remove(id:)` matched nothing and returned *successfully* without recording anything —
    /// the UI reported a revoke that never happened. Here the row survives, so the retry heals.
    @Test func aFailedTombstoneWriteLeavesTheDeviceListedAndRetryable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paired-devices-\(UUID().uuidString)")
        let store = PairedDeviceStore(persistenceURL: directory.appendingPathComponent("paired-devices.json"))
        let device = PairedDevice(deviceID: "phone-1", displayName: "David's iPhone", pinnedPublicKey: Data([0x04]), pairedAt: Date())
        try store.add(device)

        let blocker = directory.appendingPathComponent("revoked-devices.json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try store.remove(id: device.id) }
        #expect(try store.load() == [device],
                "the row must survive a failed tombstone write, or the revoke silently fails open")

        try FileManager.default.removeItem(at: blocker)
        try store.remove(id: device.id)
        #expect(try store.load() == [])
        #expect(try store.revocationDate(deviceID: "phone-1") != nil)
    }

    /// A store with no tombstone file at all reports no revocations rather than throwing — the
    /// state every Mac is in until the first revoke.
    @Test func revocationDateOnMissingFileReturnsNil() throws {
        #expect(try Self.makeStore().revocationDate(deviceID: "phone-1") == nil)
    }

    @Test func deviceLookupFindsByPeerDeviceIDNotStoreID() throws {
        let store = Self.makeStore()
        let device = PairedDevice(deviceID: "phone-1", displayName: "David's iPhone", pinnedPublicKey: Data([0x04]), pairedAt: Date())
        try store.add(device)
        #expect(try store.device(deviceID: "phone-1") == device)
        #expect(try store.device(deviceID: "unknown-device") == nil)
    }

    /// #1916: `PairedDeviceStore` migrated both `paired-devices.json` and `revoked-devices.json`
    /// onto `CodableFileStore`. Neither file's original hand-rolled encoder set a date strategy, so
    /// `Date` fields (`pairedAt`/`lastConnectedAt`, tombstone timestamps) were written with
    /// `JSONEncoder`'s default `.deferredToDate` — a raw numeric `timeIntervalSinceReferenceDate` —
    /// not `CodableFileStore.json`'s ISO 8601 default. A fixture written the old way must still
    /// decode, and re-saving it must reproduce the exact same bytes.
    @Test func byteCompatibleWithPreMigrationDevicesFormat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paired-devices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let persistenceURL = dir.appendingPathComponent("paired-devices.json")

        let devices = [
            PairedDevice(deviceID: "phone-1", displayName: "David's iPhone", pinnedPublicKey: Data([0x04, 0x01]), pairedAt: Date(timeIntervalSince1970: 1000), lastConnectedAt: Date(timeIntervalSince1970: 2000)),
        ]
        let legacyEncoder = JSONEncoder()
        legacyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fixture = try legacyEncoder.encode(devices)
        try fixture.write(to: persistenceURL)

        let store = PairedDeviceStore(persistenceURL: persistenceURL)
        #expect(try store.load() == devices)

        try store.update(devices[0])
        let resaved = try Data(contentsOf: persistenceURL)
        #expect(resaved == fixture)
    }

    /// Same guarantee as ``byteCompatibleWithPreMigrationDevicesFormat`` for the sibling
    /// `revoked-devices.json` tombstone file. `PairedDeviceStore.remove(id:)` always stamps a fresh
    /// `Date()` tombstone, so it can't be used to exercise a byte-identical re-save of a fixed
    /// fixture value — instead this constructs the `CodableFileStore` with the exact configuration
    /// `PairedDeviceStore` uses internally for `revoked-devices.json` (`.deferredToDate` on both
    /// sides, matching the original hand-rolled encoder/decoder's un-set date strategy) and drives
    /// it directly.
    @Test func byteCompatibleWithPreMigrationRevocationsFormat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paired-devices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let revocationsURL = dir.appendingPathComponent("revoked-devices.json")

        let tombstones = ["phone-1": Date(timeIntervalSince1970: 3000)]
        let legacyEncoder = JSONEncoder()
        legacyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fixture = try legacyEncoder.encode(tombstones)
        try fixture.write(to: revocationsURL)

        let store = CodableFileStore<[String: Date]>.json(
            fileURL: revocationsURL,
            dateEncodingStrategy: .deferredToDate,
            dateDecodingStrategy: .deferredToDate
        )
        let loaded = try store.load()
        #expect(loaded == tombstones)

        try store.save(try #require(loaded))
        let resaved = try Data(contentsOf: revocationsURL)
        #expect(resaved == fixture)
    }
}

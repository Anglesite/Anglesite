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

    @Test func deviceLookupFindsByPeerDeviceIDNotStoreID() throws {
        let store = Self.makeStore()
        let device = PairedDevice(deviceID: "phone-1", displayName: "David's iPhone", pinnedPublicKey: Data([0x04]), pairedAt: Date())
        try store.add(device)
        #expect(try store.device(deviceID: "phone-1") == device)
        #expect(try store.device(deviceID: "unknown-device") == nil)
    }
}

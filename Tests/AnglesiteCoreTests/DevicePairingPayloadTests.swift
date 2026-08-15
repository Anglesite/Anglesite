import Foundation
import Testing
@testable import AnglesiteCore

@Suite("DevicePairingPayload")
struct DevicePairingPayloadTests {
    @Test("encode → decode round-trips")
    func roundTrip() throws {
        let payload = DevicePairingPayload(
            deviceID: "mac-1234", publicKey: Data([0x04, 0xAB, 0xCD]))
        let json = try payload.encodedJSON()
        let decoded = try DevicePairingPayload.decode(from: String(decoding: json, as: UTF8.self))
        #expect(decoded == payload)
    }

    @Test("publicKey rides the wire as base64 under the documented field names")
    func wireFormat() throws {
        let key = Data([0x01, 0x02, 0x03])
        let json = try DevicePairingPayload(deviceID: "mac-1", publicKey: key).encodedJSON()
        let object = try #require(
            try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["deviceID"] as? String == "mac-1")
        #expect(object["publicKey"] as? String == key.base64EncodedString())
    }

    @Test("non-JSON scans are rejected", arguments: ["hello", "", "{\"a\":1}"])
    func rejectsGarbage(_ scanned: String) {
        #expect(throws: DevicePairingPayload.DecodeError.notAPairingCode) {
            try DevicePairingPayload.decode(from: scanned)
        }
    }

    @Test("empty identity fields are rejected")
    func rejectsEmptyFields() throws {
        let emptyID = try DevicePairingPayload(deviceID: "", publicKey: Data([1])).encodedJSON()
        #expect(throws: DevicePairingPayload.DecodeError.notAPairingCode) {
            try DevicePairingPayload.decode(from: String(decoding: emptyID, as: UTF8.self))
        }
        let emptyKey = try DevicePairingPayload(deviceID: "mac-1", publicKey: Data()).encodedJSON()
        #expect(throws: DevicePairingPayload.DecodeError.notAPairingCode) {
            try DevicePairingPayload.decode(from: String(decoding: emptyKey, as: UTF8.self))
        }
    }
}

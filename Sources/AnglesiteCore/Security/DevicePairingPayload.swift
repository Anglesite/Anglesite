import Foundation

/// The pairing QR code's wire shape, single-sourced so the Mac's encoder
/// (`DevicePairingSettingsView`) and the iOS scanner's decoder can never drift. Field names match
/// `DeviceAnnounceRecord`'s CloudKit fields (`deviceID`, `publicKey`); `publicKey` rides as
/// base64 via `JSONEncoder`/`JSONDecoder`'s default `Data` strategy, matching how
/// `DevicePairingKeyPair.publicKeyData` round-trips elsewhere in the pairing flow (e.g.
/// `SecretStore.writeDevicePairingKeyPair`).
public struct DevicePairingPayload: Codable, Sendable, Equatable {
    /// The announcing device's stable identifier — the peer pins it alongside the key.
    public let deviceID: String
    /// X9.63 uncompressed point, matching `DevicePairingKeyPair.publicKeyData`'s format.
    public let publicKey: Data

    public init(deviceID: String, publicKey: Data) {
        self.deviceID = deviceID
        self.publicKey = publicKey
    }

    /// Why a scanned string couldn't become a payload. One case on purpose: the owner scanned
    /// *something that isn't an Anglesite pairing code*, and which JSON rule it broke is not an
    /// owner-actionable distinction.
    public enum DecodeError: Error, Equatable {
        case notAPairingCode
    }

    /// The JSON the QR generator renders.
    public func encodedJSON() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Parses a scanned QR string, rejecting anything that isn't this shape — including a
    /// structurally valid payload with an empty `deviceID` or `publicKey`, which could never
    /// pin a real device.
    public static func decode(from string: String) throws -> DevicePairingPayload {
        guard let payload = try? JSONDecoder().decode(DevicePairingPayload.self, from: Data(string.utf8)),
              !payload.deviceID.isEmpty, !payload.publicKey.isEmpty
        else { throw DecodeError.notAPairingCode }
        return payload
    }
}

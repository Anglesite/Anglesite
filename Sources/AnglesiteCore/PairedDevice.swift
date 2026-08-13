import Foundation

/// A paired Anywhere-runtime device (design spec §Pairing and security) — persisted, non-secret
/// metadata plus the device's pinned public key. Not a secret itself (integrity, not
/// confidentiality, is what a pinned key protects), so it lives in the plain JSON record, not
/// Keychain — matching the design spec's framing ("The QR is the trust root; iCloud is just a
/// mailbox").
public struct PairedDevice: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    /// The peer's own stable device identifier (opaque string from the QR/announce payload —
    /// not this app's `id`, which is generated locally at pairing time).
    public var deviceID: String
    public var displayName: String
    /// X9.63 uncompressed point, matching `DevicePairingKeyPair.publicKeyData`'s format.
    public var pinnedPublicKey: Data
    public var pairedAt: Date
    public var lastConnectedAt: Date?

    public init(id: UUID = UUID(), deviceID: String, displayName: String, pinnedPublicKey: Data, pairedAt: Date, lastConnectedAt: Date? = nil) {
        self.id = id
        self.deviceID = deviceID
        self.displayName = displayName
        self.pinnedPublicKey = pinnedPublicKey
        self.pairedAt = pairedAt
        self.lastConnectedAt = lastConnectedAt
    }
}

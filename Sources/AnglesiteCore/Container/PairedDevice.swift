import Foundation

/// A paired Anywhere-runtime device (design spec §Pairing and security) — persisted, non-secret
/// metadata plus the device's pinned public key. Not a secret itself (integrity, not
/// confidentiality, is what a pinned key protects), so it lives in the plain JSON record, not
/// Keychain — matching the design spec's framing ("The QR is the trust root; iCloud is just a
/// mailbox").
public struct PairedDevice: Codable, Identifiable, Sendable, Equatable {
    /// Stable identity for this paired device, locally generated at pairing time and persisted
    /// across the lifetime of the pairing. Distinct from the peer's own `deviceID`.
    public let id: UUID
    /// The peer's own stable device identifier (opaque string from the QR/announce payload —
    /// not this app's `id`, which is generated locally at pairing time).
    public var deviceID: String
    /// Owner-chosen display name for this paired device (e.g. "David's iPhone"). User-facing,
    /// used to distinguish devices in the UI.
    public var displayName: String
    /// X9.63 uncompressed point, matching `DevicePairingKeyPair.publicKeyData`'s format.
    public var pinnedPublicKey: Data
    /// Timestamp when this device was initially paired with this app.
    public var pairedAt: Date
    /// Most recent time this paired device connected via a P2P channel, or `nil` if never
    /// connected. Updated on successful signaling channel completion.
    public var lastConnectedAt: Date?

    /// Memberwise init. Callers should generate a fresh `UUID` for `id` when pairing a new
    /// device; `lastConnectedAt` defaults to `nil`.
    public init(id: UUID = UUID(), deviceID: String, displayName: String, pinnedPublicKey: Data, pairedAt: Date, lastConnectedAt: Date? = nil) {
        self.id = id
        self.deviceID = deviceID
        self.displayName = displayName
        self.pinnedPublicKey = pinnedPublicKey
        self.pairedAt = pairedAt
        self.lastConnectedAt = lastConnectedAt
    }
}

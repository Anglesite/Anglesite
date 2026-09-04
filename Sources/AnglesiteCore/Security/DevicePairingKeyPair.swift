import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A device's own signing key pair for Anywhere-runtime pairing (design spec
/// §Architecture 2) — generated once per device, Keychain-persisted, and used to sign every
/// P2P signaling payload once paired. Mirrors `DPoPKeyPair`'s CryptoKit/persistence shape but
/// exposes raw signing instead of DPoP-JWT construction: pairing has no HTTP request to bind a
/// proof to, just a payload to sign.
public struct DevicePairingKeyPair: Sendable {
    #if canImport(CryptoKit)
    private let privateKey: P256.Signing.PrivateKey
    #endif

    /// Generates a fresh P-256 key pair.
    public init() {
        #if canImport(CryptoKit)
        self.privateKey = P256.Signing.PrivateKey()
        #endif
    }

    /// Reconstructs a previously persisted key pair from its raw 32-byte private scalar. `nil`
    /// if `data` isn't a valid P-256 private key.
    public init?(persistedRepresentation data: Data) {
        #if canImport(CryptoKit)
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: data) else { return nil }
        self.privateKey = key
        #else
        return nil
        #endif
    }

    /// The raw private-key bytes to persist via `SecretStore`.
    public var persistedRepresentation: Data {
        #if canImport(CryptoKit)
        privateKey.rawRepresentation
        #else
        Data()
        #endif
    }

    /// The public key as an X9.63 uncompressed point (0x04 + 32-byte X + 32-byte Y) — the format
    /// both the QR payload and CloudKit's `DeviceAnnounceRecord.publicKey` use.
    public var publicKeyData: Data {
        #if canImport(CryptoKit)
        privateKey.publicKey.x963Representation
        #else
        Data()
        #endif
    }

    /// Signs `payload` with this device's private key.
    public func sign(_ payload: Data) throws -> Data {
        #if canImport(CryptoKit)
        try privateKey.signature(for: payload).rawRepresentation
        #else
        throw DevicePairingKeyPairError.unavailable
        #endif
    }

    /// Verifies `signature` over `payload` against a peer's public key (X9.63 format, as
    /// produced by `publicKeyData`). Returns `false` (never throws) for a malformed key or a
    /// genuine verification failure — callers branch on a single boolean, matching
    /// `SignedSignalingChannel`'s "drop, don't throw" posture for untrusted network input.
    public static func verify(signature: Data, for payload: Data, publicKeyData: Data) -> Bool {
        #if canImport(CryptoKit)
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData),
              let ecdsaSignature = try? P256.Signing.ECDSASignature(rawRepresentation: signature)
        else { return false }
        return publicKey.isValidSignature(ecdsaSignature, for: payload)
        #else
        return false
        #endif
    }
}

/// Why a `DevicePairingKeyPair` operation couldn't run — mirrors `DPoPError.unavailable`'s
/// posture (CryptoKit is Apple-platforms-only; there is no pairing UI on a platform without it).
public enum DevicePairingKeyPairError: Error, Sendable {
    /// CryptoKit isn't available on this platform (matches `DPoPError.unavailable`'s posture).
    case unavailable
}

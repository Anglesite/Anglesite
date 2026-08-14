import Testing
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import AnglesiteCore

@Suite
struct DevicePairingKeyPairTests {
    @Test("persistedRepresentation round-trips through init?(persistedRepresentation:)")
    func persistenceRoundTrips() throws {
        let original = DevicePairingKeyPair()
        let restored = DevicePairingKeyPair(persistedRepresentation: original.persistedRepresentation)
        #expect(restored != nil)
        #expect(restored?.persistedRepresentation == original.persistedRepresentation)
    }

    @Test("init?(persistedRepresentation:) rejects malformed bytes")
    func rejectsMalformedBytes() {
        #expect(DevicePairingKeyPair(persistedRepresentation: Data([0x01, 0x02, 0x03])) == nil)
    }

    #if canImport(CryptoKit)
    @Test("publicKeyData is a 65-byte X9.63 uncompressed point starting with 0x04")
    func publicKeyDataShape() {
        let keyPair = DevicePairingKeyPair()
        #expect(keyPair.publicKeyData.count == 65)
        #expect(keyPair.publicKeyData.first == 0x04)
    }

    @Test("a signature verifies against the signer's own public key")
    func signatureVerifiesAgainstOwnKey() throws {
        let keyPair = DevicePairingKeyPair()
        let payload = Data("offer-sdp-text".utf8)
        let signature = try keyPair.sign(payload)
        #expect(DevicePairingKeyPair.verify(signature: signature, for: payload, publicKeyData: keyPair.publicKeyData))
    }

    @Test("a signature does not verify against a different key pair's public key")
    func signatureRejectsWrongKey() throws {
        let signer = DevicePairingKeyPair()
        let other = DevicePairingKeyPair()
        let payload = Data("offer-sdp-text".utf8)
        let signature = try signer.sign(payload)
        #expect(!DevicePairingKeyPair.verify(signature: signature, for: payload, publicKeyData: other.publicKeyData))
    }

    @Test("a signature does not verify against tampered payload bytes")
    func signatureRejectsTamperedPayload() throws {
        let keyPair = DevicePairingKeyPair()
        let signature = try keyPair.sign(Data("original".utf8))
        #expect(!DevicePairingKeyPair.verify(signature: signature, for: Data("tampered".utf8), publicKeyData: keyPair.publicKeyData))
    }

    @Test("verify returns false (not a crash) for malformed public key data")
    func verifyRejectsMalformedPublicKey() throws {
        let keyPair = DevicePairingKeyPair()
        let signature = try keyPair.sign(Data("payload".utf8))
        #expect(!DevicePairingKeyPair.verify(signature: signature, for: Data("payload".utf8), publicKeyData: Data([0x01, 0x02])))
    }
    #endif
}

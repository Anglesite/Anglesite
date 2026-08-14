import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteP2P

@Suite
struct SignedSignalingChannelTests {
    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("signed-signaling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func signedEnvelopeRoundTripsAndVerifies() async throws {
        let dir = try Self.makeTempDir()
        let alice = DevicePairingKeyPair()
        let bob = DevicePairingKeyPair()
        let aliceChannel = SignedSignalingChannel(
            wrapping: FileSignalingChannel(directory: dir, sender: "alice"),
            signingKey: alice, peerPublicKey: bob.publicKeyData)
        let bobChannel = SignedSignalingChannel(
            wrapping: FileSignalingChannel(directory: dir, sender: "bob"),
            signingKey: bob, peerPublicKey: alice.publicKeyData)

        try await aliceChannel.send(SignalingEnvelope(seq: 1, sender: "alice", kind: .offer, payload: "sdp-offer-text"))

        var iterator = bobChannel.envelopes().makeAsyncIterator()
        let received = try #require(await iterator.next())
        #expect(received.payload == "sdp-offer-text")
        #expect(received.kind == .offer)

        await aliceChannel.close()
        await bobChannel.close()
    }

    /// A minimal `SignalingChannel` fake that hands back exactly the envelopes it's told to,
    /// letting adversarial tests inject a raw (unsigned or tampered) envelope directly — something
    /// `FileSignalingChannel` can't do, since it only ever delivers what a `SignedSignalingChannel`
    /// itself wrote.
    ///
    /// Stream/continuation are `let`s fixed at `init` (mirroring `FileSignalingChannel`'s own
    /// shape) rather than lazily created inside `envelopes()`: under Swift 6 strict concurrency, a
    /// `SignalingChannel` conformer's `envelopes()` requirement must be `nonisolated` to satisfy
    /// the (non-`async`) protocol requirement without crossing actor isolation, and `nonisolated`
    /// access is only sound over an immutable, already-initialized `let`.
    actor ScriptedChannel: SignalingChannel {
        private let stream: AsyncStream<SignalingEnvelope>
        private let continuation: AsyncStream<SignalingEnvelope>.Continuation
        private(set) var sent: [SignalingEnvelope] = []

        init() {
            (stream, continuation) = AsyncStream<SignalingEnvelope>.makeStream(bufferingPolicy: .unbounded)
        }

        func send(_ envelope: SignalingEnvelope) async throws { sent.append(envelope) }
        nonisolated func envelopes() -> AsyncStream<SignalingEnvelope> { stream }
        func close() async { continuation.finish() }
        func inject(_ envelope: SignalingEnvelope) { continuation.yield(envelope) }
    }

    @Test func tamperedPayloadIsDroppedNotDelivered() async throws {
        let alice = DevicePairingKeyPair()
        let bob = DevicePairingKeyPair()
        let inner = ScriptedChannel()
        var loggedReasons: [String] = []
        let bobChannel = SignedSignalingChannel(
            wrapping: inner, signingKey: bob, peerPublicKey: alice.publicKeyData,
            onLog: { reason in loggedReasons.append(reason) })

        // A legitimately-signed envelope from alice's key, over a DIFFERENT payload than what's
        // actually being delivered — simulates a tampered-in-transit SDP.
        let signature = try alice.sign(Data("original-sdp".utf8))
        let wrapped = try JSONSerialization.data(withJSONObject: [
            "payload": "tampered-sdp", "signature": signature.base64EncodedString(),
        ])
        await inner.inject(SignalingEnvelope(seq: 1, sender: "alice", kind: .offer, payload: String(decoding: wrapped, as: UTF8.self)))

        var iterator = bobChannel.envelopes().makeAsyncIterator()
        let raceResult = await withTaskGroup(of: SignalingEnvelope?.self) { group in
            group.addTask { await iterator.next() }
            group.addTask { try? await Task.sleep(for: .milliseconds(300)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(raceResult == nil, "a tampered envelope must never be delivered")
        #expect(!loggedReasons.isEmpty)
    }

    @Test func envelopeFromUnpinnedKeyIsDroppedNotDelivered() async throws {
        let bob = DevicePairingKeyPair()
        let attacker = DevicePairingKeyPair()
        let pinnedButNotAttacker = DevicePairingKeyPair()
        let inner = ScriptedChannel()
        let bobChannel = SignedSignalingChannel(wrapping: inner, signingKey: bob, peerPublicKey: pinnedButNotAttacker.publicKeyData)

        let signature = try attacker.sign(Data("sdp-offer-text".utf8))
        let wrapped = try JSONSerialization.data(withJSONObject: [
            "payload": "sdp-offer-text", "signature": signature.base64EncodedString(),
        ])
        await inner.inject(SignalingEnvelope(seq: 1, sender: "attacker", kind: .offer, payload: String(decoding: wrapped, as: UTF8.self)))

        var iterator = bobChannel.envelopes().makeAsyncIterator()
        let raceResult = await withTaskGroup(of: SignalingEnvelope?.self) { group in
            group.addTask { await iterator.next() }
            group.addTask { try? await Task.sleep(for: .milliseconds(300)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(raceResult == nil, "an envelope signed by an unpinned key must never be delivered")
    }

    @Test func malformedWrapperJSONIsDroppedNotDelivered() async throws {
        let bob = DevicePairingKeyPair()
        let alice = DevicePairingKeyPair()
        let inner = ScriptedChannel()
        let bobChannel = SignedSignalingChannel(wrapping: inner, signingKey: bob, peerPublicKey: alice.publicKeyData)

        await inner.inject(SignalingEnvelope(seq: 1, sender: "alice", kind: .offer, payload: "not-json-at-all"))

        var iterator = bobChannel.envelopes().makeAsyncIterator()
        let raceResult = await withTaskGroup(of: SignalingEnvelope?.self) { group in
            group.addTask { await iterator.next() }
            group.addTask { try? await Task.sleep(for: .milliseconds(300)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(raceResult == nil)
    }

    @Test func closeFinishesTheEnvelopesStream() async throws {
        let dir = try Self.makeTempDir()
        let alice = DevicePairingKeyPair()
        let channel = SignedSignalingChannel(
            wrapping: FileSignalingChannel(directory: dir, sender: "alice"),
            signingKey: alice, peerPublicKey: alice.publicKeyData)
        var iterator = channel.envelopes().makeAsyncIterator()
        await channel.close()
        let result = await iterator.next()
        #expect(result == nil)
    }
}

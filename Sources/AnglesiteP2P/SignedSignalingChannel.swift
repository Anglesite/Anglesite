import Foundation
import AnglesiteCore

/// Wraps any `SignalingChannel` with sign-on-send / verify-on-receive against a pinned peer
/// public key (design spec §Architecture 4). Wraps only `SignalingEnvelope.payload` — `seq`/
/// `sender`/`kind` stay in the clear so the inner channel's own delivery/ordering logic (e.g.
/// `FileSignalingChannel`'s per-sender seq buffering) keeps working unmodified underneath.
///
/// A bad or missing signature drops that envelope from the stream entirely — it is never yielded
/// to a caller (`WebRTCPeer`) — logged loudly, not thrown, matching the design spec's "the caller
/// just sees the same stall a network partition would produce" posture (no distinct attack UX).
///
/// This type has no CloudKit dependency and is fully testable against `FileSignalingChannel` or
/// a fake `SignalingChannel` — this is where the adversarial pairing tests (tampered SDP, wrong
/// key) live, deliberately independent of whether real CloudKit entitlements are provisioned.
///
/// `envelopes()` mirrors `FileSignalingChannel`'s shape (own `stream`/`continuation` created once
/// at `init`, `envelopes()` itself `nonisolated` and returning the fixed `stream`): under Swift 6
/// strict concurrency, a `SignalingChannel` conformer's `envelopes()` requirement is non-`async`,
/// so an actor-isolated implementation would cross actor isolation to satisfy it. The verifying
/// forwarding loop instead runs in a `Task` started once at `init` (not lazily inside
/// `envelopes()`, since the protocol's "call once per channel" contract means there is only ever
/// one consumer to forward to).
public actor SignedSignalingChannel: SignalingChannel {
    /// The transport being wrapped — `FileSignalingChannel` in tests, `CloudKitSignalingChannel`
    /// in production.
    private let inner: any SignalingChannel
    /// This device's own key pair, used to sign outbound envelopes.
    private let signingKey: DevicePairingKeyPair
    /// The pinned public key (X9.63 format) inbound envelopes must verify against.
    private let peerPublicKey: Data
    /// Fires once per dropped (unverifiable) envelope, with a human-readable reason.
    private let onLog: @Sendable (String) -> Void

    /// This channel's own outbound stream of verified envelopes, vended by `envelopes()`.
    private let stream: AsyncStream<SignalingEnvelope>
    /// Paired with `stream`; fed by `forwardingTask`, which verifies each of `inner`'s envelopes
    /// before yielding it here.
    private let continuation: AsyncStream<SignalingEnvelope>.Continuation
    /// Consumes `inner.envelopes()`, verifies each envelope, and forwards the survivors into
    /// `continuation`. Started once at `init`; cancelled (idempotently) in `close()`.
    private var forwardingTask: Task<Void, Never>?

    /// - Parameters:
    ///   - inner: The transport to wrap — `FileSignalingChannel` in tests, `CloudKitSignalingChannel`
    ///     in production.
    ///   - signingKey: This device's own key pair, used to sign outbound envelopes.
    ///   - peerPublicKey: The pinned public key (X9.63 format) inbound envelopes must verify
    ///     against. Callers resolve this from `PairedDeviceStore` *before* constructing this
    ///     channel — an unpaired/unknown device never reaches this type at all (design spec
    ///     §Error handling: "refused at channel-construction time").
    ///   - onLog: Fires once per dropped (unverifiable) envelope, with a human-readable reason.
    ///     Callers route this to their own log sink — "logs are sacred" applies to a dropped
    ///     envelope exactly as it does to any other failure in this codebase.
    public init(
        wrapping inner: any SignalingChannel,
        signingKey: DevicePairingKeyPair,
        peerPublicKey: Data,
        onLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.inner = inner
        self.signingKey = signingKey
        self.peerPublicKey = peerPublicKey
        self.onLog = onLog
        (self.stream, self.continuation) = AsyncStream<SignalingEnvelope>.makeStream(bufferingPolicy: .unbounded)
        let continuation = self.continuation
        self.forwardingTask = Task {
            for await envelope in inner.envelopes() {
                guard let verified = Self.verify(envelope, against: peerPublicKey) else {
                    onLog("dropped unverifiable envelope from \(envelope.sender) (seq \(envelope.seq))")
                    continue
                }
                continuation.yield(verified)
            }
            continuation.finish()
        }
    }

    /// Signs `envelope.payload` with `signingKey` and forwards a copy carrying the wrapped
    /// `{payload, signature}` JSON in place of the original payload; `seq`/`sender`/`kind` are
    /// forwarded unchanged.
    public func send(_ envelope: SignalingEnvelope) async throws {
        let signature = try signingKey.sign(Data(envelope.payload.utf8))
        let wrapped: [String: String] = [
            "payload": envelope.payload,
            "signature": signature.base64EncodedString(),
        ]
        let wrappedData = try JSONSerialization.data(withJSONObject: wrapped)
        var signedEnvelope = envelope
        signedEnvelope.payload = String(decoding: wrappedData, as: UTF8.self)
        try await inner.send(signedEnvelope)
    }

    /// Verified, unwrapped envelopes forwarded from `inner` by `forwardingTask`. `nonisolated`
    /// (the stream is a `let` fixed at construction) so a caller can start consuming without an
    /// actor hop — see the type doc comment for why this shape is required.
    public nonisolated func envelopes() -> AsyncStream<SignalingEnvelope> { stream }

    /// Closes `inner`, which finishes `inner.envelopes()`'s stream and lets `forwardingTask`'s
    /// loop end naturally (finishing this channel's own stream in turn); then cancels
    /// `forwardingTask` itself, a no-op once the loop has already ended but a safety net if
    /// `inner.close()` doesn't promptly finish its stream. Idempotent.
    public func close() async {
        await inner.close()
        forwardingTask?.cancel()
        forwardingTask = nil
    }

    /// Verifies and unwraps one inbound envelope. `nil` for anything that doesn't parse as the
    /// wrapper JSON, doesn't carry a valid signature, or doesn't verify against `peerPublicKey`.
    /// `static` (not an instance method) so it can run inside `forwardingTask`'s closure without
    /// crossing back onto the actor for every envelope.
    private static func verify(_ envelope: SignalingEnvelope, against peerPublicKey: Data) -> SignalingEnvelope? {
        guard let wrappedData = envelope.payload.data(using: .utf8),
              let wrapped = try? JSONSerialization.jsonObject(with: wrappedData) as? [String: String],
              let originalPayload = wrapped["payload"],
              let signatureBase64 = wrapped["signature"],
              let signature = Data(base64Encoded: signatureBase64)
        else { return nil }
        guard DevicePairingKeyPair.verify(signature: signature, for: Data(originalPayload.utf8), publicKeyData: peerPublicKey)
        else { return nil }
        var verifiedEnvelope = envelope
        verifiedEnvelope.payload = originalPayload
        return verifiedEnvelope
    }
}

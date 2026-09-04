import Testing
import Foundation
import AnglesiteTestSupport
#if canImport(CloudKit)
import CloudKit
@testable import AnglesiteP2P

/// Offline coverage of the `CKRecord` ↔ `SignalingEnvelopeRecord` mapping, mirroring
/// `DeviceAnnounceRecordMappingTests`' split: a `CKRecord` is a plain in-memory object until
/// something saves it, so this half of `CloudKitSignalingChannel` needs neither a signed-in
/// iCloud account nor the CloudKit entitlement, which is why it is *not* gated behind
/// `ANGLESITE_CK_TESTS` — it is the part CI can actually run.
@Suite
struct SignalingEnvelopeRecordMappingTests {
    @Test func recordRoundTripsThroughCloudKitRepresentation() throws {
        let original = SignalingEnvelopeRecord(
            sessionID: "session-abc", seq: 3, sender: "host", kind: .candidate, payload: "ice-candidate-json")

        let record = original.makeCloudKitRecord()
        let decoded = try #require(SignalingEnvelopeRecord(record: record))

        #expect(decoded == original)
    }

    /// The record name is derived from `sessionID`/`sender`/`seq` so a delivered envelope's
    /// `CKRecord` can be deleted by reconstructing its ID, without having to keep the fetched
    /// `CKRecord.ID` around just for that.
    @Test func recordNameEncodesSessionSenderAndSeq() {
        let record = SignalingEnvelopeRecord(
            sessionID: "session-abc", seq: 3, sender: "host", kind: .offer, payload: "sdp"
        ).makeCloudKitRecord()

        #expect(record.recordID.recordName == "session-abc-host-3")
        #expect(record.recordType == SignalingEnvelopeRecord.cloudKitRecordType)
    }

    /// A peer (or a stale schema) can put anything in the owner's private database, so decoding is
    /// "drop, don't throw" — matching `DeviceAnnounceRecord` and `SignedSignalingChannel`'s posture
    /// for untrusted input.
    @Test func decodingRejectsRecordsMissingRequiredFields() {
        let record = CKRecord(
            recordType: SignalingEnvelopeRecord.cloudKitRecordType,
            recordID: CKRecord.ID(recordName: "session-abc-host-1"))
        record["sessionID"] = "session-abc" as CKRecordValue
        record["seq"] = 1 as CKRecordValue
        // No sender / kind / payload.

        #expect(SignalingEnvelopeRecord(record: record) == nil)
    }

    @Test func decodingRejectsAWrongRecordType() {
        let record = CKRecord(recordType: "SomethingElse", recordID: CKRecord.ID(recordName: "x"))
        record["sessionID"] = "session-abc" as CKRecordValue
        record["seq"] = 1 as CKRecordValue
        record["sender"] = "host" as CKRecordValue
        record["kind"] = "offer" as CKRecordValue
        record["payload"] = "sdp" as CKRecordValue

        #expect(SignalingEnvelopeRecord(record: record) == nil)
    }

    @Test func decodingRejectsAnUnknownKind() {
        let record = CKRecord(
            recordType: SignalingEnvelopeRecord.cloudKitRecordType,
            recordID: CKRecord.ID(recordName: "session-abc-host-1"))
        record["sessionID"] = "session-abc" as CKRecordValue
        record["seq"] = 1 as CKRecordValue
        record["sender"] = "host" as CKRecordValue
        record["kind"] = "not-a-real-kind" as CKRecordValue
        record["payload"] = "sdp" as CKRecordValue

        #expect(SignalingEnvelopeRecord(record: record) == nil)
    }

    /// Every `SignalingEnvelope.Kind` case must survive the round trip, since `.bye` (empty
    /// payload) and `.candidate` (JSON payload) exercise different payload shapes.
    @Test func everyEnvelopeKindRoundTrips() throws {
        for kind: SignalingEnvelope.Kind in [.offer, .answer, .candidate, .bye] {
            let record = SignalingEnvelopeRecord(
                sessionID: "session-abc", seq: 1, sender: "host", kind: kind, payload: "x"
            ).makeCloudKitRecord()
            let decoded = try #require(SignalingEnvelopeRecord(record: record))
            #expect(decoded.kind == kind)
        }
    }

    @Test func envelopeConversionRoundTrips() {
        let envelope = SignalingEnvelope(seq: 5, sender: "client", kind: .answer, payload: "answer-sdp")
        let record = SignalingEnvelopeRecord(envelope: envelope, sessionID: "session-xyz")

        #expect(record.sessionID == "session-xyz")
        #expect(record.envelope == envelope)
    }
}

/// Offline coverage of the parts of `CloudKitSignalingChannel`'s actor lifecycle that don't
/// require a real CloudKit database — mirroring `CloudKitPairingService`'s offline seam (see that
/// type's `init(offlinePollInterval:)` doc comment for why `CKContainer(identifier:)` cannot be
/// constructed here even just to leave it unused: it traps the process with SIGTRAP on a binary
/// lacking the CloudKit entitlement, which this sandbox has not provisioned).
@Suite
struct CloudKitSignalingChannelOfflineTests {
    @Test func sendThrowsWhenBuiltWithoutADatabase() async {
        let channel = CloudKitSignalingChannel(
            offlinePollInterval: .milliseconds(5), sessionID: "session-abc", sender: "host")
        await #expect(throws: Error.self) {
            try await channel.send(SignalingEnvelope(seq: 1, sender: "host", kind: .offer, payload: "sdp"))
        }
    }

    @Test func closeFinishesTheEnvelopesStreamOffline() async {
        let channel = CloudKitSignalingChannel(
            offlinePollInterval: .milliseconds(5), sessionID: "session-abc", sender: "host")
        var iterator = channel.envelopes().makeAsyncIterator()
        await channel.close()
        let result = await iterator.next()
        #expect(result == nil)
    }

    /// Sending after `close()` must fail with the specific `.closed` error, distinctly from
    /// `sendThrowsWhenBuiltWithoutADatabase`'s `CloudKitUnavailable` — a closed channel must not
    /// go on writing records nobody will ever read. Asserting the concrete error (rather than just
    /// `Error.self`) is load-bearing here: `send`'s two guards must fire in "closed, then
    /// database" order, or a post-close send on an offline-seam channel throws
    /// `CloudKitUnavailable` instead, and this test would pass vacuously either way.
    @Test func sendAfterCloseThrows() async throws {
        let channel = CloudKitSignalingChannel(
            offlinePollInterval: .milliseconds(5), sessionID: "session-abc", sender: "host")
        await channel.close()
        await #expect(throws: CloudKitSignalingChannelError.closed) {
            try await channel.send(SignalingEnvelope(seq: 1, sender: "host", kind: .offer, payload: "sdp"))
        }
    }

    /// `envelopes()` starts the poll loop lazily on first call, and `close()` must actually halt
    /// it rather than merely detach the handle — mirroring
    /// `CloudKitPairingServiceLifecycleTests.stopObservingHaltsThePollLoop`'s use of `isObserving`
    /// as the only way to assert "no leaked poll loop" from outside.
    @Test func envelopesStartsObservationAndCloseStopsIt() async throws {
        let channel = CloudKitSignalingChannel(
            offlinePollInterval: .milliseconds(5), sessionID: "session-abc", sender: "host")
        _ = channel.envelopes()
        try await waitUntil("observation to start") { await channel.isObserving == true }

        await channel.close()
        try await waitUntil("close to stop the poll loop") { await channel.isObserving == false }
    }

    /// A consumer that is cancelled (or breaks out of `for await`) terminates the stream without
    /// ever calling `close()`. Without the `onTermination` hook installed in the private
    /// designated init, the poll loop would go on hitting CloudKit for the life of the process,
    /// yielding into a continuation nobody reads — and, worse than in `CloudKitPairingService`,
    /// silently deleting the peer's undelivered SDP/ICE records into that unread buffer. Mirrors
    /// `CloudKitPairingServiceLifecycleTests.consumerCancellationStopsThePollLoop`.
    @Test func consumerCancellationStopsThePollLoop() async throws {
        let channel = CloudKitSignalingChannel(
            offlinePollInterval: .milliseconds(5), sessionID: "session-abc", sender: "host")
        let consumer = Task { for await _ in channel.envelopes() {} }
        try await waitUntil("observation to start") { await channel.isObserving == true }

        consumer.cancel()
        // `onTermination` hops back onto the actor; wait for that hop to land instead of
        // guessing how long it takes under load.
        try await waitUntil("cancellation to stop the poll loop") { await channel.isObserving == false }
    }

    /// The retain cycle the `onTermination` hook and `startObserving()`'s `[weak self]` capture
    /// together prevent: the actor owns `pollTask`, so if that task captured the actor strongly,
    /// the pair would keep each other alive for the life of the process unless someone remembered
    /// to call `close()` by hand. Dropping the last external reference without closing must still
    /// let the channel deallocate. Mirrors
    /// `CloudKitPairingServiceLifecycleTests.droppingTheServiceWithoutStoppingDeallocatesIt`.
    @Test func droppingTheChannelWithoutClosingDeallocatesIt() async throws {
        weak var weakChannel: CloudKitSignalingChannel?
        do {
            let channel = CloudKitSignalingChannel(
                offlinePollInterval: .milliseconds(5), sessionID: "session-abc", sender: "host")
            weakChannel = channel
            _ = channel.envelopes()
            try await waitUntil("observation to start") { await channel.isObserving == true }
        }

        try await waitUntil("the channel to deallocate once dropped") { weakChannel == nil }
    }
}

/// End-to-end coverage against the real `iCloud.io.dwk.anglesite` container, mirroring
/// `CloudKitPairingServiceTests`' "real infrastructure, explicitly requested" posture and
/// `FileSignalingChannelTests`' three delivery-semantics cases (never-echoes-own,
/// out-of-order-delivered-in-order, close-finishes-stream) — just run against two real
/// `CloudKitSignalingChannel`s sharing a `sessionID` instead of two `FileSignalingChannel`s
/// sharing a directory.
///
/// Opt-in via `ANGLESITE_CK_TESTS=1`: this needs live network I/O, a signed-in iCloud account, and
/// the CloudKit entitlement on the test host — none of which CI (or a sandboxed agent) has. The
/// gate is load-bearing for more than correctness: `CKContainer(identifier:)` traps with SIGTRAP
/// on an unentitled binary, so running these without the entitlement would crash the test process
/// rather than report failures. Do not ungate them to "see what happens".
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ANGLESITE_CK_TESTS"] == "1"))
struct CloudKitSignalingChannelTests {
    @Test func deliversOtherSendersEnvelopesButNeverEchoesOwn() async throws {
        let container = CKContainer(identifier: "iCloud.io.dwk.anglesite")
        let sessionID = "test-session-\(UUID().uuidString)"
        let host = CloudKitSignalingChannel(
            container: container, sessionID: sessionID, sender: "host", pollInterval: .seconds(2))
        let client = CloudKitSignalingChannel(
            container: container, sessionID: sessionID, sender: "client", pollInterval: .seconds(2))

        try await host.send(SignalingEnvelope(seq: 1, sender: "host", kind: .offer, payload: "offer-sdp"))

        var clientIterator = client.envelopes().makeAsyncIterator()
        let received = try #require(await clientIterator.next())
        #expect(received.payload == "offer-sdp")

        // host must never see its own write on its own stream.
        var hostIterator = host.envelopes().makeAsyncIterator()
        let neverArrives = await withTaskGroup(of: SignalingEnvelope?.self) { group in
            group.addTask { await hostIterator.next() }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(neverArrives == nil)

        await host.close()
        await client.close()
    }

    /// Envelopes from one sender must be delivered to the other in ascending `seq` order even when
    /// a later `seq` is saved to CloudKit first — mirroring
    /// `FileSignalingChannelTests.deliversOutOfOrderWritesInAscendingSeqOrder`.
    @Test func deliversOutOfOrderWritesInAscendingSeqOrder() async throws {
        let container = CKContainer(identifier: "iCloud.io.dwk.anglesite")
        let sessionID = "test-session-\(UUID().uuidString)"
        let host = CloudKitSignalingChannel(
            container: container, sessionID: sessionID, sender: "host", pollInterval: .seconds(2))
        let client = CloudKitSignalingChannel(
            container: container, sessionID: sessionID, sender: "client", pollInterval: .seconds(2))

        var clientIterator = client.envelopes().makeAsyncIterator()

        try await host.send(SignalingEnvelope(seq: 2, sender: "host", kind: .candidate, payload: "two"))
        try await Task.sleep(for: .seconds(3))
        try await host.send(SignalingEnvelope(seq: 1, sender: "host", kind: .offer, payload: "one"))

        let first = try #require(await clientIterator.next())
        let second = try #require(await clientIterator.next())
        #expect(first.payload == "one")
        #expect(second.payload == "two")

        await host.close()
        await client.close()
    }

    @Test func closeFinishesTheEnvelopesStream() async throws {
        let container = CKContainer(identifier: "iCloud.io.dwk.anglesite")
        let channel = CloudKitSignalingChannel(
            container: container, sessionID: "test-session-\(UUID().uuidString)", sender: "host")
        var iterator = channel.envelopes().makeAsyncIterator()
        await channel.close()
        let result = await iterator.next()
        #expect(result == nil)
    }
}
#endif

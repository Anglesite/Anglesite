import Foundation
#if canImport(CloudKit)
import CloudKit
import os

/// The real, cross-network ``SignalingChannel`` conformer (design spec §Architecture 5) — the P2
/// replacement for ``FileSignalingChannel``'s local-dev-only mailbox. SDP/ICE envelopes travel as
/// short-TTL `SignalingEnvelopeRecord`s in the owner's private CloudKit database, scoped by a
/// `sessionID` so concurrent unrelated signaling sessions in the same private database never
/// cross-deliver. CloudKit has no native TTL, so the "short TTL" is enforced by the reader: each
/// record is deleted immediately after being yielded.
///
/// This type is signing-agnostic — it transports whatever `payload` string it's given, the same
/// as `FileSignalingChannel`. Production always wraps it in ``SignedSignalingChannel`` (design
/// spec's explicit clarification, self-review 2026-08-13); this type has no knowledge of
/// signatures or key pinning.
///
/// ## Delivery: polling only
///
/// Unlike ``CloudKitPairingService``'s dual push/poll observation, this type polls only — no
/// `CKQuerySubscription`. By the time two peers are exchanging SDP/ICE, the helper process is
/// already awake (`CloudKitPairingService`'s device-announce subscription is what wakes it — see
/// that type's doc comment); a signaling session is short-lived (seconds, not idle for days), and
/// a subscription would need a fresh `subscriptionID` and predicate per session with no natural
/// point to clean it up afterwards. A short poll interval during an active handshake is simpler
/// and doesn't accumulate server-side subscription litter.
///
/// ## CKRecord/query idiom
///
/// Reuses exactly the save/query/delete idiom ``CloudKitPairingService`` established: envelopes
/// are plain `CKRecord`s (not `CKAsset`s — SDP/ICE payloads are well under the 1 MB per-record
/// ceiling), read back with a `CKQuery` predicate, decoded defensively ("drop, don't throw" for
/// anything that doesn't parse — untrusted shared-database input).
public actor CloudKitSignalingChannel: SignalingChannel {
    private static let logger = Logger(subsystem: "io.dwk.anglesite", category: "CloudKitSignalingChannel")
    /// If a sender's `pending` backlog grows past this while blocked on a single missing seq,
    /// `deliverContiguous()` logs at `.fault` — mirrors `FileSignalingChannel`'s same threshold and
    /// same rationale: a signal that delivery is genuinely stuck, not just normally out of order.
    private static let pendingBacklogWarningThreshold = 32

    /// `nil` only for a channel built by ``init(offlinePollInterval:sessionID:sender:)``; see that
    /// initializer for why an offline test cannot hold a real one.
    private let database: CKDatabase?
    private let sessionID: String
    private let sender: String
    private let pollInterval: Duration

    private let stream: AsyncStream<SignalingEnvelope>
    private let continuation: AsyncStream<SignalingEnvelope>.Continuation
    private var pollTask: Task<Void, Never>?
    private var closed = false

    /// Envelopes read from CloudKit but not yet delivered (out-of-order arrivals), keyed by sender
    /// then seq — same shape as `FileSignalingChannel.pending`. Unlike that type, entries here need
    /// no separate "already seen" set: a delivered envelope's `CKRecord` is deleted, so it simply
    /// stops coming back on the next query.
    private var pending: [String: [Int: SignalingEnvelope]] = [:]
    /// The next seq this channel will deliver for each sender.
    private var nextExpectedSeq: [String: Int] = [:]

    /// Whether the poll loop is live. Internal observability for offline lifecycle assertions.
    var isObserving: Bool { pollTask != nil }

    /// - Parameters:
    ///   - container: `CKContainer(identifier: "iCloud.io.dwk.anglesite")` in production — the
    ///     same container ``CloudKitPairingService`` uses.
    ///   - sessionID: Scopes this channel to one signaling session so concurrent unrelated
    ///     sessions in the same private database never cross-deliver.
    ///   - sender: This endpoint's stable id, same role as `FileSignalingChannel`'s `sender`.
    ///   - pollInterval: how often to re-query while observing. Tests shorten this; production
    ///     favors a short interval since a signaling session is active and short-lived, not
    ///     something latency can be traded away on the way `CloudKitPairingService` does.
    public init(container: CKContainer, sessionID: String, sender: String, pollInterval: Duration = .seconds(2)) {
        self.init(database: container.privateCloudDatabase, sessionID: sessionID, sender: sender, pollInterval: pollInterval)
    }

    /// Builds a channel with no CloudKit database, so `send`/`close`/stream-termination behavior
    /// can be exercised offline. Every CloudKit-touching method on such a channel throws
    /// ``CloudKitUnavailable``.
    ///
    /// This exists for the same reason ``CloudKitPairingService/init(offlinePollInterval:)``
    /// does: `CKContainer(identifier:)` **traps the process** when the running binary lacks the
    /// CloudKit entitlement, so "construct a container but never touch the network" is not
    /// something an unentitled test can do, and a seam is the only way to cover this actor's
    /// lifecycle in CI.
    init(offlinePollInterval: Duration, sessionID: String, sender: String) {
        self.init(database: nil, sessionID: sessionID, sender: sender, pollInterval: offlinePollInterval)
    }

    private init(database: CKDatabase?, sessionID: String, sender: String, pollInterval: Duration) {
        self.database = database
        self.sessionID = sessionID
        self.sender = sender
        self.pollInterval = pollInterval
        (self.stream, self.continuation) =
            AsyncStream<SignalingEnvelope>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Writes `envelope` (stamped with this channel's own `sender`, superseding whatever the
    /// caller passed in `envelope.sender` — matching `FileSignalingChannel.send(_:)`) as a
    /// `SignalingEnvelopeRecord` in the private database.
    ///
    /// - Throws: ``CloudKitUnavailable`` if this channel has no database (the offline seam), or
    ///   ``CloudKitSignalingChannelError/closed`` if `close()` was already called; otherwise
    ///   whatever `CKDatabase.modifyRecords` throws.
    public func send(_ envelope: SignalingEnvelope) async throws {
        guard let database else { throw CloudKitUnavailable() }
        guard !closed else { throw CloudKitSignalingChannelError.closed }
        var stamped = envelope
        stamped.sender = sender
        let record = SignalingEnvelopeRecord(envelope: stamped, sessionID: sessionID).makeCloudKitRecord()
        let (saveResults, _) = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .allKeys, atomically: true)
        for (_, result) in saveResults { _ = try result.get() }
    }

    /// The single stream of inbound envelopes from other senders in this session, in per-sender
    /// seq order. Observation starts on first call and is idempotent; `nonisolated` (the stream is
    /// a `let` fixed at construction) so a caller can start consuming without an actor hop,
    /// matching `FileSignalingChannel.envelopes()`.
    public nonisolated func envelopes() -> AsyncStream<SignalingEnvelope> {
        Task { await self.startObserving() }
        return stream
    }

    /// Stops polling and finishes `envelopes()`'s stream. Idempotent.
    public func close() async {
        guard !closed else { return }
        closed = true
        pollTask?.cancel()
        pollTask = nil
        continuation.finish()
    }

    /// Starts the poll loop, at most once per channel. Internal rather than private so offline
    /// lifecycle tests can drive it deterministically.
    func startObserving() async {
        guard !closed, pollTask == nil else { return }
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                guard await self?.refresh() != nil else { return }
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return // Cancelled.
                }
            }
        }
    }

    /// One query pass: fetches every `SignalingEnvelopeRecord` for `sessionID`, buffers records
    /// from other senders into `pending`, then delivers whatever contiguous run each sender's
    /// `pending` now supports — deleting each delivered record from CloudKit as it goes (the
    /// short-TTL enforcement the type doc comment describes). This device's own records are never
    /// touched: they exist for the *other* peer to consume and delete.
    ///
    /// Errors are logged, not thrown — a transient CloudKit failure must not tear down a long-lived
    /// observation, and the next poll retries on its own.
    private func refresh() async {
        guard let database else { return }
        let predicate = NSPredicate(format: "sessionID == %@", sessionID)
        let query = CKQuery(recordType: SignalingEnvelopeRecord.cloudKitRecordType, predicate: predicate)
        do {
            let (matchResults, _) = try await database.records(matching: query, resultsLimit: 200)
            for (_, result) in matchResults {
                guard let record = try? result.get(),
                      let envelopeRecord = SignalingEnvelopeRecord(record: record),
                      envelopeRecord.sender != sender
                else { continue }
                pending[envelopeRecord.sender, default: [:]][envelopeRecord.seq] = envelopeRecord.envelope
            }
        } catch {
            Self.logger.warning("signaling envelope query failed: \(error, privacy: .public)")
        }
        await deliverContiguous()
    }

    /// For each sender with buffered envelopes, delivers the contiguous run starting at that
    /// sender's next expected seq — mirroring `FileSignalingChannel.deliverContiguous()` — and
    /// deletes each delivered envelope's `CKRecord`, since CloudKit has no native TTL and this is
    /// the mechanism that stands in for one.
    private func deliverContiguous() async {
        for envelopeSender in Array(pending.keys) {
            guard var bucket = pending[envelopeSender] else { continue }
            var expected = nextExpectedSeq[envelopeSender] ?? 1
            while let envelope = bucket.removeValue(forKey: expected) {
                continuation.yield(envelope)
                await deleteRecord(sender: envelopeSender, seq: expected)
                expected += 1
            }
            nextExpectedSeq[envelopeSender] = expected
            if bucket.count > Self.pendingBacklogWarningThreshold {
                Self.logger.fault("pending envelope backlog for sender \(envelopeSender, privacy: .public) exceeds \(Self.pendingBacklogWarningThreshold, privacy: .public) while waiting on seq \(expected, privacy: .public) — a missing record may be wedging delivery")
            }
            pending[envelopeSender] = bucket
        }
    }

    /// Deletes a delivered envelope's `CKRecord`, reconstructing its ID from `sessionID`/`sender`/
    /// `seq` rather than keeping the fetched `CKRecord.ID` around — the record name is fully
    /// determined by those three values (see `SignalingEnvelopeRecord.makeCloudKitRecord()`).
    ///
    /// A failed delete is logged, not retried: the record would simply be re-fetched and
    /// re-buffered on the next poll, but `nextExpectedSeq` has already advanced past it, so it is
    /// never re-delivered — the failure mode is "one record never gets cleaned up", not
    /// "duplicate delivery".
    private func deleteRecord(sender: String, seq: Int) async {
        guard let database else { return }
        let recordID = CKRecord.ID(recordName: SignalingEnvelopeRecord.recordName(sessionID: sessionID, sender: sender, seq: seq))
        do {
            _ = try await database.deleteRecord(withID: recordID)
        } catch {
            Self.logger.warning("failed to delete delivered signaling record \(recordID.recordName, privacy: .public): \(error, privacy: .public)")
        }
    }
}

/// Errors specific to ``CloudKitSignalingChannel``.
public enum CloudKitSignalingChannelError: Error, Equatable {
    /// `send(_:)` was called after `close()`.
    case closed
}

/// One SDP/ICE handshake step, CloudKit-record-shaped — the ``CloudKitSignalingChannel`` analogue
/// of `DeviceAnnounceRecord`. Not `Codable` (CloudKit's own `CKRecord` is the wire format; this is
/// the typed Swift view over it).
struct SignalingEnvelopeRecord: Sendable, Equatable {
    /// Scopes this record to one signaling session, so a query can select only the envelopes
    /// belonging to it out of a private database that may hold several concurrent sessions.
    let sessionID: String
    /// See ``SignalingEnvelope/seq``.
    let seq: Int
    /// See ``SignalingEnvelope/sender``.
    let sender: String
    /// See ``SignalingEnvelope/Kind``.
    let kind: SignalingEnvelope.Kind
    /// See ``SignalingEnvelope/payload``.
    let payload: String

    init(sessionID: String, seq: Int, sender: String, kind: SignalingEnvelope.Kind, payload: String) {
        self.sessionID = sessionID
        self.seq = seq
        self.sender = sender
        self.kind = kind
        self.payload = payload
    }

    /// Builds the record for one outbound `SignalingEnvelope`, stamping it with `sessionID`.
    init(envelope: SignalingEnvelope, sessionID: String) {
        self.init(sessionID: sessionID, seq: envelope.seq, sender: envelope.sender, kind: envelope.kind, payload: envelope.payload)
    }

    /// The `SignalingEnvelope` this record carries, dropping the CloudKit-only `sessionID` field.
    var envelope: SignalingEnvelope {
        SignalingEnvelope(seq: seq, sender: sender, kind: kind, payload: payload)
    }
}

extension SignalingEnvelopeRecord {
    /// The CloudKit record type these envelopes live in.
    static let cloudKitRecordType = "SignalingEnvelopeRecord"

    /// The record name for a given `(sessionID, sender, seq)` triple — fully determined by those
    /// three values, so a delivered envelope's record can be deleted without keeping its fetched
    /// `CKRecord.ID` around.
    static func recordName(sessionID: String, sender: String, seq: Int) -> String {
        "\(sessionID)-\(sender)-\(seq)"
    }

    /// Builds the `CKRecord` for this envelope, using ``recordName(sessionID:sender:seq:)`` as the
    /// record name so a resend of the same `(sessionID, sender, seq)` overwrites in place rather
    /// than accumulating a duplicate.
    func makeCloudKitRecord() -> CKRecord {
        let record = CKRecord(
            recordType: Self.cloudKitRecordType,
            recordID: CKRecord.ID(recordName: Self.recordName(sessionID: sessionID, sender: sender, seq: seq)))
        record["sessionID"] = sessionID as CKRecordValue
        record["seq"] = seq as CKRecordValue
        record["sender"] = sender as CKRecordValue
        record["kind"] = kind.rawValue as CKRecordValue
        record["payload"] = payload as CKRecordValue
        return record
    }

    /// Reads an envelope back out of a `CKRecord`, or `nil` if the record isn't one — wrong type,
    /// missing field, wrong field type, or an unrecognized `kind`.
    ///
    /// Returns `nil` rather than throwing for the same reason `DeviceAnnounceRecord.init(record:)`
    /// does: this is untrusted input from a shared database, and the only sane response to a
    /// record that doesn't parse is to skip it.
    init?(record: CKRecord) {
        guard record.recordType == Self.cloudKitRecordType,
              let sessionID = record["sessionID"] as? String,
              let seq = record["seq"] as? Int,
              let sender = record["sender"] as? String,
              let kindRaw = record["kind"] as? String,
              let kind = SignalingEnvelope.Kind(rawValue: kindRaw),
              let payload = record["payload"] as? String
        else { return nil }
        self.init(sessionID: sessionID, seq: seq, sender: sender, kind: kind, payload: payload)
    }
}
#endif

import Foundation
#if canImport(CloudKit)
import CloudKit
import os

/// Writes and observes `DeviceAnnounceRecord`s in the owner's private CloudKit database — the
/// pairing handshake's own CloudKit interaction, distinct from `CloudKitSignalingChannel`'s
/// signaling-envelope records (design spec §Architecture 5). Both devices share the same Apple
/// ID's private database, so there is no server-side account or infrastructure: "the owner's
/// iCloud account" *is* the rendezvous point.
///
/// ## Delivery: subscription push plus a polling floor
///
/// `announcedDevices()` is driven by two cooperating mechanisms rather than one:
///
/// - A `CKQuerySubscription` with silent (`shouldSendContentAvailable`) push, registered on first
///   observation. This is the mechanism the whole Anywhere-runtime design hangs on — it is why
///   `AnglesiteRemote` is a faceless *app* rather than a bare LaunchAgent (design spec
///   §Architecture 2): APNs can wake a registered app that is otherwise idle. The push itself
///   arrives at `NSApplicationDelegate`, not here, so the delegate hands it back via
///   ``handleRemoteNotification(_:)``.
/// - A low-frequency poll of the same query. CloudKit push is best-effort — APNs coalesces,
///   drops, and delays silent pushes, and a Mac with no push connectivity (or a build whose
///   entitlement isn't provisioned yet — see the P2 plan's manual portal step) would otherwise
///   observe nothing at all. At P2's scale — one owner, a handful of devices, pairing windows
///   measured in seconds — a poll is cheap insurance, so it is the correctness floor and push is
///   the latency optimization on top.
///
/// The push path deliberately re-queries rather than reading fields out of the notification
/// payload: `CKQueryNotification.recordFields` only carries `desiredKeys` and is truncated when
/// the payload is large, so treating any push as "something changed, go look" is both simpler and
/// strictly more correct than reconstructing a record from the notification.
///
/// ## Scope
///
/// This type only reads and writes CloudKit. Deciding whether an announced device is *trusted* —
/// matching a scanned QR payload, recording it in `PairedDeviceStore` — is the pairing flow's
/// job, not this one's. `announcedDevices()` therefore yields every announce it sees, including
/// this device's own; callers filter by their own `deviceID`.
public actor CloudKitPairingService {
    private static let logger = Logger(subsystem: "io.dwk.anglesite", category: "CloudKitPairingService")

    /// The subscription's stable ID. Fixed rather than random so a relaunched helper re-registers
    /// *the same* subscription (CloudKit rejects the duplicate, which ``registerSubscription()``
    /// swallows) instead of accumulating one dead subscription per launch.
    public static let subscriptionID = "anglesite-device-announce"

    private let database: CKDatabase
    private let pollInterval: Duration
    private let stream: AsyncStream<DeviceAnnounceRecord>
    private let continuation: AsyncStream<DeviceAnnounceRecord>.Continuation
    private var observationTask: Task<Void, Never>?
    /// Announces already yielded, keyed by record name + announce timestamp, so a poll that
    /// re-reads the same rows doesn't re-emit them while a genuine *re*-announce (new timestamp)
    /// still gets through.
    private var emitted: Set<String> = []

    /// - Parameters:
    ///   - container: `CKContainer(identifier: "iCloud.io.dwk.anglesite")` in production — the
    ///     same container the app already uses for iCloud Drive site storage, not a new one.
    ///     Injectable so tests can point at a different (or the same, gated) real container
    ///     without touching production data.
    ///   - pollInterval: how often to re-query while observing. The default trades a little
    ///     latency for a lot fewer requests, since push normally beats the timer; tests shorten it.
    public init(container: CKContainer, pollInterval: Duration = .seconds(15)) {
        self.database = container.privateCloudDatabase
        self.pollInterval = pollInterval
        (self.stream, self.continuation) =
            AsyncStream<DeviceAnnounceRecord>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Publishes this device's own announce record (deviceID, public key, display name) so a peer
    /// that already knows to look can find it.
    ///
    /// Re-announcing the same `deviceID` overwrites: the record name *is* the device ID, and the
    /// save policy is `.allKeys`. Both are deliberate. A plain `save(_:)` uses
    /// `.ifServerRecordUnchanged`, which would fail with `serverRecordChanged` the second time a
    /// device announces, since a freshly built `CKRecord` carries no change tag for the row that
    /// already exists.
    ///
    /// - Parameters:
    ///   - deviceID: also the CloudKit record name, so it must be a valid one — 255 characters or
    ///     fewer, and not prefixed with `_` (which CloudKit reserves). The UUID strings the
    ///     pairing flow generates satisfy both.
    ///   - publicKeyData: the peer's X9.63 uncompressed point, as produced by
    ///     `DevicePairingKeyPair.publicKeyData`. 65 bytes, stored as a plain `Data` field:
    ///     CloudKit's per-record ceiling is 1 MB, so `CKAsset` (which exists for multi-megabyte
    ///     blobs) would add a round trip and a temp file for nothing.
    public func announce(deviceID: String, publicKeyData: Data, displayName: String) async throws {
        let record = DeviceAnnounceRecord(
            deviceID: deviceID, publicKeyData: publicKeyData,
            displayName: displayName, createdAt: Date()
        ).makeCloudKitRecord()
        let (saveResults, _) = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .allKeys, atomically: true)
        for (_, result) in saveResults { _ = try result.get() }
    }

    /// Removes this device's announce record. The announce is a rendezvous breadcrumb, not durable
    /// state — once pairing has completed (or been abandoned) there is no reason to leave it in
    /// the owner's database, and the gated tests use this to avoid littering a real container.
    public func withdrawAnnounce(deviceID: String) async throws {
        _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: deviceID))
    }

    /// Subscribes to new `DeviceAnnounceRecord`s and yields each one as it arrives.
    ///
    /// `AsyncStream` mirrors `SignalingChannel.envelopes()`'s shape for consistency, though this
    /// type does not itself conform to `SignalingChannel` — it is a distinct, smaller surface
    /// (one-shot announce plus a stream, not send/receive/close).
    ///
    /// `nonisolated` (the stream is a `let` fixed at construction) so a caller can start consuming
    /// without an actor hop, matching `FileSignalingChannel.envelopes()`. Observation itself starts
    /// on the first call and is idempotent; nothing is lost in the gap because the stream buffers
    /// without bound.
    public nonisolated func announcedDevices() -> AsyncStream<DeviceAnnounceRecord> {
        Task { await self.startObserving() }
        return stream
    }

    /// Stops polling and finishes `announcedDevices()`'s stream. Idempotent. The stream cannot be
    /// restarted afterwards — construct a new service, matching `FileSignalingChannel.close()`.
    public func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        continuation.finish()
    }

    /// Registers the silent-push `CKQuerySubscription` that lets APNs wake an otherwise-idle
    /// helper when a peer announces itself.
    ///
    /// Safe to call on every launch, which is why the subscription ID is a fixed constant rather
    /// than a fresh UUID. Apple's QA1917 ("Debugging issues with CloudKit subscriptions") states
    /// that saving a subscription built with an explicit `subscriptionID` is idempotent
    /// server-side — "if a subscription with the same ID has already existed on the server, no
    /// duplicate will be created" — so the steady-state relaunch normally *succeeds* rather than
    /// erroring, and no pre-flight `allSubscriptions()` check is needed.
    ///
    /// The `serverRejectedRequest` catch is therefore belt-and-braces, not the expected path: some
    /// CloudKit paths do surface an "already exists" rejection, and a helper must not treat that as
    /// a failure. Any other error propagates — a caller that wants to surface "push is not working"
    /// needs to see it. Observation calls this best-effort and keeps polling regardless, so a
    /// failure here degrades latency, not correctness.
    public func registerSubscription() async throws {
        let subscription = CKQuerySubscription(
            recordType: DeviceAnnounceRecord.cloudKitRecordType,
            predicate: NSPredicate(value: true),
            subscriptionID: Self.subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        // No alert/sound/badge and `shouldSendContentAvailable` gives a silent, content-available
        // push: it wakes the process without ever putting a banner in front of the owner, which is
        // the only acceptable behavior for a faceless (`LSUIElement`) login-item helper.
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        do {
            _ = try await database.save(subscription)
        } catch let error as CKError where error.code == .serverRejectedRequest {
            Self.logger.debug("device-announce subscription already registered")
        }
    }

    /// Routes an APNs payload delivered to `NSApplicationDelegate` back into this service,
    /// triggering an immediate re-query if the push belongs to our subscription.
    ///
    /// - Returns: `true` if the payload was a CloudKit notification for this service's
    ///   subscription (and a refresh was kicked off), `false` otherwise — letting a delegate that
    ///   fans one callback out to several listeners tell whether anyone claimed it.
    ///
    /// `nonisolated` on purpose: `userInfo` is a non-`Sendable` `[AnyHashable: Any]` that must not
    /// cross into the actor, so it is parsed here on the caller's thread and only the resulting
    /// `String` subscription ID is used to decide whether to hop.
    @discardableResult
    public nonisolated func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              notification.subscriptionID == Self.subscriptionID
        else { return false }
        // Deliberately ignores `CKQueryNotification.recordID`/`recordFields` — see the type doc
        // comment on why any push is treated as "go look" rather than as a record delta.
        Task { await self.refresh() }
        return true
    }

    private func startObserving() async {
        guard observationTask == nil else { return }
        observationTask = Task { [pollInterval] in
            do {
                try await self.registerSubscription()
            } catch {
                Self.logger.warning(
                    "device-announce subscription registration failed, polling only: \(error, privacy: .public)")
            }
            while !Task.isCancelled {
                await self.refresh()
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return  // Cancelled.
                }
            }
        }
    }

    /// One query pass: yields every announce not yielded before. Errors are logged, not thrown —
    /// a transient CloudKit failure must not tear down a long-lived observation, and the next
    /// poll retries on its own.
    private func refresh() async {
        let query = CKQuery(
            recordType: DeviceAnnounceRecord.cloudKitRecordType, predicate: NSPredicate(value: true))
        do {
            let (matchResults, _) = try await database.records(matching: query, resultsLimit: 200)
            for (recordID, result) in matchResults {
                guard let record = try? result.get(),
                      let announce = DeviceAnnounceRecord(record: record)
                else { continue }
                let key = "\(recordID.recordName)|\(announce.createdAt.timeIntervalSinceReferenceDate)"
                guard emitted.insert(key).inserted else { continue }
                continuation.yield(announce)
            }
        } catch {
            Self.logger.warning("device-announce query failed: \(error, privacy: .public)")
        }
    }
}

/// One device's pairing announcement — CloudKit-record-shaped, not `Codable` (CloudKit's own
/// `CKRecord` is the wire format; this is the typed Swift view over it).
public struct DeviceAnnounceRecord: Sendable, Equatable {
    /// The announcing device's stable identifier, which doubles as the CloudKit record name.
    public let deviceID: String
    /// The device's signing public key as an X9.63 uncompressed point (0x04 + X + Y), the same
    /// 65-byte format `DevicePairingKeyPair.publicKeyData` produces and the QR payload carries.
    public let publicKeyData: Data
    /// Owner-facing device name, shown in the pairing UI's device list.
    public let displayName: String
    /// When the announcement was written. Also the freshness signal a re-announce changes.
    public let createdAt: Date

    public init(deviceID: String, publicKeyData: Data, displayName: String, createdAt: Date) {
        self.deviceID = deviceID
        self.publicKeyData = publicKeyData
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

extension DeviceAnnounceRecord {
    /// The CloudKit record type these announcements live in.
    static let cloudKitRecordType = "DeviceAnnounceRecord"

    /// Builds the `CKRecord` for this announcement, using `deviceID` as the record name so a
    /// re-announce overwrites in place.
    func makeCloudKitRecord() -> CKRecord {
        let record = CKRecord(
            recordType: Self.cloudKitRecordType, recordID: CKRecord.ID(recordName: deviceID))
        record["deviceID"] = deviceID as CKRecordValue
        record["publicKey"] = publicKeyData as CKRecordValue
        record["displayName"] = displayName as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        return record
    }

    /// Reads an announcement back out of a `CKRecord`, or `nil` if the record isn't one — wrong
    /// type, missing field, or wrong field type.
    ///
    /// Returns `nil` rather than throwing for the same reason `DevicePairingKeyPair.verify` does:
    /// this is untrusted input from a shared database, and the only sane response to a record that
    /// doesn't parse is to skip it.
    init?(record: CKRecord) {
        guard record.recordType == Self.cloudKitRecordType,
              let deviceID = record["deviceID"] as? String,
              let publicKeyData = record["publicKey"] as? Data,
              let displayName = record["displayName"] as? String,
              let createdAt = record["createdAt"] as? Date
        else { return nil }
        self.init(
            deviceID: deviceID, publicKeyData: publicKeyData,
            displayName: displayName, createdAt: createdAt)
    }
}
#endif

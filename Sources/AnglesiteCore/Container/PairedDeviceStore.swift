import Foundation

/// Registry of paired Anywhere-runtime devices, persisted as JSON — mirrors `ACPAgentStore`
/// exactly (synchronous, not an actor; tiny; touched rarely — Settings edits and pairing events).
public final class PairedDeviceStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let persistenceURL: URL
    /// Sibling of ``persistenceURL`` holding the revocation tombstones — see ``remove(id:)``.
    /// Derived rather than injected so every existing call site (and every test that already passes
    /// a temp `persistenceURL`) gets a correctly co-located, correctly isolated one for free.
    private let revocationsURL: URL

    /// - Parameters:
    ///   - persistenceURL: where to read/write `paired-devices.json`. Defaults to
    ///     `~/Library/Application Support/Anglesite/paired-devices.json`. Tests should pass a temp URL.
    ///     Revocation tombstones go in `revoked-devices.json` beside it.
    ///   - fileManager: Injectable for tests; defaults to `.default`.
    public init(persistenceURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let url = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
        self.persistenceURL = url
        self.revocationsURL = url.deletingLastPathComponent()
            .appendingPathComponent("revoked-devices.json")
    }

    /// Reads the full list fresh from disk. Returns `[]` if no file exists yet.
    public func load() throws -> [PairedDevice] {
        guard fileManager.fileExists(atPath: persistenceURL.path) else { return [] }
        let data = try Data(contentsOf: persistenceURL)
        return try Self.decoder.decode([PairedDevice].self, from: data)
    }

    /// Appends `device`. Callers are responsible for using a fresh `UUID`.
    public func add(_ device: PairedDevice) throws {
        var all = try load()
        all.append(device)
        try persist(all)
    }

    /// Replaces the entry whose `id` matches `device.id`. No-op if no entry matches.
    public func update(_ device: PairedDevice) throws {
        var all = try load()
        guard let index = all.firstIndex(where: { $0.id == device.id }) else { return }
        all[index] = device
        try persist(all)
    }

    /// Removes the entry with `id` — the Revoke action's model-layer half — and records a
    /// revocation tombstone for its `deviceID`. No-op if no entry matches.
    ///
    /// ## Why removing the row is not enough
    ///
    /// Revocation has to survive the *rendezvous* layer, not just the local list. A peer's
    /// `DeviceAnnounceRecord` lives in the owner's private CloudKit database and nothing in
    /// production withdraws it, so after a revoke the stale announce is still sitting there; the
    /// helper's pairing observation (`startPairingObservation` in `anglesite-remote-helper`) starts
    /// fresh on every launch with an empty dedup set, sees that announce, and would re-pin the
    /// device it was just told to forget. Revocation would last exactly until the next session,
    /// contradicting the design spec's own §Error handling guarantee that
    /// `PairedDeviceStore.remove` "drops the pinned key immediately for *future* connection
    /// attempts".
    ///
    /// The tombstone is what makes that guarantee real, and it is stored locally precisely so it
    /// does not depend on a CloudKit delete succeeding (or on the peer cooperating).
    ///
    /// ## Why it stores a date rather than just an ID
    ///
    /// A bare "never pin this device again" list would make re-pairing a revoked phone impossible,
    /// since nothing in the UI clears it. Recording *when* the revocation happened lets
    /// ``revocationDate(deviceID:)``'s caller distinguish the two cases that matter: an announce
    /// written **before** the revoke is the stale record being defended against, while one written
    /// **after** it is the owner deliberately pairing the device again.
    ///
    /// ## Why the tombstone is written *first*
    ///
    /// This touches two files, and each write is individually atomic but the pair is not — so the
    /// order decides which way an interruption between them fails. Removing the row first fails
    /// **open**: a throw from the tombstone write leaves the device gone from
    /// `paired-devices.json` with nothing recording that it was revoked, which is precisely the
    /// state the tombstone exists to prevent — the next announce re-pins it as a brand-new device.
    /// Worse, retrying doesn't heal it: the row is already gone, so the second call matches
    /// nothing, returns *successfully* via the `guard` below, and the UI reports a revoke that
    /// never recorded anything.
    ///
    /// Writing the tombstone first fails **closed**. An interruption leaves the device tombstoned
    /// but still listed: a cosmetic inconsistency (it looks paired, but no announce can re-pin it)
    /// that the owner can resolve by revoking again — and that retry *does* heal, because the row
    /// is still there to match. A stale UI row is a much better failure than a silently
    /// un-revoked device.
    public func remove(id: UUID) throws {
        var all = try load()
        let revoked = all.filter { $0.id == id }
        guard !revoked.isEmpty else { return }
        var tombstones = try revocations()
        let now = Date()
        for device in revoked { tombstones[device.deviceID] = now }
        try persistRevocations(tombstones)
        all.removeAll { $0.id == id }
        try persist(all)
    }

    /// When `deviceID` was last revoked on this Mac, or `nil` if it never was.
    ///
    /// Callers compare it against the announcement's own `createdAt`: an announce at or before this
    /// date is the stale record a revoke was meant to defeat and must not be pinned; a later one is
    /// a fresh, deliberate re-pairing. See ``remove(id:)`` for the full rationale.
    public func revocationDate(deviceID: String) throws -> Date? {
        try revocations()[deviceID]
    }

    /// Every recorded tombstone, keyed by peer `deviceID`. Returns `[:]` if none were ever written.
    private func revocations() throws -> [String: Date] {
        guard fileManager.fileExists(atPath: revocationsURL.path) else { return [:] }
        let data = try Data(contentsOf: revocationsURL)
        return try Self.decoder.decode([String: Date].self, from: data)
    }

    private func persistRevocations(_ tombstones: [String: Date]) throws {
        try fileManager.createDirectory(
            at: revocationsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(tombstones).write(to: revocationsURL, options: [.atomic])
    }

    /// Looks up a paired device by its peer-supplied `deviceID` (not this store's own `id`) — the
    /// lookup `SignedSignalingChannel`/`CloudKitSignalingChannel` construction needs before
    /// opening a channel for an inbound connection request. `nil` for an unpaired/unknown device.
    public func device(deviceID: String) throws -> PairedDevice? {
        try load().first { $0.deviceID == deviceID }
    }

    private func persist(_ devices: [PairedDevice]) throws {
        let dir = persistenceURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(devices)
        try data.write(to: persistenceURL, options: [.atomic])
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder { JSONDecoder() }

    private static func defaultPersistenceURL(fileManager: FileManager) -> URL {
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.portableHomeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Anglesite", isDirectory: true)
            .appendingPathComponent("paired-devices.json")
    }
}

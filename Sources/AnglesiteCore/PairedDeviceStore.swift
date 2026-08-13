import Foundation

/// Registry of paired Anywhere-runtime devices, persisted as JSON — mirrors `ACPAgentStore`
/// exactly (synchronous, not an actor; tiny; touched rarely — Settings edits and pairing events).
public final class PairedDeviceStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let persistenceURL: URL

    /// - Parameters:
    ///   - persistenceURL: where to read/write `paired-devices.json`. Defaults to
    ///     `~/Library/Application Support/Anglesite/paired-devices.json`. Tests should pass a temp URL.
    ///   - fileManager: Injectable for tests; defaults to `.default`.
    public init(persistenceURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL(fileManager: fileManager)
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

    /// Removes the entry with `id` — the Revoke action's model-layer half. No-op if no entry matches.
    public func remove(id: UUID) throws {
        var all = try load()
        all.removeAll { $0.id == id }
        try persist(all)
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

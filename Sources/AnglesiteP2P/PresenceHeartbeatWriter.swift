import Foundation
#if canImport(CloudKit)

/// Writes/replaces a single `PresenceHeartbeatRecord` (design spec's Failure Modes: "Mac writes
/// a lightweight presence heartbeat to CloudKit ~every 15 min"). Write-side only in P2 — nothing
/// consumes this yet (P4's job, once a phone UI exists to render "last reachable at...").
public actor PresenceHeartbeatWriter {
    private let save: @Sendable (Date) async throws -> Void
    private let interval: Duration

    /// - Parameters:
    ///   - save: The CKRecord-save seam (`container.privateCloudDatabase.save(_:)` in
    ///     production) — injected so tests can verify write timing/content without real CloudKit.
    ///   - interval: Defaults to 15 minutes per the design spec.
    public init(save: @escaping @Sendable (Date) async throws -> Void, interval: Duration = .seconds(900)) {
        self.save = save
        self.interval = interval
    }

    /// Runs until cancelled: writes immediately, then every `interval`.
    public func run() async {
        while !Task.isCancelled {
            do { try await save(Date()) } catch { /* best-effort: a missed heartbeat is not fatal, next tick retries */ }
            try? await Task.sleep(for: interval)
        }
    }
}
#endif

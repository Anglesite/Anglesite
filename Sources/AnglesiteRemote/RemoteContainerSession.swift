import AnglesiteCore
import Foundation
import os.log

/// Boots (or reuses) the container for one site, publishing/withdrawing its
/// `RemoteSessionRegistry` claim around the container's lifetime. "One container owner per
/// site, always" (design spec §Architecture 5): if another process already published a claim
/// for this `siteID`, this session bridges to those ports instead of booting a second container.
public actor RemoteContainerSession {
    private static let logger = os.Logger(subsystem: "io.dwk.anglesite.remote", category: "RemoteContainerSession")

    private let control: any LocalContainerControl
    private let registry: RemoteSessionRegistry
    private let pid: Int32

    /// The set of `siteID`s THIS session booted (and therefore owns the claim for) — tracked so
    /// `tearDown` only stops the container and withdraws the claim when this session is the
    /// actual owner, never when it merely bridged to another process's already-published claim.
    private var ownedSiteIDs: Set<String> = []

    /// Creates a session over the given container backend and claim registry.
    /// - Parameters:
    ///   - control: The container backend — `ContainerizationControl()` in production, a fake
    ///     in tests (same seam `LocalContainerSiteRuntime` and its tests already use).
    ///   - registry: Where ownership claims are published — see Global Constraints re: the App
    ///     Group portal step this depends on in production.
    ///   - pid: This process's PID, recorded in the published claim. Injectable for tests.
    public init(control: any LocalContainerControl, registry: RemoteSessionRegistry, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.control = control
        self.registry = registry
        self.pid = pid
    }

    /// Ensures a running container for `siteID`/`sourceRepo`/`ref` and returns its endpoints —
    /// either a freshly booted one (this session becomes the owner, publishes a claim) or an
    /// already-published one from another process (no boot, no claim change).
    /// - Parameters:
    ///   - siteID: The site's stable identity, used as the registry claim key and the
    ///     container's own identity.
    ///   - sourceRepo: The site's `Source/` git repo, cloned into the guest on a fresh boot.
    ///     Ignored when reusing an existing claim.
    ///   - ref: The git ref to check out on a fresh boot. Ignored when reusing an existing claim.
    ///   - onOutput: Receives guest process output lines on a fresh boot. Never called when
    ///     reusing an existing claim, since no container is booted.
    /// - Returns: The container's host-reachable endpoints — either freshly booted or read from
    ///   another process's published claim.
    /// - Throws: Whatever `control.start(siteID:sourceRepo:ref:onOutput:)` or the registry's
    ///   `lookup` call throws. A failing `publish` is deliberately *not* propagated — see below.
    public func ensureRunning(
        siteID: String,
        sourceRepo: URL,
        ref: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> LocalContainerSession {
        if let claim = try await registry.lookup(siteID: siteID) {
            // A claim is only trustworthy while the process that published it is still alive.
            // Nothing withdraws a claim on SIGKILL/crash, so without this check a killed helper
            // leaves a claim every future session for this site believes forever, bridging to
            // ports nobody is listening on. A dead owner is treated exactly like no claim at all.
            if Self.isProcessAlive(claim.ownerPID) {
                return LocalContainerSession(previewURL: claim.previewURL, mcpURL: claim.mcpURL)
            }
            Self.logger.notice(
                "discarding stale claim for \(siteID, privacy: .public); owner pid \(claim.ownerPID, privacy: .public) is gone")
            try? await registry.withdraw(siteID: siteID)
        }

        let session = try await control.start(siteID: siteID, sourceRepo: sourceRepo, ref: ref, onOutput: onOutput)
        // Ownership is recorded the instant the container exists, BEFORE the claim is published:
        // if `publish` throws and this line hasn't run, `tearDown` refuses to stop a container
        // this session really does own, and the VM leaks for the process's lifetime.
        ownedSiteIDs.insert(siteID)
        do {
            try await registry.publish(RemoteSessionClaim(
                siteID: siteID, previewURL: session.previewURL, mcpURL: session.mcpURL, ownerPID: pid))
        } catch {
            // Deliberately not rethrown. The claim is best-effort bookkeeping for *other*
            // processes ("someone already serves this site"); it is not load-bearing for this
            // session, whose container is booted and usable. Rethrowing would report a boot
            // failure that didn't happen and abandon a running VM — the strictly worse outcome.
            // The cost of continuing is bounded and local: another helper session for the same
            // site may boot a second container.
            Self.report("claim publish failed for \(siteID) (container is up and owned): \(error)")
        }
        return session
    }

    /// True when `pid` names a live process. `kill(pid, 0)` performs the permission and existence
    /// checks without delivering a signal: 0 means it exists, `EPERM` means it exists but belongs
    /// to someone else (still alive, which is all this asks), and `ESRCH` means it's gone.
    private static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Reports to **both** the system log and stderr — `os.Logger` alone never reaches the
    /// helper's stderr transcript, which is what an operator (and the E2E suite) actually reads.
    private static func report(_ message: String) {
        logger.error("RemoteContainerSession: \(message, privacy: .public)")
        FileHandle.standardError.write(Data("RemoteContainerSession: \(message)\n".utf8))
    }

    /// Tears down — only if THIS session booted the container (owns the claim); a no-op when
    /// bridging to another process's container, since that process owns its lifecycle.
    /// - Parameter siteID: The site whose container (if owned by this session) should stop.
    public func tearDown(siteID: String) async {
        guard ownedSiteIDs.contains(siteID) else { return }
        ownedSiteIDs.remove(siteID)
        try? await control.stop(siteID: siteID)
        try? await registry.withdraw(siteID: siteID)
    }
}

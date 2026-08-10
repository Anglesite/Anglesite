import AnglesiteCore
import Foundation

/// Boots (or reuses) the container for one site, publishing/withdrawing its
/// `RemoteSessionRegistry` claim around the container's lifetime. "One container owner per
/// site, always" (design spec §Architecture 5): if another process already published a claim
/// for this `siteID`, this session bridges to those ports instead of booting a second container.
public actor RemoteContainerSession {
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
    ///   `lookup`/`publish` calls throw.
    public func ensureRunning(
        siteID: String,
        sourceRepo: URL,
        ref: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> LocalContainerSession {
        if let claim = try await registry.lookup(siteID: siteID) {
            return LocalContainerSession(previewURL: claim.previewURL, mcpURL: claim.mcpURL)
        }

        let session = try await control.start(siteID: siteID, sourceRepo: sourceRepo, ref: ref, onOutput: onOutput)
        try await registry.publish(RemoteSessionClaim(
            siteID: siteID, previewURL: session.previewURL, mcpURL: session.mcpURL, ownerPID: pid))
        ownedSiteIDs.insert(siteID)
        return session
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

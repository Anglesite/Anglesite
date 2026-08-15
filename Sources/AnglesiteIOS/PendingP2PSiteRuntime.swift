import Foundation
import AnglesiteCore

/// Placeholder `SiteRuntime` behind the Edit Site session UI (#1431) until #1208 P4 ships the
/// real WebRTC-backed `P2PSiteRuntime`: every start settles to an honest owner-facing failure.
/// P4 replaces the one factory closure in the shell that constructs this — nothing else in the
/// session UI knows which runtime it is driving.
public actor PendingP2PSiteRuntime: SiteRuntime {
    /// Never connected by this runtime; exists to satisfy the seam so the preview leg's edit
    /// pipeline wiring stays identical when the real runtime lands.
    public let mcpClient = MCPClient(supervisor: ProcessSupervisor())

    private let stateMachine = SiteRuntimeStateMachine()

    public init() {}

    public func start(siteID: String, siteDirectory: URL) async {
        let gen = stateMachine.beginStarting(siteID: siteID)
        stateMachine.settle(gen: gen, to: .failed(
            siteID: siteID,
            message: String(localized: "Editing from this device isn't available yet — a future update connects it to Anglesite on your Mac.")))
    }

    public func stop() async {
        stateMachine.settle(gen: stateMachine.beginAttempt(), to: .idle)
    }

    public func observe() -> AsyncStream<SiteRuntimeState> {
        stateMachine.observe()
    }
}

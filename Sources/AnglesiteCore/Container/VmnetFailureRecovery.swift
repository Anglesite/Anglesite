import Foundation

/// Turns the opaque error emitted by `VmnetNetwork()` into an operator-actionable diagnosis.
///
/// The app is sandboxed and must not inspect or terminate another process's Virtualization XPC
/// VM. In particular, a stale VM can survive its owning container CLI process, so this alone
/// cannot reliably repair system-wide vmnet state (#753) — quitting other apps or rebooting may
/// still be needed. But the failure can also be *this process's own* cached vmnet network stuck in
/// a bad state, which the "Restart Networking" action the failure pane offers when `isRecoverable`
/// is true (`ContainerizationControl.resetNetworking()`, #812) can fix without either.
public enum VmnetFailureRecovery {
    /// Substring both `message(for:)` and `isRecoverable(failureMessage:)` key off of, kept in one
    /// place so the two can't drift out of sync.
    private static let recoveryMarker = "VMNET_MEM_FAILURE"

    /// Returns a stable, named recovery message for known vmnet creation failures.
    public static func message(for errorDescription: String) -> String? {
        guard errorDescription.contains("vmnet_return_t(rawValue: 1002)")
        else { return nil }

        return "The macOS vmnet service reported \(recoveryMarker) (1002). Try Restart Networking below first — "
            + "it discards this app's cached vmnet network without a relaunch. If it persists, another VM or a "
            + "stale Virtualization process may still hold vmnet resources: quit other VM/container apps and "
            + "retry, or restart your Mac to clear the stale Virtualization state."
    }

    /// True when `failureMessage` (as surfaced by `SiteRuntimeState.failed`) names a vmnet failure
    /// that `ContainerizationControl.resetNetworking()` can plausibly self-heal. Gates the
    /// failure pane's "Restart Networking" button — shown only for the failures `message(for:)`
    /// itself recognizes, not every boot failure.
    public static func isRecoverable(failureMessage: String) -> Bool {
        failureMessage.contains(recoveryMarker)
    }
}

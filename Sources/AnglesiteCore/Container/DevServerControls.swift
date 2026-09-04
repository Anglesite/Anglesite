import Foundation

/// Pure enablement rules for the Site ▸ Start/Stop/Restart Dev Server menu commands (#515):
/// given the runtime's current `SiteRuntimeState`, whether the window has a site open, and
/// whether a previously issued command is still awaiting the runtime's acknowledgement, which of
/// the three commands apply. Substrate-agnostic — the same rules hold for the local-container
/// and remote runtimes because they're stated purely in `SiteRuntimeState` terms.
///
/// `commandInFlight` closes the state-staleness window (PR #542 review): the caller's mirrored
/// `state` only updates asynchronously via the runtime's `observe()` stream, so between
/// dispatching a command and observing its first state transition, `state` alone would still
/// enable the just-fired command — letting a double-click dispatch two racing runtime calls.
/// Every accepted command produces a transition (`start` always emits `.starting`, re-entering
/// it via a transient `.idle`; `stop` emits `.idle` unless superseded by a newer command whose
/// own emission arrives instead), so the flag always clears.
///
/// Lives in `AnglesiteCore` (not the app target) so the rules run under `swift test` on CI; the
/// app-side `PreviewModel`/`SiteWindowModel`/`WebsiteCommands` glue stays thin.
public enum DevServerControls {
    /// Start applies when nothing is running: the server was explicitly stopped (`.idle`) or it
    /// crashed / never came up (`.failed` — same recovery as the preview pane's Retry button).
    public static func canStart(state: SiteRuntimeState, siteOpen: Bool, commandInFlight: Bool = false) -> Bool {
        guard siteOpen, !commandInFlight else { return false }
        switch state {
        case .idle, .failed: return true
        case .starting, .ready: return false
        }
    }

    /// Stop applies while the server is booting or serving — freeing resources for a
    /// backgrounded site window. Stopping mid-boot is safe: a boot that discovers it was
    /// superseded tears down its own container/session (see the runtimes' stale-generation
    /// paths in `start()`).
    public static func canStop(state: SiteRuntimeState, siteOpen: Bool, commandInFlight: Bool = false) -> Bool {
        guard siteOpen, !commandInFlight else { return false }
        switch state {
        case .starting, .ready: return true
        case .idle, .failed: return false
        }
    }

    /// Restart applies whenever there's something to tear down or recover: a wedged boot
    /// (`.starting` that never settles), a serving-but-unresponsive Astro process (`.ready`),
    /// or a failure. From `.idle` plain Start is the right verb, so Restart stays disabled.
    /// Re-enabled as soon as the new boot's `.starting` is observed (`commandInFlight` clears),
    /// so a boot that wedges again can still be restarted again.
    public static func canRestart(state: SiteRuntimeState, siteOpen: Bool, commandInFlight: Bool = false) -> Bool {
        guard siteOpen, !commandInFlight else { return false }
        switch state {
        case .starting, .ready, .failed: return true
        case .idle: return false
        }
    }
}

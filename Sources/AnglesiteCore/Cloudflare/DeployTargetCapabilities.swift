import Foundation

/// Which optional feature families a given ``DeployTargetKind`` can actually deliver (#1683) —
/// the deploy-target analogue of `PlatformCapabilities`, and the same policy: label what's
/// unavailable and say why, never let a control succeed and provision nothing.
///
/// Without this, a site configured for GitHub Pages could still be toggled into a Worker or
/// Inbox Capture; the toggle would report success, and `DeployModel`'s
/// `as? CloudflareDeployTarget` fallback would quietly publish nothing at the next deploy. That
/// silent degradation is exactly what the codebase's capability-labeling policy exists to
/// prevent.
public enum DeployTargetCapabilities {
    /// Whether this host runs Cloudflare Workers, and therefore whether *any* Workers-backed
    /// feature is available: the worker catalog, Inbox Capture, and whatever ships next on that
    /// runtime.
    ///
    /// One flag rather than a per-feature enum, on purpose. These features aren't independently
    /// available — they're all one requirement ("needs Cloudflare Workers") wearing different
    /// labels, so splitting them would invite a future feature to be gated on the wrong one, or
    /// on nothing at all.
    public static func supportsWorkers(for kind: DeployTargetKind) -> Bool {
        switch kind {
        case .cloudflare:
            return true
        case .githubPages:
            return false
        }
    }
}

import Foundation

/// The container-guest convention's dev-server port: every site runtime (local Apple
/// Containerization, rootless podman, and the LAN dev/test rig) starts `astro dev` on this port.
/// Single source of truth so `ContainerizationControl`, `PodmanContainerControl`, and
/// `LANRuntimeConfiguration` don't each carry their own copy of the literal (#1801).
public enum DevServer {
    /// `astro dev`'s guest-side listen port.
    public static let defaultPort = 4321
}

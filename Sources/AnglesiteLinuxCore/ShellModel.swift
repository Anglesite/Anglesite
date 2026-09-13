import Foundation
import AnglesiteCore

/// Owns the site lifecycle behind the Linux shell: open a `.anglesite` package, compose the
/// Linux runtime stack (`LocalContainerSiteRuntime` over `PodmanContainerControl`, per the
/// cross-platform port design §7 and #647), and hand the UI everything it needs to render the
/// preview and route overlay edits. One site at a time, matching the one-window MVP — opening
/// a second package stops the first site's container.
///
/// An `actor`, not `@MainActor`: `current`/`inFlightStop` are mutated from GTK callbacks *and*
/// detached tasks, so they need real isolation — and on Linux `MainActor` rides the libdispatch
/// main queue, which a GTK app's `g_main_loop`-parked main thread never drains, so main-actor
/// work would starve. Actor isolation runs on the cooperative pool and is prompt regardless of
/// what the main thread is doing.
///
/// UI-free by design: state reaches the shell through `SiteRuntime.observe()`, which the app
/// layer drains and marshals onto the GTK main loop itself (`Idle`). That is also why this type
/// lives in `AnglesiteLinuxCore` rather than next to the GTK code (#1968): it needs nothing from
/// GTK/libadwaita/WebKitGTK, so keeping it out of the `ANGLESITE_LINUX_SHELL=1`-gated executable
/// lets `Tests/AnglesiteLinuxTests` run on the plain `swift:*-noble` Linux CI leg, where the
/// GTK toolchain the executable needs isn't installed.
public actor ShellModel {
    /// What `open(packageURL:)` hands the shell: the site's identity from its marker, the runtime
    /// whose `observe()` stream the shell renders, and the edit router for the preview bridge.
    public struct OpenedSite: Sendable {
        /// The site's user-visible name, from the package marker.
        public let displayName: String
        /// The site's stable package UUID (uppercase string form — what `SiteRuntime.start`
        /// and the container naming key on).
        public let siteID: String
        /// The site's runtime; the shell watches `observe()` for `.starting` → `.ready`/`.failed`.
        public let runtime: any SiteRuntime
        /// Routes the preview's apply-edit messages through the runtime's MCP client.
        public let router: MCPApplyEditRouter
    }

    /// Builds the runtime each opened site runs in. Production is
    /// ``makePodmanRuntime()``; tests inject a recording fake so the open/switch/stop ordering
    /// is checked without podman.
    public typealias RuntimeFactory = @Sendable () -> any SiteRuntime

    private let makeRuntime: RuntimeFactory
    private var current: OpenedSite?

    /// The chain of not-yet-finished `runtime.stop()` calls from previous opens. Kept (rather
    /// than fire-and-forgotten) for two reasons: `stopCurrent()` awaits it so process exit
    /// can't race past an in-flight teardown and leak that container, and each new site's
    /// `start()` is gated on it so re-opening the *same* package can't hit a podman
    /// container-name collision with its own not-yet-removed predecessor.
    private var inFlightStop: Task<Void, Never>?

    /// Creates the model.
    ///
    /// - Parameter makeRuntime: The per-site runtime factory; defaults to the production
    ///   podman-backed stack.
    public init(makeRuntime: @escaping RuntimeFactory = { ShellModel.makePodmanRuntime() }) {
        self.makeRuntime = makeRuntime
    }

    /// The production Linux runtime stack: a `LocalContainerSiteRuntime` driving rootless podman
    /// through `PodmanContainerControl`, with a fresh `MCPClient` per site (the runtime connects
    /// it to the container's published MCP port once the guest is up).
    ///
    /// - Returns: A runtime ready for `start(siteID:siteDirectory:)`.
    public static func makePodmanRuntime() -> any SiteRuntime {
        LocalContainerSiteRuntime(
            ref: "HEAD",
            control: PodmanContainerControl(),
            mcpClient: MCPClient(supervisor: .shared)
        )
    }

    /// Reads the package marker (site identity, #242), stops any previously-open site, and
    /// kicks off the container boot. Returns as soon as identity is known — `start()` runs
    /// detached (gated on the previous teardown) and the caller watches `runtime.observe()`
    /// for `.starting` → `.ready`/`.failed`.
    ///
    /// - Parameter packageURL: The `.anglesite` package to open.
    /// - Returns: The opened site's identity, runtime, and edit router.
    /// - Throws: `AnglesitePackage.PackageError` when the marker is missing or unreadable — the
    ///   previously-open site (if any) is left running in that case.
    public func open(packageURL: URL) throws -> OpenedSite {
        let package = AnglesitePackage(url: packageURL)
        let marker = try package.readMarker()

        if let previous = current {
            let priorStops = inFlightStop
            inFlightStop = Task {
                await priorStops?.value
                await previous.runtime.stop()
            }
        }

        let runtime = makeRuntime()
        let site = OpenedSite(
            displayName: marker.displayName,
            siteID: marker.siteID.uuidString,
            runtime: runtime,
            router: MCPApplyEditRouter(mcpClient: { await runtime.mcpClient })
        )
        current = site

        let sourceURL = package.sourceURL
        let stopGate = inFlightStop
        Task {
            await stopGate?.value
            await startIfStillCurrent(site, sourceURL: sourceURL)
        }
        return site
    }

    /// The deferred half of `open`: boots `site` only if nothing superseded it while it waited
    /// on the previous teardown. Actor-isolated on purpose — the `current` check and the
    /// `start()` call are back to back with no suspension between them, so a `stopCurrent()`
    /// (or a further `open`) that lands while the start is parked on the stop gate can't slip
    /// in between and leave a container booting after the shell already gave up on it.
    /// `LocalContainerSiteRuntime` orders a `stop()` against a start it has already begun; this
    /// closes the only remaining window, the start that hasn't begun yet.
    private func startIfStillCurrent(_ site: OpenedSite, sourceURL: URL) async {
        guard let current, current.runtime === site.runtime else { return }
        await site.runtime.start(siteID: site.siteID, siteDirectory: sourceURL)
    }

    /// Stops the open site's container, if any, after draining any earlier in-flight
    /// teardowns. Called on window close and on SIGINT/SIGTERM so quitting the shell never
    /// leaks a running podman container (`podman stop` on a `--rm` container tears the whole
    /// guest down, astro/MCP included) — even when the quit lands mid-site-switch. Idempotent:
    /// a second call with nothing open returns without touching any runtime.
    public func stopCurrent() async {
        await inFlightStop?.value
        inFlightStop = nil
        guard let site = current else { return }
        current = nil
        await site.runtime.stop()
    }

    /// The edit-overlay JS to inject into the preview. On macOS this rides the app bundle
    /// (`AnglesiteOverlayBundle`); on Linux resolution tries, in order: `ANGLESITE_OVERLAY_JS`
    /// env override (dev loop); `/app/share/anglesite/edit-overlay/overlay.js`, the path the
    /// Flatpak manifest installs it to (`packaging/flatpak/io.dwk.anglesite.linux.yml` — see
    /// docs/superpowers/specs/2026-08-06-flatpak-packaging-investigation.md §7), tried only when
    /// `FLATPAK_ID` indicates a Flatpak sandbox — same detection
    /// `PodmanContainerControl.flatpakHostSpawn` uses, so a stray `/app` directory on a
    /// non-Flatpak Linux box can't silently shadow the dev-relative fallback below it; then the
    /// repo-relative `scripts/build-overlay.sh` output beside the binary's cwd, for an unpackaged
    /// dev build run from the repo root. Missing overlay is non-fatal — the preview loads without
    /// edit affordances, matching `WebViewBridge`'s behavior when the bundle wasn't produced. The
    /// ordering/gating itself lives in `overlayCandidates(environment:)`, a pure function kept
    /// separate from this one's file I/O so `Tests/AnglesiteLinuxTests` can exercise it directly.
    ///
    /// - Parameter environment: The process environment to consult (injectable for tests).
    /// - Returns: The overlay source, or `nil` when no candidate file is readable.
    public static func overlaySource(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for path in overlayCandidates(environment: environment) {
            if let source = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) {
                return source
            }
        }
        return nil
    }

    /// The ordered, filtered candidate paths `overlaySource` tries — see its doc comment for what
    /// each one is and why it's ordered that way. Split out as its own pure function (no file
    /// I/O) specifically so the ordering/gating logic is unit-testable without needing real files
    /// on disk at absolute paths like `/app/share/...`.
    ///
    /// - Parameter environment: The process environment to consult.
    /// - Returns: Candidate paths, most specific first.
    public static func overlayCandidates(environment: [String: String]) -> [String] {
        [
            environment["ANGLESITE_OVERLAY_JS"],
            environment["FLATPAK_ID"] != nil ? "/app/share/anglesite/edit-overlay/overlay.js" : nil,
            "Resources/edit-overlay/overlay.js",
        ].compactMap { $0 }
    }
}

import Foundation
import Glibc
import Adwaita
import AnglesiteCore
import CWebKitGTK

/// The Linux shell (cross-platform port phase 2, #567): a GTK4/libadwaita window that opens a
/// `.anglesite` package, boots its site in a rootless-podman container
/// (`LocalContainerSiteRuntime` over `PodmanContainerControl`, #647), and live-previews the
/// containerized Astro dev server in an embedded WebKitGTK webview with the edit overlay
/// injected. Deliberately thin (port design §6 risk containment): everything below the window
/// chrome is `AnglesiteCore`/`AnglesiteBridgeCore` — the same portable stack the macOS shell
/// composes.
///
/// Usage: `anglesite-linux [path/to/Site.anglesite]`, or open a package from the header-bar
/// button. Requires podman and a loaded `localhost/anglesite-dev:latest` image.
@main
struct AnglesiteLinuxApp: App {
    /// What the window shows. `.ready`'s payload feeds `PreviewWebView` directly.
    enum PreviewStatus: Equatable {
        case noSite
        case starting(name: String)
        case ready(name: String, url: String)
        case failed(name: String, message: String)
    }

    var app = AdwaitaApp(id: "io.dwk.anglesite.linux")

    let model = ShellModel()
    let overlaySource = ShellModel.overlaySource()
    @State private var status: PreviewStatus = .noSite
    @State private var router: MCPApplyEditRouter?
    @State private var openDialog: Signal = .init()
    @State private var quitting = false
    /// Monotonic count of `open(packageURL:)` calls. Every UI update an open's observation
    /// task schedules is guarded on the generation it was spawned under, so a superseded
    /// site's late transitions (e.g. its teardown settling after a site switch) can never
    /// clobber the current site's `status`/title — even if an `Idle` closure was already
    /// enqueued when the observation task got cancelled.
    @State private var openGeneration = 0
    /// The active open's observation task, cancelled on site switch and shutdown. Without
    /// this, each "Open Site…" switch would park the previous `for await`-loop task (and the
    /// runtime + MCP client it retains) for the rest of the process's life —
    /// `SiteRuntime.observe()`'s stream only ends when the consumer cancels.
    @State private var observation: Task<Void, Never>?

    var scene: Scene {
        Window(id: "main") { _ in
            content
                .topToolbar {
                    HeaderBar.end {
                        Button("Open Site…") { openDialog.signal() }
                    }
                    .headerBarTitle {
                        Text(windowTitle)
                    }
                }
                .folderImporter(open: openDialog) { url in
                    open(packageURL: url)
                }
                .onAppear {
                    // Logs are sacred: until the shell grows a debug pane, every supervised
                    // subprocess line (container boot, git clone, astro dev, the MCP sidecar)
                    // streams to the launching terminal's stderr.
                    Task.detached {
                        let subscription = await LogCenter.shared.subscribe()
                        for await line in subscription.stream {
                            FileHandle.standardError.write(Data("[\(line.source)] \(line.text)\n".utf8))
                        }
                    }
                    // Ctrl+C / kill must tear the container down exactly like the window
                    // close-box does — `podman run -d` guests outlive this process otherwise.
                    ShutdownSignals.handler = { beginShutdown() }
                    ShutdownSignals.install()
                    // `anglesite-linux Foo.anglesite` — open straight into the site.
                    if let path = CommandLine.arguments.dropFirst().first {
                        open(packageURL: URL(fileURLWithPath: path))
                    }
                }
        }
        .defaultSize(width: 1200, height: 800)
        .onClose {
            // Never leak the site container: intercept close, stop the runtime (podman stop
            // tears down the whole `--rm` guest), then quit for real. GTK's main loop keeps
            // running during the async stop, so the window just stays up for the second or
            // two the teardown takes.
            beginShutdown()
            return .cancel
        }
    }

    var windowTitle: String {
        switch status {
        case .noSite: return "Anglesite"
        case .starting(let name), .ready(let name, _), .failed(let name, _): return name
        }
    }

    @ViewBuilder var content: Body {
        switch status {
        case .noSite:
            StatusPage()
                .title("No Site Open")
                .description("Open a .anglesite package to start its preview.")
                .iconName("folder-open-symbolic")
        case .starting(let name):
            StatusPage()
                .title("Starting \(name)…")
                .description("Booting the site container and dev server. First boot clones the site and installs dependencies.")
                .child { Spinner() }
        case .ready(_, let url):
            PreviewWebView(
                url: url,
                router: router ?? MCPApplyEditRouter(mcpClient: { nil }),
                overlaySource: overlaySource
            )
            .vexpand()
            .hexpand()
        case .failed(_, let message):
            StatusPage()
                .title("Preview Failed")
                .description(message)
                .iconName("dialog-error-symbolic")
        }
    }

    /// Opens the package and forwards every runtime state transition onto the GTK main loop.
    /// Errors surface as `.failed` on the status page rather than crashing the shell — the
    /// launching terminal (LogCenter → stderr) has the full container output. Always called
    /// on the GTK main loop (folder importer, `onAppear`), so the cancel-then-replace of
    /// `observation` and the generation bump are ordered without further synchronization.
    func open(packageURL: URL) {
        if quitting { return }
        openGeneration += 1
        let generation = openGeneration
        observation?.cancel()

        let placeholderName = packageURL.deletingPathExtension().lastPathComponent
        status = .starting(name: placeholderName)

        observation = Task {
            let site: ShellModel.OpenedSite
            do {
                site = try await model.open(packageURL: packageURL)
            } catch {
                Idle {
                    guard openGeneration == generation else { return }
                    status = .failed(
                        name: placeholderName,
                        message: "Not an openable .anglesite package: \(error)"
                    )
                }
                return
            }
            Idle {
                guard openGeneration == generation else { return }
                router = site.router
                status = .starting(name: site.displayName)
            }
            for await state in await site.runtime.observe() {
                if Task.isCancelled { break }
                Idle {
                    guard openGeneration == generation else { return }
                    switch state {
                    case .idle:
                        break
                    case .starting:
                        status = .starting(name: site.displayName)
                    case .ready(_, let url, _):
                        status = .ready(name: site.displayName, url: url.absoluteString)
                    case .failed(_, let message):
                        status = .failed(name: site.displayName, message: message)
                    }
                }
            }
        }
    }

    /// Shared teardown for the window close-box and SIGINT/SIGTERM: stop the site container
    /// (draining any in-flight site-switch teardowns first, see `ShellModel.stopCurrent`),
    /// then quit the GTK app. Idempotent — a second close click or signal while teardown is
    /// in flight is a no-op (and a second Ctrl+C hard-kills, since the signal source is
    /// one-shot).
    func beginShutdown() {
        guard !quitting else { return }
        quitting = true
        observation?.cancel()
        Task {
            await model.stopCurrent()
            Idle { app.quit() }
        }
    }
}

/// `g_unix_signal_add`'s callback is a captureless C function pointer, so the shutdown closure
/// parks in this global. `nonisolated(unsafe)` is sound here: `handler` is written once from
/// the GTK main loop (`onAppear`) before `install()` registers the sources, and GLib invokes
/// unix-signal sources on that same main context — never from the raw signal handler.
enum ShutdownSignals {
    nonisolated(unsafe) static var handler: (() -> Void)?

    static func install() {
        let callback: @convention(c) (gpointer?) -> gboolean = { _ in
            ShutdownSignals.handler?()
            return 0 // G_SOURCE_REMOVE: the next signal falls through to default disposition,
                     // so a second Ctrl+C force-kills a wedged teardown instead of being eaten.
        }
        _ = g_unix_signal_add(SIGINT, callback, nil)
        _ = g_unix_signal_add(SIGTERM, callback, nil)
    }
}

import SwiftUI
import AnglesiteCore

/// Type-erased seam over `SafariVerificationPass.run(previewURL:port:connectTimeout:)` so tests
/// can stub the Safari MCP bridge without a live `safaridriver --mcp` session. Mirrors
/// `AgentReadinessScanning`'s role for `AgentReadinessModel`.
protocol SafariVerifying: Sendable {
    func run(previewURL: URL, port: Int, connectTimeout: TimeInterval) async throws -> SafariVerificationReport
}

extension SafariVerificationPass: SafariVerifying {}

/// App-layer glue for #1911: runs one on-demand `SafariVerificationPass` against the site's
/// current live preview URL over the already-connected Safari MCP bridge from #1910, and
/// surfaces the resulting `SafariVerificationReport`. Mirrors `AgentReadinessModel`'s shape — no
/// user input, single async step, sheet-only surface (no toolbar item, matching the codebase's
/// existing menu-only "Quality" items like Onion Routing and Moderation). The live preview URL is
/// resolved by the caller (`SiteWindowModel`, which owns `PreviewModel`) rather than by this
/// model, so `run(previewURL:)` takes it as a parameter — `nil` means the caller couldn't resolve
/// one (e.g. the dev server isn't running yet), reported as a clear failure rather than a silent
/// no-op, matching `AgentReadinessModel.runScan()`'s "no deployed URL" case.
@MainActor
@Observable
final class SafariVerificationModel {
    enum Phase: Equatable {
        case idle
        case running(previewURL: URL)
        case succeeded(report: SafariVerificationReport, previewURL: URL)
        case failed(reason: String)
    }

    private(set) var phase: Phase = .idle
    var sheetPresented = false

    private let pass: any SafariVerifying
    private let portProvider: @Sendable () -> Int
    private var inFlight: Task<Void, Never>?

    init(
        pass: any SafariVerifying = SafariVerificationPass(),
        portProvider: @escaping @Sendable () -> Int = { AppSettings.shared.safariMCPBridgePort }
    ) {
        self.pass = pass
        self.portProvider = portProvider
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func openSheet() {
        guard !isRunning else { return }
        phase = .idle
        sheetPresented = true
    }

    /// Cancels any in-flight pass and resets `phase` back to `.idle` — without the reset, closing
    /// the sheet mid-run would leave `phase` stuck at `.running` forever, since `performRun`'s
    /// cancellation guards mean a cancelled task never writes another phase transition. That in
    /// turn would permanently disable `isRunning`-gated call sites (`canRunSafariVerification`,
    /// `openSheet()`) for the rest of the window's session (review finding on #1989).
    func dismissSheet() {
        inFlight?.cancel()
        inFlight = nil
        sheetPresented = false
        phase = .idle
    }

    /// Validates synchronously (a resolvable preview URL) and, only once that succeeds, flips
    /// `phase` to `.running` before spawning the async pass — same synchronous-then-async split
    /// as `AgentReadinessModel.runScan()`, so a caller polling `isRunning` right after calling
    /// this never races the task's own first `phase` write.
    func run(previewURL: URL?) {
        guard !isRunning else { return }
        guard let previewURL else {
            phase = .failed(reason: "Start the preview first — there's no live preview URL to verify yet.")
            return
        }
        phase = .running(previewURL: previewURL)

        inFlight?.cancel()
        inFlight = Task { @MainActor [weak self] in
            await self?.performRun(previewURL: previewURL)
        }
    }

    // MARK: - Private

    private func performRun(previewURL: URL) async {
        do {
            let report = try await pass.run(
                previewURL: previewURL,
                port: portProvider(),
                connectTimeout: NetworkTimeouts.safariMCPBridgeProbe
            )
            guard !Task.isCancelled else { return }
            phase = .succeeded(report: report, previewURL: previewURL)
        } catch let error as SafariVerificationPass.PassError {
            guard !Task.isCancelled else { return }
            phase = .failed(reason: Self.message(for: error))
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(reason: "Couldn't reach the connected Safari session: \(error.localizedDescription)")
        }
    }

    private static func message(for error: SafariVerificationPass.PassError) -> String {
        switch error {
        case .navigateToolUnavailable:
            return "The connected Safari session doesn't support opening the preview page."
        case .navigateFailed(let detail):
            return "Safari couldn't open the preview: \(detail)"
        }
    }
}

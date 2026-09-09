import SwiftUI
import AnglesiteCore

/// SwiftUI-facing wrapper around `BackupCommand`. Mirrors `DeployModel` — drives one backup
/// at a time, exposes the live log stream, the terminal `Phase`, and a single drawer flag.
@MainActor
@Observable
final class BackupModel {
    enum Phase: Equatable {
        case idle
        case running(siteID: String, since: Date)
        case succeeded(commitSHA: String, branch: String, remote: String, duration: TimeInterval)
        case noChanges
        case failed(reason: String, exitCode: Int32?)
        /// The source push gate refused the push (#1959) — rendered by the same
        /// `BlockedDeploySheetView` the deploy uses, with no override.
        case blocked(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning])
    }

    private(set) var phase: Phase = .idle
    /// Captured backup log lines for the current/most-recent run.
    private(set) var logLines: [LogCenter.LogLine] = []
    /// The latest milestone label from the running backup (drives a status line above the log).
    private(set) var currentMilestone: String?

    /// Bound to a slide-up drawer in `SiteWindow`. The view sets this back to false when the
    /// user clicks "Dismiss" — we never auto-close on success because the commit SHA is
    /// worth letting the user see + copy, and on `.noChanges` the user explicitly asked.
    var drawerPresented: Bool = false
    /// Bound to the blocked sheet in `SiteWindow` for the `.blocked` phase (#1959) — dismiss-only,
    /// like `DeployModel.blockedPresented`.
    var blockedPresented: Bool = false

    /// Fires on every phase change — start and terminal alike — with the site id of the run the
    /// transition belongs to (delivered per-run, not captured at wiring time, so a window
    /// replayed onto a different site can't mis-attribute an in-flight backup's outcome).
    /// `SiteWindowModel` wires this to the completion notifier (#526); the model stays
    /// UserNotifications-free.
    @ObservationIgnored var onPhaseTransition: ((_ siteID: String, _ phase: Phase) -> Void)?

    private let command: BackupCommand
    private let logCenter: LogCenter
    private var inFlight: Task<Void, Never>?

    init(
        command: BackupCommand = BackupCommand(),
        logCenter: LogCenter = .shared
    ) {
        self.command = command
        self.logCenter = logCenter
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var logText: String {
        logLines.map(\.text).joined(separator: "\n")
    }

    /// Kicks off a backup. No-op if one is already running.
    func backup(siteID: String, siteDirectory: URL) {
        guard !isRunning else { return }
        inFlight = Task { @MainActor [weak self] in
            await self?.runBackup(siteID: siteID, siteDirectory: siteDirectory)
        }
    }

    func dismissDrawer() {
        drawerPresented = false
    }

    /// The blocked sheet's only action (#1959).
    func dismissBlocked() {
        blockedPresented = false
    }

    /// Set `phase` and notify the transition hook.
    private func transition(siteID: String, to newPhase: Phase) {
        phase = newPhase
        onPhaseTransition?(siteID, newPhase)
    }

    private func runBackup(siteID: String, siteDirectory: URL) async {
        let started = Date()
        transition(siteID: siteID, to: .running(siteID: siteID, since: started))
        logLines = []
        currentMilestone = nil
        drawerPresented = true
        blockedPresented = false

        let source = "backup:\(siteID)"
        let subscription = await logCenter.subscribe()
        let logTask = Task { @MainActor [weak self] in
            for await line in subscription.stream where line.source == source {
                self?.logLines.append(line)
            }
        }

        let result = await command.backup(
            siteID: siteID,
            siteDirectory: siteDirectory,
            onProgress: { [weak self] progress in
                // The callback fires inside BackupCommand's actor isolation; hop to
                // MainActor before touching our @Observable state.
                // last-write-wins: each milestone fully replaces the label, so out-of-order delivery across these hops is benign
                Task { @MainActor in self?.currentMilestone = progress.label }
            }
        )

        subscription.cancel()
        _ = await logTask.value

        currentMilestone = nil
        let duration = Date().timeIntervalSince(started)
        switch result {
        case .succeeded(let sha, let branch, let remote):
            transition(siteID: siteID, to: .succeeded(commitSHA: sha, branch: branch, remote: remote, duration: duration))
        case .noChanges:
            transition(siteID: siteID, to: .noChanges)
        case .failed(let reason, let exit):
            transition(siteID: siteID, to: .failed(reason: reason, exitCode: exit))
        case .blocked(let failures, let warnings):
            // The modal blocked sheet carries the actionable findings; the streaming-log drawer
            // would just be noise behind it (mirrors `DeployModel`'s `.blocked` handling).
            transition(siteID: siteID, to: .blocked(failures: failures, warnings: warnings))
            drawerPresented = false
            blockedPresented = true
        }
    }
}

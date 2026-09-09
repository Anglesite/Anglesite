import Foundation
import AnglesiteCore

/// Owner-facing sentences for the failure kinds `OwnerPhrasing` (AnglesiteCore) classifies —
/// the app-side half of #1963 (decision D1): the primary surface talks about what happened to
/// the owner's *site*, and the raw git/npm/wrangler reason stays available as a technical
/// `detail` for a "Details" disclosure or the Debug pane. Kept here (not in AnglesiteCore) so
/// every sentence goes through `String(localized:)` and lands in the String Catalog.
///
/// Each entry point returns the owner sentence plus the technical detail together so a view
/// can't accidentally render one without having the other to hand.
enum OwnerFacingCopy {
    /// A failure as the owner should see it: `summary` on the primary surface, `detail` behind
    /// a disclosure. `detail` is `nil` when the summary already says everything (e.g. a
    /// cancellation).
    struct Failure: Equatable {
        let summary: String
        let detail: String?
    }

    // MARK: iCloud sync

    /// The sync badge/popover line for a `SyncScheduler.Status.failed(reason:)`.
    static func sync(reason: String) -> Failure {
        let summary: String
        switch OwnerPhrasing.syncKind(for: reason) {
        case .waitingForICloud:
            summary = String(localized: "Waiting for iCloud to finish copying this site's history.")
        case .nothingToSync:
            summary = String(localized: "Nothing to sync yet — this site has no saved changes.")
        case .unsavedEdits:
            summary = String(localized: "Sync will resume once this site's latest edits are saved into its history.")
        case .historyInUnexpectedState:
            summary = String(localized: "This site's history is in an unexpected state, so iCloud sync is paused.")
        case .couldNotCombineChanges:
            summary = String(localized: "Changes made on another Mac couldn't be combined with this one automatically.")
        case .cloudCopyUnreadable:
            summary = String(localized: "The copy of this site's history in iCloud couldn't be read.")
        case .cloudWriteFailed:
            summary = String(localized: "Anglesite couldn't save this site's history to iCloud Drive.")
        case .cloudReadFailed:
            summary = String(localized: "Anglesite couldn't read this site's history from iCloud Drive.")
        case .unknown:
            summary = String(localized: "iCloud sync didn't finish.")
        }
        return Failure(summary: summary, detail: OwnerPhrasing.detail(reason: reason, exitCode: nil))
    }

    // MARK: Backup

    /// The backup drawer / notification line for a `BackupModel.Phase.failed`.
    static func backup(reason: String, exitCode: Int32?) -> Failure {
        let summary: String
        switch OwnerPhrasing.backupKind(for: reason) {
        case .notConnected:
            summary = String(localized: "This site isn't connected to an online backup yet. Use Publish to GitHub to set one up.")
        case .canceled:
            return Failure(summary: String(localized: "Backup canceled."), detail: nil)
        case .uploadFailed:
            summary = String(localized: "Anglesite couldn't send this site's changes to its online backup. Check your connection and GitHub sign-in, then try again.")
        case .recordFailed:
            summary = String(localized: "Anglesite couldn't save this site's changes into its history.")
        case .historyUnreadable:
            summary = String(localized: "Anglesite couldn't read this site's history.")
        case .unknown:
            summary = String(localized: "Backup didn't finish.")
        }
        return Failure(summary: summary, detail: OwnerPhrasing.detail(reason: reason, exitCode: exitCode))
    }

    // MARK: Publish / audit

    /// The deploy drawer / audit sheet / notification line for a failed publish or audit run.
    /// An unrecognized reason is shown as-is (most `DeployModel` reasons are already
    /// owner-phrased), with only the exit code moved out of the primary line.
    static func operation(reason: String, exitCode: Int32?) -> Failure {
        let detail = OwnerPhrasing.detail(reason: reason, exitCode: exitCode)
        switch OwnerPhrasing.operationKind(for: reason) {
        case .buildFailed:
            return Failure(summary: String(localized: "Anglesite couldn't build this site."), detail: detail)
        case .buildInterrupted:
            return Failure(summary: String(localized: "Building this site was interrupted."), detail: detail)
        case .publishRejected:
            return Failure(summary: String(localized: "Cloudflare didn't accept this publish."), detail: detail)
        case .publishInterrupted:
            return Failure(summary: String(localized: "Publishing was interrupted."), detail: detail)
        case .safetyCheckUnavailable:
            return Failure(summary: String(localized: "Anglesite's safety check couldn't run, so nothing was published."), detail: detail)
        case .cloudflareSignInUnreadable:
            return Failure(summary: String(localized: "Anglesite couldn't read your Cloudflare sign-in. Sign in again in Settings."), detail: detail)
        case .canceled:
            return Failure(summary: String(localized: "Canceled."), detail: nil)
        case .unknown:
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only the exit code was hidden — surface it as the detail so it isn't lost.
            return Failure(summary: trimmed, detail: detail == trimmed ? nil : detail)
        }
    }

    // MARK: Backup success

    /// "Backed up to GitHub" — the destination as the owner knows it, never the remote URL or
    /// the branch name.
    static func backupDestination(remote: String) -> String {
        OwnerPhrasing.backupDestinationLabel(remote: remote)
    }
}

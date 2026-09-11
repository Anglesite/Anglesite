import Foundation

/// Classifies the raw, tool-phrased failure reasons the site operations produce (`SyncEngine`,
/// `BackupCommand`, `DeployCommand`, `AuditCommand`) into owner-facing kinds, so the primary
/// surface can say what happened to the owner's *site* instead of quoting git, npm, or wrangler
/// (#1963, decision D1 in `docs/specs/2026-09-08-product-direction-review-decisions.md`).
///
/// The raw reason is never thrown away: ``detail(reason:exitCode:)`` folds it (plus the exit
/// code, when there is one) into a single technical line the app keeps under a "Details"
/// disclosure or in the Debug pane for support conversations. This module is deliberately
/// copy-free — `AnglesiteCore` isn't localized, so each kind's owner-facing sentence lives in the
/// app (`OwnerFacingCopy`) where `String(localized:)` puts it in the String Catalog.
///
/// Classification is keyword-based on the reason text the operations emit today; unrecognized
/// reasons fall through to each enum's `unknown` case, which the app renders with a generic
/// sentence and the raw reason under Details. Adding a new raw reason shape to an operation
/// should come with a keyword here (and a test in `OwnerPhrasingTests`).
public enum OwnerPhrasing {
    // MARK: - iCloud sync

    /// Why an iCloud sync pull/push stopped, phrased as consequences for the owner's site.
    public enum SyncKind: String, Equatable, Sendable, CaseIterable {
        /// iCloud hasn't finished downloading the site's history yet — transient.
        case waitingForICloud
        /// The site has no saved history yet, so there's nothing to sync.
        case nothingToSync
        /// The site's latest edits aren't in its history yet; sync resumes once they are.
        case unsavedEdits
        /// The site's history is in a state the sync engine won't touch (detached HEAD).
        case historyInUnexpectedState
        /// Changes from another Mac couldn't be combined automatically.
        case couldNotCombineChanges
        /// The copy of the site's history in iCloud is unreadable (malformed/corrupt artifact).
        case cloudCopyUnreadable
        /// Anglesite couldn't write the site's history into iCloud Drive.
        case cloudWriteFailed
        /// Anglesite couldn't read the site's history from iCloud Drive.
        case cloudReadFailed
        /// Anything else.
        case unknown
    }

    /// Maps a `SyncEngine`/`SyncScheduler` failure reason to a ``SyncKind``.
    public static func syncKind(for reason: String) -> SyncKind {
        let r = reason.lowercased()
        if r.contains("waiting for icloud") { return .waitingForICloud }
        if r.contains("no commits yet") || r.contains("nothing to sync") { return .nothingToSync }
        if r.contains("uncommitted changes") || r.contains("snapshot local changes") { return .unsavedEdits }
        if r.contains("detached-head") || r.contains("detached head") || r.contains("check out a branch") {
            return .historyInUnexpectedState
        }
        if r.contains("couldn't push the result") { return .cloudWriteFailed }
        // "no synced history found yet at source.bundle." names the artifact file, so it must
        // be classified before the corrupt-artifact keywords below see "bundle".
        if r.contains("fetch") || r.contains("no synced history") { return .cloudReadFailed }
        if r.contains("conflict") || r.contains("merge") || r.contains("merged")
            || r.contains("fast-forward") || r.contains("divergence") || r.contains("compare local history")
            || r.contains("checkout failed") {
            return .couldNotCombineChanges
        }
        if r.contains("packfile") || r.contains("bundle") || r.contains("signature")
            || r.contains("corrupt") || r.contains("truncated") || r.contains("malformed")
            || r.contains("verification") || r.contains("unsupported") || r.contains("no refs") {
            return .cloudCopyUnreadable
        }
        if r.contains("sync directory") || r.contains("write the sync artifact")
            || r.contains("capture this site's history") {
            return .cloudWriteFailed
        }
        if r.contains("read or write the sync artifact") || r.contains("couldn't read") {
            return .cloudReadFailed
        }
        return .unknown
    }

    // MARK: - Backup

    /// Why a backup (commit + push to the site's online copy) stopped.
    public enum BackupKind: String, Equatable, Sendable, CaseIterable {
        /// The site has no online backup destination yet (no repository / no `origin`).
        case notConnected
        /// The owner canceled.
        case canceled
        /// The site's changes couldn't be sent to the online backup (`git push`).
        case uploadFailed
        /// The site's changes couldn't be recorded into its history (`git add` / `git commit`).
        case recordFailed
        /// The site's history couldn't be read (`git rev-parse` / `git status`).
        case historyUnreadable
        /// Anything else.
        case unknown
    }

    /// Maps a `BackupCommand` failure reason to a ``BackupKind``.
    public static func backupKind(for reason: String) -> BackupKind {
        let r = reason.lowercased()
        if r.contains("canceled") || r.contains("cancelled") { return .canceled }
        // The streamed-step labels come first: their stderr tail is appended to the reason and
        // may itself mention `origin` or a branch, which the later keyword groups would misread.
        if r.contains("git push") { return .uploadFailed }
        if r.contains("git commit") || r.contains("git add") { return .recordFailed }
        if r.contains("isn't a git repository") || r.contains("origin") { return .notConnected }
        if r.contains("rev-parse") || r.contains("git status") || r.contains("commit sha")
            || r.contains("current branch") || r.contains("git repository") {
            return .historyUnreadable
        }
        return .unknown
    }

    // MARK: - Publish / audit

    /// Why a publish (deploy) or audit run stopped. Both pipelines share the build step and
    /// its reason shapes, so one enum covers them.
    public enum OperationKind: String, Equatable, Sendable, CaseIterable {
        /// The site's build didn't succeed (`npm run build` non-zero).
        case buildFailed
        /// The build was killed before it finished.
        case buildInterrupted
        /// Cloudflare didn't accept the publish (`wrangler` non-zero / no URL in its output).
        case publishRejected
        /// The publish was killed before it finished.
        case publishInterrupted
        /// Anglesite's pre-publish safety check couldn't run at all.
        case safetyCheckUnavailable
        /// The stored Cloudflare sign-in couldn't be read.
        case cloudflareSignInUnreadable
        /// The owner canceled.
        case canceled
        /// The reason is already owner-phrased (or unrecognized) — show it as-is.
        case unknown
    }

    /// Maps a `DeployCommand`/`AuditCommand` failure reason to an ``OperationKind``.
    public static func operationKind(for reason: String) -> OperationKind {
        let r = reason.lowercased()
        if r.contains("canceled") || r.contains("cancelled") { return .canceled }
        if r.contains("cloudflare api token") { return .cloudflareSignInUnreadable }
        if r.contains("pre-deploy scan") || r.contains("pre-deploy check") { return .safetyCheckUnavailable }
        if r.contains("wrangler") {
            return r.contains("terminated") ? .publishInterrupted : .publishRejected
        }
        if r.contains("build was terminated") { return .buildInterrupted }
        if r.contains("npm run build") || r.contains("build failed") { return .buildFailed }
        return .unknown
    }

    // MARK: - Details

    /// The technical line kept for support: the raw reason, plus the exit code when the
    /// operation had one and the reason doesn't already spell it out. Never shown on the
    /// primary surface — it belongs under a "Details" disclosure or in the Debug pane.
    public static func detail(reason: String, exitCode: Int32?) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let exitCode else { return trimmed }
        // Command-produced reasons often already carry the code ("npm run build failed (exit 1)",
        // "wrangler exited with code 1") — appending it again produced "(exit N) (exit N)" once.
        if trimmed.contains("exit \(exitCode)") || trimmed.contains("code \(exitCode)") { return trimmed }
        return trimmed.isEmpty ? "exit code \(exitCode)" : "\(trimmed) (exit code \(exitCode))"
    }

    // MARK: - Backup destination

    /// A short label for where a backup went, from the `origin` remote URL: the host the owner
    /// signed in to ("GitHub"), not the URL (`https://github.com/me/site.git`) or the git
    /// remote/branch pair. Unrecognized hosts fall back to their hostname; an unparseable
    /// remote (SSH shorthand, local path) falls back to the raw string.
    public static func backupDestinationLabel(remote: String) -> String {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let host: String?
        if let url = URL(string: trimmed), let h = url.host, !h.isEmpty {
            host = h
        } else if let at = trimmed.firstIndex(of: "@"), let colon = trimmed[at...].firstIndex(of: ":") {
            // git@github.com:me/site.git
            host = String(trimmed[trimmed.index(after: at)..<colon])
        } else {
            host = nil
        }
        guard let host else { return trimmed }
        let lowered = host.lowercased()
        if lowered == "github.com" || lowered.hasSuffix(".github.com") { return "GitHub" }
        if lowered == "gitlab.com" || lowered.hasSuffix(".gitlab.com") { return "GitLab" }
        if lowered == "codeberg.org" { return "Codeberg" }
        return host
    }
}

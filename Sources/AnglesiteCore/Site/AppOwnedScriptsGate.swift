import Foundation

/// Deploy-time integrity check for the app-owned script set (owner decision **D5**, 2026-09-08;
/// #1958). The pre-deploy gate the app runs before every publish is
/// `scripts/pre-deploy-check.ts` *from the site's own copy* — together with every other file
/// `TemplateScriptsManifest` lists (`scripts/*`, and the `src/lib/*` modules the gate imports).
/// Site-open sync (#1053/#1962) keeps those files current, but nothing between an open and a
/// deploy stopped an agent with write access to the site from rewriting the gate and then
/// deploying through a scan that no longer scans. This type closes that: immediately before a
/// deploy, every app-owned file is compared against the copy the running app ships, and any
/// mismatch **refuses the deploy**, restores the app's copy, commits the restore, and tells the
/// owner in owner terms. There is no keep-mine and no override — the same non-bypassable posture
/// as the scan itself (CLAUDE.md "The app cannot bypass the pre-deploy security gate").
///
/// Two copies are checked, because two exist:
///
/// - the **host** copy — the site's `Source/` git repo, the canonical one (#72). Compared byte
///   for byte against the app's template; a mismatch is restored on disk, re-baselined in
///   `Config/` (so the next site open doesn't re-flag it), and committed under
///   ``commitMessage`` so the owner's history records what happened.
/// - the **runtime** copy — wherever the deploy's executor actually runs the scan (a container's
///   `/workspace/site` clone, which an in-guest agent can edit without ever touching the host).
///   Reached through ``RuntimeCopy``, which the executor supplies; compared by SHA-256, and
///   restored by writing the app's bytes straight into it. A host-only executor supplies none —
///   its "runtime copy" *is* the host directory.
///
/// The pin is the app's template (`TemplateRuntime.resolve()` — the code-signed bundle, or a
/// template author's Settings override, resolved exactly the way site-open sync resolves it so
/// the two can never disagree about what "the app's copy" is). A template update lands as an
/// app update, never as an edit inside the site.
///
/// One implementation for every deploy path: `DeployCommand.deploy` runs it before anything else,
/// and both the GUI (`DeployModel` → `SocialWorkerProvisionCommand.provision` → `DeployCommand`)
/// and the headless App Intents path (`SiteOperations.deploy` → same) go through that spine.
public enum AppOwnedScriptsGate {
    /// The commit message the host restore lands under, so the owner's history says what happened.
    public static let commitMessage = "chore: restore Anglesite-managed scripts before deploy"

    /// One app-owned file exactly as the app ships it.
    public struct Pin: Sendable, Equatable {
        /// The file's template-relative path (`scripts/pre-deploy-check.ts`, `src/lib/rsl.ts`).
        public let relativePath: String
        /// The app's bytes for it — what a restore writes.
        public let content: Data
        /// Lower-case hex SHA-256 of `content` — what a runtime copy's `sha256sum` must report.
        public let sha256: String

        /// Pins `content` for `relativePath`, computing its digest.
        public init(relativePath: String, content: Data) {
            self.relativePath = relativePath
            self.content = content
            self.sha256 = PortableSHA256.hexDigest(of: content)
        }
    }

    /// Every app-owned file in `templateDirectory` (per `TemplateScriptsManifest`), pinned.
    /// Empty when the manifest finds nothing there — which ``enforce`` treats as unverifiable,
    /// never as "nothing to protect".
    public static func pins(templateDirectory: URL) -> [Pin] {
        TemplateScriptsManifest.appOwnedRelativePaths(templateRoot: templateDirectory).compactMap { relativePath in
            guard let content = try? Data(contentsOf: templateDirectory.appendingPathComponent(relativePath)) else {
                return nil
            }
            return Pin(relativePath: relativePath, content: content)
        }
    }

    /// The per-file comparison result for one copy of the site.
    public struct Verification: Sendable, Equatable {
        /// App-owned files whose copy matches the app's exactly.
        public var intactPaths: [String] = []
        /// App-owned files present but different from the app's copy.
        public var modifiedPaths: [String] = []
        /// App-owned files this copy doesn't have at all.
        public var missingPaths: [String] = []

        /// Creates an empty verification.
        public init() {}

        /// `true` when nothing differs.
        public var isIntact: Bool { modifiedPaths.isEmpty && missingPaths.isEmpty }
        /// Every path that must be restored, sorted for deterministic reporting.
        public var mismatchedPaths: [String] { (modifiedPaths + missingPaths).sorted() }
    }

    /// Compares the host copy in `sourceDirectory` against `pins`, byte for byte. Pure — writes
    /// nothing.
    public static func verify(sourceDirectory: URL, pins: [Pin]) -> Verification {
        var verification = Verification()
        for pin in pins {
            guard let siteContent = try? Data(contentsOf: sourceDirectory.appendingPathComponent(pin.relativePath)) else {
                verification.missingPaths.append(pin.relativePath)
                continue
            }
            if siteContent == pin.content {
                verification.intactPaths.append(pin.relativePath)
            } else {
                verification.modifiedPaths.append(pin.relativePath)
            }
        }
        return verification
    }

    /// Compares a runtime copy's reported digests (`nil`, or absent, for a file it doesn't have)
    /// against `pins`. Pure.
    public static func verify(digests: [String: String?], pins: [Pin]) -> Verification {
        var verification = Verification()
        for pin in pins {
            guard let reported = digests[pin.relativePath], let digest = reported else {
                verification.missingPaths.append(pin.relativePath)
                continue
            }
            if digest.lowercased() == pin.sha256 {
                verification.intactPaths.append(pin.relativePath)
            } else {
                verification.modifiedPaths.append(pin.relativePath)
            }
        }
        return verification
    }

    /// How the gate reaches the copy of the site the deploy's executor actually runs the scan
    /// from — see the type-level doc. Built from a `DeployExecutor` by
    /// `RuntimeCopy.init(executor:source:)` (in `AppOwnedScriptsRuntimeCheck.swift`); tests
    /// inject closures directly.
    public struct RuntimeCopy: Sendable {
        /// What a runtime copy reports for the pinned paths.
        public enum Digests: Sendable, Equatable {
            /// The executor runs steps at the host directory itself — the host verification
            /// already covered the same bytes, so there is nothing more to check.
            case sameAsHost
            /// SHA-256 hex per relative path; `nil` (or absent) means the file is missing.
            case digests([String: String?])
            /// The runtime couldn't answer at all. The deploy must not proceed on a copy the gate
            /// couldn't see; `reason` is diagnostic (the caller phrases it for the owner).
            case failed(reason: String)
        }

        /// Reports the runtime copy's digests for `pins`.
        public let digests: @Sendable ([Pin]) async -> Digests
        /// Writes the app's bytes for `pins` into the runtime copy; `false` when it couldn't.
        public let restore: @Sendable ([Pin]) async -> Bool

        /// Memberwise, for tests and for the executor-backed initializer.
        public init(
            digests: @escaping @Sendable ([Pin]) async -> Digests,
            restore: @escaping @Sendable ([Pin]) async -> Bool
        ) {
            self.digests = digests
            self.restore = restore
        }
    }

    /// The gate's decision for one deploy attempt.
    public enum Outcome: Sendable, Equatable {
        /// Every app-owned file, in every copy checked, matches the app's.
        case intact
        /// The deploy is refused. `restored` were rewritten to the app's copy (in whichever copy
        /// had drifted); `unrestorable` couldn't be written and are still wrong; `committed` is
        /// `false` only when the host restore's git commit failed (a durable retry record is left
        /// in `Config/` when it's known — see `ExistingSiteMigrationCommitter`).
        case blocked(restored: [String], unrestorable: [String], committed: Bool)
        /// The app's own template couldn't be resolved, so there was nothing to verify against.
        /// Not a tamper signal — a broken install, or a test host with no bundle — and logged
        /// loudly rather than silently treated as intact. The deploy proceeds.
        case unverifiable(reason: String)
        /// The runtime copy couldn't be read. The deploy must not proceed — the scan would run on
        /// a copy the gate never saw — but nothing was tampered with as far as the app knows, so
        /// this is a failure to retry, not a refusal to remediate.
        case runtimeUnverifiable(reason: String)
    }

    /// Verifies the host copy (and, when `runtimeCopy` is given, the runtime copy), restores and
    /// commits whatever drifted, logs what happened under `source`, and decides. On any mismatch
    /// the answer is `.blocked` even though the files are now correct — D5's "refuses to deploy
    /// on mismatch": the owner is told their safety check had been changed, and the next publish
    /// runs against the restored copy from a clean start.
    ///
    /// - Parameters:
    ///   - sourceDirectory: The site's `Source/` — the host copy.
    ///   - configDirectory: The site's `Config/`, when the caller knows it; threads the restore
    ///     through the baseline and the pending-commit retry record. `nil` still commits, just
    ///     without those (#530's non-primary deploy paths).
    ///   - templateDirectory: The app's template root, or `nil` when it couldn't be resolved.
    ///   - runtimeCopy: The executor's copy of the site, when it has one of its own.
    ///   - gitCommitBatch: The commit seam — production default, tests record.
    public static func enforce(
        sourceDirectory: URL,
        configDirectory: URL?,
        templateDirectory: URL?,
        runtimeCopy: RuntimeCopy? = nil,
        source: String,
        logCenter: LogCenter = .shared,
        gitCommitBatch: @escaping @Sendable (URL, [String], String) async -> String? = InboxSubmissionCommitter.processGitCommitBatch
    ) async -> Outcome {
        guard let templateDirectory else {
            return await unverifiable(
                "Anglesite couldn't find its own copy of the site scripts to verify against",
                source: source, logCenter: logCenter)
        }
        let pins = pins(templateDirectory: templateDirectory)
        guard !pins.isEmpty else {
            return await unverifiable(
                "Anglesite's template at \(templateDirectory.path) has no app-owned scripts to verify against",
                source: source, logCenter: logCenter)
        }

        // 1. The host copy: the canonical repo. Restore on disk, re-baseline, commit.
        let host = verify(sourceDirectory: sourceDirectory, pins: pins)
        var restored: [String] = []
        var unrestorable: [String] = []
        var committed = true
        if !host.isIntact {
            var baseline = configDirectory.map { TemplateScriptsBaseline.load(from: $0) }
            for relativePath in host.mismatchedPaths {
                guard let pin = pins.first(where: { $0.relativePath == relativePath }) else { continue }
                do {
                    try write(pin, into: sourceDirectory)
                    restored.append(relativePath)
                    // The same hash `TemplateScriptsSyncChecker` computes from the site file, so
                    // the next site open sees a reconciled file rather than re-flagging it.
                    baseline?.files[relativePath] = TemplateScriptsBaseline.Entry(
                        baselineHash: VectorMath.stableHash(String(decoding: pin.content, as: UTF8.self)))
                } catch {
                    unrestorable.append(relativePath)
                    await logCenter.append(
                        source: source, stream: .stderr,
                        text: "couldn't restore \(relativePath): \(error)")
                }
            }
            if let configDirectory, let baseline {
                try? baseline.save(to: configDirectory)
            }
            if !restored.isEmpty {
                if let configDirectory {
                    committed = await ExistingSiteMigrationCommitter.commit(
                        touchedPaths: restored, sourceDirectory: sourceDirectory, configDirectory: configDirectory,
                        message: commitMessage, gitCommitBatch: gitCommitBatch)
                } else {
                    committed = await gitCommitBatch(sourceDirectory, restored, commitMessage) != nil
                }
            }
        }

        // 2. The runtime copy: where the scan actually runs. Checked even when the host was
        //    intact (an in-guest edit never reaches the host) and even when the host was just
        //    restored (the runtime must pick that restore up now, not on some later attempt).
        var runtimeRestored: [String] = []
        var runtimeUnrestorable: [String] = []
        if let runtimeCopy {
            switch await runtimeCopy.digests(pins) {
            case .sameAsHost:
                break
            case .failed(let reason):
                await logCenter.append(
                    source: source, stream: .stderr,
                    text: "couldn't verify the site's scripts in its runtime — deploy not attempted: \(reason)")
                return .runtimeUnverifiable(reason: reason)
            case .digests(let digests):
                let runtime = verify(digests: digests, pins: pins)
                if !runtime.isIntact {
                    let mismatched = runtime.mismatchedPaths
                    let toRestore = pins.filter { mismatched.contains($0.relativePath) }
                    if await runtimeCopy.restore(toRestore) {
                        runtimeRestored = mismatched
                    } else {
                        runtimeUnrestorable = mismatched
                    }
                }
            }
        }

        guard !host.isIntact || !runtimeRestored.isEmpty || !runtimeUnrestorable.isEmpty else {
            return .intact
        }

        var detail = "Anglesite's safety check on this site had been changed — deploy refused."
        if !host.modifiedPaths.isEmpty { detail += " Changed: \(host.modifiedPaths.sorted().joined(separator: ", "))." }
        if !host.missingPaths.isEmpty { detail += " Missing: \(host.missingPaths.sorted().joined(separator: ", "))." }
        if !restored.isEmpty {
            detail += committed ? " Restored and committed." : " Restored, but the commit failed — it will be retried."
        }
        if !unrestorable.isEmpty { detail += " Couldn't restore: \(unrestorable.joined(separator: ", "))." }
        if !runtimeRestored.isEmpty {
            detail += " In the site's runtime, restored: \(runtimeRestored.joined(separator: ", "))."
        }
        if !runtimeUnrestorable.isEmpty {
            detail += " In the site's runtime, couldn't restore: \(runtimeUnrestorable.joined(separator: ", "))."
        }
        await logCenter.append(source: source, stream: .stderr, text: detail)

        return .blocked(
            restored: Array(Set(restored + runtimeRestored)).sorted(),
            unrestorable: Array(Set(unrestorable + runtimeUnrestorable)).sorted(),
            committed: committed)
    }

    /// The owner-facing blocker for a `.blocked` outcome, rendered by the same sheet the scan's
    /// own findings use (`BlockedDeploySheetView`). The primary line names the consequence, not a
    /// path; the paths sit in `detail`, which that sheet shows only behind a Details disclosure
    /// for this category. `nil` for every other outcome.
    public static func scanFailure(for outcome: Outcome) -> PreDeployCheck.ScanFailure? {
        guard case .blocked(let restored, let unrestorable, let committed) = outcome else { return nil }
        let message: String
        let remediation: String
        if unrestorable.isEmpty {
            message = committed
                ? "Anglesite's safety check on this site had been changed. It has been restored."
                : "Anglesite's safety check on this site had been changed. It has been restored, though the change couldn't be recorded in the site's history yet."
            remediation = "Publish again to continue — the restored check will run."
        } else {
            message = "Anglesite's safety check on this site had been changed, and part of it couldn't be restored."
            remediation = "Check that the site's folder is writable, then publish again."
        }
        var detailLines = restored.map { "Restored: \($0)" }
        detailLines += unrestorable.map { "Couldn't restore: \($0)" }
        return PreDeployCheck.ScanFailure(
            category: .appOwnedScriptRestored,
            message: message,
            file: nil,
            detail: detailLines.joined(separator: "\n"),
            remediation: remediation
        )
    }

    /// The owner-facing reason for a `.runtimeUnverifiable` outcome — a failure to retry, not a
    /// refusal. `nil` for every other outcome.
    public static func failureReason(for outcome: Outcome) -> String? {
        guard case .runtimeUnverifiable(let reason) = outcome else { return nil }
        return "Anglesite couldn't confirm this site's safety check is intact (\(reason)) — try publishing again."
    }

    // MARK: Helpers

    private static func unverifiable(_ reason: String, source: String, logCenter: LogCenter) async -> Outcome {
        await logCenter.append(
            source: source, stream: .stderr,
            text: "\(reason) — the deploy proceeds unverified; reinstall Anglesite if this persists.")
        return .unverifiable(reason: reason)
    }

    /// Writes `pin`'s bytes to its path under `sourceDirectory`, creating the directory as needed.
    private static func write(_ pin: Pin, into sourceDirectory: URL) throws {
        let siteURL = sourceDirectory.appendingPathComponent(pin.relativePath)
        try FileManager.default.createDirectory(
            at: siteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pin.content.write(to: siteURL, options: .atomic)
    }
}

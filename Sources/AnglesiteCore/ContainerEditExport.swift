import Foundation

/// Exports one commit from a running container's guest clone as a git bundle and imports it into
/// the host's canonical `Source/` repository — the guest-to-host half of edit persistence
/// (design spec `docs/superpowers/specs/2026-08-03-anywhere-runtime-webrtc-design.md`
/// §Architecture 5). Factored out of `LocalContainerSiteRuntime.persistEdit` so
/// `HelperEditPersister` (Anywhere-runtime P1's Mac helper — no actor lifecycle/generation state
/// of its own; one session per process) can drive the identical guest-export + host-import
/// sequence without depending on that actor. `LocalContainerSiteRuntime` keeps its own
/// generation/activeSiteID/persistence-slot guards *around* a call to this function; this
/// function itself has no opinion about site lifecycle or concurrency — callers own that.
///
/// `LocalContainerSiteRuntime.persistEdit`'s original inline version re-checked its actor's
/// generation *between* the guest exec and the host import, refusing to import into a
/// `siteDirectory` captured before a since-superseded site switch. That check is dropped here
/// deliberately, not by oversight: the `siteDirectory` a caller passes is already a value fixed
/// before the call (never re-read), and `InProcessEditPersistence.importBundle`'s own
/// fast-forward-only precondition (the exported commit's parent must equal the target repo's
/// current HEAD) refuses exactly the case the removed check existed to avoid — a diverged/
/// superseded repository fails there instead, loudly, rather than silently importing into the
/// wrong state.
public enum ContainerEditExport {
    private static let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    /// True when `commit` looks like a plausible (partial or full) git hash: 7–64 hex characters.
    public static func isPlausibleCommit(_ commit: String) -> Bool {
        (7...64).contains(commit.count) && commit.unicodeScalars.allSatisfy { hexDigits.contains($0) }
    }

    /// Runs the guest-side bundle-export script inside `siteID`'s container, then imports the
    /// resulting bundle into `sourceDirectory`. Throws `SiteRuntimePersistenceError` on any
    /// failure — the same taxonomy `LocalContainerSiteRuntime.persistEdit` already surfaces.
    ///
    /// - Parameters:
    ///   - commit: The guest-side commit hash to export. Callers are expected to have already
    ///     checked `isPlausibleCommit` for their own reason string; this function does not
    ///     re-validate the input commit (only the container's *returned* full hash, below).
    ///   - siteID: The container's identity, passed straight to `control.exec`.
    ///   - control: The container backend to `exec` the export script against. Must be the same
    ///     `LocalContainerControl` instance that booted `siteID` — `exec` addresses an in-process
    ///     guest VM handle, not a system-wide registry.
    ///   - sourceDirectory: The host's canonical `Source/` git repository to import into.
    ///   - onLog: Receives the export script's stderr lines as they arrive, plus one final
    ///     `"persisted <commit> to Source"` (`.stdout`) summary line on success. Logs nothing on
    ///     failure — callers own 100% of failure logging, from the thrown error, to their own
    ///     log sink (`LogCenter`, stderr, `os.Logger`, ...).
    ///   - importBundle: The host-side import hop. Defaults to
    ///     `InProcessEditPersistence.importBundle`; injectable so callers can fake the libgit2 hop
    ///     in tests without touching a real repository.
    public static func exportAndImport(
        commit: String,
        siteID: String,
        control: any LocalContainerControl,
        sourceDirectory: URL,
        onLog: @escaping @Sendable (String, LogCenter.Stream) -> Void,
        importBundle: @Sendable (URL, String, URL) async throws -> Void = { bundle, commit, source in
            // Must match InProcessEditPersistence's own `#if canImport(Darwin)` gate exactly —
            // `#if !os(iOS)` is also true on Linux, where that type doesn't exist at all (#1444
            // CI: this compiled on every macOS run, since Darwin and !iOS agree there, and only
            // broke on the Linux portable-target build).
            #if canImport(Darwin)
            try await InProcessEditPersistence.importBundle(bundle, commit: commit, into: source)
            #else
            throw SiteRuntimePersistenceError.syncFailed("edit persistence is unavailable on this platform")
            #endif
        }
    ) async throws {
        // Export exactly the requested commit through stdout as a base64 git bundle. The canonical
        // repo remains mounted read-only, so no guest process can alter its worktree, refs, or hooks.
        let exportScript = #"""
        set -eu
        runtime=/workspace/site
        commit="$1"
        ref=refs/heads/anglesite-persist
        bundle=/tmp/anglesite-persist-$$.bundle
        cleanup() {
          git -C "$runtime" update-ref -d "$ref" >/dev/null 2>&1 || true
          rm -f "$bundle"
        }
        trap cleanup EXIT HUP INT TERM

        full=$(git -C "$runtime" rev-parse "$commit^{commit}")
        git -C "$runtime" update-ref "$ref" "$full"
        if parent=$(git -C "$runtime" rev-parse "$full^" 2>/dev/null); then
          git -C "$runtime" bundle create "$bundle" "$ref" "^$parent"
        else
          git -C "$runtime" bundle create "$bundle" "$ref"
        fi
        printf '%s\n' "$full"
        base64 "$bundle"
        """#

        let result: ContainerExecResult
        do {
            result = try await control.exec(
                siteID: siteID,
                argv: ["sh", "-c", exportScript, "anglesite-export", commit],
                environment: [:],
                workingDirectory: "/workspace/site",
                onOutput: { line, stream in
                    // stdout is the base64 bundle transport, not human-readable diagnostic output.
                    guard stream == .stderr else { return }
                    onLog(line, stream)
                }
            )
        } catch {
            throw SiteRuntimePersistenceError.syncFailed(error.localizedDescription)
        }
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SiteRuntimePersistenceError.syncFailed(
                detail.isEmpty ? "git handoff exited \(result.exitCode)" : detail)
        }

        let outputParts = result.stdout.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard outputParts.count == 2 else {
            throw SiteRuntimePersistenceError.syncFailed("container returned an invalid git bundle")
        }
        let fullCommit = String(outputParts[0])
        guard (40...64).contains(fullCommit.count),
              fullCommit.unicodeScalars.allSatisfy({ hexDigits.contains($0) }),
              let bundleData = Data(base64Encoded: String(outputParts[1]), options: .ignoreUnknownCharacters)
        else {
            throw SiteRuntimePersistenceError.syncFailed("container returned an invalid git bundle")
        }

        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anglesite-persist-\(UUID().uuidString).bundle")
        do {
            try bundleData.write(to: bundleURL, options: .atomic)
        } catch {
            throw SiteRuntimePersistenceError.syncFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        do {
            try await importBundle(bundleURL, fullCommit, sourceDirectory)
            onLog("persisted \(fullCommit) to Source", .stdout)
        } catch {
            throw SiteRuntimePersistenceError.syncFailed(error.localizedDescription)
        }
    }
}

import Foundation

/// The runtime half of #1958's gate (owner decision D5): an executor that runs deploy steps
/// somewhere *other than* the host `Source/` directory — a container's `/workspace/site` clone —
/// has a second copy of the app-owned scripts, and that copy is the one the pre-deploy scan
/// actually executes. `AppOwnedScriptsGate` verifies the host copy itself; it reaches this one
/// through `AppOwnedScriptsGate.RuntimeCopy`, which `DeployCommand` builds from its executor via
/// ``AppOwnedScriptsGate/RuntimeCopy/init(executor:source:)`` below.
///
/// An executor that runs steps at the host directory itself (`HostDeployExecutor`, test fakes)
/// simply doesn't conform — the host verification already covered the only copy there is. An
/// executor with its own copy conforms and answers with that copy's digests, so the gate can
/// refuse a deploy whose scan would have run from a copy nobody verified.
public protocol AppOwnedScriptsRuntimeVerifying: Sendable {
    /// SHA-256 hex digests of `relativePaths` in this executor's copy of the site, keyed by path;
    /// a `nil` value (or an absent key) is a missing file. `.failed` when the copy couldn't be
    /// read — never an empty dictionary standing in for "couldn't look".
    func digestAppOwnedScripts(relativePaths: [String], source: String) async -> AppOwnedScriptsGate.RuntimeCopy.Digests

    /// Writes the app's bytes for `pins` into this executor's copy of the site. `true` only when
    /// every file landed.
    func restoreAppOwnedScripts(_ pins: [AppOwnedScriptsGate.Pin], source: String) async -> Bool
}

public extension AppOwnedScriptsGate.RuntimeCopy {
    /// The runtime copy behind `executor`, or `nil` when the executor runs steps at the host
    /// directory itself and so has no second copy to verify.
    init?(executor: any DeployExecutor, source: String) {
        guard let verifying = executor as? any AppOwnedScriptsRuntimeVerifying else { return nil }
        self.init(
            digests: { pins in
                await verifying.digestAppOwnedScripts(relativePaths: pins.map(\.relativePath), source: source)
            },
            restore: { pins in
                await verifying.restoreAppOwnedScripts(pins, source: source)
            }
        )
    }
}

// MARK: - ContainerDeployExecutor

extension ContainerDeployExecutor: AppOwnedScriptsRuntimeVerifying {
    /// Runs one `sha256sum` over every pinned path in `/workspace/site` (the guest's clone of
    /// `Source/`) and parses its stdout. `sha256sum` exits 1 when any path is missing but still
    /// lists every file it could read, so a path absent from stdout is exactly a missing one; any
    /// other non-zero exit (127: no `sha256sum` in the image) is `.failed`, never "everything is
    /// missing" — that misreading would restore and refuse on every attempt forever.
    public func digestAppOwnedScripts(relativePaths: [String], source: String) async -> AppOwnedScriptsGate.RuntimeCopy.Digests {
        guard !relativePaths.isEmpty else { return .digests([:]) }
        let result: ContainerExecResult
        do {
            result = try await WranglerInvocation.exec(
                control: control, siteID: siteID,
                argv: Self.appOwnedScriptsDigestArgv(relativePaths: relativePaths),
                environment: [:], logCenter: logCenter, source: source)
        } catch {
            return .failed(reason: "couldn't read the site's scripts in its runtime: \(error)")
        }
        guard result.exitCode == 0 || result.exitCode == 1 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(reason: "sha256sum exited \(result.exitCode) in the site's runtime"
                + (detail.isEmpty ? "" : ": \(detail)"))
        }
        return .digests(Self.parseAppOwnedScriptsDigests(result.stdout, relativePaths: relativePaths))
    }

    /// Fast-forwards the guest's clone to the host's HEAD first (best effort — the host copy was
    /// verified or restored and committed just before this, so a clone that was merely behind
    /// becomes clean again rather than dirty), then writes each pin's bytes into place, one
    /// `exec` per file: the bytes travel as a base64 positional parameter (`$1`), and Linux caps
    /// a single argv string at 128 KiB — one file per call keeps the largest app-owned script
    /// (≈64 KiB raw, ≈86 KiB encoded) comfortably under it, where a whole set would not be.
    public func restoreAppOwnedScripts(_ pins: [AppOwnedScriptsGate.Pin], source: String) async -> Bool {
        guard !pins.isEmpty else { return true }
        do {
            _ = try await WranglerInvocation.exec(
                control: control, siteID: siteID,
                argv: Self.appOwnedScriptsSyncArgv,
                environment: [:], logCenter: logCenter, source: source)
        } catch {
            // Best effort: a clone that can't fast-forward (diverged, mid-edit) is still restored
            // file by file below.
        }
        for pin in pins {
            do {
                let result = try await WranglerInvocation.exec(
                    control: control, siteID: siteID,
                    argv: Self.appOwnedScriptsRestoreArgv(pin: pin),
                    environment: [:], logCenter: logCenter, source: source)
                guard result.exitCode == 0 else {
                    await logCenter.append(
                        source: source, stream: .stderr,
                        text: "couldn't restore \(pin.relativePath) in the site's runtime (exit \(result.exitCode))")
                    return false
                }
            } catch {
                await logCenter.append(
                    source: source, stream: .stderr,
                    text: "couldn't restore \(pin.relativePath) in the site's runtime: \(error)")
                return false
            }
        }
        return true
    }

    // MARK: argv

    /// `sha256sum -- <paths…>` in the guest working directory. Paths come from the app's own
    /// manifest, but they're passed as separate argv words all the same — nothing is spliced into
    /// shell text.
    static func appOwnedScriptsDigestArgv(relativePaths: [String]) -> [String] {
        ["sha256sum", "--"] + relativePaths
    }

    /// The best-effort fast-forward that precedes a restore — the same `git pull --ff-only`
    /// `LocalContainerSiteRuntime.syncFromHost` uses.
    static let appOwnedScriptsSyncArgv: [String] = ["git", "pull", "-q", "--ff-only"]

    /// Writes one pin into the guest working directory. The path and the base64 bytes both arrive
    /// as positional parameters (`$1`, `$2`) rather than being interpolated into the script — the
    /// same injection-safety pattern `guestArgv`'s `.bundleUpload` uses — so neither is ever
    /// re-parsed as shell syntax. `mkdir -p` covers a missing parent (a deleted `scripts/`).
    static func appOwnedScriptsRestoreArgv(pin: AppOwnedScriptsGate.Pin) -> [String] {
        let script = """
        dir=$(dirname -- "$1") && mkdir -p -- "$dir" && printf '%s' "$2" | base64 -d > "$1"
        """
        return ["sh", "-c", script, "sh", pin.relativePath, pin.content.base64EncodedString()]
    }

    /// Parses `sha256sum` stdout (`<hex>  <path>` per line; GNU prefixes `*` for binary mode)
    /// into a digest per requested path, `nil` for any path the output doesn't list.
    static func parseAppOwnedScriptsDigests(_ stdout: String, relativePaths: [String]) -> [String: String?] {
        var found: [String: String] = [:]
        for line in stdout.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(where: \.isWhitespace) else { continue }
            let digest = String(line[..<separator])
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { continue }
            var path = line[separator...].drop(while: \.isWhitespace)
            if path.first == "*" { path = path.dropFirst() }
            found[String(path)] = digest.lowercased()
        }
        var digests: [String: String?] = [:]
        for relativePath in relativePaths {
            digests[relativePath] = found[relativePath]
        }
        return digests
    }
}

// Linux/Flatpak-only: resolves document-portal FUSE paths to real host paths before they reach
// podman's bind-mount — cross-platform port design, Flatpak packaging investigation §6
// (docs/superpowers/specs/2026-08-06-flatpak-packaging-investigation.md).
#if canImport(Glibc)
import Foundation

/// Resolves a document-portal FUSE path — what GTK's folder picker (`.folderImporter`) returns
/// when `AnglesiteLinux` is running inside a Flatpak sandbox — to the real host filesystem path
/// backing it, via `org.freedesktop.portal.Documents.Info`.
///
/// Podman, routed through `flatpak-spawn --host` (`PodmanContainerControl.podmanInvocation`),
/// runs as a plain host process entirely outside the Flatpak sandbox. The document portal's FUSE
/// grants are recorded per sandboxed-app-instance, not per Unix UID, so a bind-mount source under
/// the FUSE path — the sandboxed app itself can read it fine — is not the caller the grant was
/// issued to once it's handed to that host-side podman process. Resolving to the real path first
/// sidesteps this entirely: podman then bind-mounts a normal host path it has ordinary
/// filesystem permission to read, no portal involved.
enum DocumentPortalResolution {
    /// Resolves `url` to its real host path if it sits under a document-portal FUSE mount;
    /// returns `url` unchanged otherwise (including whenever `flatpakHostSpawn` is false — the
    /// same `FLATPAK_ID`-driven gate `PodmanContainerControl` uses elsewhere). Outside a Flatpak
    /// sandbox, GTK's folder picker returns real paths directly; there's no document-portal
    /// indirection to resolve, and calling `gdbus` would be pure overhead on every boot.
    ///
    /// The `Info` call itself must go through `flatpak-spawn --host`, exactly like the podman
    /// invocations below it — verified live against a running `xdg-document-portal` (#1293):
    /// calling `Info` from *inside* the sandbox (this process's own D-Bus connection) fails with
    /// `org.freedesktop.portal.Error.NotAllowed: Not allowed in sandbox`, regardless of whether
    /// this app holds the grant for that doc ID. The portal's sandboxed D-Bus proxy filters
    /// `Info` out entirely — it's not a per-grant permission check, so there's no in-sandbox way
    /// to make this call succeed. Running it as a bare host process (the same
    /// `flatpak-spawn --host` escape hatch already granted for podman) sidesteps the filter and
    /// succeeds unconditionally for any doc ID whose string this process knows — an app-agnostic
    /// call, unlike `podmanInvocation`'s, so it takes `flatpakSpawnExecutable` directly rather
    /// than going through `PodmanContainerControl`.
    static func resolveHostPath(
        for url: URL,
        flatpakHostSpawn: Bool,
        supervisor: ProcessSupervisor,
        flatpakSpawnExecutable: URL = URL(fileURLWithPath: "/usr/bin/flatpak-spawn"),
        gdbusExecutable: URL = URL(fileURLWithPath: "/usr/bin/gdbus")
    ) async throws -> URL {
        guard flatpakHostSpawn, let parsed = parseDocumentPortalPath(url.path) else { return url }
        let result = try await supervisor.run(
            executable: flatpakSpawnExecutable,
            arguments: [
                "--host", gdbusExecutable.path,
                "call", "--session",
                "--dest", "org.freedesktop.portal.Documents",
                "--object-path", "/org/freedesktop/portal/documents",
                "--method", "org.freedesktop.portal.Documents.Info",
                parsed.docID,
            ])
        guard result.exitCode == 0, let realTopLevelPath = parseInfoReply(result.stdout) else {
            throw LocalContainerError.bootFailed(
                "couldn't resolve document-portal path for \(url.path) (doc id \(parsed.docID)): "
                    + (result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        var resolved = URL(fileURLWithPath: realTopLevelPath)
        for component in parsed.remainder { resolved.appendPathComponent(component) }
        return resolved
    }

    /// Pure parse of a document-portal FUSE path into its document ID and the path components
    /// that follow the originally-granted top-level item — e.g.
    /// `/run/flatpak/doc/63a3dc48/MySite.anglesite/Source` parses to
    /// `(docID: "63a3dc48", remainder: ["Source"])`. `Info(docID)` resolves to that top-level
    /// item's own real path (confirmed live against a running `xdg-document-portal`, #1293), so
    /// the remainder is what `resolveHostPath` appends back on.
    ///
    /// Recognizes both document-portal mount conventions: the in-sandbox alias
    /// (`/run/flatpak/doc/...`) and the host-visible mount (`/run/user/<uid>/doc/...`). Anchored
    /// on these specific prefixes rather than a bare `doc` path-segment search, so a real
    /// directory that happens to be named `doc` (unreachable today — this manifest grants no
    /// `--filesystem`, only document-portal access — but not guaranteed forever) can't be
    /// mistaken for a portal path. Returns `nil` for anything else, including every path outside
    /// a Flatpak sandbox.
    static func parseDocumentPortalPath(_ path: String) -> (docID: String, remainder: [String])? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let docSegmentIndex: Int?
        if components.count > 2, components[0] == "run", components[1] == "flatpak", components[2] == "doc" {
            docSegmentIndex = 2
        } else if components.count > 3, components[0] == "run", components[1] == "user",
            Int(components[2]) != nil, components[3] == "doc"
        {
            docSegmentIndex = 3
        } else {
            docSegmentIndex = nil
        }
        // Needs at least <doc_id>/<name> after the "doc" segment — the originally-granted item.
        guard let docSegmentIndex, docSegmentIndex + 2 < components.count else { return nil }
        let docID = components[docSegmentIndex + 1]
        let remainder = Array(components[(docSegmentIndex + 3)...])
        return (docID, remainder)
    }

    /// Parses `gdbus call`'s GVariant "print" output for `Info`'s `(ay path, a{sas} apps)`
    /// reply — `(b'/real/host/path', {})` for a NUL-terminated byte-array path. Confirmed live
    /// against a running `xdg-document-portal` (#1293): `g_variant_print` renders a
    /// NUL-terminated byte array as a `b'...'` bytestring literal rather than a raw byte list.
    /// Returns `nil` on any unexpected shape rather than guessing.
    static func parseInfoReply(_ output: String) -> String? {
        guard let openQuote = output.range(of: "b'"),
            let closeQuote = output.range(of: "'", range: openQuote.upperBound..<output.endIndex)
        else { return nil }
        let path = String(output[openQuote.upperBound..<closeQuote.lowerBound])
        return path.isEmpty ? nil : path
    }
}
#endif

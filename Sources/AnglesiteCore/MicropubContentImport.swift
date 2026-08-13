// Sources/AnglesiteCore/MicropubContentImport.swift
import Foundation

/// One-time, idempotent import of a site's existing typed content files into D1, run the first
/// time a CMS-mode session becomes available for a provisioned site (spec §C.7). Uses the same
/// `MicropubClient.create` write path interactive saves use — never a direct D1 write — so
/// imported posts are validated by `@dwk/micropub` exactly like any other create. See
/// docs/superpowers/plans/2026-08-12-cms-mode-mac-save-path-and-content-import.md for why this
/// doesn't run inside `SocialWorkerProvisionCommand.provision()` directly.
///
/// Scope is deliberately the **typed content** system only — every `ContentTypeRegistry`
/// descriptor with `.collection` storage (`note`, `article`, `photo`, …). The template's
/// separate, untyped `blog` collection (`Resources/Template/src/content.config.ts`) predates the
/// content-type registry and has no `ContentTypeDescriptor`/mf2 projection to import through.
public enum MicropubContentImport {
    /// Imports every typed content file under `siteDirectory` not already present in
    /// `Config/micropubSync.json`, via `client.create`. Returns the number of files imported
    /// (0 if none are pending). Never throws: a single file's create failure is logged to
    /// `LogCenter` and the import continues with the rest, so one bad file can't block an
    /// otherwise-successful one-time migration.
    ///
    /// - Parameters:
    ///   - siteDirectory: The site's `Source/` directory (contains `src/content/<collection>/`).
    ///   - configDirectory: The site's `Config/` directory, where `micropubSync.json` lives.
    ///   - client: The Micropub client to create posts through — the same one interactive saves
    ///     use, so imported posts go through identical server-side validation.
    ///   - registry: The content-type registry to enumerate `.collection`-stored descriptors
    ///     from; defaults to the shared built-in catalog.
    /// - Returns: The number of files newly imported this call.
    public static func importIfNeeded(
        siteDirectory: URL, configDirectory: URL, client: MicropubClient,
        registry: ContentTypeRegistry = .default
    ) async -> Int {
        var syncState = MicropubContentCommitter.readSyncState(from: configDirectory)
        let alreadySynced = Set(syncState.values)
        var importedCount = 0

        for descriptor in registry.all where descriptor.collection != nil {
            for fileURL in filesForImport(descriptor: descriptor, siteDirectory: siteDirectory) {
                let relPath = relativePath(of: fileURL, under: siteDirectory)
                guard !alreadySynced.contains(relPath) else { continue }
                guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let values = TypedContentEditor.read(contents, descriptor: descriptor)
                let status: MicropubPostStatus = values["draft"] == .flag(true) ? .draft : .published
                let properties = MicropubComposerProjection.properties(
                    for: descriptor, values: values, status: status)
                do {
                    let url = try await client.create(MicropubPost(properties: properties))
                    syncState[url.absoluteString] = relPath
                    importedCount += 1
                } catch {
                    await LogCenter.shared.append(
                        source: "MicropubContentImport", stream: .stderr,
                        text: "Skipping \(relPath): \(error.localizedDescription)")
                }
            }
        }
        if importedCount > 0 {
            try? MicropubContentCommitter.writeSyncState(syncState, to: configDirectory)
        }
        return importedCount
    }

    /// Every file under `siteDirectory`'s `src/content/<collection>/` for `descriptor`, matching
    /// the Astro template's own `content.config.ts` loader pattern (`glob({ pattern: "**/*.md" })`
    /// for every typed collection — `.mdx` is not part of that pattern, so this doesn't look for
    /// it either). Sorted for deterministic import order; an absent collection directory (no
    /// instances of this type yet) yields `[]` rather than an error.
    private static func filesForImport(
        descriptor: ContentTypeDescriptor, siteDirectory: URL, fileManager: FileManager = .default
    ) -> [URL] {
        guard let collection = descriptor.collection else { return [] }
        let dir = siteDirectory.appendingPathComponent("src/content/\(collection)", isDirectory: true)
        return walk(dir, fileManager: fileManager)
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.path < $1.path }
    }

    /// Recursively collects every file under `dir`. Mirrors `ContentScanner`'s private `walk`
    /// helper (not reusable across files — it's `private`), kept small since this is the only
    /// caller.
    private static func walk(_ dir: URL, fileManager: FileManager) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                files.append(contentsOf: walk(entry, fileManager: fileManager))
            } else {
                files.append(entry)
            }
        }
        return files
    }

    /// POSIX path of `url` relative to `base` (forward slashes, no leading slash) — the
    /// `Source/`-relative path shape `Config/micropubSync.json` persists. Falls back to the bare
    /// filename if `url` isn't actually under `base` (shouldn't happen given how this is called).
    private static func relativePath(of url: URL, under base: URL) -> String {
        let urlComponents = url.standardizedFileURL.pathComponents
        let baseComponents = base.standardizedFileURL.pathComponents
        guard urlComponents.starts(with: baseComponents) else { return url.lastPathComponent }
        return urlComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }
}

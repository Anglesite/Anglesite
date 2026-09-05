// Sources/AnglesiteCore/Social/MicropubContentImport.swift
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
    /// A non-zero return does **not** by itself mean every pending file made it in — a per-file
    /// failure (a caught `client.create` error, or an unreadable file skipped below) simply
    /// leaves that file out of the count and off the sync map, with no error surfaced to the
    /// caller. Callers that need to know whether anything is still pending afterward (e.g. before
    /// persisting a one-time "import completed" flag) should follow up with
    /// `unsyncedFileCount(siteDirectory:configDirectory:registry:)` rather than inferring it from
    /// this return value.
    ///
    /// - Parameters:
    ///   - siteDirectory: The site's `Source/` directory (contains `src/content/<collection>/`).
    ///   - configDirectory: The site's `Config/` directory, where `micropubSync.json` lives.
    ///   - client: The Micropub client to create posts through — the same one interactive saves
    ///     use, so imported posts go through identical server-side validation.
    ///   - registry: The content-type registry to enumerate `.collection`-stored descriptors
    ///     from; defaults to the shared built-in catalog.
    /// - Returns: The number of files newly imported this call. Not a completion signal on its
    ///   own — see `unsyncedFileCount` above.
    public static func importIfNeeded(
        siteDirectory: URL, configDirectory: URL, client: MicropubClient,
        registry: ContentTypeRegistry = .default
    ) async -> Int {
        var syncState = MicropubContentCommitter.readSyncState(from: configDirectory)
        var importedCount = 0

        let pending = pendingFiles(
            siteDirectory: siteDirectory, alreadySynced: Set(syncState.values), registry: registry)
        for (fileURL, relPath, descriptor) in pending {
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let values = TypedContentEditor.read(contents, descriptor: descriptor)
            let status: MicropubPostStatus = values["draft"] == .flag(true) ? .draft : .published
            let properties = MicropubComposerProjection.properties(
                for: descriptor, values: values, status: status)
            await warnAboutUnmappedFields(descriptor: descriptor, values: values, relPath: relPath)
            do {
                let url = try await client.create(MicropubPost(properties: properties))
                syncState[url.absoluteString] = relPath
                importedCount += 1
                // Persisted immediately, not batched to the end of the loop: `client.create`
                // just above is a remote, non-idempotent side effect (it always creates a new
                // post), so if the process is interrupted before the next iteration, the sync
                // state for every post already created so far must already be on disk — or the
                // next run re-imports (and re-`create`s, publishing a duplicate) every file that
                // actually succeeded. Imports are a rare, one-time operation, so the extra
                // per-file disk write is negligible.
                try? MicropubContentCommitter.writeSyncState(syncState, to: configDirectory)
            } catch {
                await LogCenter.shared.append(
                    source: "MicropubContentImport", stream: .stderr,
                    text: "Skipping \(relPath): \(error.localizedDescription)")
            }
        }
        return importedCount
    }

    /// Counts typed content files under `siteDirectory` that are **not yet** recorded in
    /// `Config/micropubSync.json` — i.e. still pending import. Does no importing and never fails;
    /// an unreadable directory just contributes `0`, same as `filesForImport`.
    ///
    /// This is the "did the import actually finish" check `importIfNeeded`'s own `Int` return
    /// can't provide by itself: that function catches and logs per-file failures rather than
    /// propagating them (see its doc comment), so a `client.create` failure — expired token,
    /// unreachable endpoint, network down mid-import — silently leaves the file off the sync map
    /// instead of surfacing as an error. A caller deciding whether it's safe to persist a one-time
    /// "import completed" flag should call `importIfNeeded` and then check
    /// `unsyncedFileCount(...) == 0`, not just that `importIfNeeded` returned without throwing.
    ///
    /// - Parameters:
    ///   - siteDirectory: The site's `Source/` directory (contains `src/content/<collection>/`).
    ///   - configDirectory: The site's `Config/` directory, where `micropubSync.json` lives.
    ///   - registry: The content-type registry to enumerate `.collection`-stored descriptors
    ///     from; defaults to the shared built-in catalog.
    /// - Returns: The number of typed content files still awaiting import.
    public static func unsyncedFileCount(
        siteDirectory: URL, configDirectory: URL, registry: ContentTypeRegistry = .default
    ) -> Int {
        let syncState = MicropubContentCommitter.readSyncState(from: configDirectory)
        return pendingFiles(
            siteDirectory: siteDirectory, alreadySynced: Set(syncState.values), registry: registry
        ).count
    }

    /// Every typed content file under `siteDirectory` not already listed in `alreadySynced` (a
    /// set of `Source/`-relative paths, as stored in `Config/micropubSync.json`'s values), paired
    /// with its relative path and the descriptor it was enumerated under. Shared by
    /// `importIfNeeded` (which imports each one) and `unsyncedFileCount` (which only counts them),
    /// so the two can never disagree about what "pending" means.
    private static func pendingFiles(
        siteDirectory: URL, alreadySynced: Set<String>, registry: ContentTypeRegistry
    ) -> [(fileURL: URL, relPath: String, descriptor: ContentTypeDescriptor)] {
        var result: [(URL, String, ContentTypeDescriptor)] = []
        for descriptor in registry.all where descriptor.collection != nil {
            for fileURL in filesForImport(descriptor: descriptor, siteDirectory: siteDirectory) {
                let relPath = relativePath(of: fileURL, under: siteDirectory)
                guard !alreadySynced.contains(relPath) else { continue }
                result.append((fileURL, relPath, descriptor))
            }
        }
        return result
    }

    /// Logs a warning for any field in `values` that carries content but has no Micropub wire
    /// form — so an import that silently drops part of a post at least leaves a trace, rather than
    /// the file simply disappearing from what the imported post says. Two distinct gaps, both
    /// pre-existing in `MicropubComposerProjection` (see its `properties(for:)` and `mf2Values`
    /// doc comments):
    /// - A field the descriptor declares no `microformatProperties` entry for at all.
    /// - `.objectArray` fields: `mf2Values` always returns `nil` for `.records`, regardless of
    ///   whether the descriptor maps the field — no built-in collection-stored type has ever
    ///   needed nested mf2 objects, so that direction was never built.
    ///
    /// This does **not** cover the case where a mapped `.image`/`.imageArray` field's value is a
    /// site-relative media path rather than a hosted URL — that value does reach the wire (as
    /// whatever string the file has), it just isn't uploaded through `client.uploadMedia` first.
    /// Adding that is real scope (a media-upload pass over the import), out of scope for a log
    /// warning; flagged as a fast-follow rather than silently addressed here.
    ///
    /// - Parameters:
    ///   - descriptor: The content type `values` was decoded against.
    ///   - values: The file's decoded per-field values.
    ///   - relPath: The file's `Source/`-relative path, named in the log line.
    private static func warnAboutUnmappedFields(
        descriptor: ContentTypeDescriptor, values: TypedContentEditor.Values, relPath: String
    ) async {
        let dropped = unmappedFieldsWithValues(descriptor: descriptor, values: values)
        guard !dropped.isEmpty else { return }
        await LogCenter.shared.append(
            source: "MicropubContentImport", stream: .stderr,
            text:
                "\(relPath): field(s) \(dropped.joined(separator: ", ")) have no Micropub wire "
                + "mapping and will be dropped from the imported post")
    }

    /// The names of `descriptor`'s fields (excluding `draft`, which intentionally has no mf2
    /// property of its own — see `MicropubComposerProjection.properties(for:)`) that hold a
    /// non-empty value but produce no property on the wire, per `warnAboutUnmappedFields`'s two
    /// gaps. Reuses `MicropubComposerProjection.mf2Values`/`rawMf2Property` rather than
    /// reimplementing their per-kind emptiness rules, so this can never drift from what
    /// `properties(for:)` actually omits.
    private static func unmappedFieldsWithValues(
        descriptor: ContentTypeDescriptor, values: TypedContentEditor.Values
    ) -> [String] {
        descriptor.fields.compactMap { field -> String? in
            guard field.name != "draft", let value = values[field.name] else { return nil }
            if case .records(let rows) = value, !rows.isEmpty {
                // `.objectArray` has no wire form at all, mapped or not.
                return field.name
            }
            guard descriptor.projections.rawMf2Property(forField: field.name) == nil else { return nil }
            guard MicropubComposerProjection.mf2Values(for: value, kind: field.kind) != nil else { return nil }
            return field.name
        }
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

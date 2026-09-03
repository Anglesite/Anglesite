// Sources/AnglesiteApp/TypedEntryEditorModel.swift
import Foundation
import SwiftUI
import Observation
import AnglesiteCore
import AnglesiteIOS

/// Editor state for one open *typed* content file. Parallels `FileEditorModel` but exposes the
/// file as per-field `TypedContentEditor.Values` (bound by `TypedEntryEditorView`) and commits each
/// save to git. The raw loaded `contents` is retained so writes go through
/// `TypedContentEditor.write`, which preserves untouched keys, unknown keys, and the body verbatim.
/// All disk IO runs off the main actor.
@MainActor
@Observable
final class TypedEntryEditorModel: InspectorEditorModel {
    /// Resolves a ready-to-use `MicropubClient` for `siteID`/`sourceDirectory`, or `nil` when no
    /// CMS-mode session has been onboarded for this site yet (Task A2's connect sheet never ran,
    /// or the stored session was signed out). Injectable so `save()`'s CMS-mode branch is
    /// unit-testable without touching the real Keychain or network.
    typealias MicropubClientFactory = MicropubSessionResolver.Factory

    /// Delegates to ``MicropubSessionResolver/defaultFactory(sessions:)`` — the same resolution
    /// `RestrictedPostPublisher` (#1566) uses, kept in exactly one place. `nonisolated` (rather
    /// than implicitly `@MainActor`, like every other member of this class) because `init`'s
    /// default-argument expressions run in a nonisolated context, not the initializer body's —
    /// this is what `init` calls to build its own default.
    private nonisolated static func defaultMicropubClientFactory(
        sessions: StoredMicropubSessions = StoredMicropubSessions()
    ) -> MicropubClientFactory {
        MicropubSessionResolver.defaultFactory(sessions: sessions)
    }

    let file: FileRef
    let descriptor: ContentTypeDescriptor
    let route: String
    /// Command/find seam for the body field's markdown editor.
    let markdownController = MarkdownEditorController()
    private let sourceDirectory: URL
    /// The site's `Config/` directory, or `nil` for a call site with no CMS-mode context (rare —
    /// every real site window has one). Read in `save()` to check `CMSModeStatus.isProvisioned`.
    private let configDirectory: URL?
    /// The site's stable marker UUID string (`SiteStore.Site.id`), or `nil` alongside
    /// `configDirectory`. Needed to resolve a Micropub session/credential for this site.
    private let siteID: String?
    private let makeMicropubClient: MicropubClientFactory
    private let gitCommit: NativeContentOperations.GitCommit

    var values: TypedContentEditor.Values = .init()
    private var savedValues: TypedContentEditor.Values = .init()
    var noindexEnabled = false
    private var savedNoindexEnabled = false
    var disallowCrawlEnabled = false
    private var savedDisallowCrawlEnabled = false
    private var fileSession = EditableFileSession()
    private var contents: String { fileSession.savedContents } // last-loaded/saved file text (verbatim base)
    private var numberDrafts: [String: String] = [:]
    /// Guards against a concurrent second `save()` capturing a stale `contents` base while an
    /// earlier save is still in flight (e.g. ⌘S mash, or a teardown flush racing a save). `private(set)`
    /// so `SiteWindowModel.editCommandInFlight` can read it (PR #532 review).
    private(set) var isSaving = false
    private(set) var loadError: String?
    private(set) var isLoading = false
    /// The site's default language tag (from `.site-config`'s `LANG` key), shown as the "Use site
    /// default" label in `LanguagePicker` for `.language` fields. Defaults to `"en"` when the file
    /// is absent or has no `LANG` key, matching `SiteLanguageAsset.parseSettings`'s own default.
    private(set) var siteDefaultLangTag = "en"
    /// Whether this file's site is CMS-mode provisioned — mirrors `save()`'s own branch condition
    /// (`CMSModeStatus.isProvisioned`), so `TypedEntryEditorView` can show a read-only-export banner
    /// without reimplementing the check. Computed once in `load()`, not as a computed `var`: a plain
    /// getter can't `await`, and the underlying check is actor-hopping disk I/O
    /// (`SiteConfigStore.load()`) — calling the synchronous `.read(from:)` instead would block the
    /// main thread, exactly what its own doc comment warns against for a `@MainActor` caller like
    /// this model. Mirrors how `siteDefaultLangTag` above is precomputed the same way.
    private(set) var isCMSMode = false
    var conflictDiskContents: String? {
        get { fileSession.conflictDiskContents }
        set { fileSession.conflictDiskContents = newValue }
    }

    var isDirty: Bool {
        (values != savedValues || noindexEnabled != savedNoindexEnabled || disallowCrawlEnabled != savedDisallowCrawlEnabled)
            && loadError == nil && !isLoading
    }

    init(file: FileRef,
         descriptor: ContentTypeDescriptor,
         route: String,
         sourceDirectory: URL,
         configDirectory: URL? = nil,
         siteID: String? = nil,
         gitCommit: @escaping NativeContentOperations.GitCommit = NativeContentOperations.processGitCommit,
         makeMicropubClient: @escaping MicropubClientFactory = TypedEntryEditorModel.defaultMicropubClientFactory()) {
        self.file = file
        self.descriptor = descriptor
        self.route = route
        self.sourceDirectory = sourceDirectory
        self.configDirectory = configDirectory
        self.siteID = siteID
        self.gitCommit = gitCommit
        self.makeMicropubClient = makeMicropubClient
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let url = file.url
        do {
            var session = fileSession
            let loaded = try await session.load(from: url)
            fileSession = session
            adopt(loaded)
            loadError = nil
            warnIfNoModificationDate(after: "load")
        } catch {
            loadError = error.localizedDescription
        }
        let flags = RobotsConfigFile.flags(for: robotsSource, under: sourceDirectory)
        noindexEnabled = flags.noindex
        savedNoindexEnabled = flags.noindex
        disallowCrawlEnabled = flags.disallowCrawl
        savedDisallowCrawlEnabled = flags.disallowCrawl
        if let config = try? String(contentsOf: sourceDirectory.appendingPathComponent(".site-config"), encoding: .utf8) {
            siteDefaultLangTag = SiteLanguageAsset.parseSettings(from: config).lang
        }
        if let configDirectory,
           let settings = try? await SiteConfigStore(configDirectory: configDirectory).load() {
            isCMSMode = CMSModeStatus.isProvisioned(settings: settings)
        } else {
            isCMSMode = false
        }
    }

    @discardableResult
    func save() async -> Bool {
        guard isDirty, !isSaving else { return true }
        isSaving = true
        defer { isSaving = false }
        // CMS mode (#800): once the site's composed Worker includes Micropub and this window has
        // a resolvable session for it, content writes go through `MicropubClient` instead of
        // file+git — the site's canonical copy moves to the deployed CMS. `SiteConfigStore.load()`
        // (not the synchronous `.read(from:)`) is deliberate: this method runs on the main actor,
        // and `.read(from:)`'s own doc comment warns it blocks the calling thread on disk I/O.
        if let configDirectory, let siteID,
           let settings = try? await SiteConfigStore(configDirectory: configDirectory).load(),
           CMSModeStatus.isProvisioned(settings: settings),
           let client = await makeMicropubClient(siteID, sourceDirectory) {
            return await saveViaMicropub(client: client, configDirectory: configDirectory)
        }
        return await saveViaFile()
    }

    /// The original (pre-CMS-mode) save mechanics: writes the file to disk, applies the robots
    /// side channel, and commits both to git. Also `save()`'s fallback when the site isn't
    /// CMS-mode provisioned or no Micropub session is available yet.
    ///
    /// Commit order is deliberate and predates this task's CMS-mode branch (#800 review, fix
    /// round 1): the entry file's own commit goes first, and the shared `robots-config.json`
    /// commit — conditional on it actually having changed — goes second. `applyRobotsConfig()`
    /// only computes/writes the robots file; it does *not* commit, so that order can be
    /// preserved exactly here rather than folded into one step.
    private func saveViaFile() async -> Bool {
        let descriptor = self.descriptor
        let base = contents
        let edited = values
        let newContents = TypedContentEditor.write(edited, into: base, descriptor: descriptor)
        let url = file.url
        do {
            var session = fileSession
            try await session.save(newContents, to: url)
            fileSession = session
            savedValues = edited
            warnIfNoModificationDate(after: "save")
            let robotsChanged = try applyRobotsConfig()
            await commit()
            if robotsChanged { await commitRobotsConfig() }
            return true
        } catch {
            loadError = String(localized: "Save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// CMS-mode save: projects `values` to mf2 properties (`MicropubComposerProjection`) and
    /// creates or updates the post through `client`, keyed by whether this file's `Source/`-
    /// relative path already has a synced post URL (`Config/micropubSync.json`, Task A4). Deletes
    /// mapped-but-now-absent properties on update — the two-parties concern
    /// `MicropubComposerProjection.mappedProperties(for:)`'s doc comment documents — computed
    /// fresh from the current mapped-property set rather than a cached baseline, since this model
    /// (unlike `PostComposerModel`) doesn't keep one around; deleting an already-absent property
    /// is a harmless no-op server-side.
    ///
    /// Deliberately never touches the local file or git: the CMS's stored copy is now this file's
    /// canonical content, not `Source/`'s — the read-side sync (Task A6/B1) is what reconciles
    /// `Source/` back to it. The robots-config side channel is the one exception, applied
    /// regardless of save path since it's site-wide state, not a per-post mf2 property.
    private func saveViaMicropub(client: MicropubClient, configDirectory: URL) async -> Bool {
        let relPath = relativePath(of: file.url, under: sourceDirectory)
        var syncState = MicropubContentCommitter.readSyncState(from: configDirectory)
        let status: MicropubPostStatus = values["draft"] == .flag(true) ? .draft : .published
        let properties = MicropubComposerProjection.properties(
            for: descriptor, values: values, status: status)
        do {
            if let existingURLString = syncState.first(where: { $0.value == relPath })?.key,
               let existingURL = URL(string: existingURLString) {
                let mapped = Set(MicropubComposerProjection.mappedProperties(for: descriptor))
                let cleared = mapped.subtracting(properties.keys).sorted()
                try await client.update(
                    url: existingURL, replace: properties,
                    delete: cleared.isEmpty ? nil : .properties(cleared))
            } else {
                let post = MicropubPost(properties: properties)
                let newURL = try await client.create(post)
                syncState[newURL.absoluteString] = relPath
                // Best-effort (#800 review, fix round 1): the remote post already exists once
                // `create` returns, so a failure persisting this local URL↔path bookkeeping must
                // not fail the save itself — the user's edit already took effect. A lost write
                // here only means the next save's create-vs-update lookup misses and creates a
                // second post, the same tradeoff `MicropubContentCommitter.commit()` already
                // accepts for this exact class of problem (its own `writeSyncState` calls are
                // `try?` too, for the same reason).
                try? MicropubContentCommitter.writeSyncState(syncState, to: configDirectory)
            }
            savedValues = values
            let robotsChanged = try applyRobotsConfig()
            if robotsChanged { await commitRobotsConfig() }
            return true
        } catch let error as MicropubError where error.requiresReauthorization {
            loadError = String(localized: "Sign in again to save changes to this site's CMS.")
            return false
        } catch {
            loadError = String(localized: "CMS save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Applies pending noindex/disallowCrawl toggle changes to the shared `robots-config.json`
    /// — writes the file and returns whether it actually changed, but does **not** commit.
    /// Factored out of `saveViaFile`/`saveViaMicropub` because it's independent of which path
    /// wrote the content itself — robots config isn't a per-post mf2 property, so CMS mode
    /// doesn't redirect it. Deliberately split from the commit step (unlike this task's first
    /// pass, #800 review fix round 1): `saveViaFile`'s entry-file commit must land *before* the
    /// robots-config commit, an ordering this method can't own without collapsing that sequence.
    private func applyRobotsConfig() throws -> Bool {
        let robotsChanged = try RobotsConfigFile.apply(
            source: robotsSource, noindex: noindexEnabled, disallowCrawl: disallowCrawlEnabled,
            path: route, under: sourceDirectory
        )
        savedNoindexEnabled = noindexEnabled
        savedDisallowCrawlEnabled = disallowCrawlEnabled
        return robotsChanged
    }

    func flushBeforeLeaving() async -> Bool {
        guard isDirty else { return true }
        var session = fileSession
        let canFlush = await session.canFlushBeforeLeaving(file: file.url, bufferIsDirty: true)
        fileSession = session
        guard canFlush else { return false }
        return await save()
    }

    func checkExternalChange() async {
        guard loadError == nil else { return }
        let dirty = isDirty
        var session = fileSession
        let change = await session.externalChange(at: file.url, bufferIsDirty: dirty)
        fileSession = session
        guard let change else { return }
        switch change {
        case .none:
            break
        case .reloadable(let disk):
            adopt(disk)
        case .conflict(let disk):
            conflictDiskContents = disk
        }
    }

    func keepMyChanges() { fileSession.keepMyChanges() }

    func reloadFromDisk() async {
        var session = fileSession
        guard let disk = await session.reloadFromConflict(file: file.url) else {
            fileSession = session
            return
        }
        fileSession = session
        adopt(disk)
    }

    // MARK: Bindings used by the view

    // Binding closures capture `self` weakly: SwiftUI holds a binding for the view's lifetime, and
    // the model is replaced per selection — `[weak self]` avoids keeping a stale model alive and
    // keeps the closures safe under Swift 6's non-isolated-closure checking.
    func textBinding(_ name: String) -> Binding<String> {
        Binding(get: { [weak self] in if case .text(let s)? = self?.values[name] { return s }; return "" },
                set: { [weak self] in self?.values[name] = .text($0) })
    }
    func boolBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { [weak self] in if case .flag(let b)? = self?.values[name] { return b }; return false },
                set: { [weak self] in self?.values[name] = .flag($0) })
    }
    func dateBinding(_ name: String) -> Binding<Date> {
        Binding(get: { [weak self] in if case .date(let d?)? = self?.values[name] { return d }; return Date(timeIntervalSince1970: 0) },
                set: { [weak self] in self?.values[name] = .date($0) })
    }
    func numberBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { [weak self] in
                guard let self else { return "" }
                if let draft = self.numberDrafts[name] { return draft }
                if case .number(let n?)? = self.values[name] { return Self.displayNumber(n) }
                return ""
            },
            set: { [weak self] raw in
                guard let self else { return }
                self.numberDrafts[name] = raw
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                // Only overwrite the stored value when the draft parses (or is cleared). A mid-edit
                // unparseable draft like "3." must not clobber a previously valid number with nil.
                if trimmed.isEmpty {
                    self.values[name] = .number(nil)
                } else if let parsed = Double(trimmed) {
                    self.values[name] = .number(parsed)
                }
            }
        )
    }
    func listBinding(_ name: String) -> Binding<[String]> {
        Binding(get: { [weak self] in if case .list(let a)? = self?.values[name] { return a }; return [] },
                set: { [weak self] in self?.values[name] = .list($0) })
    }
    func recordsBinding(_ name: String) -> Binding<[[String: TypedContentEditor.FieldValue]]> {
        Binding(get: { [weak self] in if case .records(let r)? = self?.values[name] { return r }; return [] },
                set: { [weak self] in self?.values[name] = .records($0) })
    }
    func noindexBinding() -> Binding<Bool> {
        Binding(get: { [weak self] in self?.noindexEnabled ?? false },
                set: { [weak self] in self?.noindexEnabled = $0 })
    }
    func disallowCrawlBinding() -> Binding<Bool> {
        Binding(get: { [weak self] in self?.disallowCrawlEnabled ?? false },
                set: { [weak self] in self?.disallowCrawlEnabled = $0 })
    }

    /// A collection entry's robots id is its path *relative to the collection root*, extension
    /// stripped (`2026/my-note`), not the bare filename: `src/content.config.ts`'s loaders glob
    /// `**/*.md`, so `notes/2026/foo.md` and `notes/2025/foo.md` would otherwise share one id and
    /// toggling either page's robots settings would silently move the other's (#1093 review).
    /// Known residual: a frontmatter `slug:` override changes the route Astro serves but not this
    /// id — harmless here, since the id only has to be stable and unique per file.
    private var robotsSource: RobotsConfigSource {
        if let collection = descriptor.collection {
            let root = sourceDirectory.appendingPathComponent("src/content/\(collection)", isDirectory: true)
            return .collection(collection, id: relativePath(of: file.url.deletingPathExtension(), under: root))
        }
        return .page(file: relativePath(of: file.url, under: sourceDirectory))
    }

    // MARK: Private

    private func adopt(_ text: String) {
        let read = TypedContentEditor.read(text, descriptor: descriptor)
        values = read
        savedValues = read
        numberDrafts.removeAll()
    }

    /// Formats a number for the editor field: integral values render without a decimal point,
    /// guarding the `Int(_:)` overflow trap for out-of-range magnitudes.
    private static func displayNumber(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 { return String(Int(n)) }
        return String(n)
    }

    /// Surface (in the debug pane) when a file has no modification date after a successful load/save:
    /// `FileDocumentIO.externalChange` keys on mtime, so a `nil` here silently disables external-change
    /// detection for this file. "Logs are sacred" — make it visible rather than failing quietly.
    private func warnIfNoModificationDate(after op: String) {
        guard fileSession.lastModified == nil else { return }
        let path = file.url.path(percentEncoded: false)
        Task {
            await LogCenter.shared.append(
                source: "editor", stream: .stderr,
                text: EditableFileSession.missingModificationDateWarning(after: op, path: path)
            )
        }
    }

    private func commit() async {
        let rel = relativePath(of: file.url, under: sourceDirectory)
        let slug = file.url.deletingPathExtension().lastPathComponent
        _ = await gitCommit(sourceDirectory, rel, "anglesite: edit \(descriptor.id) \(slug)")
    }

    /// `gitCommit` stages exactly one path, so the shared robots config needs its own commit
    /// alongside the entry's — otherwise a toggle leaves the site repo permanently dirty and never
    /// reaches the container build, which clones from committed history (#1093).
    private func commitRobotsConfig() async {
        _ = await gitCommit(sourceDirectory, RobotsConfigFile.relativePath, "anglesite: update robots-config.json")
    }

    /// `hasPrefix` alone is a string check, not a path check: `notes-archive/foo.md` shares
    /// `notes` as a string prefix with a `notes` collection root, so a bare `hasPrefix(r)` would
    /// treat a sibling directory as nested inside `root` and hand back a mangled id (#1093
    /// review). Normalizing `r` to end in `/` before comparing enforces a real path boundary — the
    /// prefix must be followed by a separator (or be an exact match) to count.
    private func relativePath(of url: URL, under root: URL) -> String {
        let u = url.standardizedFileURL.path(percentEncoded: false)
        var r = root.standardizedFileURL.path(percentEncoded: false)
        if !r.hasSuffix("/") { r += "/" }
        guard u.hasPrefix(r) else { return url.lastPathComponent }
        return String(u.dropFirst(r.count)).drop(while: { $0 == "/" }).description
    }

}

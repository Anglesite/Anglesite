import AppKit
import UniformTypeIdentifiers
import AnglesiteCore

/// File-menu / launcher actions that are window-independent. Today this is just the
/// “open an existing package as a site” flow, extracted from `SitesLauncherView.openFolder()`
/// so the File ▸ Open Site… command and the launcher footer share one implementation —
/// in particular the MAS security-scoped-bookmark minting, which must live in exactly one place.
@MainActor
enum SiteActions {
    /// Surfaced when registering a chosen package fails. Carries the package name so callers
    /// get a readable, location-specific message via `localizedDescription` — the regression
    /// that motivated this was a generic “couldn't add the chosen folder” that dropped the name.
    struct ImportError: LocalizedError {
        let folderName: String
        let underlying: Error
        var errorDescription: String? {
            String(localized: "Couldn't add “\(folderName)”: \(underlying.localizedDescription)")
        }
    }

    /// Register an existing `.anglesite` package and (on MAS) mint its security-scoped bookmark —
    /// the ONLY mint call site, shared by every open path: Finder-open (`onOpenURL`), launcher
    /// drag-drop (#524), the Dock menu, File ▸ Open Site… (`pickAndRegisterSite`), and Import
    /// (`importPackage`). `record` reads and validates the marker, throwing a legible error for
    /// non-packages.
    static func registerPackage(at url: URL) async throws -> SiteStore.Site {
        try await registerPackage(AnglesitePackage(url: url))
    }

    /// Variant for callers that already hold a constructed package (Import creates one via
    /// `PackageTransfer` before registering). Every open path funnels through here, which makes
    /// this the natural heal-on-open point (#877): before recording, migrate the package to the
    /// split-repo layout if it still has an embedded `Source/.git` — already-split packages are a
    /// no-op. `siteStore` is an injection seam for tests; production always uses `.shared`.
    static func registerPackage(_ package: AnglesitePackage, siteStore: SiteStore = .shared) async throws -> SiteStore.Site {
        // `migrate`'s file coordination (NSFileCoordinator) can block waiting on iCloud Drive to
        // relinquish the item — run it off the main actor so heal-on-open doesn't stall the UI.
        // `AnglesitePackage` is `Sendable`, so it crosses into the detached task safely.
        try await Task.detached {
            _ = try RepoRelocator.migrate(package: package)
        }.value
        let site = try await siteStore.record(package)
        #if ANGLESITE_MAS
        // The current access grant (open panel, drag, or LaunchServices open) is the only chance
        // to mint a scoped bookmark — persist it now so the grant survives relaunch. Mint from
        // `site.packageURL` (the canonicalized path the store recorded) so the bookmark's path
        // matches what subprocesses are spawned against. Propagate failures (never `try?`): a
        // grantless site silently fails to preview at open.
        let bookmark = try SecurityScopedBookmark.create(for: site.packageURL)
        try await siteStore.setBookmark(bookmark, for: site.id)
        #endif
        return site
    }

    /// Copy a plain Anglesite directory into a package, bootstrap its `Source/` as a committable
    /// git repo, then register the package. Kept separate from the panel flow so the migration
    /// behavior is unit-testable without driving AppKit.
    static func importDirectory(
        _ sourceDir: URL,
        toPackageAt dest: URL,
        displayName: String,
        bootstrapGit: @escaping @Sendable (_ sourceDirectory: URL) async throws -> Void = { sourceDirectory in
            try await RepoBootstrap.live().commitAll(source: sourceDirectory)
        },
        register: @escaping @MainActor @Sendable (_ package: AnglesitePackage) async throws -> SiteStore.Site = { package in
            try await registerPackage(package)
        }
    ) async throws -> SiteStore.Site {
        // The tree copy can be large (it may include node_modules) — run it off the main actor so
        // the import doesn't stall the UI. On failure after the copy created the package, clean up
        // the orphan; a `destinationExists` throw comes from importDirectory itself (before it
        // creates anything), so it lands in the caller's catch and never deletes a pre-existing dir.
        let pkg = try await Task.detached {
            try PackageTransfer.importDirectory(sourceDir, toPackageAt: dest, displayName: displayName)
        }.value
        do {
            try ensureImportGitignore(in: pkg.sourceURL)
            try await bootstrapGit(pkg.sourceURL)
            return try await register(pkg)
        } catch {
            // Git bootstrap or record/bookmark failed after importDirectory wrote the package —
            // remove the orphan (we created it this call) so it isn't left invisible-and-unopenable
            // on disk. If registration persisted the recents entry before a later failure (for
            // example bookmark minting in MAS), unwind that entry too.
            if let marker = try? pkg.readMarker() {
                try? await SiteStore.shared.remove(id: marker.siteID.uuidString)
            }
            try? FileManager.default.removeItem(at: pkg.url)
            throw error
        }
    }

    /// Import can receive a plain, non-git working directory that already has local build output
    /// or secrets. Seed the baseline ignores before `RepoBootstrap.commitAll` stages everything.
    private static func ensureImportGitignore(in sourceDirectory: URL, fileManager: FileManager = .default) throws {
        let url = sourceDirectory.appendingPathComponent(".gitignore")
        let required = [
            "node_modules/",
            "dist/",
            ".astro/",
            ".wrangler/",
            ".env*",
        ]
        var existing = fileManager.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8)
            : ""
        let lines = Set(existing.split(whereSeparator: \.isNewline).map(String.init))
        let missing = required.filter { !lines.contains($0) }
        guard !missing.isEmpty else { return }

        if !existing.isEmpty && !existing.hasSuffix("\n") { existing += "\n" }
        if !existing.isEmpty { existing += "\n" }
        existing += "# Local build artifacts and secrets are not committed by Anglesite imports.\n"
        existing += missing.joined(separator: "\n")
        existing += "\n"
        try existing.write(to: url, atomically: true, encoding: .utf8)
    }

    #if ANGLESITE_MAS
    /// Obtain (or reuse) a security-scoped grant to `sitesRoot` under the sandboxed (MAS) build.
    /// Shared by `SitesLauncherView.presentNewSite()` and `importPackage()` below — MAS
    /// security-scoped-bookmark minting lives in exactly one place (see this enum's doc comment).
    /// Returns the started-accessing URL, or nil if the user cancelled the grant panel.
    static func ensureSitesRootAccess(_ sitesRoot: URL) async -> URL? {
        if let data = AppSettings.shared.sitesRootBookmark,
           let resolved = try? SecurityScopedBookmark.resolve(data),
           resolved.url.startAccessingSecurityScopedResource() {
            if resolved.isStale, let fresh = try? SecurityScopedBookmark.create(for: resolved.url) {
                AppSettings.shared.sitesRootBookmark = fresh
            }
            return resolved.url
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = sitesRoot
        panel.prompt = String(localized: "Grant Access")
        panel.message = String(localized: "Choose your Sites folder so Anglesite can create the new site there.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if let data = try? SecurityScopedBookmark.create(for: url) {
            AppSettings.shared.sitesRootBookmark = data
        }
        return url.startAccessingSecurityScopedResource() ? url : nil
    }
    #endif

    /// Everything a scaffolding flow needs before it can build a site: template/theme catalog,
    /// sites-root resolution (with MAS security-scope handling), a name-uniqueness check, and a
    /// ready ``SiteScaffolder``. Shared by `SitesLauncherView`'s New Site/New Community flows and
    /// `importWXR()` (#1636) so the MAS-bookmark-sensitive setup exists in exactly one place.
    @MainActor
    struct ScaffoldingContext {
        let catalog: ThemeCatalog
        let scaffolder: SiteScaffolder
        let templateURL: URL
        let isNameTaken: (String) -> Bool
        /// The security-scoped sites-root URL this call started accessing, under MAS, when the
        /// sites root isn't the app's own iCloud container — `nil` otherwise (iCloud container,
        /// or non-MAS build). The caller owns stopping access on this URL once it's done with it;
        /// `resolveScaffoldingContext()` doesn't stop it itself, since callers need it to outlive
        /// this one call (a wizard sheet stays open across several scaffolding steps).
        let sitesRootAccess: URL?
    }

    /// Resolves everything `ScaffoldingContext` needs: loads the template/theme catalog, resolves
    /// (and, under MAS, grants access to) the sites root, and builds a `SiteScaffolder` wired to
    /// production `ProcessSupervisor`/`GitInitRunner`/`RepoBootstrap`/`SiteStore`.
    ///
    /// `settings`/`bundle` mirror `TemplateRuntime.resolve(settings:bundle:)`'s own test seam
    /// (defaulting to the live app values, same as `SiteWindowModel.resolvedThemeCatalog`) so
    /// tests can point at a fixture template and a fake iCloud-container answer instead of
    /// depending on `Bundle.main` (never the app bundle under `swift test`) or this machine's
    /// real iCloud state.
    ///
    /// `onFailure`, when supplied, is called with a user-facing message on the two failure paths
    /// a caller would otherwise have no way to explain to the user: the template is missing, or
    /// the theme catalog fails to load (both signs of a broken install). It is deliberately NOT
    /// called when the MAS sites-root-access grant panel is cancelled — that's a user choice, not
    /// an error worth surfacing. Defaults to `nil` so callers that don't need this messaging (like
    /// a future `importWXR()`) can omit it.
    ///
    /// - Returns: The context, or `nil` if the template is missing, the catalog fails to load, or
    ///   (under MAS, outside the iCloud container) the user cancels the access-grant panel.
    @MainActor
    static func resolveScaffoldingContext(
        settings: AppSettings = .shared, bundle: Bundle = .main, onFailure: ((String) -> Void)? = nil
    ) async -> ScaffoldingContext? {
        let resolution = TemplateRuntime.resolve(settings: settings, bundle: bundle)
        guard let templateURL = resolution.url else {
            onFailure?("Template not found — can't create a site. Reinstall the app.")
            return nil
        }
        let catalog: ThemeCatalog
        do {
            catalog = try ThemeCatalog.load(templateURL: templateURL)
        } catch {
            onFailure?("Couldn't load themes: \(error.localizedDescription)")
            return nil
        }

        let sitesRoot = settings.sitesRoot
        var sitesRootAccess: URL?
        #if ANGLESITE_MAS
        if settings.sitesRootSource != .iCloudContainer {
            guard let rootScope = await ensureSitesRootAccess(sitesRoot) else { return nil }
            sitesRootAccess = rootScope
        }
        #endif
        try? FileManager.default.createDirectory(at: sitesRoot, withIntermediateDirectories: true)

        try? await SiteStore.shared.load()
        let knownSites = await SiteStore.shared.sites
        let takenSlugs = Set(knownSites.map { SiteSlug.derive(from: $0.name) })
        let isNameTaken: (String) -> Bool = { name in
            takenSlugs.contains(SiteSlug.derive(from: name))
                || FileManager.default.fileExists(atPath: sitesRoot.appendingPathComponent("\(name).anglesite").path)
        }

        let scaffolder = SiteScaffolder(
            sitesRoot: sitesRoot, templateURL: templateURL, catalog: catalog,
            run: { exe, args, cwd in
                try await ProcessSupervisor.shared.run(executable: exe, arguments: args, currentDirectoryURL: cwd)
            },
            gitInit: { sourceDir in try GitInitRunner.run(in: sourceDir) },
            gitCommit: { sourceDir in try await RepoBootstrap.live().commitAll(source: sourceDir) },
            register: { package in
                let site = try await SiteStore.shared.record(package)
                #if ANGLESITE_MAS
                let bm = try SecurityScopedBookmark.create(for: site.packageURL)
                try await SiteStore.shared.setBookmark(bm, for: site.id)
                #endif
                return site
            }
        )
        return ScaffoldingContext(catalog: catalog, scaffolder: scaffolder, templateURL: templateURL,
                                  isNameTaken: isNameTaken, sitesRootAccess: sitesRootAccess)
    }

    /// Pick a plain Anglesite directory, choose where to save the new package, copy it in, and
    /// register the package. Returns the new site, or nil if either panel was cancelled.
    static func importPackage() async throws -> SiteStore.Site? {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = String(localized: "Choose")
        picker.message = String(localized: "Choose an existing Anglesite site folder to import.")
        guard picker.runModal() == .OK, let sourceDir = picker.url else { return nil }

        // NSSavePanel silently ignores a directoryURL that doesn't exist yet and reverts to its
        // last-used location, so create the sites root first — otherwise Import as a fresh
        // install's first action wouldn't default into the Anglesite folder at all (#865). Under
        // the sandbox this can need the same security-scoped grant New Site needs — gate on the
        // declared source, not a write probe (createDirectory reports success for an existing but
        // unwritable directory, so probing alone silently no-ops here — #865 PR review), and hold
        // the scope open for the rest of this function via `defer`.
        let sitesRoot = AppSettings.shared.sitesRoot
        var scopedRootURL: URL?
        defer { scopedRootURL?.stopAccessingSecurityScopedResource() }
        #if ANGLESITE_MAS
        if AppSettings.shared.sitesRootSource != .iCloudContainer {
            guard let rootScope = await ensureSitesRootAccess(sitesRoot) else { return nil }  // user cancelled
            scopedRootURL = rootScope
        }
        #endif
        try? FileManager.default.createDirectory(at: sitesRoot, withIntermediateDirectories: true)

        let name = sourceDir.deletingPathExtension().lastPathComponent
        let save = NSSavePanel()
        save.message = String(localized: "Save the imported site package.")
        save.nameFieldStringValue = "\(name).anglesite"
        save.directoryURL = sitesRoot
        guard save.runModal() == .OK, let dest = save.url else { return nil }

        do {
            return try await importDirectory(sourceDir, toPackageAt: dest, displayName: name)
        } catch {
            throw ImportError(folderName: sourceDir.lastPathComponent, underlying: error)
        }
    }

    /// Export the given site's source tree to a chosen folder, with an opt-in for `.git` history.
    static func exportSource(of site: SiteStore.Site) {
        let save = NSSavePanel()
        save.message = String(localized: "Export this site's source files to a folder.")
        save.nameFieldStringValue = site.name
        let gitToggle = NSButton(checkboxWithTitle: String(localized: "Include Git history (.git)"), target: nil, action: nil)
        gitToggle.state = .off
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        gitToggle.frame = NSRect(x: 12, y: 4, width: 256, height: 20)
        accessory.addSubview(gitToggle)
        save.accessoryView = accessory
        guard save.runModal() == .OK, let dest = save.url else { return }
        let includeGit = gitToggle.state == .on
        let pkgURL = site.packageURL
        // Off-load the copy from the main actor; surface any failure back on main via NSAlert.
        Task.detached {
            do {
                try PackageTransfer.exportSource(of: AnglesitePackage(url: pkgURL), to: dest, includeGit: includeGit)
            } catch {
                await MainActor.run { NSAlert(error: error).runModal() }
            }
        }
    }

    /// Surfaced by `reauthorize(_:)` when the folder picked in the "Locate…" panel isn't the same
    /// package as the site being repaired — guards against silently rebinding a recents entry to
    /// an unrelated package that happens to share a name (#776).
    struct ReauthorizationMismatchError: LocalizedError {
        var errorDescription: String? {
            String(localized: "That's a different site — choose the original package folder instead.")
        }
    }

    /// True when `picked`'s marker UUID matches `expectedID`.
    static func markerMatches(_ picked: AnglesitePackage, expectedID: String) -> Bool {
        (try? picked.readMarker())?.siteID.uuidString == expectedID
    }

    /// Re-grant access to `site` after its security-scoped bookmark stopped resolving (#776 — a
    /// reboot, or a preceding runtime failure, can invalidate the sandbox extension even though
    /// the package on disk is untouched). Prompts an `NSOpenPanel` anchored at the site's
    /// last-known location, confirms the chosen folder is the SAME package by marker UUID (not
    /// just path), then re-registers it through the shared `registerPackage` path — which
    /// re-validates against the just-granted access and mints a fresh bookmark, healing both
    /// `isValid` and `needsReauthorization` for every observer of `SiteStore.changeStream()`.
    ///
    /// - Returns: the healed site, or `nil` if the panel was cancelled.
    /// - Throws: `ImportError` wrapping `ReauthorizationMismatchError` on a mismatched pick, or any
    ///   error from re-registration.
    static func reauthorize(_ site: SiteStore.Site) async throws -> SiteStore.Site? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.anglesiteSite]
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = site.packageURL.deletingLastPathComponent()
        panel.prompt = String(localized: "Grant Access")
        panel.message = String(
            localized: "Anglesite lost access to “\(site.name)”, likely after a restart. Locate it again to restore access."
        )
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let package = AnglesitePackage(url: url)
        guard markerMatches(package, expectedID: site.id) else {
            throw ImportError(folderName: url.lastPathComponent, underlying: ReauthorizationMismatchError())
        }
        do {
            return try await registerPackage(package)
        } catch {
            throw ImportError(folderName: url.lastPathComponent, underlying: error)
        }
    }

    /// Surfaced when importing a WXR export fails at any stage — parse, scaffold, or write.
    struct WXRImportError: LocalizedError {
        let fileName: String
        let underlying: Error
        var errorDescription: String? {
            String(localized: "Couldn't import “\(fileName)”: \(underlying.localizedDescription)")
        }
    }

    private struct ScaffoldFailure: LocalizedError {
        /// Kept for logging — not surfaced in `errorDescription`, since `SiteScaffolder`'s step
        /// names (`"creatingFolder"`, `"copyingTemplate"`, …) are internal identifiers, not
        /// owner-facing language.
        let step: String
        let message: String
        var errorDescription: String? { String(localized: "\(message)") }
    }

    /// Parses a WXR (WordPress export) file, scaffolds a fresh site for its content, and writes
    /// the imported posts/pages into it (#1636). Panel-free core — `importWXR()` below drives the
    /// file picker and calls this, mirroring `importDirectory`/`importPackage`'s existing split so
    /// the actual import logic is unit-testable without driving AppKit.
    ///
    /// - Parameters:
    ///   - data: The raw bytes of the `.xml` export file.
    ///   - fileName: The picked file's display name — used as a site-name fallback and in error
    ///     messages.
    ///   - context: A scaffolding context (``resolveScaffoldingContext()``).
    ///   - converter: Converts each entry's HTML body to Markdown (production:
    ///     ``OffscreenHTMLConverter``).
    ///   - assetDownloader: Fetches the images referenced in imported content.
    ///   - commitGit: Lands a commit for the imported content, on top of the scaffold's own
    ///     initial commit, injectable for tests.
    ///   - now: The deterministic clock forwarded to ``ImportTransform``.
    ///   - siteStore: Where the just-scaffolded site is looked up by ID once `context.scaffolder`
    ///     reports `.done` — `context.scaffolder`'s own `register` closure is what actually wrote
    ///     it there (in production, `resolveScaffoldingContext()` registers through
    ///     `SiteStore.shared`, the same store this defaults to). Injectable, matching
    ///     ``registerPackage(_:siteStore:)``'s existing seam above, so tests can exercise a real
    ///     scaffold → register → look-up round trip against an isolated store instead of writing
    ///     to the real, on-disk `~/Library/Application Support/Anglesite/recents.json`.
    /// - Returns: The newly created, already-registered site, and the completed ``ImportReport``
    ///   describing what was written (so a caller can show the owner an import summary).
    /// - Throws: ``WXRImportError`` wrapping whatever stage failed. A failure after scaffolding
    ///   already created and registered the new site removes both the recents entry and the
    ///   package directory before rethrowing, matching ``importDirectory`` below — otherwise a
    ///   failed import would leave a mysterious, contentless site in the launcher.
    static func importWXR(
        data: Data, fileName: String, context: ScaffoldingContext, converter: any ImportHTMLConverter,
        assetDownloader: WXRAssetDownloader = WXRAssetDownloader(),
        commitGit: @escaping @Sendable (_ sourceDirectory: URL) async throws -> Void = { sourceDirectory in
            try await RepoBootstrap.live().commitAll(source: sourceDirectory)
        },
        now: Date = Date(),
        siteStore: SiteStore = .shared
    ) async throws -> (site: SiteStore.Site, report: ImportReport) {
        do {
            let (channel, entries) = try WXRParser.parse(data)
            let (items, extractionProblems) = await WXRRung.items(from: entries, convert: converter)

            var draft = NewSiteDraft(siteType: .blog,
                                     name: Self.candidateSiteName(channel: channel, fileName: fileName,
                                                                  isNameTaken: context.isNameTaken))
            draft.themeID = context.catalog.defaultThemeID(for: .blog)

            var completedSiteID: String?
            for await step in context.scaffolder.scaffold(draft) {
                if case .failed(let stepName, let message) = step {
                    throw ScaffoldFailure(step: stepName, message: message)
                }
                if case .done(let id) = step { completedSiteID = id }
            }
            guard let siteID = completedSiteID,
                  let site = await siteStore.sites.first(where: { $0.id == siteID })
            else {
                throw ScaffoldFailure(step: "registering", message: "Scaffolding finished with no site")
            }

            // From here on, a package has been scaffolded and registered — any further failure
            // must clean up the orphan (recents entry + package directory) before rethrowing,
            // mirroring `importDirectory`'s catch block below. `Data(contentsOf:)`'s caller
            // already moved that read off the main actor; `ImportTransform.run` does its own
            // per-item file I/O for potentially hundreds of posts, so it's detached here too —
            // same reasoning as `importDirectory`'s `Task.detached` around `PackageTransfer`.
            do {
                let imageURLs = items.flatMap(\.images)
                let assetsDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("wxr-import-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: assetsDirectory) }
                let (assets, downloadProblems) = await assetDownloader.download(imageURLs: imageURLs, into: assetsDirectory)

                let resolved = ResolvedContent(items: items, homepage: nil, skippedURLs: [],
                                               problems: extractionProblems + downloadProblems)
                let sourceDirectory = site.sourceDirectory
                let configDirectory = site.configDirectory
                let report = try await Task.detached {
                    try ImportTransform.run(
                        resolved: resolved, assets: assets, assetsDirectory: assetsDirectory,
                        sourceDirectory: sourceDirectory, configDirectory: configDirectory,
                        now: now, onStep: { _ in })
                }.value

                try await commitGit(site.sourceDirectory)
                return (site, report)
            } catch {
                try? await siteStore.remove(id: site.id)
                try? FileManager.default.removeItem(at: site.packageURL)
                throw error
            }
        } catch {
            throw WXRImportError(fileName: fileName, underlying: error)
        }
    }

    /// Site name for the freshly scaffolded package: the WXR channel's title when present,
    /// non-empty, and not already taken; the picked file's basename otherwise; a numbered suffix
    /// (`"Name 2"`, `"Name 3"`, …) if even that collides.
    private static func candidateSiteName(channel: WXRChannel, fileName: String,
                                          isNameTaken: (String) -> Bool) -> String {
        let trimmedTitle = channel.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (trimmedTitle?.isEmpty == false ? trimmedTitle! : nil)
            ?? (fileName as NSString).deletingPathExtension
        guard isNameTaken(base) else { return base }
        var suffix = 2
        while isNameTaken("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    /// Picks a `.xml` file, resolves a scaffolding context, and imports it — the File ▸ Import
    /// WordPress Export (WXR)… menu command's target.
    /// - Returns: the newly created site, or `nil` if the panel was cancelled or the user
    ///   cancelled a MAS sites-root access grant (both silent, non-error dismissals).
    /// - Throws: ``WXRImportError`` if the template is missing, the theme catalog fails to load,
    ///   or parsing/scaffolding/writing the import fails.
    static func importWXR() async throws -> SiteStore.Site? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a WordPress export (WXR) file to import.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        // `onFailure` distinguishes a real setup problem (template missing, catalog load failed —
        // worth an alert) from the MAS access-grant panel simply being cancelled (silent, like the
        // panel above) — `resolveScaffoldingContext` returns `nil` for both, but only calls
        // `onFailure` for the former. Without this, a broken install would make File ▸ Import
        // WordPress Export… silently do nothing, the same gap Task 6's review caught and fixed for
        // the New Site/New Community launcher flows.
        var setupFailureMessage: String?
        guard let context = await resolveScaffoldingContext(onFailure: { setupFailureMessage = $0 })
        else {
            if let setupFailureMessage {
                throw WXRImportError(fileName: url.lastPathComponent,
                                     underlying: ScaffoldFailure(step: "setup", message: setupFailureMessage))
            }
            return nil
        }
        defer { context.sitesRootAccess?.stopAccessingSecurityScopedResource() }

        do {
            // A real WordPress export can be 50-200MB — read it off the main actor so choosing a
            // large file doesn't freeze the UI before the scaffold/convert work even starts.
            let data = try await Task.detached {
                try Data(contentsOf: url)
            }.value
            let (site, report) = try await importWXR(data: data, fileName: url.lastPathComponent, context: context,
                                                      converter: OffscreenHTMLConverter())
            presentImportSummaryAlert(for: report)
            return site
        } catch let error as WXRImportError {
            throw error
        } catch {
            throw WXRImportError(fileName: url.lastPathComponent, underlying: error)
        }
    }

    /// Shows the owner what a completed WXR import brought over — counts by content type, plus
    /// any items that couldn't be brought over cleanly or were deliberately left behind — using
    /// the same owner-language phrasing `ImportSummaryModel` already builds and tests.
    private static func presentImportSummaryAlert(for report: ImportReport) {
        let summary = ImportSummaryModel(plan: report.plan)
        var informativeLines = [summary.countLines.joined(separator: ", ")]
        if let attentionLine = summary.attentionLine { informativeLines.append(attentionLine) }
        if let skippedLine = summary.skippedLine { informativeLines.append(skippedLine) }

        let alert = NSAlert()
        alert.messageText = String(localized: "Import complete")
        alert.informativeText = informativeLines.joined(separator: "\n")
        alert.runModal()
    }

    /// Run the package picker, register the chosen `.anglesite` package with `SiteStore`, and
    /// (on MAS) mint + persist a security-scoped bookmark so the grant survives relaunch.
    ///
    /// - Returns: the newly registered site, or `nil` if the user cancelled the panel.
    /// - Throws: `ImportError` (naming the chosen package) if registration or bookmarking fails.
    static func pickAndRegisterSite() async throws -> SiteStore.Site? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.anglesiteSite]
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Choose an Anglesite site package.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            return try await registerPackage(at: url)
        } catch {
            throw ImportError(folderName: url.lastPathComponent, underlying: error)
        }
    }
}

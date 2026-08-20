import AppIntents
import AnglesiteCore
import Foundation

// MARK: - Dialog formatting (pure, unit-testable)

/// Pure dialog strings for ``AddEffectIntent``. No AppIntents types, so these are fully
/// unit-testable without the AppIntents runtime — same convention as `IntegrationDialogs`
/// (`IntegrationIntents.swift`) and `ContentDialogs` (`EditContentIntent.swift`).
public enum EffectDialogs {
    /// The chosen `EffectAppEnum` case doesn't match any catalog entry's title. Shouldn't happen
    /// at runtime (the enum's cases are meant to track the catalog), but the catalog is loaded
    /// from a file on disk, so a stale enum/manifest pairing is a well-defined failure, not a trap.
    public static func unknownEffect(title: String) -> String {
        "I don't recognize \"\(title)\" as an effect."
    }
    /// The template (and therefore the effects catalog) couldn't be resolved/decoded at all.
    public static func catalogUnavailable() -> String {
        "The effects catalog isn't available right now."
    }
    /// The matched entry has no `placement` (a legacy `@astroanimate/core` micro-animation,
    /// copy-paste only) — there's nothing for click-to-place/`insertBlock` to do with it.
    public static func notPlaceable(effectTitle: String) -> String {
        "\(effectTitle) can't be placed automatically — open it from the Effects gallery in Anglesite instead."
    }
    /// Neither a `PageModelClient` nor an `EditRouter` is registered for the site — its window
    /// isn't open, so there's no live MCP connection to fetch a page model or apply an edit
    /// through (mirrors `EditContentIntent`'s `siteUnavailable` wording).
    public static func siteNotOpen(siteName: String) -> String {
        "Open \(siteName) in Anglesite first, then try adding this effect again."
    }
    /// `get_page_model` failed; `reason` is `PageModelClient.ModelError.friendlyMessage`.
    public static func modelLoadFailed(siteName: String, reason: String) -> String {
        "Couldn't load \(siteName)'s home page: \(reason)"
    }
    /// `defaultInsertion` found no `<body>`/`allowedParents` match to insert against.
    public static func noPlacementFound(effectTitle: String, siteName: String) -> String {
        "I couldn't find a spot for \(effectTitle) on \(siteName)'s home page."
    }
    /// Success dialog once `EditRouter.apply` reports `.applied`.
    public static func applied(effectTitle: String, siteName: String) -> String {
        "Added \(effectTitle) to \(siteName)."
    }
    /// Failure dialog for an apply-stage `.failed`/`.ambiguous`/`.preview` reply; `reason` carries
    /// whichever message the router surfaced.
    public static func failed(effectTitle: String, siteName: String, reason: String) -> String {
        "Couldn't add \(effectTitle) to \(siteName): \(reason)"
    }
}

// MARK: - Add Effect

/// Adds a catalog effect to a site via Siri/Shortcuts, mirroring `AddStoreIntent`'s router
/// pattern (`IntegrationIntents.swift`): plan before confirm, so a missing/ambiguous placement
/// reprompts rather than false-confirming. No live-preview click is available from this front
/// door, so placement is computed deterministically from `entry.placement.kind` via
/// ``defaultInsertion(for:in:)``, then applied through the same fetch → match → `insertBlock` →
/// apply shape `EffectPlacementController` (the in-app click-to-place flow for this same
/// feature, Task 12) uses for a real click.
///
/// Reaching the site's live MCP connection re-uses `EditContentIntent`'s established mechanism —
/// a per-siteID registry populated by `PreviewModel.open()`/`close()` while the site's window is
/// open (`EditRouterRegistry`) — extended here with a `PageModelClient` counterpart
/// (`PageModelClientRegistry`, `AnglesiteCore/PageModelClientRegistry.swift`) since `insertBlock`
/// needs a freshly-fetched `PageModel` for its `baseVersion`/`parentId`/`index`, not just a
/// router to apply the edit through. Like `EditContentIntent`, this means the effect only applies
/// while the target site's window is open — a Siri/Shortcuts invocation while it's closed gets
/// ``EffectDialogs/siteNotOpen(siteName:)`` rather than silently failing.
public struct AddEffectIntent: AppIntent {
    /// Display name in the Shortcuts action library and Siri disambiguation.
    public static let title: LocalizedStringResource = "Add Effect"
    /// Longer explanation shown under the action in the Shortcuts editor.
    public static let description = IntentDescription("Add a visual effect to a site's home page.")

    /// The target site, resolved from the recents registry via ``SiteEntity``'s query.
    @Parameter(title: "Site") public var site: SiteEntity
    /// The catalog effect to add.
    @Parameter(title: "Effect") public var effect: EffectAppEnum
    @Dependency private var catalog: EffectCatalog

    /// AppIntents requires a parameterless initializer; the framework populates `@Parameter`s
    /// after construction.
    public init() {}

    /// Shortcuts-editor sentence: "Add (effect) to (site)".
    public static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$effect) to \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await run()))
    }

    /// Pure(ish) core: resolves the catalog entry, fetches the page model, plans the insertion,
    /// confirms, applies. Shared by `perform()` and `performForTesting()` so the two stay in
    /// lockstep — same shape as `AddStoreIntent.resolvedRoute()` / `confirmAndApplyForTesting()`.
    private func run() async throws -> String {
        // Tests bind EffectCatalogOverride.scoped; production goes through @Dependency —
        // mirrors ApplyThemeIntent's `ThemeCatalogOverride.scoped ?? catalog` exactly
        // (ThemeIntents.swift). A bound override also signals "under test" below, so
        // `requestConfirmation` is skipped.
        let effectCatalog = EffectCatalogOverride.scoped ?? catalog

        guard let entry = effectCatalog.entries.first(where: { $0.title == effect.rawValue }) else {
            return EffectDialogs.unknownEffect(title: effect.rawValue)
        }
        guard entry.placement != nil else {
            return EffectDialogs.notPlaceable(effectTitle: entry.title)
        }

        // Tests bind AddEffectSiteConnectionOverride.scoped; production reads the live
        // per-siteID registries (populated only while the site's window is open).
        let pageModelClient: PageModelClient?
        let editRouter: EditRouter?
        if let connection = AddEffectSiteConnectionOverride.scoped {
            pageModelClient = connection.pageModelClient
            editRouter = connection.editRouter
        } else {
            pageModelClient = await PageModelClientRegistry.shared.pageModelClient(for: site.id)
            editRouter = await EditRouterRegistry.shared.router(for: site.id)
        }
        guard let pageModelClient, let editRouter else {
            return EffectDialogs.siteNotOpen(siteName: site.displayName)
        }

        // No page picker on this front door (v1) -- the home page's *source file*, matching what
        // `SiteWindowModel` resolves for a preview sitting on `/`. It has to be the project-
        // relative `.astro` path, not the route: `get_page_model`'s `validPagePath` and
        // `insertBlock`'s own path check both reject a route outright (#768 final review,
        // Finding 1).
        let path = PageSourcePath.homePage
        let model: PageModel
        do {
            model = try await pageModelClient.fetch(path: path)
        } catch let error as PageModelClient.ModelError {
            return EffectDialogs.modelLoadFailed(siteName: site.displayName, reason: error.friendlyMessage)
        }

        guard let insertion = Self.defaultInsertion(for: entry, in: model) else {
            return EffectDialogs.noPlacementFound(effectTitle: entry.title, siteName: site.displayName)
        }

        // Confirm only once the plan is known-good, mirroring `AddStoreIntent`
        // (`IntegrationIntents.swift`): planning happens *before* the confirmation so a
        // placement failure above reaches the user without them confirming an apply that could
        // never run. Skipped under test (`EffectCatalogOverride.scoped != nil`), same signal
        // `ApplyThemeIntent` reads off `ThemeCatalogOverride.scoped` -- `requestConfirmation`
        // needs the live Siri/Shortcuts runtime, which `swift test` doesn't have. Every `run()`
        // path that reaches this point has already required a bound `EffectCatalogOverride` under
        // test (the entry lookup above depends on it), so this one signal covers the whole method.
        if EffectCatalogOverride.scoped == nil {
            try await requestConfirmation(dialog: "Add \(entry.title) to \(site.displayName)?")
        }

        let edit = ComponentStructureEditBuilder.insertBlock(
            id: UUID().uuidString, path: path, baseVersion: model.version,
            parentId: insertion.parentId, index: insertion.index, manifestBlock: entry.title)
        let reply = await editRouter.apply(edit)
        switch reply.status {
        case .applied:
            return EffectDialogs.applied(effectTitle: entry.title, siteName: site.displayName)
        case .failed, .ambiguous, .preview:
            return EffectDialogs.failed(
                effectTitle: entry.title, siteName: site.displayName,
                reason: reply.message ?? "the edit was refused.")
        }
    }

    /// Computes a default `{parentId, index}` for an effect with no click to resolve against.
    /// `.background` inserts as the last child of `<body>` (or the tree root if no `<body>` is
    /// found — an unusual page, but insertion should still succeed rather than refuse).
    /// `.inline` inserts as the first child of the first node matching `allowedParents` (or the
    /// tree root when `allowedParents` is nil).
    public static func defaultInsertion(for entry: EffectCatalogEntry, in model: PageModel) -> PlacementMatcher.Insertion? {
        guard let placement = entry.placement else { return nil }
        switch placement.kind {
        case .background:
            let body = findNode(tagged: "BODY", in: model.tree) ?? model.tree
            return PlacementMatcher.Insertion(parentId: body.id, index: body.children.count)
        case .inline:
            if let allowedParents = placement.allowedParents,
               let match = allowedParents.lazy.compactMap({ findNode(tagged: $0, in: model.tree) }).first {
                return PlacementMatcher.Insertion(parentId: match.id, index: 0)
            }
            return PlacementMatcher.Insertion(parentId: model.tree.id, index: model.tree.children.count)
        }
    }

    private static func findNode(tagged tag: String, in node: PageModel.Node) -> PageModel.Node? {
        if node.tag?.uppercased() == tag.uppercased() { return node }
        for child in node.children {
            if let found = findNode(tagged: tag, in: child) { return found }
        }
        return nil
    }
}

// MARK: - Test-only helpers

extension AddEffectIntent {
    /// Drives `run()`'s plan → confirm → apply logic directly, bypassing the AppIntents
    /// `requestConfirmation` gate (skipped whenever `EffectCatalogOverride.scoped` is bound — see
    /// `run()`). Only callable when `EffectCatalogOverride.scoped` is bound.
    func performForTesting() async throws -> String {
        guard EffectCatalogOverride.scoped != nil else {
            fatalError("performForTesting requires a bound EffectCatalogOverride.scoped")
        }
        return try await run()
    }
}

// MARK: - EffectAppEnum

/// `AppEnum` over the catalog's placeable effect ids, for Siri's parameter picker. Raw values
/// (and display representations) are the catalog entries' `title` strings, not their `component`
/// ids — `AddEffectIntent.run()` looks entries up by title.
public enum EffectAppEnum: String, AppEnum {
    case particleField = "Particle Field"
    case auroraGradient = "Aurora Gradient"
    case grainOverlay = "Grain Overlay"
    case magneticButton = "Magnetic Button"
    case cursorGlow = "Cursor Glow"
    case tiltCard = "Tilt Card"
    case parallaxLayers = "Parallax Layers"
    case revealMask = "Reveal Mask"
    case scrollProgressTrace = "Scroll Progress Trace"
    case blobMorph = "Blob Morph"
    case meshGradient = "Mesh Gradient"
    case dotGridPulse = "Dot Grid Pulse"

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Effect"
    public static var caseDisplayRepresentations: [EffectAppEnum: DisplayRepresentation] = [
        .particleField: "Particle Field", .auroraGradient: "Aurora Gradient", .grainOverlay: "Grain Overlay",
        .magneticButton: "Magnetic Button", .cursorGlow: "Cursor Glow", .tiltCard: "Tilt Card",
        .parallaxLayers: "Parallax Layers", .revealMask: "Reveal Mask", .scrollProgressTrace: "Scroll Progress Trace",
        .blobMorph: "Blob Morph", .meshGradient: "Mesh Gradient", .dotGridPulse: "Dot Grid Pulse",
    ]
}

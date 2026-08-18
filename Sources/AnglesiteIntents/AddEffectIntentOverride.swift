import AnglesiteCore

/// Test-only escape hatch for ``AddEffectIntent``, bundling everything production resolves via a
/// live template read plus the site's registries: the effect catalog (normally
/// `EffectCatalog.load(templateDirectory:)` against the bundled template) and the site's
/// `PageModelClient`/`EditRouter` pair (normally read from `PageModelClientRegistry`/
/// `EditRouterRegistry`, which only have entries while a site window is open). Under `swift test`
/// there is no bundled template and no open window, so tests bind this instead of relying on
/// `@Dependency` resolution or the live registries.
///
/// A bound value also skips `requestConfirmation`, mirroring `ThemeCatalogOverride` /
/// `IntegrationOperationsOverride` elsewhere in this file's sibling intents — Siri's confirmation
/// dialog isn't introspectable under `swift test`, so tests short-circuit it rather than exercise
/// it.
public struct AddEffectIntentFakes: Sendable {
    /// The catalog `AddEffectIntent` looks the chosen effect up in.
    public let catalog: EffectCatalog
    /// The site's page-model source, or `nil` to simulate "site not open in Anglesite."
    public let pageModelClient: PageModelClient?
    /// The site's edit router, or `nil` to simulate "site not open in Anglesite." Independent of
    /// `pageModelClient` so a test can exercise the case where only one of the pair is missing —
    /// production always registers/unregisters both together (`PreviewModel.open()`/`close()`),
    /// but the intent still checks both explicitly rather than assuming they travel in lockstep.
    public let editRouter: EditRouter?

    public init(catalog: EffectCatalog, pageModelClient: PageModelClient?, editRouter: EditRouter?) {
        self.catalog = catalog
        self.pageModelClient = pageModelClient
        self.editRouter = editRouter
    }
}

/// `@TaskLocal` binding point for ``AddEffectIntentFakes``. `AddEffectIntent` reads
/// `AddEffectIntentOverride.scoped` first; a bound value wins over the live template/registry
/// lookups and also signals "under test," so `requestConfirmation` is skipped. Always `nil` in
/// production.
public enum AddEffectIntentOverride {
    @TaskLocal public static var scoped: AddEffectIntentFakes?
}

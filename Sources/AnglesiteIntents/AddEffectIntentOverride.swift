import AnglesiteCore

/// Test-only escape hatch for the site connectivity ``AddEffectIntent`` normally resolves from
/// `PageModelClientRegistry`/`EditRouterRegistry` — registries populated by `PreviewModel.open()`/
/// `close()` that only have entries while a site window is open. `swift test` has no open window,
/// so tests bind this instead of relying on the live registries.
///
/// Unlike ``EffectCatalogOverride`` (which pairs with a `@Dependency`, matching every other
/// catalog/service override in this file's sibling intents), there's no single existing
/// `@Dependency`-backed type these two registry lookups collapse into — production always looks
/// them up as a pair via `PageModelClientRegistry.shared`/`EditRouterRegistry.shared` directly,
/// not through `@Dependency`. So this stays a small dedicated bundle rather than forcing a
/// mismatched single-`@Dependency` shape onto a pair of registry lookups that don't have one.
public struct AddEffectSiteConnection: Sendable {
    /// The site's page-model source, or `nil` to simulate "site not open in Anglesite."
    public let pageModelClient: PageModelClient?
    /// The site's edit router, or `nil` to simulate "site not open in Anglesite." Independent of
    /// `pageModelClient` so a test can exercise the case where only one of the pair is missing —
    /// production always registers/unregisters both together (`PreviewModel.open()`/`close()`),
    /// but the intent still checks both explicitly rather than assuming they travel in lockstep.
    public let editRouter: EditRouter?

    public init(pageModelClient: PageModelClient?, editRouter: EditRouter?) {
        self.pageModelClient = pageModelClient
        self.editRouter = editRouter
    }
}

/// `@TaskLocal` binding point for ``AddEffectSiteConnection``. `AddEffectIntent` reads
/// `AddEffectSiteConnectionOverride.scoped` first; a bound value wins over the live registry
/// lookups. Always `nil` in production.
public enum AddEffectSiteConnectionOverride {
    @TaskLocal public static var scoped: AddEffectSiteConnection?
}

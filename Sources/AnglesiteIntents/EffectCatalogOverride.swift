import AnglesiteCore

/// Test-only escape hatch around `@Dependency` resolution of `EffectCatalog`, mirroring
/// `ThemeCatalogOverride`. `@Dependency` is gated to the AppIntents perform flow; direct
/// `intent.perform()` calls from unit tests crash without it. Tests bind this `@TaskLocal` to a
/// fake catalog before invoking `AddEffectIntent`, which reads
/// `EffectCatalogOverride.scoped ?? self.catalog`, so production flows through `@Dependency`.
public enum EffectCatalogOverride {
    /// The task-scoped fake catalog. Always `nil` in production; a bound value also signals
    /// "under test" to ``AddEffectIntent``, which then skips its `requestConfirmation` gate.
    @TaskLocal public static var scoped: EffectCatalog?
}

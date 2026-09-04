import Foundation

/// Translates a high-level intent edit request into an `EditMessage` and routes it through an
/// `EditRouter` (A.4, #138). The router comes from a `RouterProvider`, which the app wires to
/// look up the active site window's edit router and fall back to a `HeadlessRuntimePool`-backed
/// `MCPApplyEditRouter` when no window is open — so a Siri/Shortcuts edit works whether or not
/// the site is on screen. The bridge itself is UI-agnostic and lives in Core so the
/// `AnglesiteIntents` (Siri) surface can use it without depending on the WKWebView layer.
public struct IntentEditBridge: Sendable {
    /// Resolve the `EditRouter` to use for a site, or `nil` if one can't be obtained.
    public typealias RouterProvider = @Sendable (_ siteID: String) async -> EditRouter?

    private let routerProvider: RouterProvider
    private let makeID: @Sendable () -> String

    /// `makeID` is injectable so the correlation id is deterministic in tests; production defaults
    /// to a fresh UUID per edit.
    public init(
        routerProvider: @escaping RouterProvider,
        makeID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.routerProvider = routerProvider
        self.makeID = makeID
    }

    /// Build an `apply-edit` `EditMessage` and route it. Returns the router's `EditReply`, or a
    /// `.failed` reply (carrying the generated id) when no router is available for the site.
    ///
    /// `filePath` is the page path the overlay would target (e.g. `/about`); `selector` is the
    /// structured `ElementInfo` the plugin's `selector.mjs` resolves server-side; `op`/`value`
    /// are the edit operation and its payload.
    public func applyEdit(
        siteID: String,
        filePath: String,
        selector: JSONValue,
        op: String,
        value: JSONValue?,
        dryRun: Bool = false
    ) async -> EditReply {
        let id = makeID()
        guard let router = await routerProvider(siteID) else {
            return EditReply(
                id: id,
                status: .failed,
                message: "No edit router available for this site — open it in Anglesite, or check that the plugin is bundled."
            )
        }
        let message = EditMessage(id: id, type: .applyEdit, path: filePath, selector: selector, op: op, value: value, dryRun: dryRun)
        return await router.apply(message)
    }
}

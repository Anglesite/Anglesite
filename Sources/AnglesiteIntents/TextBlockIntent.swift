import AppIntents
import AnglesiteCore
import Foundation

// MARK: - Dialog formatting (pure, unit-testable)

/// Pure dialog strings for ``AddTextBlockIntent``. No AppIntents types, so these are fully
/// unit-testable without the AppIntents runtime — same convention as `EffectDialogs`
/// (`EffectIntents.swift`).
public enum TextBlockDialogs {
    /// Neither a `PageModelClient` nor an `EditRouter` is registered for the site — its window
    /// isn't open, so there's no live MCP connection to fetch a page model or apply an edit
    /// through (mirrors `EffectDialogs.siteNotOpen`).
    public static func siteNotOpen(siteName: String) -> String {
        "Open \(siteName) in Anglesite first, then try adding this text again."
    }
    /// `get_page_model` failed; `reason` is `PageModelClient.ModelError.friendlyMessage`.
    public static func modelLoadFailed(siteName: String, reason: String) -> String {
        "Couldn't load \(siteName)'s home page: \(reason)"
    }
    /// Success dialog once the op transport reports `.applied`.
    public static func applied(siteName: String) -> String {
        "Added a paragraph to \(siteName)."
    }
    /// Failure dialog for a `.rejected` op result; `reason` carries whichever message the
    /// transport surfaced.
    public static func failed(siteName: String, reason: String) -> String {
        "Couldn't add a paragraph to \(siteName): \(reason)"
    }
}

// MARK: - Add Text Block

/// Adds a plain paragraph block to a site's home page via Siri/Shortcuts, exercising the real
/// WYSIWYG ops vocabulary (`Op`/`OpEnvelope`, `WYSIWYGOps.swift`) through the same production
/// transport `PreviewModel.enterEditMode` builds for the live canvas (`SidecarWYSIWYGHostTransport`)
/// — unlike `AddEffectIntent`, which talks to `EditMessage` directly and never constructs an `Op`
/// at all.
///
/// No page picker on this front door (v1) — the home page's source file, mirroring
/// `AddEffectIntent`'s own simplification. Reaches the site's live MCP connection the same way:
/// `PageModelClientRegistry`/`EditRouterRegistry`, populated only while the site's window is open,
/// so a Siri/Shortcuts invocation while it's closed gets ``TextBlockDialogs/siteNotOpen(siteName:)``
/// rather than silently failing.
public struct AddTextBlockIntent: AppIntent {
    /// Display name in the Shortcuts action library and Siri disambiguation.
    public static let title: LocalizedStringResource = "Add Text Block"
    /// Longer explanation shown under the action in the Shortcuts editor.
    public static let description = IntentDescription("Add a paragraph of text to a site's home page.")

    /// The target site, resolved from the recents registry via ``SiteEntity``'s query.
    @Parameter(title: "Site") public var site: SiteEntity
    /// The paragraph's text content.
    @Parameter(title: "Text") public var text: String

    /// AppIntents requires a parameterless initializer; the framework populates `@Parameter`s
    /// after construction.
    public init() {}

    /// Shortcuts-editor sentence: "Add (text) to (site)".
    public static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await run()))
    }

    /// Pure(ish) core: resolves the site connection, fetches the page model, confirms, applies.
    /// Shared by `perform()` and `performForTesting()` so the two stay in lockstep — same shape
    /// as `AddEffectIntent.run()`.
    private func run() async throws -> String {
        // Tests bind SiteConnectionOverride.scoped; production reads the live per-siteID
        // registries (populated only while the site's window is open). A bound override also
        // signals "under test", so `requestConfirmation` is skipped.
        let pageModelClient: PageModelClient?
        let editRouter: EditRouter?
        let underTest = SiteConnectionOverride.scoped != nil
        if let connection = SiteConnectionOverride.scoped {
            pageModelClient = connection.pageModelClient
            editRouter = connection.editRouter
        } else {
            pageModelClient = await PageModelClientRegistry.shared.pageModelClient(for: site.id)
            editRouter = await EditRouterRegistry.shared.router(for: site.id)
        }
        guard let pageModelClient, let editRouter else {
            return TextBlockDialogs.siteNotOpen(siteName: site.displayName)
        }

        // Project-relative `.astro` path, not the route — `get_page_model`'s `validPagePath` and
        // `insertBlock`'s own path check both reject a route outright (#768 final review,
        // Finding 1).
        let path = PageSourcePath.homePage
        let model: PageModel
        do {
            model = try await pageModelClient.fetch(path: path)
        } catch let error as PageModelClient.ModelError {
            return TextBlockDialogs.modelLoadFailed(siteName: site.displayName, reason: error.friendlyMessage)
        }

        if !underTest {
            try await requestConfirmation(dialog: "Add this text to \(site.displayName)?")
        }

        let body = Self.findNode(tagged: "BODY", in: model.tree) ?? model.tree
        let content = BlockNodeContent(
            kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0],
            richText: [RichTextRun(kind: .text, text: text)])
        let op = Op.insertBlock(
            parentId: body.id, slot: "default", index: body.children.count,
            newId: UUID().uuidString, block: content)
        let transport = SidecarWYSIWYGHostTransport(
            path: path, pageModelClient: pageModelClient, editRouter: editRouter, rootId: model.tree.id)
        let result = await transport.sendOp(OpEnvelope(id: UUID().uuidString, targetVersion: model.version, op: op))

        switch result {
        case .applied:
            return TextBlockDialogs.applied(siteName: site.displayName)
        case .rejected(_, let message, _):
            return TextBlockDialogs.failed(siteName: site.displayName, reason: message ?? "the edit was refused.")
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

extension AddTextBlockIntent {
    /// Drives `run()`'s fetch → confirm → apply logic directly, bypassing the AppIntents
    /// `requestConfirmation` gate (skipped whenever `SiteConnectionOverride.scoped` is bound — see
    /// `run()`). Only callable when `SiteConnectionOverride.scoped` is bound.
    func performForTesting() async throws -> String {
        guard SiteConnectionOverride.scoped != nil else {
            fatalError("performForTesting requires a bound SiteConnectionOverride.scoped")
        }
        return try await run()
    }
}

import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

/// `PreviewModel`'s WYSIWYG edit-mode toggle (#1225 Task 8) — mounts a `WYSIWYGCanvasController`
/// against the existing `.preview` pane's `WKWebView` rather than adding a new pane mode. Uses
/// `UnavailableSiteRuntime`, the same real minimal `SiteRuntime` fixture
/// `PreviewModelContainerCapabilityTests` already reaches for — edit mode itself never touches the
/// runtime, so no bespoke fake is needed here.
@Suite("PreviewModel WYSIWYG edit mode (#1225)")
@MainActor
struct PreviewModelWYSIWYGTests {
    @Test("enterEditMode constructs a canvas controller; exitEditMode tears it down")
    func editModeLifecycle() async {
        let model = PreviewModel(runtime: UnavailableSiteRuntime(reason: "no runtime needed for edit-mode toggle"))
        #expect(model.isEditModeEnabled == false)
        #expect(model.wysiwygCanvas == nil)

        await model.enterEditMode(
            seedModel: BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:]),
            undoManager: nil)
        #expect(model.isEditModeEnabled == true)
        #expect(model.wysiwygCanvas != nil)

        model.exitEditMode()
        #expect(model.isEditModeEnabled == false)
        #expect(model.wysiwygCanvas == nil)
    }

    /// #1225 final-review round 2, Finding A: `SiteWindowModel.windowUndoManager`'s `didSet` fan-out
    /// forwards to `preview.wysiwygCanvas?.undoCoordinator.undoManager`, but only fires when the
    /// environment value itself arrives/changes — which happens once, early, before the owner has
    /// ever toggled edit mode on. Without threading the manager through `enterEditMode` directly,
    /// the freshly-built canvas's `undoCoordinator.undoManager` stays permanently `nil`, so
    /// `WYSIWYGUndoCoordinator.register(...)`'s `guard let undoManager else { return nil }` always
    /// bails and canvas edits never register on the undo stack.
    @Test("enterEditMode seeds the canvas's undo coordinator with the passed-in undo manager")
    func editModeSeedsUndoManager() async {
        let model = PreviewModel(runtime: UnavailableSiteRuntime(reason: "no runtime needed for edit-mode toggle"))
        let undoManager = UndoManager()

        await model.enterEditMode(
            seedModel: BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:]),
            undoManager: undoManager)
        #expect(model.wysiwygCanvas?.undoCoordinator.undoManager === undoManager)
    }

    /// Same finding, the toggle-off/toggle-on-again half: `exitEditMode()` drops `wysiwygCanvas`
    /// entirely, so a second `enterEditMode` call must build (and seed) a brand-new canvas — not
    /// silently leave the new one's `undoCoordinator.undoManager` nil because the manager was
    /// already forwarded "once" to the first canvas.
    @Test("re-entering edit mode after exiting seeds the new canvas's undo manager again")
    func reenteringEditModeReseedsUndoManager() async {
        let model = PreviewModel(runtime: UnavailableSiteRuntime(reason: "no runtime needed for edit-mode toggle"))
        let firstUndoManager = UndoManager()
        let seed = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:])

        await model.enterEditMode(seedModel: seed, undoManager: firstUndoManager)
        let firstCanvas = model.wysiwygCanvas
        #expect(firstCanvas?.undoCoordinator.undoManager === firstUndoManager)

        model.exitEditMode()
        #expect(model.wysiwygCanvas == nil)

        let secondUndoManager = UndoManager()
        await model.enterEditMode(seedModel: seed, undoManager: secondUndoManager)
        #expect(model.wysiwygCanvas !== nil)
        #expect(model.wysiwygCanvas !== firstCanvas)
        #expect(model.wysiwygCanvas?.undoCoordinator.undoManager === secondUndoManager)
    }

    @Test("enterEditMode builds the canvas's qualityGateContext from the open site's Source/ directory")
    func editModeBuildsQualityGateContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = root.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ":root { --color-text: #111111; }".write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)

        let model = PreviewModel(runtime: UnavailableSiteRuntime(reason: "no runtime needed for this test"))
        model.open(site: CurrentSite(id: "site-1", packageURL: root, sourceDirectory: root))

        await model.enterEditMode(
            seedModel: BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:]),
            undoManager: nil)

        #expect(model.wysiwygCanvas?.qualityGateContext?.resolvedTokens["color-text"] == "#111111")
    }
}

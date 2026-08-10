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

        await model.enterEditMode(seedModel: BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: [], blocks: [:]))
        #expect(model.isEditModeEnabled == true)
        #expect(model.wysiwygCanvas != nil)

        model.exitEditMode()
        #expect(model.isEditModeEnabled == false)
        #expect(model.wysiwygCanvas == nil)
    }
}

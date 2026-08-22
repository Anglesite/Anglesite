import Testing
import Foundation
@testable import AnglesiteAppCore

/// Covers the data-source logic `QuickLookPreviewController` hands to `QLPreviewPanel` — the
/// only part callable headlessly without an actual key window/responder chain (#1617). The
/// responder-chain wiring (`acceptsPreviewPanelControl`/`begin`/`endPreviewPanelControl`,
/// first-responder handoff in `togglePanel()`) is exercised manually per
/// `docs/mac-assed-app-spec.md`'s acceptance checklist, not by `swift test`.
@Suite @MainActor struct QuickLookPreviewControllerTests {
    @Test func noPreviewItemsWhenNoPackageIsSet() {
        let controller = QuickLookPreviewController()
        #expect(controller.numberOfPreviewItems(in: nil) == 0)
        #expect(controller.previewPanel(nil, previewItemAt: 0) == nil)
    }

    @Test func onePreviewItemPointingAtThePackageURLWhenSet() {
        let controller = QuickLookPreviewController()
        let url = URL(fileURLWithPath: "/tmp/Acme.anglesite")
        controller.packageURL = url
        #expect(controller.numberOfPreviewItems(in: nil) == 1)
        #expect(controller.previewPanel(nil, previewItemAt: 0)?.previewItemURL == url)
    }

    @Test func outOfRangeIndexReturnsNilEvenWithAPackageSet() {
        let controller = QuickLookPreviewController()
        controller.packageURL = URL(fileURLWithPath: "/tmp/Acme.anglesite")
        #expect(controller.previewPanel(nil, previewItemAt: 1) == nil)
    }
}

import Testing
import AppKit
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@Suite("WYSIWYGBlockContextMenu")
@MainActor
struct WYSIWYGBlockContextMenuTests {
    @Test("builds a menu with Duplicate and Delete items targeting the given block")
    func buildsDuplicateAndDelete() {
        let node = BlockNode(id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": node])
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))

        let menu = WYSIWYGBlockContextMenu.build(for: "b1", controller: controller)

        let titles = menu.items.map(\.title)
        #expect(titles.contains("Duplicate"))
        #expect(titles.contains("Delete"))
    }

    @Test("selecting Duplicate sets the controller's selection to the target block first")
    func duplicateSelectsTargetFirst() {
        let node = BlockNode(id: "b1", kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": node])
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))
        controller.selectedBlockId = nil

        let menu = WYSIWYGBlockContextMenu.build(for: "b1", controller: controller)
        let duplicateItem = menu.items.first { $0.title == "Duplicate" }
        _ = duplicateItem?.target?.perform(duplicateItem?.action, with: duplicateItem)

        #expect(controller.selectedBlockId == "b1")
    }
}

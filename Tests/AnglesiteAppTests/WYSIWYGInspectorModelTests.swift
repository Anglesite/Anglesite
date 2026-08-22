import Testing
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@Suite("WYSIWYGInspectorModel")
@MainActor
struct WYSIWYGInspectorModelTests {
    static func makeController(componentName: String, props: [String: PropValue] = [:]) -> (WYSIWYGCanvasController, BlockId) {
        let node = BlockNode(id: "b1", kind: .astro, componentName: componentName, props: props, slots: [:], sourceSpan: [0, 0])
        let initial = BlockModel(path: "src/pages/index.astro", version: "v0", rootIds: ["b1"], blocks: ["b1": node])
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))
        return (controller, "b1")
    }

    @Test("descriptors resolves from the palette entry matching the block's componentName")
    func descriptorsResolveFromPalette() {
        let (controller, blockId) = Self.makeController(componentName: "Callout")
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId)

        #expect(model.descriptors.map(\.name).sorted() == ["accentColor", "emphasis", "title"])
    }

    @Test("descriptors is empty for a component with no palette match")
    func descriptorsEmptyForUnknownComponent() {
        let (controller, blockId) = Self.makeController(componentName: "SomeUnknownWidget")
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId)

        #expect(model.descriptors.isEmpty)
    }

    @Test("setString submits a setProp op and stringValue reflects the committed result")
    func setStringCommitsAndReflects() async {
        let (controller, blockId) = Self.makeController(componentName: "Callout", props: ["title": .string("old")])
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId)

        model.setString("new", for: "title")

        var attempts = 0
        while model.stringValue(for: "title") != "new", attempts < 50 {
            try? await Task.sleep(nanoseconds: 5_000_000) // poll for the fire-and-forget Task's commit
            attempts += 1
        }

        #expect(model.stringValue(for: "title") == "new")
    }

    @Test("boolValue defaults to false for a prop not yet set on the block")
    func boolValueDefaultsFalse() {
        let (controller, blockId) = Self.makeController(componentName: "Callout")
        let model = WYSIWYGInspectorModel(controller: controller, blockId: blockId)

        #expect(model.boolValue(for: "emphasis") == false)
    }
}

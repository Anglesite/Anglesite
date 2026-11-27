import Foundation
import Testing
@testable import AnglesiteAppCore
@testable import AnglesiteCore

/// `WYSIWYGCanvasController.refreshFromSource()` (#2215): outside changes to the page reach an
/// already-mounted canvas.
@Suite("WYSIWYGCanvasController.refreshFromSource")
@MainActor
struct WYSIWYGCanvasControllerRefreshTests {
    /// A refreshable transport whose "source" a test sets directly. `sendOp` applies nothing and
    /// can be held open, to exercise the in-flight guard.
    actor FakeRefreshableTransport: WYSIWYGRefreshableTransport {
        var source: BlockModel
        private(set) var refreshCalls = 0
        private var heldOp: CheckedContinuation<Void, Never>?

        init(source: BlockModel) { self.source = source }

        func setSource(_ model: BlockModel) { source = model }

        func refreshModel(knownVersion: String) async -> BlockModel? {
            refreshCalls += 1
            return source.version == knownVersion ? nil : source
        }

        func sendOp(_ envelope: OpEnvelope) async -> OpResult {
            await withCheckedContinuation { heldOp = $0 }
            return .applied(model: source)
        }

        var isHoldingOp: Bool { heldOp != nil }

        func releaseOp() {
            heldOp?.resume()
            heldOp = nil
        }

        func onModelUpdate(_ listener: @escaping @Sendable (BlockModel) -> Void) async -> () -> Void { {} }
    }

    private static func model(version: String, blockIds: [BlockId]) -> BlockModel {
        var blocks: [BlockId: BlockNode] = [:]
        for id in blockIds {
            blocks[id] = BlockNode(id: id, kind: .text, componentName: "p", props: [:], slots: [:], sourceSpan: [0, 0])
        }
        return BlockModel(path: "src/pages/index.astro", version: version, rootIds: blockIds, blocks: blocks)
    }

    @Test("adopts the source's model when it changed outside the canvas")
    func adoptsOutsideChange() async {
        let initial = Self.model(version: "v0", blockIds: ["b1"])
        let transport = FakeRefreshableTransport(source: Self.model(version: "v1", blockIds: ["b1", "b2"]))
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)

        await controller.refreshFromSource()

        #expect(controller.model.version == "v1")
        #expect(controller.model.rootIds == ["b1", "b2"])
    }

    @Test("leaves the model alone when the source is unchanged")
    func unchangedSourceIsNoOp() async {
        let initial = Self.model(version: "v0", blockIds: ["b1"])
        let transport = FakeRefreshableTransport(source: initial)
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)

        await controller.refreshFromSource()

        #expect(controller.model == initial)
        #expect(await transport.refreshCalls == 1)
    }

    @Test("keeps the selection when its block survives, clears it when the block is gone")
    func selectionFollowsTheBlock() async {
        let initial = Self.model(version: "v0", blockIds: ["b1", "b2"])
        let transport = FakeRefreshableTransport(source: Self.model(version: "v1", blockIds: ["b1", "b2", "b3"]))
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)
        controller.selectedBlockId = "b2"

        await controller.refreshFromSource()
        #expect(controller.selectedBlockId == "b2")

        await transport.setSource(Self.model(version: "v2", blockIds: ["b1"]))
        await controller.refreshFromSource()
        #expect(controller.selectedBlockId == nil)
    }

    @Test("stands down while an op is in flight, since the op's result carries the newest model")
    func standsDownDuringAnOp() async {
        let initial = Self.model(version: "v0", blockIds: ["b1"])
        let transport = FakeRefreshableTransport(source: Self.model(version: "v1", blockIds: ["b1"]))
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: transport)

        let op = Task { await controller.submit(.setDesignToken(tokenName: "t", value: "a", previousValue: "b")) }
        while await !transport.isHoldingOp { await Task.yield() }

        await controller.refreshFromSource()
        #expect(await transport.refreshCalls == 0)
        #expect(controller.model.version == "v0")

        await transport.releaseOp()
        _ = await op.value
        #expect(controller.model.version == "v1")
    }

    @Test("a transport that can't refresh is left alone")
    func nonRefreshableTransportIsNoOp() async {
        let initial = Self.model(version: "v0", blockIds: [])
        let controller = WYSIWYGCanvasController(initialModel: initial, transport: StubWYSIWYGHostTransport(model: initial))
        await controller.refreshFromSource()
        #expect(controller.model == initial)
    }

    @Test("modelUpdateScript pushes the model's exact JSON through _handleModelUpdate")
    func modelUpdateScriptShape() throws {
        let model = Self.model(version: "v9", blockIds: ["b1"])
        let script = WYSIWYGCanvasController.modelUpdateScript(for: model)
        let prefix = "window.__anglesiteWysiwygHost?._handleModelUpdate?.("
        #expect(script.hasPrefix(prefix))
        #expect(script.hasSuffix(")"))
        let json = String(script.dropFirst(prefix.count).dropLast())
        let decoded = try JSONDecoder().decode(BlockModel.self, from: Data(json.utf8))
        #expect(decoded == model)
    }
}

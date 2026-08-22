import Foundation
import Observation
import AnglesiteCore

/// The native inspector's model for one selected WYSIWYG block (#1588 Task 6) — the WYSIWYG
/// analog of `TypedEntryEditorModel`'s per-field binding methods (`TypedEntryEditorModel.swift`),
/// but committing per-edit through `Op.setProp` rather than buffering until an explicit Save: the
/// canvas has no Save step, everything applies live (design doc §1).
@MainActor
@Observable
final class WYSIWYGInspectorModel {
    let controller: WYSIWYGCanvasController
    let blockId: BlockId

    init(controller: WYSIWYGCanvasController, blockId: BlockId) {
        self.controller = controller
        self.blockId = blockId
    }

    private var node: BlockNode? { controller.model.blocks[blockId] }

    /// The editable props for this block's kind, resolved from the interim palette (Task 5) by
    /// matching `componentName` — real prop schemas arrive with #1222's CEM manifest.
    var descriptors: [WYSIWYGPropDescriptor] {
        guard let node else { return [] }
        return WYSIWYGCanvasController.stubBlockPalette.first { $0.componentName == node.componentName }?.props ?? []
    }

    func stringValue(for name: String) -> String {
        guard case .string(let value)? = node?.props[name] else { return "" }
        return value
    }

    func setString(_ value: String, for name: String) {
        Task { await commit(name: name, value: .string(value)) }
    }

    func numberValue(for name: String) -> Double {
        guard case .number(let value)? = node?.props[name] else { return 0 }
        return value
    }

    func setNumber(_ value: Double, for name: String) {
        Task { await commit(name: name, value: .number(value)) }
    }

    func boolValue(for name: String) -> Bool {
        guard case .bool(let value)? = node?.props[name] else { return false }
        return value
    }

    func setBool(_ value: Bool, for name: String) {
        Task { await commit(name: name, value: .bool(value)) }
    }

    private func commit(name: String, value: PropValue) async {
        let previous = node?.props[name] ?? .null
        await controller.submit(.setProp(blockId: blockId, propName: name, value: value, previousValue: previous))
    }
}

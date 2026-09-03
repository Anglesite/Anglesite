import Foundation

/// Applies ops to an in-memory `BlockModel` only — no real source write, no git commit. Mirrors
/// `JS/wysiwyg-engine/src/testing/fixture-host.ts`'s reducer so both sides of the protocol are
/// exercised against equivalent stand-ins until the real sidecar-backed transport lands (#1222).
public actor StubWYSIWYGHostTransport: WYSIWYGHostTransport {
    private var model: BlockModel
    private var listeners: [UUID: @Sendable (BlockModel) -> Void] = [:]

    public init(model: BlockModel) {
        self.model = model
    }

    public func sendOp(_ envelope: OpEnvelope) async -> OpResult {
        guard envelope.targetVersion == model.version else {
            return .rejected(reason: .versionMismatch, message: "stale model version", freshModel: model)
        }
        guard let next = Self.applying(envelope.op, to: model) else {
            return .rejected(reason: .invalidTarget, message: "target block not found", freshModel: nil)
        }
        model = next
        return .applied(model: next)
    }

    /// Host-initiated model push (spec §3.2/§3.3) — e.g. `simulateExternalEdit` in the JS fixture
    /// host's test-only surface. This stub keeps the listener registry for protocol parity but has
    /// no external-edit trigger yet; nothing currently calls into it. `async` because registering
    /// the listener is actor-isolated state; the returned unsubscribe closure still hops onto a
    /// detached `Task` to reach that state later, mirroring `LogCenter.subscribe()`'s `[weak self]`
    /// + `Task { await self.removeSubscriber(id) }` pattern elsewhere in this target.
    public func onModelUpdate(_ listener: @escaping @Sendable (BlockModel) -> Void) async -> () -> Void {
        let token = UUID()
        listeners[token] = listener
        return { [weak self] in
            guard let self else { return }
            Task { await self.removeListener(token) }
        }
    }

    private func removeListener(_ token: UUID) {
        listeners.removeValue(forKey: token)
    }

    /// Pure reducer, ported from `fixture-host.ts`'s `applyOp`/`spliceIntoSlot`. Returns `nil` on
    /// an invalid target (parent/index/block not found) rather than throwing.
    static func applying(_ op: Op, to model: BlockModel) -> BlockModel? {
        var blocks = model.blocks
        var rootIds = model.rootIds

        func spliceOut(parentId: ParentRef, slot: String, blockId: BlockId) -> Bool {
            if parentId == rootParentID {
                guard let idx = rootIds.firstIndex(of: blockId) else { return false }
                rootIds.remove(at: idx)
                return true
            }
            guard var parent = blocks[parentId] else { return false }
            var ids = parent.slots[slot] ?? []
            guard let idx = ids.firstIndex(of: blockId) else { return false }
            ids.remove(at: idx)
            parent.slots[slot] = ids
            blocks[parentId] = parent
            return true
        }

        func spliceIn(parentId: ParentRef, slot: String, index: Int, blockId: BlockId) -> Bool {
            if parentId == rootParentID {
                guard index >= 0, index <= rootIds.count else { return false }
                rootIds.insert(blockId, at: index)
                return true
            }
            guard var parent = blocks[parentId] else { return false }
            var ids = parent.slots[slot] ?? []
            guard index >= 0, index <= ids.count else { return false }
            ids.insert(blockId, at: index)
            parent.slots[slot] = ids
            blocks[parentId] = parent
            return true
        }

        switch op {
        case .insertBlock(let parentId, let slot, let index, let newId, let content):
            blocks[newId] = BlockNode(id: newId, kind: content.kind, componentName: content.componentName, props: content.props, slots: content.slots, sourceSpan: content.sourceSpan, richText: content.richText, manifestName: content.manifestName)
            guard spliceIn(parentId: parentId, slot: slot, index: index, blockId: newId) else { return nil }

        case .deleteBlock(let parentId, let slot, _, let blockId, _):
            guard spliceOut(parentId: parentId, slot: slot, blockId: blockId) else { return nil }
            blocks.removeValue(forKey: blockId)

        case .moveBlock(let blockId, let fromParentId, let fromSlot, _, let toParentId, let toSlot, let toIndex):
            guard spliceOut(parentId: fromParentId, slot: fromSlot, blockId: blockId) else { return nil }
            guard spliceIn(parentId: toParentId, slot: toSlot, index: toIndex, blockId: blockId) else { return nil }

        case .setProp(let blockId, let propName, let value, _):
            guard var node = blocks[blockId] else { return nil }
            node.props[propName] = value
            blocks[blockId] = node

        case .editText(let blockId, let runs, _):
            guard var node = blocks[blockId] else { return nil }
            node.richText = runs
            blocks[blockId] = node

        case .setDesignToken:
            break // Accepted but not modeled in the stub — matches fixture-host.ts's no-op case.
        }

        // A UUID-derived version is sufficient for a stub whose only job is "always differ after
        // a mutation" — fixture-host.ts's own hash is documented as never a real algorithm either.
        return BlockModel(path: model.path, version: "stub-\(UUID().uuidString)", rootIds: rootIds, blocks: blocks)
    }
}

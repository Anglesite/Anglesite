import Foundation

extension BlockModel {
    /// All blocks in document order (pre-order: each block, then its slots' children in slot-name
    /// order, then each slot's children in list order) — the order heading-hierarchy validation
    /// needs (`HeadingOrderGate`, Task 6), and a convenient "all blocks" traversal for the other
    /// gates, where order doesn't matter. Guards against a cyclic slots graph with a visited set —
    /// that should never occur, but a checker looping the main thread on malformed data would be a
    /// worse failure than a merely incomplete result.
    public var orderedBlocks: [BlockNode] {
        var result: [BlockNode] = []
        var visited = Set<BlockId>()
        func visit(_ id: BlockId) {
            guard visited.insert(id).inserted, let node = blocks[id] else { return }
            result.append(node)
            for slotName in node.slots.keys.sorted() {
                for childId in node.slots[slotName] ?? [] { visit(childId) }
            }
        }
        for id in rootIds { visit(id) }
        return result
    }
}

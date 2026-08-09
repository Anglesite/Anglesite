import type { BlockId, BlockNode, OpResult, ParentRef } from "./types.js";
import type { WysiwygEngine } from "./engine.js";
import { ROOT_PARENT_ID } from "./types.js";
import { BLOCK_ID_ATTR } from "./hit-test.js";

export interface DropTarget {
  parentId: ParentRef;
  slot: string;
  index: number;
}

/**
 * Pure geometry: given a vertical point and the ordered rects of the candidate siblings, finds the
 * nearest valid insertion index by comparing against each sibling's vertical midpoint. Split out
 * from `computeDropTarget`'s DOM-querying half so it's unit-testable without a real layout engine
 * (mirrors hit-test.ts's split between `hitTest()` and `blockIdForElement()`).
 */
export function nearestIndexInSlot(pointY: number, siblingRects: { top: number; bottom: number }[]): number {
  for (let i = 0; i < siblingRects.length; i++) {
    const rect = siblingRects[i];
    if (!rect) continue;
    const midpoint = (rect.top + rect.bottom) / 2;
    if (pointY < midpoint) return i;
  }
  return siblingRects.length;
}

/**
 * Computes the nearest valid insertion point for a point-based drag/drop gesture among the direct
 * block-children of `container`. Root-level only for this slice, matching the fixture host/e2e
 * convention that already treats top-level blocks as `ROOT_PARENT_ID`/"default" — the `parentId`/
 * `slot` parameters leave room for nested-slot targeting in a future slice without an API change.
 */
export function computeDropTarget(
  point: { x: number; y: number },
  container: ParentNode,
  parentId: ParentRef = ROOT_PARENT_ID,
  slot = "default",
): DropTarget {
  const children = Array.from(container.children).filter((el) => el.hasAttribute(BLOCK_ID_ATTR));
  const rects = children.map((el) => el.getBoundingClientRect());
  return { parentId, slot, index: nearestIndexInSlot(point.y, rects) };
}

let idCounter = 0;

/** Block IDs are engine-generated, never raw user text (types.ts) — this is chrome's generator for
 *  blocks created by a drop, distinct per call within a session. */
export function generateBlockId(): BlockId {
  idCounter += 1;
  return `chrome-${Date.now().toString(36)}-${idCounter}`;
}

/** Builds and submits the `insertBlock` op for a drop at `target`. The engine never inspects a
 *  drag's `DataTransfer` itself (design doc §5) — by the time `submitDrop` is called, the host has
 *  already decided what `block` to build. */
export function submitDrop(engine: WysiwygEngine, target: DropTarget, block: Omit<BlockNode, "id">): Promise<OpResult> {
  return engine.submit({
    kind: "insertBlock",
    parentId: target.parentId,
    slot: target.slot,
    index: target.index,
    newId: generateBlockId(),
    block,
  });
}

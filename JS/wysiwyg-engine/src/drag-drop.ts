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

/**
 * Pointer-based (not HTML5 Drag and Drop) in-canvas block reordering — more reliable for
 * same-document dragging and behaves uniformly whether the block lives in a single canvas or one
 * of several breakpoint frames (design doc §5). Tracks a live `DropTarget` indicator during the
 * drag via `onIndicator` and, on release, submits `moveBlock` to that target.
 *
 * **One controller per document.** `container` is captured once at construction and every
 * `pointermove` is measured against it, but `startDrag`'s `doc` decides which document's pointer
 * events are listened to. Those two must belong to the same document, or the gesture is measured in
 * the wrong coordinate space and produces a plausible-looking but wrong drop index. Omitting
 * `startDrag`'s `doc` therefore requires `container` to come from the global `document`. A host
 * driving several breakpoint frames needs one `DragReorderController` per frame, not one shared
 * instance — see the design doc's "Known limitations carried into slice 4".
 */
export class DragReorderController {
  #engine: WysiwygEngine;
  #container: ParentNode;
  #onIndicator: (target: DropTarget | null) => void;
  #draggingId: BlockId | null = null;
  #indicatorTarget: DropTarget | null = null;
  #doc: Document | null = null;
  #onMove = (event: PointerEvent) => this.#handleMove(event);
  #onUp = () => {
    void this.#handleUp();
  };

  constructor(engine: WysiwygEngine, onIndicator: (target: DropTarget | null) => void, container: ParentNode = document) {
    this.#engine = engine;
    this.#onIndicator = onIndicator;
    this.#container = container;
  }

  get isDragging(): boolean {
    return this.#draggingId !== null;
  }

  /** Begins tracking a drag of `blockId`. `doc` must be the document `container` belongs to (see
   *  the class doc comment) — pointer coordinates from a different document are measured against
   *  the wrong coordinate space. */
  startDrag(blockId: BlockId, doc: Document = document): void {
    this.#draggingId = blockId;
    this.#doc = doc;
    doc.addEventListener("pointermove", this.#onMove);
    doc.addEventListener("pointerup", this.#onUp);
  }

  dispose(): void {
    this.#doc?.removeEventListener("pointermove", this.#onMove);
    this.#doc?.removeEventListener("pointerup", this.#onUp);
    this.#draggingId = null;
    this.#indicatorTarget = null;
    this.#doc = null;
    this.#onIndicator(null);
  }

  #handleMove(event: PointerEvent): void {
    if (!this.#draggingId) return;
    this.#indicatorTarget = computeDropTarget({ x: event.clientX, y: event.clientY }, this.#container);
    this.#onIndicator(this.#indicatorTarget);
  }

  async #handleUp(): Promise<void> {
    this.#doc?.removeEventListener("pointermove", this.#onMove);
    this.#doc?.removeEventListener("pointerup", this.#onUp);
    this.#doc = null;

    const blockId = this.#draggingId;
    const target = this.#indicatorTarget;
    this.#draggingId = null;
    this.#indicatorTarget = null;
    this.#onIndicator(null);
    if (!blockId || !target) return;

    const model = this.#engine.modelSync.current;
    const fromIndex = model.rootIds.indexOf(blockId);
    // The dragged block was removed by a concurrent model update (design doc §7) — abort cleanly
    // rather than submit a moveBlock against a now-invalid index.
    if (fromIndex === -1) return;

    // `computeDropTarget` measures against the DOM *including* the still-present dragged element, so
    // its index is in pre-removal coordinates; `moveBlock.toIndex` is post-removal (types.ts). Those
    // agree except when moving a block later in its own slot, where every index past `fromIndex`
    // shifts down by one once the block is lifted out. This controller only ever moves within the
    // root slot today, but check the actual from/to slot so a future nested-slot target can't
    // silently inherit the same-slot adjustment.
    const sameSlot = target.parentId === ROOT_PARENT_ID && target.slot === "default";
    const toIndex = sameSlot && fromIndex < target.index ? target.index - 1 : target.index;

    await this.#engine.submit({
      kind: "moveBlock",
      blockId,
      fromParentId: ROOT_PARENT_ID,
      fromSlot: "default",
      fromIndex,
      toParentId: target.parentId,
      toSlot: target.slot,
      toIndex,
    });
  }
}

export type ExternalDropHandler = (target: DropTarget, dataTransfer: DataTransfer) => void;

export interface WireExternalDropOptions {
  container?: ParentNode;
  parentId?: ParentRef;
  slot?: string;
}

/**
 * Wires native `dragover`/`dragleave`/`drop` DOM events on `canvasEl` for external drags (palette,
 * Finder) — real OS/host-originated drags surface as native drag events even inside a WKWebView.
 * The engine never interprets `DataTransfer` itself (design doc §5): `onDrop` receives the computed
 * target and the raw `DataTransfer`, and the host decides what block (if any) to build and calls
 * `submitDrop`. Returns a disposer that removes all three listeners.
 */
export function wireExternalDrop(
  canvasEl: HTMLElement,
  onIndicator: (target: DropTarget | null) => void,
  onDrop: ExternalDropHandler,
  options: WireExternalDropOptions = {},
): () => void {
  const container = options.container ?? canvasEl;
  const parentId = options.parentId ?? ROOT_PARENT_ID;
  const slot = options.slot ?? "default";

  const onDragOver = (event: DragEvent) => {
    event.preventDefault();
    onIndicator(computeDropTarget({ x: event.clientX, y: event.clientY }, container, parentId, slot));
  };
  // dragleave bubbles from every child block element the drag passes over, not just from a true
  // exit of canvasEl itself — clearing the indicator on every bubbled event would flicker it off
  // and back on as the drag crosses in-canvas block boundaries. Only clear when the drag has
  // actually left canvasEl's subtree (relatedTarget is where the pointer went, null at the
  // viewport edge — that's also a real exit).
  const onDragLeave = (event: DragEvent) => {
    if (event.relatedTarget instanceof Node && canvasEl.contains(event.relatedTarget)) return;
    onIndicator(null);
  };
  const onDropEvent = (event: DragEvent) => {
    event.preventDefault();
    onIndicator(null);
    if (!event.dataTransfer) return;
    const target = computeDropTarget({ x: event.clientX, y: event.clientY }, container, parentId, slot);
    onDrop(target, event.dataTransfer);
  };

  canvasEl.addEventListener("dragover", onDragOver);
  canvasEl.addEventListener("dragleave", onDragLeave);
  canvasEl.addEventListener("drop", onDropEvent);

  return () => {
    canvasEl.removeEventListener("dragover", onDragOver);
    canvasEl.removeEventListener("dragleave", onDragLeave);
    canvasEl.removeEventListener("drop", onDropEvent);
  };
}

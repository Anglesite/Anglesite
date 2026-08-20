import { WysiwygEngine } from "../engine.js";
import { RichTextEditor } from "../rich-text.js";
import { QualityGateChips } from "../quality-gates.js";
import { NativeHostTransport } from "./native-host-transport.js";
import { DragReorderController, computeDropTarget } from "../drag-drop.js";
import { computeHandleRect } from "../selection.js";
import type { BlockId, BlockModel } from "../types.js";

declare global {
  interface Window {
    __anglesiteWysiwygEngine?: WysiwygEngine;
    __anglesiteWysiwygRichTextEditor?: RichTextEditor;
    __anglesiteWysiwygQualityGates?: QualityGateChips;
    __anglesiteWysiwygMount?: {
      mount: (initialModel: BlockModel) => WysiwygEngine;
      unmount: () => void;
      dropTargetAt: (x: number, y: number) => { parentId: string; slot: string; index: number };
    };
  }
}

/**
 * Click-to-select (spec §8.1's engine hit-testing, this time driving native block selection
 * instead of a context menu) plus the engine → native half of the selection round-trip: whenever
 * `engine.selection` changes — from this click listener, or from any other future engine-internal
 * cause — post it to native so `WYSIWYGCanvasController.selectedBlockId` (the source the native
 * inspector/palette read) stays in sync. A `document`-level click listener, not scoped to the
 * mounted canvas root, matches the existing `contextmenu` listener below for the same reason:
 * `hitTest`'s `elementFromPoint` walks up from whatever's under the cursor to the nearest
 * block-id-bearing ancestor regardless of where the click started.
 */
function wireSelection(engine: WysiwygEngine): () => void {
  const onClick = (event: MouseEvent) => {
    const blockId = engine.hitTest({ x: event.clientX, y: event.clientY });
    engine.selection.select(blockId);
  };
  document.addEventListener("click", onClick);

  const unsubscribe = engine.onEvent((event) => {
    if (event.type !== "selection-changed") return;
    window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "selection-changed", blockId: event.blockId });
  });

  return () => {
    document.removeEventListener("click", onClick);
    unsubscribe();
  };
}

/**
 * A small drag-handle element positioned over the selected block (via `computeHandleRect`),
 * dragging which starts an in-canvas reorder through `DragReorderController` (design doc §4/§5,
 * fixing "DragReorderController is currently one-per-document" for the single-document case this
 * slice mounts — see the plan's Global Constraints for why multi-frame support stays deferred).
 * A dedicated handle, not a raw pointerdown-anywhere-on-the-block listener, so dragging doesn't
 * fight with `RichTextEditor`'s own mouse handling for placing a text cursor/selecting text
 * inside an actively-edited block.
 */
function renderSelectionHandle(engine: WysiwygEngine, dragReorder: Pick<DragReorderController, "startDrag">): () => void {
  const handle = document.createElement("div");
  handle.id = "__anglesite-wysiwyg-drag-handle";
  handle.setAttribute(
    "style",
    "position: fixed; width: 14px; height: 14px; margin-left: -18px; cursor: grab; z-index: 2147483647; display: none; background: transparent;",
  );
  document.body.appendChild(handle);

  const reposition = (blockId: BlockId | null) => {
    if (!blockId) {
      handle.style.display = "none";
      return;
    }
    const rect = computeHandleRect(blockId);
    if (!rect) {
      handle.style.display = "none";
      return;
    }
    handle.style.display = "block";
    handle.style.left = `${rect.x}px`;
    handle.style.top = `${rect.y}px`;
  };

  const onPointerDown = (event: PointerEvent) => {
    const blockId = engine.selection.current;
    if (!blockId) return;
    event.preventDefault();
    dragReorder.startDrag(blockId);
  };
  handle.addEventListener("pointerdown", onPointerDown);

  const unsubscribe = engine.onEvent((event) => {
    if (event.type === "selection-changed") reposition(event.blockId);
  });
  reposition(engine.selection.current);

  return () => {
    handle.removeEventListener("pointerdown", onPointerDown);
    unsubscribe();
    handle.remove();
  };
}

// Test-only escape hatch (vitest imports this module directly rather than going through the
// window globals mount() sets) — mirrors no existing precedent in this file because mount.ts had
// no internal functions worth unit-testing before this task; kept to the functions that need it
// rather than exporting everything.
export const __testables = { wireSelection, renderSelectionHandle };

let disposeSelection: (() => void) | null = null;
let disposeHandle: (() => void) | null = null;

// Disposes whatever is currently mounted (if anything) and clears the globals — the shared body
// of `unmount()` below, factored out so `mount()` can call it too (#1225 final-review round 2,
// Finding B) rather than only being reachable from the native `unmountEngine()` call. Safe to call
// when nothing is mounted: all three globals are `undefined` and the optional-chained calls no-op.
function disposeMounted(): void {
  disposeSelection?.();
  disposeSelection = null;
  disposeHandle?.();
  disposeHandle = null;
  window.__anglesiteWysiwygRichTextEditor?.dispose();
  window.__anglesiteWysiwygQualityGates?.dispose();
  window.__anglesiteWysiwygEngine?.dispose();
  window.__anglesiteWysiwygRichTextEditor = undefined;
  window.__anglesiteWysiwygQualityGates = undefined;
  window.__anglesiteWysiwygEngine = undefined;
}

// Injected as a WKUserScript (Task 6); the engine can't self-construct at injection time because
// WysiwygEngine needs an initialModel, which is only known once the native host has fetched one —
// so this just exposes a `mount()` entry point the Swift host calls via `evaluateJavaScript`.
window.__anglesiteWysiwygMount = {
  mount(initialModel: BlockModel): WysiwygEngine {
    // Idempotent: dispose any already-mounted engine/RichTextEditor/QualityGateChips first (#1225
    // final-review round 2, Finding B) — see the original comment on this behavior for why.
    disposeMounted();
    const transport = new NativeHostTransport();
    const engine = new WysiwygEngine(initialModel, transport);
    window.__anglesiteWysiwygEngine = engine;
    window.__anglesiteWysiwygRichTextEditor = new RichTextEditor(engine);
    // Same `transport` instance passed to both — `NativeHostTransport` implements both
    // `HostTransport` and `QualityGateTransport` (#1226 Task 12), so one object owns the whole
    // `window.__anglesiteWysiwygHost` bridge.
    window.__anglesiteWysiwygQualityGates = new QualityGateChips(engine, transport);
    disposeSelection = wireSelection(engine);
    const dragReorder = new DragReorderController(engine, () => {}, document);
    disposeHandle = renderSelectionHandle(engine, dragReorder);
    return engine;
  },
  // The counterpart to `mount` — called by `WYSIWYGCanvasController.unmountEngine()` (#1225
  // final-review fix wave, Findings 1/6) when Site ▸ Edit Page toggles off, or `PreviewView`'s
  // `updateNSView` observes the mounted controller change out from under an already-loaded page.
  unmount(): void {
    disposeMounted();
  },
  // Exposed so Task 11's native drop handler can compute an insertion index without a new bridge
  // message type — the "native pulls via `evaluateJavaScript`" pattern
  // `ComponentEditorCanvasPane.performCanvasDrop` already uses for
  // `window.anglesiteCanvas?.dropTargetAt?.(x, y)`.
  dropTargetAt(x: number, y: number) {
    return computeDropTarget({ x, y }, document.body);
  },
};

// Never a web context menu (spec §8.1: "the engine hit-tests and reports the block under the
// cursor; the host builds the menu"). The engine resolves the right-clicked point to a block id
// via hit-test; the native host (`WYSIWYGScriptHandler`/`WYSIWYGBlockContextMenu`) builds and pops
// up a real NSMenu there. A `document`-level listener (rather than scoping to the mounted canvas
// root) matches `hitTest`'s own `doc.elementFromPoint` — it walks up from whatever's under the
// cursor to the nearest block-id-bearing ancestor, so it doesn't matter which element the event
// started on. No engine mounted yet, or the point misses every block (chrome, empty page margin):
// fall through to the platform's default context menu instead of showing an empty one.
document.addEventListener("contextmenu", (event) => {
  const engine = window.__anglesiteWysiwygEngine;
  if (!engine) return;
  const blockId = engine.hitTest({ x: event.clientX, y: event.clientY });
  if (!blockId) return;
  event.preventDefault();
  window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "context-menu", blockId, x: event.clientX, y: event.clientY });
});

import { WysiwygEngine } from "../engine.js";
import { RichTextEditor } from "../rich-text.js";
import { QualityGateChips } from "../quality-gates.js";
import { KeyboardNavigation } from "../keyboard-nav.js";
import { AccessibilityAnnotator } from "../accessibility.js";
import { NativeHostTransport } from "./native-host-transport.js";
import { DragReorderController, computeDropTarget } from "../drag-drop.js";
import { computeHandleRect, findBlockElement } from "../selection.js";
import { BLOCK_ID_ATTR } from "../hit-test.js";
import { ROOT_PARENT_ID } from "../types.js";
import type { BlockId, BlockModel } from "../types.js";
import type { DropTarget } from "../drag-drop.js";

/**
 * The slot name the *native* side uses for the page root — `WYSIWYGCanvasController.locate`,
 * `insertBlock`, `duplicateSelectedBlock` and `deleteSelectedBlock` all spell it `"main"`, so any
 * target this module hands across the bridge must too. Deliberately not `computeDropTarget`'s own
 * `"default"` default, which is the fixture-host/in-canvas-reorder convention and never leaves JS.
 */
const NATIVE_ROOT_SLOT = "main";

declare global {
  interface Window {
    __anglesiteWysiwygEngine?: WysiwygEngine;
    __anglesiteWysiwygRichTextEditor?: RichTextEditor;
    __anglesiteWysiwygQualityGates?: QualityGateChips;
    __anglesiteWysiwygKeyboardNav?: KeyboardNavigation;
    __anglesiteWysiwygAccessibility?: AccessibilityAnnotator;
    __anglesiteWysiwygMount?: {
      mount: (initialModel: BlockModel, displayNames?: Record<string, string>, selectedBlockId?: BlockId | null) => WysiwygEngine;
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
 * Scrolls the selected block's element into view on every selection change (#1700 — the scroll
 * half of #1697/#1698's native-initiated selection, deliberately left out of that fix pending its
 * own investigation into timing). `block: "nearest"`/`inline: "nearest"` makes this a no-op when
 * the element is already visible, so an ordinary click-to-select (the block is on-screen by
 * definition — the owner just clicked it) never fights the owner's existing scroll position; only
 * a selection that lands off-screen — a block inserted below the fold, or keyboard nav walking past
 * the viewport edge — actually moves the page. A missing element (selection cleared, or the DOM
 * hasn't caught up with a very recent insert yet) is a harmless no-op via the optional chain, same
 * as every other `findBlockElement` caller in this file.
 */
function wireScrollIntoView(engine: WysiwygEngine): () => void {
  return engine.onEvent((event) => {
    if (event.type !== "selection-changed" || !event.blockId) return;
    // `?.` on the method itself, not just the element: jsdom (this file's own test environment)
    // has no layout engine and doesn't implement `Element.scrollIntoView` at all, unlike every
    // real browser engine (including WebKit/WKWebView, this code's actual runtime) — see
    // mount-scroll.test.ts's header comment for the confirmed jsdom gap.
    findBlockElement(event.blockId)?.scrollIntoView?.({ block: "nearest", inline: "nearest" });
  });
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
  // Deliberately opaque, bordered and glyph-bearing rather than the transparent hit-target this
  // started as: a drag affordance nobody can see is a feature nobody discovers. Colors are
  // hard-coded rather than inherited from the site's theme — this is host chrome overlaying an
  // arbitrary owner-authored page, so it has to stay legible against whatever that page paints.
  handle.setAttribute(
    "style",
    [
      "position: fixed",
      "width: 14px",
      "height: 14px",
      "margin-left: -18px",
      "cursor: grab",
      "z-index: 2147483647",
      "display: none",
      "box-sizing: border-box",
      "background: #ffffff",
      "border: 1px solid #6e6e73",
      "border-radius: 3px",
      "box-shadow: 0 1px 2px rgba(0, 0, 0, 0.3)",
      "color: #1c1c1e",
      "font: 10px/12px -apple-system, system-ui, sans-serif",
      "text-align: center",
      "user-select: none",
    ].join("; "),
  );
  handle.textContent = "⠿";
  handle.setAttribute("aria-hidden", "true");
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

  // `preventDefault()` on `pointerdown` suppresses the compatibility *mouse* events but not
  // `click` (Pointer Events spec), so without this a click or a completed drag on the handle
  // bubbles to `wireSelection`'s document-level listener, whose `hitTest` walks up from the handle
  // to `document.body`, finds no block id, and clears the selection — hiding the very handle that
  // was just grabbed. Harmless while the handle was an invisible hit target nobody aimed at;
  // load-bearing now that it's a real affordance.
  const onClick = (event: MouseEvent) => event.stopPropagation();
  handle.addEventListener("click", onClick);

  const unsubscribe = engine.onEvent((event) => {
    if (event.type === "selection-changed") reposition(event.blockId);
  });

  // `computeHandleRect` returns viewport coordinates and the handle is `position: fixed`, so a
  // rect computed at selection time goes stale the moment the page scrolls or the window resizes —
  // leaving a visible handle (and its hit target) parked over unrelated content. Capture-phase
  // `scroll` so scrolling inside a nested scroll container counts too: scroll events from an
  // element don't bubble to `window`, but they do reach it in the capture phase.
  const onViewportChange = () => reposition(engine.selection.current);
  window.addEventListener("scroll", onViewportChange, true);
  window.addEventListener("resize", onViewportChange);

  reposition(engine.selection.current);

  return () => {
    handle.removeEventListener("pointerdown", onPointerDown);
    handle.removeEventListener("click", onClick);
    window.removeEventListener("scroll", onViewportChange, true);
    window.removeEventListener("resize", onViewportChange);
    unsubscribe();
    handle.remove();
  };
}

/**
 * The host half of `DragReorderController`'s `onIndicator` contract (design doc §5: the controller
 * computes a live `DropTarget` during a drag and leaves it to the host to draw). A thin rule laid
 * across the top edge of the block that would be pushed down by the drop — or the bottom edge of
 * the last block, for an append — so a reorder gesture shows where it will land instead of
 * committing blind. Same "host chrome over an arbitrary page" reasoning as the drag handle above:
 * fixed-position, own colors, `pointer-events: none` so it never eats the in-flight drag.
 */
function renderDropIndicator(): { update: (target: DropTarget | null) => void; dispose: () => void } {
  const line = document.createElement("div");
  line.id = "__anglesite-wysiwyg-drop-indicator";
  line.setAttribute(
    "style",
    [
      "position: fixed",
      "height: 2px",
      "z-index: 2147483646",
      "display: none",
      "background: #0a84ff",
      "pointer-events: none",
    ].join("; "),
  );
  line.setAttribute("aria-hidden", "true");
  document.body.appendChild(line);

  const update = (target: DropTarget | null) => {
    if (!target) {
      line.style.display = "none";
      return;
    }
    // Same candidate set `computeDropTarget` measured the index against (drag-drop.ts), so the
    // indicator lands on the block the submitted op would actually insert before.
    const blocks = Array.from(document.body.children).filter((el) => el.hasAttribute(BLOCK_ID_ATTR));
    const atEnd = target.index >= blocks.length;
    const anchor = atEnd ? blocks[blocks.length - 1] : blocks[target.index];
    if (!anchor) {
      line.style.display = "none";
      return;
    }
    const rect = anchor.getBoundingClientRect();
    line.style.display = "block";
    line.style.left = `${rect.left}px`;
    line.style.width = `${rect.width}px`;
    line.style.top = `${(atEnd ? rect.bottom : rect.top) - 1}px`;
  };

  return { update, dispose: () => line.remove() };
}

// Test-only escape hatch (vitest imports this module directly rather than going through the
// window globals mount() sets) — mirrors no existing precedent in this file because mount.ts had
// no internal functions worth unit-testing before this task; kept to the functions that need it
// rather than exporting everything.
export const __testables = { wireSelection, wireScrollIntoView, renderSelectionHandle, renderDropIndicator };

let disposeSelection: (() => void) | null = null;
let disposeScroll: (() => void) | null = null;
let disposeHandle: (() => void) | null = null;
let dropIndicator: { update: (target: DropTarget | null) => void; dispose: () => void } | null = null;
let dragReorder: DragReorderController | null = null;

// Disposes whatever is currently mounted (if anything) and clears the globals — the shared body
// of `unmount()` below, factored out so `mount()` can call it too (#1225 final-review round 2,
// Finding B) rather than only being reachable from the native `unmountEngine()` call. Safe to call
// when nothing is mounted: all globals are `undefined` and the optional-chained calls no-op.
function disposeMounted(): void {
  disposeSelection?.();
  disposeSelection = null;
  disposeScroll?.();
  disposeScroll = null;
  disposeHandle?.();
  disposeHandle = null;
  // Tears down `dragReorder`'s own `pointermove`/`pointerup` document listeners (drag-drop.ts).
  // Without this, a drag in progress when the host unmounts/remounts (e.g. Edit Page toggled off
  // mid-drag) leaves those listeners attached and closing over the engine being disposed below —
  // a later `pointerup` would then call `submit()` on an already-disposed engine.
  dragReorder?.dispose();
  dragReorder = null;
  // After `dragReorder.dispose()` — that call fires `onIndicator(null)`, which reaches back into
  // this indicator, so removing the element first would leave the callback writing to a detached
  // node (harmless, but the ordering is load-bearing for the next reader).
  dropIndicator?.dispose();
  dropIndicator = null;
  window.__anglesiteWysiwygRichTextEditor?.dispose();
  window.__anglesiteWysiwygQualityGates?.dispose();
  window.__anglesiteWysiwygKeyboardNav?.dispose();
  window.__anglesiteWysiwygAccessibility?.dispose();
  window.__anglesiteWysiwygEngine?.dispose();
  window.__anglesiteWysiwygRichTextEditor = undefined;
  window.__anglesiteWysiwygQualityGates = undefined;
  window.__anglesiteWysiwygKeyboardNav = undefined;
  window.__anglesiteWysiwygAccessibility = undefined;
  window.__anglesiteWysiwygEngine = undefined;
}

// Injected as a WKUserScript (Task 6); the engine can't self-construct at injection time because
// WysiwygEngine needs an initialModel, which is only known once the native host has fetched one —
// so this just exposes a `mount()` entry point the Swift host calls via `evaluateJavaScript`.
window.__anglesiteWysiwygMount = {
  mount(initialModel: BlockModel, displayNames: Record<string, string> = {}, selectedBlockId: BlockId | null = null): WysiwygEngine {
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
    window.__anglesiteWysiwygKeyboardNav = new KeyboardNavigation(
      engine,
      window.__anglesiteWysiwygRichTextEditor,
      document,
      // Tab-walks-props (#1616): the actual focus move is native-side (WKWebView → the SwiftUI
      // inspector), so this just relays the request across the bridge, same shape as this
      // function's own `context-menu`/`selection-changed` posts. `blockId` rides along rather
      // than trusting native's own `selectedBlockId` mirror to already be caught up — that
      // mirror updates from the separate `selection-changed` message above, posted and
      // dispatched independently, so a fast select-then-Tab could otherwise land the focus
      // request against native's still-stale prior selection.
      (direction, blockId) => window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "focus-inspector", direction, blockId }),
    );
    window.__anglesiteWysiwygAccessibility = new AccessibilityAnnotator(engine, displayNames);
    // `wireSelection` below posts every `"selection-changed"` engine event to native regardless of
    // cause — clicks (its own hit-test listener), keyboard nav (`KeyboardNavigation` calling
    // `engine.selection.select(...)`), or anything else — since `WysiwygEngine`'s constructor
    // already forwards every `selection.onChange` into its own `onEvent("selection-changed")`
    // stream. A second, keyboard-specific posting subscription here would just double-post on
    // every keyboard-driven selection change; keeping one funnel is both simpler and correct.
    disposeSelection = wireSelection(engine);
    disposeScroll = wireScrollIntoView(engine);
    dropIndicator = renderDropIndicator();
    // Real callback, not a no-op: `DragReorderController` already computes the live drop target on
    // every `pointermove` and hands it to `onIndicator` precisely so a host can draw it.
    dragReorder = new DragReorderController(engine, (target) => dropIndicator?.update(target), document);
    disposeHandle = renderSelectionHandle(engine, dragReorder);
    // Restores native's own selection (`WYSIWYGCanvasController.selectedBlockId`) into this *new*
    // engine's fresh `SelectionState`, now that every selection-reacting listener above is already
    // wired — a real navigation (an HMR reload, ⌘R, a route change) discards the previous engine
    // entirely, so without this every one of those listeners (the drag handle, `AccessibilityAnnotator`,
    // `wireScrollIntoView` above) would silently sit on an unselected canvas even though native still
    // thinks a block is selected. Safe to call unconditionally: `initialModel` is native's own current
    // model, captured after the op that set `selectedBlockId` already applied
    // (`WYSIWYGCanvasController.mountScript(for:displayNames:selectedBlockId:)`'s doc comment), so a
    // non-null `selectedBlockId` is guaranteed to name a block this model actually has.
    engine.selection.select(selectedBlockId);
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
    // `parentId`/`slot` passed explicitly rather than leaning on `computeDropTarget`'s own
    // defaults: this is the one place a JS-computed target crosses into the *native* op stream
    // (`resolveWYSIWYGDropTarget` → `insertBlock`), and every native path — `locate`,
    // `insertBlock`, `duplicateSelectedBlock`, `deleteSelectedBlock` in
    // `WYSIWYGCanvasController` — names the page-root slot `"main"`. Inheriting the JS-side
    // `"default"` here would file drop-inserted blocks under a slot name nothing else on the
    // native side ever writes, which is inert only while the stub transport ignores `slot` at
    // the root.
    return computeDropTarget({ x, y }, document.body, ROOT_PARENT_ID, NATIVE_ROOT_SLOT);
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
  // Keep the engine's own selection in sync with the right-clicked block (#1589 final review):
  // without this, right-click acted on a block that keyboard navigation and AccessibilityAnnotator
  // never learned was selected, so a subsequent arrow press could silently relocate the user's
  // selection instead of moving from the block they just right-clicked.
  engine.selection.select(blockId);
  window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "context-menu", blockId, x: event.clientX, y: event.clientY });
});

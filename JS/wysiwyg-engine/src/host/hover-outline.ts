import type { WysiwygEngine } from "../engine.js";
import { BLOCK_ID_ATTR, blockIdForElement } from "../hit-test.js";
import { findBlockElement } from "../selection.js";
import type { BlockId } from "../types.js";

/** Class the hovered block element carries while the pointer is over it. Class-based (like the
 *  retired overlay's `anglesite-hover`) rather than a positioned chrome element so it needs no
 *  layout reads and follows the block through scrolls and reflows for free. */
export const HOVER_CLASS = "anglesite-block-hover";
const STYLE_ID = "__anglesite-wysiwyg-hover-style";

/**
 * Hover outline on the live page (#1957 parity item 1): moving the pointer over any block outlines
 * it so the owner can see what a click would select, the way the retired click-to-edit overlay
 * outlined editable text. Driven by `mouseover`/`mouseout` targets walked up to the nearest
 * block-id-bearing ancestor (`blockIdForElement`) — deliberately not `hitTest`'s
 * `elementFromPoint`, which needs a real layout engine, so this stays unit-testable in jsdom.
 *
 * The *selected* block is never hover-outlined: it already shows the drag handle
 * (`renderSelectionHandle`), and drawing the candidate ring on top would read as two selections.
 * When the hovered block becomes the selection (a click), the ring clears; when the selection
 * moves elsewhere, the ring comes back on the next pointer move.
 *
 * Returns a disposer that removes the listeners, the class, and the injected stylesheet.
 */
export function renderHoverOutline(engine: WysiwygEngine, doc: Document = document): () => void {
  installStyles(doc);
  let hovered: Element | null = null;

  const clear = () => {
    hovered?.classList.remove(HOVER_CLASS);
    hovered = null;
  };

  const outline = (blockId: BlockId | null) => {
    if (!blockId || blockId === engine.selection.current) {
      clear();
      return;
    }
    const el = findBlockElement(blockId, doc);
    if (el === hovered) return;
    clear();
    if (!el) return;
    el.classList.add(HOVER_CLASS);
    hovered = el;
  };

  const onMouseOver = (event: MouseEvent) => {
    const target = event.target instanceof Element ? event.target : null;
    outline(blockIdForElement(target));
  };
  // `mouseout` fires on every element boundary the pointer crosses, including moves between two
  // descendants of the same block — only clear when the pointer really left the hovered block's
  // subtree (or the document: `relatedTarget` is null at the viewport edge).
  const onMouseOut = (event: MouseEvent) => {
    if (!hovered) return;
    const next = event.relatedTarget instanceof Node ? event.relatedTarget : null;
    if (next && hovered.contains(next)) return;
    clear();
  };
  doc.addEventListener("mouseover", onMouseOver);
  doc.addEventListener("mouseout", onMouseOut);

  const unsubscribe = engine.onEvent((event) => {
    if (event.type !== "selection-changed") return;
    if (hovered && hovered.getAttribute(BLOCK_ID_ATTR) === event.blockId) clear();
  });

  return () => {
    doc.removeEventListener("mouseover", onMouseOver);
    doc.removeEventListener("mouseout", onMouseOut);
    unsubscribe();
    clear();
    doc.getElementById(STYLE_ID)?.remove();
  };
}

function installStyles(doc: Document): void {
  if (doc.getElementById(STYLE_ID)) return;
  const style = doc.createElement("style");
  style.id = STYLE_ID;
  // Same blue as the drop indicator (`renderDropIndicator`) and the retired overlay's hover ring,
  // so the two editing surfaces never looked like different apps during the transition.
  style.textContent =
    `[${BLOCK_ID_ATTR}].${HOVER_CLASS} { outline: 2px solid rgba(10, 132, 255, 0.8); outline-offset: 2px; }`;
  doc.head.appendChild(style);
}

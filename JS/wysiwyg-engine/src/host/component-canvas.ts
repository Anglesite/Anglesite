/**
 * Component-harness canvas module. Active only on /_anglesite/component/*
 * pages (the Component Editor's isolated canvas). Reports clicks as
 * structured selections + computed styles to native over the `wysiwyg` bridge, and exposes
 * highlight and interactive structure/style-edit hooks so the native view can drive the canvas.
 * Installed by `page-bridge.ts` at injection time instead of the page-level engine. Moved here
 * verbatim from the retired `JS/edit-overlay/src/component-canvas.ts` (#1957); only the bridge
 * namespace changed.
 */

const HARNESS_PREFIX = "/_anglesite/component/";
const RING_CLASS = "anglesite-canvas-ring";
const SCRUB_STYLE_ID = "anglesite-scrub";
const INSTALLED_FLAG = "__anglesiteComponentCanvasInstalled" as const;

// Curated list shown in the inspector's Computed section.
const REPORTED_PROPERTIES = [
  "display", "position", "width", "height",
  "margin-top", "margin-right", "margin-bottom", "margin-left",
  "padding-top", "padding-right", "padding-bottom", "padding-left",
  "font-family", "font-size", "font-weight", "line-height",
  "color", "background-color", "border-radius",
] as const;

export interface SourceLoc {
  file: string;
  line: number;
  column: number;
}

export function isHarnessPage(): boolean {
  return location.pathname.startsWith(HARNESS_PREFIX);
}

export function sourceLoc(el: Element): SourceLoc | null {
  let node: Element | null = el;
  while (node && node !== document.body) {
    const loc = node.getAttribute("data-astro-source-loc");
    const file = node.getAttribute("data-astro-source-file");
    if (loc && file) {
      const [line, column] = loc.split(":").map(Number);
      return { file, line: line ?? 0, column: column ?? 0 };
    }
    node = node.parentElement;
  }
  return null;
}

/** Mount the component canvas onto `window`/`document`. Safe to call more than once. */
export function installComponentCanvas(): void {
  if (!isHarnessPage()) return;
  const win = window as unknown as { [INSTALLED_FLAG]?: boolean };
  if (win[INSTALLED_FLAG]) return;
  win[INSTALLED_FLAG] = true;
  document.addEventListener("click", onClick, true);
  (window as unknown as Record<string, unknown>).anglesiteCanvas = {
    highlight(line: number, column: number): void {
      clearRing();
      const el = findByLoc(line, column);
      if (el) drawRing(el);
    },
    clear: clearRing,
    scrub,
    clearScrub,
    dropTargetAt,
  };
}

/**
 * `selector`/`property`/`value` are interpolated into the scrub `<style>` tag's raw text — a
 * `{` or `}` in any of them would break out of the intended `selector { property: value; }`
 * block and inject arbitrary rules (or attribute selectors) into this harness page's live DOM
 * while a drag/scrub is in progress. This is a live-preview-only override (the eventual real
 * `apply_edit` op is what actually validates and commits the value), so fail safe by skipping
 * the scrub entirely rather than trusting unescaped input.
 */
function containsUnsafeCssBreak(value: string): boolean {
  return value.includes("{") || value.includes("}");
}

function scrub(selector: string, property: string, value: string): void {
  if (
    containsUnsafeCssBreak(selector) ||
    containsUnsafeCssBreak(property) ||
    containsUnsafeCssBreak(value)
  ) {
    return;
  }
  let style = document.getElementById(SCRUB_STYLE_ID) as HTMLStyleElement | null;
  if (!style) {
    style = document.createElement("style");
    style.id = SCRUB_STYLE_ID;
    document.head.appendChild(style);
  }
  style.textContent = `${selector} { ${property}: ${value}; }`;
}

function clearScrub(): void {
  document.getElementById(SCRUB_STYLE_ID)?.remove();
}

/// Astro's dev server stamps `data-astro-source-loc` at the END of an
/// element's opening tag, not at its parse position — so native passes the
/// PARSE column (from the component's structured model), which never equals
/// the annotation column on the matching element. Match on line only via a
/// prefix selector, then among same-line candidates pick the one whose
/// annotated column is nearest >= the requested column (closest following
/// start), falling back to the first same-line match if none qualifies.
function findByLoc(line: number, column: number): Element | null {
  const candidates = Array.from(document.querySelectorAll(`[data-astro-source-loc^="${line}:"]`));
  if (candidates.length === 0) return null;
  let best: Element | null = null;
  let bestColumn = Infinity;
  for (const el of candidates) {
    const loc = el.getAttribute("data-astro-source-loc") ?? "";
    const col = Number(loc.split(":")[1]);
    if (!Number.isNaN(col) && col >= column && col < bestColumn) {
      bestColumn = col;
      best = el;
    }
  }
  return best ?? candidates[0] ?? null;
}

export interface DropTarget extends SourceLoc {
  zone: "before" | "after" | "into";
}

/**
 * Nearest droppable element at a canvas-local point, plus which third of its bounding box the
 * point falls in — top third = "before" (insert as a preceding sibling), bottom third =
 * "after" (following sibling), middle third = "into" (append as the last child). Used during
 * a native drag-over to drive drop-target highlighting and, on drop, to resolve the insertion
 * point for a palette→canvas insert-node.
 */
function dropTargetAt(x: number, y: number): DropTarget | null {
  const el = document.elementFromPoint(x, y);
  if (!el) return null;
  const loc = sourceLoc(el);
  if (!loc) return null;
  const rect = (sourceLocElement(el) ?? el).getBoundingClientRect();
  const relativeY = y - rect.top;
  const zone: DropTarget["zone"] =
    relativeY < rect.height / 3 ? "before" : relativeY > (rect.height * 2) / 3 ? "after" : "into";
  return { ...loc, zone };
}

/** Walks up from `el` to the nearest ancestor (inclusive) actually carrying the
 *  `data-astro-source-loc` attribute `sourceLoc` resolved from — needed because `sourceLoc`
 *  itself only returns the loc value, not which element it was found on, and drop-zone
 *  geometry must be measured against THAT element's box, not the original event target's. */
function sourceLocElement(el: Element): Element | null {
  let node: Element | null = el;
  while (node && node !== document.body) {
    if (node.hasAttribute("data-astro-source-loc")) return node;
    node = node.parentElement;
  }
  return null;
}

function onClick(event: MouseEvent): void {
  const target = event.target instanceof Element ? event.target : null;
  if (!target) return;
  event.preventDefault();
  event.stopPropagation();
  const loc = sourceLoc(target);
  post({
    type: "anglesite:canvas-selection",
    file: loc?.file ?? null,
    line: loc?.line ?? null,
    column: loc?.column ?? null,
  });
  reportComputedStyles(target);
  clearRing();
  drawRing(target);
}

function reportComputedStyles(el: Element): void {
  const computed = getComputedStyle(el);
  const styles: Record<string, string> = {};
  for (const property of REPORTED_PROPERTIES) {
    styles[property] = computed.getPropertyValue(property);
  }
  post({ type: "anglesite:computed-styles", styles });
}

function drawRing(el: Element): void {
  const rect = el.getBoundingClientRect();
  const ring = document.createElement("div");
  ring.className = RING_CLASS;
  ring.style.cssText =
    `position:absolute;pointer-events:none;z-index:2147483646;` +
    `border:2px solid #0a84ff;border-radius:2px;` +
    `left:${rect.left + scrollX - 2}px;top:${rect.top + scrollY - 2}px;` +
    `width:${rect.width}px;height:${rect.height}px;`;
  document.body.appendChild(ring);
}

function clearRing(): void {
  document.querySelectorAll(`.${RING_CLASS}`).forEach((n) => n.remove());
}

interface WebKitHost {
  webkit?: { messageHandlers?: { wysiwyg?: { postMessage(msg: unknown): void } } };
}

function post(msg: unknown): void {
  (window as WebKitHost).webkit?.messageHandlers?.wysiwyg?.postMessage(msg);
}

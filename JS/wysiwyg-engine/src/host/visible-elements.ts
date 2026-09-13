// VisibleElementReport collector — feeds Phase B onscreen awareness (App Intents).
//
// Watches priority-category elements (headings, images, nav items, interactive controls) via
// IntersectionObserver, and posts a typed `anglesite:visible-elements` message on the `wysiwyg`
// bridge whenever the visible set changes. The native side (`PreviewAnnotationProvider`, #146)
// maps those reports into `ElementEntity` instances that AppKit's `appEntityUIElementProvider`
// (#148) returns when Siri hit-tests the WKWebView. Installed for every non-harness page by
// `page-bridge.ts` at injection time — independent of whether a block engine is mounted.
//
// Selector field: we send structured `ElementInfo` rather than a CSS string. The issue (#145)
// sketched `selector: string`, but `element-info.ts` (decided in #18) keeps the CSS-resolution
// strategy in one place — the plugin's `server/selector.mjs`. Moved here verbatim from the
// retired `JS/edit-overlay/src/visible-elements.ts` (#1957); only the bridge namespace changed.

import { elementInfoFor, type ElementInfo } from "./element-info.js";

export interface VisibleElement {
  /** Stable per-tab id. Sourced from `data-anglesite-id` when present, otherwise a generated
   *  `v-…` string kept stable across reports via an internal WeakMap (no DOM mutation). */
  id: string;
  tag: string;
  /** Structured selector payload — same shape used by `apply-edit` messages. */
  selector: ElementInfo;
  rect: { x: number; y: number; width: number; height: number };
  /** `textContent` whitespace-collapsed and truncated to 120 chars. Absent if empty.
   *  Deliberately not `innerText` — `innerText` forces a layout flush per read, which would
   *  pile up to 50× per emit on busy pages. `textContent` is essentially free; the trade-off
   *  is that it can include hidden text (`display:none`, `aria-hidden`). For the Siri-match
   *  use case the false positives are bounded and self-correcting (the user can rephrase). */
  text?: string;
  /** Present for `<img>` only. */
  src?: string;
  /** `alt` attribute — only populated for `<img>`. Critical for the Siri use case: `<img>` has
   *  no `textContent`, so without `alt` the only name to match against is the `src` path. */
  alt?: string;
  /** `aria-label` attribute, when present. Fills the name role for icon controls and other
   *  elements whose visible text doesn't describe them ("✕" buttons, glyph-only links, etc.). */
  ariaLabel?: string;
  /** ARIA `role` attribute, if any. */
  role?: string;
  /** Current page route at report time (`location.pathname`). */
  pagePath?: string;
}

export interface VisibleElementReport {
  type: "anglesite:visible-elements";
  elements: VisibleElement[];
}

const MAX_ELEMENTS = 50;
const MAX_TEXT = 120;
const SCROLL_DEBOUNCE_MS = 200;
const MUTATION_DEBOUNCE_MS = 500;
const RESIZE_DEBOUNCE_MS = 200;

const INSTALLED_FLAG = "__anglesiteVisibleElementsInstalled" as const;

/**
 * Priority categories. Lower index = reported first. -1 means "not a candidate".
 *
 *   0: headings (H1–H6)
 *   1: images  (IMG)
 *   2: nav items (A inside <nav> or [role=navigation])
 *   3: interactive (BUTTON, INPUT, SELECT, TEXTAREA, SUMMARY, A outside nav, [role=button/link/checkbox/…])
 */
function categoryOf(el: Element): number {
  const tag = el.tagName;
  if (/^H[1-6]$/.test(tag)) return 0;
  if (tag === "IMG") return 1;
  if (tag === "A" && isInsideNav(el)) return 2;
  if (isInteractive(el)) return 3;
  return -1;
}

function isInsideNav(el: Element): boolean {
  let cur: Element | null = el.parentElement;
  while (cur) {
    if (cur.tagName === "NAV") return true;
    if (cur.getAttribute("role") === "navigation") return true;
    cur = cur.parentElement;
  }
  return false;
}

const INTERACTIVE_TAGS = new Set(["BUTTON", "INPUT", "SELECT", "TEXTAREA", "SUMMARY", "A"]);
const INTERACTIVE_ROLES = new Set([
  "button", "link", "checkbox", "radio", "switch", "menuitem", "tab", "option",
]);

function isInteractive(el: Element): boolean {
  if (INTERACTIVE_TAGS.has(el.tagName)) return true;
  const role = el.getAttribute("role");
  if (role && INTERACTIVE_ROLES.has(role)) return true;
  return false;
}

/** Single selector covering every candidate the IntersectionObserver should watch. */
const CANDIDATE_SELECTOR =
  "h1, h2, h3, h4, h5, h6, img, a, button, input, select, textarea, summary, " +
  "[role=button], [role=link], [role=checkbox], [role=radio], [role=switch], " +
  "[role=menuitem], [role=tab], [role=option]";

function findCandidates(root: ParentNode = document): Element[] {
  return Array.from(root.querySelectorAll(CANDIDATE_SELECTOR));
}

const idMap = new WeakMap<Element, string>();
let idCounter = 0;
function idFor(el: Element): string {
  const fromAttr = el.getAttribute("data-anglesite-id");
  if (fromAttr) return fromAttr;
  const existing = idMap.get(el);
  if (existing) return existing;
  idCounter += 1;
  const generated = `v-${idCounter.toString(36)}`;
  idMap.set(el, generated);
  return generated;
}

function condenseText(raw: string): string {
  const normalized = raw.replace(/\s+/g, " ").trim();
  if (normalized.length <= MAX_TEXT) return normalized;
  return normalized.slice(0, MAX_TEXT - 1) + "…";
}

function shape(el: Element, pagePath: string): VisibleElement {
  const rect = el.getBoundingClientRect();
  const text = condenseText(el.textContent ?? "");
  const role = el.getAttribute("role") ?? undefined;
  const isImg = el.tagName === "IMG";
  const src = isImg ? (el as HTMLImageElement).getAttribute("src") ?? undefined : undefined;
  const alt = isImg ? (el as HTMLImageElement).getAttribute("alt") ?? undefined : undefined;
  const ariaLabel = el.getAttribute("aria-label") ?? undefined;
  const out: VisibleElement = {
    id: idFor(el),
    tag: el.tagName,
    selector: elementInfoFor(el),
    rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
    pagePath,
  };
  if (text) out.text = text;
  if (src) out.src = src;
  if (alt) out.alt = alt;
  if (ariaLabel) out.ariaLabel = ariaLabel;
  if (role) out.role = role;
  return out;
}

/**
 * Filter, prioritize, and shape a candidate list into a report payload.
 *
 * Pure (modulo the id WeakMap and rect / textContent reads) — given the same DOM state, the
 * same input list, and the same `pagePath`, returns the same output. Stable sort within a
 * category preserves DOM order, which gives Siri a predictable "first heading", "first image",
 * etc.
 *
 * Performance: each `shape()` call invokes `getBoundingClientRect()`, which can force a
 * style/layout flush. For pages with many priority elements this is a known cost — bounded
 * by the 50-element cap. If it becomes a hot spot in real-world traces, the path forward is
 * to cache `entry.boundingClientRect` from the `IntersectionObserver` callback (it's already
 * computed by the browser at zero cost) and only fall back to a live read in the scroll /
 * resize / mutation paths.
 */
export function collectVisibleElements(
  candidates: Element[],
  pagePath: string,
): VisibleElement[] {
  const tagged = candidates
    .map((el) => ({ el, cat: categoryOf(el) }))
    .filter((x) => x.cat >= 0);
  // Stable sort: JS Array.sort is stable as of ES2019.
  tagged.sort((a, b) => a.cat - b.cat);
  const capped = tagged.slice(0, MAX_ELEMENTS);
  return capped.map(({ el }) => shape(el, pagePath));
}

interface WebKitWindow {
  webkit?: {
    messageHandlers?: {
      wysiwyg?: { postMessage: (body: unknown) => void };
    };
  };
}

/** Post a report to native. Returns `false` (no throw) if the WKWebView bridge is absent —
 *  e.g. when the engine is loaded in a plain browser tab for local debugging. */
export function postVisibleElements(
  report: VisibleElementReport,
  win: WebKitWindow = window as unknown as WebKitWindow,
): boolean {
  const handler = win.webkit?.messageHandlers?.wysiwyg;
  if (!handler) return false;
  handler.postMessage(report);
  return true;
}

interface InstallableWindow {
  [INSTALLED_FLAG]?: boolean;
}

/**
 * Install the reporter: observe priority-category elements via IntersectionObserver, debounce
 * scroll / mutation / resize triggers, and post a `VisibleElementReport` each time the
 * visible set is non-empty.
 *
 * Idempotent — a second call is a no-op. Returns silently when `IntersectionObserver` is
 * unavailable (older environments / non-WKWebView hosts).
 *
 * Internal `emit()` posts via the default `window`. The `postVisibleElements` `win` seam exists
 * for unit-test direct invocation; the install path is integration-tested via the global
 * `window.webkit` stub.
 */
export function installVisibleElementsReporter(): void {
  const win = window as unknown as InstallableWindow;
  if (win[INSTALLED_FLAG]) return;
  if (typeof IntersectionObserver === "undefined") return;
  win[INSTALLED_FLAG] = true;

  const visible = new Set<Element>();
  const observed = new Set<Element>();
  // Dedup key for the last-sent report — the sorted, joined `id` list. Avoids redundant IPC
  // when the user scrolls slowly within a region whose visible set doesn't change.
  let lastEmittedKey = "";

  const observer = new IntersectionObserver((entries) => {
    let changed = false;
    for (const entry of entries) {
      if (entry.isIntersecting) {
        if (!visible.has(entry.target)) {
          visible.add(entry.target);
          changed = true;
        }
      } else if (visible.delete(entry.target)) {
        changed = true;
      }
    }
    // The browser's IntersectionObserver batches per-frame, so emitting synchronously here
    // doesn't fan out into a torrent. The 4 documented triggers (scroll/mutation/resize, plus
    // initial load — all in the issue) are how we *throttle*: the observer is the gating
    // mechanism, the triggers control rate. Emitting here also covers the initial-load case
    // since the observer fires its first batch right after `observe()`.
    if (changed) emit();
  });

  function reconcileObservations(): void {
    const candidates = new Set(findCandidates());
    for (const el of candidates) {
      if (!observed.has(el)) {
        observer.observe(el);
        observed.add(el);
      }
    }
    // Snapshot-then-iterate: mutating a `Set` during `for…of` is safe per ES2019 iterator
    // semantics, but it reads like a bug. The spread copy is O(n) and n is bounded by the
    // candidate count (≤50 in practice). Lint sees the spread as redundant — it isn't here.
    // oxlint-disable-next-line no-useless-spread
    for (const el of [...observed]) {
      if (!candidates.has(el)) {
        observer.unobserve(el);
        observed.delete(el);
        visible.delete(el);
      }
    }
  }

  function emit(): void {
    if (visible.size === 0) return;
    const elements = collectVisibleElements(Array.from(visible), location.pathname);
    if (elements.length === 0) return;
    // Dedup against the previous report's id set (sorted so visible-set permutations don't
    // count as changes). Rects-only changes between reports don't trigger a re-emit; the
    // next mutation / resize will get a fresh batch when geometry actually matters.
    const key = elements.map((e) => e.id).sort().join(",");
    if (key === lastEmittedKey) return;
    lastEmittedKey = key;
    const report: VisibleElementReport = { type: "anglesite:visible-elements", elements };
    postVisibleElements(report);
  }

  // Initial reconcile. The observer's first callback (async, on next layout) populates
  // `visible` and triggers the initial-load emit — no explicit `emit()` needed here.
  reconcileObservations();

  // Scroll: debounced. Passive listener — we never preventDefault.
  let scrollTimer: ReturnType<typeof setTimeout> | undefined;
  window.addEventListener("scroll", () => {
    if (scrollTimer !== undefined) clearTimeout(scrollTimer);
    scrollTimer = setTimeout(() => {
      scrollTimer = undefined;
      emit();
    }, SCROLL_DEBOUNCE_MS);
  }, { passive: true, capture: true });

  // Window resize: debounced, also re-reconciles since layout shifts may add/remove candidates.
  let resizeTimer: ReturnType<typeof setTimeout> | undefined;
  window.addEventListener("resize", () => {
    if (resizeTimer !== undefined) clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      resizeTimer = undefined;
      reconcileObservations();
      emit();
    }, RESIZE_DEBOUNCE_MS);
  }, { passive: true });

  // DOM mutations: debounced. Re-reconcile so newly-added candidates start being observed
  // (and removed ones are dropped from the visible set). `alt` and `aria-label` are in the
  // filter because `shape()` reads them — changes should refresh the report so Siri picks up
  // renamed assets / relabeled controls without waiting for the next mutation cycle.
  let mutationTimer: ReturnType<typeof setTimeout> | undefined;
  const mutationObserver = new MutationObserver(() => {
    if (mutationTimer !== undefined) clearTimeout(mutationTimer);
    mutationTimer = setTimeout(() => {
      mutationTimer = undefined;
      reconcileObservations();
      // Dedup is based on id set, which doesn't change just because `alt` changed. Force a
      // re-emit by clearing the cache here — geometry / attribute changes are exactly the
      // case the mutation trigger exists to surface.
      lastEmittedKey = "";
      emit();
    }, MUTATION_DEBOUNCE_MS);
  });
  mutationObserver.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["src", "alt", "role", "aria-label", "data-anglesite-id"],
  });
}

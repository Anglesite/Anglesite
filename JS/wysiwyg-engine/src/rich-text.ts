import type { RichTextRun } from "./types.js";
import type { BlockId } from "./types.js";
import type { WysiwygEngine, EngineEvent } from "./engine.js";
import { findBlockElement } from "./selection.js";

const INLINE_TAG_TO_RUN_KIND: Record<string, RichTextRun["kind"]> = {
  strong: "strong",
  b: "strong",
  em: "em",
  i: "em",
  a: "link",
  code: "code",
};

/**
 * Serializes a contenteditable element's live DOM into the honest-runs vocabulary (spec §4): only
 * strong/em/link/code ever survive as anything but text. Anything else the browser's
 * contenteditable implementation might inject — a stray `<div>` from a paste, a styled `<span>` —
 * is not represented; its text content flattens into the surrounding run. This is the structural
 * backstop for roundtrip honesty, independent of how careful the editing UI upstream is.
 *
 * Composing two recognized formats (bold containing italic, etc.) nests one recognized tag inside
 * another — that nesting is preserved via `RichTextRun.children`, not flattened. `text` on a
 * composed run still carries the full flattened content, so a consumer that ignores `children`
 * gets a reasonable plain-text fallback rather than nothing.
 */
export function runsFromElement(el: Element): RichTextRun[] {
  const runs: RichTextRun[] = [];
  for (const node of Array.from(el.childNodes)) {
    const run = runFromNode(node);
    if (run) runs.push(run);
  }
  return mergeAdjacentTextRuns(runs);
}

function runFromNode(node: ChildNode): RichTextRun | null {
  if (node.nodeType === Node.TEXT_NODE) {
    const text = node.textContent ?? "";
    return text.length > 0 ? { kind: "text", text } : null;
  }
  if (node.nodeType !== Node.ELEMENT_NODE) return null;

  const el = node as Element;
  const tag = el.tagName.toLowerCase();
  const kind = INLINE_TAG_TO_RUN_KIND[tag];
  const text = el.textContent ?? "";
  if (text.length === 0) return null;

  if (!kind) return { kind: "text", text };

  // Composing two recognized formats (e.g. toggling italic on a selection already inside a bold
  // run) nests one recognized tag inside another — an entirely ordinary editing gesture. Recurse
  // so that composition survives a commit instead of collapsing to a single flat run via
  // `textContent`; `children` is populated only when a genuinely nested format is present, so a
  // plain (non-composed) recognized run stays exactly as flat as before.
  const children = runsFromElement(el);
  const isComposed = children.some((child) => child.kind !== "text");

  if (kind === "link") {
    const href = el.getAttribute("href") ?? "";
    return isComposed ? { kind, text, href, children } : { kind, text, href };
  }
  return isComposed ? { kind, text, children } : { kind, text };
}

function mergeAdjacentTextRuns(runs: RichTextRun[]): RichTextRun[] {
  const merged: RichTextRun[] = [];
  for (const run of runs) {
    const prev = merged[merged.length - 1];
    if (prev && prev.kind === "text" && run.kind === "text") {
      prev.text += run.text;
    } else {
      merged.push({ ...run });
    }
  }
  return merged;
}

/** Coalesces a burst of changes into a single `commit()` call after `delayMs` of quiet, or
 *  immediately via `flush()` — the mechanism behind `RichTextEditor`'s debounced `editText`
 *  commits (design doc §4). Pure timer logic, no DOM dependency. */
export class DebouncedCommitter {
  #commit: () => void;
  #delayMs: number;
  #timer: ReturnType<typeof setTimeout> | null = null;

  constructor(commit: () => void, delayMs: number) {
    this.#commit = commit;
    this.#delayMs = delayMs;
  }

  notifyChange(): void {
    this.cancel();
    this.#timer = setTimeout(() => {
      this.#timer = null;
      this.#commit();
    }, this.#delayMs);
  }

  /** Commits now if a debounced commit is pending; otherwise does nothing. */
  flush(): void {
    const pending = this.#timer !== null;
    this.cancel();
    if (pending) this.#commit();
  }

  /** Discards a pending commit without running it. */
  cancel(): void {
    if (this.#timer !== null) {
      clearTimeout(this.#timer);
      this.#timer = null;
    }
  }
}

/** Walks up from `node` to the nearest ancestor (inclusive) whose tag matches `tagName`, stopping
 *  at (and not including past) `root`. */
export function findAncestorTag(node: Node, tagName: string, root: Element): HTMLElement | null {
  let current: Node | null = node;
  while (current && current !== root.parentNode) {
    if (current.nodeType === Node.ELEMENT_NODE && (current as Element).tagName.toLowerCase() === tagName) {
      return current as HTMLElement;
    }
    if (current === root) return null;
    current = current.parentNode;
  }
  return null;
}

/** Wraps `range`'s contents in a new `tagName` element, replacing the range with it, and leaves
 *  the element's contents selected (so a follow-up format command composes naturally). */
export function wrapRange(range: Range, tagName: string, doc: Document = document): HTMLElement {
  const wrapper = doc.createElement(tagName);
  wrapper.appendChild(range.extractContents());
  range.insertNode(wrapper);
  range.selectNodeContents(wrapper);
  const selection = doc.getSelection();
  selection?.removeAllRanges();
  selection?.addRange(range);
  return wrapper;
}

/** Replaces `el` with its own children, at the same position — the inverse of `wrapRange`. */
export function unwrapElement(el: HTMLElement): void {
  const parent = el.parentNode;
  if (!parent) return;
  while (el.firstChild) parent.insertBefore(el.firstChild, el);
  parent.removeChild(el);
}

export type FormatKind = "strong" | "em" | "code";

const FORMAT_TAG: Record<FormatKind, string> = { strong: "strong", em: "em", code: "code" };

/**
 * Toggles `kind` on the current selection within `root`: unwraps if the selection is already
 * inside a matching element, otherwise wraps it. Live-`Selection`-dependent — real behavior is
 * covered by Playwright e2e goldens (Task 9), not jsdom, matching this package's established
 * test split (jsdom has no real text-selection behavior to verify against).
 */
export function toggleInlineFormat(root: HTMLElement, kind: FormatKind, doc: Document = document): void {
  const selection = doc.getSelection();
  if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return;
  const range = selection.getRangeAt(0);
  if (!root.contains(range.commonAncestorContainer)) return;

  const tagName = FORMAT_TAG[kind];
  const existing = findAncestorTag(range.commonAncestorContainer, tagName, root);
  if (existing) {
    unwrapElement(existing);
  } else {
    wrapRange(range, tagName, doc);
  }
}

/** Wraps the current selection in `<a href>`, replacing any existing link ancestor first. */
export function setLinkFormat(root: HTMLElement, href: string, doc: Document = document): void {
  const selection = doc.getSelection();
  if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return;
  const range = selection.getRangeAt(0);
  if (!root.contains(range.commonAncestorContainer)) return;

  const existing = findAncestorTag(range.commonAncestorContainer, "a", root);
  if (existing) {
    // Unwrapping moves the link's children, and moving a node collapses any live Range boundary
    // inside it — so re-linking text that's already a link used to wrap nothing. The boundary
    // nodes themselves survive the move; re-anchor the range on them afterwards.
    const { startContainer, startOffset, endContainer, endOffset } = range;
    unwrapElement(existing);
    range.setStart(startContainer, startOffset);
    range.setEnd(endContainer, endOffset);
  }
  const anchor = wrapRange(range, "a", doc);
  anchor.setAttribute("href", href);
}

/** Removes the link ancestor around the current selection or caret, if any. */
export function unsetLinkFormat(root: HTMLElement, doc: Document = document): void {
  const selection = doc.getSelection();
  if (!selection || selection.rangeCount === 0) return;
  const existing = findAncestorTag(selection.getRangeAt(0).commonAncestorContainer, "a", root);
  if (existing) unwrapElement(existing);
}

/** Schemes a link the owner types may never carry: each runs script or smuggles content
 *  instead of navigating. Rejected outright rather than escaped — there's no safe spelling. */
const UNSAFE_LINK_SCHEMES = new Set(["javascript", "vbscript", "data"]);

/**
 * Turns what an owner types into a link field into an `href` (#2216), or `null` when it can't be
 * one. Whitespace-only input normalizes to `""`, which `commitLinkEdit` treats as Remove Link —
 * same as clearing the URL field in Pages or Mail. An explicit scheme (`https:`, `mailto:`, `tel:`)
 * and a site-relative reference (`/about`, `#top`, `?q`, `./x`, `../x`) pass through untouched.
 * A bare address gets the scheme people leave off: `name@example.com` → `mailto:`, anything else
 * (`example.com/path`) → `https://`.
 */
export function normalizeHref(input: string): string | null {
  const value = input.trim();
  if (value.length === 0) return "";
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(value)?.[1]?.toLowerCase();
  if (scheme !== undefined) {
    // `localhost:4321` parses as a scheme too; treat a scheme followed by digits as a host:port.
    if (/^[a-z][a-z0-9+.-]*:\d/i.test(value) && !value.includes("://")) return `https://${value}`;
    return UNSAFE_LINK_SCHEMES.has(scheme) ? null : value;
  }
  if (/^[/#?]/.test(value) || value.startsWith("./") || value.startsWith("../")) return value;
  if (/\s/.test(value)) return null;
  if (/^[^@/]+@[^@/]+\.[^@/]+$/.test(value)) return `mailto:${value}`;
  return `https://${value}`;
}

/** A selection rect in the top-level page's viewport coordinates (CSS px). */
export interface ViewportRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** What `beginLinkEdit` hands the native host to anchor and pre-fill its URL popover. */
export interface LinkEditContext {
  /** The existing link's `href` when the selection is inside one, else `null`. */
  href: string | null;
  /** The selected text, for the popover's accessibility label. */
  text: string;
  /** Where to anchor the popover. */
  rect: ViewportRect;
}

/** Why `commitLinkEdit` didn't change the page. `invalid`: the address can't be a link (keep the
 *  popover open). `stale`: no held session, or the held text was replaced underneath it. */
export type LinkCommitResult = "applied" | "removed" | "invalid" | "stale";

/**
 * Translates `rect` from `doc`'s own viewport into the top-level viewport by adding each
 * enclosing iframe's offset — BreakpointCanvas renders blocks into same-origin frames, and the
 * native host only knows the top-level web view's coordinate space.
 */
function toTopLevelViewport(rect: DOMRect, doc: Document): ViewportRect {
  let x = rect.left;
  let y = rect.top;
  let view: Window | null = doc.defaultView;
  while (view && view !== view.parent) {
    let frame: Element | null = null;
    try {
      frame = view.frameElement;
    } catch {
      break; // Cross-origin parent: nothing further to translate through.
    }
    if (!frame) break;
    const frameRect = frame.getBoundingClientRect();
    x += frameRect.left + (frame as HTMLElement).clientLeft;
    y += frameRect.top + (frame as HTMLElement).clientTop;
    view = view.parent;
  }
  return { x, y, width: rect.width, height: rect.height };
}

export interface RichTextEditorOptions {
  debounceMs?: number;
  /** How long a blur waits before ending the session, so focus churn around native UI or a
   *  breakpoint frame doesn't end an edit that never really lost focus (#2216). */
  blurExitDelayMs?: number;
}

const DEFAULT_DEBOUNCE_MS = 400;
const DEFAULT_BLUR_EXIT_DELAY_MS = 200;

/**
 * Contenteditable lifecycle for one text block at a time (design doc §4). `enter()` activates
 * editing and snapshots the current runs as the commit baseline; an `input` listener schedules a
 * debounced `editText` commit; `exit()` flushes any pending commit and deactivates. `previousRuns`
 * on every commit is always the baseline captured at `enter()`, not the prior debounce tick — so a
 * version-mismatch rejection mid-edit discards the whole in-progress edit in one step rather than
 * reconstructing intermediate state.
 */
export class RichTextEditor {
  #engine: WysiwygEngine;
  #committer: DebouncedCommitter;
  #activeBlockId: BlockId | null = null;
  #activeElement: HTMLElement | null = null;
  #baselineRuns: RichTextRun[] = [];
  #unsubscribeEngine: (() => void) | null = null;
  #blurExitDelayMs: number;
  #blurTimer: ReturnType<typeof setTimeout> | null = null;
  /** The selection saved by `beginLinkEdit`, while the native link popover holds the session. */
  #heldRange: Range | null = null;
  #onInput = () => this.#committer.notifyChange();
  /**
   * Blur no longer ends the session on the spot (#2216). While a link edit holds the session,
   * blur is expected — focus is in the native URL field — and is ignored. Otherwise the exit waits
   * `blurExitDelayMs`, then happens only if focus really left: the element isn't the active
   * element, or the document itself lost focus (the owner clicked native app chrome).
   */
  #onBlur = () => {
    if (this.#heldRange) return;
    this.#cancelBlurTimer();
    this.#blurTimer = setTimeout(() => {
      this.#blurTimer = null;
      const el = this.#activeElement;
      if (!el || this.#heldRange) return;
      const doc = el.ownerDocument;
      if (doc.activeElement !== el || !doc.hasFocus()) this.exit();
    }, this.#blurExitDelayMs);
  };
  #onKeydown = (event: KeyboardEvent) => {
    if (event.key === "Escape") {
      this.exit();
      event.stopPropagation();
    }
  };

  constructor(engine: WysiwygEngine, options: RichTextEditorOptions = {}) {
    this.#engine = engine;
    this.#committer = new DebouncedCommitter(() => this.#commit(), options.debounceMs ?? DEFAULT_DEBOUNCE_MS);
    this.#blurExitDelayMs = options.blurExitDelayMs ?? DEFAULT_BLUR_EXIT_DELAY_MS;
  }

  /** Whether a link edit currently holds the session open (`beginLinkEdit` → commit/cancel). */
  get isHoldingForLinkEdit(): boolean {
    return this.#heldRange !== null;
  }

  get activeBlockId(): BlockId | null {
    return this.#activeBlockId;
  }

  /** Test-only accessor for the currently-attached DOM node — lets a test prove reattachment
   *  (identity change) without reaching into private state. */
  get activeElementForTesting(): HTMLElement | null {
    return this.#activeElement;
  }

  /**
   * The current text selection's context, if one exists inside the block currently being edited
   * (#1227 PR 2) — `null` when nothing is active, the selection is collapsed (a caret, not a
   * range), or the selection lies outside the active element. Selection-live-behavior is exactly
   * `toggleInlineFormat`'s own guard shape (this file, above) — same reasoning, same Selection
   * API usage.
   */
  currentSelectionContext(doc: Document = document): { blockId: BlockId; range: Range; text: string } | null {
    if (this.#activeBlockId === null || this.#activeElement === null) return null;
    const selection = doc.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
    const range = selection.getRangeAt(0);
    if (!this.#activeElement.contains(range.commonAncestorContainer)) return null;
    const text = range.toString();
    if (text.length === 0) return null;
    return { blockId: this.#activeBlockId, range, text };
  }

  /**
   * Replaces `range`'s live DOM content with `newText`, then re-serializes and submits an
   * `editText` op through the same commit path typing already uses — no positional run-splicing
   * (see plan Global Constraints): the DOM mutation plus `runsFromElement` re-serialization is
   * the "diff." `previousRuns` is this editor's `enter()`-time baseline, same invariant `#commit()`
   * already preserves — a version-mismatch rejection mid-flow still discards the whole pending
   * edit in one step. Uses `this.#activeElement.ownerDocument` to handle cross-frame editing
   * (BreakpointCanvas), matching the pattern established in `enter()` and the format commands.
   */
  applyTextReplacement(range: Range, newText: string): void {
    if (this.#activeBlockId === null || this.#activeElement === null) return;
    const doc = this.#activeElement.ownerDocument;
    range.deleteContents();
    range.insertNode(doc.createTextNode(newText));
    // Collapse and clear the live selection so a stray leftover Range doesn't confuse the next
    // selectionchange listener (the toolbar's own trigger, added in Task 6) into reopening itself
    // immediately after Accept.
    const selection = doc.getSelection();
    selection?.removeAllRanges();
    const runs = runsFromElement(this.#activeElement);
    void this.#engine.submit({
      kind: "editText",
      blockId: this.#activeBlockId,
      runs,
      previousRuns: this.#baselineRuns,
    });
    this.#baselineRuns = runs;
  }

  enter(blockId: BlockId, root: ParentNode = document): void {
    // `root` exists precisely so a caller can pass another frame's Document (BreakpointCanvas), and
    // an element from another realm is not `instanceof` *this* realm's HTMLElement — an
    // `instanceof` guard here silently no-ops every cross-document edit. Duck-type on the DOM
    // interface instead, the way hit-test.ts already does.
    const el = findBlockElement(blockId, root) as HTMLElement | null;
    if (el === null || el.nodeType !== 1 /* Node.ELEMENT_NODE */) return;

    // Compare by element identity, not just blockId: BreakpointCanvas renders the same blockId into
    // every frame simultaneously, so re-entering "the same block" can still mean switching to a
    // different frame's element. Only a redundant call for the exact element already being edited
    // is a true no-op.
    if (this.#activeElement === el) return;
    if (this.#activeBlockId !== null) this.exit();

    this.#baselineRuns = this.#engine.modelSync.getBlock(blockId)?.richText ?? [];
    this.#activeBlockId = blockId;
    this.#activeElement = el;
    el.contentEditable = "true";
    this.#attach(el);
    el.focus();

    // Design doc §7a's known limitation: any applied op makes the host re-render the whole block
    // subtree (BreakpointCanvas#render), which can replace `el` with a fresh node carrying the same
    // block-id attribute — disconnecting the element above without telling us. Subscribe so a
    // reattach happens instead of silently editing a detached node. Re-resolved against this call's
    // `root`, since the active element can live in a specific breakpoint frame's document.
    this.#unsubscribeEngine?.();
    this.#unsubscribeEngine = this.#engine.onEvent((event) => this.#onEngineEvent(event, root));
  }

  /** Flushes any pending debounced commit and deactivates — called explicitly, or automatically on
   *  blur/Escape (design doc §4: both commit immediately, alongside a format command). */
  exit(): void {
    this.#cancelBlurTimer();
    this.#heldRange = null;
    this.#unsubscribeEngine?.();
    this.#unsubscribeEngine = null;
    this.#committer.flush();
    if (this.#activeElement) {
      this.#activeElement.removeEventListener("input", this.#onInput);
      this.#activeElement.removeEventListener("blur", this.#onBlur);
      this.#activeElement.removeEventListener("keydown", this.#onKeydown);
      this.#activeElement.contentEditable = "false";
    }
    this.#activeBlockId = null;
    this.#activeElement = null;
    this.#baselineRuns = [];
  }

  // The three format commands all derive their Document from the active element rather than letting
  // the format helpers fall back to the global `document`: the active element can live in a
  // breakpoint frame, whose Selection/Range — and whose ownership of any wrapper element created by
  // `wrapRange` — belong to that frame's document, not this module's.

  toggleFormat(kind: FormatKind): void {
    if (!this.#activeElement) return;
    toggleInlineFormat(this.#activeElement, kind, this.#activeElement.ownerDocument);
    this.#committer.notifyChange();
    this.#committer.flush();
  }

  setLink(href: string): void {
    if (!this.#activeElement) return;
    setLinkFormat(this.#activeElement, href, this.#activeElement.ownerDocument);
    this.#committer.notifyChange();
    this.#committer.flush();
  }

  unsetLink(): void {
    if (!this.#activeElement) return;
    unsetLinkFormat(this.#activeElement, this.#activeElement.ownerDocument);
    this.#committer.notifyChange();
    this.#committer.flush();
  }

  /**
   * Format ▸ Add Link… (#2216), step 1: saves the selection and holds the session open so moving
   * focus into the native URL popover doesn't end it. With a caret inside an existing link, the
   * whole link is selected so the edit replaces its address. Returns `null` — and holds nothing —
   * when there's no active session, or no text selected and no link under the caret.
   */
  beginLinkEdit(): LinkEditContext | null {
    const el = this.#activeElement;
    if (!el) return null;
    const doc = el.ownerDocument;
    const selection = doc.getSelection();
    if (!selection || selection.rangeCount === 0) return null;
    const range = selection.getRangeAt(0).cloneRange();
    if (!el.contains(range.commonAncestorContainer)) return null;

    const link = findAncestorTag(range.commonAncestorContainer, "a", el);
    if (range.collapsed) {
      if (!link) return null;
      range.selectNodeContents(link);
      selection.removeAllRanges();
      selection.addRange(range);
    }
    const text = range.toString();
    if (text.length === 0) return null;

    this.#cancelBlurTimer();
    this.#heldRange = range;
    return { href: link?.getAttribute("href") ?? null, text, rect: toTopLevelViewport(range.getBoundingClientRect(), doc) };
  }

  /**
   * Step 2, on Return: restores the held selection, then links it to `input` (normalized by
   * `normalizeHref`) or, for an empty address, removes the link — one commit, one undo step.
   * An `invalid` address keeps the hold so the owner can fix it in the still-open popover.
   */
  commitLinkEdit(input: string): LinkCommitResult {
    const range = this.#heldRange;
    const el = this.#activeElement;
    if (!range || !el) return "stale";
    const href = normalizeHref(input);
    if (href === null) return "invalid";
    this.#heldRange = null;
    // A re-render while the popover was open (some other op applied) can replace the nodes the
    // saved range points into; linking a detached range would silently do nothing.
    // Removing the range's text collapses it onto the element, hence the `collapsed` check.
    if (range.collapsed || !el.contains(range.commonAncestorContainer)) {
      el.focus();
      return "stale";
    }
    this.#restoreSelection(el, range);
    if (href === "") {
      this.unsetLink();
      return "removed";
    }
    this.setLink(href);
    return "applied";
  }

  /** Step 2, on Escape or a popover dismissed without Return: releases the hold and puts the
   *  selection and focus back where they were, changing nothing. */
  cancelLinkEdit(): void {
    const range = this.#heldRange;
    const el = this.#activeElement;
    this.#heldRange = null;
    if (range && el && el.contains(range.commonAncestorContainer)) this.#restoreSelection(el, range);
  }

  /**
   * Unified entry point the native host's Format menu calls (#1225 Task 10) — a thin dispatcher
   * onto `toggleFormat`/`setLink` above, so the Swift bridge (`WYSIWYGCanvasController.applyFormat`)
   * can post one JS method name regardless of which command was requested instead of needing a
   * method-per-command mapping on the native side. `strong`/`em` reuse `toggleFormat`'s existing
   * Range-based wrap/unwrap (already covered above and by the Playwright e2e goldens for real
   * Selection support); `link` reuses `setLink`. `href` defaults to `""` when omitted, matching
   * `MarkdownEditorController.perform(.link)`'s empty-URL convention — the selection gets wrapped
   * in an empty-href link for the user to fill in, rather than being treated as "clear".
   * `⌘K` (inline `code`) is explicitly out of scope for this task.
   */
  applyFormat(command: "strong" | "em" | "link" | "unlink", href?: string): void {
    if (command === "link") {
      this.setLink(href ?? "");
    } else if (command === "unlink") {
      // Format ▸ Remove Link (#2216).
      this.unsetLink();
    } else {
      this.toggleFormat(command);
    }
  }

  dispose(): void {
    this.exit();
  }

  #cancelBlurTimer(): void {
    if (this.#blurTimer !== null) {
      clearTimeout(this.#blurTimer);
      this.#blurTimer = null;
    }
  }

  /** Focus first, then the range: focusing a contenteditable element can move the caret. */
  #restoreSelection(el: HTMLElement, range: Range): void {
    el.focus();
    const selection = el.ownerDocument.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
  }

  /** Wires the three listeners `enter()`'s initial attach and the reattach path below both need —
   *  factored out so the same `addEventListener` triplet isn't duplicated in both places. */
  #attach(element: HTMLElement): void {
    element.addEventListener("input", this.#onInput);
    element.addEventListener("blur", this.#onBlur);
    element.addEventListener("keydown", this.#onKeydown);
  }

  /** Any event carrying a model (`model-updated`, `applied`, or a `rejected` that adopted a fresh
   *  model) is a potential whole-subtree re-render — exactly the events `BreakpointCanvas#render`
   *  reacts to. Re-resolve the live element for the block currently being edited and reattach if
   *  its identity changed underneath us. */
  #onEngineEvent(event: EngineEvent, root: ParentNode): void {
    if (!("model" in event) || !event.model) return;
    if (this.#activeBlockId === null) return;

    const current = findBlockElement(this.#activeBlockId, root) as HTMLElement | null;
    if (current && current !== this.#activeElement) {
      this.#activeElement?.removeEventListener("input", this.#onInput);
      this.#activeElement?.removeEventListener("blur", this.#onBlur);
      this.#activeElement?.removeEventListener("keydown", this.#onKeydown);
      this.#activeElement = current;
      this.#attach(current);
      // The replacement node arrives from a fresh render — plain, non-editable DOM, same as any
      // other block. Without these two lines the pointer moves correctly on the JS side but the
      // owner's in-progress edit still effectively dies from their perspective: the new node isn't
      // editable and doesn't hold focus, so the next keystroke goes nowhere (#1225 final-review fix
      // wave, Finding 4).
      current.contentEditable = "true";
      // While a link edit holds the session, focus belongs to the native URL popover;
      // `commitLinkEdit`/`cancelLinkEdit` refocus once it closes.
      if (!this.#heldRange) current.focus();
      // `#baselineRuns` is deliberately NOT re-resolved from `current`'s content here: the whole
      // point of a fixed enter()-time baseline (see this class's header comment) is that a
      // version-mismatch rejection mid-edit can discard the whole in-progress edit in one step. The
      // re-render that triggered this reattach was some *other* op applying to the model (this
      // block's own content is exactly what's still being locally edited and hasn't been submitted
      // yet) — re-reading `current`'s content now would just read back the same pre-edit text the
      // baseline already holds, so there's nothing to gain and re-resolving would risk masking a
      // real divergence (e.g. a genuinely conflicting concurrent edit) behind a silently-updated
      // baseline instead of surfacing it through the normal rejection path.
    }
  }

  #commit(): void {
    if (!this.#activeBlockId || !this.#activeElement) return;
    const runs = runsFromElement(this.#activeElement);
    // A touch-and-revert (type, then delete back to the exact original text before the debounce or
    // a blur/Escape flush fires) would otherwise still submit a spurious no-op editText, reaching
    // the host/undo pipeline for an edit that never actually happened.
    if (JSON.stringify(runs) === JSON.stringify(this.#baselineRuns)) return;
    void this.#engine.submit({
      kind: "editText",
      blockId: this.#activeBlockId,
      runs,
      previousRuns: this.#baselineRuns,
    });
  }
}

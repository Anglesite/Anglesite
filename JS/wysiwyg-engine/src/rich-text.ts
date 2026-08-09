import type { RichTextRun } from "./types.js";
import type { BlockId } from "./types.js";
import type { WysiwygEngine } from "./engine.js";
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
  if (kind === "link") return { kind, text, href: el.getAttribute("href") ?? "" };
  return { kind, text };
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
  if (existing) unwrapElement(existing);
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

export interface RichTextEditorOptions {
  debounceMs?: number;
}

const DEFAULT_DEBOUNCE_MS = 400;

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
  #onInput = () => this.#committer.notifyChange();
  #onBlur = () => this.exit();
  #onKeydown = (event: KeyboardEvent) => {
    if (event.key === "Escape") this.exit();
  };

  constructor(engine: WysiwygEngine, options: RichTextEditorOptions = {}) {
    this.#engine = engine;
    this.#committer = new DebouncedCommitter(() => this.#commit(), options.debounceMs ?? DEFAULT_DEBOUNCE_MS);
  }

  get activeBlockId(): BlockId | null {
    return this.#activeBlockId;
  }

  enter(blockId: BlockId, root: ParentNode = document): void {
    if (this.#activeBlockId === blockId) return;
    if (this.#activeBlockId !== null) this.exit();

    const el = findBlockElement(blockId, root);
    if (!(el instanceof HTMLElement)) return;

    this.#baselineRuns = this.#engine.modelSync.getBlock(blockId)?.richText ?? [];
    this.#activeBlockId = blockId;
    this.#activeElement = el;
    el.contentEditable = "true";
    el.addEventListener("input", this.#onInput);
    el.addEventListener("blur", this.#onBlur);
    el.addEventListener("keydown", this.#onKeydown);
    el.focus();
  }

  /** Flushes any pending debounced commit and deactivates — called explicitly, or automatically on
   *  blur/Escape (design doc §4: both commit immediately, alongside a format command). */
  exit(): void {
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

  toggleFormat(kind: FormatKind): void {
    if (!this.#activeElement) return;
    toggleInlineFormat(this.#activeElement, kind);
    this.#committer.notifyChange();
  }

  setLink(href: string): void {
    if (!this.#activeElement) return;
    setLinkFormat(this.#activeElement, href);
    this.#committer.notifyChange();
  }

  unsetLink(): void {
    if (!this.#activeElement) return;
    unsetLinkFormat(this.#activeElement);
    this.#committer.notifyChange();
  }

  dispose(): void {
    this.exit();
  }

  #commit(): void {
    if (!this.#activeBlockId || !this.#activeElement) return;
    void this.#engine.submit({
      kind: "editText",
      blockId: this.#activeBlockId,
      runs: runsFromElement(this.#activeElement),
      previousRuns: this.#baselineRuns,
    });
  }
}

import type { RichTextRun } from "./types.js";

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

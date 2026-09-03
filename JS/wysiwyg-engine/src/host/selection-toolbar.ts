import type { RichTextEditor } from "../rich-text.js";
import type { HostTransport, WritingHelpReply } from "../types.js";

/** Extends `HostTransport` with the writing-help round trip (#1227 PR 2, Task 3) —
 *  `NativeHostTransport` implements this alongside `HostTransport`/`QualityGateTransport`, the
 *  same "one object, several seams" shape `QualityGateTransport` already established. */
export interface WritingHelpTransport extends HostTransport {
  requestWritingHelp(text: string, instruction: string): Promise<WritingHelpReply>;
}

export type ToolbarAction = "rewrite" | "tighten" | "tone";
export type TonePreset = "friendlier" | "more formal" | "more confident";

/** Canned instruction text per toolbar action (plan Global Constraints: one instruction-taking
 *  API, no action enum on the host side — the action→instruction mapping lives entirely here). */
export function instructionForAction(action: ToolbarAction, tone?: TonePreset): string {
  switch (action) {
    case "rewrite":
      return "Rewrite this to be clearer and more engaging, keeping roughly the same length and meaning.";
    case "tighten":
      return "Make this noticeably shorter while keeping the essential meaning.";
    case "tone":
      return `Rewrite this in a ${tone ?? "friendlier"} tone, keeping the same meaning and roughly the same length.`;
  }
}

const TOOLBAR_Z_INDEX = "2147483000";

/**
 * Floating selection toolbar (#1227 PR 2, design doc §4): appears on a non-collapsed text
 * selection inside the block currently being edited, offers Rewrite/Tighten/Tone(preset) buttons,
 * and shows a before/after preview with Accept/Discard after a request round-trips. Positioning
 * and inline-style conventions follow `QualityGateChips` (this package's existing chip precedent)
 * even though the trigger direction is the opposite: this is JS-locally `selectionchange`-driven,
 * not a host push.
 */
export class SelectionToolbar {
  #richTextEditor: RichTextEditor;
  #transport: WritingHelpTransport;
  #doc: Document;
  #el: HTMLElement | null = null;
  #pendingRange: Range | null = null;
  #onSelectionChange = () => this.#handleSelectionChange();

  constructor(richTextEditor: RichTextEditor, transport: WritingHelpTransport, doc: Document = document) {
    this.#richTextEditor = richTextEditor;
    this.#transport = transport;
    this.#doc = doc;
    doc.addEventListener("selectionchange", this.#onSelectionChange);
  }

  dispose(): void {
    this.#doc.removeEventListener("selectionchange", this.#onSelectionChange);
    this.#el?.remove();
    this.#el = null;
  }

  #handleSelectionChange(): void {
    const context = this.#richTextEditor.currentSelectionContext(this.#doc);
    if (!context) {
      this.#hide();
      return;
    }
    this.#showButtons(context.range);
  }

  #hide(): void {
    this.#el?.remove();
    this.#el = null;
    this.#pendingRange = null;
  }

  #showButtons(range: Range): void {
    // Invalidates any earlier in-flight request unconditionally, not just the ones `#hide()`
    // already covers. Without this, reselecting to a *different* non-collapsed range B while a
    // request for range A is still in flight leaves `#pendingRange` pointing at A — so when A's
    // reply lands, `#request`'s `this.#pendingRange !== range` guard compares `rangeA !== rangeA`
    // and wrongly treats it as fresh, overwriting the just-rendered button bar for B with a preview
    // of A's rewritten text (Accept still bound to A's range, not what the owner is looking at).
    // Once the visible selection has moved on, any earlier request is moot regardless of whether
    // the new selection happens to overlap the old range.
    this.#pendingRange = null;
    this.#el?.remove();
    const el = this.#doc.createElement("div");
    el.setAttribute("data-selection-toolbar", "");
    el.style.cssText = `position:fixed;z-index:${TOOLBAR_Z_INDEX};display:flex;gap:4px;padding:4px;background:#1f2937;border-radius:6px;box-shadow:0 2px 8px rgba(0,0,0,0.3);`;
    const rect = range.getBoundingClientRect();
    el.style.left = `${Math.max(0, rect.left)}px`;
    el.style.top = `${Math.max(0, rect.top - 40)}px`;

    const addButton = (label: string, action: ToolbarAction, tone?: TonePreset) => {
      const button = this.#doc.createElement("button");
      button.textContent = label;
      button.style.cssText = "font-size:12px;padding:2px 8px;border-radius:4px;border:none;cursor:pointer;";
      this.#preventFocusSteal(button);
      button.addEventListener("click", () => void this.#request(range, action, tone));
      el.appendChild(button);
    };
    addButton("Rewrite", "rewrite");
    addButton("Tighten", "tighten");
    addButton("Friendlier", "tone", "friendlier");
    addButton("More Formal", "tone", "more formal");
    addButton("More Confident", "tone", "more confident");

    this.#doc.body.appendChild(el);
    this.#el = el;
  }

  /**
   * Toolbar buttons live outside the block being edited, so a click on one steals DOM focus from
   * `RichTextEditor`'s `contenteditable` element — which fires its `blur` listener and calls
   * `exit()`, clearing `#activeElement`/`#activeBlockId` before `#request`/Accept ever run
   * (`applyTextReplacement` then silently no-ops on the cleared state; confirmed live in the
   * Playwright golden, not reachable from the jsdom-only unit tests). `mousedown` fires — and can
   * be prevented — before the browser moves focus on `click`, so `preventDefault()` here keeps
   * focus (and the live selection/edit) on the block — the standard technique for a UI control
   * that must not steal focus from an active edit (not an existing pattern elsewhere in this
   * package — `mount.ts`'s drag-handle `onPointerDown`/`preventDefault()` solves a different
   * problem, suppressing compatibility mouse events for drag start).
   */
  #preventFocusSteal(button: HTMLButtonElement): void {
    button.addEventListener("mousedown", (event) => event.preventDefault());
  }

  async #request(range: Range, action: ToolbarAction, tone?: TonePreset): Promise<void> {
    this.#pendingRange = range;
    const text = range.toString();
    this.#renderLoading();
    let reply: WritingHelpReply;
    try {
      reply = await this.#transport.requestWritingHelp(text, instructionForAction(action, tone));
    } catch {
      // A rejected promise (transport-level failure, not a `{status:"unavailable"}` reply) must
      // not leave the toolbar stuck on "Rewriting…" forever with an unhandled rejection — surface
      // the same user-visible error state the `.unavailable` reply path already renders below.
      if (this.#pendingRange === range) this.#renderError("Couldn't generate a rewrite — try again.");
      return;
    }
    // The selection (and thus the active edit) may have moved on during the round trip — discard
    // a stale reply rather than force-applying it to whatever is selected now.
    if (this.#pendingRange !== range) return;
    if (reply.status === "unavailable") {
      this.#renderError(reply.message);
      return;
    }
    this.#renderPreview(reply.text, range);
  }

  #renderLoading(): void {
    if (!this.#el) return;
    this.#el.innerHTML = "";
    const label = this.#doc.createElement("span");
    label.textContent = "Rewriting…";
    label.style.cssText = "font-size:12px;color:#e5e7eb;padding:2px 4px;";
    this.#el.appendChild(label);
  }

  #renderError(message: string): void {
    if (!this.#el) return;
    this.#el.innerHTML = "";
    const label = this.#doc.createElement("span");
    label.textContent = message;
    label.style.cssText = "font-size:12px;color:#fca5a5;padding:2px 4px;max-width:240px;";
    this.#el.appendChild(label);
  }

  #renderPreview(rewritten: string, range: Range): void {
    if (!this.#el) return;
    this.#el.innerHTML = "";
    const preview = this.#doc.createElement("div");
    preview.style.cssText = "font-size:12px;color:#e5e7eb;max-width:280px;";
    preview.textContent = rewritten;
    this.#el.appendChild(preview);

    const accept = this.#doc.createElement("button");
    accept.textContent = "Accept";
    accept.style.cssText = "font-size:12px;padding:2px 8px;border-radius:4px;border:none;cursor:pointer;background:#16a34a;color:white;";
    this.#preventFocusSteal(accept);
    accept.addEventListener("click", () => {
      this.#richTextEditor.applyTextReplacement(range, rewritten);
      this.#hide();
    });

    const discard = this.#doc.createElement("button");
    discard.textContent = "Discard";
    discard.style.cssText = "font-size:12px;padding:2px 8px;border-radius:4px;border:none;cursor:pointer;";
    this.#preventFocusSteal(discard);
    discard.addEventListener("click", () => this.#hide());

    this.#el.appendChild(accept);
    this.#el.appendChild(discard);
  }
}

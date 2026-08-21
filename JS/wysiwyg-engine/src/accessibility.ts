import type { BlockId } from "./types.js";
import type { WysiwygEngine, EngineEvent } from "./engine.js";
import { findBlockElement } from "./selection.js";

/**
 * Keeps VoiceOver-relevant attributes on each block's rendered element in sync with the model and
 * selection (design doc §8.6: "VoiceOver navigates blocks by their owner-facing manifest names —
 * the block model doubles as the accessibility model"). Never renders DOM itself — only annotates
 * elements the host's already-rendered page produced with the block-id attribute, the same
 * contract `findBlockElement` relies on elsewhere (e.g. `RichTextEditor.enter()`).
 */
export class AccessibilityAnnotator {
  #engine: WysiwygEngine;
  #displayNames: Record<string, string>;
  #root: ParentNode;
  #unsubscribeEngine: () => void;
  #unsubscribeSelection: () => void;

  constructor(engine: WysiwygEngine, displayNames: Record<string, string>, root: ParentNode = document) {
    this.#engine = engine;
    this.#displayNames = displayNames;
    this.#root = root;
    this.#annotateAll();
    this.#unsubscribeEngine = engine.onEvent((event) => this.#onEngineEvent(event));
    this.#unsubscribeSelection = engine.selection.onChange((id) => this.#onSelectionChange(id));
  }

  /** The name VoiceOver announces for `componentName` — the interim palette's display name if
   *  known, otherwise the raw component name (documented interim limitation, same as
   *  `WYSIWYGCanvasController.stubBlockPalette`'s own doc comment: a real CEM-aligned manifest
   *  replaces this once #1222's model service supplies one). */
  displayName(componentName: string): string {
    return this.#displayNames[componentName] ?? componentName;
  }

  dispose(): void {
    this.#unsubscribeEngine();
    this.#unsubscribeSelection();
  }

  #onEngineEvent(event: EngineEvent): void {
    const rerenders =
      event.type === "model-updated" || event.type === "applied" || (event.type === "rejected" && event.model !== undefined);
    if (rerenders) this.#annotateAll();
  }

  #onSelectionChange(selected: BlockId | null): void {
    const model = this.#engine.modelSync.current;
    for (const id of model.rootIds) {
      const el = findBlockElement(id, this.#root) as HTMLElement | null;
      if (!el) continue;
      const isSelected = id === selected;
      el.setAttribute("aria-selected", String(isSelected));
      el.tabIndex = isSelected ? 0 : -1;
    }
    if (selected) (findBlockElement(selected, this.#root) as HTMLElement | null)?.focus();
  }

  #annotateAll(): void {
    const model = this.#engine.modelSync.current;
    const selected = this.#engine.selection.current;
    for (const id of model.rootIds) {
      const node = model.blocks[id];
      const el = findBlockElement(id, this.#root) as HTMLElement | null;
      if (!node || !el) continue;
      el.setAttribute("role", "group");
      el.setAttribute("aria-label", this.displayName(node.componentName));
      const isSelected = id === selected;
      el.setAttribute("aria-selected", String(isSelected));
      el.tabIndex = isSelected ? 0 : -1;
    }
  }
}

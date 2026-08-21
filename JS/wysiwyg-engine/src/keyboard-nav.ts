import type { BlockId } from "./types.js";
import type { WysiwygEngine } from "./engine.js";
import type { RichTextEditor } from "./rich-text.js";

/**
 * Keyboard-only editing grammar (design doc §8.6): arrows move block selection, Return enters text
 * editing on the selected block, Escape exits the deepest active context first — text-editing (via
 * `RichTextEditor`'s own Escape handling, which stops propagation once it fires — see rich-text.ts),
 * then block-selected, then none.
 *
 * Tab-walks-props is deliberately not handled here: it needs the native inspector PR2 ships
 * (#1588/#1613), which doesn't exist on `main` yet — see this plan's header and #1589's PR body.
 *
 * Listens on `document` (default `target`) rather than a specific block element, mirroring
 * `mount.ts`'s own `contextmenu` listener: whichever element already has focus (a block, or
 * nothing) is where these keys should apply, and re-deriving that per-block would just reduce to
 * `document.activeElement` anyway. `target` is overridable for tests and for a future breakpoint
 * frame's own `Document` (matching `hitTest`/`findBlockElement`'s existing `root` parameter
 * convention elsewhere in this package).
 */
export class KeyboardNavigation {
  #engine: WysiwygEngine;
  #richText: RichTextEditor;
  #target: GlobalEventHandlers;
  #onKeydown = (event: Event) => this.#handleKeydown(event as KeyboardEvent);

  constructor(engine: WysiwygEngine, richText: RichTextEditor, target: GlobalEventHandlers = document) {
    this.#engine = engine;
    this.#richText = richText;
    this.#target = target;
    target.addEventListener("keydown", this.#onKeydown);
  }

  dispose(): void {
    this.#target.removeEventListener("keydown", this.#onKeydown);
  }

  #handleKeydown(event: KeyboardEvent): void {
    // A live text-editing session owns arrows/Return/Escape for caret movement and text input.
    if (this.#richText.activeBlockId !== null) return;

    switch (event.key) {
      case "ArrowDown":
      case "ArrowRight":
        this.#moveSelection(1);
        event.preventDefault();
        break;
      case "ArrowUp":
      case "ArrowLeft":
        this.#moveSelection(-1);
        event.preventDefault();
        break;
      case "Enter":
      case "Return":
        if (this.#enterTextEditingIfPossible()) event.preventDefault();
        break;
      case "Escape":
        if (this.#engine.selection.current !== null) {
          this.#engine.selection.clear();
          event.preventDefault();
        }
        break;
    }
  }

  #moveSelection(delta: 1 | -1): void {
    const { rootIds } = this.#engine.modelSync.current;
    if (rootIds.length === 0) return;
    const current = this.#engine.selection.current;
    const currentIndex = current === null ? -1 : rootIds.indexOf(current);
    const nextIndex =
      currentIndex === -1
        ? (delta === 1 ? 0 : rootIds.length - 1)
        : Math.min(Math.max(currentIndex + delta, 0), rootIds.length - 1);
    this.#engine.selection.select(rootIds[nextIndex] as BlockId);
  }

  #enterTextEditingIfPossible(): boolean {
    const selected = this.#engine.selection.current;
    if (selected === null) return false;
    const node = this.#engine.modelSync.current.blocks[selected];
    if (!node || node.kind !== "text") return false;
    this.#richText.enter(selected);
    return true;
  }
}

import type { BlockId } from "./types.js";
import type { WysiwygEngine } from "./engine.js";
import type { RichTextEditor } from "./rich-text.js";
import { findBlockElement } from "./selection.js";

/**
 * Keyboard-only editing grammar (design doc §8.6): arrows move block selection, Return enters text
 * editing on the selected block, Escape exits the deepest active context first — text-editing (via
 * `RichTextEditor`'s own Escape handling, which stops propagation once it fires — see rich-text.ts),
 * then block-selected, then none. Tab walks focus into the native inspector's first prop field with
 * a block selected (Shift-Tab into the last field); the actual focus move is native-side (#1616),
 * so this class only requests it via `onFocusInspectorRequested` — `mount.ts` posts that request
 * across the bridge, same as this file's other host-bound signals. The request carries the
 * selected block's id rather than relying on the native side's own `selectedBlockId` mirror
 * already being in sync: that mirror is updated by a *separate* `selection-changed` bridge
 * message, posted and dispatched independently (final review, #1616) — without the id riding
 * along, a fast select-then-Tab could have the inspector focus request land against native's
 * still-stale prior selection.
 *
 * Listens on `document` (default `target`) rather than a specific block element, mirroring
 * `mount.ts`'s own `contextmenu` listener: whichever element already has focus (a block, or
 * nothing) is where these keys should apply, and re-deriving that per-block would just reduce to
 * `document.activeElement` anyway. `target` is overridable for tests and for a future breakpoint
 * frame's own `Document` (matching `findBlockElement`'s existing `root` parameter convention
 * elsewhere in this package — `hitTest` itself names its own equivalent parameter `doc`).
 */
export class KeyboardNavigation {
  #engine: WysiwygEngine;
  #richText: RichTextEditor;
  #target: GlobalEventHandlers;
  #onFocusInspectorRequested: (direction: "forward" | "backward", blockId: BlockId) => void;
  #onKeydown = (event: Event) => this.#handleKeydown(event as KeyboardEvent);

  constructor(
    engine: WysiwygEngine,
    richText: RichTextEditor,
    target: GlobalEventHandlers = document,
    onFocusInspectorRequested: (direction: "forward" | "backward", blockId: BlockId) => void = () => {},
  ) {
    this.#engine = engine;
    this.#richText = richText;
    this.#target = target;
    this.#onFocusInspectorRequested = onFocusInspectorRequested;
    target.addEventListener("keydown", this.#onKeydown);
  }

  dispose(): void {
    this.#target.removeEventListener("keydown", this.#onKeydown);
  }

  #handleKeydown(event: KeyboardEvent): void {
    // A live text-editing session owns arrows/Return/Escape for caret movement and text input.
    if (this.#richText.activeBlockId !== null) return;

    // Never hijack a modified keystroke: VoiceOver's own navigation is Control+Option+arrow, and
    // Cmd/Option-arrow are standard macOS caret/list motions this handler must not repurpose.
    if (event.metaKey || event.ctrlKey || event.altKey) return;

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
      case "Tab": {
        const selected = this.#engine.selection.current;
        if (selected !== null) {
          this.#onFocusInspectorRequested(event.shiftKey ? "backward" : "forward", selected);
          event.preventDefault();
        }
        break;
      }
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
    if (!findBlockElement(selected)) return false;
    this.#richText.enter(selected);
    return true;
  }
}

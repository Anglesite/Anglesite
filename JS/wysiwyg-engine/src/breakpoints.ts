import type { BlockId, BlockModel } from "./types.js";
import type { WysiwygEngine, EngineEvent } from "./engine.js";
import { computeHandleRect } from "./selection.js";
import type { HandleRect } from "./selection.js";

export interface BreakpointFrame {
  name: string;
  doc: Document;
}

export type RenderFn = (model: BlockModel, doc: Document) => void;

/**
 * Drives N breakpoint frame documents from one shared `WysiwygEngine` (design doc §6, spec §5:
 * breakpoints are views, not modes). Because `hitTest()`/`computeHandleRect()` already accept an
 * explicit document/root instead of assuming the global `document`, one engine — one model, one
 * selection, one op queue — can resolve gestures against any registered frame: selecting a block in
 * one frame is reflected in every frame automatically, with no cross-frame sync layer.
 */
export class BreakpointCanvas {
  #engine: WysiwygEngine;
  #render: RenderFn;
  #frames: BreakpointFrame[] = [];
  #unsubscribe: () => void;

  constructor(engine: WysiwygEngine, render: RenderFn) {
    this.#engine = engine;
    this.#render = render;
    this.#unsubscribe = engine.onEvent((event) => this.#onEngineEvent(event));
  }

  registerFrame(frame: BreakpointFrame): void {
    this.#frames.push(frame);
    this.#render(this.#engine.modelSync.current, frame.doc);
  }

  unregisterFrame(name: string): void {
    this.#frames = this.#frames.filter((f) => f.name !== name);
  }

  get frames(): readonly BreakpointFrame[] {
    return this.#frames;
  }

  hitTestFrame(name: string, point: { x: number; y: number }): BlockId | null {
    const frame = this.#frames.find((f) => f.name === name);
    if (!frame) return null;
    return this.#engine.hitTest(point, frame.doc);
  }

  /** Selection-handle geometry for every frame currently rendering the selected block — callers
   *  redraw their own outline chrome from this, mirroring how the engine itself owns no rendering
   *  (spec §3.1). Call after any engine event that could move or reselect a block. */
  handleRectsForSelection(): { name: string; rect: HandleRect }[] {
    const selected = this.#engine.selection.current;
    if (!selected) return [];
    const rects: { name: string; rect: HandleRect }[] = [];
    for (const frame of this.#frames) {
      const rect = computeHandleRect(selected, frame.doc);
      if (rect) rects.push({ name: frame.name, rect });
    }
    return rects;
  }

  dispose(): void {
    this.#unsubscribe();
    this.#frames = [];
  }

  #onEngineEvent(event: EngineEvent): void {
    const shouldRerender =
      event.type === "model-updated" || event.type === "applied" || (event.type === "rejected" && event.model !== undefined);
    if (!shouldRerender) return;
    const model = this.#engine.modelSync.current;
    for (const frame of this.#frames) this.#render(model, frame.doc);
  }
}

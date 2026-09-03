import { WysiwygEngine } from "../src/engine.js";
import { FixtureHost } from "../src/testing/fixture-host.js";
import { computeHandleRect } from "../src/selection.js";
import { ROOT_PARENT_ID } from "../src/types.js";
import { RichTextEditor } from "../src/rich-text.js";
import { DragReorderController, wireExternalDrop, submitDrop } from "../src/drag-drop.js";
import { QualityGateChips } from "../src/quality-gates.js";
import { SelectionToolbar } from "../src/host/selection-toolbar.js";
import type { WritingHelpTransport } from "../src/host/selection-toolbar.js";
import type { HandleRect } from "../src/selection.js";
import type { BlockModel, OpResult, RichTextRun, BlockNode, OpEnvelope, WritingHelpReply } from "../src/types.js";
import type { DropTarget } from "../src/drag-drop.js";
import type { FormatKind } from "../src/rich-text.js";
import type { Finding } from "../src/quality-gates.js";

const initialModel: BlockModel = {
  path: "src/pages/index.astro",
  version: "fixture-initial",
  rootIds: ["b1", "b2", "t1"],
  blocks: {
    b1: { id: "b1", kind: "astro", componentName: "Hero", props: { title: "Welcome" }, slots: {}, sourceSpan: [0, 10] },
    b2: { id: "b2", kind: "astro", componentName: "Testimonial", props: { quote: "Great!" }, slots: {}, sourceSpan: [11, 20] },
    t1: {
      id: "t1",
      kind: "text",
      componentName: "paragraph",
      props: {},
      slots: {},
      sourceSpan: [21, 30],
      richText: [
        { kind: "text", text: "Edit " },
        { kind: "strong", text: "me" },
      ],
    },
  },
};

const host = new FixtureHost(initialModel);
const engine = new WysiwygEngine(initialModel, host);
const richText = new RichTextEditor(engine, { debounceMs: 300 });

function canvas(): HTMLElement {
  const el = document.getElementById("canvas");
  if (!el) throw new Error("fixture.html is missing #canvas");
  return el;
}

/** `"` matters as much as `<`/`&` here: renderRuns' `link` case interpolates escaped text into an
 *  `href="…"` attribute, and this slice's own setLinkFormat can put arbitrary user text into a real
 *  `link` run through a live edit — so the attribute context is reachable, not hypothetical. */
function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** Host-owned rendering of RichTextRun[] into markup — the inverse of runsFromElement, and, like
 *  the rest of this fixture's render(), a stand-in for what a real host's DOM projection does. */
function renderRuns(runs: RichTextRun[]): string {
  return runs
    .map((run) => {
      const text = escapeHtml(run.text);
      switch (run.kind) {
        case "strong":
          return `<strong>${text}</strong>`;
        case "em":
          return `<em>${text}</em>`;
        case "link":
          return `<a href="${escapeHtml(run.href ?? "")}">${text}</a>`;
        case "code":
          return `<code>${text}</code>`;
        default:
          return text;
      }
    })
    .join("");
}

function render(model: BlockModel): void {
  const root = canvas();
  root.innerHTML = "";
  for (const id of model.rootIds) {
    const block = model.blocks[id];
    if (!block) continue;
    const el = document.createElement("div");
    el.setAttribute("data-anglesite-block-id", id);
    el.setAttribute("data-component", block.componentName);
    el.setAttribute("data-anglesite-selected", "false");
    if (block.kind === "text") {
      el.innerHTML = renderRuns(block.richText ?? []);
    } else {
      el.textContent = `${block.componentName} (${id})`;
    }
    el.style.cssText = "padding:8px;margin:4px;border:1px solid #ccc;";
    el.addEventListener("click", () => engine.selection.select(id));
    el.addEventListener("pointerdown", () => dragReorder.startDrag(id));
    root.appendChild(el);
  }
}

const dragReorder = new DragReorderController(
  engine,
  (target) => {
    window.__dropIndicator = target;
  },
  canvas(),
);

const disposeExternalDrop = wireExternalDrop(
  canvas(),
  (target) => {
    window.__dropIndicator = target;
  },
  (target, dataTransfer) => {
    const json = dataTransfer.getData("application/x-anglesite-block");
    if (!json) return;
    const block = JSON.parse(json) as Omit<BlockNode, "id">;
    void submitDrop(engine, target, block);
  },
);

class FixtureQualityGateTransport {
  #listeners = new Set<(findings: Finding[]) => void>();
  onFindings(listener: (findings: Finding[]) => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }
  push(findings: Finding[]): void {
    for (const listener of this.#listeners) listener(findings);
  }
}

const qualityGateTransport = new FixtureQualityGateTransport();
const qualityGateChips = new QualityGateChips(engine, qualityGateTransport, canvas());

/** Delegates the ops half of `WritingHelpTransport` to `host` (same instance the engine itself
 *  uses) and leaves `requestWritingHelp` resolvable on demand from Playwright via
 *  `window.__resolveWritingHelp`, so a spec can assert on the toolbar's loading state before the
 *  reply lands rather than only ever observing the settled result. */
class FixtureWritingHelpTransport implements WritingHelpTransport {
  #host: FixtureHost;
  #pending: Array<(reply: WritingHelpReply) => void> = [];

  constructor(host: FixtureHost) {
    this.#host = host;
  }

  sendOp(envelope: OpEnvelope): Promise<OpResult> {
    return this.#host.sendOp(envelope);
  }

  onModelUpdate(listener: (model: BlockModel) => void): () => void {
    return this.#host.onModelUpdate(listener);
  }

  requestWritingHelp(): Promise<WritingHelpReply> {
    return new Promise((resolve) => {
      this.#pending.push(resolve);
    });
  }

  /** Resolves the oldest still-pending `requestWritingHelp()` call. */
  resolveNext(reply: WritingHelpReply): void {
    const resolve = this.#pending.shift();
    if (!resolve) throw new Error("no pending requestWritingHelp() call to resolve");
    resolve(reply);
  }
}

const writingHelpTransport = new FixtureWritingHelpTransport(host);
const selectionToolbar = new SelectionToolbar(richText, writingHelpTransport, document);

engine.onEvent((event) => {
  // A `rejected` event that carries a model carries the host's *fresh* one — the engine has already
  // adopted it, so the host has to re-render from it too or the DOM silently drifts from the model.
  if (event.type === "model-updated" || event.type === "applied" || (event.type === "rejected" && event.model)) {
    render(engine.modelSync.current);
  }
  if (event.type === "selection-changed") {
    for (const el of Array.from(canvas().children)) {
      const selected = el.getAttribute("data-anglesite-block-id") === event.blockId;
      el.setAttribute("data-anglesite-selected", String(selected));
    }
  }
  // Cheap, poll-able signal Playwright can wait on without a custom event bridge.
  document.title = `event:${event.type}`;
});

render(initialModel);

declare global {
  interface Window {
    __engine: WysiwygEngine;
    __host: FixtureHost;
    __richText: RichTextEditor;
    __dragReorder: DragReorderController;
    __dropIndicator: DropTarget | null;
    __moveBlock: (blockId: string, toIndex: number) => Promise<OpResult>;
    __computeHandleRect: (blockId: string) => HandleRect | null;
    __submitDrop: (target: DropTarget, block: Omit<BlockNode, "id">) => Promise<OpResult>;
    __toggleFormat: (kind: FormatKind) => void;
    __disposeExternalDrop: () => void;
    __qualityGateChips: QualityGateChips;
    __pushQualityFindings: (findings: Finding[]) => void;
    __selectionToolbar: SelectionToolbar;
    __resolveWritingHelp: (reply: WritingHelpReply) => void;
  }
}

window.__engine = engine;
window.__host = host;
window.__richText = richText;
window.__dragReorder = dragReorder;
window.__dropIndicator = null;
// Bridged for e2e/geometry.spec.ts: jsdom's getBoundingClientRect() is all zeros, so the unit tests
// can only prove computeHandleRect's wiring — real on-screen geometry needs a browser.
window.__computeHandleRect = (blockId) => computeHandleRect(blockId);
window.__submitDrop = (target, block) => submitDrop(engine, target, block);
window.__toggleFormat = (kind) => richText.toggleFormat(kind);
window.__disposeExternalDrop = disposeExternalDrop;
window.__qualityGateChips = qualityGateChips;
window.__pushQualityFindings = (findings) => qualityGateTransport.push(findings);
window.__selectionToolbar = selectionToolbar;
window.__resolveWritingHelp = (reply) => writingHelpTransport.resolveNext(reply);
window.__moveBlock = (blockId, toIndex) => {
  const model = engine.modelSync.current;
  const fromIndex = model.rootIds.indexOf(blockId);
  return engine.submit({
    kind: "moveBlock",
    blockId,
    fromParentId: ROOT_PARENT_ID,
    fromSlot: "default",
    fromIndex,
    toParentId: ROOT_PARENT_ID,
    toSlot: "default",
    toIndex,
  });
};

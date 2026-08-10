import { WysiwygEngine } from "../src/engine.js";
import { FixtureHost } from "../src/testing/fixture-host.js";
import { BreakpointCanvas } from "../src/breakpoints.js";
import { RichTextEditor } from "../src/rich-text.js";
import type { BlockId, BlockModel, RichTextRun } from "../src/types.js";
import type { HandleRect } from "../src/selection.js";
import type { FormatKind } from "../src/rich-text.js";

const initialModel: BlockModel = {
  path: "src/pages/index.astro",
  version: "fixture-initial",
  rootIds: ["b1", "b2", "t1"],
  blocks: {
    b1: { id: "b1", kind: "astro", componentName: "Hero", props: { title: "Welcome" }, slots: {}, sourceSpan: [0, 10] },
    b2: { id: "b2", kind: "astro", componentName: "Testimonial", props: { quote: "Great!" }, slots: {}, sourceSpan: [11, 20] },
    // A text block so this fixture can exercise the one thing only a real iframe can prove: a
    // RichTextEditor living in the parent document editing an element from a *frame's* document.
    t1: {
      id: "t1",
      kind: "text",
      componentName: "paragraph",
      props: {},
      slots: {},
      sourceSpan: [21, 30],
      richText: [{ kind: "text", text: "Edit me" }],
    },
  },
};

const host = new FixtureHost(initialModel);
const engine = new WysiwygEngine(initialModel, host);
const richText = new RichTextEditor(engine, { debounceMs: 300 });

function plainText(runs: RichTextRun[]): string {
  return runs.map((run) => run.text).join("");
}

function render(model: BlockModel, doc: Document): void {
  const root = doc.getElementById("canvas");
  if (!root) return;
  root.innerHTML = "";
  for (const id of model.rootIds) {
    const block = model.blocks[id];
    if (!block) continue;
    const el = doc.createElement("div");
    el.setAttribute("data-anglesite-block-id", id);
    // Text blocks render their runs' plain text (no inline markup) — enough for a cross-frame
    // selection + format golden, without duplicating fixture-page.ts's runs-to-markup projection.
    el.textContent = block.kind === "text" ? plainText(block.richText ?? []) : block.componentName;
    el.style.cssText = "padding:8px;margin:4px;border:1px solid #ccc;";
    el.addEventListener("click", () => engine.selection.select(id));
    root.appendChild(el);
  }
}

const canvas = new BreakpointCanvas(engine, render);
const frameNames = ["phone", "tablet", "desktop"] as const;

function registerFrames(): void {
  for (const name of frameNames) {
    const iframe = document.getElementById(name) as HTMLIFrameElement | null;
    const frameDoc = iframe?.contentDocument;
    if (!frameDoc) {
      // This throw can fire from inside an async `load` listener, where it becomes an unhandled
      // error rather than a rejected promise — log first so a real failure here shows up as more
      // than an opaque 30s `breakpoints:ready` timeout in the test output.
      const message = `missing iframe document for ${name}`;
      console.error(message);
      throw new Error(message);
    }
    canvas.registerFrame({ name, doc: frameDoc });
  }
  // Cheap, poll-able readiness signal — engine.onEvent() below overwrites it on any later event.
  document.title = "breakpoints:ready";
}

const iframes = frameNames
  .map((name) => document.getElementById(name) as HTMLIFrameElement | null)
  .filter((el): el is HTMLIFrameElement => el !== null);

let loadedCount = 0;
function onFrameLoaded(): void {
  loadedCount += 1;
  if (loadedCount === iframes.length) registerFrames();
}
for (const iframe of iframes) {
  // An iframe's `load` event is a normal queued task, not deferred until the parent document
  // finishes parsing — while this script (loaded from a parser-blocking <script> tag after the
  // three <iframe> elements) was being fetched/compiled, any of those tiny frame.html documents
  // may already have finished loading. A `load`-listener-only approach misses those and never
  // reaches `iframes.length`, so check for already-complete frames first.
  const doc = iframe.contentDocument;
  if (doc && doc.readyState === "complete" && doc.URL !== "about:blank") {
    onFrameLoaded();
    continue;
  }
  iframe.addEventListener("load", onFrameLoaded, { once: true });
}

engine.onEvent((event) => {
  document.title = `event:${event.type}`;
});

declare global {
  interface Window {
    __engine: WysiwygEngine;
    __host: FixtureHost;
    __canvas: BreakpointCanvas;
    __richText: RichTextEditor;
    __handleRects: () => { name: string; rect: HandleRect }[];
    __enterRichTextInFrame: (frameName: string, blockId: BlockId) => BlockId | null;
    __toggleFormat: (kind: FormatKind) => void;
  }
}

window.__engine = engine;
window.__host = host;
window.__canvas = canvas;
window.__richText = richText;
window.__handleRects = () => canvas.handleRectsForSelection();
// The editor is constructed in THIS document but handed a block element from a frame's document —
// the cross-realm case `enter()`'s guard has to survive.
window.__enterRichTextInFrame = (frameName, blockId) => {
  const frame = canvas.frames.find((f) => f.name === frameName);
  if (!frame) throw new Error(`unregistered frame ${frameName}`);
  richText.enter(blockId, frame.doc);
  return richText.activeBlockId;
};
window.__toggleFormat = (kind) => richText.toggleFormat(kind);

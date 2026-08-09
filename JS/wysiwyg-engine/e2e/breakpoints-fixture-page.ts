import { WysiwygEngine } from "../src/engine.js";
import { FixtureHost } from "../src/testing/fixture-host.js";
import { BreakpointCanvas } from "../src/breakpoints.js";
import type { BlockModel } from "../src/types.js";
import type { HandleRect } from "../src/selection.js";

const initialModel: BlockModel = {
  path: "src/pages/index.astro",
  version: "fixture-initial",
  rootIds: ["b1", "b2"],
  blocks: {
    b1: { id: "b1", kind: "astro", componentName: "Hero", props: { title: "Welcome" }, slots: {}, sourceSpan: [0, 10] },
    b2: { id: "b2", kind: "astro", componentName: "Testimonial", props: { quote: "Great!" }, slots: {}, sourceSpan: [11, 20] },
  },
};

const host = new FixtureHost(initialModel);
const engine = new WysiwygEngine(initialModel, host);

function render(model: BlockModel, doc: Document): void {
  const root = doc.getElementById("canvas");
  if (!root) return;
  root.innerHTML = "";
  for (const id of model.rootIds) {
    const block = model.blocks[id];
    if (!block) continue;
    const el = doc.createElement("div");
    el.setAttribute("data-anglesite-block-id", id);
    el.textContent = block.componentName;
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
    __handleRects: () => { name: string; rect: HandleRect }[];
  }
}

window.__engine = engine;
window.__host = host;
window.__canvas = canvas;
window.__handleRects = () => canvas.handleRectsForSelection();

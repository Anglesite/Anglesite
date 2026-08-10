import { WysiwygEngine } from "../engine.js";
import { RichTextEditor } from "../rich-text.js";
import { NativeHostTransport } from "./native-host-transport.js";
import type { BlockModel } from "../types.js";

declare global {
  interface Window {
    __anglesiteWysiwygEngine?: WysiwygEngine;
    __anglesiteWysiwygRichTextEditor?: RichTextEditor;
    __anglesiteWysiwygMount?: { mount: (initialModel: BlockModel) => WysiwygEngine; unmount: () => void };
  }
}

// Disposes whatever is currently mounted (if anything) and clears the globals — the shared body
// of `unmount()` below, factored out so `mount()` can call it too (#1225 final-review round 2,
// Finding B) rather than only being reachable from the native `unmountEngine()` call. Safe to call
// when nothing is mounted: both globals are `undefined` and the optional-chained calls no-op.
function disposeMounted(): void {
  window.__anglesiteWysiwygRichTextEditor?.dispose();
  window.__anglesiteWysiwygEngine?.dispose();
  window.__anglesiteWysiwygRichTextEditor = undefined;
  window.__anglesiteWysiwygEngine = undefined;
}

// Injected as a WKUserScript (Task 6); the engine can't self-construct at injection time because
// WysiwygEngine needs an initialModel, which is only known once the native host has fetched one —
// so this just exposes a `mount()` entry point the Swift host calls via `evaluateJavaScript`.
window.__anglesiteWysiwygMount = {
  mount(initialModel: BlockModel): WysiwygEngine {
    // Idempotent: dispose any already-mounted engine/RichTextEditor first (#1225 final-review
    // round 2, Finding B). Now that a `WKNavigationDelegate` remounts on every navigation
    // completion while edit mode is on (`PreviewView.Coordinator.webView(_:didFinish:)`), it's
    // possible — though not expected in the steady state — for a mount to be requested while one
    // is already live (e.g. a native-side call racing the navigation-driven one across the same
    // page instance). Without this, two engine/RichTextEditor pairs would both end up wired to
    // the same DOM and both listening for the same events, corrupting hit-testing and op
    // submission. `unmount()` itself calls this same function, so an explicit unmount → mount
    // pair (the normal edit-mode-off → on cycle) stays exactly as before.
    disposeMounted();
    const engine = new WysiwygEngine(initialModel, new NativeHostTransport());
    window.__anglesiteWysiwygEngine = engine;
    // `RichTextEditor` needs an engine to submit `editText` ops through, so it's constructed here
    // rather than at injection time too — exposed globally so `WYSIWYGCanvasController.applyFormat`
    // (#1225 Task 10) can reach it via `evaluateJavaScript`. Block selection (`enter()`) is wired by
    // a different task; this only makes the instance reachable.
    window.__anglesiteWysiwygRichTextEditor = new RichTextEditor(engine);
    return engine;
  },
  // The counterpart to `mount` — called by `WYSIWYGCanvasController.unmountEngine()` (#1225
  // final-review fix wave, Findings 1/6) when Site ▸ Edit Page toggles off, or `PreviewView`'s
  // `updateNSView` observes the mounted controller change out from under an already-loaded page.
  // Disposes both globals' listeners (`WysiwygEngine.dispose()`/`RichTextEditor.dispose()` — the
  // latter also exits any in-progress edit, flushing a pending debounced commit) and clears the
  // globals so a stale `window.__anglesiteWysiwygEngine` can't answer a hit-test or accept an op
  // after the native side considers edit mode off.
  unmount(): void {
    disposeMounted();
  },
};

// Never a web context menu (spec §8.1: "the engine hit-tests and reports the block under the
// cursor; the host builds the menu"). The engine resolves the right-clicked point to a block id
// via hit-test; the native host (`WYSIWYGScriptHandler`/`WYSIWYGBlockContextMenu`) builds and pops
// up a real NSMenu there. A `document`-level listener (rather than scoping to the mounted canvas
// root) matches `hitTest`'s own `doc.elementFromPoint` — it walks up from whatever's under the
// cursor to the nearest block-id-bearing ancestor, so it doesn't matter which element the event
// started on. No engine mounted yet, or the point misses every block (chrome, empty page margin):
// fall through to the platform's default context menu instead of showing an empty one.
document.addEventListener("contextmenu", (event) => {
  const engine = window.__anglesiteWysiwygEngine;
  if (!engine) return;
  const blockId = engine.hitTest({ x: event.clientX, y: event.clientY });
  if (!blockId) return;
  event.preventDefault();
  window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "context-menu", blockId, x: event.clientX, y: event.clientY });
});

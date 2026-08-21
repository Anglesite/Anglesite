import { WysiwygEngine } from "../engine.js";
import { RichTextEditor } from "../rich-text.js";
import { QualityGateChips } from "../quality-gates.js";
import { KeyboardNavigation } from "../keyboard-nav.js";
import { AccessibilityAnnotator } from "../accessibility.js";
import { NativeHostTransport } from "./native-host-transport.js";
import type { BlockModel } from "../types.js";

declare global {
  interface Window {
    __anglesiteWysiwygEngine?: WysiwygEngine;
    __anglesiteWysiwygRichTextEditor?: RichTextEditor;
    __anglesiteWysiwygQualityGates?: QualityGateChips;
    __anglesiteWysiwygKeyboardNav?: KeyboardNavigation;
    __anglesiteWysiwygAccessibility?: AccessibilityAnnotator;
    __anglesiteWysiwygMount?: { mount: (initialModel: BlockModel, displayNames?: Record<string, string>) => WysiwygEngine; unmount: () => void };
  }
}

// Disposes whatever is currently mounted (if anything) and clears the globals — the shared body
// of `unmount()` below, factored out so `mount()` can call it too (#1225 final-review round 2,
// Finding B) rather than only being reachable from the native `unmountEngine()` call. Safe to call
// when nothing is mounted: all globals are `undefined` and the optional-chained calls no-op.
function disposeMounted(): void {
  window.__anglesiteWysiwygRichTextEditor?.dispose();
  window.__anglesiteWysiwygQualityGates?.dispose();
  window.__anglesiteWysiwygKeyboardNav?.dispose();
  window.__anglesiteWysiwygAccessibility?.dispose();
  window.__anglesiteWysiwygEngine?.dispose();
  window.__anglesiteWysiwygRichTextEditor = undefined;
  window.__anglesiteWysiwygQualityGates = undefined;
  window.__anglesiteWysiwygKeyboardNav = undefined;
  window.__anglesiteWysiwygAccessibility = undefined;
  window.__anglesiteWysiwygEngine = undefined;
}

// Injected as a WKUserScript (Task 6); the engine can't self-construct at injection time because
// WysiwygEngine needs an initialModel, which is only known once the native host has fetched one —
// so this just exposes a `mount()` entry point the Swift host calls via `evaluateJavaScript`.
window.__anglesiteWysiwygMount = {
  mount(initialModel: BlockModel, displayNames: Record<string, string> = {}): WysiwygEngine {
    // Idempotent: dispose any already-mounted engine/RichTextEditor/QualityGateChips first (#1225
    // final-review round 2, Finding B) — see the original comment on this behavior for why.
    disposeMounted();
    const transport = new NativeHostTransport();
    const engine = new WysiwygEngine(initialModel, transport);
    window.__anglesiteWysiwygEngine = engine;
    window.__anglesiteWysiwygRichTextEditor = new RichTextEditor(engine);
    // Same `transport` instance passed to both — `NativeHostTransport` implements both
    // `HostTransport` and `QualityGateTransport` (#1226 Task 12), so one object owns the whole
    // `window.__anglesiteWysiwygHost` bridge.
    window.__anglesiteWysiwygQualityGates = new QualityGateChips(engine, transport);
    window.__anglesiteWysiwygKeyboardNav = new KeyboardNavigation(engine, window.__anglesiteWysiwygRichTextEditor);
    window.__anglesiteWysiwygAccessibility = new AccessibilityAnnotator(engine, displayNames);
    // Keyboard-driven (and, later, any other JS-originated) selection changes need to reach
    // `WYSIWYGCanvasController.selectedBlockId` so native Duplicate/Delete keep acting on the right
    // block (#1589) — mirrors the `contextmenu` listener below's posting convention exactly.
    engine.selection.onChange((blockId) => {
      window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "selection-changed", blockId });
    });
    return engine;
  },
  // The counterpart to `mount` — called by `WYSIWYGCanvasController.unmountEngine()` (#1225
  // final-review fix wave, Findings 1/6) when Site ▸ Edit Page toggles off, or `PreviewView`'s
  // `updateNSView` observes the mounted controller change out from under an already-loaded page.
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

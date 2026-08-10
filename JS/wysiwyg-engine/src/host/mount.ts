import { WysiwygEngine } from "../engine.js";
import { RichTextEditor } from "../rich-text.js";
import { NativeHostTransport } from "./native-host-transport.js";
import type { BlockModel } from "../types.js";

declare global {
  interface Window {
    __anglesiteWysiwygEngine?: WysiwygEngine;
    __anglesiteWysiwygRichTextEditor?: RichTextEditor;
    __anglesiteWysiwygMount?: { mount: (initialModel: BlockModel) => WysiwygEngine };
  }
}

// Injected as a WKUserScript (Task 6); the engine can't self-construct at injection time because
// WysiwygEngine needs an initialModel, which is only known once the native host has fetched one —
// so this just exposes a `mount()` entry point the Swift host calls via `evaluateJavaScript`.
window.__anglesiteWysiwygMount = {
  mount(initialModel: BlockModel): WysiwygEngine {
    const engine = new WysiwygEngine(initialModel, new NativeHostTransport());
    window.__anglesiteWysiwygEngine = engine;
    // `RichTextEditor` needs an engine to submit `editText` ops through, so it's constructed here
    // rather than at injection time too — exposed globally so `WYSIWYGCanvasController.applyFormat`
    // (#1225 Task 10) can reach it via `evaluateJavaScript`. Block selection (`enter()`) is wired by
    // a different task; this only makes the instance reachable.
    window.__anglesiteWysiwygRichTextEditor = new RichTextEditor(engine);
    return engine;
  },
};

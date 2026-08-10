import { WysiwygEngine } from "../engine.js";
import { NativeHostTransport } from "./native-host-transport.js";
import type { BlockModel } from "../types.js";

declare global {
  interface Window {
    __anglesiteWysiwygEngine?: WysiwygEngine;
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
    return engine;
  },
};

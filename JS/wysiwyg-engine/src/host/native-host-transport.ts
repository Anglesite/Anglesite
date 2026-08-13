import type { HostTransport, OpEnvelope, OpResult, BlockModel } from "../types.js";
import type { Finding, QualityGateTransport } from "../quality-gates.js";

declare global {
  interface Window {
    webkit?: { messageHandlers?: { wysiwyg?: { postMessage(body: unknown): void } } };
    __anglesiteWysiwygHost?: {
      _handleOpResult?: (requestId: string, result: OpResult) => void;
      _handleModelUpdate?: (model: BlockModel) => void;
      _handleQualityFindings?: (findings: Finding[]) => void;
    };
  }
}

/**
 * Adapts the engine's `HostTransport` interface to the native WKWebView bridge
 * (`Sources/AnglesiteBridge/WYSIWYGScriptHandler.swift`). Posts `submit-op` messages via
 * `window.webkit.messageHandlers.wysiwyg` and resolves pending promises when the native side calls
 * back into `window.__anglesiteWysiwygHost`.
 *
 * Also implements `QualityGateTransport` (design doc §3) — one object owns the whole
 * `window.__anglesiteWysiwygHost` bridge rather than splitting it across two classes, even though
 * the two interfaces stay conceptually separate (quality-gate findings are not part of the ops
 * protocol `HostTransport` itself covers).
 */
export class NativeHostTransport implements HostTransport, QualityGateTransport {
  #pending = new Map<string, (result: OpResult) => void>();
  #modelListeners = new Set<(model: BlockModel) => void>();
  #findingsListeners = new Set<(findings: Finding[]) => void>();

  constructor() {
    window.__anglesiteWysiwygHost = {
      _handleOpResult: (requestId, result) => {
        const resolve = this.#pending.get(requestId);
        if (!resolve) return;
        this.#pending.delete(requestId);
        resolve(result);
      },
      _handleModelUpdate: (model) => {
        for (const listener of this.#modelListeners) listener(model);
      },
      _handleQualityFindings: (findings) => {
        for (const listener of this.#findingsListeners) listener(findings);
      },
    };
  }

  sendOp(envelope: OpEnvelope): Promise<OpResult> {
    return new Promise((resolve) => {
      this.#pending.set(envelope.id, resolve);
      window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "submit-op", envelope });
    });
  }

  onModelUpdate(listener: (model: BlockModel) => void): () => void {
    this.#modelListeners.add(listener);
    return () => this.#modelListeners.delete(listener);
  }

  onFindings(listener: (findings: Finding[]) => void): () => void {
    this.#findingsListeners.add(listener);
    return () => this.#findingsListeners.delete(listener);
  }
}

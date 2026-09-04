import type { HostTransport, OpEnvelope, OpResult, BlockModel, WritingHelpReply } from "../types.js";
import type { Finding, QualityGateTransport } from "../quality-gates.js";

declare global {
  interface Window {
    webkit?: { messageHandlers?: { wysiwyg?: { postMessage(body: unknown): void } } };
    __anglesiteWysiwygHost?: {
      _handleOpResult?: (requestId: string, result: OpResult) => void;
      _handleModelUpdate?: (model: BlockModel) => void;
      _handleQualityFindings?: (findings: Finding[]) => void;
      _handleWritingHelpReply?: (requestId: string, reply: WritingHelpReply) => void;
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
  // Separate namespace from #pending so a writing-help requestId never collides with an op requestId.
  #pendingWritingHelp = new Map<string, (reply: WritingHelpReply) => void>();

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
      _handleWritingHelpReply: (requestId, reply) => {
        const resolve = this.#pendingWritingHelp.get(requestId);
        if (!resolve) return;
        this.#pendingWritingHelp.delete(requestId);
        resolve(reply);
      },
    };
  }

  sendOp(envelope: OpEnvelope): Promise<OpResult> {
    return new Promise((resolve) => {
      this.#pending.set(envelope.id, resolve);
      window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "submit-op", envelope });
    });
  }

  /**
   * Requests a writing-help rewrite from the native FoundationModels-backed assistant
   * (`WritingHelpAssisting`, `Sources/AnglesiteCore/WritingHelpAssistant.swift`) via
   * `WYSIWYGScriptHandler`'s `writing-help-request` message. Never rejects — an unavailable
   * assistant or a generation failure both resolve as `{status: "unavailable", message}`.
   */
  requestWritingHelp(text: string, instruction: string): Promise<WritingHelpReply> {
    const requestId = crypto.randomUUID();
    return new Promise((resolve) => {
      this.#pendingWritingHelp.set(requestId, resolve);
      window.webkit?.messageHandlers?.wysiwyg?.postMessage({ type: "writing-help-request", requestId, text, instruction });
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

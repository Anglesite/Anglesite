import type { BlockModel, HostTransport, OpEnvelope, OpResult } from "../types.js";

/** The dev-server endpoint `Resources/Template/scripts/editor-write-reload.ts` serves. */
export const EDITOR_WRITE_ENDPOINT = "/_anglesite/editor-write";

/**
 * Op kinds whose result the page already shows correctly without a reload: a text edit was typed
 * into the live DOM before it was ever committed. Structural ops keep reloading until the
 * engine's projection is shown to match what Astro renders (#2214).
 */
export const RELOAD_FREE_OP_KINDS: ReadonlySet<string> = new Set(["editText"]);

/** How long an op waits for its "expect" announcement to reach the dev server before going out
 *  anyway. Losing the race only means the page reloads, as it did before. */
const EXPECT_TIMEOUT_MS = 250;

export type EditorWriteMessage =
  | { id: string; phase: "expect"; path: string }
  | { id: string; phase: "settle"; version: string | null };

/** Posts one message to the dev server. Never rejects. */
export type EditorWritePoster = (message: EditorWriteMessage) => Promise<void>;

export const postToDevServer: EditorWritePoster = async (message) => {
  try {
    await fetch(EDITOR_WRITE_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(message),
      keepalive: true,
    });
  } catch {
    // No dev server endpoint (an older site, a plain browser tab): the page just reloads.
  }
};

/**
 * Wraps the engine's transport so the dev server can tell the editor's own writes from every other
 * change and skip the reload for them (#2214). Before a reload-free op goes out it announces the
 * write ("expect", with the page's source path); once the op settles it reports the version the
 * write produced, or `null` if it didn't land. Every other op, and the model-update stream, pass
 * through untouched.
 */
export class SelfWriteAnnouncingTransport implements HostTransport {
  #inner: HostTransport;
  #pagePath: string;
  #post: EditorWritePoster;

  constructor(inner: HostTransport, pagePath: string, post: EditorWritePoster = postToDevServer) {
    this.#inner = inner;
    this.#pagePath = pagePath;
    this.#post = post;
  }

  async sendOp(envelope: OpEnvelope): Promise<OpResult> {
    if (!RELOAD_FREE_OP_KINDS.has(envelope.op.kind) || this.#pagePath.length === 0) {
      return this.#inner.sendOp(envelope);
    }
    await withTimeout(this.#post({ id: envelope.id, phase: "expect", path: this.#pagePath }), EXPECT_TIMEOUT_MS);
    let version: string | null = null;
    try {
      const result = await this.#inner.sendOp(envelope);
      if (result.status === "applied") version = result.model.version;
      return result;
    } finally {
      void this.#post({ id: envelope.id, phase: "settle", version });
    }
  }

  onModelUpdate(listener: (model: BlockModel) => void): () => void {
    return this.#inner.onModelUpdate(listener);
  }
}

function withTimeout(promise: Promise<void>, ms: number): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<void>((resolve) => (timer = setTimeout(resolve, ms)));
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

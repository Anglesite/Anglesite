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
 * Whether `a` and `b` have the same blocks in the same places: the same ids, each with the same
 * kind, tag and children. Only text and props may differ.
 */
export function sameBlockTree(a: BlockModel, b: BlockModel): boolean {
  if (a.rootIds.join("\u0000") !== b.rootIds.join("\u0000")) return false;
  const ids = Object.keys(a.blocks);
  if (ids.length !== Object.keys(b.blocks).length) return false;
  return ids.every((id) => {
    const x = a.blocks[id];
    const y = b.blocks[id];
    return (
      x !== undefined &&
      y !== undefined &&
      x.kind === y.kind &&
      x.componentName === y.componentName &&
      JSON.stringify(x.slots) === JSON.stringify(y.slots)
    );
  });
}

/**
 * Wraps the engine's transport so the dev server can tell the editor's own writes from every other
 * change and skip the reload for them (#2214). Before a reload-free op goes out it announces the
 * write ("expect", with the page's source path); once the op settles it reports the version the
 * write produced, or `null` if it didn't land. Every other op, and the model-update stream, pass
 * through untouched.
 *
 * A text edit that adds or removes markup (bold, a link) still reloads (#2243 review): the
 * sidecar numbers nodes in tree order, so new nodes shift every later block's id, and the page's
 * block marks (`block-stamping.ts`) would then name the wrong blocks. When `currentModel` is
 * given and the applied model's block tree differs from the one before the op, the write settles
 * as `null`, so the dev server reloads and the engine mounts afresh with matching marks.
 */
export class SelfWriteAnnouncingTransport implements HostTransport {
  #inner: HostTransport;
  #pagePath: string;
  #post: EditorWritePoster;

  #currentModel: (() => BlockModel) | undefined;

  constructor(
    inner: HostTransport,
    pagePath: string,
    post: EditorWritePoster = postToDevServer,
    currentModel?: () => BlockModel,
  ) {
    this.#inner = inner;
    this.#pagePath = pagePath;
    this.#post = post;
    this.#currentModel = currentModel;
  }

  async sendOp(envelope: OpEnvelope): Promise<OpResult> {
    if (!RELOAD_FREE_OP_KINDS.has(envelope.op.kind) || this.#pagePath.length === 0) {
      return this.#inner.sendOp(envelope);
    }
    await withTimeout(this.#post({ id: envelope.id, phase: "expect", path: this.#pagePath }), EXPECT_TIMEOUT_MS);
    const before = this.#currentModel?.();
    let version: string | null = null;
    try {
      const result = await this.#inner.sendOp(envelope);
      if (result.status === "applied" && (!before || sameBlockTree(before, result.model))) {
        version = result.model.version;
      }
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

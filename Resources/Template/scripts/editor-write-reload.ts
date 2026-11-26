import { createHash } from "node:crypto";
import { isAbsolute, normalize, relative, sep } from "node:path";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { Plugin } from "vite";

/**
 * Dev-only: skips the page reload `astro dev` does after the block editor's own write (#2214).
 *
 * Each text edit the editor commits writes the page's source through the sidecar, and the dev
 * server answers that write with a full reload. The reload throws away the editor (its selection,
 * the text being typed, the scroll position) only to show text the page already shows. The
 * editor announces each write here before sending it, then settles it with the version the write
 * produced. A reload that change would trigger is held until the write settles, and dropped only
 * when the file on disk is exactly that version — so a hand edit, a sync, or any other change
 * still reloads as before.
 *
 * The page talks to this over {@link EDITOR_WRITE_ENDPOINT}; see
 * `JS/wysiwyg-engine/src/host/self-write-transport.ts` for the other side.
 */

/** Where the editor announces and settles its writes. */
export const EDITOR_WRITE_ENDPOINT = "/_anglesite/editor-write";

/** How long a reload waits for an announced write to settle before going ahead anyway. */
const SETTLE_TIMEOUT_MS = 5_000;

/** How long a settled write still counts. A watcher (polling, in a container) can report the
 *  change after the editor has already settled it. */
const SETTLED_GRACE_MS = 3_000;

/** The largest request body the endpoint reads. */
const MAX_BODY_BYTES = 4_096;

/**
 * The sidecar's content-hash version of a source file (`server/file-version.mjs` in
 * Anglesite/anglesite-skills): the first 12 hex digits of its SHA-256. Must match exactly, or no
 * reload is ever skipped.
 */
export function fileVersion(source: string): string {
  return "sha256:" + createHash("sha256").update(source).digest("hex").slice(0, 12);
}

/** Normalizes a site-relative path from the page, or `null` if it reaches outside the site. */
export function siteRelativePath(path: string): string | null {
  if (path.length === 0 || isAbsolute(path)) return null;
  const normalized = normalize(path);
  if (normalized === ".." || normalized.startsWith(`..${sep}`)) return null;
  return normalized.split(sep).join("/");
}

interface Write {
  path: string;
  announcedAt: number;
  /** `undefined` until settled; `null` when the write didn't land. */
  version?: string | null;
  settledAt?: number;
  settled: Promise<void>;
  resolveSettled: () => void;
}

/** The editor's announced writes. Pure bookkeeping; time is injected for tests. */
export class EditorWriteLedger {
  #writes = new Map<string, Write>();
  #now: () => number;
  #settleTimeoutMs: number;

  constructor(options: { now?: () => number; settleTimeoutMs?: number } = {}) {
    this.#now = options.now ?? Date.now;
    this.#settleTimeoutMs = options.settleTimeoutMs ?? SETTLE_TIMEOUT_MS;
  }

  /** The editor is about to write `path` for op `id`. */
  expect(id: string, path: string): void {
    this.#prune();
    let resolveSettled = () => {};
    const settled = new Promise<void>((resolve) => (resolveSettled = resolve));
    this.#writes.set(id, { path, announcedAt: this.#now(), settled, resolveSettled });
  }

  /** Op `id` finished: `version` is the file's version after the write, or `null` if it failed. */
  settle(id: string, version: string | null): void {
    const write = this.#writes.get(id);
    if (!write || write.version !== undefined) return;
    write.version = version;
    write.settledAt = this.#now();
    write.resolveSettled();
  }

  /**
   * Whether the change to `path`, now holding `readContent()`, is exactly what one of the editor's
   * writes produced. Waits for any unsettled write to `path`, up to the settle timeout.
   */
  async isOwnWrite(path: string, readContent: () => string | Promise<string>): Promise<boolean> {
    this.#prune();
    const writes = [...this.#writes.values()].filter((write) => write.path === path);
    if (writes.length === 0) return false;
    await Promise.all(writes.map((write) => this.#settledOrTimeout(write)));
    const current = fileVersion(await readContent());
    return writes.some((write) => write.version === current);
  }

  /** Number of writes being tracked — for tests. */
  get size(): number {
    return this.#writes.size;
  }

  #settledOrTimeout(write: Write): Promise<void> {
    const remaining = write.announcedAt + this.#settleTimeoutMs - this.#now();
    if (write.version !== undefined || remaining <= 0) return Promise.resolve();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<void>((resolve) => (timer = setTimeout(resolve, remaining)));
    return Promise.race([write.settled, timeout]).finally(() => clearTimeout(timer));
  }

  #prune(): void {
    const now = this.#now();
    for (const [id, write] of this.#writes) {
      const expired = write.settledAt !== undefined
        ? now - write.settledAt > SETTLED_GRACE_MS
        : now - write.announcedAt > this.#settleTimeoutMs + SETTLED_GRACE_MS;
      if (expired) this.#writes.delete(id);
    }
  }
}

/** Applies one endpoint request body to `ledger`. Returns an HTTP status. */
export function handleEditorWriteMessage(ledger: EditorWriteLedger, body: unknown): number {
  if (typeof body !== "object" || body === null) return 400;
  const { id, phase, path, version } = body as Record<string, unknown>;
  if (typeof id !== "string" || id.length === 0 || id.length > 200) return 400;
  if (phase === "expect") {
    const relativePath = typeof path === "string" ? siteRelativePath(path) : null;
    if (relativePath === null) return 400;
    ledger.expect(id, relativePath);
    return 204;
  }
  if (phase === "settle") {
    if (version !== null && typeof version !== "string") return 400;
    ledger.settle(id, version);
    return 204;
  }
  return 400;
}

function readBody(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve) => {
    let size = 0;
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        resolve(undefined);
        req.destroy();
      } else {
        chunks.push(chunk);
      }
    });
    req.on("end", () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        resolve(undefined);
      }
    });
    req.on("error", () => resolve(undefined));
  });
}

/** The Vite plugin `anglesiteHarness()` adds to `astro dev`. */
export function editorWriteReloadGuard(): Plugin {
  const ledger = new EditorWriteLedger();
  let root = process.cwd();
  let log: (message: string) => void = () => {};
  // Decided once per changed file, shared by every environment's hotUpdate for that change.
  const decisions = new Map<string, Promise<boolean>>();
  // While set, a `full-reload` is the one an own write would have caused.
  let skipReloadUntil = 0;

  return {
    name: "anglesite-editor-write-reload",
    apply: "serve",
    enforce: "pre",

    configResolved(config) {
      root = config.root;
      log = (message) => config.logger.info(message, { timestamp: true });
    },

    configureServer(server) {
      server.middlewares.use(EDITOR_WRITE_ENDPOINT, (req: IncomingMessage, res: ServerResponse, next: () => void) => {
        if (req.method !== "POST") return next();
        void readBody(req).then((body) => {
          res.statusCode = handleEditorWriteMessage(ledger, body);
          res.end();
        });
      });

      // The reload payload names no file, so it's held back by timing: hotUpdate below decides
      // (awaiting the write's settle) before Vite and Astro send it.
      const channel = server.environments?.client?.hot ?? server.ws;
      const send = channel.send.bind(channel) as (...args: unknown[]) => void;
      channel.send = ((...args: unknown[]) => {
        const payload = args[0] as { type?: string } | undefined;
        if (payload?.type === "full-reload" && Date.now() < skipReloadUntil) return;
        send(...args);
      }) as typeof channel.send;
    },

    async hotUpdate({ file, read }) {
      const path = siteRelativePath(relative(root, file));
      if (path === null) return;
      let decision = decisions.get(file);
      if (!decision) {
        decision = ledger.isOwnWrite(path, read);
        decisions.set(file, decision);
        void decision.finally(() => setTimeout(() => decisions.delete(file), 1_000));
      }
      const own = await decision;
      skipReloadUntil = own ? Date.now() + 1_000 : 0;
      // Only the browser's update is dropped; the server-side module graph still invalidates,
      // so the next real navigation renders the new source.
      if (own && this.environment.name === "client") {
        log(`[anglesite] kept the editor open after its own change to ${path}`);
        return [];
      }
    },
  };
}

# Vouch protocol for webmention spam mitigation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add IndieWeb [Vouch](https://indieweb.org/Vouch) support to inbound Webmentions — an optional sender-supplied URL that, when it also links to the target's domain, is recorded as a trust signal and rendered on the received interaction.

**Architecture:** The fetch/verify pipeline lives in `@dwk/webmention` (sidecar repo `davidwkeith/workers`); Anglesite only composes it. Vouch verification is added to that package the same way RSVP support was: an optional field on the queue job → a new `verifyVouch` check (twin of `verifySource`) → an additive D1 column → surfaced in `VerifiedMention`. Anglesite then threads the new field through its D1 reader, Swift model, Zod schema, and Astro render — no new moderation queue, no change to the existing hard verification gate.

**Tech Stack:** TypeScript (Cloudflare Workers, vitest + `@cloudflare/vitest-pool-workers`) for the sidecar package; Swift 6.4 (`AnglesiteCore`, Swift Testing) + Astro/Zod (`node:test`) for the app.

Full design: [`docs/superpowers/specs/2026-08-20-vouch-webmention-design.md`](../specs/2026-08-20-vouch-webmention-design.md).

## Global Constraints

- Sidecar repo (`davidwkeith/workers`): Node.js >= 22, pnpm 10 (`corepack enable`). Before any PR: `pnpm lint && pnpm format:check && pnpm typecheck && pnpm build && pnpm test` must pass (CONTRIBUTING.md ▸ "Development workflow").
- Sidecar: every behavior change needs a colocated test in the package's `src/*.test.ts` (CONTRIBUTING.md).
- Sidecar: read `packages/webmention/spec/packages/webmention.md`-adjacent doc comments before changing behavior; keep doc comments accurate, don't add a separate spec file.
- App repo (this one): macOS 27+ / Xcode 27+ (Swift 6.4). Run `swift test --package-path .` before opening the PR (`AnglesiteCoreTests` covers everything touched here).
- App repo: `npm test` inside `Resources/Template/` (or the narrower `npm run test:scripts`) covers `src/lib/*.test.ts`.
- Conventional commits, subject <= 72 characters.
- **Do not put a GitHub closing keyword (`Closes #1597`) in the sidecar PR** — #1597 is an Anglesite issue; a cross-repo closing keyword would close it before the app-side half ships. Reference it as plain text (`part of Anglesite/Anglesite#1597`) instead. Reserve `Closes #1597` for the final Anglesite PR (Task 10).
- Both repos: additive-only. No existing field, column, or exported signature changes shape — only new optional ones are added, matching every other field in this pipeline (`rsvp`, the mf2-enrichment columns).

---

## Sidecar: `@dwk/webmention` (davidwkeith/workers)

Do this work in a worktree off `origin/main` (the local `main` branch is behind `origin/main`, and the checked-out branch `codex/issue-327-phase-3` is unrelated feature work — do not build on either).

### Task 1: `WebmentionJob.vouch` + receive-handler parsing

**Files:**
- Create worktree: `/Users/dwk/Developer/github.com/davidwkeith/workers/.claude/worktrees/vouch-1597/` on a new branch `feat/vouch-webmention` based on `origin/main`
- Modify: `packages/webmention/src/index.ts` (`WebmentionJob` interface, `createWebmention`)
- Test: `packages/webmention/src/index.test.ts`

**Interfaces:**
- Produces: `WebmentionJob.vouch?: string` (raw form value, already validated as a syntactically valid `http(s)` URL — or absent).

- [ ] **Step 1: Create the worktree**

```bash
cd /Users/dwk/Developer/github.com/davidwkeith/workers
git fetch origin main
git worktree add .claude/worktrees/vouch-1597 -b feat/vouch-webmention origin/main
cd .claude/worktrees/vouch-1597
pnpm install
pnpm build
```

- [ ] **Step 2: Write the failing tests**

In `packages/webmention/src/index.test.ts`, change the `formPost` helper to accept an optional third argument, and add two new `it` blocks inside `describe("createWebmention", ...)`:

```ts
function formPost(source?: string, target?: string, vouch?: string): Request {
  const body = new URLSearchParams();
  if (source !== undefined) body.set("source", source);
  if (target !== undefined) body.set("target", target);
  if (vouch !== undefined) body.set("vouch", vouch);
  return new Request("https://example.com/webmention", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });
}
```

```ts
  it("includes a syntactically valid vouch URL in the enqueued job", async () => {
    const handler = createWebmention(config);
    const { env, sent } = envWithQueue();
    const response = await handler(
      formPost(
        "https://other.example/p",
        "https://example.com/article",
        "https://vouches.example/for-me",
      ),
      env,
      ctx,
    );
    expect(response.status).toBe(202);
    expect(sent).toEqual([
      {
        source: "https://other.example/p",
        target: "https://example.com/article",
        vouch: "https://vouches.example/for-me",
      },
    ]);
  });

  it("drops a malformed vouch URL instead of rejecting the mention", async () => {
    const handler = createWebmention(config);
    const { env, sent } = envWithQueue();
    const response = await handler(
      formPost(
        "https://other.example/p",
        "https://example.com/article",
        "not-a-url",
      ),
      env,
      ctx,
    );
    expect(response.status).toBe(202);
    expect(sent).toEqual([
      {
        source: "https://other.example/p",
        target: "https://example.com/article",
      },
    ]);
  });
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `pnpm test --project @dwk/webmention -- -t "vouch"`
Expected: FAIL — `sent[0]` has no `vouch` key yet (the job is still just `{ source, target }`).

- [ ] **Step 4: Implement**

In `packages/webmention/src/index.ts`, add `vouch` to `WebmentionJob`:

```ts
/** A queued verification job: confirm that `source` links to `target`. */
export interface WebmentionJob {
  readonly source: string;
  readonly target: string;
  /**
   * The sender's Vouch URL (indieweb.org/Vouch), when supplied and
   * syntactically a valid `http(s)` URL. Verified asynchronously alongside
   * `source`/`target` — see {@link verifyVouch} in `verify.ts`.
   */
  readonly vouch?: string;
}
```

Add a small parsing helper right after `formValue`:

```ts
/**
 * Extract and validate the optional `vouch` form field. A missing or
 * syntactically invalid value returns `undefined` rather than an error —
 * Vouch is a supplementary trust signal (indieweb.org/Vouch), not a required
 * one, so a malformed vouch parameter must never turn into a whole-mention
 * rejection.
 */
function validVouchUrl(value: string | File | null): string | undefined {
  const raw = formValue(value);
  if (raw === null || raw === "") {
    return undefined;
  }
  try {
    const url = new URL(raw);
    return url.protocol === "http:" || url.protocol === "https:"
      ? url.toString()
      : undefined;
  } catch {
    return undefined;
  }
}
```

Then in `createWebmention`, read it and thread it into the enqueue call:

```ts
    const vouch = validVouchUrl(form.get("vouch"));

    await env.WEBMENTION_QUEUE.send({
      source: result.source,
      target: result.target,
      ...(vouch !== undefined ? { vouch } : {}),
    });
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pnpm test --project @dwk/webmention -- -t "vouch"`
Expected: PASS

- [ ] **Step 6: Run the full package gate and commit**

```bash
pnpm --filter @dwk/webmention typecheck
pnpm --filter @dwk/webmention build
pnpm test --project @dwk/webmention
git add packages/webmention/src/index.ts packages/webmention/src/index.test.ts
git commit -m "feat(webmention): accept an optional vouch URL on receive"
```

---

### Task 2: `VerifiedMention.vouch` + D1 inbox columns

**Files:**
- Modify: `packages/webmention/src/inbox.ts`
- Test: `packages/webmention/src/inbox.test.ts`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `VerifiedMention.vouch?: { readonly url: string; readonly verified: boolean }`; `InboxStore.store()`/`list()` round-trip it via new `vouch_url TEXT` / `vouch_verified INTEGER` columns.

- [ ] **Step 1: Write the failing tests**

Add to `packages/webmention/src/inbox.test.ts` (inside `describe("createD1Inbox", ...)`):

```ts
  it("persists and lists a vouch outcome", async () => {
    const inbox = createD1Inbox(db, { table: "wm_vouch" });
    await inbox.store({
      source: "https://a.example/vouch",
      target: "https://example.com/x",
      verifiedAt: 1,
      vouch: { url: "https://trusted.example/", verified: true },
    });
    const all = await inbox.list();
    expect(all[0]?.vouch).toEqual({
      url: "https://trusted.example/",
      verified: true,
    });
  });

  it("distinguishes a failed vouch attempt from no vouch at all", async () => {
    const inbox = createD1Inbox(db, { table: "wm_vouch_failed" });
    await inbox.store({
      source: "https://a.example/vouch",
      target: "https://example.com/x",
      verifiedAt: 1,
      vouch: { url: "https://untrusted.example/", verified: false },
    });
    const all = await inbox.list();
    expect(all[0]?.vouch).toEqual({
      url: "https://untrusted.example/",
      verified: false,
    });
  });

  it("omits vouch on a mention stored without one", async () => {
    const inbox = createD1Inbox(db, { table: "wm_no_vouch" });
    await inbox.store({
      source: "https://a.example/p",
      target: "https://example.com/x",
      verifiedAt: 1,
    });
    const all = await inbox.list();
    expect(all[0]?.vouch).toBeUndefined();
  });

  it("migrates a pre-vouch table additively", async () => {
    // A table created by a @dwk/webmention version before vouch support
    // existed — has every enrichment column except vouch_url/vouch_verified.
    await db
      .prepare(
        "CREATE TABLE wm_pre_vouch (source TEXT NOT NULL, target TEXT NOT NULL, " +
          "verified_at INTEGER NOT NULL, rsvp TEXT, id TEXT, interaction_type TEXT, " +
          "author_name TEXT, author_url TEXT, author_photo TEXT, content TEXT, " +
          "published_at INTEGER, PRIMARY KEY (source, target))",
      )
      .run();
    await db
      .prepare(
        "INSERT INTO wm_pre_vouch (source, target, verified_at, id) VALUES (?1, ?2, ?3, ?4)",
      )
      .bind(
        "https://old.example/p",
        "https://example.com/x",
        7,
        mentionId("https://old.example/p", "https://example.com/x"),
      )
      .run();

    const inbox = createD1Inbox(db, { table: "wm_pre_vouch" });
    const preExisting = (await inbox.list())[0];
    expect(preExisting?.vouch).toBeUndefined();

    await inbox.store({
      source: "https://new.example/vouched",
      target: "https://example.com/x",
      verifiedAt: 8,
      vouch: { url: "https://trusted.example/", verified: true },
    });
    const vouched = (await inbox.list()).find(
      (m) => m.source === "https://new.example/vouched",
    );
    expect(vouched?.vouch).toEqual({
      url: "https://trusted.example/",
      verified: true,
    });
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test --project @dwk/webmention -- -t "vouch"`
Expected: FAIL — `vouch` is not a recognized field on `VerifiedMention`/not persisted.

- [ ] **Step 3: Implement**

In `packages/webmention/src/inbox.ts`:

Add to `ADDED_COLUMNS` (after the existing `published_at` entry):

```ts
const ADDED_COLUMNS: ReadonlyArray<readonly [name: string, type: string]> = [
  ["rsvp", "TEXT"],
  ["id", "TEXT"],
  ["interaction_type", "TEXT"],
  ["author_name", "TEXT"],
  ["author_url", "TEXT"],
  ["author_photo", "TEXT"],
  ["content", "TEXT"],
  ["published_at", "INTEGER"],
  ["vouch_url", "TEXT"],
  ["vouch_verified", "INTEGER"],
];
```

Add to `VerifiedMention`:

```ts
  /**
   * The sender's Vouch URL (indieweb.org/Vouch) and whether it was confirmed
   * to link to the target's domain; omitted when no vouch was sent. A vouch
   * that was sent but did NOT check out is still recorded (`verified: false`)
   * — distinct from no vouch at all, since a failed vouch attempt is a
   * stronger spam signal than silence.
   */
  readonly vouch?: { readonly url: string; readonly verified: boolean };
```

Add to `MentionRow`:

```ts
  readonly vouch_url: string | null;
  readonly vouch_verified: number | null;
```

In `store()`, extend the `INSERT`:

```ts
    async store(mention) {
      await ensureSchema();
      await db
        .prepare(
          `INSERT INTO ${table} (source, target, verified_at, rsvp, id, ` +
            `interaction_type, author_name, author_url, author_photo, ` +
            `content, published_at, vouch_url, vouch_verified) ` +
            `VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13) ` +
            `ON CONFLICT (source, target) ` +
            `DO UPDATE SET verified_at = excluded.verified_at, ` +
            `rsvp = excluded.rsvp, ` +
            `id = excluded.id, ` +
            `interaction_type = excluded.interaction_type, ` +
            `author_name = excluded.author_name, ` +
            `author_url = excluded.author_url, ` +
            `author_photo = excluded.author_photo, ` +
            `content = excluded.content, ` +
            `published_at = excluded.published_at, ` +
            `vouch_url = excluded.vouch_url, ` +
            `vouch_verified = excluded.vouch_verified`,
        )
        .bind(
          mention.source,
          mention.target,
          mention.verifiedAt,
          mention.rsvp ?? null,
          mentionId(mention.source, mention.target),
          mention.interactionType ?? "mention",
          mention.author?.name ?? null,
          mention.author?.url ?? null,
          mention.author?.photo ?? null,
          mention.content ?? null,
          mention.publishedAt ?? mention.verifiedAt,
          mention.vouch?.url ?? null,
          mention.vouch !== undefined ? (mention.vouch.verified ? 1 : 0) : null,
        )
        .run();
    },
```

In `list()`, extend the selected columns and the row mapping:

```ts
      const columns =
        `id, source, target, verified_at, rsvp, interaction_type, ` +
        `author_name, author_url, author_photo, content, published_at, ` +
        `vouch_url, vouch_verified`;
```

```ts
        const vouch =
          row.vouch_url !== null && row.vouch_verified !== null
            ? { url: row.vouch_url, verified: row.vouch_verified !== 0 }
            : undefined;
        return {
          id: row.id ?? mentionId(row.source, row.target),
          source: row.source,
          target: row.target,
          verifiedAt: row.verified_at,
          interactionType:
            row.interaction_type !== null &&
            isInteractionType(row.interaction_type)
              ? row.interaction_type
              : "mention",
          ...(author !== undefined ? { author } : {}),
          ...(row.content !== null ? { content: row.content } : {}),
          publishedAt: row.published_at ?? row.verified_at,
          ...(row.rsvp !== null && isRsvpValue(row.rsvp)
            ? { rsvp: row.rsvp }
            : {}),
          ...(vouch !== undefined ? { vouch } : {}),
        };
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test --project @dwk/webmention -- -t "vouch"`
Expected: PASS

- [ ] **Step 5: Run the full package gate and commit**

```bash
pnpm --filter @dwk/webmention typecheck
pnpm --filter @dwk/webmention build
pnpm test --project @dwk/webmention
git add packages/webmention/src/inbox.ts packages/webmention/src/inbox.test.ts
git commit -m "feat(webmention): store vouch outcome on the inbox record"
```

---

### Task 3: `verifyVouch` + `VouchVerified` log event

**Files:**
- Modify: `packages/webmention/src/verify.ts`
- Modify: `packages/webmention/src/log.ts`
- Modify: `packages/webmention/src/index.ts` (export block only)
- Test: `packages/webmention/src/verify.test.ts`

**Interfaces:**
- Consumes: `safeFetch`, `readBodyCapped`, `FetchLike` (`@dwk/safe-fetch`); `isHtmlContentType` (`./html.js`); `extractLinks` (already local to `verify.ts`); `hostFromUrl`, `noopLogger`, `noopMetrics` (`@dwk/log`).
- Produces: `verifyVouch(vouchUrl: string, target: string, options?: VerifyOptions): Promise<VouchResult>` where `VouchResult = { readonly verified: boolean }`. Never throws.

- [ ] **Step 1: Write the failing tests**

Add to `packages/webmention/src/verify.test.ts` (new top-level `describe`, after the existing `describe("verifySource", ...)` block):

```ts
describe("verifyVouch", () => {
  const vouchUrl = "https://vouches.example/for-me";

  it("is verified true when the vouch page links to the target's host", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response(`<a href="${target}">I trust this site</a>`, {
          headers: { "content-type": "text/html" },
        }),
    );
    expect(
      await verifyVouch(vouchUrl, target, { fetch: fetchImpl }),
    ).toEqual({ verified: true });
  });

  it("is verified true for a link to a different path under the target's host", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response('<a href="https://example.com/somewhere-else">x</a>', {
          headers: { "content-type": "text/html" },
        }),
    );
    expect(
      await verifyVouch(vouchUrl, target, { fetch: fetchImpl }),
    ).toEqual({ verified: true });
  });

  it("is verified false when the vouch page links elsewhere", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response('<a href="https://elsewhere.example/">x</a>', {
          headers: { "content-type": "text/html" },
        }),
    );
    expect(
      await verifyVouch(vouchUrl, target, { fetch: fetchImpl }),
    ).toEqual({ verified: false });
  });

  it("is verified false for a 404 vouch page", async () => {
    const fetchImpl = vi.fn(async () => new Response("gone", { status: 404 }));
    expect(
      await verifyVouch(vouchUrl, target, { fetch: fetchImpl }),
    ).toEqual({ verified: false });
  });

  it("is verified false when the fetch throws", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new Error("network");
    });
    expect(
      await verifyVouch(vouchUrl, target, { fetch: fetchImpl }),
    ).toEqual({ verified: false });
  });

  it("is verified false for a non-HTML vouch page", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response(JSON.stringify({ ref: target }), {
          headers: { "content-type": "application/json" },
        }),
    );
    expect(
      await verifyVouch(vouchUrl, target, { fetch: fetchImpl }),
    ).toEqual({ verified: false });
  });
});
```

And update the import line at the top of the file:

```ts
import { extractLinks, sourceLinksTo, verifySource, verifyVouch } from "./verify.js";
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test --project @dwk/webmention -- -t "verifyVouch"`
Expected: FAIL — `verifyVouch` is not exported.

- [ ] **Step 3: Implement**

In `packages/webmention/src/log.ts`, add a new event (after `VerifyFetchFailed`):

```ts
  /** Vouch verification finished. Fields: `verified`. */
  VouchVerified: "webmention.vouch.verified",
```

In `packages/webmention/src/verify.ts`, add after `verifySource`:

```ts
/** Outcome of fetching and checking a Vouch URL. */
export interface VouchResult {
  /** Whether the vouch page links anywhere under the target's hostname. */
  readonly verified: boolean;
}

/**
 * Fetch `vouchUrl` and check whether it links anywhere under `target`'s
 * hostname — the Vouch protocol's trust signal (indieweb.org/Vouch): a page
 * already known to (or trusted by) the sender is fetched and confirmed to
 * link back to the target's domain, raising confidence the mention isn't
 * spam.
 *
 * Uses the same SSRF-safe {@link safeFetch} wrapper as {@link verifySource}.
 * Unlike {@link sourceLinksTo}'s exact-URL match, this checks **hostname**
 * equality — any link on the vouch page pointing anywhere under the target's
 * host counts, per the "domain of the target" wording of the spec. Only HTML
 * vouch pages are scanned (this is a hyperlink check, not the multi-format
 * exact-match Webmention verification itself needs). Any fetch failure,
 * non-2xx status, non-HTML response, or oversized/unreadable body yields
 * `{ verified: false }`; this function never throws.
 */
export async function verifyVouch(
  vouchUrl: string,
  target: string,
  options?: VerifyOptions,
): Promise<VouchResult> {
  const doFetch: FetchLike =
    options?.fetch ?? ((input, init) => fetch(input, init));
  const logger = options?.logger ?? noopLogger;
  const metrics = options?.metrics ?? noopMetrics;

  let targetHost: string;
  try {
    targetHost = new URL(target).hostname.toLowerCase();
  } catch {
    return { verified: false };
  }

  let response: Response;
  let base: string;
  try {
    const result = await safeFetch(
      doFetch,
      vouchUrl,
      { method: "GET", headers: { accept: "text/html, */*" } },
      {
        logger,
        metrics,
        logEvent: WebmentionLogEvent.SsrfBlocked,
        allowedHosts: options?.fetchAllowedHosts,
      },
    );
    response = result.response;
    base = result.url;
  } catch {
    return { verified: false };
  }

  if (!response.ok) {
    return { verified: false };
  }

  const contentType = response.headers.get("content-type") ?? "";
  if (!isHtmlContentType(contentType)) {
    return { verified: false };
  }

  const body = await readBodyCapped(response);
  if (body === null) {
    return { verified: false };
  }

  const links = await extractLinks(body, base);
  const verified = links.some((link) => {
    try {
      return new URL(link).hostname.toLowerCase() === targetHost;
    } catch {
      return false;
    }
  });

  const fields = {
    vouchHost: hostFromUrl(vouchUrl),
    targetHost: hostFromUrl(target),
    verified,
  };
  logger.info(WebmentionLogEvent.VouchVerified, fields);
  metrics.count(WebmentionLogEvent.VouchVerified, fields);
  return { verified };
}
```

In `packages/webmention/src/index.ts`, extend the re-export block:

```ts
export {
  verifySource,
  sourceLinksTo,
  extractLinks,
  verifyVouch,
  type VerifyOptions,
  type VerifyResult,
  type VouchResult,
} from "./verify.js";
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test --project @dwk/webmention -- -t "verifyVouch"`
Expected: PASS

- [ ] **Step 5: Run the full package gate and commit**

```bash
pnpm --filter @dwk/webmention typecheck
pnpm --filter @dwk/webmention build
pnpm test --project @dwk/webmention
git add packages/webmention/src/verify.ts packages/webmention/src/verify.test.ts \
  packages/webmention/src/log.ts packages/webmention/src/index.ts
git commit -m "feat(webmention): verify vouch URLs against the target's domain"
```

---

### Task 4: wire vouch verification into the queue consumer

**Files:**
- Modify: `packages/webmention/src/index.ts` (`createWebmentionQueueConsumer`)
- Test: `packages/webmention/src/index.test.ts`

**Interfaces:**
- Consumes: `WebmentionJob.vouch` (Task 1), `verifyVouch` (Task 3), `VerifiedMention.vouch` (Task 2).
- Produces: a stored mention carries `vouch` exactly when `message.body.vouch` was present and the mention itself verified (`result.links === true`).

- [ ] **Step 1: Write the failing tests**

Add to `packages/webmention/src/index.test.ts` (inside `describe("createWebmentionQueueConsumer", ...)`):

```ts
  it("verifies and stores a vouch when the job includes one and the mention verifies", async () => {
    const inbox = new MemoryInbox();
    const fetchImpl: FetchLike = vi.fn(async (input) => {
      const url = String(input);
      if (url === "https://vouches.example/for-me") {
        return new Response(
          '<a href="https://example.com/article">I trust this</a>',
          { headers: { "content-type": "text/html" } },
        );
      }
      return new Response('<a href="https://example.com/article">x</a>', {
        headers: { "content-type": "text/html" },
      });
    });
    const consumer = createWebmentionQueueConsumer({
      ...config,
      inbox,
      fetch: fetchImpl,
    });
    const { batch } = batchOf([
      {
        source: "https://other.example/p",
        target: "https://example.com/article",
        vouch: "https://vouches.example/for-me",
      },
    ]);
    await consumer(batch, {} as WebmentionEnv, ctx);

    const [stored] = await inbox.list();
    expect(stored?.vouch).toEqual({
      url: "https://vouches.example/for-me",
      verified: true,
    });
  });

  it("stores a failed vouch outcome without affecting the mention itself", async () => {
    const inbox = new MemoryInbox();
    const fetchImpl: FetchLike = vi.fn(async (input) => {
      const url = String(input);
      if (url === "https://vouches.example/for-me") {
        return new Response('<a href="https://elsewhere.example/">x</a>', {
          headers: { "content-type": "text/html" },
        });
      }
      return new Response('<a href="https://example.com/article">x</a>', {
        headers: { "content-type": "text/html" },
      });
    });
    const consumer = createWebmentionQueueConsumer({
      ...config,
      inbox,
      fetch: fetchImpl,
    });
    const { batch } = batchOf([
      {
        source: "https://other.example/p",
        target: "https://example.com/article",
        vouch: "https://vouches.example/for-me",
      },
    ]);
    await consumer(batch, {} as WebmentionEnv, ctx);

    const [stored] = await inbox.list();
    expect(stored?.vouch).toEqual({
      url: "https://vouches.example/for-me",
      verified: false,
    });
    expect(stored?.source).toBe("https://other.example/p");
  });

  it("stores no vouch field when the job carries none", async () => {
    const inbox = new MemoryInbox();
    const fetchImpl: FetchLike = vi.fn(
      async () =>
        new Response('<a href="https://example.com/article">x</a>', {
          headers: { "content-type": "text/html" },
        }),
    );
    const consumer = createWebmentionQueueConsumer({
      ...config,
      inbox,
      fetch: fetchImpl,
    });
    const { batch } = batchOf([
      {
        source: "https://other.example/p",
        target: "https://example.com/article",
      },
    ]);
    await consumer(batch, {} as WebmentionEnv, ctx);

    const [stored] = await inbox.list();
    expect(stored?.vouch).toBeUndefined();
  });

  it("never fetches the vouch URL when the source itself does not verify", async () => {
    const inbox = new MemoryInbox();
    const fetchedUrls: string[] = [];
    const fetchImpl: FetchLike = vi.fn(async (input) => {
      fetchedUrls.push(String(input));
      return new Response("<p>link removed</p>", {
        headers: { "content-type": "text/html" },
      });
    });
    const consumer = createWebmentionQueueConsumer({
      ...config,
      inbox,
      fetch: fetchImpl,
    });
    const { batch } = batchOf([
      {
        source: "https://other.example/p",
        target: "https://example.com/article",
        vouch: "https://vouches.example/for-me",
      },
    ]);
    await consumer(batch, {} as WebmentionEnv, ctx);

    expect(fetchedUrls).toEqual(["https://other.example/p"]);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test --project @dwk/webmention -- -t "vouch"`
Expected: FAIL — the consumer never calls `verifyVouch` yet, so `stored?.vouch` is always `undefined` and the "never fetches" test's premise doesn't yet distinguish behavior.

- [ ] **Step 3: Implement**

In `packages/webmention/src/index.ts`, inside `createWebmentionQueueConsumer`'s loop, change:

```ts
      const { source, target } = message.body;
```

to:

```ts
      const { source, target, vouch } = message.body;
```

and change the `if (result.links) { ... }` block to:

```ts
        if (result.links) {
          const verifiedAt = Date.now();
          // `dt-published` when the entry declares (and we can parse) it,
          // else the verification time — the field is always populated.
          const publishedMs =
            result.published !== undefined
              ? Date.parse(result.published)
              : Number.NaN;
          // Vouch only runs once the mention itself has verified — it is a
          // trust signal on top of a real mention, never a substitute for one.
          const vouchResult =
            vouch !== undefined
              ? await verifyVouch(vouch, target, {
                  fetch: config.fetch,
                  logger,
                  metrics,
                  fetchAllowedHosts: config.fetchAllowedHosts,
                })
              : undefined;
          await inbox.store({
            source,
            target,
            verifiedAt,
            interactionType: result.interactionType ?? "mention",
            ...(result.author !== undefined ? { author: result.author } : {}),
            ...(result.content !== undefined
              ? { content: result.content }
              : {}),
            publishedAt: Number.isFinite(publishedMs)
              ? publishedMs
              : verifiedAt,
            ...(result.rsvp !== undefined ? { rsvp: result.rsvp } : {}),
            ...(vouchResult !== undefined
              ? { vouch: { url: vouch, verified: vouchResult.verified } }
              : {}),
          });
        } else {
          await inbox.remove(source, target);
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test --project @dwk/webmention -- -t "vouch"`
Expected: PASS

- [ ] **Step 5: Run the full package gate and commit**

```bash
pnpm --filter @dwk/webmention typecheck
pnpm --filter @dwk/webmention build
pnpm test --project @dwk/webmention
git add packages/webmention/src/index.ts packages/webmention/src/index.test.ts
git commit -m "feat(webmention): verify vouch URLs during queue consumption"
```

---

### Task 5: changeset, version bump, full repo gate, PR

**Files:**
- Create: `.changeset/webmention-vouch.md`
- Modify: `packages/webmention/package.json` (version)

- [ ] **Step 1: Add the changeset**

```bash
cat > .changeset/webmention-vouch.md <<'EOF'
---
"@dwk/webmention": minor
---

Recognize IndieWeb Vouch (indieweb.org/Vouch). A receiver may include an
optional `vouch` form field alongside `source`/`target`; during asynchronous
verification, once the mention itself verifies, the vouch URL is fetched and
checked for a link back to the target's hostname. The outcome is persisted on
the inbox record (`vouch: { url, verified }`, new nullable `vouch_url` /
`vouch_verified` columns, migrated additively on existing inboxes) — a vouch
that fails is stored distinctly from no vouch at all. Vouch never overrides
the primary source-links-to-target gate; a failed or absent vouch does not
reject the mention. Exports `verifyVouch` and `VouchResult`; `WebmentionJob`
and `VerifiedMention` gain an optional `vouch`. Part of
Anglesite/Anglesite#1597.
EOF
```

- [ ] **Step 2: Bump the package version**

Edit `packages/webmention/package.json`, changing `"version": "1.0.0-beta.1"` to `"version": "1.0.0-beta.2"`.

- [ ] **Step 3: Run the full repo gate**

```bash
pnpm lint && pnpm format:check && pnpm typecheck && pnpm build && pnpm test
```

Expected: all green. Fix any failure before proceeding — do not skip a failing check.

- [ ] **Step 4: Commit, push, open the PR**

```bash
git add .changeset/webmention-vouch.md packages/webmention/package.json
git commit -m "feat(webmention): bump to 1.0.0-beta.2 for vouch support"
git push -u origin feat/vouch-webmention
```

Confirm with the user before running `gh pr create` (pushing/opening a PR needs explicit confirmation per the standing safety rules — do not skip this even though the design was pre-approved). Once confirmed, open the PR against `davidwkeith/workers` main with a summary of the vouch feature and `part of Anglesite/Anglesite#1597` in the body (no closing keyword — see Global Constraints).

**Do not proceed to Task 6 until this PR has merged and a tagged `1.0.0-beta.2` (or later) release of `@dwk/webmention` is published to npm** — Task 6 bumps Anglesite's dependency on that exact published version. Check with `npm view @dwk/webmention versions --json`.

---

## App side (Anglesite/Anglesite)

### Task 6: bump `@dwk/webmention` and extend `WebmentionInboxD1Client`

**Files:**
- Modify: `Resources/Template/package.json`
- Modify: `Sources/AnglesiteCore/WebmentionInboxD1Client.swift`
- Test: `Tests/AnglesiteCoreTests/WebmentionInboxD1ClientTests.swift`

**Interfaces:**
- Produces: `WebmentionInboxD1Client.Mention.vouchURL: String? = nil`, `.vouchVerified: Bool? = nil` (defaulted so all 13 existing call sites keep compiling unchanged).

- [ ] **Step 1: Bump the template's pinned version**

In `Resources/Template/package.json`, change `"@dwk/webmention": "1.0.0-beta.1"` to `"@dwk/webmention": "1.0.0-beta.2"` (or whatever version Task 5 actually published — verify with `npm view @dwk/webmention versions --json` first).

- [ ] **Step 2: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/WebmentionInboxD1ClientTests.swift`, after `listsVerifiedMentionsWithEnrichment`:

```swift
    @Test("decodes a vouched mention")
    func decodesVouchedMention() async throws {
        let body = Data("""
        {"success": true, "result": [{"success": true, "results": [
            {"id": "wm-abc123", "source": "https://alice.example/post", "target": "https://me.example/blog/hi",
             "verified_at": 1753300000000, "interaction_type": "reply", "author_name": "Alice",
             "author_url": "https://alice.example", "author_photo": "https://alice.example/photo.jpg",
             "content": "Great post!", "published_at": 1753299000000,
             "vouch_url": "https://trusted.example/", "vouch_verified": 1}
        ]}]}
        """.utf8)

        let client = WebmentionInboxD1Client(
            accountID: "acct1", databaseID: "db1", apiToken: "token",
            transport: { _ in (body, Self.response(200)) })

        let mentions = try await client.listVerifiedMentions()
        let mention = try #require(mentions.first)
        #expect(mention.vouchURL == "https://trusted.example/")
        #expect(mention.vouchVerified == true)
    }

    @Test("decodes an unverified vouch attempt as verified == false, not nil")
    func decodesUnverifiedVouch() async throws {
        let body = Data("""
        {"success": true, "result": [{"success": true, "results": [
            {"id": "wm-ghi789", "source": "https://carol.example/post", "target": "https://me.example/blog/hi",
             "verified_at": 1753300000000, "interaction_type": null, "author_name": null,
             "author_url": null, "author_photo": null, "content": null, "published_at": null,
             "vouch_url": "https://untrusted.example/", "vouch_verified": 0}
        ]}]}
        """.utf8)

        let client = WebmentionInboxD1Client(
            accountID: "acct1", databaseID: "db1", apiToken: "token",
            transport: { _ in (body, Self.response(200)) })

        let mentions = try await client.listVerifiedMentions()
        let mention = try #require(mentions.first)
        #expect(mention.vouchURL == "https://untrusted.example/")
        #expect(mention.vouchVerified == false)
    }

```

Do not add a third "no vouch columns present" test — the existing
`decodesLegacyRowsWithNullEnrichmentColumns` test already covers it unmodified:
its JSON has no `vouch_url`/`vouch_verified` keys at all, and Swift's
synthesized `Decodable` treats a missing key on an `Optional` property as
`nil`, so it exercises exactly that case once `Row` gains the two optional
fields in Step 3.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path . --filter WebmentionInboxD1ClientTests`
Expected: FAIL to compile — `Mention` has no `vouchURL`/`vouchVerified` members yet.

- [ ] **Step 4: Implement**

In `Sources/AnglesiteCore/WebmentionInboxD1Client.swift`, extend `Mention`:

```swift
        /// Source page's declared publication date in epoch milliseconds, when enrichment ran.
        public let publishedAt: Int?
        /// The sender's Vouch URL (indieweb.org/Vouch), when supplied and the mention verified.
        /// `nil` when no vouch was sent, or the row predates vouch support upstream.
        public let vouchURL: String? = nil
        /// Whether `vouchURL` was confirmed to link to this mention's target domain. `nil` exactly
        /// when `vouchURL` is `nil`; otherwise `true`/`false` — a failed vouch attempt is still
        /// recorded (not collapsed into "no vouch"), since it's a stronger spam signal than silence.
        public let vouchVerified: Bool? = nil
    }
```

(The `= nil` defaults on `Mention`'s new stored properties keep its synthesized memberwise initializer backward-compatible — all 13 existing call sites across the codebase keep compiling with no vouch arguments.)

Extend `Row`:

```swift
    private struct Row: Decodable {
        let id: String?
        let source: String
        let target: String
        let verified_at: Int
        let interaction_type: String?
        let author_name: String?
        let author_url: String?
        let author_photo: String?
        let content: String?
        let published_at: Int?
        let vouch_url: String?
        let vouch_verified: Int?
    }
```

Extend `listVerifiedSQL`:

```swift
    private static let listVerifiedSQL = """
    SELECT id, source, target, verified_at, interaction_type, author_name, author_url, \
    author_photo, content, published_at, vouch_url, vouch_verified FROM webmentions ORDER BY verified_at DESC
    """
```

Extend the mapping in `listVerifiedMentions()`:

```swift
        return rows.compactMap { row in
            guard let id = row.id else { return nil }
            return Mention(
                id: id, source: row.source, target: row.target, verifiedAt: row.verified_at,
                interactionType: row.interaction_type, authorName: row.author_name,
                authorURL: row.author_url, authorPhoto: row.author_photo, content: row.content,
                publishedAt: row.published_at, vouchURL: row.vouch_url,
                vouchVerified: row.vouch_verified.map { $0 != 0 })
        }
```

Also update the class-level doc comment's "tolerates the enrichment columns... being entirely `NULL`" note to mention `vouch_url`/`vouch_verified` alongside the existing list, since the same tolerance now applies to them too.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path . --filter WebmentionInboxD1ClientTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/package.json Sources/AnglesiteCore/WebmentionInboxD1Client.swift \
  Tests/AnglesiteCoreTests/WebmentionInboxD1ClientTests.swift
git commit -m "feat(#1597): bump @dwk/webmention, read vouch columns from D1"
```

---

### Task 7: `ReceivedInteraction.Vouch`

**Files:**
- Modify: `Sources/AnglesiteCore/ReceivedInteraction.swift`
- Test: `Tests/AnglesiteCoreTests/ReceivedInteractionTests.swift`

**Interfaces:**
- Consumes: nothing from Task 6 (this is the pure data-model type).
- Produces: `ReceivedInteraction.Vouch { url: URL; verified: Bool }`; `ReceivedInteraction.vouch: Vouch?`; `ReceivedInteraction.init(...)` gains a defaulted trailing parameter `vouch: Vouch? = nil` (all 13 existing call sites keep compiling unchanged).

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/ReceivedInteractionTests.swift`, after `jsonRoundTrip`:

```swift
    @Test("round-trips a vouch through JSON encoding")
    func vouchRoundTrips() throws {
        let interaction = try ReceivedInteraction(
            id: "wm-abc123",
            type: .webmention,
            source: URL(string: "https://other.example/post/42")!,
            target: URL(string: "https://my.site/articles/hello-world")!,
            interactionType: .reply,
            author: nil,
            content: "Great post!",
            published: ISO8601DateFormatter().date(from: "2026-06-28T14:30:00Z")!,
            verified: ISO8601DateFormatter().date(from: "2026-06-28T14:35:12Z")!,
            verificationStatus: .verified,
            vouch: ReceivedInteraction.Vouch(url: URL(string: "https://trusted.example/")!, verified: true)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(interaction)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReceivedInteraction.self, from: data)
        #expect(decoded == interaction)
        #expect(decoded.vouch?.verified == true)
    }

    @Test("vouch defaults to nil when not supplied")
    func vouchDefaultsToNil() throws {
        let interaction = try ReceivedInteraction(
            id: "wm-no-vouch",
            type: .webmention,
            source: URL(string: "https://other.example/post/42")!,
            target: URL(string: "https://my.site/articles/hello-world")!,
            interactionType: .mention,
            author: nil,
            content: nil,
            published: Date(),
            verified: Date(),
            verificationStatus: .verified
        )
        #expect(interaction.vouch == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter ReceivedInteractionTests`
Expected: FAIL to compile — no `Vouch` type, no `vouch` parameter/property.

- [ ] **Step 3: Implement**

In `Sources/AnglesiteCore/ReceivedInteraction.swift`, add the nested type after `Author`:

```swift
    /// A Vouch (indieweb.org/Vouch): the sender-supplied URL and whether the Worker confirmed it
    /// links to this mention's target domain — an additional inbound-trust signal beyond ordinary
    /// source→target link verification. A vouch that was sent but did NOT check out is still
    /// represented here (`verified: false`), not collapsed into "no vouch" — see the type-level
    /// design doc for why.
    public struct Vouch: Codable, Sendable, Equatable {
        /// The URL the sender supplied as their vouch.
        public let url: URL
        /// Whether `url` was confirmed to link to the target's domain.
        public let verified: Bool

        /// Creates a vouch outcome.
        public init(url: URL, verified: Bool) {
            self.url = url
            self.verified = verified
        }
    }
```

Add the stored property (after `verificationStatus`):

```swift
    /// Current verification state of the interaction.
    public let verificationStatus: VerificationStatus
    /// The sender's Vouch outcome, when a vouch was supplied; `nil` when none was.
    public let vouch: Vouch?
```

Update the initializer to accept it with a default:

```swift
    public init(
        id: String,
        type: ProtocolType,
        source: URL,
        target: URL,
        interactionType: InteractionType,
        author: Author?,
        content: String?,
        published: Date,
        verified: Date,
        verificationStatus: VerificationStatus,
        vouch: Vouch? = nil
    ) throws {
        guard id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ValidationError.invalidID(id)
        }
        self.id = id
        self.type = type
        self.source = source
        self.target = target
        self.interactionType = interactionType
        self.author = author
        self.content = content
        self.published = published
        self.verified = verified
        self.verificationStatus = verificationStatus
        self.vouch = vouch
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter ReceivedInteractionTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ReceivedInteraction.swift Tests/AnglesiteCoreTests/ReceivedInteractionTests.swift
git commit -m "feat(#1597): add ReceivedInteraction.Vouch"
```

---

### Task 8: map vouch through `ReceivedInteractionSync`

**Files:**
- Modify: `Sources/AnglesiteCore/ReceivedInteractionSync.swift`
- Test: `Tests/AnglesiteCoreTests/ReceivedInteractionSyncTests.swift`

**Interfaces:**
- Consumes: `WebmentionInboxD1Client.Mention.vouchURL`/`.vouchVerified` (Task 6), `ReceivedInteraction.Vouch`/`.vouch` (Task 7).
- Produces: `ReceivedInteractionSync.makeInteraction(from:)` populates `.vouch` from the mention's vouch columns.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/ReceivedInteractionSyncTests.swift`, after `makeInteractionDefaultsLegacyMention`:

```swift
    @Test("makeInteraction maps a vouched mention")
    func makeInteractionMapsVouchedMention() throws {
        let mention = WebmentionInboxD1Client.Mention(
            id: "wm-abc123", source: "https://alice.example/post", target: "https://me.example/blog/hi",
            verifiedAt: 1_753_300_000_000, interactionType: "reply", authorName: "Alice",
            authorURL: "https://alice.example", authorPhoto: "https://alice.example/photo.jpg",
            content: "Great post!", publishedAt: 1_753_299_000_000,
            vouchURL: "https://trusted.example/", vouchVerified: true)

        let interaction = try #require(ReceivedInteractionSync.makeInteraction(from: mention))
        #expect(interaction.vouch?.url.absoluteString == "https://trusted.example/")
        #expect(interaction.vouch?.verified == true)
    }

    @Test("makeInteraction maps a failed vouch attempt distinctly from no vouch")
    func makeInteractionMapsFailedVouch() throws {
        let mention = WebmentionInboxD1Client.Mention(
            id: "wm-fail", source: "https://alice.example/post", target: "https://me.example/blog/hi",
            verifiedAt: 1_753_300_000_000, interactionType: "reply", authorName: nil,
            authorURL: nil, authorPhoto: nil, content: nil, publishedAt: nil,
            vouchURL: "https://untrusted.example/", vouchVerified: false)

        let interaction = try #require(ReceivedInteractionSync.makeInteraction(from: mention))
        #expect(interaction.vouch?.url.absoluteString == "https://untrusted.example/")
        #expect(interaction.vouch?.verified == false)
    }

    @Test("makeInteraction has no vouch when the mention carries none")
    func makeInteractionHasNoVouchWhenAbsent() throws {
        let mention = WebmentionInboxD1Client.Mention(
            id: "wm-def456", source: "https://bob.example/post", target: "https://me.example/blog/hi",
            verifiedAt: 1_753_300_000_000, interactionType: nil, authorName: nil,
            authorURL: nil, authorPhoto: nil, content: nil, publishedAt: nil)

        let interaction = try #require(ReceivedInteractionSync.makeInteraction(from: mention))
        #expect(interaction.vouch == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter ReceivedInteractionSyncTests`
Expected: FAIL — `interaction.vouch` is always `nil` (not wired up yet).

- [ ] **Step 3: Implement**

In `Sources/AnglesiteCore/ReceivedInteractionSync.swift`, extend `makeInteraction(from:)`:

```swift
    static func makeInteraction(from mention: WebmentionInboxD1Client.Mention) -> ReceivedInteraction? {
        guard let source = URL(string: mention.source), let target = URL(string: mention.target) else { return nil }
        let interactionType = mention.interactionType.flatMap(ReceivedInteraction.InteractionType.init(rawValue:)) ?? .mention
        let author: ReceivedInteraction.Author? =
            (mention.authorName != nil || mention.authorURL != nil || mention.authorPhoto != nil)
            ? .init(
                name: mention.authorName,
                url: mention.authorURL.flatMap(URL.init(string:)),
                photo: mention.authorPhoto.flatMap(URL.init(string:)))
            : nil
        // A vouch requires both the URL and the verified flag from the row — if either is missing
        // (no vouch was sent, or a malformed vouchURL somehow made it through), there is no vouch.
        let vouch: ReceivedInteraction.Vouch? = {
            guard let vouchURLString = mention.vouchURL, let vouchVerified = mention.vouchVerified,
                  let vouchURL = URL(string: vouchURLString)
            else { return nil }
            return ReceivedInteraction.Vouch(url: vouchURL, verified: vouchVerified)
        }()
        let verifiedAt = Double(mention.verifiedAt) / 1000
        let publishedAt = Double(mention.publishedAt ?? mention.verifiedAt) / 1000
        return try? ReceivedInteraction(
            id: mention.id, type: .webmention, source: source, target: target,
            interactionType: interactionType, author: author, content: mention.content,
            published: Date(timeIntervalSince1970: publishedAt),
            verified: Date(timeIntervalSince1970: verifiedAt), verificationStatus: .verified,
            vouch: vouch)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter ReceivedInteractionSyncTests`
Expected: PASS

- [ ] **Step 5: Run the full Swift suite and commit**

```bash
swift test --package-path .
git add Sources/AnglesiteCore/ReceivedInteractionSync.swift Tests/AnglesiteCoreTests/ReceivedInteractionSyncTests.swift
git commit -m "feat(#1597): map vouch outcome into ReceivedInteraction"
```

---

### Task 9: `interactions.ts` Zod schema

**Files:**
- Modify: `Resources/Template/src/lib/interactions.ts`
- Test: `Resources/Template/src/lib/interactions.test.ts`

**Interfaces:**
- Consumes: `httpUrl` (already defined in this file).
- Produces: `ReceivedInteraction.vouch?: { url: string; verified: boolean }` (the TS type, inferred from the Zod schema — same name as the Swift type, different language/file).

- [ ] **Step 1: Write the failing tests**

Add to `Resources/Template/src/lib/interactions.test.ts`, after the "author and content are optional" test:

```ts
test("vouch is optional and round-trips when present", () => {
  const all = parseInteractions(mods(raw({ vouch: { url: "https://trusted.example/", verified: true } })));
  assert.equal(all.length, 1);
  assert.deepEqual(all[0].vouch, { url: "https://trusted.example/", verified: true });
});

test("a failed vouch attempt round-trips distinctly from no vouch", () => {
  const all = parseInteractions(mods(raw({ vouch: { url: "https://untrusted.example/", verified: false } })));
  assert.equal(all[0].vouch?.verified, false);
});

test("vouch is undefined when absent", () => {
  const all = parseInteractions(mods(raw()));
  assert.equal(all[0].vouch, undefined);
});

test("rejects a non-http(s) vouch.url", () => {
  const warnings: string[] = [];
  const origWarn = console.warn;
  console.warn = (...args: unknown[]) => warnings.push(args.join(" "));
  try {
    const all = parseInteractions(
      mods(raw({ vouch: { url: "javascript:alert(1)", verified: true } })),
    );
    assert.equal(all.length, 0);
    assert.equal(warnings.length, 1);
  } finally {
    console.warn = origWarn;
  }
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test src/lib/interactions.test.ts`
Expected: FAIL — `vouch` is an unrecognized key that Zod silently strips (so `all[0].vouch` is `undefined` even in the "present" case) or, depending on the exact zod version's default object mode, is stripped without error either way the assertion on the round-tripped value fails.

- [ ] **Step 3: Implement**

In `Resources/Template/src/lib/interactions.ts`, add to `interactionSchema` (after `verificationStatus`):

```ts
  verificationStatus: z.enum(["verified", "pending", "failed"]),
  /**
   * The sender's Vouch outcome (indieweb.org/Vouch), when a vouch was supplied and the mention
   * verified. `verified: false` means a vouch was attempted but didn't check out — distinct from
   * no vouch at all, and worth surfacing since a failed vouch is a stronger spam signal than
   * silence.
   */
  vouch: z
    .object({
      url: httpUrl,
      verified: z.boolean(),
    })
    .optional(),
});
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test src/lib/interactions.test.ts`
Expected: PASS

- [ ] **Step 5: Run the full template test suite and commit**

```bash
cd Resources/Template
npm run test:scripts
cd ../..
git add Resources/Template/src/lib/interactions.ts Resources/Template/src/lib/interactions.test.ts
git commit -m "feat(#1597): add vouch to the received-interaction schema"
```

---

### Task 10: render the trust badge in `Interactions.astro`, final verification, PR

**Files:**
- Modify: `Resources/Template/src/components/Interactions.astro`

**Interfaces:**
- Consumes: `ReceivedInteraction.vouch` (Task 9's Zod type).

- [ ] **Step 1: Add the badge to comments**

In `Resources/Template/src/components/Interactions.astro`, inside the comments `<li>` template, add the badge right after the author byline and before the `dt-published` link:

```astro
                <div class="comment-body">
                  <p class="comment-meta">
                    {c.author?.url ? (
                      <a class="u-author h-card" href={c.author.url} rel="nofollow ugc">
                        {c.author?.name ?? new URL(c.author.url).hostname}
                      </a>
                    ) : (
                      <span class="u-author h-card">{c.author?.name ?? new URL(c.source).hostname}</span>
                    )}
                    {c.vouch && (
                      <span class={`trust-badge ${c.vouch.verified ? "trust-vouched" : "trust-unverified"}`}>
                        {c.vouch.verified ? "Vouched" : "Unverified vouch"}
                      </span>
                    )}
                    <a class="u-url" href={c.source} rel="nofollow ugc">
                      <time class="dt-published" datetime={c.published}>
                        {human(c.published)}
                      </time>
                    </a>
                  </p>
                  {c.content && <p class="p-content">{c.content}</p>}
                </div>
```

- [ ] **Step 2: Add the badge to the "Mentioned by" list**

Change the mentions block to:

```astro
      {g.mentions.length > 0 && (
        <p class="mentions">
          Mentioned by{" "}
          {g.mentions.map((m, index) => (
            <>
              <a class="h-cite" href={m.source} rel="nofollow ugc">
                {m.author?.name ?? new URL(m.source).hostname}
              </a>
              {m.vouch && (
                <span class={`trust-badge ${m.vouch.verified ? "trust-vouched" : "trust-unverified"}`}>
                  {m.vouch.verified ? "Vouched" : "Unverified vouch"}
                </span>
              )}
              {index < g.mentions.length - 1 ? ", " : ""}
            </>
          ))}
        </p>
      )}
```

- [ ] **Step 3: Add the badge styles**

In the `<style>` block, after `.mentions`:

```css
  .trust-badge {
    display: inline-block;
    margin-left: 0.4rem;
    padding: 0.05rem 0.5rem;
    border-radius: 999px;
    font-size: 0.75rem;
    font-weight: 600;
    vertical-align: middle;
  }
  .trust-vouched {
    background: var(--color-success-surface, #dcfce7);
    color: var(--color-success-text, #166534);
  }
  .trust-unverified {
    background: var(--color-warning-surface, #fef3c7);
    color: var(--color-warning-text, #92400e);
  }
```

- [ ] **Step 4: Manually verify the render in a browser**

Astro components using `import.meta.glob` aren't unit-testable directly (per the existing `interactions.test.ts` design — pure logic lives in `interactions.ts`, glob lives in the `.astro` file), so this needs a real build. In a scratch site or the template's own dev checkout:

1. Create three fixture files under `data/interactions/` in a test site (or temporarily in `Resources/Template/data/interactions/` if that directory is used for local preview — check first with `ls Resources/Template/data/interactions/`):
   - one with `vouch: { url: "https://trusted.example/", verified: true }` targeting a real page on the site,
   - one with `vouch: { url: "https://untrusted.example/", verified: false }`,
   - one with no `vouch` key at all.
2. Run `npm run dev` from `Resources/Template/` (or the equivalent scaffolded site) and open the page whose canonical URL matches those fixtures' `target`.
3. Confirm: the vouched one shows a green "Vouched" badge, the failed one shows an amber "Unverified vouch" badge, the plain one shows no badge, and existing (no-vouch) interaction rendering is visually unchanged.
4. Remove any fixture files you added that aren't meant to be committed.

- [ ] **Step 5: Run `astro check` and the full test suites**

```bash
cd Resources/Template
npx astro check
npm run test:scripts
cd ../..
swift test --package-path .
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/src/components/Interactions.astro
git commit -m "feat(#1597): render vouch trust badge on received interactions"
```

- [ ] **Step 7: Push and open the PR**

Confirm with the user before pushing/opening the PR (per the standing safety rules on pushing code and creating PRs — the design being pre-approved doesn't cover this step).

```bash
git push -u origin claude/issue-1597-567179
```

Open the PR using `.github/PULL_REQUEST_TEMPLATE.md`'s exact headings (Summary, Paired PR check, Test plan — see `CONTRIBUTING.md` ▸ "Commits and pull requests"). The **Paired PR check** section should note the sidecar PR (`davidwkeith/workers`, Task 5) that shipped first. Body includes `Closes #1597`.

---

## Self-Review Notes

- **Spec coverage:** every section of the design doc maps to a task — `WebmentionJob.vouch`/receive parsing (Task 1), D1 storage (Task 2), `verifyVouch` + log event (Task 3), queue-consumer wiring (Task 4), release (Task 5), D1 client (Task 6), Swift model (Task 7), sync mapping (Task 8), Zod schema (Task 9), Astro render + manual verification (Task 10). The "no moderation queue" non-goal has no task, correctly — it's an explicit absence, not a deliverable.
- **Placeholder scan:** no TBD/TODO steps. Task 6 explicitly explains why a third "legacy row" test isn't needed (the existing `decodesLegacyRowsWithNullEnrichmentColumns` test already covers it) rather than silently omitting coverage.
- **Type consistency:** `VouchResult { verified: boolean }` (Task 3) → consumed by the queue consumer (Task 4) → stored as `VerifiedMention.vouch: { url, verified }` (Task 2) → read as `Mention.vouchURL`/`.vouchVerified` (Task 6) → mapped to `ReceivedInteraction.Vouch { url: URL, verified: Bool }` (Task 7/8) → Zod `vouch: { url: httpUrl, verified: z.boolean() }` (Task 9) → rendered via `c.vouch`/`m.vouch` (Task 10). Names match at every hop.

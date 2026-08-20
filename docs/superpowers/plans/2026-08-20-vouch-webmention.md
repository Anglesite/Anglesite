# Vouch protocol for webmention spam mitigation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add IndieWeb [Vouch](https://indieweb.org/Vouch) support to inbound Webmentions — an optional sender-supplied URL that, when it also links to the target's domain, is recorded as a trust signal and rendered on the received interaction.

**Architecture:** The fetch/verify pipeline lives in `@dwk/webmention` (sidecar repo `davidwkeith/workers`); Anglesite only composes it. Vouch verification is added to that package the same way RSVP support was: an optional field on the queue job → a new `verifyVouch` check (twin of `verifySource`) → an additive D1 column → surfaced in `VerifiedMention`. Anglesite then threads the new field through its D1 reader, Swift model, Zod schema, and Astro render — no new moderation queue, no change to the existing hard verification gate.

**Tech Stack:** TypeScript (Cloudflare Workers, vitest + `@cloudflare/vitest-pool-workers`) for the sidecar package; Swift 6.4 (`AnglesiteCore`, Swift Testing) + Astro/Zod (`node:test`) for the app.

Full design: [`docs/superpowers/specs/2026-08-20-vouch-webmention-design.md`](../specs/2026-08-20-vouch-webmention-design.md).

**Status (2026-08-20): Tasks 1–5 (the sidecar half) are done and merged —
[davidwkeith/workers#505](https://github.com/davidwkeith/workers/pull/505).** Do not re-run
Task 1's worktree-creation step or re-open a PR for that work. **However, PR review on the
Anglesite side (#1604) found the shipped `verifyVouch` semantics are inverted from the actual
protocol — see the design spec's "Known issue" section before touching Task 6 or later.** A
correctness fix to the already-merged sidecar code is pending a decision on trust-list scope.

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
- Create worktree: `<davidwkeith/workers checkout>/.claude/worktrees/vouch-1597/` on a new branch `feat/vouch-webmention` based on `origin/main` — `davidwkeith/workers` isn't one of the two repos `AGENTS.md`'s `ANGLESITE_SIDECAR_SRC` convention covers, so there's no established env var for it; substitute wherever it's actually cloned (e.g. a sibling of this repo under the same `github.com/` root).
- Modify: `packages/webmention/src/index.ts` (`WebmentionJob` interface, `createWebmention`)
- Test: `packages/webmention/src/index.test.ts`

**Interfaces:**
- Produces: `WebmentionJob.vouch?: string` (raw form value, already validated as a syntactically valid `http(s)` URL — or absent).

- [x] **Step 1: Create the worktree**

```bash
cd <davidwkeith/workers checkout>
git fetch origin main
git worktree add .claude/worktrees/vouch-1597 -b feat/vouch-webmention origin/main
cd .claude/worktrees/vouch-1597
pnpm install
pnpm build
```

- [x] **Step 2: Write the failing tests**

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

- [x] **Step 3: Run the tests to verify they fail**

Run: `pnpm test --project @dwk/webmention -- -t "vouch"`
Expected: FAIL — `sent[0]` has no `vouch` key yet (the job is still just `{ source, target }`).

- [x] **Step 4: Implement**

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

- [x] **Step 5: Run the tests to verify they pass**

Run: `pnpm test --project @dwk/webmention -- -t "vouch"`
Expected: PASS

- [x] **Step 6: Run the full package gate and commit**

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

- [x] **Step 1: Write the failing tests**

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

- [x] **Step 2: Run the tests to verify they fail**

Run: `pnpm test --project @dwk/webmention -- -t "vouch"`
Expected: FAIL — `vouch` is not a recognized field on `VerifiedMention`/not persisted.

- [x] **Step 3: Implement**

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

**Note (raised in review):** `ON CONFLICT DO UPDATE` unconditionally overwrites `vouch_url`/
`vouch_verified` with `excluded.*` — a re-sent webmention for the same `(source, target)` that
arrives *without* a vouch will wipe a previously-verified one, and the badge silently
disappears on a resend. This matches how the existing `rsvp`/enrichment columns already behave
(same unconditional overwrite), so it's consistent with precedent, not a new gap — but it means
`vouch` (like `rsvp`, `interactionType`, `author`, `content`) is a property of the *latest
delivery*, not a permanent property of the mention. Documented here rather than changed:
switching to `COALESCE(excluded.vouch_url, ${table}.vouch_url)` (sticky-until-explicitly-
cleared) would be a real behavior change affecting every existing column this way, not just
vouch, and is out of scope for this plan.

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

- [x] **Step 4: Run the tests to verify they pass**

Run: `pnpm test --project @dwk/webmention -- -t "vouch"`
Expected: PASS

- [x] **Step 5: Run the full package gate and commit**

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

- [x] **Step 1: Write the failing tests**

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

- [x] **Step 2: Run the tests to verify they fail**

Run: `pnpm test --project @dwk/webmention -- -t "verifyVouch"`
Expected: FAIL — `verifyVouch` is not exported.

- [x] **Step 3: Implement**

In `packages/webmention/src/log.ts`, add a new event (after `VerifyFetchFailed`):

```ts
  /** Vouch verification finished (every exit path, not just the success path). Fields: `verified`, `reason`. */
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
```

> **This function's target-matching semantics are under revision — see the design spec's
> "Known issue" section.** The code below still shows the original (buggy) hostname-matching
> logic pending that decision; the logging fix (emitting `VouchVerified` on every exit path,
> not just the one that reaches the link check) applies regardless of which URL ends up being
> matched, so it's written correctly below. Do not implement this task from the plan text alone
> until the design spec's "Known issue" section shows a resolved status.

Every early return below previously skipped the `VouchVerified` log/metric entirely — so the
counter only ever fired for "page fetched fine, checked its links," and every other failure
mode (SSRF block, fetch throw, non-2xx, wrong content type, oversized body) was invisible,
making it impossible to tell "vouches are failing" from "nobody sends vouches" from the logs.
Fix: a single exit point that always emits `VouchVerified` with a `reason` field:

```typescript
export async function verifyVouch(
  vouchUrl: string,
  target: string,
  options?: VerifyOptions,
): Promise<VouchResult> {
  const doFetch: FetchLike =
    options?.fetch ?? ((input, init) => fetch(input, init));
  const logger = options?.logger ?? noopLogger;
  const metrics = options?.metrics ?? noopMetrics;

  const record = (
    verified: boolean,
    reason:
      | "ok"
      | "invalid-target"
      | "fetch-failed"
      | "not-ok"
      | "not-html"
      | "body-unreadable",
  ): VouchResult => {
    const fields = {
      vouchHost: hostFromUrl(vouchUrl),
      targetHost: hostFromUrl(target),
      verified,
      reason,
    };
    logger.info(WebmentionLogEvent.VouchVerified, fields);
    metrics.count(WebmentionLogEvent.VouchVerified, fields);
    return { verified };
  };

  let targetHost: string;
  try {
    targetHost = new URL(target).hostname.toLowerCase();
  } catch {
    return record(false, "invalid-target");
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
    return record(false, "fetch-failed");
  }

  if (!response.ok) {
    return record(false, "not-ok");
  }

  const contentType = response.headers.get("content-type") ?? "";
  if (!isHtmlContentType(contentType)) {
    return record(false, "not-html");
  }

  const body = await readBodyCapped(response);
  if (body === null) {
    return record(false, "body-unreadable");
  }

  const links = await extractLinks(body, base);
  const verified = links.some((link) => {
    try {
      return new URL(link).hostname.toLowerCase() === targetHost;
    } catch {
      return false;
    }
  });

  return record(verified, "ok");
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

- [x] **Step 4: Run the tests to verify they pass**

Run: `pnpm test --project @dwk/webmention -- -t "verifyVouch"`
Expected: PASS

- [x] **Step 5: Run the full package gate and commit**

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

- [x] **Step 1: Write the failing tests**

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

- [x] **Step 2: Run the tests to verify they fail**

Run: `pnpm test --project @dwk/webmention -- -t "vouch"`
Expected: FAIL — the consumer never calls `verifyVouch` yet, so `stored?.vouch` is always `undefined` and the "never fetches" test's premise doesn't yet distinguish behavior.

- [x] **Step 3: Implement**

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

- [x] **Step 4: Run the tests to verify they pass**

Run: `pnpm test --project @dwk/webmention -- -t "vouch"`
Expected: PASS

- [x] **Step 5: Run the full package gate and commit**

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

- [x] **Step 1: Add the changeset**

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

- [x] **Step 2: Bump the package version**

Edit `packages/webmention/package.json`, changing `"version": "1.0.0-beta.1"` to `"version": "1.0.0-beta.2"`.

- [x] **Step 3: Run the full repo gate**

```bash
pnpm lint && pnpm format:check && pnpm typecheck && pnpm build && pnpm test
```

Expected: all green. Fix any failure before proceeding — do not skip a failing check.

- [x] **Step 4: Commit, push, open the PR**

```bash
git add .changeset/webmention-vouch.md packages/webmention/package.json
git commit -m "feat(webmention): bump to 1.0.0-beta.2 for vouch support"
git push -u origin feat/vouch-webmention
```

Confirm with the user before running `gh pr create` (pushing/opening a PR needs explicit confirmation per the standing safety rules — do not skip this even though the design was pre-approved). Once confirmed, open the PR against `davidwkeith/workers` main with a summary of the vouch feature and `part of Anglesite/Anglesite#1597` in the body (no closing keyword — see Global Constraints).

**Status: done.** [davidwkeith/workers#505](https://github.com/davidwkeith/workers/pull/505)
was opened, reviewed, and merged. One review finding required a follow-up commit: the manual
`package.json` version bump in Step 2 above conflicts with `RELEASING.md`'s documented flow
(version bumps come only from a dedicated `pnpm changeset version` run) — it was reverted back
to `1.0.0-beta.1`, keeping the changeset file for that step to consume normally. **This means
the actual next `@dwk/webmention` version is whatever the sidecar's real release run produces —
not `1.0.0-beta.2`** as Step 2 above still literally says; treat that version number as
illustrative, not exact.

**Do not proceed to Task 6 until a tagged `@dwk/webmention` release containing this PR's commits
is published to npm** — Task 6 bumps Anglesite's dependency on that exact published version.
Check with `npm view @dwk/webmention versions --json` and cross-reference against
[davidwkeith/workers#505](https://github.com/davidwkeith/workers/pull/505)'s merge commit to
confirm the vouch commits are actually included in whatever version comes back.

---

## App side (Anglesite/Anglesite)

### Task 6: bump `@dwk/webmention` and extend `WebmentionInboxD1Client`

**Files:**
- Modify: `Resources/Template/package.json`
- Modify: `Sources/AnglesiteCore/WebmentionInboxD1Client.swift`
- Test: `Tests/AnglesiteCoreTests/WebmentionInboxD1ClientTests.swift`

**Interfaces:**
- Produces: `WebmentionInboxD1Client.Mention.vouchURL: String?`, `.vouchVerified: Bool?`, via a new explicit `init` (defaulting both to `nil`) — see Step 4 for why a stored-property default alone doesn't work here. All 13 existing call sites keep compiling unchanged.

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

    @Test("falls back to the legacy column set when the site's worker hasn't migrated the vouch columns yet")
    func fallsBackWhenVouchColumnsAreMissing() async throws {
        let missingColumnBody = Data("""
        {"success": false, "errors": [{"code": 7500, "message": "D1_ERROR: no such column: vouch_url: SQLITE_ERROR"}]}
        """.utf8)
        let legacyBody = Data("""
        {"success": true, "result": [{"success": true, "results": [
            {"id": "wm-abc123", "source": "https://alice.example/post", "target": "https://me.example/blog/hi",
             "verified_at": 1753300000000, "interaction_type": "reply", "author_name": "Alice",
             "author_url": "https://alice.example", "author_photo": "https://alice.example/photo.jpg",
             "content": "Great post!", "published_at": 1753299000000}
        ]}]}
        """.utf8)

        let attempts = ActorBox<Int>(0)
        let client = WebmentionInboxD1Client(
            accountID: "acct1", databaseID: "db1", apiToken: "token",
            transport: { _ in
                let n = await attempts.get()
                await attempts.set(n + 1)
                return n == 0 ? (missingColumnBody, Self.response(200)) : (legacyBody, Self.response(200))
            })

        let mentions = try await client.listVerifiedMentions()
        let mention = try #require(mentions.first)
        #expect(mention.id == "wm-abc123")
        #expect(mention.vouchURL == nil)
        #expect(mention.vouchVerified == nil)
        #expect(await attempts.get() == 2)
    }

    @Test("still throws when the D1 failure is unrelated to a missing column")
    func doesNotFallBackOnUnrelatedError() async throws {
        let body = Data("""
        {"success": false, "errors": [{"code": 7500, "message": "D1_ERROR: database is locked"}]}
        """.utf8)
        let client = WebmentionInboxD1Client(
            accountID: "acct1", databaseID: "db1", apiToken: "token",
            transport: { _ in (body, Self.response(200)) })

        await #expect(throws: CloudflareError.api(message: "D1_ERROR: database is locked")) {
            _ = try await client.listVerifiedMentions()
        }
    }

```

`fallsBackWhenVouchColumnsAreMissing` reuses the `ActorBox` helper already defined at the
bottom of this test file (used by `WebmentionInboxD1ClientTests`'s
`sendsPostToD1QueryEndpoint` test) as a simple mutable counter — no new helper needed.

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

In `Sources/AnglesiteCore/WebmentionInboxD1Client.swift`, extend `Mention`.

**Important:** a `let` stored property *with* a default value (`= nil`) is excluded from
Swift's synthesized memberwise initializer — it's already considered initialized and the
compiler drops it from the generated `init` entirely. Giving the two new properties `= nil`
at their declaration would silently make them permanently `nil`: `Mention`'s memberwise init
would gain no `vouchURL:`/`vouchVerified:` parameters at all, so the mapping code below
wouldn't compile (extra-argument error), and if it were adjusted to compile some other way,
`mention.vouchURL` would never be anything but `nil`. The fix is an **explicit `init`** with
the two new parameters defaulted — the same pattern `ReceivedInteraction.Author` (Task 7's
`ReceivedInteraction.swift`) already uses for its own optional fields:

```swift
        public let publishedAt: Int?
        /// The sender's Vouch URL (indieweb.org/Vouch), when supplied and the mention verified.
        /// `nil` when no vouch was sent, or the row predates vouch support upstream.
        public let vouchURL: String?
        /// Whether `vouchURL` was confirmed to link to this mention's target domain. `nil` exactly
        /// when `vouchURL` is `nil`; otherwise `true`/`false` — a failed vouch attempt is still
        /// recorded (not collapsed into "no vouch"), since it's a stronger spam signal than silence.
        public let vouchVerified: Bool?

        /// Creates a mention row. `vouchURL`/`vouchVerified` default to `nil` so every existing
        /// call site (production and test) that predates vouch support keeps compiling unchanged.
        init(
            id: String, source: String, target: String, verifiedAt: Int,
            interactionType: String?, authorName: String?, authorURL: String?, authorPhoto: String?,
            content: String?, publishedAt: Int?,
            vouchURL: String? = nil, vouchVerified: Bool? = nil
        ) {
            self.id = id
            self.source = source
            self.target = target
            self.verifiedAt = verifiedAt
            self.interactionType = interactionType
            self.authorName = authorName
            self.authorURL = authorURL
            self.authorPhoto = authorPhoto
            self.content = content
            self.publishedAt = publishedAt
            self.vouchURL = vouchURL
            self.vouchVerified = vouchVerified
        }
    }
```

This gives `Mention` an explicit `init` for the first time — it previously relied on the
synthesized memberwise one. All 13 existing call sites across the codebase (production and
tests) omit `vouchURL`/`vouchVerified` and keep compiling unchanged via the new init's
defaults, exactly as intended — verify this by running the full `WebmentionInboxD1ClientTests`
and `ReceivedInteractionSyncTests` suites in Step 5, not just the new vouch-specific tests.

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

Add a second, legacy SQL constant, and extend `Envelope` to decode D1's error detail so a
"missing column" failure can be recognized (rather than only ever throwing a generic
`.malformedResponse`):

```swift
    private static let listVerifiedSQL = """
    SELECT id, source, target, verified_at, interaction_type, author_name, author_url, \
    author_photo, content, published_at, vouch_url, vouch_verified FROM webmentions ORDER BY verified_at DESC
    """

    /// Column set from before vouch support existed. Used as a fallback when a site's D1
    /// database hasn't been migrated yet — see `listVerifiedMentions()`'s deploy-ordering
    /// handling below.
    private static let listVerifiedSQLLegacy = """
    SELECT id, source, target, verified_at, interaction_type, author_name, author_url, \
    author_photo, content, published_at FROM webmentions ORDER BY verified_at DESC
    """
```

```swift
    private struct D1ErrorDetail: Decodable {
        let message: String
    }

    private struct Envelope: Decodable {
        let success: Bool
        let result: [QueryResult]?
        let errors: [D1ErrorDetail]?
    }
```

**Deploy-ordering hazard this closes:** `Resources/Template/package.json`'s `@dwk/webmention`
version bump (Step 1) only affects newly scaffolded or rebuilt sites — it does nothing to a
worker already running in someone's Cloudflare account. Until that site's owner redeploys, its
D1 database's `webmentions` table has no `vouch_url`/`vouch_verified` columns at all, and
`SELECT`ing them is a hard SQLite error (`no such column`), not a `NULL` — unlike the existing
"tolerates enrichment columns being entirely `NULL`" case, which only covers *values*, not
*missing columns*. Left unhandled, `listVerifiedMentions()` would throw on every call for an
un-redeployed site, and `ReceivedInteractionSync.pullAndCommit` already treats any thrown error
as "sync did nothing this time" (`guard let mentions = try? await client.listVerifiedMentions()
else { return 0 }`) — so **all** interaction syncing for that site would silently stop, not
just vouch data, until the owner happens to redeploy.

Fix: catch specifically a "no such column" failure and retry once with the legacy column set,
so an un-redeployed site keeps syncing everything except vouch data (degrading gracefully,
matching the intent of the existing NULL-tolerance note) rather than syncing nothing. Split the
existing request/decode logic out of `listVerifiedMentions()` into a private `queryMentions`
helper parameterized on which SQL/column set to use, and make `listVerifiedMentions()` itself
the two-attempt wrapper:

```swift
    public func listVerifiedMentions() async throws -> [Mention] {
        do {
            return try await queryMentions(sql: Self.listVerifiedSQL, includeVouch: true)
        } catch CloudflareError.api(let message)
        where message.localizedCaseInsensitiveContains("no such column") {
            return try await queryMentions(sql: Self.listVerifiedSQLLegacy, includeVouch: false)
        }
    }

    private func queryMentions(sql: String, includeVouch: Bool) async throws -> [Mention] {
        let url = URL(string: "\(baseURL)/accounts/\(accountID)/d1/database/\(databaseID)/query")
        guard let url else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(QueryBody(sql: sql))

        let (data, http) = try await transport(request)
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw CloudflareError.malformedResponse
        }
        guard envelope.success, let rows = envelope.result?.first?.results else {
            throw CloudflareError.api(message: envelope.errors?.first?.message ?? "unknown D1 error")
        }

        return rows.compactMap { row in
            guard let id = row.id else { return nil }
            return Mention(
                id: id, source: row.source, target: row.target, verifiedAt: row.verified_at,
                interactionType: row.interaction_type, authorName: row.author_name,
                authorURL: row.author_url, authorPhoto: row.author_photo, content: row.content,
                publishedAt: row.published_at,
                vouchURL: includeVouch ? row.vouch_url : nil,
                vouchVerified: includeVouch ? row.vouch_verified.map { $0 != 0 } : nil)
        }
    }
```

(`CloudflareError.api(message:)` already exists in `CloudflareReading.swift` — this reuses it
rather than adding a new error case.)

Also update the class-level doc comment's "tolerates the enrichment columns... being entirely
`NULL`" note to mention `vouch_url`/`vouch_verified` alongside the existing list, and add a
sentence noting that a *missing* vouch column (not just a null value) is handled separately by
the fallback above.

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

`warnings.length === 1` for a single rejected file matches this same test file's existing
convention — not a new assumption: the "skips malformed files with a warning instead of
throwing" test asserts `warnings.length === 3` for 3 bad files among 4 inputs, and "rejects
non-http(s) URL schemes on source/target/author fields" asserts `warnings.length === 4` for 4
bad inputs — both confirm `parseInteractions` logs exactly one warning per rejected file, never
more, in this codebase today.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test src/lib/interactions.test.ts`
Expected: FAIL — `interactionSchema` is a plain `z.object()` (Zod's default mode strips unknown
keys rather than rejecting them), so `vouch` is silently dropped: the "round-trips when present"
test's `assert.deepEqual(all[0].vouch, {...})` fails because `all[0].vouch` is `undefined`, and
the "rejects a non-http(s) vouch.url" test fails because the malformed `vouch.url` never reaches
validation at all (it's stripped, so the file parses as "valid" with `all.length === 1`, not
`0`).

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

**Two fixes from review, applied below:**
1. `--color-success-surface`/`--color-success-text`/`--color-warning-surface`/`--color-warning-text`
   don't exist anywhere in `Resources/Template/` — every one of them silently fell through to
   its hardcoded hex fallback. Those hexes are light-mode pastels, and the template *does*
   theme (`src/styles/global.css` has a `prefers-color-scheme: dark` block redefining
   `--color-surface`/`--color-text-muted`/etc.), so a dark-themed site would have rendered a
   bright mint/amber chip against a slate page. Fixed below by building the badge entirely out
   of tokens that already exist (`--color-primary`, `--color-surface`, `--color-text-muted`) —
   no `global.css` change needed.
2. An `Unverified vouch` badge is only reachable when a sender *bothered to send* a vouch that
   then failed — a spammer who omits the field entirely renders clean, so this badge would only
   ever land on an honest sender whose vouch page moved or errored, punishing exactly the wrong
   party. Fixed below by rendering a badge only for `verified === true`; a failed vouch is still
   stored (Task 2) for the owner to see in the raw data, just not rendered as a claim on the
   page. This is independent of the open Vouch-semantics question in the design spec (which
   affects what `verified: true` *means*, not whether a false one should be shown) — revisit
   once that's resolved.

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
                    {c.vouch?.verified && (
                      <span class="trust-badge" title="This sender named a page that links back to this post">Vouched</span>
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
              {m.vouch?.verified && (
                <span class="trust-badge" title="This sender named a page that links back to this post">Vouched</span>
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
    background: var(--color-surface, #f8fafc);
    color: var(--color-primary, #2563eb);
    border: 1px solid var(--color-primary, #2563eb);
  }
```

Every token here (`--color-surface`, `--color-primary`) is already defined under both `:root`
and the `prefers-color-scheme: dark` block in `src/styles/global.css`, so this badge follows
the site's theme automatically with no new tokens to add.

- [ ] **Step 4: Manually verify the render in a browser**

Astro components using `import.meta.glob` aren't unit-testable directly (per the existing `interactions.test.ts` design — pure logic lives in `interactions.ts`, glob lives in the `.astro` file), so this needs a real build. In a scratch site or the template's own dev checkout:

1. Create three fixture files under `data/interactions/` in a test site (or temporarily in `Resources/Template/data/interactions/` if that directory is used for local preview — check first with `ls Resources/Template/data/interactions/`):
   - one with `vouch: { url: "https://trusted.example/", verified: true }` targeting a real page on the site,
   - one with `vouch: { url: "https://untrusted.example/", verified: false }`,
   - one with no `vouch` key at all.
2. Run `npm run dev` from `Resources/Template/` (or the equivalent scaffolded site) and open the page whose canonical URL matches those fixtures' `target`.
3. Confirm: the vouched one shows the "Vouched" badge (using the site's `--color-primary`, so check it also looks right in dark mode — resize or toggle `prefers-color-scheme`), the failed one shows **no** badge (per Step 3's fix: a failed vouch is stored but not rendered as a claim), and the plain one is visually identical to interaction rendering before this task.
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

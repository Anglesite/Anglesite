# Vouch trust-list fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the Vouch verification shipped in [davidwkeith/workers#505](https://github.com/davidwkeith/workers/pull/505) — it checks the wrong domain (target instead of source) and has no trust list, making the "Vouched" signal trivially forgeable — and give it a real trust list sourced from the site's existing blogroll.

**Architecture:** Sidecar fix (new commit/PR on top of the already-merged #505): `verifyVouch` gains a required `isTrustedDomain` predicate, checked *before* any fetch, and matches the fetched vouch page against the **source's** hostname instead of the target's. `WebmentionConfig` gains an optional `isTrustedVouchDomain`, threaded through the queue consumer. App side: the trust list is the site's existing blogroll content collection, synced to the same `SOCIAL_KV` namespace `#1567` already provisions (new key `vouch:trusted-domains`) via a new Swift pair mirroring `ContactsAllowlistSync`/`ContactsAllowlistKVClient`, read at Worker request time by a new `worker/vouch-trust.ts` mirroring `reader-identity.ts`.

**Tech Stack:** TypeScript (Cloudflare Workers, vitest + `@cloudflare/vitest-pool-workers`) for the sidecar package; Swift 6.4 (`AnglesiteCore`, Swift Testing) for the app; the same `worker/*.ts` TypeScript for the Worker-side read.

Full design: [`docs/superpowers/specs/2026-08-20-vouch-webmention-design.md`](../specs/2026-08-20-vouch-webmention-design.md) — see "Bug found in review, and its fix."

## Global Constraints

- Sidecar repo (`davidwkeith/workers`): Node.js >= 22, pnpm 10 (`corepack enable`). Before any PR: `pnpm lint && pnpm format:check && pnpm typecheck && pnpm build && pnpm test` must pass.
- Sidecar: every behavior change needs a colocated test in the package's `src/*.test.ts`.
- **Do not manually bump `packages/webmention/package.json`'s version.** Confirmed the hard way on #505's review: version bumps come only from a dedicated `pnpm changeset version` release run per `RELEASING.md`, never hand-edited alongside feature work. Add a changeset only.
- **Do not put a GitHub closing keyword (`Closes #1597`) in the sidecar PR** — #1597 is an Anglesite issue; reference it as plain text (`part of Anglesite/Anglesite#1597`) instead.
- App repo (this one): macOS 27+ / Xcode 27+ (Swift 6.4). Run `swift test --package-path .` before opening the PR.
- App repo: `npm test` inside `Resources/Template/` (or the narrower `npm run test:scripts`) covers `worker/*.test.ts`.
- Conventional commits, subject <= 72 characters.
- Both repos: additive-only. No existing field, column, or exported signature changes shape without a caller-visible reason — `verifyVouch`'s signature *does* change here (a new required parameter), which is the one deliberate exception in this plan, since the function is not yet used by any released version (only the just-merged, not-yet-published #505).

---

## Sidecar: `@dwk/webmention` (davidwkeith/workers)

Base this work on `origin/main`, which now includes #505's merge commit (`461ef4e`). Do not build on the old `feat/vouch-webmention` branch — it's merged and its worktree (if still present at `.claude/worktrees/vouch-1597`) is stale; remove it if it still exists before starting (`git worktree remove` from the main checkout, after confirming it's not mid-use by another process).

### Task 1: Rewrite `verifyVouch` — trust list first, source-domain match, full logging

**Files:**
- Create worktree: `<davidwkeith/workers checkout>/.claude/worktrees/vouch-trust-fix/` on a new branch `fix/vouch-trust-list` based on `origin/main`
- Modify: `packages/webmention/src/verify.ts`
- Test: `packages/webmention/src/verify.test.ts`

**Interfaces:**
- Produces: `verifyVouch(vouchUrl: string, source: string, isTrustedDomain: (hostname: string) => boolean | Promise<boolean>, options?: VerifyOptions): Promise<VouchResult>`. `VouchResult` is unchanged (`{ readonly verified: boolean }`).

- [ ] **Step 1: Create the worktree**

```bash
cd <davidwkeith/workers checkout>
git fetch origin main
git worktree add .claude/worktrees/vouch-trust-fix -b fix/vouch-trust-list origin/main
cd .claude/worktrees/vouch-trust-fix
pnpm install
pnpm build
```

- [ ] **Step 2: Write the failing tests**

In `packages/webmention/src/verify.test.ts`, find the existing `describe("verifyVouch", ...)` block (it currently calls `verifyVouch(vouchUrl, target, { fetch: fetchImpl })` with a 3rd positional `options` argument and no trust predicate). Replace the whole block with:

```ts
describe("verifyVouch", () => {
  const vouchUrl = "https://vouches.example/for-me";
  const alwaysTrusted = () => true;
  const neverTrusted = () => false;

  it("is verified true when the vouch domain is trusted and the page links to the source's host", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response(`<a href="${source}">I trust this site</a>`, {
          headers: { "content-type": "text/html" },
        }),
    );
    expect(
      await verifyVouch(vouchUrl, source, alwaysTrusted, { fetch: fetchImpl }),
    ).toEqual({ verified: true });
  });

  it("is verified true for a link to a different path under the source's host", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response('<a href="https://blog.example/somewhere-else">x</a>', {
          headers: { "content-type": "text/html" },
        }),
    );
    expect(
      await verifyVouch(vouchUrl, source, alwaysTrusted, { fetch: fetchImpl }),
    ).toEqual({ verified: true });
  });

  it("is verified false when the vouch domain is not trusted, and never fetches", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new Error("must not be called");
    });
    expect(
      await verifyVouch(vouchUrl, source, neverTrusted, { fetch: fetchImpl }),
    ).toEqual({ verified: false });
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("is verified false when a trusted vouch page links elsewhere", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response('<a href="https://elsewhere.example/">x</a>', {
          headers: { "content-type": "text/html" },
        }),
    );
    expect(
      await verifyVouch(vouchUrl, source, alwaysTrusted, { fetch: fetchImpl }),
    ).toEqual({ verified: false });
  });

  it("is verified false for a 404 vouch page", async () => {
    const fetchImpl = vi.fn(async () => new Response("gone", { status: 404 }));
    expect(
      await verifyVouch(vouchUrl, source, alwaysTrusted, { fetch: fetchImpl }),
    ).toEqual({ verified: false });
  });

  it("is verified false when the fetch throws", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new Error("network");
    });
    expect(
      await verifyVouch(vouchUrl, source, alwaysTrusted, { fetch: fetchImpl }),
    ).toEqual({ verified: false });
  });

  it("is verified false for a non-HTML vouch page", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response(JSON.stringify({ ref: source }), {
          headers: { "content-type": "application/json" },
        }),
    );
    expect(
      await verifyVouch(vouchUrl, source, alwaysTrusted, { fetch: fetchImpl }),
    ).toEqual({ verified: false });
  });

  it("is verified false when isTrustedDomain itself throws", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new Error("must not be called");
    });
    const throwing = () => {
      throw new Error("KV read failed");
    };
    expect(
      await verifyVouch(vouchUrl, source, throwing, { fetch: fetchImpl }),
    ).toEqual({ verified: false });
    expect(fetchImpl).not.toHaveBeenCalled();
  });
});
```

Note this test file already declares `const source = "https://blog.example/post";` and
`const target = "https://example.com/article";` near the top (shared across the file's other
`describe` blocks) — reuse the existing `source` constant, don't redeclare it.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `pnpm test --project @dwk/webmention -- -t "verifyVouch"`
Expected: FAIL to compile — `verifyVouch` doesn't accept a 3rd `isTrustedDomain` argument yet (existing call sites pass an options object as the 3rd argument).

- [ ] **Step 4: Implement**

Replace the entire `verifyVouch` function in `packages/webmention/src/verify.ts` (it's the last
thing in the file, right after `verifySource`) with:

```ts
/** Outcome of fetching and checking a Vouch URL. */
export interface VouchResult {
  /** Whether the vouch domain was trusted and its page links to the source's hostname. */
  readonly verified: boolean;
}

/**
 * Check whether `vouchUrl` establishes a Vouch trust chain (indieweb.org/Vouch) for `source`:
 * the vouch URL's own domain must be one the receiver already trusts (`isTrustedDomain`), *and*
 * the vouch page — once fetched — must link anywhere under the **source's** hostname (not the
 * target's; per the spec, "the vouch ... contains a hyperlink to the domain used in source").
 *
 * The trust check runs first, before any network access: an untrusted vouch domain returns
 * `{ verified: false }` immediately, with no fetch at all — this also bounds the fetch
 * amplification an attacker-named vouch URL could otherwise cause (every verified mention would
 * otherwise trigger a second outbound fetch to a URL the sender picked). Only a trusted domain's
 * page is fetched, through the same SSRF-safe {@link safeFetch} wrapper {@link verifySource}
 * uses. Matching is **hostname** equality via {@link extractLinks}, not {@link sourceLinksTo}'s
 * exact-URL match — any link on the vouch page pointing anywhere under the source's host counts.
 * Only HTML vouch pages are scanned. `isTrustedDomain` throwing, a fetch failure, non-2xx status,
 * non-HTML response, or oversized/unreadable body all yield `{ verified: false }`; this function
 * never throws.
 */
export async function verifyVouch(
  vouchUrl: string,
  source: string,
  isTrustedDomain: (hostname: string) => boolean | Promise<boolean>,
  options?: VerifyOptions,
): Promise<VouchResult> {
  const doFetch: FetchLike =
    options?.fetch ?? ((input, init) => fetch(input, init));
  const logger = options?.logger ?? noopLogger;
  const metrics = options?.metrics ?? noopMetrics;

  const record = (
    verified: boolean,
    reason:
      | "untrusted-domain"
      | "trust-check-failed"
      | "invalid-vouch-url"
      | "invalid-source"
      | "fetch-failed"
      | "not-ok"
      | "not-html"
      | "body-unreadable"
      | "ok",
  ): VouchResult => {
    const fields = {
      vouchHost: hostFromUrl(vouchUrl),
      sourceHost: hostFromUrl(source),
      verified,
      reason,
    };
    logger.info(WebmentionLogEvent.VouchVerified, fields);
    metrics.count(WebmentionLogEvent.VouchVerified, fields);
    return { verified };
  };

  let vouchHost: string;
  try {
    vouchHost = new URL(vouchUrl).hostname.toLowerCase();
  } catch {
    return record(false, "invalid-vouch-url");
  }

  let sourceHost: string;
  try {
    sourceHost = new URL(source).hostname.toLowerCase();
  } catch {
    return record(false, "invalid-source");
  }

  let trusted: boolean;
  try {
    trusted = await isTrustedDomain(vouchHost);
  } catch {
    return record(false, "trust-check-failed");
  }
  if (!trusted) {
    return record(false, "untrusted-domain");
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
      return new URL(link).hostname.toLowerCase() === sourceHost;
    } catch {
      return false;
    }
  });

  return record(verified, "ok");
}
```

In `packages/webmention/src/log.ts`, update the `VouchVerified` doc comment (it currently says
`Fields: verified`):

```ts
  /** Vouch verification finished (every exit path). Fields: `verified`, `reason`. */
  VouchVerified: "webmention.vouch.verified",
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pnpm test --project @dwk/webmention -- -t "verifyVouch"`
Expected: PASS

- [ ] **Step 6: Run the full package gate and commit**

```bash
pnpm --filter @dwk/webmention typecheck
pnpm --filter @dwk/webmention build
pnpm test --project @dwk/webmention
git add packages/webmention/src/verify.ts packages/webmention/src/verify.test.ts packages/webmention/src/log.ts
git commit -m "fix(webmention): vouch trust list, match source not target"
```

**Note:** `pnpm --filter @dwk/webmention typecheck`/`build` will fail after this step until Task 2 updates the one call site in `index.ts` — that's expected; Task 2 fixes it. If you want a green gate at every commit, do Task 1's and Task 2's implementation steps together before running the gate the first time; either way, land them as two separate commits per the steps above (they have independent test coverage and review value).

---

### Task 2: `WebmentionConfig.isTrustedVouchDomain` + queue consumer wiring

**Files:**
- Modify: `packages/webmention/src/index.ts`
- Test: `packages/webmention/src/index.test.ts`

**Interfaces:**
- Consumes: `verifyVouch(vouchUrl, source, isTrustedDomain, options?)` (Task 1).
- Produces: `WebmentionConfig.isTrustedVouchDomain?: (hostname: string) => boolean | Promise<boolean>`.

- [ ] **Step 1: Write the failing tests**

In `packages/webmention/src/index.test.ts`, inside `describe("createWebmentionQueueConsumer", ...)`, the existing vouch tests build their `fetchImpl` branching on the vouch URL vs. the source URL and assert on `stored?.vouch`. Add `isTrustedVouchDomain: () => true` to `config` in the two tests that expect a vouch outcome, and add three new tests:

```ts
  it("does not verify vouch when isTrustedVouchDomain is not configured (defaults to always-untrusted)", async () => {
    const inbox = new MemoryInbox();
    const fetchedUrls: string[] = [];
    const fetchImpl: FetchLike = vi.fn(async (input) => {
      fetchedUrls.push(String(input));
      return new Response('<a href="https://example.com/article">x</a>', {
        headers: { "content-type": "text/html" },
      });
    });
    const consumer = createWebmentionQueueConsumer({
      ...config,
      inbox,
      fetch: fetchImpl,
      // isTrustedVouchDomain intentionally omitted
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
    // The vouch URL itself must never be fetched when it's untrusted (Task 1's contract) —
    // only the source URL should appear.
    expect(fetchedUrls).toEqual(["https://other.example/p"]);
  });

  it("verifies vouch against the source's domain, not the target's", async () => {
    const inbox = new MemoryInbox();
    const fetchImpl: FetchLike = vi.fn(async (input) => {
      const url = String(input);
      if (url === "https://vouches.example/for-me") {
        // Links to the SOURCE, not the target — this must verify true only because
        // isTrustedVouchDomain is configured and the match is against source.
        return new Response(
          '<a href="https://other.example/p">I trust this sender</a>',
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
      isTrustedVouchDomain: () => true,
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

  it("passes the vouch URL's hostname to isTrustedVouchDomain", async () => {
    const inbox = new MemoryInbox();
    const seenHostnames: string[] = [];
    const fetchImpl: FetchLike = vi.fn(
      async () =>
        new Response('<a href="https://other.example/p">x</a>', {
          headers: { "content-type": "text/html" },
        }),
    );
    const consumer = createWebmentionQueueConsumer({
      ...config,
      inbox,
      fetch: fetchImpl,
      isTrustedVouchDomain: (hostname) => {
        seenHostnames.push(hostname);
        return true;
      },
    });
    const { batch } = batchOf([
      {
        source: "https://other.example/p",
        target: "https://example.com/article",
        vouch: "https://vouches.example/for-me",
      },
    ]);
    await consumer(batch, {} as WebmentionEnv, ctx);

    expect(seenHostnames).toEqual(["vouches.example"]);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test --project @dwk/webmention -- -t "vouch"`
Expected: FAIL — `createWebmentionQueueConsumer` still calls `verifyVouch(vouch, target, {...})`
(2-arg-plus-options, matching Task 1's old signature), which no longer typechecks against Task
1's 4-parameter `verifyVouch`. Confirm the compile error names `isTrustedDomain` as a missing
argument.

- [ ] **Step 3: Implement**

In `packages/webmention/src/index.ts`, add to `WebmentionConfig` (after `fetchAllowedHosts`):

```ts
  /**
   * Whether a vouch URL's own hostname is one this receiver already trusts (indieweb.org/Vouch)
   * — checked before any vouch page is fetched. Omitted entirely means "nothing is trusted yet"
   * (every vouch verifies false, but the mention itself is unaffected — vouch is only ever a
   * bonus signal on top of source→target verification, never a gate on it), not "everything is
   * trusted." See {@link verifyVouch} in `verify.ts`.
   */
  readonly isTrustedVouchDomain?: (
    hostname: string,
  ) => boolean | Promise<boolean>;
```

In `createWebmentionQueueConsumer`, change the `vouchOutcome` computation (inside the
`if (result.links) { ... }` block) from:

```ts
          const vouchOutcome =
            vouch !== undefined
              ? {
                  url: vouch,
                  verified: (
                    await verifyVouch(vouch, target, {
                      fetch: config.fetch,
                      logger,
                      metrics,
                      fetchAllowedHosts: config.fetchAllowedHosts,
                    })
                  ).verified,
                }
              : undefined;
```

to:

```ts
          const vouchOutcome =
            vouch !== undefined
              ? {
                  url: vouch,
                  verified: (
                    await verifyVouch(
                      vouch,
                      source,
                      config.isTrustedVouchDomain ?? (() => false),
                      {
                        fetch: config.fetch,
                        logger,
                        metrics,
                        fetchAllowedHosts: config.fetchAllowedHosts,
                      },
                    )
                  ).verified,
                }
              : undefined;
```

(Only the `target` → `source` argument and the new third `isTrustedDomain` argument change —
everything else in this block is untouched.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test --project @dwk/webmention -- -t "vouch"`
Expected: PASS

- [ ] **Step 5: Run the full package gate and commit**

```bash
pnpm --filter @dwk/webmention typecheck
pnpm --filter @dwk/webmention build
pnpm test --project @dwk/webmention
git add packages/webmention/src/index.ts packages/webmention/src/index.test.ts
git commit -m "fix(webmention): thread isTrustedVouchDomain through the queue consumer"
```

---

### Task 3: Changeset, full repo gate, PR

**Files:**
- Create: `.changeset/webmention-vouch-trust-list.md`

- [ ] **Step 1: Add the changeset**

```bash
cat > .changeset/webmention-vouch-trust-list.md <<'EOF'
---
"@dwk/webmention": patch
---

Fix Vouch verification (indieweb.org/Vouch), shipped in the prior `minor` release with two
bugs: it matched the vouch page against the **target's** domain instead of the **source's**,
and had no trust list at all — meaning `vouch=<the source URL itself>` verified unconditionally
once `verifySource` had already proven that link exists. `verifyVouch` now takes a required
`isTrustedDomain` predicate, checked before any fetch (an untrusted vouch domain returns
`verified: false` with no network access at all, closing a fetch-amplification side issue too),
and matches the fetched page against the source's hostname. `WebmentionConfig` gains an
optional `isTrustedVouchDomain`; omitted, every vouch verifies false rather than defaulting to
trusted. `VouchVerified` now logs on every exit path (`reason` field), not only the one that
reaches the link check. Part of Anglesite/Anglesite#1597.
EOF
```

(`patch`, not `minor` — this corrects the previous release's behavior rather than adding new
surface, even though `verifyVouch`'s exported signature does change; the package is still
prerelease (`1.0.0-beta.N`), where changeset semver bumps are advisory ordering rather than a
stability promise to external consumers.)

- [ ] **Step 2: Run the full repo gate**

```bash
pnpm lint && pnpm format:check && pnpm typecheck && pnpm build && pnpm test
```

Expected: all green. Fix any failure before proceeding — do not skip a failing check.

- [ ] **Step 3: Commit, push, open the PR**

```bash
git add .changeset/webmention-vouch-trust-list.md
git commit -m "fix(webmention): add changeset for vouch trust-list fix"
git push -u origin fix/vouch-trust-list
```

Confirm with the user before running `gh pr create` (pushing/opening a PR needs explicit
confirmation per the standing safety rules). Once confirmed, open the PR against
`davidwkeith/workers` main, referencing the bug found in review of
[Anglesite/Anglesite#1604](https://github.com/Anglesite/Anglesite/pull/1604) and linking back
to [#505](https://github.com/davidwkeith/workers/pull/505) as the PR this corrects. Body
includes `part of Anglesite/Anglesite#1597` — no closing keyword.

**Do not proceed to Task 4 until this PR has merged and a tagged `@dwk/webmention` release
containing both #505 and this fix is published to npm** — the Anglesite-side plan
(`docs/superpowers/plans/2026-08-20-vouch-webmention.md`, Task 6) bumps the dependency on that
exact published version. Tasks 4–6 below (the Anglesite-side blogroll-trust-list pieces) have
no dependency on this sidecar release, though, and can proceed in parallel if useful — only the
*original* plan's Task 6 (which reads `vouch_url`/`vouch_verified` from D1) is gated on it.

---

## App side (Anglesite/Anglesite)

### Task 4: `BlogrollTrustKVClient.swift`

**Files:**
- Create: `Sources/AnglesiteCore/BlogrollTrustKVClient.swift`
- Test: `Tests/AnglesiteCoreTests/BlogrollTrustKVClientTests.swift`

**Interfaces:**
- Produces: `BlogrollTrustKVClient.putTrustedDomains(_ domains: Set<String>) async throws`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/BlogrollTrustKVClientTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct BlogrollTrustKVClientTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/")!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!
    }

    @Test("putTrustedDomains PUTs a sorted JSON array to the vouch:trusted-domains key")
    func putsSortedArray() async throws {
        let captured = CapturedRequest()
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                await captured.set(request)
                return (Data(), Self.response(200))
            })

        try await client.putTrustedDomains(["bob.example", "alice.example"])

        let request = await captured.value
        #expect(request?.httpMethod == "PUT")
        #expect(request?.url?.path.hasSuffix("/values/vouch:trusted-domains") == true)
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let body = try #require(await captured.body)
        let decoded = try JSONDecoder().decode([String].self, from: body)
        #expect(decoded == ["alice.example", "bob.example"])
    }

    @Test("putTrustedDomains succeeds with an empty set (empty blogroll)")
    func putsEmptySet() async throws {
        let captured = CapturedRequest()
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                await captured.set(request)
                return (Data(), Self.response(200))
            })

        try await client.putTrustedDomains([])

        let body = try #require(await captured.body)
        let decoded = try JSONDecoder().decode([String].self, from: body)
        #expect(decoded.isEmpty)
    }

    @Test("throws unauthorized on a 401/403 response")
    func throwsUnauthorized() async {
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "bad",
            transport: { _ in (Data(), Self.response(403)) })
        await #expect(throws: CloudflareError.unauthorized) {
            try await client.putTrustedDomains(["alice.example"])
        }
    }

    @Test("throws http(status:) on any other non-2xx response")
    func throwsHTTPError() async {
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { _ in (Data(), Self.response(500)) })
        await #expect(throws: CloudflareError.http(status: 500)) {
            try await client.putTrustedDomains(["alice.example"])
        }
    }
}

private actor CapturedRequest {
    private(set) var value: URLRequest?
    var body: Data? { value?.httpBody }
    func set(_ request: URLRequest) { value = request }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter BlogrollTrustKVClientTests`
Expected: FAIL to compile — `BlogrollTrustKVClient` doesn't exist yet.

- [ ] **Step 3: Implement**

Create `Sources/AnglesiteCore/BlogrollTrustKVClient.swift` — a straight copy of
`ContactsAllowlistKVClient.swift` with the type renamed and the key changed:

```swift
import Foundation
// URLSession/URLRequest/HTTPURLResponse live in FoundationNetworking on non-Darwin
// platforms (swift-corelibs-foundation); this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cloudflare Workers KV client for the Vouch trust-list push (#1597). Writes the site's
/// blogroll domains (`BlogrollTrustSync`) as a single JSON array under `vouch:trusted-domains`
/// in the already-provisioned `SOCIAL_KV` namespace — `worker/vouch-trust.ts` reads this key
/// from the Worker side to gate Vouch verification. Follows the same injectable-transport DI
/// pattern as `ContactsAllowlistKVClient`/`InboxKVClient` — no Keychain coupling, token passed
/// in at init.
public struct BlogrollTrustKVClient: Sendable {
    private static let key = "vouch:trusted-domains"

    private let baseURL: String
    private let accountID: String
    private let namespaceID: String
    private let apiToken: String
    private let transport: CloudflareTransport

    public init(
        accountID: String,
        namespaceID: String,
        apiToken: String,
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) {
        self.accountID = accountID
        self.namespaceID = namespaceID
        self.apiToken = apiToken
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Replaces the whole `vouch:trusted-domains` value with `domains`, sorted for a
    /// deterministic request body. Whole-set replace, not an incremental add/remove — the
    /// caller (`BlogrollTrustSync`) always supplies the complete current blogroll domain set, so
    /// this single call doubles as both "push on change" and "reconcile."
    public func putTrustedDomains(_ domains: Set<String>) async throws {
        let body = try JSONEncoder().encode(domains.sorted())
        let valueURLString = "\(baseURL)/accounts/\(accountID)/storage/kv/namespaces/\(namespaceID)/values/\(Self.key)"
        guard let url = URL(string: valueURLString) else { throw CloudflareError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (_, http) = try await transport(request)
        if http.statusCode == 401 || http.statusCode == 403 { throw CloudflareError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw CloudflareError.http(status: http.statusCode) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter BlogrollTrustKVClientTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/BlogrollTrustKVClient.swift Tests/AnglesiteCoreTests/BlogrollTrustKVClientTests.swift
git commit -m "feat(#1597): add BlogrollTrustKVClient"
```

---

### Task 5: `BlogrollTrustSync.swift` + wire into deploy

**Files:**
- Create: `Sources/AnglesiteCore/BlogrollTrustSync.swift`
- Test: `Tests/AnglesiteCoreTests/BlogrollTrustSyncTests.swift`
- Modify: `Sources/AnglesiteCore/OperationProgress.swift`
- Modify: `Sources/AnglesiteCore/DeployCoordinator.swift`
- Modify: `Sources/AnglesiteApp/DeployModel.swift`

**Interfaces:**
- Consumes: `BlogrollTrustKVClient.putTrustedDomains(_:)` (Task 4); `BlogrollPlan.build(projectRoot:) -> BlogrollPlan.Plan` (already exists — `Sources/AnglesiteCore/BlogrollPlan.swift`; each `Plan.entries[].url: URL`).
- Produces: `BlogrollTrustSync.push(entries: [BlogrollPlan.Entry], client: BlogrollTrustKVClient) async`; `BlogrollTrustSync.pushIfConfigured(siteDirectory: URL, configDirectory: URL, secretStore:, baseURL:, transport:) async`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/BlogrollTrustSyncTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct BlogrollTrustSyncTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.cloudflare.com/")!, statusCode: status,
                         httpVersion: nil, headerFields: nil)!
    }

    private static func makeSiteDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blogroll-trust-sync-\(UUID().uuidString)", isDirectory: true)
        let blogrollDir = dir.appendingPathComponent("src/content/blogroll", isDirectory: true)
        try FileManager.default.createDirectory(at: blogrollDir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeEntry(name: String, url: String, in siteDirectory: URL) throws {
        let content = """
        ---
        name: \(name)
        url: \(url)
        addedDate: 2026-08-01
        ---
        """
        let file = siteDirectory.appendingPathComponent("src/content/blogroll/\(name).md")
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    @Test("push extracts hostnames from blogroll entries and forwards them to the client")
    func pushForwardsHostnames() async throws {
        let siteDirectory = try Self.makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        try Self.writeEntry(name: "alice", url: "https://alice.example/", in: siteDirectory)
        try Self.writeEntry(name: "bob", url: "https://bob.example/blog", in: siteDirectory)
        let plan = BlogrollPlan.build(projectRoot: siteDirectory)

        let captured = CapturedURLs()
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                if let body = request.httpBody, let domains = try? JSONDecoder().decode([String].self, from: body) {
                    await captured.set(domains)
                }
                return (Data(), Self.response(200))
            })

        await BlogrollTrustSync.push(entries: plan.entries, client: client)

        #expect(await captured.value == ["alice.example", "bob.example"])
    }

    @Test("push dedupes multiple entries on the same host")
    func pushDedupesHosts() async throws {
        let siteDirectory = try Self.makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        try Self.writeEntry(name: "alice-posts", url: "https://alice.example/posts", in: siteDirectory)
        try Self.writeEntry(name: "alice-notes", url: "https://alice.example/notes", in: siteDirectory)
        let plan = BlogrollPlan.build(projectRoot: siteDirectory)

        let captured = CapturedURLs()
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                if let body = request.httpBody, let domains = try? JSONDecoder().decode([String].self, from: body) {
                    await captured.set(domains)
                }
                return (Data(), Self.response(200))
            })

        await BlogrollTrustSync.push(entries: plan.entries, client: client)

        #expect(await captured.value == ["alice.example"])
    }

    @Test("push sends an empty array for an empty blogroll, not a no-op")
    func pushSendsEmptyArray() async throws {
        let siteDirectory = try Self.makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        let plan = BlogrollPlan.build(projectRoot: siteDirectory)
        #expect(plan.entries.isEmpty)

        let captured = CapturedURLs()
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { request in
                if let body = request.httpBody, let domains = try? JSONDecoder().decode([String].self, from: body) {
                    await captured.set(domains)
                }
                return (Data(), Self.response(200))
            })

        await BlogrollTrustSync.push(entries: plan.entries, client: client)

        #expect(await captured.value == [])
    }

    @Test("push logs and does not throw when the client fails")
    func pushSwallowsClientFailure() async throws {
        let siteDirectory = try Self.makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        try Self.writeEntry(name: "alice", url: "https://alice.example/", in: siteDirectory)
        let plan = BlogrollPlan.build(projectRoot: siteDirectory)
        let client = BlogrollTrustKVClient(
            accountID: "acct1", namespaceID: "ns1", apiToken: "token",
            transport: { _ in (Data(), Self.response(500)) })

        await BlogrollTrustSync.push(entries: plan.entries, client: client)
    }

    @Test("pushIfConfigured no-ops (no network call) when SOCIAL_KV has not been provisioned")
    func noOpsWithoutKVNamespace() async throws {
        let siteDirectory = try Self.makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blogroll-trust-sync-config-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }

        await BlogrollTrustSync.pushIfConfigured(
            siteDirectory: siteDirectory,
            configDirectory: configDir,
            secretStore: FakeSecretStore(token: "unused"),
            transport: { _ in
                Issue.record("transport must not be called with no provisioned SOCIAL_KV namespace")
                struct UnexpectedNetworkCall: Error {}
                throw UnexpectedNetworkCall()
            })
    }

    @Test("pushIfConfigured resolves the account id and pushes the current blogroll domains")
    func resolvesAccountAndPushes() async throws {
        let cfToken = await CloudflareAPITokenTestEnvironment.shared.claimClear()
        defer { cfToken.release() }
        let siteDirectory = try Self.makeSiteDirectory()
        defer { try? FileManager.default.removeItem(at: siteDirectory) }
        try Self.writeEntry(name: "alice", url: "https://alice.example/", in: siteDirectory)
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blogroll-trust-sync-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }
        try await SiteConfigStore(configDirectory: configDir).save(
            SiteSettings(provisionedWorkerResources: .init(kvNamespaceID: "ns1")))

        let accountsBody = Data("""
        {"success": true, "result": [{"id": "acct1"}]}
        """.utf8)
        let capturedPUT = CapturedURLs()

        await BlogrollTrustSync.pushIfConfigured(
            siteDirectory: siteDirectory,
            configDirectory: configDir,
            secretStore: FakeSecretStore(token: "token"),
            transport: { request in
                if request.url!.path.hasSuffix("/accounts") { return (accountsBody, Self.response(200)) }
                if request.url!.path.hasSuffix("/values/vouch:trusted-domains") {
                    if let body = request.httpBody, let domains = try? JSONDecoder().decode([String].self, from: body) {
                        await capturedPUT.set(domains)
                    }
                    return (Data(), Self.response(200))
                }
                return (Data(), Self.response(404))
            })

        #expect(await capturedPUT.value == ["alice.example"])
    }
}

private struct FakeSecretStore: SecretStore {
    let token: String?
    func read(account: String) throws -> String? { account == SecretAccounts.cloudflareToken ? token : nil }
    func write(_ value: String, account: String) throws {}
    func delete(account: String) throws {}
}

private actor CapturedURLs {
    private(set) var value: [String]?
    func set(_ urls: [String]) { value = urls }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --filter BlogrollTrustSyncTests`
Expected: FAIL to compile — `BlogrollTrustSync` doesn't exist yet.

- [ ] **Step 3: Implement**

Create `Sources/AnglesiteCore/BlogrollTrustSync.swift`:

```swift
import Foundation

/// Pushes the site's blogroll domains (`BlogrollPlan.build(projectRoot:)`) to the Worker's
/// `SOCIAL_KV` store under `vouch:trusted-domains` (#1597) — the Vouch trust list. Deploy-time
/// only (unlike `ContactsAllowlistSync`, no immediate-on-edit trigger): the list doesn't need
/// real-time freshness, and this avoids hooking every blogroll-editing code path. Both the
/// deploy trigger and this whole-set-replace `push` make `src/content/blogroll/` the always-
/// authoritative source: there's no diffing, only an unconditional overwrite, so a missed push
/// self-heals on the next deploy.
public enum BlogrollTrustSync {
    /// Extracts each entry's hostname, deduplicates, and replaces `client`'s
    /// `vouch:trusted-domains` value with the result. An empty blogroll still pushes an empty
    /// array — never skipped — so removing every entry actually clears the trust list rather
    /// than leaving a stale one in place. Never throws — a failure (network, auth,
    /// provisioning) is logged and otherwise invisible; the next deploy retries with the
    /// current state.
    public static func push(entries: [BlogrollPlan.Entry], client: BlogrollTrustKVClient) async {
        do {
            let domains = Set(entries.compactMap { $0.url.host })
            try await client.putTrustedDomains(domains)
        } catch {
            await LogCenter.shared.append(
                source: "BlogrollTrustSync", stream: .stderr,
                text: "Failed to push blogroll trust list to SOCIAL_KV: \(error). Will retry on "
                    + "the next deploy.")
        }
    }

    /// Reads the site's `SiteSettings` and Cloudflare API token from `secretStore`; no-ops (no
    /// network call) unless `SOCIAL_KV` has been provisioned
    /// (`provisionedWorkerResources.kvNamespaceID`) and a token is available. `siteDirectory` is
    /// the package's `Source/` directory (`AnglesitePackage.sourceURL`) — `BlogrollPlan` reads
    /// blogroll entries from there; `configDirectory` is the sibling `Config/` directory.
    public static func pushIfConfigured(
        siteDirectory: URL,
        configDirectory: URL,
        secretStore: any SecretStore = PlatformSecretStore.make(),
        baseURL: String = "https://api.cloudflare.com/client/v4",
        transport: @escaping CloudflareTransport = HTTPCloudflareClient.defaultTransport
    ) async {
        guard let settings = try? SiteConfigStore.read(from: configDirectory),
              let namespaceID = settings.provisionedWorkerResources?.kvNamespaceID, !namespaceID.isEmpty
        else { return }
        guard let token = try? await CloudflareAPICredentials.resolve(secretStore: secretStore), !token.isEmpty
        else { return }
        guard let accountID = await CloudflareAccountLookup.resolveAccountID(apiToken: token, baseURL: baseURL, transport: transport)
        else { return }

        let plan = BlogrollPlan.build(projectRoot: siteDirectory)
        let client = BlogrollTrustKVClient(
            accountID: accountID, namespaceID: namespaceID, apiToken: token, baseURL: baseURL, transport: transport)
        await push(entries: plan.entries, client: client)
    }
}
```

Check the exact signature `SiteConfigStore.read(from:)` uses in `ContactsAllowlistSync.swift`
(`try? SiteConfigStore.read(from: configDirectory)`) before assuming it — if `SiteConfigStore`
in this codebase actually only exposes an instance `load()` (as used elsewhere in
`DeployModel.swift`: `SiteConfigStore(configDirectory: configDirectory).load()`), match
whichever form `ContactsAllowlistSync.swift` itself uses verbatim, since this type is a direct
copy of that file's pattern.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --filter BlogrollTrustSyncTests`
Expected: PASS

- [ ] **Step 5: Wire into the deploy pipeline**

In `Sources/AnglesiteCore/OperationProgress.swift`, add a new milestone right after
`deployPushingContactsAllowlist`:

```swift
    /// Post-deploy: pushing the blogroll's domains to the Vouch trust list's backing store
    /// (#1597).
    static let deployPushingVouchTrustList = OperationProgress(
        kind: .deploy, phase: "vouchTrustListPush", label: "Syncing Vouch trust list…"
    )
```

In `Sources/AnglesiteCore/DeployCoordinator.swift`, `runPostDeploySequencing` gains an eighth
pass. Update the doc comment's "seven post-deploy passes" to "eight," add
`pushVouchTrustList` after `pushContactsAllowlist`, and call it:

```swift
        pushContactsAllowlist: () async -> Void = {},
        /// Vouch trust-list push (#1597): pushes the site's current blogroll domains to the
        /// site's remote store. Ordered last, alongside contacts-allowlist push — unrelated to
        /// every other pass here, and (like contacts) a reconcile that only needs to run once
        /// per deploy. Best-effort and never throws, like every other step here. Callers
        /// without a blogroll/SOCIAL_KV configured pass a no-op.
        pushVouchTrustList: () async -> Void = {}
    ) async {
        onMilestone(.deployWebmentions)
        await sendWebmentions()
        onMilestone(.deployStandardSitePublishing)
        await publishStandardSite()
        onMilestone(.deployStandardSiteGraphPublishing)
        await publishStandardSiteGraph()
        onMilestone(.deploySyndicating)
        await syndicate()
        onMilestone(.deployNotifyingSubscribers)
        await notifySubscribers()
        onMilestone(.deployBackfillingActivityPub)
        await backfillActivityPubOutbox()
        onMilestone(.deployPushingContactsAllowlist)
        await pushContactsAllowlist()
        onMilestone(.deployPushingVouchTrustList)
        await pushVouchTrustList()
    }
}
```

In `Sources/AnglesiteApp/DeployModel.swift`, find the call site that passes
`pushContactsAllowlist:` (search for `ContactsAllowlistSync.pushIfConfigured`) and add a sibling
parameter right after it:

```swift
                pushContactsAllowlist: { [weak self] in
                    guard let self else { return }
                    await ContactsAllowlistSync.pushIfConfigured(
                        configDirectory: configDirectory, secretStore: self.keychain
                    )
                },
                pushVouchTrustList: { [weak self] in
                    guard let self else { return }
                    await BlogrollTrustSync.pushIfConfigured(
                        siteDirectory: siteDirectory, configDirectory: configDirectory, secretStore: self.keychain
                    )
                }
```

(`siteDirectory` is already in scope at this call site — it's used a few lines earlier for
`backfillActivityPubOutbox`'s `siteDirectory: siteDirectory` argument.)

- [ ] **Step 6: Run the full Swift suite and commit**

```bash
swift test --package-path .
git add Sources/AnglesiteCore/BlogrollTrustSync.swift Tests/AnglesiteCoreTests/BlogrollTrustSyncTests.swift \
  Sources/AnglesiteCore/OperationProgress.swift Sources/AnglesiteCore/DeployCoordinator.swift \
  Sources/AnglesiteApp/DeployModel.swift
git commit -m "feat(#1597): sync blogroll domains to the Vouch trust list on deploy"
```

---

### Task 6: `worker/vouch-trust.ts` + wire into `worker.ts`

**Files:**
- Create: `Resources/Template/worker/vouch-trust.ts`
- Test: `Resources/Template/worker/vouch-trust.test.ts`
- Modify: `Resources/Template/worker/worker.ts`

**Interfaces:**
- Produces: `isTrustedVouchDomain(env: VouchTrustEnv, hostname: string): Promise<boolean>`.

- [ ] **Step 1: Write the failing tests**

Create `Resources/Template/worker/vouch-trust.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { isTrustedVouchDomain } from "./vouch-trust.ts";

describe("isTrustedVouchDomain", () => {
  it("is true when the hostname is in the pushed trust list", async () => {
    const env = { SOCIAL_KV: { get: async () => JSON.stringify(["alice.example", "bob.example"]) } };
    expect(await isTrustedVouchDomain(env, "alice.example")).toBe(true);
  });

  it("is false when the hostname is not in the list", async () => {
    const env = { SOCIAL_KV: { get: async () => JSON.stringify(["alice.example"]) } };
    expect(await isTrustedVouchDomain(env, "carol.example")).toBe(false);
  });

  it("is false when SOCIAL_KV is not bound", async () => {
    const env = {};
    expect(await isTrustedVouchDomain(env, "alice.example")).toBe(false);
  });

  it("is false when the key is missing", async () => {
    const env = { SOCIAL_KV: { get: async () => null } };
    expect(await isTrustedVouchDomain(env, "alice.example")).toBe(false);
  });

  it("is false, not thrown, when the stored value is malformed JSON", async () => {
    const env = { SOCIAL_KV: { get: async () => "not json" } };
    expect(await isTrustedVouchDomain(env, "alice.example")).toBe(false);
  });

  it("is false when the stored value is valid JSON but not a string array", async () => {
    const env = { SOCIAL_KV: { get: async () => JSON.stringify({ not: "an array" }) } };
    expect(await isTrustedVouchDomain(env, "alice.example")).toBe(false);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx vitest run worker/vouch-trust.test.ts --config vitest.config.ts`
Expected: FAIL — `./vouch-trust.ts` doesn't exist yet.

- [ ] **Step 3: Implement**

Create `Resources/Template/worker/vouch-trust.ts`:

```ts
/**
 * Vouch trust-list membership (#1597), reading the `vouch:trusted-domains` key
 * `BlogrollTrustSync` pushes to `SOCIAL_KV` from the site's blogroll.
 *
 * @see docs/superpowers/specs/2026-08-20-vouch-webmention-design.md
 */

const TRUST_LIST_KEY = "vouch:trusted-domains";

/** Minimal KV read surface this module needs (mirrors `reader-identity.ts`'s `ReaderIdentityEnv`). */
export interface VouchTrustEnv {
  readonly SOCIAL_KV?: { get(key: string): Promise<string | null> };
}

/**
 * Parses the bare JSON array of hostname strings `BlogrollTrustSync` pushes to
 * `vouch:trusted-domains`. Returns an empty set for a missing binding, missing key, or
 * malformed JSON — never throws, so a KV outage or an unexpected value degrades to "nothing is
 * trusted yet" rather than crashing the queue consumer.
 */
async function readTrustedDomains(env: VouchTrustEnv): Promise<ReadonlySet<string>> {
  if (!env.SOCIAL_KV) return new Set();
  const raw = await env.SOCIAL_KV.get(TRUST_LIST_KEY);
  if (raw === null) return new Set();
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return new Set();
    return new Set(parsed.filter((value): value is string => typeof value === "string"));
  } catch {
    return new Set();
  }
}

/**
 * Whether `hostname` (already lowercased by `verifyVouch`) is in the pushed Vouch trust list.
 */
export async function isTrustedVouchDomain(env: VouchTrustEnv, hostname: string): Promise<boolean> {
  const trusted = await readTrustedDomains(env);
  return trusted.has(hostname);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Resources/Template && npx vitest run worker/vouch-trust.test.ts --config vitest.config.ts`
Expected: PASS

- [ ] **Step 5: Wire into `worker.ts`**

In `Resources/Template/worker/worker.ts`, add the import near the other `worker/*.ts` imports
(alongside `reader-identity.ts`'s import):

```ts
import { isTrustedVouchDomain } from "./vouch-trust.ts";
```

In `handleWebmentionQueue` (currently ~line 958), add `isTrustedVouchDomain` to the
`createWebmentionQueueConsumer` config:

```ts
function handleWebmentionQueue(
  batch: MessageBatch<WebmentionJob>,
  env: WorkerEnv,
  ctx: ExecutionContext,
): Promise<void> {
  if (!env.WEBMENTION_QUEUE || !env.WEBMENTION_INBOX || !env.SITE_URL) {
    return Promise.resolve();
  }
  const consumer = createWebmentionQueueConsumer({
    baseUrl: env.SITE_URL,
    inbox: createD1Inbox(env.WEBMENTION_INBOX),
    isTrustedVouchDomain: (hostname) => isTrustedVouchDomain(env, hostname),
  });
  const webmentionEnv: WebmentionEnv = {
    WEBMENTION_QUEUE: env.WEBMENTION_QUEUE,
    WEBMENTION_INBOX: env.WEBMENTION_INBOX,
  };
  return consumer(batch, webmentionEnv, ctx);
}
```

(Only the new `isTrustedVouchDomain` line is added — everything else in this function is
unchanged. `env` is already in scope here, so the closure can read the real per-request
`SOCIAL_KV` binding.) This requires the `@dwk/webmention` dependency bump from the *other* plan
(`docs/superpowers/plans/2026-08-20-vouch-webmention.md`, Task 6, Step 1) to have landed first —
`WebmentionConfig.isTrustedVouchDomain` doesn't exist in the currently-pinned `1.0.0-beta.1`.
If that bump hasn't happened yet, do it as part of this step (same one-line `package.json`
change) rather than waiting — Task 6 there will find it already done.

- [ ] **Step 6: Run the full template test suite and commit**

```bash
cd Resources/Template
npm run test:scripts
npm run test:worker
cd ../..
git add Resources/Template/worker/vouch-trust.ts Resources/Template/worker/vouch-trust.test.ts \
  Resources/Template/worker/worker.ts Resources/Template/package.json
git commit -m "feat(#1597): wire the Vouch trust list into the webmention queue consumer"
```

---

## Self-Review Notes

- **Spec coverage:** the design spec's "Bug found in review, and its fix" section maps
  entirely to Tasks 1–2 (algorithm) and 4–6 (trust-list plumbing); Task 3 covers the release
  mechanics note ("its own changeset, its own review"). The "Non-goals" list (no dedicated
  vouch-trust UI, reuses blogroll as-is) has no task, correctly — it's an explicit absence.
- **Placeholder scan:** no TBD/TODO. Task 5's implementation step flags one genuine uncertainty
  (whether `SiteConfigStore.read(from:)` vs. an instance `.load()` is this codebase's actual
  call shape) rather than guessing — resolved by copying whatever `ContactsAllowlistSync.swift`
  itself does, since that file is being mirrored verbatim and is the ground truth.
- **Type consistency:** `verifyVouch(vouchUrl, source, isTrustedDomain, options?)` (Task 1) →
  called by the queue consumer as `verifyVouch(vouch, source, config.isTrustedVouchDomain ??
  (() => false), {...})` (Task 2) → `WebmentionConfig.isTrustedVouchDomain` (Task 2) → supplied
  by `worker.ts` as `(hostname) => isTrustedVouchDomain(env, hostname)` (Task 6) → reading
  `SOCIAL_KV` key `vouch:trusted-domains` (Task 6) ← written by `BlogrollTrustKVClient
  .putTrustedDomains` (Task 4) ← called by `BlogrollTrustSync.push` (Task 5) reading
  `BlogrollPlan.Entry.url.host`. Names and the trust-list key string (`vouch:trusted-domains`)
  match at every hop.

# Repo-Owned Edge Artifacts (Layer C1) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate the two repo-owned edge artifacts every Anglesite site should ship — `public/robots.txt` and `public/.well-known/security.txt` — at build time, driven by `.site-config`.

**Architecture:** A new build-time generator `Resources/Template/scripts/edge-artifacts.ts`, mirroring the existing `scripts/csp.ts` pattern (pure builder functions + a `main()` writer + `node:test` unit tests). It runs at `prebuild`, after `csp.ts`. `robots.txt` has stable content, so it is committed and covered by a byte-identical test (like `public/_headers`). `security.txt`'s `Expires` field is regenerated on every build, so it is gitignored and produced only when `SECURITY_CONTACT` is set.

**Tech Stack:** TypeScript (ES modules), `tsx`, `node:test`. Tests run with `npx tsx --test scripts/edge-artifacts.test.ts` from `Resources/Template/`.

**Issue:** [#405](https://github.com/Anglesite/Anglesite-app/issues/405) — sub-issue C1 of epic [#402](https://github.com/Anglesite/Anglesite-app/issues/402). Spec: [`docs/superpowers/specs/2026-06-27-security-story-hardening-design.md`](../specs/2026-06-27-security-story-hardening-design.md) §"C1 — Repo-owned edge artifacts".

> **Post-review update (after PR #413 review):** the shipped implementation in
> [#413](https://github.com/Anglesite/Anglesite-app/pull/413) corrects three things in the code blocks below — the
> merged code is the source of truth:
> 1. **Task 1 imports** — `edge-artifacts.ts` imports only what each task uses
>    (`writeFileSync`/`resolve`/`fileURLToPath` in Task 1; `mkdirSync`/`readConfig` added in Task 2). `dirname` is
>    not imported (it's only used in the test file). The Task 1 code block below over-imports.
> 2. **`buildSecurityTxt` rejects invalid contacts** — a value that is neither a recognized URI
>    (`http`/`https`/`mailto`/`tel`) nor a bare email returns `null` (skip the file) rather than emitting an invalid
>    RFC 9116 `Contact`. A test covers it.
> 3. **`.gitignore` is scoped to `public/.well-known/security.txt`** (not the whole `public/.well-known/` directory),
>    so future static well-known files can still be committed. Tests narrow `string | null` with `assert.ok` before
>    `assert.match`.

## Global Constraints

- **ES Modules only** — `import`/`export`, never CommonJS.
- **Template-only change** — files live under `Resources/Template/`; no `AnglesiteCore`/Swift changes.
- **Mirror the `csp.ts` pattern** — pure builder functions (no I/O), a `main()` that does the file writes, and a guard so `main()` only runs when the script is invoked directly (`if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();`). Unit tests target the pure functions.
- **Config access** — use `readConfig(key)` from `./config` (reads `.site-config`; returns `string | undefined`). Known keys: `SITE_URL` (default `https://example.com` — see `astro.config.ts`); this plan adds `SECURITY_CONTACT`.
- **Determinism for tests** — `buildSecurityTxt` takes the current time as an injected `now: Date` parameter (never calls `new Date()` internally), so tests are deterministic. `main()` passes `new Date()`.
- **robots.txt is committed; security.txt is gitignored** — `robots.txt` content is stable (byte-identical test enforces committed == generated). `security.txt` carries a per-build `Expires`, so it is gitignored and never committed.
- **AI-crawler directives are out of scope** — `robots.txt` allows all crawlers by default; AI-crawler blocking is C4 (#408), opt-in.
- **No Sitemap directive** — the template has no sitemap integration (`@astrojs/sitemap` is not a dependency), so `robots.txt` omits the `Sitemap:` line. (Add it when/if a sitemap integration lands.)
- **No new dependencies.**
- **Work in a git worktree** branched off `main`; do not commit on the main checkout.
- **Verification is JS-only** for this template-only change: `npx tsx --test scripts/edge-artifacts.test.ts` plus the generator round-trip for the committed `robots.txt`. `swift test` is not required (no Swift touched).

---

### Task 1: robots.txt generator

**Files:**
- Create: `Resources/Template/scripts/edge-artifacts.ts`
- Create: `Resources/Template/public/robots.txt` (committed; the generator's output)
- Create: `Resources/Template/scripts/edge-artifacts.test.ts`
- Modify: `Resources/Template/package.json` (the `prebuild` script)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `export function buildRobotsTxt(): string` — returns the full `robots.txt` body, ending in a trailing newline. `main()` writes it to `public/robots.txt`.

- [ ] **Step 1: Write the failing test**

Create `Resources/Template/scripts/edge-artifacts.test.ts`:

```typescript
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { buildRobotsTxt } from "./edge-artifacts";

test("buildRobotsTxt: allows all crawlers and ends with a newline", () => {
  const out = buildRobotsTxt();
  assert.match(out, /^User-agent: \*$/m);
  assert.match(out, /^Disallow:\s*$/m);
  assert.match(out, /\n$/);
});

test("committed public/robots.txt is byte-identical to buildRobotsTxt()", () => {
  const committed = readFileSync(
    resolve(dirname(fileURLToPath(import.meta.url)), "../public/robots.txt"),
    "utf-8",
  );
  assert.equal(buildRobotsTxt(), committed);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Resources/Template && npx tsx --test scripts/edge-artifacts.test.ts`
Expected: FAIL — `buildRobotsTxt` is not exported (module not found / undefined).

- [ ] **Step 3: Create the generator with `buildRobotsTxt` + `main()`**

Create `Resources/Template/scripts/edge-artifacts.ts`:

```typescript
#!/usr/bin/env npx tsx
/**
 * Build-time generator for repo-owned edge artifacts: public/robots.txt and
 * public/.well-known/security.txt. Runs at prebuild (after csp.ts). robots.txt
 * is stable and committed; security.txt carries a per-build Expires and is
 * gitignored (generated only when SECURITY_CONTACT is set). See
 * docs/superpowers/specs/2026-06-27-security-story-hardening-design.md §C1.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { readConfig } from "./config";

/** robots.txt body. Allows all crawlers; AI-crawler directives are C4 (opt-in). */
export function buildRobotsTxt(): string {
  return `# robots.txt — generated by scripts/edge-artifacts.ts
User-agent: *
Disallow:
`;
}

function main(): void {
  const publicDir = resolve(process.cwd(), "public");
  writeFileSync(resolve(publicDir, "robots.txt"), buildRobotsTxt(), "utf-8");
  console.log("Wrote public/robots.txt");
}

// Run only when invoked directly (e.g. `npx tsx scripts/edge-artifacts.ts`), never on import.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
```

- [ ] **Step 4: Generate the committed `public/robots.txt`**

Run: `cd Resources/Template && npx tsx scripts/edge-artifacts.ts`
Expected: prints `Wrote public/robots.txt` and creates `Resources/Template/public/robots.txt` with exactly:

```
# robots.txt — generated by scripts/edge-artifacts.ts
User-agent: *
Disallow:
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test scripts/edge-artifacts.test.ts`
Expected: PASS — both tests pass (the byte-identical test confirms the committed file matches the generator).

- [ ] **Step 6: Wire the generator into `prebuild`**

In `Resources/Template/package.json`, change the `prebuild` script from:

```json
    "prebuild": "npx tsx scripts/csp.ts",
```

to:

```json
    "prebuild": "npx tsx scripts/csp.ts && npx tsx scripts/edge-artifacts.ts",
```

- [ ] **Step 7: Commit**

```bash
git add Resources/Template/scripts/edge-artifacts.ts Resources/Template/scripts/edge-artifacts.test.ts Resources/Template/public/robots.txt Resources/Template/package.json
git commit -m "feat(#405): generate public/robots.txt at build

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: security.txt generator

**Files:**
- Modify: `Resources/Template/scripts/edge-artifacts.ts` (add `buildSecurityTxt`; extend `main()`)
- Modify: `Resources/Template/scripts/edge-artifacts.test.ts`
- Modify: `Resources/Template/.gitignore` (ignore the generated `security.txt`)

**Interfaces:**
- Consumes: `buildRobotsTxt` / `main()` from Task 1; `readConfig` from `./config`.
- Produces: `export function buildSecurityTxt(contact: string | undefined, siteUrl: string, now: Date): string | null` — returns the RFC 9116 body, or `null` when `contact` is missing/blank. `main()` writes it to `public/.well-known/security.txt` only when non-null.

- [ ] **Step 1: Write the failing tests**

Add to `Resources/Template/scripts/edge-artifacts.test.ts` (extend the import on line 6 to add `buildSecurityTxt`):

```typescript
import { buildRobotsTxt, buildSecurityTxt } from "./edge-artifacts";

const NOW = new Date("2026-06-28T12:00:00Z");

test("buildSecurityTxt: returns null when no contact configured", () => {
  assert.equal(buildSecurityTxt(undefined, "https://example.com", NOW), null);
  assert.equal(buildSecurityTxt("  ", "https://example.com", NOW), null);
});

test("buildSecurityTxt: bare email gets a mailto: scheme", () => {
  const out = buildSecurityTxt("security@example.com", "https://example.com", NOW);
  assert.match(out, /^Contact: mailto:security@example\.com$/m);
});

test("buildSecurityTxt: a URL or mailto contact is used as-is", () => {
  const url = buildSecurityTxt("https://example.com/report", "https://example.com", NOW);
  assert.match(url, /^Contact: https:\/\/example\.com\/report$/m);
  const mailto = buildSecurityTxt("mailto:s@example.com", "https://example.com", NOW);
  assert.match(mailto, /^Contact: mailto:s@example\.com$/m);
});

test("buildSecurityTxt: Expires is one year out at UTC midnight", () => {
  const out = buildSecurityTxt("security@example.com", "https://example.com", NOW);
  assert.match(out, /^Expires: 2027-06-28T00:00:00\.000Z$/m);
});

test("buildSecurityTxt: includes a Canonical URL and trailing newline", () => {
  const out = buildSecurityTxt("security@example.com", "https://example.com", NOW);
  assert.match(out, /^Canonical: https:\/\/example\.com\/\.well-known\/security\.txt$/m);
  assert.match(out, /\n$/);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test scripts/edge-artifacts.test.ts`
Expected: FAIL — `buildSecurityTxt` is not exported.

- [ ] **Step 3: Implement `buildSecurityTxt`**

In `Resources/Template/scripts/edge-artifacts.ts`, add after `buildRobotsTxt`:

```typescript
/**
 * RFC 9116 security.txt body, or null when no contact is configured (so we never
 * emit an invalid file with no Contact). `Expires` is one year from `now` at UTC
 * midnight, regenerated every build so it never lapses.
 */
export function buildSecurityTxt(contact: string | undefined, siteUrl: string, now: Date): string | null {
  const trimmed = (contact ?? "").trim();
  if (trimmed.length === 0) return null;
  const contactUri = /^(https?:|mailto:|tel:)/i.test(trimmed)
    ? trimmed
    : trimmed.includes("@")
      ? `mailto:${trimmed}`
      : trimmed;
  const expires = new Date(
    Date.UTC(now.getUTCFullYear() + 1, now.getUTCMonth(), now.getUTCDate()),
  ).toISOString();
  const canonical = `${siteUrl.replace(/\/+$/, "")}/.well-known/security.txt`;
  return `Contact: ${contactUri}
Expires: ${expires}
Canonical: ${canonical}
`;
}
```

- [ ] **Step 4: Extend `main()` to write security.txt when configured**

In `Resources/Template/scripts/edge-artifacts.ts`, replace the body of `main()`:

```typescript
function main(): void {
  const publicDir = resolve(process.cwd(), "public");
  writeFileSync(resolve(publicDir, "robots.txt"), buildRobotsTxt(), "utf-8");
  console.log("Wrote public/robots.txt");

  const siteUrl = readConfig("SITE_URL") ?? "https://example.com";
  const securityTxt = buildSecurityTxt(readConfig("SECURITY_CONTACT"), siteUrl, new Date());
  if (securityTxt !== null) {
    const wellKnown = resolve(publicDir, ".well-known");
    mkdirSync(wellKnown, { recursive: true });
    writeFileSync(resolve(wellKnown, "security.txt"), securityTxt, "utf-8");
    console.log("Wrote public/.well-known/security.txt");
  } else {
    console.log("Skipped security.txt (no SECURITY_CONTACT in .site-config)");
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test scripts/edge-artifacts.test.ts`
Expected: PASS — all robots.txt and security.txt tests pass.

- [ ] **Step 6: Gitignore the generated security.txt**

Append to `Resources/Template/.gitignore`:

```
# Generated at build by scripts/edge-artifacts.ts (Expires changes every build)
public/.well-known/
```

- [ ] **Step 7: Verify the generator runs end-to-end and robots.txt round-trips**

Run: `cd Resources/Template && npx tsx scripts/edge-artifacts.ts && git diff --exit-code public/robots.txt && git status --porcelain public/.well-known`
Expected: prints the two `Wrote …`/`Skipped …` lines, `git diff` exits 0 (committed `robots.txt` unchanged), and `git status` shows nothing for `public/.well-known` (gitignored). Note: with no `.site-config` present in the template, security.txt is skipped — that is the expected default.

- [ ] **Step 8: Commit**

```bash
git add Resources/Template/scripts/edge-artifacts.ts Resources/Template/scripts/edge-artifacts.test.ts Resources/Template/.gitignore
git commit -m "feat(#405): generate RFC 9116 security.txt when SECURITY_CONTACT is set

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage** (spec §C1): `public/.well-known/security.txt` with `Contact` + `Expires` from `SECURITY_CONTACT` ✅ Task 2; `Expires` auto-refreshed every build ✅ Task 2 (injected `now`, recomputed in `main()`); `public/robots.txt` allowing legitimate crawlers ✅ Task 1; AI-crawler directives gated behind C4 ✅ Global Constraints (out of scope). The generator mirrors the `csp.ts` pure-function + writer + tests pattern ✅. Satisfies layer B's artifact-presence warnings: `robots.txt` always (committed → copied to `dist/`), `security.txt` when `SECURITY_CONTACT` is set.

**Placeholder scan:** no TBD/TODO; every code step shows complete code; every run step has an exact command and expected output.

**Type consistency:** `buildRobotsTxt(): string` and `buildSecurityTxt(contact: string | undefined, siteUrl: string, now: Date): string | null` are used consistently in `main()` and the tests. `main()` is defined in Task 1 and replaced wholesale in Task 2 (no partial-edit ambiguity). `readConfig` is the existing `(key: string) => string | undefined` from `./config`. The injected-`now` decision (Global Constraints) matches `buildSecurityTxt`'s signature.

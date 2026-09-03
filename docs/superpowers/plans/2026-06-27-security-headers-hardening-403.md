# Security Header Hardening (Layer A) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the response headers current OWASP/Mozilla guidance recommends (HSTS, COOP, CORP, `upgrade-insecure-requests`) to Anglesite's build-time `_headers` generator.

**Architecture:** Extend the existing build-time CSP generator (`Resources/Template/scripts/csp.ts`). `buildCSP()` gains the valueless `upgrade-insecure-requests` directive; `buildHeaders()` gains three static/conditional header lines. The committed `public/_headers` is the no-config baseline and must stay byte-identical to `buildHeaders("")` — a test enforces this, so every output change updates both the code and the committed file in the same commit.

**Tech Stack:** TypeScript (ES modules), `tsx`, `node:test`. Tests run with `npx tsx --test <file>` from `Resources/Template/`.

**Issue:** [#403](https://github.com/Anglesite/Anglesite-app/issues/403) — sub-issue A of epic [#402](https://github.com/Anglesite/Anglesite-app/issues/402). Spec: [`docs/superpowers/specs/2026-06-27-security-story-hardening-design.md`](../specs/2026-06-27-security-story-hardening-design.md) §"A — Response headers / CSP".

> **Post-review update (after PR #410 review):** two settled deviations from the task text below.
> (1) **COOP/CORP final values** are `Cross-Origin-Opener-Policy: same-origin-allow-popups` and
> `Cross-Origin-Resource-Policy: same-site` (the Task 2 snippets show the original `same-origin`
> values) — see the spec §A for the rationale (popup/auth flows; same-site subdomain assets).
> (2) **Verification is JS-only** (see the Pre-push guard below): `swift test` was *not* required for
> this template-only change.

## Global Constraints

- **ES Modules only** — `import`/`export`, never CommonJS.
- **Template-only change** — files live under `Resources/Template/`; no `AnglesiteCore`/Swift changes.
- **Byte-identical invariant** — `buildHeaders("")` must exactly equal the committed `Resources/Template/public/_headers`. Any change to generator output updates `public/_headers` in the same commit.
- **`X-XSS-Protection` stays absent** — deprecated/harmful; do not add it.
- **COEP stays off** — would break third-party embeds; out of scope for this plan.
- **Work in a git worktree** — create it via the `superpowers:using-git-worktrees` skill before starting; do not commit on the main checkout. Branch off `main` (the spec/plan PR #409 is docs-only and independent).
- **HSTS preload is opt-in** — only emitted when `.site-config` has `HSTS_PRELOAD=true`; never in the baseline.
- **Pre-push guard** — the JS gate is authoritative for this template-only change: `npx tsx --test scripts/csp.test.ts` plus the generator round-trip (`npx tsx scripts/csp.ts && git diff --exit-code public/_headers`). `grep` shows no Swift test asserts header content, so `swift test` is **not required** here. If you do run it, set `ANGLESITE_PLUGIN_PATH` to the plugin checkout (or `--filter` out the e2e suites) — the MCP e2e tests (`AppliesEditEndToEndTests`, `MCPClientHTTPEndToEndTests`) **fail** (not skip) when the plugin checkout is absent, and `swift test` needs `DEVELOPER_DIR` set per project memory.

---

### Task 1: Add `upgrade-insecure-requests` to the CSP

**Files:**
- Modify: `Resources/Template/scripts/csp.ts` (the `BASE` map, `DIRECTIVE_ORDER`, and the `buildCSP` emit line)
- Modify: `Resources/Template/public/_headers` (the `Content-Security-Policy` line)
- Test: `Resources/Template/scripts/csp.test.ts`

**Interfaces:**
- Consumes: nothing new.
- Produces: `buildCSP(configContent: string): string` now ends its output with `; upgrade-insecure-requests`. `buildHeaders` output likewise gains it (via `buildCSP`).

- [ ] **Step 1: Update the failing test for the new baseline CSP**

In `scripts/csp.test.ts`, change the `buildCSP: baseline when no integrations configured` assertion to expect the trailing directive:

```typescript
test("buildCSP: baseline when no integrations configured", () => {
  assert.equal(
    buildCSP(""),
    "default-src 'self'; script-src 'self' static.cloudflareinsights.com; " +
      "style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; " +
      "connect-src 'self' cloudflareinsights.com; frame-src 'self'; object-src 'none'; " +
      "frame-ancestors 'none'; base-uri 'self'; form-action 'self'; upgrade-insecure-requests",
  );
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Resources/Template && npx tsx --test scripts/csp.test.ts`
Expected: FAIL — `buildCSP: baseline …` shows actual output ending at `form-action 'self'` (no `upgrade-insecure-requests`). The byte-identical test still passes for now.

- [ ] **Step 3: Add the directive to the generator**

In `scripts/csp.ts`, add `upgrade-insecure-requests` with an empty value array to `BASE` (after `form-action`):

```typescript
  "form-action": ["'self'"],
  "upgrade-insecure-requests": [],
```

Add it to the end of `DIRECTIVE_ORDER`:

```typescript
const DIRECTIVE_ORDER = [
  "default-src", "script-src", "style-src", "img-src", "font-src",
  "connect-src", "frame-src", "object-src", "frame-ancestors", "base-uri", "form-action",
  "upgrade-insecure-requests",
];
```

Update the emit line in `buildCSP` so a valueless directive emits its name with no trailing space:

```typescript
  return DIRECTIVE_ORDER.map((name) =>
    directives[name].length ? `${name} ${directives[name].join(" ")}` : name,
  ).join("; ");
```

- [ ] **Step 4: Run the test to verify the baseline passes and byte-identical now fails**

Run: `cd Resources/Template && npx tsx --test scripts/csp.test.ts`
Expected: `buildCSP: baseline …` now PASSES; `committed public/_headers is byte-identical …` now FAILS (the committed file lacks the new directive).

- [ ] **Step 5: Update the committed `public/_headers`**

In `Resources/Template/public/_headers`, append `; upgrade-insecure-requests` to the end of the `Content-Security-Policy:` line so it reads:

```
  Content-Security-Policy: default-src 'self'; script-src 'self' static.cloudflareinsights.com; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self' cloudflareinsights.com; frame-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; upgrade-insecure-requests
```

- [ ] **Step 6: Run the full file to verify all green**

Run: `cd Resources/Template && npx tsx --test scripts/csp.test.ts`
Expected: PASS — all 6 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Resources/Template/scripts/csp.ts Resources/Template/scripts/csp.test.ts Resources/Template/public/_headers
git commit -m "feat(#403): add upgrade-insecure-requests to generated CSP

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Add Cross-Origin-Opener-Policy and Cross-Origin-Resource-Policy

**Files:**
- Modify: `Resources/Template/scripts/csp.ts` (the `buildHeaders` template literal)
- Modify: `Resources/Template/public/_headers`
- Test: `Resources/Template/scripts/csp.test.ts`

**Interfaces:**
- Consumes: `buildCSP` from Task 1.
- Produces: `buildHeaders` output now contains `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Resource-Policy: same-origin` lines.

- [ ] **Step 1: Write the failing test**

Add this test to `scripts/csp.test.ts`:

```typescript
test("buildHeaders: includes cross-origin isolation headers", () => {
  const out = buildHeaders("");
  assert.match(out, /Cross-Origin-Opener-Policy: same-origin/);
  assert.match(out, /Cross-Origin-Resource-Policy: same-origin/);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Resources/Template && npx tsx --test scripts/csp.test.ts`
Expected: FAIL — `buildHeaders: includes cross-origin isolation headers` fails (headers not present).

- [ ] **Step 3: Add the headers to `buildHeaders`**

In `scripts/csp.ts`, insert the two lines after the `Permissions-Policy` line in the `buildHeaders` template literal:

```typescript
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Resource-Policy: same-origin
  Content-Security-Policy: ${csp}
```

- [ ] **Step 4: Run the test to verify the new test passes and byte-identical now fails**

Run: `cd Resources/Template && npx tsx --test scripts/csp.test.ts`
Expected: `buildHeaders: includes cross-origin isolation headers` PASSES; `committed public/_headers is byte-identical …` FAILS.

- [ ] **Step 5: Update the committed `public/_headers`**

In `Resources/Template/public/_headers`, insert the two lines after the `Permissions-Policy:` line:

```
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Resource-Policy: same-origin
  Content-Security-Policy: default-src 'self'; script-src 'self' static.cloudflareinsights.com; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self' cloudflareinsights.com; frame-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; upgrade-insecure-requests
```

- [ ] **Step 6: Run the full file to verify all green**

Run: `cd Resources/Template && npx tsx --test scripts/csp.test.ts`
Expected: PASS — all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Resources/Template/scripts/csp.ts Resources/Template/scripts/csp.test.ts Resources/Template/public/_headers
git commit -m "feat(#403): add COOP and CORP response headers

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Add Strict-Transport-Security with opt-in preload

**Files:**
- Modify: `Resources/Template/scripts/csp.ts` (the `buildHeaders` function body + template literal)
- Modify: `Resources/Template/public/_headers`
- Test: `Resources/Template/scripts/csp.test.ts`

**Interfaces:**
- Consumes: `readConfigFromString` (already imported in `csp.ts`).
- Produces: `buildHeaders("")` emits `Strict-Transport-Security: max-age=31536000; includeSubDomains` (no `preload`). `buildHeaders("HSTS_PRELOAD=true")` appends `; preload`.

- [ ] **Step 1: Write the failing tests**

Add these tests to `scripts/csp.test.ts`:

```typescript
test("buildHeaders: HSTS present without preload by default", () => {
  const out = buildHeaders("");
  assert.match(out, /Strict-Transport-Security: max-age=31536000; includeSubDomains\n/);
  assert.ok(!/Strict-Transport-Security:[^\n]*preload/.test(out));
});

test("buildHeaders: HSTS_PRELOAD=true appends preload", () => {
  const out = buildHeaders("HSTS_PRELOAD=true");
  assert.match(out, /Strict-Transport-Security: max-age=31536000; includeSubDomains; preload\n/);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test scripts/csp.test.ts`
Expected: FAIL — both new tests fail (no `Strict-Transport-Security` line emitted).

- [ ] **Step 3: Add HSTS to `buildHeaders`**

In `scripts/csp.ts`, at the top of `buildHeaders`, compute the value, then add the line after the `Cross-Origin-Resource-Policy` line:

```typescript
export function buildHeaders(configContent: string): string {
  const csp = buildCSP(configContent);
  const hstsPreload =
    (readConfigFromString(configContent, "HSTS_PRELOAD") ?? "").trim().toLowerCase() === "true";
  const hsts = `max-age=31536000; includeSubDomains${hstsPreload ? "; preload" : ""}`;
  return `/*
  X-Frame-Options: DENY
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Resource-Policy: same-origin
  Strict-Transport-Security: ${hsts}
  Content-Security-Policy: ${csp}
  Cache-Control: public, max-age=0, must-revalidate

/_astro/*
  Cache-Control: public, max-age=31536000, immutable
`;
}
```

- [ ] **Step 4: Run the tests to verify they pass and byte-identical now fails**

Run: `cd Resources/Template && npx tsx --test scripts/csp.test.ts`
Expected: both HSTS tests PASS; `committed public/_headers is byte-identical …` FAILS.

- [ ] **Step 5: Update the committed `public/_headers`**

In `Resources/Template/public/_headers`, add the HSTS line after `Cross-Origin-Resource-Policy:`:

```
  Cross-Origin-Resource-Policy: same-origin
  Strict-Transport-Security: max-age=31536000; includeSubDomains
  Content-Security-Policy: default-src 'self'; script-src 'self' static.cloudflareinsights.com; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self' cloudflareinsights.com; frame-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; upgrade-insecure-requests
```

- [ ] **Step 6: Run the full file to verify all green**

Run: `cd Resources/Template && npx tsx --test scripts/csp.test.ts`
Expected: PASS — all tests pass.

- [ ] **Step 7: Verify the generator round-trips (JS-only gate)**

Run: `cd Resources/Template && npx tsx scripts/csp.ts && git diff --exit-code public/_headers`
Expected: exits 0 — running the generator regenerates a `public/_headers` identical to the committed one.

(`swift test` is **not required** for this template-only change — see the Pre-push guard in Global Constraints for the `ANGLESITE_PLUGIN_PATH`/`DEVELOPER_DIR` caveats if you choose to run it anyway.)

- [ ] **Step 8: Commit**

```bash
git add Resources/Template/scripts/csp.ts Resources/Template/scripts/csp.test.ts Resources/Template/public/_headers
git commit -m "feat(#403): add HSTS header with opt-in HSTS_PRELOAD

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage** (spec §A): HSTS ✅ Task 3; `HSTS_PRELOAD` opt-in ✅ Task 3; COOP ✅ Task 2; CORP ✅ Task 2; `upgrade-insecure-requests` ✅ Task 1; `X-XSS-Protection` absent ✅ Global Constraints (never added); COEP off ✅ Global Constraints (out of scope); nonce/hash inline scripts — explicitly a phase-2 stretch in the spec, intentionally **not** in this plan.

**Placeholder scan:** no TBD/TODO/"handle edge cases"; every code step shows complete code; every run step states the exact command and expected result.

**Type consistency:** `buildCSP(configContent: string): string`, `buildHeaders(configContent: string): string`, and `readConfigFromString(content, key): string | undefined` match their existing definitions throughout. The valueless-directive emit handles the empty-array case introduced in Task 1 and relied on by later tasks.

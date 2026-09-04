# CSP Headers Enforcement Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate a `public/_headers` file (with a Content-Security-Policy) at build time from the integration domains already recorded in `.site-config`, and validate it in the pre-deploy security gate.

**Architecture:** A new build-time script (`scripts/csp.ts`) reads the flat `SCRIPT_ALLOW` list from `.site-config` and writes a complete `public/_headers`. Astro copies `public/` verbatim into `dist/`, so the headers reach the static host with no Astro config change. An npm `prebuild` hook regenerates the file before every `astro build`. The pre-deploy check then asserts `dist/_headers` exists, has a CSP, and covers every configured domain.

**Tech Stack:** TypeScript run via `tsx` (already a template devDependency), Node's built-in test runner (`node:test`), Astro 5. No new dependencies.

## Global Constraints

- **Template-only.** All changes live under `Resources/Template/`. No `AnglesiteCore`/Swift changes — the descriptor `cspDomains` → `SCRIPT_ALLOW` pipeline already exists and is untouched.
- **No new dependencies.** Use only `tsx` (already present), `node:test`, `node:assert`, and Node's `node:fs`/`node:path`/`node:url` built-ins.
- **Broad/flat CSP rule:** every domain in `SCRIPT_ALLOW` is added to exactly these four directives — `script-src`, `frame-src`, `connect-src`, `img-src`. Domains are deduplicated and sorted for reproducible output.
- **Baseline CSP** (used when no integrations are configured) is exactly:
  `default-src 'self'; script-src 'self' static.cloudflareinsights.com; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self' cloudflareinsights.com; frame-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'`
- **Test files must not ship to user sites.** `scaffold.sh` `rsync`s the template into each new site; `scripts/*.test.ts` must be excluded.
- **Commit trailer:** every commit message ends with
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- All commands below are run from the template directory unless noted:
  `cd Resources/Template` (from the repo/worktree root).

---

### Task 1: CSP generator (`scripts/csp.ts`)

Pure header-composition logic plus a thin CLI. This is the testable core.

**Files:**
- Create: `Resources/Template/scripts/csp.ts`
- Test: `Resources/Template/scripts/csp.test.ts`

**Interfaces:**
- Consumes: `readConfigFromString(content: string, key: string): string | undefined` from `Resources/Template/scripts/config.ts` (existing).
- Produces:
  - `parseAllowedDomains(configContent: string): string[]` — sorted, deduped, non-empty domains from `SCRIPT_ALLOW`.
  - `buildCSP(configContent: string): string` — the Content-Security-Policy header *value*.
  - `buildHeaders(configContent: string): string` — the full `_headers` file body (trailing newline).

- [ ] **Step 1: Write the failing test**

Create `Resources/Template/scripts/csp.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";
import { parseAllowedDomains, buildCSP, buildHeaders } from "./csp";

test("parseAllowedDomains: empty config yields no domains", () => {
  assert.deepEqual(parseAllowedDomains(""), []);
});

test("parseAllowedDomains: dedupes, trims, sorts, drops blanks", () => {
  const cfg = "SCRIPT_ALLOW=js.stripe.com, app.cal.com ,,js.stripe.com, ";
  assert.deepEqual(parseAllowedDomains(cfg), ["app.cal.com", "js.stripe.com"]);
});

test("buildCSP: baseline when no integrations configured", () => {
  assert.equal(
    buildCSP(""),
    "default-src 'self'; script-src 'self' static.cloudflareinsights.com; " +
      "style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; " +
      "connect-src 'self' cloudflareinsights.com; frame-src 'self'; " +
      "frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
  );
});

test("buildCSP: a configured domain lands in script/frame/connect/img only", () => {
  const csp = buildCSP("SCRIPT_ALLOW=giscus.app");
  // present in the four embed directives
  assert.match(csp, /script-src 'self' static\.cloudflareinsights\.com giscus\.app;/);
  assert.match(csp, /img-src 'self' data: giscus\.app;/);
  assert.match(csp, /connect-src 'self' cloudflareinsights\.com giscus\.app;/);
  assert.match(csp, /frame-src 'self' giscus\.app;/);
  // absent from a non-embed directive
  assert.match(csp, /style-src 'self' 'unsafe-inline';/);
  assert.ok(!/style-src[^;]*giscus\.app/.test(csp));
});

test("buildHeaders: includes security headers, CSP, and astro caching", () => {
  const out = buildHeaders("SCRIPT_ALLOW=js.stripe.com");
  assert.match(out, /^\/\*\n/);
  assert.match(out, /X-Frame-Options: DENY/);
  assert.match(out, /X-Content-Type-Options: nosniff/);
  assert.match(out, /Content-Security-Policy: .*js\.stripe\.com/);
  assert.match(out, /\/_astro\/\*\n  Cache-Control: public, max-age=31536000, immutable\n$/);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Resources/Template && npx tsx --test scripts/csp.test.ts`
Expected: FAIL — module `./csp` cannot be resolved (file does not exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `Resources/Template/scripts/csp.ts`:

```ts
#!/usr/bin/env npx tsx
/**
 * Build-time CSP generator. Reads SCRIPT_ALLOW from .site-config and writes a
 * complete public/_headers file. Integration domains are applied broadly to the
 * four directives embeds need (script/frame/connect/img). See
 * docs/superpowers/specs/2026-06-22-csp-headers-enforcement-design.md.
 */
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { readConfigFromString } from "./config";

/** Directives each configured integration domain is added to. */
const EMBED_DIRECTIVES = ["script-src", "frame-src", "connect-src", "img-src"];

/** Baseline directive values (secure-by-default). */
const BASE: Record<string, string[]> = {
  "default-src": ["'self'"],
  "script-src": ["'self'", "static.cloudflareinsights.com"],
  "style-src": ["'self'", "'unsafe-inline'"],
  "img-src": ["'self'", "data:"],
  "font-src": ["'self'"],
  "connect-src": ["'self'", "cloudflareinsights.com"],
  "frame-src": ["'self'"],
  "frame-ancestors": ["'none'"],
  "base-uri": ["'self'"],
  "form-action": ["'self'"],
};

/** Emission order for directives (stable, reproducible output). */
const DIRECTIVE_ORDER = [
  "default-src", "script-src", "style-src", "img-src", "font-src",
  "connect-src", "frame-src", "frame-ancestors", "base-uri", "form-action",
];

/** Sorted, deduped, non-empty domains from the SCRIPT_ALLOW key. */
export function parseAllowedDomains(configContent: string): string[] {
  const raw = readConfigFromString(configContent, "SCRIPT_ALLOW") ?? "";
  const domains = raw.split(",").map((d) => d.trim()).filter((d) => d.length > 0);
  return [...new Set(domains)].sort();
}

/** Compose the Content-Security-Policy header value. */
export function buildCSP(configContent: string): string {
  const domains = parseAllowedDomains(configContent);
  const directives: Record<string, string[]> = {};
  for (const name of DIRECTIVE_ORDER) directives[name] = [...BASE[name]];
  for (const name of EMBED_DIRECTIVES) {
    for (const d of domains) {
      if (!directives[name].includes(d)) directives[name].push(d);
    }
  }
  return DIRECTIVE_ORDER.map((name) => `${name} ${directives[name].join(" ")}`).join("; ");
}

/** Compose the full public/_headers file body. */
export function buildHeaders(configContent: string): string {
  const csp = buildCSP(configContent);
  return `/*
  X-Frame-Options: DENY
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()
  Content-Security-Policy: ${csp}
  Cache-Control: public, max-age=0, must-revalidate

/_astro/*
  Cache-Control: public, max-age=31536000, immutable
`;
}

function main(): void {
  const configPath = resolve(process.cwd(), ".site-config");
  const config = existsSync(configPath) ? readFileSync(configPath, "utf-8") : "";
  const outPath = resolve(process.cwd(), "public", "_headers");
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, buildHeaders(config), "utf-8");
  console.log(`Wrote ${outPath}`);
}

// Run only when invoked directly (e.g. `npx tsx scripts/csp.ts`), never on import.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Resources/Template && npx tsx --test scripts/csp.test.ts`
Expected: PASS — `# pass 5`, `# fail 0`.

- [ ] **Step 5: Commit**

```bash
git add Resources/Template/scripts/csp.ts Resources/Template/scripts/csp.test.ts
git commit -m "feat(#290): build-time CSP header generator (csp.ts)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Wire generation into build + ship baseline + exclude tests

Make the generator run automatically, commit the baseline `public/_headers`, and keep test files out of scaffolded sites.

**Files:**
- Create: `Resources/Template/public/_headers` (committed baseline, produced by the generator)
- Modify: `Resources/Template/package.json` (add `prebuild` script)
- Modify: `Resources/Template/scripts/scaffold.sh` (exclude `scripts/*.test.ts`)

**Interfaces:**
- Consumes: `scripts/csp.ts` CLI from Task 1 (`npx tsx scripts/csp.ts`).
- Produces: a committed `public/_headers` whose contents equal `buildHeaders("")`.

- [ ] **Step 1: Generate the baseline `public/_headers`**

Run from a directory with **no** `.site-config` so the baseline is integration-free:

```bash
cd Resources/Template && npx tsx scripts/csp.ts
```

Expected: prints `Wrote .../Resources/Template/public/_headers`. (`Resources/Template` has no `.site-config`, so the output is the baseline.)

- [ ] **Step 2: Verify the baseline matches the spec exactly**

Run: `cd Resources/Template && cat public/_headers`
Expected output (verbatim):

```
/*
  X-Frame-Options: DENY
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()
  Content-Security-Policy: default-src 'self'; script-src 'self' static.cloudflareinsights.com; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self' cloudflareinsights.com; frame-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'
  Cache-Control: public, max-age=0, must-revalidate

/_astro/*
  Cache-Control: public, max-age=31536000, immutable
```

- [ ] **Step 3: Add the `prebuild` hook to `package.json`**

Modify `Resources/Template/package.json` — change the `scripts` block to:

```json
  "scripts": {
    "dev": "astro dev",
    "prebuild": "npx tsx scripts/csp.ts",
    "build": "astro build",
    "preview": "astro preview",
    "check": "npx tsx scripts/pre-deploy-check.ts"
  },
```

(npm runs `prebuild` automatically before `build`; `check` is unchanged because it scans `dist/`, which already holds the freshly generated `_headers` from the preceding build.)

- [ ] **Step 4: Exclude test files from scaffolded sites**

Modify `Resources/Template/scripts/scaffold.sh` — add one `--exclude` line to the existing `rsync` invocation so it reads:

```sh
rsync -a \
    --exclude='scripts/scaffold.sh' \
    --exclude='scripts/themes.ts' \
    --exclude='scripts/*.test.ts' \
    --exclude='integrations/' \
    --exclude='node_modules/' \
    --exclude='.DS_Store' \
    "$TEMPLATE_ROOT/" "$TARGET/"
```

- [ ] **Step 5: Verify scaffold ships `_headers` and the generator, but not the tests**

```bash
rm -rf /tmp/csp-scaffold-test
zsh Resources/Template/scripts/scaffold.sh --yes /tmp/csp-scaffold-test
ls /tmp/csp-scaffold-test/public/_headers /tmp/csp-scaffold-test/scripts/csp.ts
ls /tmp/csp-scaffold-test/scripts/*.test.ts 2>/dev/null && echo "LEAKED TESTS" || echo "OK: no test files shipped"
```

Expected: the first `ls` lists both files; the second prints `OK: no test files shipped`.

- [ ] **Step 6: Verify `prebuild` regenerates with a configured domain**

```bash
cd /tmp/csp-scaffold-test
printf 'SCRIPT_ALLOW=js.stripe.com\n' >> .site-config
npx tsx scripts/csp.ts
grep -q "frame-src 'self' js.stripe.com" public/_headers && echo "OK: domain enforced" || echo "FAIL"
```

Expected: `OK: domain enforced`.

- [ ] **Step 7: Commit**

```bash
git add Resources/Template/public/_headers Resources/Template/package.json Resources/Template/scripts/scaffold.sh
git commit -m "feat(#290): regenerate public/_headers on build; ship baseline; exclude tests from scaffold

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Validate headers in the pre-deploy gate

Teach `pre-deploy-check.ts` to fail when `dist/_headers` is missing, has no CSP, or omits a configured integration domain. Requires guarding the module's `main()` so the check can be unit-tested.

**Files:**
- Modify: `Resources/Template/scripts/pre-deploy-check.ts`
- Test: `Resources/Template/scripts/pre-deploy-check.test.ts`

**Interfaces:**
- Consumes: `readConfigFromString` from `./config`; the `Issue` type already defined in `pre-deploy-check.ts`.
- Produces: `checkHeaders(headersContent: string | null, configContent: string): Issue[]` — `[]` when valid; one `error` Issue per problem otherwise.

- [ ] **Step 1: Write the failing test**

Create `Resources/Template/scripts/pre-deploy-check.test.ts`:

```ts
import test from "node:test";
import assert from "node:assert/strict";
import { checkHeaders } from "./pre-deploy-check";

const GOOD = `/*
  Content-Security-Policy: default-src 'self'; frame-src 'self' js.stripe.com
`;

test("missing _headers is an error", () => {
  const issues = checkHeaders(null, "");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "error");
  assert.match(issues[0].message, /not enforced/);
});

test("_headers without a CSP is an error", () => {
  const issues = checkHeaders("/*\n  X-Frame-Options: DENY\n", "");
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /no Content-Security-Policy/);
});

test("configured domain missing from CSP is an error naming the domain", () => {
  const issues = checkHeaders(GOOD, "SCRIPT_ALLOW=js.stripe.com,giscus.app");
  assert.equal(issues.length, 1);
  assert.match(issues[0].message, /giscus\.app/);
});

test("CSP covering all configured domains passes", () => {
  assert.deepEqual(checkHeaders(GOOD, "SCRIPT_ALLOW=js.stripe.com"), []);
});

test("no SCRIPT_ALLOW: a present CSP passes", () => {
  assert.deepEqual(checkHeaders(GOOD, ""), []);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: FAIL — `checkHeaders` is not exported from `./pre-deploy-check`.

- [ ] **Step 3: Add `checkHeaders`, wire it in, and guard `main()`**

Modify `Resources/Template/scripts/pre-deploy-check.ts`:

(a) Update the imports at the top of the file:

```ts
import { readdir, readFile, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { parseAllowedDomains } from "./csp";
```

(b) Add these constants next to the existing `DIST_DIR` declaration:

```ts
const HEADERS_FILE = join(DIST_DIR, "_headers");
const CONFIG_FILE = join(process.cwd(), ".site-config");
```

(c) Add the exported checker (place it above `scan`):

```ts
/**
 * Validate the generated CSP. Returns one error Issue per problem:
 * missing _headers, no CSP directive, or a configured SCRIPT_ALLOW domain
 * absent from the CSP.
 */
export function checkHeaders(headersContent: string | null, configContent: string): Issue[] {
  const issues: Issue[] = [];
  if (headersContent === null) {
    issues.push({ severity: "error", message: "No dist/_headers — CSP is not enforced.", file: "_headers" });
    return issues;
  }
  const cspLine = headersContent
    .split("\n")
    .map((l) => l.trim())
    .find((l) => l.startsWith("Content-Security-Policy:"));
  if (!cspLine) {
    issues.push({ severity: "error", message: "dist/_headers has no Content-Security-Policy.", file: "_headers" });
    return issues;
  }
  // Exact-token membership, not substring: `cal.com` must not satisfy `app.cal.com`.
  const cspTokens = new Set(
    cspLine
      .replace(/^Content-Security-Policy:/, "")
      .split(/[\s;]+/)
      .filter((t) => t.length > 0),
  );
  const allow = parseAllowedDomains(configContent);
  for (const domain of allow) {
    if (!cspTokens.has(domain)) {
      issues.push({
        severity: "error",
        message: `Configured integration domain "${domain}" is missing from the CSP.`,
        file: "_headers",
      });
    }
  }
  return issues;
}
```

(d) Inside `scan()`, after the existing `dist/` `stat` try/catch (which early-returns when `dist/` is absent) and before the `for await (const file of walk(DIST_DIR))` loop, insert:

```ts
  const headersContent = existsSync(HEADERS_FILE) ? await readFile(HEADERS_FILE, "utf-8") : null;
  const configContent = existsSync(CONFIG_FILE) ? await readFile(CONFIG_FILE, "utf-8") : "";
  issues.push(...checkHeaders(headersContent, configContent));
```

(e) Replace the bare `main();` at the end of the file with a main-module guard:

```ts
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: PASS — `# pass 5`, `# fail 0`.

- [ ] **Step 5: Verify the full test suite and the CLI still behave**

```bash
cd Resources/Template
npx tsx --test scripts/csp.test.ts scripts/pre-deploy-check.test.ts
```
Expected: PASS — `# pass 10`, `# fail 0`.

Then confirm the CLI still runs (no `dist/` here → its pre-existing "nothing to scan" warning, exit 0):

```bash
cd Resources/Template && npx tsx scripts/pre-deploy-check.ts; echo "exit=$?"
```
Expected: prints the existing "No dist/ directory found — nothing to scan." warning and `exit=0`.

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/scripts/pre-deploy-check.ts Resources/Template/scripts/pre-deploy-check.test.ts
git commit -m "feat(#290): pre-deploy gate validates CSP covers configured integration domains

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Build-time generation from `.site-config` → Task 1 (`csp.ts`) + Task 2 (`prebuild`). ✓
- Broad/flat directive rule (script/frame/connect/img) → Task 1 `EMBED_DIRECTIVES` + tests. ✓
- Baseline secure-by-default `_headers` → Task 2 committed baseline + Task 1 baseline test. ✓
- Generate + validate gate → Task 3 `checkHeaders` wired into `scan()`. ✓
- Template-only, no new deps → all tasks; only `tsx`/`node:test` used. ✓
- Tests excluded from scaffolded sites → Task 2 Step 4 + verification Step 5. ✓
- `main()` guard so `checkHeaders` is importable → Task 3 Step 3(e). ✓
- Edge cases (no `.site-config`, blank domains, dedupe) → Task 1 tests; (missing/empty CSP) → Task 3 tests. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to" — every code step shows complete code. ✓

**Type consistency:** `parseAllowedDomains`/`buildCSP`/`buildHeaders` signatures match between Task 1 definition and tests. `checkHeaders(headersContent: string | null, configContent: string): Issue[]` matches between Task 3 definition, its test imports, and the `scan()` call site. `Issue` is the existing type in `pre-deploy-check.ts`. `readConfigFromString` signature matches `config.ts`. ✓

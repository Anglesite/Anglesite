# Pre-Deploy Audit Extensions (Layer B) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the pre-deploy security scan with four content/artifact checks — mixed content, missing SRI, unsafe `target="_blank"` links, and presence of `robots.txt` / `security.txt`.

**Architecture:** Mirror the existing `checkHeaders` pattern in `Resources/Template/scripts/pre-deploy-check.ts`: each new check is an **exported pure function** unit-tested in isolation, then wired into the `scan()` file walk. No change to the `Issue` model or the error/warning exit semantics.

**Tech Stack:** TypeScript (ES modules), `tsx`, `node:test`. Tests run with `npx tsx --test scripts/pre-deploy-check.test.ts` from `Resources/Template/`.

**Issue:** [#404](https://github.com/Anglesite/Anglesite-app/issues/404) — sub-issue B of epic [#402](https://github.com/Anglesite/Anglesite-app/issues/402). Spec: [`docs/superpowers/specs/2026-06-27-security-story-hardening-design.md`](../specs/2026-06-27-security-story-hardening-design.md) §"B — Pre-deploy checks".

## Global Constraints

- **ES Modules only** — `import`/`export`, never CommonJS.
- **Template-only change** — files live under `Resources/Template/`; no `AnglesiteCore`/Swift changes.
- **Follow the existing pattern** — new checks are exported pure functions in `pre-deploy-check.ts` with the signature `(content: string, file: string): Issue[]` (or `(relPaths: string[]): Issue[]` for the presence check), unit-tested like `checkHeaders`. `scan()` integration is untested (consistent with the existing code, which has no `scan()` test).
- **Severity rules:**
  - Mixed content → **warning** (not error). Rationale: slice A added `upgrade-insecure-requests` to the CSP, which auto-upgrades insecure subresources at runtime, so this is advisory, not deploy-blocking. *(This deliberately refines the spec's "error".)*
  - Missing SRI → **warning**.
  - `target="_blank"` without `rel="noopener"` → **warning**.
  - Missing `robots.txt` / `security.txt` → **warning** (the generators land in slice C1; until then this is informational).
- **No new dependencies** — checks are regex/string-based, like the existing `BLOCKED_SCRIPTS` checks. Heuristic regex HTML matching is acceptable here and consistent with the file.
- **Out of scope for this plan:** the dependency/lockfile vulnerability audit mentioned in spec §B — it needs a different mechanism (an `npm audit` subprocess + advisory data) and is tracked as a separate follow-up, not part of these four checks.
- **Work in a git worktree** branched off `main`; do not commit on the main checkout.
- **One issue per file per check** — a check returns at most one `Issue` per file (matching how `BLOCKED_SCRIPTS` reports), so a file with three insecure refs yields one warning, not three.

---

### Task 1: Mixed-content check

**Files:**
- Modify: `Resources/Template/scripts/pre-deploy-check.ts` (add `checkMixedContent`; call it in the `scan()` per-file loop for `.html`/`.css`)
- Test: `Resources/Template/scripts/pre-deploy-check.test.ts`

**Interfaces:**
- Consumes: the `Issue` interface (already defined in `pre-deploy-check.ts`).
- Produces: `export function checkMixedContent(content: string, file: string): Issue[]`.

- [ ] **Step 1: Write the failing tests**

Add to `scripts/pre-deploy-check.test.ts` (and extend the import on line 3 to include `checkMixedContent`):

```typescript
import { checkHeaders, checkMixedContent } from "./pre-deploy-check";

test("checkMixedContent: flags an insecure src", () => {
  const issues = checkMixedContent('<img src="http://example.com/a.png">', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.match(issues[0].message, /mixed content/i);
  assert.equal(issues[0].file, "dist/index.html");
});

test("checkMixedContent: flags an insecure url() in CSS", () => {
  const issues = checkMixedContent("body { background: url(http://x.com/bg.png); }", "dist/a.css");
  assert.equal(issues.length, 1);
});

test("checkMixedContent: https and relative refs are clean", () => {
  const ok = '<img src="https://x.com/a.png"><script src="/local.js"></script>';
  assert.deepEqual(checkMixedContent(ok, "dist/index.html"), []);
});

test("checkMixedContent: svg xmlns http URL is not flagged", () => {
  const svg = '<svg xmlns="http://www.w3.org/2000/svg"></svg>';
  assert.deepEqual(checkMixedContent(svg, "dist/index.html"), []);
});

test("checkMixedContent: at most one issue per file", () => {
  const two = '<img src="http://a.com/1.png"><img src="http://b.com/2.png">';
  assert.equal(checkMixedContent(two, "dist/index.html").length, 1);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: FAIL — `checkMixedContent` is not exported (import error / undefined).

- [ ] **Step 3: Implement `checkMixedContent`**

In `scripts/pre-deploy-check.ts`, add after `checkHeaders` (before `scan`):

```typescript
/**
 * Insecure (http://) subresource references in built HTML/CSS. Targets resource
 * attributes (`src`) and CSS `url(...)` only — NOT `href` — so anchor links and
 * `xmlns="http://..."` declarations do not false-positive. Advisory: slice A's
 * `upgrade-insecure-requests` auto-upgrades these at runtime. One issue per file.
 */
export function checkMixedContent(content: string, file: string): Issue[] {
  const patterns = [/\bsrc\s*=\s*["']http:\/\//i, /url\(\s*["']?http:\/\//i];
  for (const pattern of patterns) {
    if (pattern.test(content)) {
      return [{ severity: "warning", message: "Mixed content: insecure http:// resource reference", file }];
    }
  }
  return [];
}
```

- [ ] **Step 4: Wire it into `scan()`**

In `scripts/pre-deploy-check.ts`, inside the `for await (const file of walk(DIST_DIR))` loop, after the `SECRET_PATTERNS` block and before the `if (/\.html?$/i.test(file))` block, add:

```typescript
    if (/\.(html?|css)$/i.test(file)) {
      issues.push(...checkMixedContent(content, rel));
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: PASS — all tests pass (existing `checkHeaders` tests plus the 5 new ones).

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/scripts/pre-deploy-check.ts Resources/Template/scripts/pre-deploy-check.test.ts
git commit -m "feat(#404): add mixed-content pre-deploy check

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Subresource-integrity (SRI) check

**Files:**
- Modify: `Resources/Template/scripts/pre-deploy-check.ts` (add `checkSRI`; call it in `scan()` for `.html`)
- Test: `Resources/Template/scripts/pre-deploy-check.test.ts`

**Interfaces:**
- Consumes: `Issue`.
- Produces: `export function checkSRI(content: string, file: string): Issue[]`.

- [ ] **Step 1: Write the failing tests**

Add to the test file (extend the import to include `checkSRI`):

```typescript
test("checkSRI: external script without integrity is a warning", () => {
  const issues = checkSRI('<script src="https://cdn.x.com/a.js"></script>', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.match(issues[0].message, /integrity/i);
});

test("checkSRI: external script WITH integrity is clean", () => {
  const ok = '<script src="https://cdn.x.com/a.js" integrity="sha384-abc"></script>';
  assert.deepEqual(checkSRI(ok, "dist/index.html"), []);
});

test("checkSRI: relative script is clean", () => {
  assert.deepEqual(checkSRI('<script src="/local.js"></script>', "dist/index.html"), []);
});

test("checkSRI: external stylesheet link without integrity is a warning", () => {
  const issues = checkSRI('<link rel="stylesheet" href="https://cdn.x.com/a.css">', "dist/index.html");
  assert.equal(issues.length, 1);
});

test("checkSRI: non-stylesheet link is ignored", () => {
  assert.deepEqual(checkSRI('<link rel="preconnect" href="https://x.com">', "dist/index.html"), []);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: FAIL — `checkSRI` is not exported.

- [ ] **Step 3: Implement `checkSRI`**

In `scripts/pre-deploy-check.ts`, add after `checkMixedContent`:

```typescript
/**
 * External (absolute or protocol-relative) <script> and stylesheet <link> tags
 * that lack an `integrity` attribute. Heuristic tag-level regex match. One issue
 * per offending tag.
 */
export function checkSRI(content: string, file: string): Issue[] {
  const issues: Issue[] = [];
  const tagPattern = /<(script|link)\b[^>]*>/gi;
  let m: RegExpExecArray | null;
  while ((m = tagPattern.exec(content)) !== null) {
    const tag = m[0];
    const isScript = m[1].toLowerCase() === "script";
    const urlAttr = isScript
      ? /\bsrc\s*=\s*["'](?:https?:)?\/\//i
      : /\bhref\s*=\s*["'](?:https?:)?\/\//i;
    if (!urlAttr.test(tag)) continue;
    if (!isScript && !/\brel\s*=\s*["'][^"']*stylesheet/i.test(tag)) continue;
    if (!/\bintegrity\s*=/i.test(tag)) {
      issues.push({
        severity: "warning",
        message: `External ${isScript ? "script" : "stylesheet"} without subresource integrity (SRI)`,
        file,
      });
    }
  }
  return issues;
}
```

- [ ] **Step 4: Wire it into `scan()`**

In `scripts/pre-deploy-check.ts`, inside the existing `if (/\.html?$/i.test(file))` block (alongside the `BLOCKED_SCRIPTS` / `BLOCKED_ROUTES` loops), add:

```typescript
      issues.push(...checkSRI(content, rel));
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: PASS — all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/scripts/pre-deploy-check.ts Resources/Template/scripts/pre-deploy-check.test.ts
git commit -m "feat(#404): add subresource-integrity (SRI) pre-deploy check

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Unsafe `target="_blank"` link check

**Files:**
- Modify: `Resources/Template/scripts/pre-deploy-check.ts` (add `checkExternalLinkRel`; call it in `scan()` for `.html`)
- Test: `Resources/Template/scripts/pre-deploy-check.test.ts`

**Interfaces:**
- Consumes: `Issue`.
- Produces: `export function checkExternalLinkRel(content: string, file: string): Issue[]`.

- [ ] **Step 1: Write the failing tests**

Add to the test file (extend the import to include `checkExternalLinkRel`):

```typescript
test("checkExternalLinkRel: target=_blank without rel=noopener is a warning", () => {
  const issues = checkExternalLinkRel('<a href="https://x.com" target="_blank">x</a>', "dist/index.html");
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.match(issues[0].message, /noopener/i);
});

test("checkExternalLinkRel: rel=noopener is clean", () => {
  const ok = '<a href="https://x.com" target="_blank" rel="noopener">x</a>';
  assert.deepEqual(checkExternalLinkRel(ok, "dist/index.html"), []);
});

test("checkExternalLinkRel: rel with noopener among others is clean", () => {
  const ok = '<a href="https://x.com" target="_blank" rel="noopener noreferrer">x</a>';
  assert.deepEqual(checkExternalLinkRel(ok, "dist/index.html"), []);
});

test("checkExternalLinkRel: link without target=_blank is ignored", () => {
  assert.deepEqual(checkExternalLinkRel('<a href="https://x.com">x</a>', "dist/index.html"), []);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: FAIL — `checkExternalLinkRel` is not exported.

- [ ] **Step 3: Implement `checkExternalLinkRel`**

In `scripts/pre-deploy-check.ts`, add after `checkSRI`:

```typescript
/**
 * Anchors that open a new tab (`target="_blank"`) without `rel="noopener"`,
 * which can expose `window.opener`. Advisory — modern browsers imply noopener,
 * but explicit is safer. One issue per offending anchor.
 */
export function checkExternalLinkRel(content: string, file: string): Issue[] {
  const issues: Issue[] = [];
  const anchorPattern = /<a\b[^>]*>/gi;
  let m: RegExpExecArray | null;
  while ((m = anchorPattern.exec(content)) !== null) {
    const tag = m[0];
    if (!/\btarget\s*=\s*["']_blank["']/i.test(tag)) continue;
    const relMatch = tag.match(/\brel\s*=\s*["']([^"']*)["']/i);
    const rel = relMatch ? relMatch[1].toLowerCase() : "";
    if (!/\bnoopener\b/.test(rel)) {
      issues.push({ severity: "warning", message: 'Link with target="_blank" missing rel="noopener"', file });
    }
  }
  return issues;
}
```

- [ ] **Step 4: Wire it into `scan()`**

In `scripts/pre-deploy-check.ts`, inside the same `if (/\.html?$/i.test(file))` block, add:

```typescript
      issues.push(...checkExternalLinkRel(content, rel));
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: PASS — all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Resources/Template/scripts/pre-deploy-check.ts Resources/Template/scripts/pre-deploy-check.test.ts
git commit -m "feat(#404): warn on target=_blank links missing rel=noopener

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Security-artifact presence check

**Files:**
- Modify: `Resources/Template/scripts/pre-deploy-check.ts` (add `checkArtifactPresence`; collect relative paths during the walk and call it after the loop)
- Test: `Resources/Template/scripts/pre-deploy-check.test.ts`

**Interfaces:**
- Consumes: `Issue`.
- Produces: `export function checkArtifactPresence(relPaths: string[]): Issue[]`.

- [ ] **Step 1: Write the failing tests**

Add to the test file (extend the import to include `checkArtifactPresence`):

```typescript
test("checkArtifactPresence: both present is clean", () => {
  const paths = ["dist/index.html", "dist/robots.txt", "dist/.well-known/security.txt"];
  assert.deepEqual(checkArtifactPresence(paths), []);
});

test("checkArtifactPresence: missing robots.txt is a warning", () => {
  const issues = checkArtifactPresence(["dist/index.html", "dist/.well-known/security.txt"]);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].severity, "warning");
  assert.match(issues[0].message, /robots\.txt/);
});

test("checkArtifactPresence: missing both yields two warnings", () => {
  const issues = checkArtifactPresence(["dist/index.html"]);
  assert.equal(issues.length, 2);
});

test("checkArtifactPresence: backslash paths are normalized", () => {
  const paths = ["dist\\robots.txt", "dist\\.well-known\\security.txt"];
  assert.deepEqual(checkArtifactPresence(paths), []);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: FAIL — `checkArtifactPresence` is not exported.

- [ ] **Step 3: Implement `checkArtifactPresence`**

In `scripts/pre-deploy-check.ts`, add after `checkExternalLinkRel`:

```typescript
/**
 * Warn when expected security artifacts are absent from the built output.
 * Generators for these land in slice C1 (#405); until then this is informational.
 */
export function checkArtifactPresence(relPaths: string[]): Issue[] {
  const set = new Set(relPaths.map((p) => p.replace(/\\/g, "/")));
  const required = ["dist/robots.txt", "dist/.well-known/security.txt"];
  const issues: Issue[] = [];
  for (const path of required) {
    if (!set.has(path)) {
      issues.push({ severity: "warning", message: `Missing security artifact: ${path.replace(/^dist\//, "")}`, file: path });
    }
  }
  return issues;
}
```

- [ ] **Step 4: Wire it into `scan()`**

In `scripts/pre-deploy-check.ts`, collect the relative paths during the walk and run the check after the loop. Declare a collector before the loop:

```typescript
  const relPaths: string[] = [];
```

Inside the `for await (const file of walk(DIST_DIR))` loop, immediately after `const rel = relative(process.cwd(), file);`, add:

```typescript
    relPaths.push(rel);
```

After the `for await` loop closes (before `return issues;`), add:

```typescript
  issues.push(...checkArtifactPresence(relPaths));
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Resources/Template && npx tsx --test scripts/pre-deploy-check.test.ts`
Expected: PASS — all tests pass.

- [ ] **Step 6: Final verification — generator + scan still run clean**

Run: `cd Resources/Template && npx tsx scripts/pre-deploy-check.ts --json`
Expected: exits without throwing and prints a JSON array (it will report "No dist/ directory found" as a single warning when run in the template, which is expected — there is no built `dist/` in the template).

- [ ] **Step 7: Commit**

```bash
git add Resources/Template/scripts/pre-deploy-check.ts Resources/Template/scripts/pre-deploy-check.test.ts
git commit -m "feat(#404): warn on missing robots.txt / security.txt in built output

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage** (spec §B): SRI ✅ Task 2; mixed content ✅ Task 1 (severity refined to warning, flagged in Global Constraints); `rel=noopener` ✅ Task 3; `security.txt`/`robots.txt` presence ✅ Task 4; dependency/lockfile audit — explicitly deferred to a follow-up in Global Constraints (different mechanism), **not** silently dropped.

**Placeholder scan:** no TBD/TODO; every code step shows complete code; every run step states the command and expected result.

**Type consistency:** all four new functions return `Issue[]` using the existing `Issue` interface. Content checks share the `(content: string, file: string)` signature; `checkArtifactPresence(relPaths: string[])` is the documented exception. The `scan()` wiring references each function by the exact exported name. The `relPaths` collector declared in Task 4 is the only new local in `scan()`.

**Ordering note:** Tasks 1–3 each append to the per-file loop / the `.html` block; Task 4 adds a pre-loop declaration and a post-loop call. None conflict; each leaves the test suite green at commit.

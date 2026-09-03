# `.anglesite` Package Model — Phase 5 (Docs Reconciliation) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reconcile the project docs with the now-shipped `.anglesite` package model: update CLAUDE.md's "source of truth" wording and module-layout/`~/Sites` references so they describe the package world (a `Source/` git repo wrapped in a Finder-opaque package), while staying compatible with the #72 ordering note (final filesystem→Git wording waits on the container epics).

**Architecture:** Documentation-only. No code, no tests. Verification is internal consistency: the docs must not describe both the old `~/Sites`-scan model and the new recents/package model as current, and must not claim an unshipped state.

**Tech Stack:** Markdown (`CLAUDE.md`, design spec cross-link).

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-06-19-anglesite-package-model-design.md` §8 (epic interactions & docs).
- **Depends on P1–P4 having landed** (the package model is real before docs claim it).
- **#72 ordering (verbatim from CLAUDE.md):** the filesystem→Git "source of truth" rewording must not be finalized "before that ships, or the doc describes an unshipped state." So: describe the **package** model (which HAS shipped after P1–P4) and that `Source/` is a git repo opened by `cd`/git/VS Code/CLI; phrase the Git-as-source-of-truth point as still gated on the container epics (#66/#69) + repo-everywhere (#68), not as done.
- **Don't invent shipped state:** container runtimes (#66/#69), git bootstrap (#68), and the iOS client (#71) are still open — don't describe them as done.
- **Commit style:** Conventional Commits, scope `(#242)`, body ends `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## File Structure

- `CLAUDE.md` — **modify**: the "source of truth" bullet (line 64), the module-layout/template paragraph, and `~/Sites` references that imply the app owns a scan root.

---

### Task 1: Reword the "source of truth" bullet for the package model

**Files:**
- Modify: `CLAUDE.md` (the editing-guidelines bullet currently at line 64)

- [ ] **Step 1: Read the current bullet to anchor the edit**

Run: `grep -n "source of truth" CLAUDE.md`
Confirm the bullet reads (≈line 64): "**The filesystem is the source of truth** — the app must never become the only way to edit a site. Owners can open `~/Sites/<name>/` in Finder, VS Code, or Claude Code CLI and continue working. (Per #72 …)".

- [ ] **Step 2: Replace the bullet**

Replace that whole bullet with:

```markdown
- **The filesystem is the source of truth** — the app must never become the only way to edit a
  site. A site is now an `.anglesite` **package**: Finder treats it as opaque (double-click opens
  it in Anglesite), but its `Source/` subdirectory is an ordinary git repo, so `cd`, `git`, VS
  Code, and the Claude Code CLI all descend into `Foo.anglesite/Source/` and keep working. App-
  owned per-site state lives alongside it in `Foo.anglesite/Config/`, outside that repo. (Per #72
  this still reframes to **Git** as the source of truth — the `Source/` repo, clonable anywhere,
  is the externally-editable copy — but only once the container runtimes (#66/#69) land and every
  site is a repo (#68). The package model is compatible with both states; don't finalize the
  filesystem→Git wording before that ships, or the doc describes an unshipped state.)
```

- [ ] **Step 3: Verify no contradictory "app owns ~/Sites" claim remains as current**

Run: `grep -n "~/Sites" CLAUDE.md`
For each hit, confirm it's either (a) describing the *default save location* for new/imported packages, or (b) historical context — NOT "the app discovers sites by scanning `~/Sites`" (that model was removed in P2). Update any that still describe the scan as current. If a hit is inside the `AppSettings.sitesRoot` discussion, reword to "the default location new/imported packages are saved to."

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(#242): reword "source of truth" for the .anglesite package model

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Update the module-layout / template paragraph

The "two-repo coordination" / "Stack" / module-layout sections describe the template scaffolding into a site dir and the app hosting `~/Sites/<name>/`. Bring them in line with the package model (scaffold targets `Source/`; a site is a package).

**Files:**
- Modify: `CLAUDE.md` (the "two-repo coordination" template paragraph and the `Resources/Template/` / module-layout notes)

- [ ] **Step 1: Locate the relevant lines**

Run: `grep -n "Template/\|website template\|scaffold\|TemplateRuntime\|Sites/<name>" CLAUDE.md`

- [ ] **Step 2: Add a short "Site identity" note**

Under the "## Stack" section (or immediately after the two-repo table), add a concise paragraph:

```markdown
## Site identity — the `.anglesite` package

A site is a self-contained `.anglesite` **package** (a directory with the `dev.anglesite.site`
package UTI). Layout: `Info.plist` (marker: format version + stable site UUID + display name),
`Source/` (the Astro project, a git repo — the externally-editable, clonable unit), and `Config/`
(app-owned per-site state: `settings.plist`, `chat-history.jsonl`, caches — never in git). The app
opens packages explicitly (Finder double-click, **File ▸ Open**, **Open Recent**) and discovers
them via a recents registry, not by scanning a folder. **File ▸ Import** copies a plain Anglesite
directory into a new package; **File ▸ Export** copies a package's `Source/` back out. New sites
scaffold into `Source/`; deploy, the dev server, and `pre-deploy-check` all run with cwd =
`Source/`. On the MAS build, one security-scoped bookmark per package covers both `Source/` and
`Config/`. The `.site-config` file stays in `Source/` (template/plugin-owned).
```

- [ ] **Step 3: Reconcile any stale scaffold/`~/Sites` wording**

Where the template paragraph says scaffolding lands in `~/Sites/<name>/`, update to "into the package's `Source/` (default package location `~/Sites/<name>.anglesite`)".

- [ ] **Step 4: Self-consistency check**

Run: `grep -n "scans\|scanning\|sites.json\|discover" CLAUDE.md`
Confirm nothing still describes `~/Sites` scanning or `sites.json` as the current discovery mechanism (P2 replaced it with the recents registry / `recents.json`). Fix any stragglers.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(#242): document the .anglesite package layout + recents discovery

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Cross-link the design spec and close the issue loop

**Files:**
- Modify: `CLAUDE.md` (the "## Plan" section — add #242 to the shipped/feature list as appropriate)

- [ ] **Step 1: Add a one-line pointer**

In the "## Plan" section where features are tracked, add a short note that the `.anglesite` package model (#242) shipped, linking the design spec: `docs/superpowers/specs/2026-06-19-anglesite-package-model-design.md`. Keep it factual and dated only if the section uses dates.

- [ ] **Step 2: Final docs consistency pass**

Run: `grep -rn "~/Sites\|sites.json\|filesystem is the source" CLAUDE.md docs/build-plan.md 2>/dev/null`
Skim each hit; ensure none assert the removed scan model as current. `docs/build-plan.md` edits are optional — only touch it if a line directly contradicts the package model; otherwise leave the roadmap alone.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(#242): note package model shipped; link design spec

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:** §8 CLAUDE.md "source of truth" reconciliation → Task 1. Package-model documentation → Task 2. Spec cross-link / plan note → Task 3. The §8 #68/#66/#69 alignment is already encoded in the spec itself (the plans for those epics consume `Source/`); P5 only needs the doc wording, which Tasks 1–2 cover with the #72-compatible phrasing.

**Placeholder scan:** none — each task gives the exact replacement prose and the grep commands to find anchors.

**Risk flags:** the #72 constraint is the trap — do NOT state Git-as-source-of-truth as done; keep it gated on the container epics. Don't describe #66/#69/#68/#71 as shipped. This is the final phase of #242; after it lands, run the whole-#242 review and use superpowers:finishing-a-development-branch to open the PR.

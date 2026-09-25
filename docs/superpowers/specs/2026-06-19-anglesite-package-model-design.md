# `.anglesite` package + per-site config model — design

**Issue:** #242 — Adopt `.anglesite` package + per-site (Xcode-style) config model
**Date:** 2026-06-19
**Status:** Approved design; ready for implementation planning.

## Goal

Adopt an **Xcode-style, per-site identity model**: a site is a self-contained
`.anglesite` macOS **package** that the app opens directly (like Xcode opens a
project), with per-site configuration attached to the package rather than stored
app-globally. This replaces the implicit "the app owns `~/Sites/<name>/`"
(Mail.app-style) assumption with "the project is the unit, and its config travels
with it."

## Why

Anglesite lets owners open *any* Anglesite website, and the project ethos commits
to "the filesystem (→ Git, per #72) is the source of truth — the app must never
become the only way to edit a site." That argues against an app-owned store and
for an Xcode-style model where the **project is the unit**. A macOS package (a
directory with a declared package UTI) is the idiomatic fit: Finder treats it as
opaque (double-click opens it in Anglesite) while `cd`, `git`, VS Code, and the
Claude Code CLI all still descend into it normally — so the "open in any editor /
Git is the source of truth" ethos is preserved; only Finder's double-click
behavior changes.

## Decisions (locked in brainstorming)

| Decision | Choice |
|---|---|
| Spec scope | Comprehensive (the whole issue), implemented in phases |
| Scene/window model | Keep custom `WindowGroup(for: String.self)` + declare the package UTI; **not** `DocumentGroup` |
| Git boundary | Repo = the **source subdir**; app config lives in the package but **outside** git |
| Internal layout | `Source/` (git repo) + `Config/` (app-owned) + `Info.plist` marker |
| Migration of existing sites | **File ▸ Import** copies a plain dir into a new package (symmetric with File ▸ Export); originals untouched. No in-place wrap, no plain-dir compat runtime |
| Discovery | **Recents-based** registry; drop the `~/Sites` scan (`~/Sites` survives only as the default save location) |
| Identity | **Stable UUID** in `Info.plist` (replaces today's path-derived id) |

## 1. Package format & identity

`<Name>.anglesite` is a directory with extension `anglesite` and
`LSTypeIsPackage = YES` — Finder-opaque (double-click opens in Anglesite), but
`cd` / `git` / VS Code / Claude Code CLI descend into it normally.

```
Acme.anglesite/                 (UTI: dev.anglesite.site, LSTypeIsPackage)
├── Info.plist                  marker: formatVersion, siteID (UUID), displayName, createdDate
├── Source/                     git repo — the Astro project (clonable, containerized, pushable)
│   ├── .git/
│   ├── src/  astro.config.mjs  package.json
│   └── scripts/pre-deploy-check.ts
└── Config/                     app-owned, NOT in git
    ├── settings.plist          per-site: Siri/readiness config, preferences
    ├── chat-history.jsonl      (migrated from <site>/.anglesite/)
    └── cache/                  derived/cached state
```

**Identity change.** Site identity moves from today's path-derived string
(`SiteStore.identifier(for:)` = canonicalized path) to a **stable UUID** minted at
creation and stored in `Info.plist`. This survives moves/renames and gives Siri
(`SiteEntity`) a durable id. `WindowGroup(for: String.self)` is unchanged — it is
now keyed by the UUID string instead of the path string.

`Info.plist` fields:

- `AnglesiteFormatVersion` (Int) — for forward-compat gating.
- `AnglesiteSiteID` (String, UUID) — stable identity.
- `AnglesiteDisplayName` (String) — defaults to the package base name.
- `AnglesiteCreatedDate` (Date).

## 2. Type declarations

Add to both targets (DevID + MAS) via `project.yml` / Info.plist:

- `UTExportedTypeDeclarations` entry for `dev.anglesite.site`:
  - conforms to `com.apple.package`, `public.composite-content`
  - `public.filename-extension = anglesite`
- `CFBundleDocumentTypes` entry:
  - role **Editor**
  - `LSTypeIsPackage = YES`
  - `LSItemContentTypes = [dev.anglesite.site]`

**Open routing.** `application(_:open:)` (SwiftUI `onOpenURL` / `openWindow`
equivalent) receives an opened package URL → resolves/validates → registers in the
recents registry → opens its window. This covers Finder double-click and "Open
With" on both targets. On MAS the user-initiated open carries an implicit grant; a
security-scoped bookmark is minted on first open (see §7).

## 3. Site model: scanner → recents registry

`SiteStore` stops scanning `~/Sites`. It becomes a **recents registry** of
packages the owner has created / opened / imported.

- Persisted in Application Support (replacing today's `sites.json`): per entry
  `{ siteID (UUID), packageURL, displayName, bookmarkData? (MAS), lastSeen }`.
- The launcher "Sites" window lists recents (Xcode "recent projects" model).
- `~/Sites` survives **only** as the default save location for new/imported
  packages — it is no longer a discovery root and carries no app-owns-folder
  semantics.
- `ProjectValidator` now validates `<pkg>/Source/` (sentinels live in the source
  tree), not the package root.
- Stale entries (package moved/deleted/bookmark unresolvable) are marked missing
  rather than silently dropped.

## 4. Per-site config store

New `SiteConfigStore` (in `AnglesiteCore`) reads/writes
`<pkg>/Config/settings.plist`; owned per-window by `SiteWindow`.

- **Starter schema** (forward-looking; mostly empty today): display name,
  Siri/readiness config, per-site preferences. Grows as features attach per-site
  state instead of reaching for app-global `UserDefaults`.
- `chat-history.jsonl` moves from `<site>/.anglesite/` → `<pkg>/Config/`.
- The old write-once `.site-config` (SITE_NAME/SITE_TYPE/TAGLINE) is folded into
  `Info.plist` (identity) + `settings.plist` (preferences).
- Replaces app-global per-site state. Genuinely global keys (e.g.
  `lastOpenedSiteID`) stay in `AppSettings`, now holding a UUID.

> **Amendment (2026-09-08, #1960 / decision D6):** `Config/` also holds the generated
> `wrangler.toml` (`AnglesitePackage.wranglerConfigURL`) and the deploy markers that used to
> be `.site-config` keys (`SiteSettings.workerDeployed` / `.workerProvisioned` /
> `.sourceBundleBucket`). They carry provisioned Cloudflare resource ids and deploy history —
> infrastructure the app manages on the owner's behalf, not site content — so they never enter
> the `Source/` repo; the deploy path stages `wrangler.toml` into the guest. The full
> content-versus-config classification of every app-written file is in
> [`../../specs/2026-09-08-site-file-ownership-classification-decision.md`](../../specs/2026-09-08-site-file-ownership-classification-decision.md).

## 5. Create / Import / Export

**New site.** Scaffold writes into `<pkg>/Source/`:

1. Create package dir + `Info.plist` (fresh UUID) + empty `Config/`.
2. Run the template scaffold with cwd = `<pkg>/Source/`.
3. `git init` in `Source/` (coordinates with #68).
4. Default save path `~/Sites/<slug>.anglesite`; register in recents.

**File ▸ Import** (plain dir → package):

1. Pick a plain Anglesite directory.
2. **Copy** its tree into a new package's `Source/` (preserve an existing `.git`
   if present).
3. Migrate any `<dir>/.anglesite/` contents → `Config/`.
4. Write `Info.plist` (fresh UUID). Original directory is left untouched.

> **Known tradeoff (documented):** after import two copies exist — the original
> plain directory and the package. The package's `Source/` is the live copy going
> forward; the original is no longer tracked by Anglesite. This was an explicit
> choice over in-place wrapping.

**File ▸ Export** (package → plain dir):

- Copy `<pkg>/Source/` working tree to a chosen plain directory.
- Default **excludes** `node_modules/`; option to include or exclude `.git`.

## 6. Runtime working directory

All site-rooted subprocess invocations switch cwd from the site root to
**`<pkg>/Source/`**. `ProcessSupervisor.launch(currentDirectoryURL:)` is unchanged
— only the URL passed in changes. Affected callers:

- `SiteScaffolder` (scaffold script)
- `LocalSiteRuntime` (Astro dev server)
- `DeployCommand` (build + deploy)
- `PreDeployCheck` (`pre-deploy-check.ts --json`)

## 7. MAS sandbox & bookmarks

- One security-scoped bookmark **per package URL** (today it is per plain-dir
  site). `Source/` and `Config/` are both inside the granted package, so a single
  grant covers subprocess cwd inheritance *and* config I/O.
- Bookmark minted on first open (Finder/powerbox/Open-panel grant), stored in the
  recents entry, resolved + `startAccessingSecurityScopedResource()` per
  `SiteWindow` lifetime (existing `SiteWindow.acquireGrant()` flow, retargeted to
  the package URL).

## 8. Epic interactions & docs

- **#68 (git bootstrap):** operates on `Source/` — `git init` / first push happen
  there. Aligns cleanly.
- **#66 / #69 (container runtimes):** the runtime mounts/clones **`Source/`**
  only; `Config/` never enters the container.
- **#72 / CLAUDE.md ("source of truth"):** reconcile the wording to the package
  model — *Git (the `Source/` repo) is the externally-editable, clonable copy; the
  package wraps it; `cd`/git/VS Code/CLI still descend into it.* #72 notes the
  filesystem→Git wording should not be finalized until the container runtimes land;
  the package-model wording proposed here is compatible with both the pre- and
  post-container states, so it can land with this work, but the final phrasing
  change is sequenced in P5 and coordinated with #72.

## 9. Error handling & edge cases

- **Unknown / newer `AnglesiteFormatVersion`** → open read-only with an upgrade
  prompt (forward-compat); never silently rewrite a newer format.
- **Missing/corrupt `Source/` or failed sentinels** → surface invalid-site state
  via the existing health surface; do not crash.
- **Stale recents entry** (package moved/deleted, bookmark unresolvable) → mark
  missing, offer to relocate or remove.
- **Import target name collision** → disambiguate the destination path.
- **Partial scaffold/import failure** → clean up the half-written package (no
  orphaned partial packages registered in recents).

## 10. Testing

`AnglesiteCore` unit tests (CI-runnable; no hosted app target — per the project's
CI constraint, keep app-target glue thin and push logic into testable Core types):

- Package read/write round-trip.
- `Info.plist` marker parse + format-version gating (older / current / newer).
- `SiteConfigStore` read/write + defaults.
- Import: dir → package, with and without an existing `.git`; `.anglesite/`
  migration; original-untouched assertion.
- Export: package → dir; `node_modules` excluded; `.git` include/exclude option.
- Identity-UUID stability across a simulated package move.
- Recents registry persistence + stale-entry handling.
- cwd resolution = `<pkg>/Source/` for scaffold/dev/deploy/pre-deploy.

## 11. Implementation phasing

The design is comprehensive; the implementation plan will deliver it in phases:

- **P1 — Format core:** package read/write, `Info.plist` marker + UUID identity,
  type declarations (UTI / `CFBundleDocumentTypes`), format-version gating.
- **P2 — Open/create + runtime:** `SiteStore` → recents registry, open routing
  (`onOpenURL`/Finder), new-site scaffold into `Source/`, cwd switch to `Source/`,
  MAS bookmark retarget to the package.
- **P3 — Import / Export:** File ▸ Import (dir→package copy), File ▸ Export
  (package→dir copy).
- **P4 — Config store:** `SiteConfigStore`, migrate chat history + `.site-config`
  into `Config/` / `Info.plist`.
- **P5 — Docs + epic touchpoints:** CLAUDE.md "source of truth" reconciliation
  (coordinated with #72), confirm #68/#66/#69 alignment notes.

## Out of scope

- Changing the deploy/preview *pipeline* behavior beyond the cwd retarget.
- Implementing the container runtimes (#66/#69) or git-bootstrap (#68) — this spec
  only defines the package boundary they consume.
- Any third-party state/document library (the project stays Plain SwiftUI + actors
  for v0).

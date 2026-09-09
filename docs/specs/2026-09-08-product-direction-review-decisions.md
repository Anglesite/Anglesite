# Product direction review — decision record (2026-09-08)

**Date:** 2026-09-08
**Status:** current
**Issue:** — (owner review session; follow-ups #1957–#1968, see §4)

A whole-project review on 2026-09-08 compared the as-built app against the
founding design (`anglesite-skills/docs/dev/mac-app-design.md` §2–§3), the
Personal Publishing OS pivot, and the Claude Code removal roadmap. It found
four places where docs marked `current` contradict each other and several
places where the code has moved past every doc. The owner resolved each one.
This record is the reference; the contradicted docs carry an amendment note
pointing here.

## 1. Context — what the review found

**Related:** [`2026-06-26-personal-publishing-os-pivot-analysis.md`](2026-06-26-personal-publishing-os-pivot-analysis.md) (pivot),
[`../superpowers/specs/2026-07-08-cross-platform-swift-port-design.md`](../superpowers/specs/2026-07-08-cross-platform-swift-port-design.md) (port),
[`../superpowers/specs/2026-08-03-modern-wysiwyg-editor-design.md`](../superpowers/specs/2026-08-03-modern-wysiwyg-editor-design.md) (block editor),
[`../architecture.md`](../architecture.md), [`../build-plan.md`](../build-plan.md), #72, #459, #1015, #1221, #1615.

- The founding design's non-goals ("Mac-only", "not a hosting service", "not an
  IDE") have each been partly or wholly reversed by later work without a
  decision record saying so.
- The pivot analysis (§5.8) decided Windows/Linux would be *separate native
  apps*; the port design twelve days later approved a *shared-code port*. Both
  were marked current.
- The pivot's locked decisions "import dropped for V1" (§5.4) and
  "Cloudflare-only deploy for v1" (§5.5) were reversed by the website-import
  spec (#1615) and the DeployTarget seam (#1015) without amending the pivot.
- `docs/architecture.md` asserted "no external LLM APIs ever" and a live
  Private Cloud Compute tier; `ExternalLLMBackend` ships behind a Settings
  opt-in and the PCC tier is an alias for on-device.
- Two editing pipelines (`JS/edit-overlay` click-to-edit and
  `JS/wysiwyg-engine` block editor) are both injected into every preview with
  no deprecation decision.
- The pre-deploy gate script runs from the owner-editable `Source/` clone and
  nothing re-verifies it at deploy time, so "the gate cannot be bypassed" held
  only for the app's own invocation, not for the script's contents.
- `wrangler.toml` and `.site-config` deploy markers carry app-owned
  infrastructure state (D1/KV/R2/queue IDs) inside the clonable `Source/` repo.
- The app depends on Anglesite-operated infrastructure (`auth.anglesite.dwk.io`
  OAuth callback; the Worker catalog fetched from `davidwkeith/workers`) that
  the "desktop client" framing never named.
- The primary UI exposes git nouns, npm semver ranges, raw file paths, a
  Terminal command, and three ungated code editors to an audience CLAUDE.md
  defines as non-technical.

## 2. Decisions (owner, 2026-09-08)

| # | Question | Decision |
|---|---|---|
| D1 | Who is the user? | **Individuals and small businesses owning their social web.** Anglesite manages the technical details — Worker configuration, provisioning, deployment — on their behalf. The founding "non-technical owner" bar still applies to the *surface*: the owner never adjudicates git, npm, file layout, or infrastructure; the app does. |
| D2 | Windows/Linux: shared-code port or separate native apps? | **Shared-code port** (#571). The port design supersedes pivot §5.8. |
| D3 | Did website import (#1615) and GitHub Pages (#1015) override the pivot's locked V1 decisions? | **Confirmed.** Pivot §5.4 and §5.5 are amended, not binding. |
| D4 | Overlay vs block editor | **Block editor only.** `JS/edit-overlay` click-to-edit is deprecated and must be removed before 1.0. |
| D5 | Gate integrity | **Yes.** The app pins the hash of `scripts/pre-deploy-check.ts` (and the rest of the app-owned `scripts/` set) and refuses to deploy on mismatch. "Keep my version" is not offered for the gate. |
| D6 | `wrangler.toml` location | **Move to `Config/`.** Infrastructure identifiers are app-owned state; a generated copy is staged into the guest at deploy time. `.site-config` deploy markers follow the same rule. |
| D7 | Anglesite-operated infrastructure | **Accepted.** Anglesite controls everything under and including `anglesite.dwk.io`. The Worker catalog fetch is pinned. |
| D8 | Milestones | **Both.** App Store submission (#617) *and* the software-factory and WYSIWYG epics gate v1.0. |

## 3. Consequences

**D1 — audience.** Turns the UX findings from "accepted scope" into bugs. In
particular: the blocking per-file sheets at site open (scripts divergence,
dependency updates) must decide for the owner (#1053 already says so); git
nouns leave the toolbar and drawers; the Terminal command in Settings ▸
Advanced is gated or removed; the sync-conflict sheet is re-phrased in terms
of the owner's content, not files and Macs; raw subprocess logs stay behind
an explicit "Show details" affordance. Code editors (Component Editor source
tab, CSS and props inspectors) are kept but move behind the Advanced gate.
"Hosting service" is no longer a non-goal: the app is expected to provision
and reconcile the owner's Cloudflare resources.

**D2 — port.** Pivot §5.8 is superseded. `AnglesiteLinux`, `AnglesiteIOS`,
`AnglesiteMobile` are real targets and need real test coverage before they
count as shipped (today: 44 lines for Linux, none for Mobile).

**D3 — import and deploy targets.** Pivot §5.4/§5.5 are amended. GitHub Pages
and future static hosts ride the `DeployTarget` seam; the gate stays in the
shared spine.

**D4 — block editor.** `WebViewBridge` stops injecting the overlay bundle; the
`anglesite` script-message namespace, `EditUndoCoordinator`, and the overlay's
prebuild phase go with it. Quick-edit affordances the overlay provided (hover
outline, image drop on `<img>`) must exist in the block editor first. The
WYSIWYG vision doc's §12 "supersedes the overlay" line becomes binding.

**D5 — gate integrity.** `TemplateScriptsManifest` already lists the
app-owned scripts; deploy-time verification compares the site's copy against
the app's bundled hash and blocks with an owner-phrased message ("Anglesite's
safety check on this site was changed; restoring it") followed by an automatic
restore, never a keep-mine choice. Also closes the gap that `RepoBootstrap.publish`
pushes `Source/` with no scan.

**D6 — `wrangler.toml` to `Config/`.** `SocialWorkerProvisionCommand`,
`WorkerNameRename`, `UntitledSitePropagation`, and the executor's
base64-staging step read/write `Config/wrangler.toml`. Existing sites migrate
on open (move + gitignore + commit) under the #745 versioned-migration
mechanism. `annotations.json`, `docs/DESIGN.md`, `docs/brand.md` and
`Attributions/` get an explicit content-or-config classification in the same
pass.

**D7 — Anglesite infrastructure.** `auth.anglesite.dwk.io` and the catalog are
documented first-party dependencies. `WorkerCatalogFetcher` and
`WorkersConformanceFetcher` pin a commit (or a signed release asset) instead
of `main`.

**D8 — milestones.** v0.5.0-Alpha and v1.0.0-Beta are closed out or folded
into v1.0; v1.0 = #617 + #1256 + #1221 + overlay removal (D4) + gate pin (D5).

## 4. Follow-up issues

Filed from this record on 2026-09-08:

- #1957 — Deprecate and remove `JS/edit-overlay` before 1.0 (D4).
- #1958 — Pin and verify app-owned `scripts/` at deploy time; block on mismatch (D5).
- #1959 — Gate `RepoBootstrap.publish` with `PreDeployCheck` (D5).
- #1960 — Move `wrangler.toml` and `.site-config` deploy markers to `Config/` (D6).
- #1961 — Pin the Worker catalog and conformance fetch (D7).
- #1962 — Blocking site-open sheets decide for the owner: scripts divergence, dependency updates (D1, #1053).
- #1963 — Remove git/npm/wrangler/MCP vocabulary from primary-surface strings (D1).
- #1964 — Gate the Safari MCP Terminal command and the three code editors behind Advanced (D1).
- #1965 — Label PCC-tier features that degrade to on-device; disclose off-device sends on the External LLM opt-in (LLM policy).
- #1966 — `ProcessSupervisor.run` logs to `LogCenter` by default (eight silent call sites).
- #1967 — Reconcile milestones per D8.
- #1968 — Tests for `AnglesiteMobile`, `AnglesiteLinux`, QuickLook extensions (D2).

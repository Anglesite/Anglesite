# A/B slice 5: configure/start lifecycle UI — design (#1518)

**Status:** approved design, pre-implementation.
**Issue:** [#1518](https://github.com/Anglesite/Anglesite/issues/1518), slice 5 of 6 from
[#1270](https://github.com/Anglesite/Anglesite/issues/1270)'s approved design
(`docs/superpowers/specs/2026-08-16-edge-ab-testing-design.md`, hereafter "the master
spec" — §5 "Experiment lifecycle" and §10 item 5 define this slice's scope). This
document fills in the implementation-level decisions the master spec deliberately left
to the slice: sheet architecture, the variant-scaffold function, and — the one piece
not anticipated by existing code — how an owner picks an on-page element for the
`visible` goal kind without seeing CSS-selector jargon.

Depends on slice 3 (#1515, merged — `DomainConfig.Experiments`, deploy-path wiring) and
is independent of slice 4 (#1516, results pipeline — `ExperimentEventsD1Client`, still
open). Slice 5 does not block on slice 4: the "running" step shows declared config
state (id/name/status/started date) with no live visitor/conversion counts, exactly as
this doc's §6 specifies.

## 1. Architecture

`ExperimentStatsModel` (`Sources/AnglesiteApp/ExperimentStatsModel.swift`) gains an
enum-driven step, the same shape as `EmailSetupModel`'s already-shipped
`Step { ecosystem, appleTier, details, ... }` pattern:

```swift
enum Step {
    case manual                        // today's #769 form, unchanged
    case propose                       // playbook suggestions, interactive
    case configure(ExperimentDraft)    // variant scaffold + goal picker
    case starting                      // config write + deploy in flight
    case running(DomainConfig.Experiments.Experiment)  // declared status only
}
```

One sheet, one model, one menu command (`WebsiteCommands.swift:123`) — no new window
class, matching the master spec §5's "all UI extends the existing Experiment Results
sheet surface."

The model gains a `sourceDirectory: URL` dependency it doesn't have today (currently
only `siteID`), to load/write `DomainConfig.Experiments` through
`DomainConfigStore.update(sourceDirectory:_:)` and to call `DeployModel.deploy(...)` for
the start step — mirroring `EmailSetupModel`'s existing `sourceDirectory` + ops-seam
pattern.

**Step resolution on open:** load config; a `running` or `draft` entry in
`experiments.active` jumps straight to `.running`/`.configure`; no entry falls back to
`.manual` with the playbook section now tappable to enter `.propose`. Since the schema
allows at most one active experiment (master spec §2), there's never an ambiguous
starting state.

## 2. Propose

The existing static "Test ideas" list (`ExperimentStatsSheetView.swift:35-42`,
currently read-only text) becomes a list of tappable rows plus an "or describe your own
idea" text field. Selecting one creates an `ExperimentDraft` (page = the sheet's site
route context, suggestion title/rationale carried through as the default experiment
name) and moves to `.configure`. Nothing persists yet, per master spec §5's Propose row
("Nothing persisted").

## 3. Configure

### Variant scaffold

New `AnglesiteCore` function, `duplicatePageAsVariant(siteID:relativePath:experimentID:variantID:) async -> ContentCreateResult`, built on `NativeContentOperations.duplicatePage`'s
read/write/commit shape (`NativeContentOperations.swift:414-450`) but differing in two
ways `duplicatePage` doesn't support:

- **Deterministic target route** — `/x/<experimentId>/<variantId>/` (master spec §2),
  not `duplicatePage`'s "Title Copy" / "Copy 2" collision-bumping naming.
- **Frontmatter injection** — `rel=canonical` → the control page's URL, `noindex`, and
  sitemap exclusion, none of which `duplicatePage` or `ContentScaffold.renderPage`
  (template-from-`PageTemplate`, not content-copy) do today. These three are also gate
  requirements (master spec §6), so the scaffold function is the single place that
  guarantees they're always present — no separate "remember to add noindex" step for a
  hand author to skip.

After scaffolding, the sheet hands off to the ordinary page editor (Navigator `.route`
entry for the new variant page) for content edits — master spec §5's "owner edits the
variant — the same editing surfaces as any page." The configure step's own UI is the
goal picker plus a "done editing, continue" affordance; it does not embed an editor.

### Goal picker

Three consequence-phrased options, no kind names, no `IntersectionObserver`/selector
vocabulary anywhere in the UI (master spec §10 item 5):

- **"Counts when a visitor reaches ___"** (`pageview`) — a page picker scoped to the
  site's existing routes.
- **"Counts when a visitor scrolls about ___ of the way down"** (`scroll`) — a percent
  stepper, 1–100.
- **"Counts when a visitor sees ___ on the page"** (`visible`) — click-to-select in the
  live preview (below).

### Click-to-select (`visible` goal)

Reuses `EffectPlacementController`'s exact state machine (`idle → picking → applying →
succeeded/failed`, Esc-to-cancel via `.onExitCommand`, HUD banner text swapped for goal
language) and the JS-side exclusive pick-mode gate
(`installPlacementPickMode()`/`_enterPlacementMode`/`_exitPlacementMode`,
`overlay.ts:119-158`) already shipped for the Effects Gallery. Two net-new pieces, both
flagged by the preview-architecture survey as genuinely absent from the codebase today:

1. **A new message type** (or a new terminal-handler branch on the existing
   `anglesite:pick-placement` message, decided during implementation by whichever
   requires less duplication) carrying the same `ElementInfo` payload
   (`selector.ts`'s `elementInfoFor`) that placement-pick already collects.
2. **A CSS-selector-string builder** — nothing today emits a literal selector; the two
   adjacent mechanisms (`selector.mjs` in the sibling repo, `PlacementMatcher.swift`)
   resolve to a source-file patch location or a `PageModel` node id, not selector text.
   The new builder reuses the *proven priority order* from both (`data-anglesite-id` →
   `data-testid` → `#id` → role/aria-label → stable classes → `tag:nth-child`), filters
   Astro's dev-time `astro-*` scoped-class hashes (already flagged as needed,
   `selector.ts:6`), and joins the ancestor chain into a `>`-combinator selector.

Hover feedback on the candidate element while picking (not present in placement-pick
today) is added as a small `mouseover` handler inside `installPlacementPickMode`'s
active branch, mirroring `attachHover`'s existing pattern — worth the small addition
since "point at the reviews section" is meaningfully harder without a hover outline
confirming what's about to be selected.

**Known limitation, stated explicitly rather than silently accepted:** the picker runs
against the Astro **dev-server** DOM (via the live preview), while the beacon matches
the selector against the **production build's** DOM. These are not guaranteed
identical. §4 below closes this gap with a gate check rather than leaving it as a
runtime surprise.

Draft state (variant route, goal config) is written through
`DomainConfigStore.update(sourceDirectory:)` as `status: "draft"` as soon as the goal is
picked — not deferred to Start — so closing and reopening the sheet mid-configure
resumes where the owner left off.

## 4. Pre-deploy gate extension

`checkExperiments` (already partially built per the survey — `experiments-artifact.ts`,
`experiments-paths.ts` exist) gains a check for `visible`-goal experiments: after
`dist/` is built, confirm the picked selector resolves to at least one element in both
the control and variant pages' built HTML. This closes the dev-DOM-vs-build-DOM gap
from §3 — a selector that only matched dev-server markup (e.g. a scoped class that
doesn't survive the production build) fails the deploy instead of shipping a goal that
silently never fires. Consistent with the master spec §6's existing posture ("a test
that 404s its own arm burns traffic silently... exactly the class of misconfiguration
SRM would only catch a week later") — this is the same failure class, one gate.

## 5. Start

"Start" (owner-initiated, one tap) writes `status: "running"` + `startedAt` via
`DomainConfigStore.update(sourceDirectory:)`, then calls the existing
`DeployModel.deploy(siteID:siteDirectory:configDirectory:currentRoutes:...)` — no new
deploy machinery. `DeployCoordinator.resolveRunningExperiments` and the D1/Worker
provisioning gated on `hasRunningExperiment` are already wired end-to-end from slice 3.
Copy per master spec §5: "Your test is live. Visitors will see one version or the
other; I'll tell you when there's a clear answer."

Deploy failure (blocked by the gate, network error, etc.) reverts the step to
`.configure` with the draft intact — `status` is not written to `"running"` until
deploy succeeds, so a failed start never leaves the config in a state claiming a test
is live when it isn't.

## 6. Running status

Shows id, name, started date, and status only — sourced entirely from
`DomainConfig.Experiments`, no D1 read. This is a deliberate, temporary gap: live
visitor/conversion counts are slice 4's (#1516) `ExperimentEventsD1Client` responsibility, not
this slice's. When #1516 ships, the `.running` case gains a live-count subview; this
slice's job is only to make sure a running experiment is visible and identifiable in
the sheet, not to duplicate #769's manual-entry counting for it.

`LiveRegionAnnouncer` gains a lifecycle-transition case (e.g. `configuring → running`),
posted from `.onChange(of: model.step)` in the sheet view, following
`DeployDrawerView`'s existing `.onChange(of: model.phase)` pattern
(`DeployDrawerView.swift:253-259`) gated the same way on `AppSettings.shared.announcesLiveUpdates`.

## 7. Accessibility

Every new interactive element (playbook row, goal-picker option, start button,
running-status display) follows the house label/value/hint pattern
(`SyncStatusView.swift:30-34`) and, for the goal-picker's selectable options,
`.isSelected` via `.accessibilityAddTraits` on a button-per-row layout
(`LicenseGateSheetView.swift:169-195`'s pattern) rather than a `Picker`/checkmark
layout, for the same one-element-per-row screen-reader reason documented there.

## 8. Testing

- **Swift:** `ExperimentStatsModel` step transitions (propose → configure → starting →
  running, and the resume-from-draft path) with a stubbed `DomainConfigStore`; the new
  selector-builder function against representative `ElementInfo` fixtures (id present,
  id absent/stable-class-only, id absent/nth-child-fallback, `astro-*` hash filtering);
  `duplicatePageAsVariant`'s frontmatter injection (canonical/noindex/sitemap
  exclusion) and deterministic-route behavior (including the collision-with-existing-
  route case, which `pathProblem`-style validation should reject rather than silently
  overwrite).
- **JS (edit-overlay, vitest):** the new pick-mode message type/handler, hover-outline
  behavior, Esc-to-cancel.
- **Template (`npx tsx --test`):** the `checkExperiments` dist/-selector-resolution
  check, both the matches and the no-match-fails-the-gate cases.
- **Manual/E2E:** not required for CI per master spec §8; a live click-to-select run
  against a real dev-server preview is worth doing once by hand before merge, since it's
  the one path with no automated DOM to assert against.

## 9. Out of scope (this slice)

- Live D1 visitor/conversion counts on the running-status view — slice 4 (#1516).
- Conclude (promote/keep/discard) — slice 6.
- `route` goal kind's picker UI — the master spec ties it to the Cloudflare-native
  contact form (free-services slice 2) landing first; this slice's goal picker offers
  `pageview`/`scroll`/`visible` only. Adding `route` later is additive to the same
  picker, not a redesign.
- Auto-generated variant copy — explicitly out of scope for the whole feature (master
  spec §11).

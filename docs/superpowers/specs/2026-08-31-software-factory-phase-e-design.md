# Software factory Phase E — enforced failure-feedback loop + metrics

**Date:** 2026-08-31
**Status:** Approved
**Tracking:** #1263 (epic #1256, design doc `docs/specs/2026-08-04-software-factory-design.md`
§4.2 Stage 5, §5 Phase E)

## 1. Goal

Every existing factory routine already has a "give up and route to `🏭 Blocked: human`" path,
but none of them close the loop Cloudflare's design insight calls for: naming *what beat the
agent* so the gap gets fixed like any other work. Phase E adds that mandatory step (Stage 5),
gives it a place to land (a new label + issue shape), and adds enough metrics that the owner
can make the Phase E exit-criteria decision — whether the factory earns wider autonomy or
stays allowlisted — with real data instead of a guess.

The autonomy decision itself is explicitly out of this design's scope: it's an owner call
(§5.4 of the parent design doc), not something a routine can make. This design builds the
infrastructure that makes the decision *decidable*.

## 2. Failure vs. routing — the distinction that scopes Stage 5

Every routine's "give up" path was audited (`docs/issue-repro-diagnose-routine.md`,
`docs/issue-fix-dispatcher-routine.md`, `docs/issue-intake-routine.md`, the issue-splitter
routine). Two shapes exist, and only one is a Stage-5 case:

- **Legitimate routing** — the agent correctly recognized the issue needs a human: an epic,
  missing information, `TIER_4_ESCALATION`/`ENVIRONMENT_ESCALATION`, a multi-machine
  requirement, an unsplittable issue. The agent didn't fail; it classified correctly. No gap
  issue.
- **Actual failure** — the agent tried and lost: an attempt cap exhausted with no usable
  result, a stage that produced no report/no diagnosis marker at all. This is "what beat the
  agent" — exactly Stage 5's target.

Concretely, three hook points across two files carry the second shape today, and none of them
currently produce a gap issue:

| File | Branch | Current behavior |
|---|---|---|
| `docs/issue-repro-diagnose-routine.md` | Stage 1, attempt 2 produces no `## Stage 1 — Reproduce report` comment | Remove `🛠️ In Progress`, add `🏭 Blocked: human`, post a comment explaining the run failed |
| `docs/issue-repro-diagnose-routine.md` | Stage 2, attempt 2 returns `DIAGNOSIS_FAILED` or no marker | Same as above |
| `docs/issue-fix-dispatcher-routine.md` | Attempt-cap check finds 2 closed, unmerged factory PRs already linked to the issue | Post a comment summarizing both PR attempts, add `🏭 Blocked: human` |

No other branch in any routine changes.

## 3. Gap issue: label, shape, and routing

**Label:** `🏭 Factory gap`, description "Doc/test-seam/abstraction gap that beat a factory
run — filed by Stage 5, routes via intake" (GitHub caps label descriptions at 100 characters;
this is 93), color `E99695`.
Checked against the full existing label palette to avoid a color collision (`docs` uses
`0075ca`, the two `Blocked` labels share `B60205`, `Needs split` is `D93F0B`, `Needs repro` is
`FEF2C0`) — `E99695` is unused and reads as "actionable, needs attention" without being
mistaken for either existing red `Blocked` label or being visually identical to `Needs split`,
since the two can plausibly co-occur in a filtered issue view (an unsplittable issue can also
be a Stage-5 failure).

**Body shape** — the routine constructs this directly via `gh issue create`; no
`.github/ISSUE_TEMPLATE/` file, since these are always filed programmatically, never through
GitHub's UI picker:

```
## What was attempted
<what the routine/fix session actually did — e.g. "2 fix-session attempts (PR #X, PR #Y),
both timed out at 24h without green CI" or "Stage 1 attempt 2 produced no report comment">

## What was missing
<the concrete gap, named as specifically as the failing run can identify it — a missing test
seam, an opaque abstraction, an absent doc, an environment the agent couldn't reach>

## Proposed fix
<a first-pass suggestion from the filing agent, explicitly a guess, not a mandate>

---
Filed by the software factory's Stage-5 feedback loop against #<original-issue-number>.
```

Title: `Factory gap: <short description of what beat the agent> (from #<N>)`.

**Routing:** the Stage-5 step applies only `🏭 Factory gap` — no `🎯` area label, no `🏭`
state label. The existing intake routine (Stage 0) picks up the newly-opened issue on its own
schedule and classifies it exactly like a human-filed issue. This matches the parent design's
own instruction ("routing back through normal intake so gaps get fixed like any other work")
and needs no changes to the intake routine itself, since it doesn't care what unrelated labels
already exist on an issue it's classifying.

**Cross-linking:** the gap issue's body links back to the original (`#<N>`, shown above); the
routine also posts a comment on the *original* issue linking to the new gap issue, appended
to (or folded into, per each routine's existing pattern) the failure comment it already posts.

## 4. Routine changes

Both `docs/issue-repro-diagnose-routine.md` and `docs/issue-fix-dispatcher-routine.md` are the
version-controlled master copies of live local scheduled tasks (`anglesite-factory-repro-
diagnose`, `anglesite-fix-dispatcher`) per their own "this file is the master copy" convention.
Each gets one new step inserted immediately before its existing `🏭 Blocked: human` label-add,
at each of the three hook points in §2's table:

> **Stage 5 (mandatory).** Before adding `🏭 Blocked: human`, file a gap issue:
> `gh issue create --repo Anglesite/Anglesite --title "Factory gap: <short description> (from
> #<N>)" --label "🏭 Factory gap" --body "<body per the template in the Phase E design doc,
> docs/superpowers/specs/2026-08-31-software-factory-phase-e-design.md §3>"`. Use what you
> already know about this run (the attempt(s) that failed, any partial output, any PR links)
> to fill in "What was attempted" and "What was missing" — do not leave either generic. Then
> append a link to the new gap issue to the failure comment you're about to post on #<N>
> (do not skip the existing failure comment — both happen).

After editing, both live scheduled tasks are updated via
`mcp__scheduled-tasks__update_scheduled_task` to match the doc verbatim, same as every prior
change to these routines.

No changes to the intake routine, the issue-splitter routine, or any routine's legitimate-
routing branches.

## 5. Metrics routine

**New routine + doc:** `docs/issue-factory-metrics-routine.md`, following the same
master-copy convention as the other three routine docs. **New scheduled task:**
`anglesite-factory-metrics`, weekly cadence (matching the "closed per week" framing in
#1263's own task list), local scheduled task (no toolchain need, but consistent with where
the other factory routines that mutate GitHub state already run).

**Mechanism:** each firing computes a small set of counters purely from GitHub state (no new
persistent storage) and overwrites one designated comment on epic #1256 — found by a fixed
marker string (`<!-- factory-metrics-report -->`) at the top of the comment body, via
`gh api repos/Anglesite/Anglesite/issues/comments/<id>` (PATCH) if found, or `gh issue comment
1256` (create) on the routine's first-ever run. This mirrors the repo's existing "labels +
comments are the only pipeline state" philosophy — no new storage, no dashboard.

**Counters** (cumulative all-time, plus a trailing-7-day column):

- **Issues closed by the factory** — merged PRs whose body ends with the `_Opened by the
  software factory (Phase C) — epic #1256._` marker (same search the dispatcher already uses
  for its own concurrency-cap check), counted by merge date.
- **Attempts per close** — for each merged factory PR, count how many *other* closed
  (unmerged) factory PRs also reference the same issue via `closingIssuesReferences`, plus 1
  for the merge itself; report the mean across the period. This is the proxy "cost" metric
  (§ per your answer: no real token/dollar cost source exists via `gh` alone, so this and
  wall-clock time from `🏭 Ready` to merge stand in for it — both derived, never presented as
  real spend).
- **Gap issues filed / fixed** — count of open+closed issues carrying `🏭 Factory gap`,
  split by state, for the period.
- **Current backlog snapshot** — open counts of `🏭 Blocked: human` and `🏭 Ready` (context
  for reading the other numbers, not a rate).

**Report shape** (the comment body, regenerated fully each run — no incremental diffing):

```
<!-- factory-metrics-report -->
## Software factory metrics — Phase E

_Last updated: <ISO date>, by the weekly anglesite-factory-metrics routine._

| Metric | All-time | Last 7 days |
|---|---|---|
| Issues closed by factory | N | N |
| Avg attempts per close | N.N | N.N |
| Gap issues filed | N | N |
| Gap issues fixed | N | N |

**Current backlog:** N open `🏭 Blocked: human`, N open `🏭 Ready`.

---
This report is infrastructure for the Phase E decision gate (#1263, task 4) — deciding
whether the factory earns wider autonomy is an explicit owner call, not something this
routine does. See the parent design doc §5 (Rollout) for the criteria.
```

## 6. Backfill

Handled once, directly in the implementing session — not a routine, since it's a one-time
audit, not a recurring job. Procedure: list every currently-open `🏭 Blocked: human` issue,
read its comment history, and classify each per §2's failure/routing distinction (e.g. a
comment naming an attempt-cap with linked PRs is a failure; a comment naming an epic, missing
info, `TIER_4_ESCALATION`, or a multi-machine surface is legitimate routing). File a gap issue
per §3 for each genuine failure found; touch nothing for legitimate-routing issues.

## 7. Non-goals

- No dashboard, no new persistent storage beyond GitHub issues/comments/labels.
- No change to any routine's legitimate-routing branches.
- No automated autonomy decision — that stays an explicit, manual owner action reading the
  metrics report.
- No paired sidecar-repo work — this phase is entirely app-repo GitHub-state and local
  scheduled-task changes.

## 8. Exit criteria (from #1263, restated)

Every capped-out or failed run has a corresponding gap issue (§2–§4, plus the one-time
backfill in §6), and a recurring metrics summary exists (§5) that's sufficient to make the
autonomy decision. The decision itself (#1263 task 4) stays open on the tracking issue after
this ships — this design's PR should not carry a closing keyword for #1263 (per
`CONTRIBUTING.md`'s multi-PR tracking-issue guidance), since one task remains genuinely
undone until the owner acts on it.

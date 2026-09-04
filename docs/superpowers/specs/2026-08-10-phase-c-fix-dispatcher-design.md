# Software factory Phase C — fix dispatcher + capped fix agents

**Date:** 2026-08-10
**Status:** Approved
**Tracking:** #1261 (epic #1256, design doc `docs/specs/2026-08-04-software-factory-design.md`
§4.2–4.5)

## 1. Goal

Implement Phase C: a scheduled dispatcher that claims `🏭 Ready` issues and launches
autonomous fix agents, bounded by a concurrency cap of 3 and a per-issue attempt cap of 2,
starting on a Tier-1-only allowlist (docs, `Resources/Template/`, JS edit overlay, portable
Swift targets). Exit criteria (per #1261): factory-authored PRs merging at a steady rate on
allowlisted paths, with zero dispatcher collisions against human/agent-claimed issues and
both caps observed in practice.

## 2. A real backlog check changes the starting assumption

Before designing, the actual `🏭 Ready` backlog was checked (2026-08-10): 5 issues carry the
label, and 4 of them ("WYSIWYG slice 4–7") are large, multi-week feature slices, not small
atomic fixes. Phase A's intake routine assigns `🏭 Ready` for "well-scoped, unblocked,
actionable" — a much looser bar than "small enough for one autonomous PR" — and Phase A's own
closing comment on #1259 explicitly deferred verification-tier tagging as out of scope.

**Consequence:** `🏭 Ready` alone does not tell the dispatcher an issue is Tier-1-sized. The
dispatcher needs its own scoping judgment, separate from the label (§5).

## 3. Decision: Cloud routine, not Local

Unlike Phase B (which needed the owner's own Mac for a real Xcode/Swift toolchain), Phase C's
allowlist is Tier-1-only — docs, `Resources/Template/`, the JS edit overlay, and portable
SwiftPM targets, all of which the design doc's own Tier table (§4.4) already classifies as
buildable on Linux, and this repo's CI already runs a Linux lane against the portable Swift
targets. A Cloud routine (Anthropic's sandbox, matching Phase A's substrate) is therefore
viable and preferred: it doesn't tie up the owner's Mac, doesn't need it awake/online, and an
autonomous agent that commits/pushes/opens real PRs runs in a disposable sandbox rather than
with the owner's local git/gh credentials for no toolchain reason.

## 4. Architecture: two decoupled jobs

A single routine firing that claims an issue, writes the fix, and babysits the PR to green
would need to run for as long as CI takes — potentially many hours, as already observed in
this environment's own PR-babysitting trigger chains (a real flaky-CI PR needed 24+ hours of
periodic check-ins). Routine firings should stay short and cheap, like Phase A's. So:

- **Dispatcher** — scheduled (hourly, matching Phase A's cadence — each firing is cheap:
  counting + scoping-checking + picking). Each firing: counts current factory-owned in-flight
  work (§6); if under the concurrency cap of 3, scans `🏭 Ready` issues oldest-first (capped
  at 5 candidates per firing) for one that passes the scoping pre-check (§5) and the attempt
  cap (§7); claims it (`🛠️ In Progress`) and **launches** a fix session for it via
  `RemoteTrigger` (creating a near-immediate one-shot trigger, the same mechanism already
  used for this environment's own PR-babysitting check-in chains); then its own turn ends. It
  does not wait for the fix session to finish. **At most one new fix session per firing** —
  even if the count is well under 3, the dispatcher doesn't loop to fill the cap in one
  sitting; the hourly cadence fills it gradually. This keeps each firing's own logic and
  cost simple and matches the real backlog's low volume (§2).
- **Fix session** — a separate, decoupled session (also Cloud) that does the actual work:
  applies or writes the failing test (§8), fixes it, opens the PR, and babysits it to green
  using the same self-re-arming check-in pattern already proven in this environment — each
  check-in decides whether to schedule another one, until the PR merges, the 24-hour budget
  expires (§9), or it needs a human.

**Confirmed via a live probe (2026-08-10), not assumed.** Rather than build the dispatcher
around this and find out at dry-run time (the mistake Phase B's final review caught — an
unexercised happy path), a throwaway Cloud routine was created and fired with a trivial
prompt asking it to check for trigger-management tooling and attempt creating a child
trigger. Result: Cloud routines have `mcp__Claude_Code_Remote__create_trigger` (plus
`list_triggers`, `delete_trigger`, `update_trigger`, `fire_trigger`) available via a
`Claude_Code_Remote` MCP connector — present by default in the environment's `mcp_connections`,
not something that had to be explicitly requested. The probe's child-trigger creation call
succeeded (a real one-shot trigger was created and, confirmed separately, fired on its own
schedule). Both probe triggers were disabled afterward. The dispatcher and fix-session
prompts (§10, implementation) should reference these exact MCP tool names — not the
`RemoteTrigger` tool name this session uses locally, which is a different interface to the
same underlying capability.

## 5. Scoping pre-check

Because `🏭 Ready` doesn't guarantee Tier-1 size (§2), the dispatcher runs a cheap subagent
against each oldest-first candidate (up to 5 per firing) that judges: does this look like a
single, coherent, Tier-1-pathed change (docs / `Resources/Template/` / JS edit overlay /
portable SwiftPM target), or is it too large / wrong tier / ambiguous? This mirrors Stage 1's
own tier self-assessment in Phase B.

**A rejected candidate's labels are never touched.** "Not Tier-1-sized right now" is not a
`🏭 Blocked: human` verdict — it stays `🏭 Ready` for a human, or for a future phase that
widens the allowlist per the design doc's own rollout plan (§5: "Widen per evidence from
Phase A's audit").

## 6. Tracking factory-owned in-flight work without a bot identity

Phase A's finding still holds: every routine posts as the owner's own GitHub account, not a
distinct bot — so "a human claimed this" and "the factory claimed this" aren't
distinguishable by author alone. Rather than add another label (the parent design is
explicit about avoiding label sprawl), every factory-authored PR carries a required footer
marker, reusing the convention Phase B's report comments already use:

```
_Opened by the software factory (Phase C) — epic #1256._
```

The dispatcher's concurrency count (§4) is: **open PRs containing that exact marker.**
Auditable via GitHub PR search, no new label, no separate identity needed.

## 7. Attempt cap (2), via closed-not-merged factory PRs

Before claiming a candidate, the dispatcher searches **closed, not-merged** PRs carrying the
factory footer marker (§6) that reference the issue via a closing keyword:

- Zero such PRs → attempt 1.
- One → attempt 2; the fix session's dispatch note says so explicitly.
- Two → **do not claim.** Apply `🏭 Blocked: human` with a comment summarizing both failed
  attempts (linking both PRs) instead of launching a 3rd fix session.

This needs no new tracking state — it's derived entirely from GitHub's own PR history, the
same "labels + comments/PRs are the only state" principle the parent design already commits
to.

## 8. Test-basis handling (provenance-dependent)

The fix session checks whether the issue carries a `## Stage 1 — Reproduce report` comment
(Phase B's exact heading):

- **Present** (the issue came through Phase B): re-apply that comment's test diff, confirm it
  still fails on `main`, then fix until it passes. This directly satisfies issue #1261's
  "Stage 1's failing test must fail on main and pass on the PR" requirement, and lets the fix
  session start from Phase B's diagnosis report instead of re-deriving root cause from
  scratch.
- **Absent** (the issue went straight from intake to `🏭 Ready` — a feature or an
  already-understood simple bug): standard test-first. Write the test, confirm it fails, then
  implement.

## 9. Babysitting budget and hard rules

- **24-hour wall-clock budget.** If a factory PR's CI hasn't gone green within 24 hours of
  opening, the fix session closes it, releases `🛠️ In Progress`, and the attempt counts as
  failed (§7) — bounds cost and matches the real persistent-flake pattern already observed in
  this environment, where a CI issue unrelated to the PR's own diff, not the fix's quality,
  was what dragged out a babysitting chain.
- **Agents never merge.** No `gh pr merge`, no enabling GitHub auto-merge on a factory PR —
  the human merge gate from the parent design (§4.5) is untouched by this phase.
- **UX-affecting changes get `✅ Manual QA`**, applied at PR-open time with a note on what
  needs in-app verification.
- **MCP-schema discoveries abort cleanly.** If a fix session discovers mid-work that it needs
  to touch the MCP message schema (sidecar-owned surface per CLAUDE.md ▸ Two-repo
  coordination), it closes any draft, releases the claim, and routes the issue to
  `🏭 Blocked: human` — never a half-landed PR. This does not count as a failed attempt (§7)
  the way an MCP-schema discovery in Phase B's Tier 4 escalation doesn't burn a repro
  attempt — it's a scoping fact, not a quality failure.

## 10. Routine configuration

- **Dispatcher name:** `anglesite-factory-fix-dispatcher`
- **Execution mode:** Cloud (§3)
- **Schedule:** Hourly, matching Phase A's cadence (§4) — dispatcher firings are cheap
- **Concurrency cap:** 3 (§6)
- **Attempt cap:** 2 (§7)
- **Allowlist:** docs, `Resources/Template/`, JS edit overlay (`JS/edit-overlay/`), portable
  SwiftPM targets (`Package.swift`'s `portableTargets` set) — Tier 1 only, per issue #1261's
  own stated starting scope
  *(Widened since: `Sources/AnglesiteApp` + `AnglesiteContainer` on 2026-08-31, and
  `Workers/ControlWorker/` + `container/` with its image scripts on 2026-09-04 — see the
  operational updates in `docs/issue-fix-dispatcher-routine.md`.)*
- **Fix session:** launched per-claim via `RemoteTrigger` (§4), not a standing schedule of
  its own

The exact prompt text for both the dispatcher and the fix session is authored during
implementation and recorded in an operational-record doc, mirroring
`docs/issue-repro-diagnose-routine.md` for Phase B — this spec defines required behavior
(§4–§9), not literal wording.

## 11. Non-goals (this phase)

- **No Tier 2+ allowlist widening.** Starting conservative per issue #1261; widening is a
  future decision made with evidence from live factory PRs, not designed speculatively here.
- **No Stage-5 gap-issue filing** on attempt-cap exhaustion — Phase E isn't live yet.
  Exhausted attempts route to `🏭 Blocked: human` only, same deferral Phase B already made.
- **No dedicated bot/machine identity.** Carried forward from Phase A/B's finding; the
  footer-marker approach (§6) works without one.
- **No auto-merge, ever.** Not a deferred feature — an explicit, permanent hard rule (§9) per
  the parent design's human-merge-gate doctrine.

## 12. Verification plan

No application code path exists to exercise with `swift test`/`npm test` — this is routine
configuration plus prompts, the same situation as Phases A and B. Verification is:

- Careful review of both routine prompts (dispatcher and fix session) before enabling the
  dispatcher's schedule.
- A manual dry run of the dispatcher against the real backlog, confirming: the scoping
  pre-check correctly skips the WYSIWYG slices without touching their labels, correctly
  selects a genuinely Tier-1 candidate if one exists (or reports none available), and the
  `RemoteTrigger`-based fix-session launch mechanism actually works (§4's flagged
  assumption).
- A full dry run of one launched fix session through to an opened PR, confirming: the correct
  test-basis path is taken (§8), the footer marker is present, and the babysitting check-in
  chain self-arms correctly — before trusting the dispatcher's schedule unattended.

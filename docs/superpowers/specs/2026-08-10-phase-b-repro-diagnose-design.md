# Software factory Phase B — reproduce/diagnose stages for bug issues

**Date:** 2026-08-10
**Status:** Approved
**Tracking:** #1260 (epic #1256, design doc `docs/specs/2026-08-04-software-factory-design.md`
§4.2, §4.4)

## 1. Goal

Implement Phase B: turn `🏭 Needs repro` bug issues into a failing test plus a diagnosis,
with no fixing, before any fix agent (Phase C) touches them. Exit criteria (per #1260): a
bug issue can go from freshly-triaged to `🏭 Ready` with a failing test and diagnosis
attached, with no human involvement and no fix written.

## 2. Decision: a local Claude Routine, not a cloud one

Phase A's Stage 0 (intake triage) runs as a **cloud** Claude Routine because it only needs
`gh` API calls — no code execution. Phase B is different: Stage 1 (reproduce) has to
actually build and run this project's test suites, including `swift test` across
non-portable packages that need a real macOS/Xcode toolchain (the design doc's own Tier
table draws that line — see `docs/specs/2026-08-04-software-factory-design.md` §4.4). A
generic cloud sandbox is not guaranteed to have that toolchain at all; the owner's own Mac
definitely does.

Claude Routines support a **Local** execution mode (run via the local Claude Code app,
scheduled, while the machine is awake and online) as an alternative to the Cloud mode Phase
A used. This sidesteps the toolchain question entirely and, as a side benefit, the Local
routine creation UI has built-in git-worktree isolation (a checkbox), so this phase needs no
custom `launchd`/cron machinery or hand-rolled worktree setup — both were considered and
dropped once the native Local mode's capabilities were confirmed.

**Permissions:** the routine runs under "Settings default," which resolves to this
worktree's inherited configuration — global `defaultMode: auto` plus this repo's committed
`.claude/settings.json`, which already pre-approves `swift test`, `swift build`, and
`xcodebuild`. No new permission scoping is needed for Tier 1 or Tier 2 execution; this is
the same trust boundary interactive agent sessions already run under in this repo. Unlike
Phase A's cloud routine (which structurally withheld `Write`/`Edit` via a tool allowlist),
this routine has full file-write access by necessity (it has to create a test file) — the
"no fixing" boundary here is enforced by prompt instruction and by the fact that nothing it
writes is ever committed or pushed (§5), not by tool restriction.

## 3. Execution model: subagent-isolated stages, one routine

Cloudflare's phase-isolation bias guard (a diagnoser who reasoned their way to a repro is
subtly biased to defend that reasoning) is implemented as: one routine picks up an issue,
then internally spawns two independently-scoped subagents via the `Task`/`Agent` tool:

1. **Stage 1 (Reproduce) subagent** — given only the issue number. Reads the issue via `gh`,
   determines the affected tier/suite, writes a failing test, runs it, confirms the failure,
   and posts the Stage 1 report comment (§5). No fixing.
2. **Stage 2 (Diagnose) subagent** — given only the issue number, spawned fresh with **no
   memory of Stage 1's internal reasoning**. It re-reads the issue's comments (including the
   Stage 1 report just posted) as its sole input, root-causes, and posts the Stage 2 report.
   It never sees Stage 1's tool calls, dead-end hypotheses, or scratch notes — only what
   Stage 1 published. That's the actual isolation mechanism, not merely "a different
   prompt."

This keeps operations simple (one routine to schedule and monitor) while still honoring the
isolation the design calls for, since a subagent's context is a hard boundary regardless of
which top-level session spawned it.

**Issues per run: capped at 1.** Unlike Stage 0 (cheap, `gh`-only, took 10 per run), each
Phase B run does a real build+test cycle across two stages — potentially several minutes.
Taking one issue at a time keeps each firing bounded and avoids stacking overlapping runs.

## 4. Tier scope and toolchain handling

The routine attempts **Tier 1 and Tier 2** repro (portable SwiftPM/JS overlay/template, and
`swift test` across the rest of the package graph respectively) — Tier 3 (Xcode Cloud) isn't
stood up yet (Phase D) and Tier 4 (hosted app/UI) is explicitly out of scope for automated
repro per the parent design's routing rule.

Because this runs on the owner's own development Mac (§2), the toolchain-availability risk
that would apply to a cloud sandbox doesn't apply here — Xcode and the Swift toolchain are
already present, the same as in any interactive session in this repo. If a run nonetheless
hits an environment problem (e.g. a stale `.build` lock from another process, per the
existing CLAUDE.md troubleshooting note), that's treated the same as a Tier-4 discovery
(§6): it doesn't burn an attempt, and routes to `🏭 Blocked: human` with an explanation
rather than being silently retried into the same wall.

## 5. Report comment format

**Stage 1 — Reproduce**, posted as one issue comment:

```
## Stage 1 — Reproduce report

**Tier assessed:** 1 | 2
**Command:** `swift test --package-path . --filter <TestName>`
**Result:** FAILS on `main` (confirms the bug)

<details><summary>Test diff</summary>

​```diff
<the failing test, as a diff — never committed, shown as text only>
​```
</details>

**Failure output:**
​```
<relevant excerpt>
​```

**Repro steps (for a human):**
1. ...
```

**Stage 2 — Diagnose**, posted as a separate issue comment:

```
## Stage 2 — Diagnose report

**Root cause:** <one paragraph>
**Evidence:** <instrumentation notes, `file:line` references>
**Affected code path(s):** `file:line`, `file:line`
**Confidence:** high | medium | low
**Suggested fix direction (not a fix):** <1-2 sentences, non-binding — Stage 3 (Phase C) owns
the actual fix>
```

Both close with a footer identifying the stage and linking the parent epic, matching Phase
A's triage-comment convention (`docs/issue-intake-routine.md`).

The test diff is pasted as comment text only — it is never committed to a branch or pushed.
Stage 1/2 open no PR; the worktree the routine's platform creates for the run is discarded
afterward regardless of outcome.

## 6. Labels, claiming, and attempt caps

- **Claim at start, release at end:** the routine adds `🛠️ In Progress` before starting work
  on an issue (honoring the existing claim protocol against humans and other agents) and
  removes it when the run ends, whatever the outcome. Unlike a fix PR (which keeps the label
  until merge), there's nothing here to keep it in place *for* — no PR opens.
- **Attempt counting via comment history, not a new label:** an "attempt" is one full
  Stage-1(+2) pass that doesn't reach `🏭 Ready`. The routine counts existing
  `## Stage 1 — Reproduce report` comments it already posted on the issue to determine which
  attempt this is. No new pipeline state is introduced — consistent with the parent design's
  "labels + comments are the only state."
- **Cap: 2 attempts**, matching Phase C's fix-agent attempt cap for consistency. On the 2nd
  failure: `🏭 Blocked: human` plus a comment explaining why. Phase E's "gap issue" filing
  doesn't exist yet (Phase E isn't live), so exhausted attempts stop here — recorded as a
  deferred non-goal (§8), the same way Phase A recorded its own deferrals.
- **Environment or Tier-4 discoveries don't burn an attempt:** if Stage 1 discovers mid-repro
  that the issue actually needs a hosted app/UI (Tier 4), or hits an environment problem
  (§4), that's a scoping/infrastructure fact, not a failed attempt — straight to `🏭 Blocked:
  human`, attempt count untouched.
- **Success:** both stages complete → `🏭 Needs repro` flips to `🏭 Ready`.

## 7. Routine configuration

- **Name:** `anglesite-factory-repro-diagnose`
- **Description:** "Reproduce + diagnose bug issues labeled 🏭 Needs repro (software factory
  Phase B, epic #1256): writes a failing test, confirms it fails on main, root-causes with a
  fresh isolated subagent, and promotes the issue to 🏭 Ready — or routes to 🏭 Blocked: human
  if it can't."
- **Repo / branch:** this repo, `main`
- **Worktree:** checked (native isolation — see §2)
- **Permissions:** Settings default (see §2)
- **Schedule:** every 4 hours (custom) — a middle ground between Phase A's hourly cadence
  (too frequent for a real build+test cycle) and daily (slower than needed, since bug
  reports needing repro are a minority of the backlog per the Phase A audit)
- **Issues per run:** 1 (§3)

The exact Instructions text (the routine's prompt) is authored during implementation and
recorded in an operational-record doc, mirroring `docs/issue-intake-routine.md` for Phase A
— this spec defines its required behavior (§3–§6), not its literal wording.

## 8. Non-goals (this phase)

- **No Stage-5 gap-issue filing** on attempt-cap exhaustion — that's Phase E, not live yet.
  Exhausted attempts route to `🏭 Blocked: human` only.
- **No Tier 3/4 repro** — Xcode Cloud (Tier 3, Phase D) isn't stood up, and Tier 4 requires a
  hosted app/UI by definition; both route straight to `🏭 Blocked: human`.
- **No external repro-repo cloning or execution.** Anglesite's issues are mostly internal
  backlog, not third-party bug reports with attached repro repos (parent design §3.2). If
  Stage 1 finds it needs to run someone else's linked repository to reproduce, that's
  "can't reproduce with available tooling," not attempted — cloning and running arbitrary
  external code unattended on the owner's own Mac is a risk this phase deliberately doesn't
  take on.
- **No cross-run concurrency guard beyond the claim label.** A single Local routine on a
  fixed schedule is assumed not to overlap itself; this isn't hardened further.

## 9. Verification plan

No code path exists to exercise with `swift test`/`npm test` — this is a routine
configuration plus its prompt, same situation as Phase A. Verification is:

- Careful review of the routine's Instructions text and guardrails before enabling the
  4-hourly schedule.
- A manual dry run (triggering the routine once, on-demand) against a real `🏭 Needs repro`
  issue before trusting the unattended cadence — mirroring Phase A's dry-run discipline.
- Confirming the worktree the platform creates is actually cleaned up after the run (stated
  as an assumption in §3; verify during the dry run rather than trusting it blind).

# Generated docs index and `Status:` convention for design docs

**Status:** current
**Date:** 2026-09-03
**Issue:** [#1816](https://github.com/Anglesite/Anglesite/issues/1816)
**Related:** #1794 (stale architecture doc — same root cause: nothing says what is current)

## Problem

`docs/specs` (52 files), `docs/superpowers/specs` (185) and `docs/superpowers/plans`
(217) have no index and no machine-readable status. A reader opens files by
date-prefixed name to learn whether a spec is current, superseded, or an executed
plan that is now history. Two files are decision records in all but name and there
is no convention to find more. `CLAUDE.md` and friends point at individual specs by
path, which silently goes stale when a spec is superseded.

## Goals

1. A generated `docs/specs/README.md` and `docs/superpowers/README.md` listing date,
   title, linked issue(s) and status for every top-level `*.md` in those trees.
2. A script under `scripts/` that regenerates them, plus a `--check` mode that fails
   when a committed index is stale, wired into CI the same way as the Help Book link
   check (path-filtered lane, listed in the `ci` fan-in job).
3. A one-line `Status:` header convention with four tokens — `draft`, `current`,
   `superseded by …`, `historical` — that new files must use and that the generator
   also derives from the ~30 free-form spellings already in the tree.
4. Bulk-mark executed plans `historical`.
5. Name the two decision files as Architecture Decision Records (ADRs) without moving
   them, and record the convention in `CONTRIBUTING.md`.

## Non-goals

- Reclassifying the 150+ existing *specs* whose free-form status says "approved" but
  whose work has since shipped. Their truth is unknown without per-file archaeology;
  they render as `current` until someone flips them. Tracked as a follow-up.
- Renaming or moving any existing file (four inbound links plus git history would
  break for no reader benefit).
- YAML front matter. The tree uses bold `**Key:** value` header lines; the convention
  extends that instead of introducing a second metadata syntax.

## Design

### The script: `scripts/generate-docs-index.py`

Python 3 standard library only, executable, `#!/usr/bin/env python3`. A `.py` file
rather than the repo's usual bash-with-heredoc-python because the logic (parsing,
classification, table rendering, diffing) is the whole script, and a standalone file
can be unit-tested. Runs on the `ubuntu-latest` and macOS runners as-is (both ship
python3).

```
scripts/generate-docs-index.py            # rewrite both READMEs in place
scripts/generate-docs-index.py --check    # exit 1 if either README differs from
                                          # what would be generated; print the diff
```

Inputs: the top-level `*.md` files of `docs/specs/`, `docs/superpowers/specs/` and
`docs/superpowers/plans/`. Subdirectories (`docs/specs/assets/`,
`docs/superpowers/plans/harnesses/`) and the READMEs themselves are ignored.

Per-file extraction reads only the **header block** — everything before the first
`## ` heading — so a `Status:` mentioned in body prose never counts:

| Field | Source, in priority order |
|---|---|
| Date | `YYYY-MM-DD-` filename prefix; else a `**Date:**` header line; else `—` |
| Title | text of the first `# ` heading |
| Issue(s) | every `#NNN` on a header line keyed `Issue`, `Issues`, `Tracks`, `Tracking`, `Part of`, `Epic`, `Parent`; else the first `#NNN` in the H1; else the first `#NNN` anywhere in the header block; else `—` |
| Status | the header line matching `^\*{0,2}Status:?\*{0,2}\s*(.+)$`, classified (below); missing → `—` |
| Kind | `decision` when the filename ends `-decision.md` / `-decisions.md`; `plan` under `plans/`; else `spec` |

### Status classification

The convention's four tokens, and how free text maps onto them. Matching is
case-insensitive on the raw value; the first rule that fires wins:

| Token | Rule |
|---|---|
| `superseded by …` | value starts with `superseded`. The remainder is kept verbatim; if it names a `.md` path in the docs tree it is rendered as a relative link. |
| `historical` | contains any of: historical, shipped, implemented, merged, landed, done, complete, retired, abandoned, rejected, withdrawn |
| `draft` | contains any of: draft, proposed, proposal, wip, in progress, pending, open question |
| `current` | contains any of: current, approved, decided, accepted, active, ready, final, findings |
| `unclassified` | anything else — rendered as the first 40 characters of the raw value in italics so the oddity is visible in the index |

Ordering matters: "approved — implemented in #123" is `historical`, not `current`;
"approved design, pre-implementation" is `current`.

### Generated READMEs

Both files start with a comment naming the generator and the regenerate command, a
one-paragraph legend for the four status tokens, and then tables. Rows are sorted by
date descending (newest first), then filename. Issue numbers link to
`https://github.com/Anglesite/Anglesite/issues/N`. Titles link to the file relative to
the README. Pipe characters in titles are escaped.

- `docs/specs/README.md`: one **Decision records** table (kind = decision) followed by
  one **Specs, notes and plans** table for the rest.
- `docs/superpowers/README.md`: **Decision records**, then **Specs**
  (`superpowers/specs/`), then **Plans** (`superpowers/plans/`).

### `--check` mode

1. Regenerate both READMEs in memory and compare to the committed bytes; on any
   difference print a unified diff and `run scripts/generate-docs-index.py`, exit 1.
2. **Convention gate for new files:** any indexed file whose filename date is on or
   after `2026-09-04` (the day after this convention lands) with a missing or
   `unclassified` status is an error naming the file. Older files are exempt, so the
   gate never asks anyone to do archaeology on the backlog.
3. **Stale-pointer warning (non-fatal):** scan `CLAUDE.md`, `CONTRIBUTING.md`,
   `README.md` and `docs/*.md` for `docs/(specs|superpowers/(specs|plans))/…\.md`
   paths whose target is `superseded` and print a warning per hit. This is the
   issue's "pointer is not updated" case; it stays a warning because an intentional
   historical reference is legitimate.

### CI lane

In `.github/workflows/ci.yml`:

- `changes` job: new `docsIndex` output, true when a changed path matches
  `docs/specs/**`, `docs/superpowers/**`, `scripts/generate-docs-index.py`,
  `scripts/test-generate-docs-index.py` or the workflow file itself.
- New job `docs-index` (name "Docs index (specs/plans README + Status header)"),
  `ubuntu-latest`, 5-minute timeout, checkout then
  `python3 scripts/test-generate-docs-index.py` then
  `scripts/generate-docs-index.py --check`.
- `docs-index` added to the `ci` fan-in job's `needs` so the single required check
  covers it.

### Tests: `scripts/test-generate-docs-index.py`

`unittest`, run by the CI lane and by hand. Covers: status classification table
(each token, precedence, unclassified), issue extraction priority, header-block
boundary (a `Status:` after `## ` is ignored), decision-kind detection, a round trip
on a temporary docs tree (generate → `--check` passes → edit a file → `--check`
fails → regenerate → passes), and the new-file convention gate.

### Bulk `historical` marking of plans

One-off, done by hand in this PR (not a script mode — it never needs to run again).
Rule for each `docs/superpowers/plans/*.md` without a `Status:` line:

- an issue referenced in its header block, or in the subject of the commit that added
  the plan, is **closed**, or that commit is itself the feature PR's squash merge →
  `**Status:** historical` (the plan shipped with its implementation)
- the plan was added by a `docs(…)` commit and its issue is still **open** → check
  `git log --grep` for a later feature commit; `historical` if one landed, else
  `current`
- never implemented and replaced by a different approach → `superseded by <spec>`

Outcome: 211 plans `historical`, one `superseded by` (the #1699 layout-firewall plan,
replaced by the AppKit shell design), none `current`; the two plans that already had
a `Status:` line were left alone. The line is inserted immediately after the H1,
separated by a blank line, so it sits in the header block.

### ADR convention

An ADR is a spec whose filename ends `-decision.md` (or `-decisions.md` for a
decision *set*), lives in `docs/specs/` when project-wide or `docs/superpowers/specs/`
when scoped to one epic, and carries `**Status:** current` (accepted) or
`superseded by …`. The two existing files already match and need no rename; they
surface under **Decision records** in the generated READMEs.

### Documentation changes

- `CONTRIBUTING.md`: new "Design docs" subsection under "Before you start" — where
  specs/plans live, the `Status:` line, the regenerate command, the CI check, the ADR
  naming rule.
- `CLAUDE.md` (`AGENTS.md` is a symlink to it) ▸ "Plan": one sentence pointing at the
  two READMEs as the way to find out what is current.
- `.github/PULL_REQUEST_TEMPLATE.md`: unchanged. The CI lane is the reminder.

## Error handling

The generator fails loudly (non-zero, message to stderr) if a docs directory is
missing or a file has no H1; it never writes a partial README. `--check` never writes.

## Implementation steps

1. Script + tests, verified against the real tree.
2. Bulk-mark plans; generate both READMEs; commit.
3. CI lane; CONTRIBUTING and CLAUDE.md text.
4. Run `--check` clean; open the PR with the "current" plan exceptions listed.

## Follow-ups (not this PR)

- Flip shipped *specs* from free-form "approved" to `historical`, possibly by
  cross-referencing the closing PR of each linked issue.
- Teach the brainstorming/writing-plans skills to emit `**Status:** draft` so new
  files pass the convention gate without a manual edit.

#!/usr/bin/env python3
"""Generate (or check) the design-doc indexes for docs/specs and docs/superpowers (#1816).

Writes `docs/specs/README.md` and `docs/superpowers/README.md`: one table row per
top-level `*.md` under docs/specs, docs/superpowers/specs and docs/superpowers/plans,
with date, title, linked issue(s) and status. Subdirectories (assets, harnesses) and the
READMEs themselves are skipped.

    scripts/generate-docs-index.py            # rewrite both READMEs
    scripts/generate-docs-index.py --check    # exit 1 if either README is stale, or a
                                              # file dated >= CONVENTION_START has no
                                              # recognised Status line; never writes

Metadata comes from each file's *header block* — everything before the first `## `
heading — so a `Status:` mentioned in body prose never counts:

  Date    YYYY-MM-DD- filename prefix, else a `**Date:**` header line.
  Title   the first `# ` heading.
  Issues  every #NNN on a header line keyed Issue/Issues/Tracks/Tracking/Part of/
          Epic/Parent; else the first #NNN in the H1; else the first in the header.
  Status  the `Status:` header line, classified into the convention's four tokens —
          draft / current / superseded by … / historical — from the free-form spellings
          already in the tree (see classify_status). Missing renders as `—`.
  Kind    `decision` for `-decision(s).md` filenames (ADRs), `plan` under plans/, else spec.

Design: docs/superpowers/specs/2026-09-03-docs-index-and-status-convention-design.md.
Stdlib only; runs on the ubuntu and macOS CI runners as-is.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import difflib
import os
import re
import sys
from collections import namedtuple
from pathlib import Path

ISSUE_URL = "https://github.com/Anglesite/Anglesite/issues/{n}"

# Files dated on/after this must carry a recognised Status line (`--check` errors
# otherwise). Older files are exempt so the gate never demands backlog archaeology.
CONVENTION_START = _dt.date(2026, 9, 4)

# Each README and the doc directories (relative to the repo root) it indexes.
READMES = {
    "docs/specs/README.md": ["docs/specs"],
    "docs/superpowers/README.md": ["docs/superpowers/specs", "docs/superpowers/plans"],
}
PLANS_DIR = "docs/superpowers/plans"

# Agent/contributor instruction files scanned for pointers at superseded docs.
POINTER_FILES = ["CLAUDE.md", "CONTRIBUTING.md", "README.md"]

Status = namedtuple("Status", "token detail")
Entry = namedtuple("Entry", "path rel date title issues status kind")

_H1_RE = re.compile(r"^# (.+?)\s*$", re.M)
_H2_RE = re.compile(r"^## ", re.M)
_DATE_PREFIX_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})-")
_DATE_LINE_RE = re.compile(r"^\s*(?:[-*]\s+)?\*{0,2}Date:?\*{0,2}:?\s*(\d{4}-\d{2}-\d{2})", re.M)
_STATUS_LINE_RE = re.compile(r"^\s*(?:[-*]\s+)?\*{0,2}Status:?\*{0,2}:?\s*(.+?)\s*$", re.M)
_ISSUE_KEY_RE = re.compile(
    r"^\s*(?:[-*]\s+)?\*{0,2}(?:Issues?|Tracks|Tracking|Part of|Epic|Parent):?\*{0,2}:?\s*(.*)$",
    re.M,
)
_ISSUE_NUM_RE = re.compile(r"#(\d{1,6})\b")
_DOC_POINTER_RE = re.compile(r"docs/(?:specs|superpowers/(?:specs|plans))/[A-Za-z0-9._-]+\.md")

# Status classification, first match wins. Word-bounded so "already" isn't "ready".
_NEGATED_RE = re.compile(r"\b(?:not\s+(?:yet\s+)?|un)(?:implemented|shipped|merged|done|complete\w*)\b", re.I)
# "slice 1 landed", "Tasks 1–5 shipped", "snapshot step implemented": progress on part of
# the work, not the whole — such a doc is still the live reference, so it stays `current`.
_PARTIAL_RE = re.compile(
    r"\b(?:slices?|tasks?|phases?|steps?|parts?|stages?|half)\b[^.;]*?"
    r"\b(?:landed|shipped|merged|done|implemented|completed?)\b", re.I)
_HISTORICAL_RE = re.compile(
    r"\b(?:historical|shipped|implemented|merged|landed|done|completed?|retired|abandoned|rejected|withdrawn)\b", re.I)
_DRAFT_RE = re.compile(r"\b(?:draft|proposed|proposal|wip|in progress|pending|open question)\b", re.I)
_CURRENT_RE = re.compile(r"\b(?:current|approved|decided|accepted|active|ready|final|findings|design)\b", re.I)
_SUPERSEDED_PREFIX_RE = re.compile(r"^superseded\s*(?:by)?\s*[:\-—–]?\s*", re.I)


def classify_status(raw: str | None) -> Status:
    """Map a free-form Status value onto the convention's tokens.

    Precedence: superseded, then draft (a status that still says "pending" or "proposed"
    is unfinished whatever else it says), then historical (unless the completion word only
    qualifies part of the work), then current.
    """
    if raw is None:
        return Status("missing", None)
    value = raw.strip().rstrip(".")
    if re.match(r"superseded\b", value, re.I):
        return Status("superseded", _SUPERSEDED_PREFIX_RE.sub("", value).strip())
    probe = _NEGATED_RE.sub("", value)
    if _DRAFT_RE.search(probe):
        return Status("draft", None)
    if _HISTORICAL_RE.search(probe):
        return Status("current" if _PARTIAL_RE.search(probe) else "historical", None)
    if _CURRENT_RE.search(probe):
        return Status("current", None)
    return Status("unclassified", value)


def header_block(text: str) -> str:
    m = _H2_RE.search(text)
    return text[: m.start()] if m else text


def find_status(text: str) -> str | None:
    header = header_block(text)
    m = _STATUS_LINE_RE.search(header)
    if not m:
        return None
    value = m.group(1)
    if re.fullmatch(r"superseded\s*(?:by)?\s*[:\-—–]?", value, re.I):
        # Target wrapped onto the next line: `**Status:** Superseded by\n[`file`](…)`.
        rest = header[m.end():].lstrip("\n").split("\n", 1)[0].strip()
        value = f"{value} {rest}".strip()
    return value


def extract_issues(header: str, title: str) -> list[int]:
    found: list[int] = []
    for m in _ISSUE_KEY_RE.finditer(header):
        for n in _ISSUE_NUM_RE.findall(m.group(1)):
            if int(n) not in found:
                found.append(int(n))
    if found:
        return found
    m = _ISSUE_NUM_RE.search(title) or _ISSUE_NUM_RE.search(header)
    return [int(m.group(1))] if m else []


def kind_for(path: Path, root: Path) -> str:
    if re.search(r"-decisions?\.md$", path.name):
        return "decision"
    if path.parent.resolve() == (root / PLANS_DIR).resolve():
        return "plan"
    return "spec"


def date_for(filename: str, text: str) -> str:
    m = _DATE_PREFIX_RE.match(filename)
    if m:
        return m.group(1)
    m = _DATE_LINE_RE.search(header_block(text))
    return m.group(1) if m else ""


def parse_entry(path: Path, root: Path) -> Entry:
    text = path.read_text(encoding="utf-8")
    m = _H1_RE.search(text)
    if not m:
        raise ValueError(f"{path.relative_to(root)}: no '# ' heading")
    title = m.group(1)
    header = header_block(text)
    return Entry(
        path=path,
        rel=path.relative_to(root).as_posix(),
        date=date_for(path.name, text),
        title=title,
        issues=extract_issues(header, title),
        status=classify_status(find_status(text)),
        kind=kind_for(path, root),
    )


def collect(root: Path) -> dict[str, list[Entry]]:
    """{doc dir: entries}, newest first. Raises FileNotFoundError / ValueError."""
    out: dict[str, list[Entry]] = {}
    for dirs in READMES.values():
        for d in dirs:
            directory = root / d
            if not directory.is_dir():
                raise FileNotFoundError(f"{d} not found under {root}")
            entries = [
                parse_entry(p, root)
                for p in sorted(directory.iterdir())
                if p.is_file() and p.suffix == ".md" and p.name != "README.md"
            ]
            entries.sort(key=lambda e: (e.date == "", e.date), reverse=True)
            out[d] = sorted(entries, key=lambda e: (e.date, e.path.name), reverse=True)
    return out


def _escape(cell: str) -> str:
    return cell.replace("|", "\\|")


def _issue_links(issues: list[int]) -> str:
    return ", ".join(f"[#{n}]({ISSUE_URL.format(n=n)})" for n in issues) or "—"


def _status_cell(entry: Entry, readme_dir: Path, by_name: dict[str, Entry]) -> str:
    token, detail = entry.status
    if token == "superseded":
        # Flatten any markdown link / code span the author wrote (its relative path is
        # relative to the doc, not to the README) and keep the first clause only.
        rendered = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", detail or "").replace("`", "")
        rendered = re.split(r"\s+[—–-]\s+|;\s", rendered, 1)[0].strip()
        for name in re.findall(r"[A-Za-z0-9._-]+\.md", rendered):
            target = by_name.get(name)
            if target:
                link = os.path.relpath(target.path, readme_dir)
                rendered = rendered.replace(name, f"[{name}]({link})")
        rendered = _ISSUE_NUM_RE.sub(lambda m: f"[#{m.group(1)}]({ISSUE_URL.format(n=m.group(1))})", rendered)
        return f"superseded by {_escape(rendered)}".rstrip()
    if token == "unclassified":
        # Show the oddity, but flattened (a link cut mid-URL would break the table cell)
        # and short.
        flat = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", detail).replace("`", "").replace("*", "")
        if len(flat) > 40:
            flat = flat[:40].rsplit(" ", 1)[0] + "…"
        return f"_{_escape(flat)}_"
    if token == "missing":
        return "—"
    return token


def _table(entries: list[Entry], readme_dir: Path, by_name: dict[str, Entry]) -> str:
    lines = ["| Date | Title | Issue | Status |", "|---|---|---|---|"]
    for e in entries:
        link = os.path.relpath(e.path, readme_dir)
        lines.append(
            f"| {e.date or '—'} | [{_escape(e.title)}]({link}) | {_issue_links(e.issues)} "
            f"| {_status_cell(e, readme_dir, by_name)} |"
        )
    return "\n".join(lines)


_PREAMBLE = """<!-- Generated by scripts/generate-docs-index.py — do not edit by hand. Regenerate with
     `scripts/generate-docs-index.py`; CI's `docs-index` lane fails when this file is stale. -->
# {heading}

Index of the design documents in {dirs}. Metadata is read from each file's header
block (the lines before its first `##`). **Status** is the file's `Status:` line
normalised to the convention in `CONTRIBUTING.md` ▸ "Design docs":

- `draft` — being written or proposed, not yet agreed.
- `current` — agreed and still the reference for how things work or should work.
- `superseded by …` — replaced; the link says by what.
- `historical` — executed plan, retired design, or spike notes kept for the record.
- `—` — no `Status:` line (pre-convention file; add one when you next touch it).
"""


def render(readme_rel: str, dirs: list[str], collected: dict[str, list[Entry]], root: Path) -> str:
    readme_dir = (root / readme_rel).parent
    all_entries = [e for d in dirs for e in collected[d]]
    by_name = {e.path.name: e for e in collected_all(collected)}
    parts = [_PREAMBLE.format(
        heading=f"Design docs index — {Path(readme_rel).parent.as_posix()}",
        dirs=", ".join(f"`{d}/`" for d in dirs),
    )]
    decisions = [e for e in all_entries if e.kind == "decision"]
    decisions.sort(key=lambda e: (e.date, e.path.name), reverse=True)
    if decisions:
        parts.append("## Decision records\n\nArchitecture decision records (ADRs): specs named "
                     "`…-decision.md` / `…-decisions.md`.\n\n" + _table(decisions, readme_dir, by_name) + "\n")
    if len(dirs) == 1:
        rest = [e for e in all_entries if e.kind != "decision"]
        parts.append("## Specs, notes and plans\n\n" + _table(rest, readme_dir, by_name) + "\n")
    else:
        for d in dirs:
            rest = [e for e in collected[d] if e.kind != "decision"]
            heading = "Plans" if d == PLANS_DIR else "Specs"
            parts.append(f"## {heading}\n\n`{d}/`\n\n" + _table(rest, readme_dir, by_name) + "\n")
    return "\n".join(parts)


def collected_all(collected: dict[str, list[Entry]]) -> list[Entry]:
    return [e for entries in collected.values() for e in entries]


def generate(root: Path) -> dict[str, str]:
    collected = collect(root)
    return {rel: render(rel, dirs, collected, root) for rel, dirs in READMES.items()}, collected


def convention_violations(entries: list[Entry]) -> list[str]:
    bad = []
    for e in entries:
        if not e.date:
            continue
        try:
            dated = _dt.date.fromisoformat(e.date)
        except ValueError:
            continue
        if dated >= CONVENTION_START and e.status.token in ("missing", "unclassified"):
            what = "has no `Status:` line" if e.status.token == "missing" else \
                f"has an unrecognised Status ({e.status.detail!r})"
            bad.append(f"{e.rel}: {what}; files dated {CONVENTION_START} or later must use "
                       "draft / current / superseded by … / historical")
    return bad


def stale_pointers(root: Path, entries: list[Entry]) -> list[str]:
    superseded = {e.rel: e for e in entries if e.status.token == "superseded"}
    files = [root / f for f in POINTER_FILES] + sorted((root / "docs").glob("*.md"))
    hits = []
    for f in files:
        if not f.is_file():
            continue
        for lineno, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            for target in _DOC_POINTER_RE.findall(line):
                if target in superseded:
                    by = superseded[target].status.detail or "another document"
                    hits.append(f"{f.relative_to(root)}:{lineno}: points at superseded {target} "
                                f"(superseded by {by})")
    return hits


def main(argv: list[str] | None = None, root: Path | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true",
                        help="verify the committed READMEs are current instead of writing them")
    args = parser.parse_args(argv)
    root = (root or Path(__file__).resolve().parent.parent).resolve()

    try:
        rendered, collected = generate(root)
    except (FileNotFoundError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if not args.check:
        for rel, content in rendered.items():
            (root / rel).write_text(content, encoding="utf-8")
            print(f"wrote {rel}")
        return 0

    failed = False
    for rel, content in rendered.items():
        path = root / rel
        current = path.read_text(encoding="utf-8") if path.is_file() else ""
        if current != content:
            failed = True
            print(f"STALE: {rel} does not match the generated index:", file=sys.stderr)
            diff = difflib.unified_diff(current.splitlines(), content.splitlines(),
                                        f"a/{rel}", f"b/{rel}", lineterm="", n=1)
            print("\n".join(diff), file=sys.stderr)
    for msg in convention_violations(collected_all(collected)):
        failed = True
        print(f"error: {msg}", file=sys.stderr)
    for msg in stale_pointers(root, collected_all(collected)):
        print(f"warning: {msg}", file=sys.stderr)
    if failed:
        print("FAIL: run scripts/generate-docs-index.py and commit the result "
              "(and add a Status: line to any file named above).", file=sys.stderr)
        return 1
    print("OK: docs indexes are current.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

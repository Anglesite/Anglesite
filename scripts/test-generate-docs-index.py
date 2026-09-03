#!/usr/bin/env python3
"""Unit tests for scripts/generate-docs-index.py (#1816).

Run directly (`python3 scripts/test-generate-docs-index.py`) or via the CI `docs-index`
lane. Stdlib only. The generator's filename has hyphens, so it is loaded by path.
"""
import importlib.util
import io
import sys

sys.dont_write_bytecode = True  # keep scripts/__pycache__ out of the worktree
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("gdi", HERE / "generate-docs-index.py")
gdi = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gdi)


class ClassifyStatusTests(unittest.TestCase):
    def check(self, raw, token):
        self.assertEqual(gdi.classify_status(raw).token, token, raw)

    def test_convention_tokens(self):
        self.check("draft", "draft")
        self.check("current", "current")
        self.check("historical", "historical")
        self.check("superseded by 2026-09-01-foo-design.md", "superseded")

    def test_free_form_spellings_seen_in_tree(self):
        self.check("Approved design; ready for implementation planning.", "current")
        self.check("Decided", "current")
        self.check("owner-approved decision set, 2026-08-18. Pre-implementation.", "current")
        self.check("spike findings — answers the registration question", "current")
        self.check("Proposed", "draft")
        self.check("draft. Not yet implemented.", "draft")
        self.check("Approved design, implemented.", "historical")
        self.check("Implemented (PR #302, 2026-06-23)", "historical")
        self.check("Evaluation complete — recommendation: do not integrate yet", "historical")
        self.check("Approved (brainstorm)", "current")

    def test_precedence_superseded_then_draft_then_historical_then_current(self):
        self.check("Superseded by #1699 (approved earlier)", "superseded")
        self.check("approved — implemented in #123", "historical")
        self.check("approved draft", "draft")
        self.check("Static pass complete; live pass pending", "draft")
        self.check("Design approved, pending implementation plan", "draft")

    def test_partial_progress_stays_current(self):
        self.check("Approved 2026-09-01; **slice 1 landed and gate PASSED** (2026-09-01):", "current")
        self.check("sidecar Tasks 1–5 shipped and merged", "current")
        self.check("Decided; snapshot step implemented (#362, 2026-07-24)", "current")

    def test_superseded_detail_keeps_target(self):
        st = gdi.classify_status("superseded by 2026-09-01-site-window-appkit-shell-design.md")
        self.assertEqual(st.token, "superseded")
        self.assertEqual(st.detail, "2026-09-01-site-window-appkit-shell-design.md")

    def test_unclassified_and_missing(self):
        self.check("something nobody has written before", "unclassified")
        self.assertEqual(gdi.classify_status(None).token, "missing")

    def test_unclassified_cell_flattens_links_and_truncates_on_a_word(self):
        entry = gdi.Entry(Path("/r/x.md"), "x.md", "2026-01-01", "T", [],
                          gdi.Status("unclassified", "Elaborates [#800](https://x/800) (spec for the `client` and more words)"), "spec")
        cell = gdi._status_cell(entry, Path("/r"), {})
        self.assertEqual(cell, "_Elaborates #800 (spec for the client…_")
        self.assertNotIn("](", cell)


class HeaderParsingTests(unittest.TestCase):
    def test_header_block_stops_at_first_h2(self):
        text = "# T\n\n**Status:** draft\n\n## Body\n\n**Status:** current\n"
        self.assertNotIn("current", gdi.header_block(text))

    def test_status_line_forms(self):
        for line in ("**Status:** draft", "Status: draft", "- **Status:** draft"):
            with self.subTest(line=line):
                self.assertEqual(gdi.find_status(f"# T\n\n{line}\n"), "draft")

    def test_superseded_target_on_next_line(self):
        text = "# T\n\n**Status:** Superseded by\n[`2026-07-21-x-design.md`](../x.md) — split repo\n**Date:** 1\n"
        st = gdi.classify_status(gdi.find_status(text))
        self.assertEqual(st.token, "superseded")
        self.assertIn("2026-07-21-x-design.md", st.detail)

    def test_issue_priority_keyed_line_beats_h1_beats_anywhere(self):
        header = "# Foo (#11) plan\n\n**Related:** #22\n**Issue:** [#33](x), #44\n"
        self.assertEqual(gdi.extract_issues(header, "Foo (#11) plan"), [33, 44])
        header = "# Foo (#11) plan\n\n**Related:** #22\n"
        self.assertEqual(gdi.extract_issues(header, "Foo (#11) plan"), [11])
        header = "# Foo plan\n\n**Related:** #22 and #23\n"
        self.assertEqual(gdi.extract_issues(header, "Foo plan"), [22])
        self.assertEqual(gdi.extract_issues("# Foo\n", "Foo"), [])

    def test_kind_from_path(self):
        root = Path("/r")
        self.assertEqual(gdi.kind_for(root / "docs/specs/2026-01-01-x-decision.md", root), "decision")
        self.assertEqual(gdi.kind_for(root / "docs/superpowers/specs/2026-01-01-x-decisions.md", root), "decision")
        self.assertEqual(gdi.kind_for(root / "docs/superpowers/plans/2026-01-01-x.md", root), "plan")
        self.assertEqual(gdi.kind_for(root / "docs/superpowers/specs/2026-01-01-x-design.md", root), "spec")

    def test_date_from_filename_then_header(self):
        self.assertEqual(gdi.date_for("2026-05-26-x.md", "# T\n**Date:** 2020-01-01\n"), "2026-05-26")
        self.assertEqual(gdi.date_for("x.md", "# T\n**Date:** 2020-01-01\n"), "2020-01-01")
        self.assertEqual(gdi.date_for("x.md", "# T\n"), "")


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def make_tree(root: Path) -> None:
    write(root / "docs/specs/2026-06-29-c1-thing-decision.md",
          "# C.1: Decide the thing\n\n**Status:** Decided\n**Part of:** #340\n\n## Decision\n")
    write(root / "docs/specs/2026-06-23-inspector-design.md",
          "# Inspector\n\n**Status:** Superseded by\n[`#1099`](https://x/1099) — retired, leaving the\nrest\n\n## P\n")
    write(root / "docs/specs/2026-05-26-old-design.md",
          "# Old | design\n\n**Status:** approved — shipped in #31\n**Tracks:** [#31](u)\n\n## Motivation\n")
    write(root / "docs/superpowers/specs/2026-08-31-crash-design.md",
          "# Crash design\n\n**Status:** superseded by 2026-09-01-shell-design.md\n**Issue:** #1699\n\n## P\n")
    write(root / "docs/superpowers/specs/2026-09-01-shell-design.md",
          "# Shell design\n\n**Status:** current\n**Issue:** #1699\n\n## P\n")
    write(root / "docs/superpowers/plans/2026-09-02-shell-plan.md",
          "# Shell (#1699) Implementation Plan\n\n**Status:** historical\n\n**Goal:** x\n\n## Task 1\n")
    write(root / "docs/superpowers/plans/harnesses/gate.sh", "#!/bin/sh\n")
    write(root / "docs/specs/assets/x.svg", "<svg/>")
    write(root / "CLAUDE.md", "see docs/superpowers/specs/2026-08-31-crash-design.md and "
                              "docs/superpowers/specs/2026-09-01-shell-design.md\n")


def run(argv, root):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = gdi.main(argv, root=root)
    return code, out.getvalue(), err.getvalue()


class EndToEndTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        make_tree(self.root)

    def tearDown(self):
        self._tmp.cleanup()

    def test_generate_then_check_round_trip(self):
        code, _, err = run(["--check"], self.root)
        self.assertEqual(code, 1, err)  # nothing generated yet
        self.assertEqual(run([], self.root)[0], 0)
        code, _, err = run(["--check"], self.root)
        self.assertEqual(code, 0, err)
        # Editing an indexed file makes the committed index stale.
        write(self.root / "docs/superpowers/specs/2026-09-01-shell-design.md",
              "# Shell design, renamed\n\n**Status:** current\n\n## P\n")
        code, _, err = run(["--check"], self.root)
        self.assertEqual(code, 1)
        self.assertIn("generate-docs-index.py", err)
        self.assertEqual(run([], self.root)[0], 0)
        self.assertEqual(run(["--check"], self.root)[0], 0)

    def test_readme_contents(self):
        run([], self.root)
        specs = (self.root / "docs/specs/README.md").read_text()
        sp = (self.root / "docs/superpowers/README.md").read_text()
        self.assertIn("generate-docs-index.py", specs.splitlines()[0])
        self.assertIn("## Decision records", specs)
        self.assertIn("[C.1: Decide the thing](2026-06-29-c1-thing-decision.md)", specs)
        self.assertIn("Old \\| design", specs)
        self.assertIn("[#31](https://github.com/Anglesite/Anglesite/issues/31)", specs)
        self.assertIn("historical", specs)  # "shipped" classified
        self.assertNotIn("assets", specs)
        self.assertIn("## Specs", sp)
        self.assertIn("## Plans", sp)
        self.assertIn("(specs/2026-09-01-shell-design.md)", sp)
        self.assertIn("(plans/2026-09-02-shell-plan.md)", sp)
        self.assertIn("superseded by [2026-09-01-shell-design.md](specs/2026-09-01-shell-design.md)", sp)
        # A pre-existing link/code span in the target and a trailing clause are flattened.
        self.assertIn("superseded by [#1099](https://github.com/Anglesite/Anglesite/issues/1099) |", specs)
        self.assertNotIn("harnesses", sp)
        # Newest first within a table.
        self.assertLess(sp.index("2026-09-01-shell-design.md"), sp.index("2026-08-31-crash-design.md"))

    def test_new_file_without_status_fails_check(self):
        run([], self.root)
        write(self.root / "docs/superpowers/specs/2026-09-04-fresh-design.md", "# Fresh\n\n## P\n")
        run([], self.root)  # index is current again, only the gate can fail now
        code, _, err = run(["--check"], self.root)
        self.assertEqual(code, 1)
        self.assertIn("2026-09-04-fresh-design.md", err)
        self.assertIn("Status", err)

    def test_old_file_without_status_is_tolerated(self):
        write(self.root / "docs/superpowers/specs/2026-07-04-legacy-design.md", "# Legacy\n\n## P\n")
        run([], self.root)
        code, _, err = run(["--check"], self.root)
        self.assertEqual(code, 0, err)
        self.assertIn("| — |", (self.root / "docs/superpowers/README.md").read_text())

    def test_stale_pointer_is_a_warning_not_a_failure(self):
        run([], self.root)
        code, _, err = run(["--check"], self.root)
        self.assertEqual(code, 0)
        self.assertIn("warning", err)
        self.assertIn("2026-08-31-crash-design.md", err)
        self.assertNotIn("points at superseded docs/superpowers/specs/2026-09-01-shell-design.md", err)

    def test_missing_docs_dir_is_an_error(self):
        code, _, err = run([], self.root / "nope")
        self.assertEqual(code, 2)
        self.assertIn("error", err)


if __name__ == "__main__":
    unittest.main()

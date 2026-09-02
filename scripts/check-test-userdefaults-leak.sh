#!/usr/bin/env bash
# Fails if a `swift test` run left test `UserDefaults` suites behind (#1727).
#
# Every test suite that needs defaults goes through AnglesiteTestSupport's
# TemporaryUserDefaults, which persists the suite as a path-shaped domain inside a
# `$TMPDIR/test-anglesite-*` scratch directory and deletes that directory in cleanup().
# The in-suite assertions can only observe what happens while the test process is alive;
# whether cfprefsd writes a domain back out at process exit (the mechanism behind the
# original ~/Library/Preferences leak) is only visible from another process afterwards. So
# run this as a SEPARATE process after `swift test` has exited — CI does, in build-test.
#
# Two places are checked: the helper's scratch directory (a leftover means cleanup() did not
# run or did not work) and ~/Library/Preferences (a `test-anglesite-*.plist` there means a
# suite regressed to a plain `UserDefaults(suiteName:)` name, which cfprefsd never reclaims).
# On a Mac that still carries the pre-#1727 backlog, clear it once first:
#   rm ~/Library/Preferences/test-anglesite-*.plist
set -u

prefix="test-anglesite-"
# Same resolution order as Foundation's NSTemporaryDirectory(): $TMPDIR, else the per-user
# confstr directory (/var/folders/.../T/), else /tmp.
tmpdir="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp)}"
status=0

scratch=$(find "$tmpdir" -maxdepth 1 -name "${prefix}*" 2>/dev/null | sort)
if [ -n "$scratch" ]; then
  echo "::error title=Leaked test UserDefaults scratch suites::$(printf '%s\n' "$scratch" | wc -l | tr -d ' ') left in $tmpdir"
  printf '%s\n' "$scratch"
  status=1
fi

prefs="$HOME/Library/Preferences"
leaked=$(ls "$prefs" 2>/dev/null | grep "^${prefix}" | sort)
if [ -n "$leaked" ]; then
  echo "::error title=Test UserDefaults suites in ~/Library/Preferences::$(printf '%s\n' "$leaked" | wc -l | tr -d ' ') ${prefix}*.plist under $prefs (first 10 shown)"
  printf '%s\n' "$leaked" | head -10
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "OK: no ${prefix}* suites left in $tmpdir or $prefs"
fi
exit "$status"

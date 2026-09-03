#!/usr/bin/env bash
#
# Exercises scripts/prune-worktrees.sh against a throwaway git repo with
# stubbed `gh`, `lsof`, and `plutil`, so every safety branch runs without
# touching the real repo, real processes, or real DerivedData (#1461):
#
#   * merged+clean worktree      -> candidate, removed by --remove
#   * merged+dirty worktree      -> reported, removed ONLY with --force-dirty
#   * open-PR worktree           -> kept
#   * merged but live-cwd busy   -> skipped (the lsof safety check)
#   * orphaned dir (unregistered)-> candidate, rm -rf'd by --remove
#   * DerivedData with dead/live WorkspacePath -> removed / kept
#
# Runs in CI's linux-build-test lane (ci.yml) — every external dependency (gh, lsof,
# plutil) and the worktree/DerivedData fixtures above are stubbed or thrown away, so the
# script's real host-machine state is never touched. Run it locally after changing
# prune-worktrees.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/prune-worktrees.sh"

# Resolve symlinks (macOS /var -> /private/var) so paths match git's output.
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

overall_status=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; overall_status=1; }
assert_exists()  { [[ -e "$2" ]] && pass "$1" || fail "$1 (missing: $2)"; }
assert_gone()    { [[ ! -e "$2" ]] && pass "$1" || fail "$1 (still exists: $2)"; }
assert_output()  { grep -qF "$2" "$3" && pass "$1" || { fail "$1 (no match: $2)"; sed 's/^/  | /' "$3"; }; }

# ---- Fixture: main repo + worktrees -----------------------------------------

main="$tmp/main"
mkdir -p "$main"
git -C "$main" init -q -b main
git -C "$main" config user.email test@example.com
git -C "$main" config user.name "Prune Test"
echo hello >"$main/README.md"
mkdir -p "$main/scripts"
cp "$TARGET" "$main/scripts/prune-worktrees.sh"
git -C "$main" add -A
git -C "$main" commit -qm "init"

wt="$main/.claude/worktrees"
git -C "$main" worktree add -q "$wt/merged-clean" -b merged-clean
git -C "$main" worktree add -q "$wt/merged-dirty" -b merged-dirty
git -C "$main" worktree add -q "$wt/merged-busy"  -b merged-busy
git -C "$main" worktree add -q "$wt/open-pr"      -b open-pr
echo scratch >"$wt/merged-dirty/uncommitted.txt"
mkdir -p "$wt/orphan-dir"
echo leftover >"$wt/orphan-dir/junk.txt"

# ---- Fixture: DerivedData + stubs -------------------------------------------

home="$tmp/home"
dd="$home/Library/Developer/Xcode/DerivedData"
mkdir -p "$dd/Anglesite-stale" "$dd/Anglesite-forclean" "$dd/Anglesite-live"
# Stub plutil reads the WorkspacePath from a sibling .ws file, so the fixture
# needs no real binary plists (and the test runs on Linux too).
echo "$tmp/nonexistent-checkout"  >"$dd/Anglesite-stale/info.plist.ws";    touch "$dd/Anglesite-stale/info.plist"
echo "$wt/merged-clean"           >"$dd/Anglesite-forclean/info.plist.ws"; touch "$dd/Anglesite-forclean/info.plist"
echo "$main"                      >"$dd/Anglesite-live/info.plist.ws";     touch "$dd/Anglesite-live/info.plist"

stubs="$tmp/stubs"
mkdir -p "$stubs"

# gh: MERGED for merged-*, OPEN for open-pr, [] otherwise.
cat >"$stubs/gh" <<'STUB'
#!/usr/bin/env bash
branch=""
prev=""
for arg in "$@"; do
  [[ "$prev" == "--head" ]] && branch="$arg"
  prev="$arg"
done
case "$branch" in
  merged-*) echo '[{"state":"MERGED"}]' ;;
  open-pr)  echo '[{"state":"OPEN"}]' ;;
  *)        echo '[]' ;;
esac
STUB

# lsof: one fake live process whose cwd is inside merged-busy.
cat >"$stubs/lsof" <<STUB
#!/usr/bin/env bash
echo "p4242"
echo "cclaude"
echo "n$wt/merged-busy"
STUB

# plutil: print the sibling .ws file of the plist passed as the last argument.
cat >"$stubs/plutil" <<'STUB'
#!/usr/bin/env bash
plist="${@: -1}"
ws="$plist.ws"
[[ -f "$ws" ]] || exit 1
cat "$ws"
STUB

chmod +x "$stubs/gh" "$stubs/lsof" "$stubs/plutil"
run() { HOME="$home" PATH="$stubs:$PATH" bash "$main/scripts/prune-worktrees.sh" "$@"; }

# ---- Case 1: report-only deletes nothing, classifies everything -------------

echo "== report-only =="
run >"$tmp/report.log" 2>&1 || { fail "report run exited $?"; cat "$tmp/report.log"; }
assert_output "report: merged-clean is a candidate"       "CANDIDATE merged-clean"        "$tmp/report.log"
assert_output "report: merged-dirty needs --force-dirty"  "needs --force-dirty"           "$tmp/report.log"
assert_output "report: merged-busy skipped (live cwd)"    "SKIP      merged-busy"         "$tmp/report.log"
assert_output "report: busy skip names the process"       "pid 4242 (claude)"             "$tmp/report.log"
assert_output "report: open-pr kept"                      "keep      open-pr"             "$tmp/report.log"
assert_output "report: orphan-dir is a candidate"         "CANDIDATE orphan-dir"          "$tmp/report.log"
assert_output "report: stale DerivedData is a candidate"  "CANDIDATE DerivedData/Anglesite-stale" "$tmp/report.log"
assert_output "report: live DerivedData kept"             "keep      DerivedData/Anglesite-live"  "$tmp/report.log"
for d in merged-clean merged-dirty merged-busy open-pr orphan-dir; do
  assert_exists "report: $d untouched" "$wt/$d"
done
assert_exists "report: DerivedData untouched" "$dd/Anglesite-stale"

# ---- Case 2: --remove --yes honors every safety rail ------------------------

echo "== --remove --yes =="
run --remove --yes >"$tmp/remove.log" 2>&1 || { fail "remove run exited $?"; cat "$tmp/remove.log"; }
assert_gone   "remove: merged-clean removed"              "$wt/merged-clean"
assert_gone   "remove: orphan-dir removed"                "$wt/orphan-dir"
assert_exists "remove: merged-dirty kept (no --force-dirty)" "$wt/merged-dirty"
assert_exists "remove: merged-busy kept (live cwd)"       "$wt/merged-busy"
assert_exists "remove: open-pr kept"                      "$wt/open-pr"
assert_gone   "remove: stale DerivedData removed"         "$dd/Anglesite-stale"
assert_gone   "remove: freed worktree's DerivedData removed" "$dd/Anglesite-forclean"
assert_exists "remove: live DerivedData kept"             "$dd/Anglesite-live"
if git -C "$main" worktree list --porcelain | grep -q "merged-clean"; then
  fail "remove: merged-clean still registered in git worktree list"
else
  pass "remove: merged-clean deregistered"
fi

# ---- Case 3: --force-dirty removes the dirty-but-merged worktree ------------

echo "== --remove --yes --force-dirty =="
run --remove --yes --force-dirty >"$tmp/force.log" 2>&1 || { fail "force run exited $?"; cat "$tmp/force.log"; }
assert_gone   "force: merged-dirty removed"               "$wt/merged-dirty"
assert_exists "force: merged-busy still kept (live cwd)"  "$wt/merged-busy"
assert_exists "force: open-pr still kept"                 "$wt/open-pr"

echo
if [[ "$overall_status" -eq 0 ]]; then echo "PASS: all prune-worktrees.sh cases"; else echo "FAIL: see above"; fi
exit "$overall_status"

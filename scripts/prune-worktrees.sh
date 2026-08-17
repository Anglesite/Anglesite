#!/usr/bin/env bash
#
# Prune stale agent worktrees under .claude/worktrees/ and the orphaned Xcode
# DerivedData they leave behind (#1461).
#
# This repo runs every feature/agent task in its own worktree (AGENTS.md ▸
# "Worktrees"), and each worktree's distinct Anglesite.xcodeproj path also earns
# its own ~/Library/Developer/Xcode/DerivedData/Anglesite-* directory. Nothing
# reclaims either automatically — a 2026-08-13 audit found 141GB of stale
# worktrees plus 146GB of orphaned DerivedData. This script automates the manual
# cleanup procedure documented in AGENTS.md, including both safety checks:
#
#   1. Registered worktrees (in `git worktree list`) are candidates only when
#      their branch's PR is merged or closed (`gh pr list --head … --state all`).
#      Removal additionally requires a clean `git status --short`; a dirty
#      worktree whose PR is merged needs an explicit --force-dirty (never
#      `git worktree remove --force` by default).
#   2. Directories on disk but NOT in `git worktree list` (broken gitdir links
#      from a rename/relocation, or an interrupted removal) are plain leftover
#      directories — `git worktree remove` won't touch them — and are removed
#      with `rm -rf`.
#   3. EVERY candidate — registered or orphaned — must have no live process
#      holding it as a cwd (lsof check). Git status and PR state alone don't
#      reveal a live agent session using a worktree; skipping this check is
#      what caused the live-session collision that motivated this script.
#   4. DerivedData/Anglesite-* directories whose info.plist WorkspacePath no
#      longer exists on disk (including ones freed by this run's removals) are
#      stale and removed. Skipped off-macOS / without plutil.
#
# Report-only by default: prints candidates, reasons, and reclaimable size but
# deletes nothing. --remove performs deletions, confirming each candidate
# interactively; --yes skips the per-candidate confirmation.
#
# This is host-machine maintenance, not CI (CI runners have no long-lived
# worktree state). scripts/setup-dev-env.sh offers to run this report when the
# worktree count/size crosses a threshold. Local test: scripts/prune-worktrees.test.sh

set -euo pipefail

usage() {
    cat <<'EOF'
usage: scripts/prune-worktrees.sh [--remove] [--yes] [--force-dirty]

  (no flags)     report candidates and reclaimable size; delete nothing
  --remove       actually remove safe candidates (per-candidate confirmation)
  --yes          with --remove: skip the per-candidate confirmation prompt
  --force-dirty  with --remove: also remove worktrees with uncommitted changes
                 when their PR is MERGED (uses `git worktree remove --force`)
  -h, --help     show this help

Safety: a candidate is never touched while any live process has it as its cwd,
and a dirty worktree is never force-removed without --force-dirty.
EOF
}

REMOVE=0
ASSUME_YES=0
FORCE_DIRTY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --remove)      REMOVE=1 ;;
        --yes)         ASSUME_YES=1 ;;
        --force-dirty) FORCE_DIRTY=1 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Resolve the MAIN checkout even when this script runs from inside a worktree:
# --git-common-dir points at the main checkout's .git in both cases.
MAIN_ROOT=$(dirname "$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir)")
WORKTREES_DIR="$MAIN_ROOT/.claude/worktrees"
DERIVED_DATA_ROOT="$HOME/Library/Developer/Xcode/DerivedData"

# One lsof pass, cached: "cwd<TAB>pid<TAB>command" per live process. Used to
# refuse any candidate that is some process's current working directory.
LIVE_CWDS=$(lsof -d cwd -F pcn 2>/dev/null | awk '
    /^p/ { pid = substr($0, 2) }
    /^c/ { cmd = substr($0, 2) }
    /^n/ { printf "%s\t%s\t%s\n", substr($0, 2), pid, cmd }' || true)

# Prints "pid<TAB>command" lines for processes whose cwd is at/under $1;
# returns 1 (and prints nothing) when the directory is not in use.
live_users() {
    local dir="$1" found=1 cwd pid cmd
    while IFS=$'\t' read -r cwd pid cmd; do
        [[ -n "$cwd" ]] || continue
        if [[ "$cwd" == "$dir" || "$cwd" == "$dir"/* ]]; then
            printf '%s\t%s\n' "$pid" "$cmd"
            found=0
        fi
    done <<<"$LIVE_CWDS"
    return "$found"
}

# PR state for a branch: MERGED / CLOSED / OPEN / NONE / UNKNOWN (gh missing
# or the lookup failed — e.g. offline). UNKNOWN/NONE/OPEN are never candidates.
pr_state() {
    local branch="$1" out
    command -v gh >/dev/null 2>&1 || { echo UNKNOWN; return; }
    if ! out=$(gh pr list --head "$branch" --state all --json state --limit 1 </dev/null 2>/dev/null); then
        echo UNKNOWN
        return
    fi
    case "$out" in
        *MERGED*) echo MERGED ;;
        *CLOSED*) echo CLOSED ;;
        *OPEN*)   echo OPEN ;;
        *)        echo NONE ;;
    esac
}

size_kb() { du -sk "$1" 2>/dev/null | awk '{ print $1 }'; }

human() { # KB -> human string
    local kb="${1:-0}"
    if   [[ "$kb" -ge 1048576 ]]; then awk -v k="$kb" 'BEGIN { printf "%.1fGB", k / 1048576 }'
    elif [[ "$kb" -ge 1024 ]];    then awk -v k="$kb" 'BEGIN { printf "%.0fMB", k / 1024 }'
    else printf '%sKB' "$kb"
    fi
}

# $1 = prompt; honors --yes. Reads from /dev/tty (not stdin — the worktree
# loops feed stdin from a herestring); no terminal without --yes = no.
confirm() {
    [[ "$ASSUME_YES" -eq 1 ]] && return 0
    local ans
    if ! read -r -p "    $1 [y/N] " ans </dev/tty 2>/dev/null; then
        echo "    skipping (no interactive terminal; pass --yes to confirm removals)"
        return 1
    fi
    [[ "$ans" == [yY]* ]]
}

RECLAIMABLE_KB=0
RECLAIMED_KB=0
CANDIDATES=0
REMOVED=0

report_live_users() {
    while IFS=$'\t' read -r pid cmd; do
        echo "      in use by pid $pid ($cmd)"
    done <<<"$1"
}

echo "Worktrees root: $WORKTREES_DIR"
if [[ "$REMOVE" -eq 1 ]]; then echo "Mode: REMOVE"; else echo "Mode: report-only (pass --remove to delete)"; fi
echo

# ---- Phase 1: registered worktrees under .claude/worktrees/ -----------------

# Registered worktree paths, one per line (all of them, not just ours).
REGISTERED=$(git -C "$MAIN_ROOT" worktree list --porcelain | sed -n 's/^worktree //p')

if [[ -d "$WORKTREES_DIR" ]]; then
    while IFS= read -r wt; do
        case "$wt" in "$WORKTREES_DIR"/*) ;; *) continue ;; esac
        [[ -d "$wt" ]] || continue
        name=${wt#"$WORKTREES_DIR"/}

        branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
        if [[ -z "$branch" ]]; then
            echo "keep      $name — detached HEAD, no branch to check a PR for"
            continue
        fi

        state=$(pr_state "$branch")
        if [[ "$state" != "MERGED" && "$state" != "CLOSED" ]]; then
            echo "keep      $name — PR state: $state ($branch)"
            continue
        fi

        if users=$(live_users "$wt"); then
            echo "SKIP      $name — PR $state but a live process has it as cwd:"
            report_live_users "$users"
            continue
        fi

        dirty=$(git -C "$wt" status --short 2>/dev/null || echo "?? status-failed")
        force_this=""
        if [[ -n "$dirty" ]]; then
            if [[ "$state" != "MERGED" ]]; then
                echo "SKIP      $name — PR $state but has uncommitted changes; inspect manually:"
                echo "$dirty" | sed 's/^/        /'
                continue
            fi
            if [[ "$FORCE_DIRTY" -ne 1 ]]; then
                kb=$(size_kb "$wt")
                RECLAIMABLE_KB=$((RECLAIMABLE_KB + ${kb:-0}))
                CANDIDATES=$((CANDIDATES + 1))
                echo "CANDIDATE $name — PR MERGED but dirty ($(human "${kb:-0}")); needs --force-dirty:"
                echo "$dirty" | sed 's/^/        /'
                continue
            fi
            force_this="--force"
        fi

        kb=$(size_kb "$wt")
        RECLAIMABLE_KB=$((RECLAIMABLE_KB + ${kb:-0}))
        CANDIDATES=$((CANDIDATES + 1))
        echo "CANDIDATE $name — PR $state, ${dirty:+dirty (--force-dirty), }no live users ($(human "${kb:-0}"))"

        if [[ "$REMOVE" -eq 1 ]] && confirm "git worktree remove${force_this:+ --force} $name?"; then
            # shellcheck disable=SC2086 # force_this is empty or a single flag
            if git -C "$MAIN_ROOT" worktree remove $force_this "$wt"; then
                echo "REMOVED   $name"
                REMOVED=$((REMOVED + 1))
                RECLAIMED_KB=$((RECLAIMED_KB + ${kb:-0}))
            else
                echo "ERROR     $name — git worktree remove refused; inspect it manually"
            fi
        fi
    done <<<"$REGISTERED"
fi

# ---- Phase 2: orphaned directories (on disk, not in `git worktree list`) ----

if [[ -d "$WORKTREES_DIR" ]]; then
    for dir in "$WORKTREES_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        dir=${dir%/}
        if grep -qxF "$dir" <<<"$REGISTERED"; then
            continue
        fi
        name=${dir#"$WORKTREES_DIR"/}

        if users=$(live_users "$dir"); then
            echo "SKIP      $name — orphaned (not in \`git worktree list\`) but a live process has it as cwd:"
            report_live_users "$users"
            continue
        fi

        kb=$(size_kb "$dir")
        RECLAIMABLE_KB=$((RECLAIMABLE_KB + ${kb:-0}))
        CANDIDATES=$((CANDIDATES + 1))
        echo "CANDIDATE $name — orphaned directory, not a registered worktree ($(human "${kb:-0}"))"

        if [[ "$REMOVE" -eq 1 ]] && confirm "rm -rf $name?"; then
            rm -rf "$dir"
            echo "REMOVED   $name"
            REMOVED=$((REMOVED + 1))
            RECLAIMED_KB=$((RECLAIMED_KB + ${kb:-0}))
        fi
    done
fi

# Registered entries whose directory vanished out-of-band are harmless stale
# registrations; tidy them after removals.
if [[ "$REMOVE" -eq 1 ]]; then
    git -C "$MAIN_ROOT" worktree prune
fi

# ---- Phase 3: stale DerivedData (Anglesite-*) -------------------------------

# Runs AFTER the worktree phases so DerivedData belonging to a worktree removed
# in this run is already stale (its WorkspacePath no longer exists).
if ! command -v plutil >/dev/null 2>&1; then
    echo "note      skipping DerivedData scan — plutil not available (macOS-only phase)"
elif [[ ! -d "$DERIVED_DATA_ROOT" ]]; then
    echo "note      skipping DerivedData scan — $DERIVED_DATA_ROOT does not exist"
else
    for dd in "$DERIVED_DATA_ROOT"/Anglesite-*/; do
        [[ -d "$dd" ]] || continue
        dd=${dd%/}
        name=${dd#"$DERIVED_DATA_ROOT"/}

        ws=$(plutil -extract WorkspacePath raw -o - "$dd/info.plist" 2>/dev/null || true)
        if [[ -z "$ws" ]]; then
            echo "keep      DerivedData/$name — no readable WorkspacePath; not touching it"
            continue
        fi
        if [[ -e "$ws" ]]; then
            echo "keep      DerivedData/$name — workspace still exists ($ws)"
            continue
        fi

        kb=$(size_kb "$dd")
        RECLAIMABLE_KB=$((RECLAIMABLE_KB + ${kb:-0}))
        CANDIDATES=$((CANDIDATES + 1))
        echo "CANDIDATE DerivedData/$name — workspace gone: $ws ($(human "${kb:-0}"))"

        if [[ "$REMOVE" -eq 1 ]] && confirm "rm -rf DerivedData/$name?"; then
            rm -rf "$dd"
            echo "REMOVED   DerivedData/$name"
            REMOVED=$((REMOVED + 1))
            RECLAIMED_KB=$((RECLAIMED_KB + ${kb:-0}))
        fi
    done
fi

# ---- Summary ----------------------------------------------------------------

echo
if [[ "$REMOVE" -eq 1 ]]; then
    echo "Removed $REMOVED of $CANDIDATES candidate(s), reclaimed $(human "$RECLAIMED_KB")."
else
    echo "$CANDIDATES candidate(s), $(human "$RECLAIMABLE_KB") reclaimable."
    if [[ "$CANDIDATES" -gt 0 ]]; then
        echo "Nothing was deleted. To remove: scripts/prune-worktrees.sh --remove"
    fi
fi

#!/usr/bin/env zsh
#
# Build the chassis with each theme pack overlaid, so a pack that breaks
# `astro build` (or the pre/post-build checks) cannot land. Run from anywhere;
# requires the template's node_modules to be installed (npm ci/install first).
#
# Spec: docs/superpowers/specs/2026-07-31-curated-theme-ports-design.md §7.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${(%):-%x}")" && pwd)
TEMPLATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PACKS_DIR="$TEMPLATE_ROOT/packs"
REPORTS_DIR="$TEMPLATE_ROOT/reports/impeccable"

if [[ ! -d "$PACKS_DIR" ]] || [[ -z "$(ls -A "$PACKS_DIR" 2>/dev/null)" ]]; then
    echo "build-packs: no packs to build."
    exit 0
fi

if [[ ! -d "$TEMPLATE_ROOT/node_modules" ]]; then
    echo "build-packs: run npm install in $TEMPLATE_ROOT first." >&2
    exit 1
fi

rm -rf "$REPORTS_DIR"
mkdir -p "$REPORTS_DIR"

for pack_dir in "$PACKS_DIR"/*(/); do
    pack=$(basename "$pack_dir")
    target=$(mktemp -d)
    echo "==> Building chassis with pack: $pack"
    "$SCRIPT_DIR/scaffold.sh" --yes "$target"
    rsync -a "$pack_dir/src/" "$target/src/"
    [[ -f "$pack_dir/LICENSE" ]] && cp "$pack_dir/LICENSE" "$target/THEME-LICENSE"
    ln -s "$TEMPLATE_ROOT/node_modules" "$target/node_modules"
    (cd "$target" && npm run build)

    # Design-slop / drift detector (#1946 step 1): report-only experiment, no
    # exit-code gate — a finding must not fail this lane yet. Findings feed the
    # per-pack triage in the PR before any rule is promoted to a failing check
    # (#1946 step 2). Exit 1 means impeccable itself couldn't scan the target,
    # which is worth a loud warning even in report-only mode; exit 2 (findings)
    # and exit 0 (clean) are both just data.
    report="$REPORTS_DIR/$pack.json"
    set +e
    (cd "$target" && npx impeccable detect --json dist) >"$report" 2>"$REPORTS_DIR/$pack.stderr"
    impeccable_status=$?
    set -e
    if [[ "$impeccable_status" -eq 1 ]]; then
        echo "==> impeccable: $pack could not be scanned — see $REPORTS_DIR/$pack.stderr" >&2
    else
        count=$(grep -c '"antipattern"' "$report" || true)
        echo "==> impeccable: $pack — $count finding(s) (report: $report)"
    fi

    rm -rf "$target"
done

echo "==> All packs built."

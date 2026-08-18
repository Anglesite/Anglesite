#!/usr/bin/env bash
#
# Builds the Safari Web Extension's content script, background worker, and popup script from
# JS/safari-extension/ into Resources/SafariExtension/. Unlike Resources/edit-overlay/ (entirely
# generated), Resources/SafariExtension/ mixes tracked static files (manifest.json, popup.html,
# popup.css, images/) with these three generated .js files — only the generated files are
# gitignored (see .gitignore), so this script never needs to `mkdir -p` a destination that
# doesn't already exist in git.
#
# Best-effort like the other build scripts: if Node isn't available or the install fails, warn
# and exit 0 so the Xcode build keeps going.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
EXT_DIR="$REPO_ROOT/JS/safari-extension"
DEST_DIR="$REPO_ROOT/Resources/SafariExtension"

if [[ ! -d "$EXT_DIR" ]]; then
    echo "warning: $EXT_DIR missing — skipping Safari extension build." >&2
    exit 0
fi

NPM=""
if command -v npm >/dev/null 2>&1; then
    NPM="$(command -v npm)"
else
    echo "warning: no npm found on PATH. Skipping Safari extension build." >&2
    exit 0
fi

cd "$EXT_DIR"

if [[ ! -x "$EXT_DIR/node_modules/.bin/esbuild" ]]; then
    echo "==> Installing JS/safari-extension dependencies"
    if ! "$NPM" ci --prefer-offline --no-audit --no-fund 2>&1; then
        echo "warning: npm ci failed — skipping Safari extension build." >&2
        exit 0
    fi
fi

echo "==> Type-checking JS/safari-extension"
"$NPM" run typecheck

echo "==> Building Safari extension → ${DEST_DIR#"$REPO_ROOT"/}/{content-script,background,popup}.js"
"$NPM" run build

for name in content-script background popup; do
    bytes=$(wc -c < "$DEST_DIR/$name.js" | tr -d '[:space:]')
    echo "  $name.js (${bytes} bytes)"
done

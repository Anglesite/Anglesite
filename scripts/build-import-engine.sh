#!/usr/bin/env bash
#
# Builds JS/import-engine/'s injected entry point into Resources/ImportEngine/import-engine.js,
# mirroring scripts/build-safari-extension.sh's structure. Unlike Resources/SafariExtension/
# (mixed tracked static files + generated .js), Resources/ImportEngine/ is entirely
# generated — same as Resources/wysiwyg-engine/ — so this script `mkdir -p`s a destination
# that git never tracks (see .gitignore).
#
# Best-effort like the other build scripts: if Node isn't available or the install fails, warn
# and exit 0 so the Xcode build keeps going.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
EXT_DIR="$REPO_ROOT/JS/import-engine"
DEST_DIR="$REPO_ROOT/Resources/ImportEngine"

mkdir -p "$DEST_DIR"

if [[ ! -d "$EXT_DIR" ]]; then
    echo "warning: $EXT_DIR missing — skipping import engine build." >&2
    exit 0
fi

NPM=""
if command -v npm >/dev/null 2>&1; then
    NPM="$(command -v npm)"
else
    echo "warning: no npm found on PATH. Skipping import engine build." >&2
    exit 0
fi

cd "$EXT_DIR"

if [[ ! -x "$EXT_DIR/node_modules/.bin/esbuild" ]]; then
    echo "==> Installing JS/import-engine dependencies"
    if ! "$NPM" ci --prefer-offline --no-audit --no-fund 2>&1; then
        echo "warning: npm ci failed — skipping import engine build." >&2
        exit 0
    fi
fi

echo "==> Type-checking JS/import-engine"
"$NPM" run typecheck

echo "==> Building import engine → ${DEST_DIR#"$REPO_ROOT"/}/import-engine.js"
"$NPM" run build

bytes=$(wc -c < "$DEST_DIR/import-engine.js" | tr -d '[:space:]')
echo "Import engine bundle: $DEST_DIR/import-engine.js (${bytes} bytes)"

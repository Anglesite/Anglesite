#!/usr/bin/env bash
# scripts/build-wysiwyg-engine.sh
#
# Builds JS/wysiwyg-engine/'s host mount entry point into
# Resources/wysiwyg-engine/engine.js, mirroring scripts/build-overlay.sh exactly. Best-effort:
# if Node isn't available or the install fails, warn and exit 0 so the Xcode build keeps going —
# WYSIWYGCanvasController logs the absence at runtime and edit mode just stays unavailable.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ENGINE_DIR="$REPO_ROOT/JS/wysiwyg-engine"
DEST_DIR="$REPO_ROOT/Resources/wysiwyg-engine"

mkdir -p "$DEST_DIR"

if [[ ! -d "$ENGINE_DIR" ]]; then
    echo "warning: $ENGINE_DIR missing — skipping wysiwyg-engine build." >&2
    exit 0
fi

NPM=""
if command -v npm >/dev/null 2>&1; then
    NPM="$(command -v npm)"
else
    echo "warning: no npm found on PATH. Skipping wysiwyg-engine build." >&2
    exit 0
fi

cd "$ENGINE_DIR"

if [[ ! -x "$ENGINE_DIR/node_modules/.bin/esbuild" ]]; then
    echo "==> Installing JS/wysiwyg-engine dependencies"
    if ! "$NPM" ci --prefer-offline --no-audit --no-fund 2>&1; then
        echo "warning: npm ci failed — skipping wysiwyg-engine build." >&2
        exit 0
    fi
fi

echo "==> Type-checking JS/wysiwyg-engine"
"$NPM" run typecheck

echo "==> Building wysiwyg-engine → ${DEST_DIR#"$REPO_ROOT"/}/engine.js"
"$NPM" run build

bytes=$(wc -c < "$DEST_DIR/engine.js" | tr -d '[:space:]')
echo "WYSIWYG engine bundle: $DEST_DIR/engine.js (${bytes} bytes)"

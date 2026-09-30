#!/usr/bin/env bash
#
# Builds an EmDash site the way the app scaffolds one (#2050), so a change to the template or to
# its EmDash overlay (Resources/Template/emdash/) that breaks a server-rendered EmDash site fails
# CI instead of the owner's first build.
#
# Mirrors SiteScaffolder for an EmDash site: scaffold.sh copies the template, the starter entries
# are removed (EmDashScaffold.removeStarterContent), the template's astro.config.ts is renamed and
# the overlay is copied on top (EmDashScaffold.applyTemplateOverlay). Then `npm ci` against the
# overlay's lockfile and the site's own `npm run build:ci`: the build, then the pre-deploy gate in
# --strict mode, whose server-rendered checks (#2055 slice 2) must pass on a clean EmDash site.
#
# Usage: scripts/check-emdash-overlay.sh [work-dir]   (default: a fresh temp dir, removed on exit)

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMPLATE="$REPO_ROOT/Resources/Template"
OVERLAY="$TEMPLATE/emdash"

if [[ $# -ge 1 ]]; then
    WORK="$1"
    mkdir -p "$WORK"
else
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
fi
SITE="$WORK/Source"
rm -rf "$SITE"

zsh "$TEMPLATE/scripts/scaffold.sh" --yes "$SITE"

[[ ! -e "$SITE/emdash" ]] || { echo "scaffold.sh copied the EmDash overlay into a plain site" >&2; exit 1; }

for collection in "$SITE"/src/content/*/; do
    find "$collection" -mindepth 1 -delete
    : > "$collection/.gitkeep"
done

# EmDashScaffold refuses an overlay containing a symbolic link; so does this check.
if [[ -n "$(find "$OVERLAY" -type l -not -path '*/node_modules/*' -print -quit)" ]]; then
    echo "the EmDash overlay contains a symbolic link" >&2
    exit 1
fi

mv "$SITE/astro.config.ts" "$SITE/astro.anglesite.config.ts"
# Must match EmDashScaffold.overlaySkippedNames (top level only, hence the leading slash);
# EmDashOverlayTemplateTests fails if they drift apart.
rsync -a \
    --exclude='/README.md' \
    --exclude='/node_modules' \
    --exclude='/dist' \
    --exclude='/.astro' \
    --exclude='/.wrangler' \
    --exclude='/.DS_Store' \
    "$OVERLAY/" "$SITE/"

cd "$SITE"
git init -q
npm ci --no-audit --no-fund
npm run build:ci

# The article routes render on request, so they must not be prerendered files.
[[ ! -e dist/client/articles/index.html ]] || { echo "the article index was prerendered" >&2; exit 1; }
[[ -f dist/server/entry.mjs ]] || { echo "no server bundle at dist/server/entry.mjs" >&2; exit 1; }
# anglesite-gate is registered in code, so its id and its policy code (loaded from the site's own
# scripts/emdash-gate/, not a stale copy) are always in the server bundle.
grep -rqs '"anglesite-gate"' dist/server || { echo "anglesite-gate is not registered in the server bundle" >&2; exit 1; }
grep -rqs 'decidePublish' dist/server || { echo "anglesite-gate's policy is not in the server bundle" >&2; exit 1; }
# The deploy gate must refuse this same build once the gate is gone from it.
[[ -f dist/anglesite-build.json ]] || { echo "no build manifest at dist/anglesite-build.json" >&2; exit 1; }
echo '{"version":1,"gateModules":{},"vendoredClientChunks":[]}' > dist/anglesite-build.json
if npx tsx scripts/pre-deploy-check.ts --json --strict; then
    echo "the pre-deploy gate passed a server build without the publish gate" >&2
    exit 1
fi
echo "✓ EmDash overlay site built"

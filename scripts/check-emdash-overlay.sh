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
# The built site is then booted on workerd with a local D1 (scripts/check-emdash-gate-runtime.mjs,
# #2089) to prove `anglesite-gate` fires there: a draft with a secret in it is refused with the
# gate's reason, and a clean one publishes.
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
# A distinctive .site-config value the runtime check looks for on a page the Worker renders:
# the Worker has no site files, so it can only get there through the server bundle (#2133).
printf 'PWA_THEME_COLOR=#213300\n' >> .site-config
npm ci --no-audit --no-fund
npm run build:ci

# The article routes render on request, so they must not be prerendered files.
[[ ! -e dist/client/articles/index.html ]] || { echo "the article index was prerendered" >&2; exit 1; }
# So do the routes that list articles (#2133): the feeds, the article sitemap and the tag pages.
# The sitemap index and the page sitemap list no articles, so they stay prerendered.
for route in rss.xml atom.xml feed.json articles/rss.xml articles/atom.xml articles/feed.json \
    sitemap-articles.xml tags/index.html; do
    [[ ! -e "dist/client/$route" ]] || { echo "dist/client/$route was prerendered; it must render on request" >&2; exit 1; }
done
for route in sitemap.xml sitemap-pages.xml; do
    [[ -f "dist/client/$route" ]] || { echo "dist/client/$route is missing; it should be prerendered" >&2; exit 1; }
done
[[ -f dist/server/entry.mjs ]] || { echo "no server bundle at dist/server/entry.mjs" >&2; exit 1; }
# anglesite-gate is registered in code, so its id and its policy code (loaded from the site's own
# scripts/emdash-gate/, not a stale copy) are always in the server bundle.
grep -rqs '"anglesite-gate"' dist/server || { echo "anglesite-gate is not registered in the server bundle" >&2; exit 1; }
grep -rqs 'decidePublish' dist/server || { echo "anglesite-gate's policy is not in the server bundle" >&2; exit 1; }
# The render backstop is in the server bundle (the manifest lists every gate source it holds).
# (`gateModules` is BuildManifest's field in scripts/anglesite-build-manifest.ts.)
node -e 'const m = JSON.parse(require("fs").readFileSync("dist/anglesite-build.json", "utf8"));
  if (typeof m.gateModules !== "object" || m.gateModules === null) { console.error("the build manifest has no gateModules"); process.exit(1); }
  if (!m.gateModules["scripts/emdash-gate/render-backstop.ts"]) { console.error("the render backstop is not in the server bundle"); process.exit(1); }'
# The deploy gate must refuse this same build once the gate is gone from it, and for that reason:
# any other failure (a crash, a bad import) would also exit non-zero, so the report is checked.
[[ -f dist/anglesite-build.json ]] || { echo "no build manifest at dist/anglesite-build.json" >&2; exit 1; }
node -e 'const m = JSON.parse(require("fs").readFileSync("dist/anglesite-build.json", "utf8"));
  if (m.gateRegistered !== true) { console.error("the build manifest does not record the gate as registered"); process.exit(1); }'
# The gate is in the bundle; now prove it fires. Boots this build (astro preview on workerd, a
# local D1 as `DB`) and publishes through EmDash's content API: a secret-bearing draft must be
# cancelled with the gate's reason, a clean one must go live (#2089).
node "$REPO_ROOT/scripts/check-emdash-gate-runtime.mjs" "$SITE"
echo '{"version":1,"gateModules":{},"gateRegistered":false,"vendoredClientChunks":[]}' > dist/anglesite-build.json
report=$(npx tsx scripts/pre-deploy-check.ts --json --strict || true)
echo "$report"
REPORT="$report" node -e 'const r = JSON.parse(process.env.REPORT);
  const missing = r.failures.filter((f) => f.category === "publish-gate-missing").length;
  // One per REQUIRED_GATE_MODULES source (gate checks, policy, plugin, render backstop), plus
  // the missing registration.
  if (r.ok !== false || missing !== 5) {
    console.error(`expected the gate to be refused with 5 publish-gate-missing failures, got ok=${r.ok}, ${missing}`);
    process.exit(1);
  }'
echo "✓ the pre-deploy gate refuses the build without the publish gate"

# Workers Caching (#2116). The build above had no Worker config, as in local development, so it
# must not have Cloudflare's route-cache provider (its `astro-version:` tag prefix marks it in the
# bundle: `VERSION_TAG_PREFIX` in @astrojs/cloudflare's src/cache/provider.ts, upstream at
# https://github.com/withastro/astro/blob/main/packages/integrations/cloudflare/src/cache/provider.ts),
# or EmDash would purge a cache the Worker doesn't have. If the adapter renames the prefix, the
# provider-present check below fails, so the rename can't make this check pass by accident. A Workers Paid site's config
# (`EmDashWorkerConfig.toml(…, cache: true)`) turns the provider on, and the adapter carries the
# setting into the deployed config.
cache_provider_bundled() { grep -rqs 'astro-version:' dist/server; }
! cache_provider_bundled || { echo "the route cache is on without a Worker config that enables it" >&2; exit 1; }
printf 'name = "emdash-overlay-check"\nmain = "./src/worker.ts"\ncompatibility_date = "2026-07-15"\ncompatibility_flags = ["nodejs_compat"]\n\n[cache]\nenabled = true\n' > wrangler.toml
npm run build
cache_provider_bundled || { echo "a Worker config with [cache] enabled = true didn't turn the route cache on" >&2; exit 1; }
node -e 'const c = JSON.parse(require("fs").readFileSync("dist/server/wrangler.json", "utf8"));
  if (c.cache?.enabled !== true) { console.error("the deployed Worker config does not enable caching"); process.exit(1); }'
sed -i.bak 's/^enabled = true$/enabled = false/' wrangler.toml && rm -f wrangler.toml.bak
npm run build
! cache_provider_bundled || { echo "a Worker config with [cache] enabled = false still turned the route cache on" >&2; exit 1; }
rm wrangler.toml
echo "✓ the route cache follows the Worker config's [cache] table"
echo "✓ EmDash overlay site built"

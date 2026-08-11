#!/usr/bin/env bash
# Shared staging step for scripts that build Containers/anglesite-dev/Dockerfile (the app's
# local dev-server image), whichever tool builds it (Apple `container` CLI or podman).
#
# Stages the MCP sidecar (from the sibling Anglesite plugin repo) and the website template's dependency
# manifests into the build context, and registers a cleanup trap so the staged, gitignored
# copies don't linger after the build. Source this file, then call stage_dev_image_context "$CTX".
#
# The EXIT trap it registers runs in the *caller's* shell (this function is sourced, not
# subshelled) and overwrites any EXIT trap already set there — fine today since both callers
# invoke this exactly once and set no other EXIT trap, but worth remembering if a future caller
# needs its own EXIT cleanup too.

# Dependency-free "x.y.z" >= "x.y.z" compare — no jq, no `sort -V` (BSD sort on macOS, this
# script's only supported platform, doesn't have it). Non-numeric/missing components read as 0,
# which is fine for the plain release-tag versions this repo's sidecar actually publishes.
_version_ge() {
    local IFS=.
    local -a a=($1) b=($2)
    local i ai bi
    for i in 0 1 2; do
        ai="${a[i]:-0}"; bi="${b[i]:-0}"
        [[ "$ai" =~ ^[0-9]+$ ]] || ai=0
        [[ "$bi" =~ ^[0-9]+$ ]] || bi=0
        (( ai > bi )) && return 0
        (( ai < bi )) && return 1
    done
    return 0
}

# Fails loud if the sidecar checkout at $1's package.json declares a version older than $2
# ("x.y.z"). Without this, a too-old sidecar checkout bakes a broken MCP path into the staged
# image — the container still boots and serves the preview, so nothing else here would catch
# the mismatch before a `tools/call` 400s at runtime.
require_min_sidecar_version() {
    local sidecar_src="$1" min_version="$2" pkg_json="$1/package.json" found
    found="$(grep -m1 '"version"[[:space:]]*:' "$pkg_json" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
    if [[ -z "$found" ]]; then
        echo "ERROR: could not read a \"version\" field from $pkg_json" >&2
        exit 1
    fi
    if ! _version_ge "$found" "$min_version"; then
        echo "ERROR: MCP sidecar checkout at $sidecar_src is v$found, but the app requires >= v$min_version." >&2
        echo "       (MCP 2026-07-28 stateless protocol, #1277 — an older sidecar 400s every tools/call.)" >&2
        echo "       Update the checkout, e.g.:" >&2
        echo "         git -C '$sidecar_src' fetch --tags && git -C '$sidecar_src' checkout v$min_version" >&2
        exit 1
    fi
}

stage_dev_image_context() {
    local ctx="$1"
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    # Honor $ANGLESITE_SIDECAR_SRC for the MCP-server source boundary. The sibling
    # checkout remains the published Anglesite plugin; ANGLESITE_PLUGIN_SRC remains
    # a compatibility alias for existing local development environments.
    local default_sidecar_src="$(cd "$root/.." && pwd)/anglesite"
    local sidecar_src="${ANGLESITE_SIDECAR_SRC:-${ANGLESITE_PLUGIN_SRC:-$default_sidecar_src}}"

    if [[ ! -d "$sidecar_src" ]]; then
        echo "ERROR: MCP sidecar source not found at $sidecar_src" >&2
        echo "       Set ANGLESITE_SIDECAR_SRC or clone github.com/Anglesite/anglesite-skills as a sibling directory named 'anglesite'." >&2
        exit 1
    fi
    if [[ ! -f "$sidecar_src/server/index.mjs" || ! -f "$sidecar_src/package.json" ]]; then
        echo "ERROR: $sidecar_src does not look like an Anglesite MCP sidecar" >&2
        echo "       Expected server/index.mjs and package.json." >&2
        exit 1
    fi

    # MCPClient/HTTPTransport dropped the initialize/Mcp-Session-Id handshake for the MCP
    # 2026-07-28 stateless spec (#1277, PR #1377) and now send every request session-free. A
    # sidecar older than v1.9.0 (sidecar #432) still runs the sessionful StreamableHTTPServerTransport,
    # which 400s a client that never sends `initialize` — the container boots and previews fine,
    # only the MCP path silently breaks. Since this staged image is a gitignored local build
    # artifact (never rebuilt automatically), a checkout that predates this requirement would
    # otherwise bake that mismatch into the image with no signal until a `tools/call` fails at
    # runtime. Matches the CI sidecar pin in .github/workflows/ci.yml — bump both together.
    require_min_sidecar_version "$sidecar_src" "1.9.0"

    local sidecar_stage="$ctx/mcp-sidecar"
    echo "Staging MCP sidecar from $sidecar_src → $sidecar_stage"
    rm -rf "$sidecar_stage"
    mkdir -p "$sidecar_stage"

    # Copy the sidecar's server/ directory + package manifests (no node_modules, no .git).
    rsync -a --delete \
        --exclude='node_modules/' \
        --exclude='.git/' \
        "$sidecar_src/server/" "$sidecar_stage/server/"
    cp "$sidecar_src/package.json" "$sidecar_stage/"
    cp "$sidecar_src/package-lock.json" "$sidecar_stage/"

    echo "Sidecar staged: $(ls "$sidecar_stage")"

    # Stage the website template's dependency manifests + the hydrate script into the build
    # context, so the image can bake the template's full node_modules (design §5b, same pattern
    # as container/Dockerfile). hydrate.sh is shared with the Cloudflare image —
    # container/hydrate.sh is the single source.
    local template_stage="$ctx/template"
    echo "Staging template manifests from $root/Resources/Template → $template_stage"
    rm -rf "$template_stage"
    mkdir -p "$template_stage"
    cp "$root/Resources/Template/package.json" "$template_stage/"
    cp "$root/Resources/Template/package-lock.json" "$template_stage/"
    cp "$root/container/hydrate.sh" "$ctx/hydrate.sh"

    # Clean up the staged sidecar + template + hydrate script on exit (success or failure) so
    # they don't accumulate in the build context. These are gitignored. The trap body is built
    # as a string with the paths substituted now — `local`s go out of scope with this function's
    # stack frame, so a trap naming them by variable (rather than value) would see them unbound
    # by the time EXIT actually fires.
    trap "rm -rf '$sidecar_stage' '$template_stage' '$ctx/hydrate.sh'" EXIT
}

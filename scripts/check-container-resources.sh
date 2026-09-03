#!/usr/bin/env bash
#
# Build-time guard for the vendored container boot artifacts.
#
# `Resources/container-{image,kernel,initfs}/` are gitignored and populated by
# scripts/vendor-container-image.sh (image) and scripts/vendor-container-kernel.sh
# (kernel + initfs). They ship into the app via SwiftPM `.copy()` resources on
# AnglesiteContainer, so an unvendored tree (fresh clone, new worktree, git clean)
# still BUILDS fine — the app only fails at runtime, when preview reports
# "imageLayoutNotProvisioned; kernelNotProvisioned; initfsNotProvisioned"
# (BundledImage.swift). This script surfaces that gap at build time instead.
#
# The checks mirror BundledImage.swift's provisioning markers exactly — the dirs
# always exist (each keeps a committed .gitkeep so the `.copy()` rule never
# breaks), so presence of the real artifact files is what "provisioned" means:
#   container-image/index.json    (OCI layout — vendor-container-image.sh)
#   container-kernel/vmlinux      (kernel binary — vendor-container-kernel.sh)
#   container-initfs/index.json   (vminit OCI layout — vendor-container-kernel.sh)
#
# Beyond presence, the kernel/initfs (not the locally-built image — #616 scope) are also
# digest-checked against scripts/container-artifact-versions.lock.json: a present-but-wrong
# artifact (stale cache, corrupted download, tampered override) is exactly the failure presence
# checks alone can't catch. An entry with no pin recorded yet (lock value "null") is never
# treated as an error here — only a lock/artifact *mismatch* is, at the same Debug-warn/
# Release-error severity as a missing file below. This also settles #616's open question on env
# overrides in Release: they stay allowed, but a Release build now digest-checks the *overridden*
# path too, same severity as the default path — a stale/wrong override fails Release exactly like
# a stale/wrong vendored artifact would.
#
# Policy: Debug builds WARN (Xcode issue-navigator warnings, build continues) —
# a fresh worktree must stay buildable for work that never boots a container.
# Release builds FAIL — an archive without boot artifacts ships an app whose
# local-container preview can never work, and nothing downstream would catch it.
# Set ANGLESITE_ALLOW_UNPROVISIONED_CONTAINER=1 to downgrade a Release failure
# to a warning (e.g. exercising the Release configuration without vendoring).
#
# Lines prefixed `warning:` / `error:` are parsed by Xcode into real build issues.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
RESOURCES="$REPO_ROOT/Resources"
source "$SCRIPT_DIR/lib/artifact-lock.sh"
source "$SCRIPT_DIR/lib/mcp-protocol-version.sh"

# Appends to `missing` iff the lock has a real pin for $1 that disagrees with $2 (the digest/hash
# just computed from the on-disk artifact). Silent no-op when unpinned ("null") — see comment
# above. $3 is the human-readable label used in the failure message.
check_digest() {
    local jq_path="$1" actual="$2" label="$3"
    local expected
    expected="$(lock_get "$jq_path")"
    [[ "$expected" == "null" || -z "$expected" ]] && return 0
    if [[ "$actual" != "$expected" ]]; then
        missing+=("$label digest mismatch — expected $expected (pinned in scripts/container-artifact-versions.lock.json), got $actual. Re-vendor, or if this bump is intentional, re-run scripts/vendor-container-kernel.sh --update-lock.")
    fi
}

# The saved OCI layout's index.json may be reformatted/repackaged relative to what the registry
# served (see the matching comment in vendor-container-kernel.sh), so this doesn't hash the file —
# it confirms the pinned manifest digest (a unique-enough hex string) is referenced somewhere
# inside it, which is robust to exactly how `container image save` chose to shape the layout.
check_vminit_layout() {
    local index_json="$1" label="$2"
    local expected
    expected="$(lock_get '.vminit.arm64_manifest_digest')"
    [[ "$expected" == "null" || -z "$expected" ]] && return 0
    if ! grep -q "${expected#sha256:}" "$index_json" 2>/dev/null; then
        missing+=("$label does not reference the pinned vminit manifest digest $expected (scripts/container-artifact-versions.lock.json). Re-vendor, or if this bump is intentional, re-run scripts/vendor-container-kernel.sh --update-lock.")
    fi
}

# Appends to `missing` iff the vendored image's protocol-version stamp (vendor-manifest.json,
# written by vendor-container-image.sh) is missing or disagrees with this app build's current
# MCPClient.protocolVersion. Unlike check_digest above, there is no external pin to compare
# against — the image is a non-deterministic local build (#616 excluded it from digest-pinning
# for exactly that reason) — so this checks the stamp against the app's own live source of truth
# instead. A missing stamp (image vendored before this check existed) is flagged the same as a
# mismatch: both mean the bundled sidecar's MCP protocol support is unverified (#1407).
check_mcp_protocol_stamp() {
    local manifest="$1" label="$2"
    local expected actual
    expected="$(mcp_protocol_version)"
    if [[ ! -f "$manifest" ]]; then
        missing+=("$label has no vendor-manifest.json (vendored before the MCP-protocol staleness check existed) — re-run scripts/vendor-container-image.sh so the bundled sidecar matches MCP-Protocol-Version $expected.")
        return
    fi
    # `|| true`: under `set -e`/pipefail, a manifest with no mcpProtocolVersion field would make
    # grep exit 1 and abort the whole script instead of falling through to the missing+=() below.
    actual="$(grep -m1 '"mcpProtocolVersion"' "$manifest" | sed -E 's/.*"mcpProtocolVersion"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')" || true
    if [[ "$actual" != "$expected" ]]; then
        missing+=("$label was vendored for MCP protocol $actual but this app build now expects $expected — re-run scripts/vendor-container-image.sh, or the local preview's MCP handshake will fail with an opaque HTTP error.")
    fi
}

# Per-artifact runtime overrides (BundledImage honors these at runtime, so a dev
# running against external artifacts shouldn't be nagged about unvendored dirs).
# Mirror BundledImage.swift exactly: a set override still gets its own
# file-existence check, not a free pass — a stale/mistyped override must fail
# here too, or this guard can't be trusted (it would print "provisioned — OK"
# and pass a Release build that still hits NotProvisioned at runtime).
missing=()

if [[ -n "${ANGLESITE_CONTAINER_IMAGE:-}" ]]; then
    if [[ ! -f "$ANGLESITE_CONTAINER_IMAGE/index.json" ]]; then
        missing+=("ANGLESITE_CONTAINER_IMAGE=$ANGLESITE_CONTAINER_IMAGE has no index.json — fix or unset the override")
    else
        check_mcp_protocol_stamp "$ANGLESITE_CONTAINER_IMAGE/vendor-manifest.json" "ANGLESITE_CONTAINER_IMAGE"
    fi
elif [[ ! -f "$RESOURCES/container-image/index.json" ]]; then
    missing+=("Resources/container-image is unvendored (no index.json) — run scripts/vendor-container-image.sh")
else
    check_mcp_protocol_stamp "$RESOURCES/container-image/vendor-manifest.json" "Resources/container-image"
fi

if [[ -n "${ANGLESITE_CONTAINER_KERNEL:-}" ]]; then
    if [[ ! -f "$ANGLESITE_CONTAINER_KERNEL" ]]; then
        missing+=("ANGLESITE_CONTAINER_KERNEL=$ANGLESITE_CONTAINER_KERNEL does not exist — fix or unset the override")
    else
        check_digest '.kata.vmlinux_sha256' "$(sha256_of "$ANGLESITE_CONTAINER_KERNEL")" "ANGLESITE_CONTAINER_KERNEL vmlinux"
    fi
elif [[ ! -f "$RESOURCES/container-kernel/vmlinux" ]]; then
    missing+=("Resources/container-kernel is unvendored (no vmlinux) — run scripts/vendor-container-kernel.sh")
else
    check_digest '.kata.vmlinux_sha256' "$(sha256_of "$RESOURCES/container-kernel/vmlinux")" "Resources/container-kernel/vmlinux"
fi

if [[ -n "${ANGLESITE_CONTAINER_INITFS:-}" ]]; then
    if [[ ! -f "$ANGLESITE_CONTAINER_INITFS/index.json" ]]; then
        missing+=("ANGLESITE_CONTAINER_INITFS=$ANGLESITE_CONTAINER_INITFS has no index.json — fix or unset the override")
    else
        check_vminit_layout "$ANGLESITE_CONTAINER_INITFS/index.json" "ANGLESITE_CONTAINER_INITFS layout"
    fi
elif [[ ! -f "$RESOURCES/container-initfs/index.json" ]]; then
    missing+=("Resources/container-initfs is unvendored (no index.json) — run scripts/vendor-container-kernel.sh")
else
    check_vminit_layout "$RESOURCES/container-initfs/index.json" "Resources/container-initfs layout"
fi

if [[ ${#missing[@]} -eq 0 ]]; then
    echo "==> Container boot artifacts provisioned — OK"
    exit 0
fi

# Release archives must not ship without boot artifacts; everything else warns.
severity="warning"
if [[ "${CONFIGURATION:-Debug}" == "Release" && "${ANGLESITE_ALLOW_UNPROVISIONED_CONTAINER:-0}" != "1" ]]; then
    severity="error"
fi

for m in "${missing[@]}"; do
    echo "$severity: $m" >&2
done
echo "$severity: local-container preview will fail at runtime with 'NotProvisioned' until the vendor scripts above are run (see BundledImage.swift)." >&2

if [[ "$severity" == "error" ]]; then
    echo "       To build Release anyway (NOT for distribution), set ANGLESITE_ALLOW_UNPROVISIONED_CONTAINER=1." >&2
    exit 1
fi
exit 0

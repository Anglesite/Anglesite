#!/usr/bin/env bash
#
# Bootstrap / verify a development environment for this repo, on macOS or Linux.
#
# macOS — full app development: Xcode 27+, XcodeGen (Anglesite.xcodeproj is gitignored
# and generated from project.yml), the auto-regen git hooks, and optionally Node for
# the JS edit overlay.
#
# Linux — cross-platform port work (2026-07-08 design, Linux first): a Swift 6.3+
# toolchain for the portable SwiftPM targets. No Xcode, XcodeGen, or Node required.
# Known wrinkle: distros shipping libxml2 ≥ 2.15 (e.g. Ubuntu 26.04) provide
# libxml2.so.16, but the swift.org toolchain's libFoundationXML links libxml2.so.2 —
# this script creates a user-level soname shim (no sudo needed) and prints the
# LD_LIBRARY_PATH export that activates it.
#
# Check-and-fix: fixes what it safely can (soname shim, xcodegen generate, git hooks)
# and prints actionable instructions for the rest.
# Exit 0 = ready for this platform's development flow. Exit 1 = blocking gap remains.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

FAILURES=0
ok()   { printf '  \342\234\223 %s\n' "$1"; }
todo() { printf '  \342\234\227 %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
note() { printf '    %s\n' "$1"; }

# Both platforms: the git hooks keep generated state in sync after pulls/switches
# (on macOS they regenerate the .xcodeproj). Harmless to enable everywhere.
setup_git_hooks() {
    if [[ "$(git -C "$REPO_ROOT" config core.hooksPath || true)" == "scripts/git-hooks" ]]; then
        ok "git hooks (core.hooksPath = scripts/git-hooks)"
    else
        git -C "$REPO_ROOT" config core.hooksPath scripts/git-hooks
        ok "git hooks enabled (core.hooksPath = scripts/git-hooks)"
    fi
}

setup_macos() {
    echo "Platform: macOS (full app development)"

    if xcodebuild -version >/dev/null 2>&1; then
        XCODE_MAJOR=$(xcodebuild -version | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
        if [[ "${XCODE_MAJOR:-0}" -ge 27 ]]; then
            ok "Xcode ${XCODE_MAJOR} (need 27+)"
        else
            todo "Xcode 27+ required (found ${XCODE_MAJOR:-unknown}) — needed for Swift 6.4 / SwiftUI 27 @State semantics"
        fi
    else
        todo "Xcode not found — install Xcode 27+ from the App Store or developer.apple.com"
    fi

    if command -v xcodegen >/dev/null 2>&1; then
        if [[ -d "$REPO_ROOT/Anglesite.xcodeproj" ]]; then
            ok "Anglesite.xcodeproj present (regenerate anytime with: xcodegen generate)"
        else
            (cd "$REPO_ROOT" && xcodegen generate >/dev/null)
            ok "Anglesite.xcodeproj generated from project.yml"
        fi
    else
        todo "XcodeGen not found — brew install xcodegen (the .xcodeproj is gitignored and generated from project.yml)"
    fi

    setup_git_hooks

    # Node is only needed to rebuild the JS edit overlay (scripts/build-overlay.sh);
    # the app itself embeds no host Node (#70). Warn-only.
    if command -v node >/dev/null 2>&1; then
        ok "Node $(node --version) (used by scripts/build-overlay.sh for the edit overlay)"
    else
        note "Node not found — only needed if you work on JS/edit-overlay (see scripts/node-version.txt)"
    fi

    if [[ -d "$REPO_ROOT/../anglesite" ]]; then
        ok "sibling Anglesite plugin checkout found (../anglesite) — MCP e2e tests can run (ANGLESITE_PLUGIN_PATH)"
    else
        note "sibling Anglesite plugin repo not found at ../anglesite — MCP e2e tests will skip cleanly (optional)"
    fi

    echo
    echo "Build:  open Anglesite.xcodeproj   (not \`xed .\`) — or:"
    echo "        xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build"
    echo "Tests:  swift test"
}

setup_linux() {
    echo "Platform: Linux (portable core — cross-platform port, Linux-first)"

    if command -v swift >/dev/null 2>&1; then
        SWIFT_VERSION=$(swift --version 2>/dev/null | sed -n 's/^Swift version \([0-9.]*\).*/\1/p' | head -1)
        SWIFT_MINOR=$(printf '%s' "${SWIFT_VERSION:-0}" | awk -F. '{ printf "%d%02d", $1, $2 }')
        if [[ "${SWIFT_MINOR:-0}" -ge 603 ]]; then
            ok "Swift ${SWIFT_VERSION} (need 6.3+)"
        else
            todo "Swift 6.3+ required (found ${SWIFT_VERSION:-unknown}) — swiftly install latest"
        fi
    else
        todo "Swift toolchain not found — install swiftly, then a toolchain:"
        note "curl -O https://download.swift.org/swiftly/linux/swiftly-\$(uname -m).tar.gz && tar zxf swiftly-*.tar.gz && ./swiftly init"
        note "swiftly install latest"
    fi

    # libxml2 soname shim: the swift.org toolchain's libFoundationXML.so links
    # libxml2.so.2; distros with libxml2 >= 2.15 (Ubuntu 26.04+) ship libxml2.so.16
    # and no compat package. A user-level symlink satisfies the loader — the API
    # subset FoundationXML uses survived the soname bump. Loader warnings about
    # "no version information" are expected and harmless.
    SHIM_DIR="$HOME/.local/lib/anglesite-shims"
    if ldconfig -p 2>/dev/null | grep -qF 'libxml2.so.2 '; then
        ok "libxml2.so.2 present (no shim needed)"
    else
        # `|| true`: under set -e/pipefail a failed pipeline inside $() aborts the whole
        # script (e.g. ldconfig not on a non-root PATH); fall through to the todo below instead.
        LIBXML2_NEW=$(ldconfig -p 2>/dev/null | awk '/libxml2\.so\.[0-9]+ /{ print $NF; exit }' || true)
        if [[ -n "$LIBXML2_NEW" ]]; then
            mkdir -p "$SHIM_DIR"
            ln -sf "$LIBXML2_NEW" "$SHIM_DIR/libxml2.so.2"
            ok "libxml2 soname shim created: $SHIM_DIR/libxml2.so.2 -> $LIBXML2_NEW"
            note "activate it for every swift invocation:"
            note "export LD_LIBRARY_PATH=\"$SHIM_DIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\""
            note "(add that line to your shell profile)"
        else
            todo "libxml2 not found — install your distro's libxml2 runtime package"
        fi
    fi

    setup_git_hooks

    if command -v podman >/dev/null 2>&1; then
        ok "podman $(podman --version | awk '{ print $NF }') (needed for the Linux MVP site runtime)"
        note "provision the dev-server image PodmanContainerControl expects: scripts/build-podman-image.sh"
    else
        note "podman not found — not needed for the purity phase; required later for PodmanSiteRuntime (Linux MVP)"
    fi

    echo
    if [[ "$FAILURES" -eq 0 ]] && command -v swift >/dev/null 2>&1; then
        echo "Smoke build (portable targets)…"
        if (cd "$REPO_ROOT" && LD_LIBRARY_PATH="$SHIM_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" swift build --target AnglesiteSiteModel 2>&1 | tail -1); then
            ok "swift build --target AnglesiteSiteModel"
        else
            todo "smoke build failed — see output above"
        fi
    fi

    echo
    echo "Build:  swift build          (portable targets only — Package.swift filters off-Darwin;"
    echo "                              AnglesiteSiteModel, AnglesiteQuickLookSupport, AnglesiteCore)"
    echo "Tests:  swift test"
}

# Worktree hygiene (#1461): .claude/worktrees/ and per-worktree DerivedData
# accumulate silently (a 2026-08-13 audit found 287GB combined). When the
# count/size crosses a threshold, surface it here and OFFER the prune report —
# setup never deletes anything itself; scripts/prune-worktrees.sh only removes
# with an explicit --remove and its own per-candidate safety checks.
WORKTREE_COUNT_THRESHOLD=5
WORKTREE_SIZE_GB_THRESHOLD=20
check_worktree_hygiene() {
    # Resolve the MAIN checkout — when setup runs from inside a worktree, the
    # worktrees root lives beside the main checkout's .git, not this one.
    local main_root wt_dir count size_kb size_gb
    main_root=$(dirname "$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)")
    wt_dir="$main_root/.claude/worktrees"
    [[ -d "$wt_dir" ]] || return 0
    count=$(find "$wt_dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    [[ "$count" -gt 0 ]] || return 0
    size_kb=$(du -sk "$wt_dir" 2>/dev/null | awk '{ print $1 }')
    size_gb=$(( ${size_kb:-0} / 1048576 ))

    echo
    if [[ "$count" -le "$WORKTREE_COUNT_THRESHOLD" && "$size_gb" -lt "$WORKTREE_SIZE_GB_THRESHOLD" ]]; then
        ok "worktree hygiene: $count worktree dir(s), ~${size_gb}GB (thresholds: >$WORKTREE_COUNT_THRESHOLD or ≥${WORKTREE_SIZE_GB_THRESHOLD}GB)"
        return 0
    fi

    echo "Worktree hygiene: $count dir(s) under .claude/worktrees/ (~${size_gb}GB) — over the" \
         ">$WORKTREE_COUNT_THRESHOLD/≥${WORKTREE_SIZE_GB_THRESHOLD}GB threshold."
    note "stale worktrees (merged PRs, orphaned dirs) and their DerivedData can be pruned safely:"
    note "report:  scripts/prune-worktrees.sh"
    note "remove:  scripts/prune-worktrees.sh --remove   (per-candidate confirmation; never forced)"
    if [[ -t 0 && -t 1 ]]; then
        local ans
        read -r -p "  Run the prune report now (read-only, deletes nothing)? [y/N] " ans
        if [[ "$ans" == [yY]* ]]; then
            "$SCRIPT_DIR/prune-worktrees.sh" || true
        fi
    fi
}

case "$(uname -s)" in
    Darwin) setup_macos ;;
    Linux)  setup_linux ;;
    *)
        echo "error: unsupported platform '$(uname -s)' — this repo supports macOS and Linux development" >&2
        exit 1
        ;;
esac

check_worktree_hygiene

echo
if [[ "$FAILURES" -gt 0 ]]; then
    echo "Environment NOT ready: $FAILURES blocking item(s) above."
    exit 1
fi
echo "Environment ready."

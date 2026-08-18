#!/bin/bash
#
# SessionStart hook for Claude Code.
#
# Two jobs, by platform:
#
# macOS (local sessions): emit a toolchain preflight into the session context
# so agents never misdiagnose "the build tooling is not there" — the recurring
# failure is environment resolution (xcode-select at CommandLineTools, an
# ungenerated worktree .xcodeproj, unprovisioned container artifacts), not
# absent tooling. See docs/testing-macos-app.md. Best-effort: a probe failure
# must never fail the session.
#
# Linux (Claude Code on the web): the portable-target flow (see
# scripts/setup-dev-env.sh and README.md#developing-on-linux) needs a
# Swift 6.3+ toolchain for `swift build`/`swift test` to work, and web session
# containers don't ship one. The preferred install path is the cloud
# environment's **setup script** (fetched from GitHub via curl since the setup
# script runs before the session's repo clone exists, cached with the
# environment — see README.md#developing-on-linux); this hook is the
# per-session fallback for environments without that cache, and it owns the
# part a setup script can't do: persisting the toolchain's
# PATH/LD_LIBRARY_PATH into the session via $CLAUDE_ENV_FILE.
set -euo pipefail

if [ "$(uname -s)" = "Darwin" ] && [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  proj_dir="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
  echo "Anglesite macOS toolchain preflight (docs/testing-macos-app.md):"

  sel=$(xcode-select -p 2>/dev/null || true)
  case "$sel" in
    *.app/Contents/Developer)
      echo "- xcode-select: $sel ($(xcodebuild -version 2>/dev/null | head -1 || echo 'version unknown'))"
      ;;
    *)
      echo "- WARNING: xcode-select points at '${sel:-nothing}', not an Xcode app. Do NOT run xcode-select --switch (needs sudo) — export DEVELOPER_DIR instead."
      best=""
      best_v=0
      for app in /Applications/Xcode*.app; do
        [ -d "$app" ] || continue
        v=$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 0)
        maj=${v%%.*}
        if [ "${maj:-0}" -ge "$best_v" ] 2>/dev/null; then
          best="$app"
          best_v="$maj"
        fi
      done
      if [ -n "$best" ]; then
        echo "  Fix: export DEVELOPER_DIR=\"$best/Contents/Developer\"  (Xcode ${best_v}.x found; this repo needs 27+). Re-export in every tool call — shell state does not persist."
      else
        echo "  No /Applications/Xcode*.app found — the macOS app cannot be built on this machine."
      fi
      ;;
  esac

  if command -v xcodegen >/dev/null 2>&1; then
    echo "- xcodegen: $(command -v xcodegen)"
  else
    echo "- WARNING: xcodegen not on PATH (brew install xcodegen) — required to generate the gitignored Anglesite.xcodeproj."
  fi

  if [ ! -e "$proj_dir/Anglesite.xcodeproj" ]; then
    echo "- Anglesite.xcodeproj not generated in this checkout (normal for a fresh worktree) — run 'xcodegen generate', or just use scripts/build-app.sh which does it for you."
  fi

  if [ ! -f "$proj_dir/Resources/container-image/index.json" ] \
     || [ ! -f "$proj_dir/Resources/container-kernel/vmlinux" ] \
     || [ ! -f "$proj_dir/Resources/container-initfs/index.json" ]; then
    echo "- Container boot artifacts unprovisioned here: Debug builds warn, Release builds fail, and site previews fail at runtime. Fix: rsync Resources/container-{image,kernel,initfs} from the main checkout — see docs/testing-macos-app.md § Container boot artifacts."
  fi

  exit 0
fi

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

: "${CLAUDE_ENV_FILE:?CLAUDE_ENV_FILE must be set}"

# Idempotent: no-ops fast when the environment cache (or an earlier session)
# already installed a Swift 6.3+ toolchain.
"${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}/scripts/install-swift-linux.sh"

# Persist swiftly's PATH for the rest of this session (env.sh itself is a
# no-op re-source: it only prepends SWIFTLY_BIN_DIR if not already present).
SWIFTLY_ENV="$HOME/.local/share/swiftly/env.sh"
if [ -f "$SWIFTLY_ENV" ]; then
  echo ". \"$SWIFTLY_ENV\"" >> "$CLAUDE_ENV_FILE"
fi

# Distros shipping libxml2 >= 2.15 (e.g. Ubuntu 26.04) provide libxml2.so.16
# with no libxml2.so.2 compat symlink, but the swift.org toolchain's
# libFoundationXML links libxml2.so.2. Shim it with a user-level symlink (the
# API subset FoundationXML uses survived the soname bump) — mirrors
# scripts/setup-dev-env.sh's Linux path.
if ! ldconfig -p 2>/dev/null | grep -qF 'libxml2.so.2 '; then
  LIBXML2_NEW=$(ldconfig -p 2>/dev/null | awk '/libxml2\.so\.[0-9]+ /{ print $NF; exit }' || true)
  if [ -n "$LIBXML2_NEW" ]; then
    SHIM_DIR="$HOME/.local/lib/anglesite-shims"
    mkdir -p "$SHIM_DIR"
    ln -sf "$LIBXML2_NEW" "$SHIM_DIR/libxml2.so.2"
    case ":${LD_LIBRARY_PATH:-}:" in
      *":$SHIM_DIR:"*) ;;
      *) echo "export LD_LIBRARY_PATH=\"$SHIM_DIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\"" >> "$CLAUDE_ENV_FILE" ;;
    esac
  fi
fi

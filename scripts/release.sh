#!/usr/bin/env bash
#
# Mac App Store release pipeline for the Anglesite target.
#
# Archives the sandboxed Anglesite scheme, verifies the archived app's signature survived
# the archive, then hands the App Store .pkg (signed with the Apple Distribution +
# Mac Installer Distribution identities) to App Store Connect via
# `xcodebuild -exportArchive` with `destination: upload`. (App Store Connect stopped
# accepting `altool --upload-app` in November 2023 — the supported CLI paths are
# xcodebuild's upload destination or Transporter.)
#
# There is deliberately no direct-download update feed or GitHub Release step. On the App Store,
# App Store Connect is the distribution channel and updates ship through it.
#
# Every uploaded build corresponds to a tagged, public commit (#2231). The app statically links
# LGPL-2.1+ code (libgit2's LibXDiff, via SwiftGit2), which LGPL-2.1 section 6 allows when
# recipients can get the source to rebuild it. So an upload requires a clean checkout whose HEAD
# is already on an origin branch; the archive is stamped with that revision (Info.plist
# AnglesiteSourceRevision, shown as a link in the Acknowledgments window); and after a successful
# upload the commit is tagged v<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION> and the tag pushed.
#
# Prerequisites (one-time, see docs/release.md "Mac App Store submission"):
#   - An App Store Connect app record for bundle id io.dwk.anglesite.
#   - An "Apple Distribution" cert + a "Mac Installer Distribution" cert in the keychain.
#   - The Apple WWDR (G3) intermediate cert (https://www.apple.com/certificateauthority/).
#   - A Mac App Store provisioning profile for io.dwk.anglesite, installed.
#   - An App Store Connect API key (AuthKey_<key id>.p8 in ~/.appstoreconnect/private_keys/
#     or ~/.private_keys/, or point ASC_API_KEY_PATH at it) plus its key id + issuer id,
#     for keychain-free xcodebuild upload.
#
# Usage:
#   TEAM_ID=ABCDE12345 \
#   PROVISIONING_PROFILE="Anglesite MAS App Store" \
#   ASC_API_KEY_ID=XXXXXXXXXX ASC_API_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
#     scripts/release.sh [--validate-only] [--force]
#
#   --validate-only   Archive + export the signed .pkg locally (destination: export),
#                     but stop before upload. Useful before a real App Store upload;
#                     Transporter.app's "Verify" can pre-validate the exported .pkg.
#   --force           With --validate-only only: proceed even if the git worktree is dirty
#                     or HEAD isn't on an origin branch. Such an archive is not stamped with
#                     a source revision. An upload always requires a clean, published HEAD.
#
# Env:
#   TEAM_ID               (required) 10-char Apple Developer Team ID.
#   PROVISIONING_PROFILE  (required) Name of the installed App Store provisioning profile
#                         for io.dwk.anglesite.
#   ASC_API_KEY_ID        (required unless --validate-only) App Store Connect API key id.
#   ASC_API_ISSUER_ID     (required unless --validate-only) App Store Connect API issuer id.
#   ASC_API_KEY_PATH      (optional) Explicit path to the AuthKey_<key id>.p8 file; when
#                         unset, the standard private_keys directories are searched.

set -euo pipefail

VALIDATE_ONLY=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --validate-only) VALIDATE_ONLY=1 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
        *) echo "error: unknown argument '$arg'" >&2; exit 64 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/resolve-asc-key.sh
source "$SCRIPT_DIR/lib/resolve-asc-key.sh"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Anglesite.xcarchive"
EXPORT_DIR="$BUILD_DIR/export-mas"
EXPORT_OPTIONS="$BUILD_DIR/exportOptions-appstore.plist"
EXPORT_OPTIONS_TEMPLATE="$SCRIPT_DIR/exportOptions-appstore.plist"
BUNDLE_ID="io.dwk.anglesite"
SCHEME="Anglesite"
CONFIGURATION="Release"

bail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ "$FORCE" -eq 0 || "$VALIDATE_ONLY" -eq 1 ]] \
    || bail "--force is only allowed with --validate-only: an uploaded build must match a clean, published, tagged commit (#2231)."
step() { printf '\n=== %s ===\n' "$*"; }

# --- Preflight ---------------------------------------------------------------
step "0/6 preflight"

[[ -n "${TEAM_ID:-}" ]] \
    || bail "TEAM_ID is unset. Export your 10-character Apple Developer Team ID and re-run."
[[ -n "${PROVISIONING_PROFILE:-}" ]] \
    || bail "PROVISIONING_PROFILE is unset. Set it to the name of the App Store provisioning profile for $BUNDLE_ID."

command -v xcodegen >/dev/null || bail "xcodegen not installed. brew install xcodegen"
command -v xcodebuild >/dev/null || bail "xcodebuild not on PATH (install Xcode + command line tools)."

# Refuse to archive a dirty worktree or an unpublished commit: the .xcarchive would bake in
# changes that match no public commit, so the shipped build would have no corresponding source
# (#2231). --force (validate-only) overrides for deliberate local experiments, and such an
# archive is left unstamped.
git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || bail "$REPO_ROOT is not a git checkout; a release must be built from one."
SOURCE_REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD)"
dirty=$(git -C "$REPO_ROOT" status --porcelain)
if [[ -n "$dirty" ]]; then
    if [[ "$FORCE" -eq 0 ]]; then
        printf '%s\n' "$dirty" | sed 's/^/    /' >&2
        bail "worktree is dirty (uncommitted changes above). Commit them, or for a local validate-only run re-run with --validate-only --force."
    fi
    SOURCE_REVISION=""
fi
if [[ -n "$SOURCE_REVISION" ]]; then
    git -C "$REPO_ROOT" fetch --quiet origin \
        || bail "couldn't fetch origin to confirm HEAD is published."
    if [[ -z "$(git -C "$REPO_ROOT" branch -r --contains "$SOURCE_REVISION" 'origin/*')" ]]; then
        [[ "$FORCE" -eq 1 ]] \
            || bail "HEAD ($SOURCE_REVISION) isn't on any origin branch. Push it first, so the build's source is public."
        SOURCE_REVISION=""
    fi
fi

# Apple Distribution signing identity (signs the .app).
security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Distribution" \
    || bail "no 'Apple Distribution' codesigning identity in the keychain. Create one in the Apple Developer portal and install it."

# Mac Installer Distribution identity (signs the .pkg). Installer certs are not codesigning
# certs, so they don't appear under -p codesigning; scan the full identity list.
security find-identity -v 2>/dev/null | grep -Eq "Mac Installer Distribution|3rd Party Mac Developer Installer" \
    || bail "no 'Mac Installer Distribution' (installer) identity in the keychain. App Store .pkg signing needs it."

# WWDR-G3 intermediate cert — without it the distribution chain won't validate at upload.
security find-certificate -a 2>/dev/null | grep -q "Apple Worldwide Developer Relations" \
    || bail "Apple WWDR intermediate cert missing. Download G3 from https://www.apple.com/certificateauthority/ and add it to the keychain."

ASC_KEY_PATH=""
if [[ "$VALIDATE_ONLY" -eq 0 ]]; then
    [[ -n "${ASC_API_KEY_ID:-}" ]] \
        || bail "ASC_API_KEY_ID is unset (needed for upload). Re-run with --validate-only to skip the upload step."
    [[ -n "${ASC_API_ISSUER_ID:-}" ]] \
        || bail "ASC_API_ISSUER_ID is unset (needed for upload). Re-run with --validate-only to skip the upload step."
    # xcodebuild (unlike altool) needs the API key file path spelled out.
    ASC_KEY_PATH="$(resolve_asc_key_path "$ASC_API_KEY_ID")"
fi

echo "  source:      ${SOURCE_REVISION:-(unstamped: --force with a dirty or unpublished HEAD)}"
echo "  team:        $TEAM_ID"
echo "  profile:     $PROVISIONING_PROFILE"
echo "  mode:        $([[ "$VALIDATE_ONLY" -eq 1 ]] && echo 'validate-only (export .pkg, no upload)' || echo 'export + upload to App Store Connect')"

# --- Generate project + export options ---------------------------------------
step "1/6 xcodegen generate + release tag preflight"
(cd "$REPO_ROOT" && xcodegen generate)

# The release tag is derived from the version the archive will carry. Check it now, before the
# slow archive: an existing tag on another commit means the version wasn't bumped.
build_setting() {
    xcodebuild -project "$REPO_ROOT/Anglesite.xcodeproj" -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
        | sed -n "s/^ *$1 = //p" | head -1
}
MARKETING_VERSION="$(build_setting MARKETING_VERSION)"
BUILD_NUMBER="$(build_setting CURRENT_PROJECT_VERSION)"
[[ -n "$MARKETING_VERSION" && -n "$BUILD_NUMBER" ]] \
    || bail "couldn't read MARKETING_VERSION / CURRENT_PROJECT_VERSION from the $SCHEME scheme."
RELEASE_TAG="v${MARKETING_VERSION}-${BUILD_NUMBER}"
# The commit an existing local or remote tag points at (peeled), or nothing.
existing_tag_commit() {
    git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$RELEASE_TAG^{commit}" 2>/dev/null && return
    git -C "$REPO_ROOT" ls-remote origin "refs/tags/$RELEASE_TAG^{}" "refs/tags/$RELEASE_TAG" \
        | awk '{c=$1} /\^\{\}$/ {p=$1} END {print p ? p : c}'
}
tag_commit="$(existing_tag_commit)"
if [[ -n "$tag_commit" && "$tag_commit" != "$SOURCE_REVISION" ]]; then
    bail "tag $RELEASE_TAG already exists on $tag_commit. Bump MARKETING_VERSION or CURRENT_PROJECT_VERSION in project.yml."
fi
echo "  release tag: $RELEASE_TAG"

mkdir -p "$BUILD_DIR"
# Fill in the template with plutil, not sed: a team id / profile name containing sed
# or XML metacharacters (/ & \ < …) round-trips correctly, and plutil validates the
# plist as it writes. The template's __TEAM_ID__/__PROVISIONING_PROFILE__ placeholders
# are simply overwritten. (Dots in the bundle-id keypath segment need escaping.)
cp "$EXPORT_OPTIONS_TEMPLATE" "$EXPORT_OPTIONS"
plutil -replace teamID -string "$TEAM_ID" "$EXPORT_OPTIONS"
plutil -replace "provisioningProfiles.${BUNDLE_ID//./\\.}" -string "$PROVISIONING_PROFILE" "$EXPORT_OPTIONS"

if [[ "$VALIDATE_ONLY" -eq 0 ]]; then
    # destination `upload` makes -exportArchive hand the signed .pkg straight to
    # App Store Connect. The template omits the key, so exports default to `export`
    # (write the .pkg locally) in --validate-only mode.
    plutil -insert destination -string upload "$EXPORT_OPTIONS"
fi

# --- Archive -----------------------------------------------------------------
step "2/6 xcodebuild archive ($SCHEME)"
rm -rf "$ARCHIVE_PATH"
xcodebuild \
    -project "$REPO_ROOT/Anglesite.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ANGLESITE_SOURCE_REVISION="$SOURCE_REVISION" \
    archive
[[ -d "$ARCHIVE_PATH" ]] || bail "archive produced no .xcarchive at $ARCHIVE_PATH"

# --- Verify the app signature survived the archive ---------------------------
step "3/6 verify archived app signature + source stamp"
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/Anglesite.app"
stamped="$(plutil -extract AnglesiteSourceRevision raw -o - "$ARCHIVED_APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$stamped" == "$SOURCE_REVISION" ]] \
    || bail "archived Info.plist AnglesiteSourceRevision is '$stamped', expected '$SOURCE_REVISION'."
echo "  source stamp: ${stamped:-(none)}"
codesign --verify --strict --verbose=2 "$ARCHIVED_APP" \
    || bail "archived app failed codesign --verify."
app_team="$(codesign -dvv "$ARCHIVED_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$app_team" == "$TEAM_ID" ]] \
    || bail "app TeamIdentifier '$app_team' != expected team '$TEAM_ID'."
echo "  app: signed, team=$app_team"

# --- Export (and, unless --validate-only, upload) -----------------------------
# With `destination: upload` in the export options, this single xcodebuild call
# packages AND submits to App Store Connect, authenticated by the ASC API key —
# the supported replacement for the retired `altool --validate/--upload-app`.
step "4/6 xcodebuild -exportArchive ($([[ "$VALIDATE_ONLY" -eq 1 ]] && echo 'destination: export' || echo 'destination: upload'))"
rm -rf "$EXPORT_DIR"
export_args=(
    -exportArchive
    -archivePath "$ARCHIVE_PATH"
    -exportPath "$EXPORT_DIR"
    -exportOptionsPlist "$EXPORT_OPTIONS"
)
if [[ "$VALIDATE_ONLY" -eq 0 ]]; then
    export_args+=(
        -allowProvisioningUpdates
        -authenticationKeyID "$ASC_API_KEY_ID"
        -authenticationKeyIssuerID "$ASC_API_ISSUER_ID"
        -authenticationKeyPath "$ASC_KEY_PATH"
    )
fi
xcodebuild "${export_args[@]}"

# --- Result ------------------------------------------------------------------
if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
    step "5/6 release tag (skipped: validate-only)"
    echo "  an upload of this checkout would tag ${SOURCE_REVISION:-(unstamped)} as $RELEASE_TAG"
else
    # Tag only after a successful upload, so a failed upload never leaves a tag behind. The
    # upload has already happened by now, so a tag failure doesn't undo it; it prints how to
    # finish by hand instead.
    step "5/6 tag $RELEASE_TAG and push it"
    if ! git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$RELEASE_TAG" >/dev/null; then
        git -C "$REPO_ROOT" tag -a "$RELEASE_TAG" -m "Anglesite $MARKETING_VERSION ($BUILD_NUMBER)" "$SOURCE_REVISION" \
            || bail "uploaded, but creating tag $RELEASE_TAG failed. Run: git tag -a $RELEASE_TAG $SOURCE_REVISION && git push origin $RELEASE_TAG"
    fi
    git -C "$REPO_ROOT" push origin "refs/tags/$RELEASE_TAG" \
        || bail "uploaded, but pushing tag $RELEASE_TAG failed. Run: git push origin $RELEASE_TAG"
fi

step "6/6 result"
if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
    PKG_PATH="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.pkg' -print -quit)"
    [[ -n "$PKG_PATH" && -f "$PKG_PATH" ]] || bail "export produced no .pkg under $EXPORT_DIR"
    echo "  → $PKG_PATH ($(stat -f%z "$PKG_PATH") bytes)"
    cat <<EOF

✅ Validate-only run complete. Package ready at:
     $PKG_PATH

To upload to App Store Connect, re-run without --validate-only (and with
ASC_API_KEY_ID / ASC_API_ISSUER_ID set), or drop the .pkg into Transporter.app
(whose "Verify" button runs the App Store Connect pre-upload validation).
EOF
    exit 0
fi

cat <<EOF

✅ Uploaded $SCHEME to App Store Connect, built from $SOURCE_REVISION (tag $RELEASE_TAG).
   (Upload logs, if any, are under $EXPORT_DIR.)

Next steps:
  1. Wait for processing in App Store Connect → TestFlight / App Store.
  2. Attach the build to a version and submit for review.
See docs/release.md "Mac App Store submission" for the full flow.
EOF

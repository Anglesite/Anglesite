#!/usr/bin/env bash
#
# Exercises scripts/release.sh's source-availability rules (#2231) against a throwaway repo with
# a bare `origin`, with `xcodegen`, `xcodebuild`, `security`, `codesign`, `plutil` and `stat`
# stubbed on PATH, so every branch runs without Xcode, signing identities or App Store Connect:
#
#   * upload from a clean, pushed HEAD   -> archive gets ANGLESITE_SOURCE_REVISION=<HEAD>, and
#                                           annotated tag v<version>-<build> is pushed to origin
#   * re-run on the same tagged commit   -> succeeds; the tag is left as is
#   * tag already on another commit      -> refuses before archiving ("Bump MARKETING_VERSION")
#   * dirty worktree                     -> refuses
#   * HEAD not on any origin branch      -> refuses
#   * --force without --validate-only    -> refuses
#   * --validate-only --force, dirty     -> archives unstamped, creates no tag
#   * archive missing the source stamp   -> refuses before export/upload
#
# Runs in CI's linux-build-test lane (ci.yml) beside the other self-contained script tests: it
# needs only bash, git, sed and awk.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

overall_status=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; overall_status=1; }

# ---- Fixture: a repo carrying release.sh, published to a bare origin ------------------------

origin="$tmp/origin.git"
repo="$tmp/repo"
git init -q --bare "$origin"
git init -q -b main "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name "Release Test"
mkdir -p "$repo/scripts/lib"
cp "$SCRIPT_DIR/release.sh" "$repo/scripts/release.sh"
cp "$SCRIPT_DIR/lib/resolve-asc-key.sh" "$repo/scripts/lib/resolve-asc-key.sh"
cp "$SCRIPT_DIR/exportOptions-appstore.plist" "$repo/scripts/exportOptions-appstore.plist"
printf 'build/\n*.log\n' > "$repo/.gitignore"
echo one > "$repo/file.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm one
git -C "$repo" remote add origin "$origin"
git -C "$repo" push -q origin main

# ---- Stubs ----------------------------------------------------------------------------------

stubs="$tmp/stubs"
mkdir -p "$stubs"
log="$tmp/xcodebuild.log"
cat > "$stubs/xcodegen" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
# xcodebuild: -showBuildSettings prints the version; archive writes a fake app whose Info.plist
# "value" is just the stamped revision (plutil below reads it back); -exportArchive writes a .pkg.
cat > "$stubs/xcodebuild" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$log"
archive_path="" export_path="" revision="" mode=""
for arg in "\$@"; do
    case "\$arg" in
        ANGLESITE_SOURCE_REVISION=*) revision="\${arg#*=}" ;;
        -showBuildSettings) mode=settings ;;
        archive) mode=archive ;;
        -exportArchive) mode=export ;;
    esac
done
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -archivePath) archive_path="\$2"; shift ;;
        -exportPath) export_path="\$2"; shift ;;
    esac
    shift
done
case "\$mode" in
    settings) printf '    MARKETING_VERSION = 1.2.3\n    CURRENT_PROJECT_VERSION = 7\n' ;;
    archive)
        app="\$archive_path/Products/Applications/Anglesite.app/Contents"
        mkdir -p "\$app"
        if [[ -n "\${STUB_DROP_STAMP:-}" ]]; then revision=""; fi
        printf '%s' "\$revision" > "\$app/Info.plist" ;;
    export) mkdir -p "\$export_path" && echo pkg > "\$export_path/Anglesite.pkg" ;;
esac
STUB
cat > "$stubs/security" <<'STUB'
#!/usr/bin/env bash
echo "1) ABC \"Apple Distribution: Test (TEAM123456)\""
echo "2) DEF \"3rd Party Mac Developer Installer: Test (TEAM123456)\""
echo "\"Apple Worldwide Developer Relations Certification Authority\""
STUB
cat > "$stubs/codesign" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "-dvv" ]] && echo "TeamIdentifier=TEAM123456" >&2
exit 0
STUB
# plutil: `-extract <key> raw -o - <file>` prints the fake Info.plist's content; edits succeed.
cat > "$stubs/plutil" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-extract" ]]; then cat "${!#}"; fi
exit 0
STUB
cat > "$stubs/stat" <<'STUB'
#!/usr/bin/env bash
echo 3
STUB
chmod +x "$stubs"/*
touch "$tmp/AuthKey_TEST.p8"

run() {
    PATH="$stubs:$PATH" TEAM_ID=TEAM123456 PROVISIONING_PROFILE="Test Profile" \
        ASC_API_KEY_ID=TEST ASC_API_ISSUER_ID=issuer ASC_API_KEY_PATH="$tmp/AuthKey_TEST.p8" \
        bash "$repo/scripts/release.sh" "$@" > "$tmp/out" 2>&1
}
remote_tag_commit() {
    git -C "$repo" ls-remote origin "refs/tags/$1^{}" | awk '{print $1}'
}
expect_refusal() {
    local label="$1" message="$2"; shift 2
    : > "$log"
    if run "$@"; then
        fail "$label -> refuses (it succeeded)"; sed 's/^/  | /' "$tmp/out"
    elif ! grep -qF -- "$message" "$tmp/out"; then
        fail "$label -> message '$message'"; sed 's/^/  | /' "$tmp/out"
    else
        pass "$label -> refuses with '$message'"
    fi
}

# ---- Cases ----------------------------------------------------------------------------------

head1="$(git -C "$repo" rev-parse HEAD)"
: > "$log"
if run && grep -q "ANGLESITE_SOURCE_REVISION=$head1 archive" "$log" \
    && [[ "$(remote_tag_commit v1.2.3-7)" == "$head1" ]] \
    && [[ "$(git -C "$repo" cat-file -t v1.2.3-7)" == tag ]]; then
    pass "upload from a clean, pushed HEAD -> stamped archive, annotated tag pushed"
else
    fail "upload from a clean, pushed HEAD -> stamped archive, annotated tag pushed"
    sed 's/^/  | /' "$tmp/out"
fi

if run && [[ "$(remote_tag_commit v1.2.3-7)" == "$head1" ]]; then
    pass "re-run on the same tagged commit -> succeeds, tag unchanged"
else
    fail "re-run on the same tagged commit -> succeeds, tag unchanged"; sed 's/^/  | /' "$tmp/out"
fi

echo two > "$repo/file.txt"
git -C "$repo" commit -qam two
git -C "$repo" push -q origin main
expect_refusal "tag already on another commit" "already exists on $head1"
if grep -q ' archive$' "$log"; then
    fail "tag already on another commit -> refused before archiving"
else
    pass "tag already on another commit -> refused before archiving"
fi

# A fresh build number from here on, so the remaining cases aren't stopped by the tag check.
sed -i.bak 's/CURRENT_PROJECT_VERSION = 7/CURRENT_PROJECT_VERSION = 8/' "$stubs/xcodebuild"

echo dirty > "$repo/file.txt"
expect_refusal "dirty worktree" "worktree is dirty"
git -C "$repo" checkout -q -- file.txt

echo three > "$repo/file.txt"
git -C "$repo" commit -qam three
expect_refusal "HEAD not on any origin branch" "isn't on any origin branch"

expect_refusal "--force without --validate-only" "--force is only allowed with --validate-only" --force

echo dirty > "$repo/file.txt"
: > "$log"
if run --validate-only --force && grep -q "ANGLESITE_SOURCE_REVISION= archive" "$log" \
    && [[ -z "$(git -C "$repo" tag -l v1.2.3-8)" ]]; then
    pass "--validate-only --force on a dirty tree -> unstamped archive, no tag"
else
    fail "--validate-only --force on a dirty tree -> unstamped archive, no tag"
    sed 's/^/  | /' "$tmp/out"
fi
git -C "$repo" checkout -q -- file.txt
git -C "$repo" push -q origin main

STUB_DROP_STAMP=1 expect_refusal "archive missing the source stamp" "AnglesiteSourceRevision is ''"
if grep -q -- '-exportArchive' "$log"; then
    fail "archive missing the source stamp -> refused before export"
else
    pass "archive missing the source stamp -> refused before export"
fi
[[ -z "$(git -C "$repo" tag -l v1.2.3-8)" ]] \
    && pass "a refused upload creates no tag" || fail "a refused upload creates no tag"

exit "$overall_status"

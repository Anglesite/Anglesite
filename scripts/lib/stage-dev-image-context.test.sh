#!/bin/bash
#
# Exercises require_min_sidecar_version() in stage-dev-image-context.sh: the guard that fails
# a container-image build loudly when the staged MCP sidecar checkout predates a protocol the
# app's MCPClient requires (see the call site's comment, #1277) instead of silently baking a
# broken MCP path into the image. Never runs staged_dev_image_context itself — no rsync/tar
# side effects, just the version-compare and the guard's pass/fail behavior against a stubbed
# package.json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stage-dev-image-context.sh
source "$SCRIPT_DIR/stage-dev-image-context.sh"

overall_status=0

assert_version_ge() {
  local a="$1" b="$2" want="$3"
  local got="fail"
  _version_ge "$a" "$b" && got="pass"
  if [ "$got" = "$want" ]; then
    echo "PASS [_version_ge $a >= $b]: $got"
  else
    echo "FAIL [_version_ge $a >= $b]: got $got, want $want"
    overall_status=1
  fi
}

assert_version_ge "1.9.0" "1.9.0" "pass"
assert_version_ge "1.10.0" "1.9.0" "pass"
assert_version_ge "2.0.0" "1.9.0" "pass"
assert_version_ge "1.9.1" "1.9.0" "pass"
assert_version_ge "1.8.0" "1.9.0" "fail"
assert_version_ge "1.9" "1.9.0" "pass"
assert_version_ge "0.9.99" "1.9.0" "fail"

run_guard_case() {
  local name="$1" version="$2" want_exit="$3"
  local tmp
  tmp=$(mktemp -d)
  cat >"$tmp/package.json" <<PKG
{"name": "anglesite-skills", "version": "$version"}
PKG

  local exit_code=0
  ( require_min_sidecar_version "$tmp" "1.9.0" ) >"$tmp/out.log" 2>&1 || exit_code=$?

  if [ "$exit_code" = "$want_exit" ]; then
    echo "PASS [$name]: exit=$exit_code"
  else
    echo "FAIL [$name]: exit=$exit_code, want $want_exit"
    cat "$tmp/out.log"
    overall_status=1
  fi
  rm -rf "$tmp"
}

run_guard_case "at minimum version" "1.9.0" 0
run_guard_case "above minimum version" "1.10.2" 0
run_guard_case "below minimum version" "1.8.0" 1

# Missing/unparseable version field also fails loud rather than silently skipping the check.
tmp_missing=$(mktemp -d)
echo '{"name": "anglesite-skills"}' >"$tmp_missing/package.json"
exit_code=0
( require_min_sidecar_version "$tmp_missing" "1.9.0" ) >"$tmp_missing/out.log" 2>&1 || exit_code=$?
if [ "$exit_code" = "1" ]; then
  echo "PASS [missing version field]: exit=$exit_code"
else
  echo "FAIL [missing version field]: exit=$exit_code, want 1"
  cat "$tmp_missing/out.log"
  overall_status=1
fi
rm -rf "$tmp_missing"

if [ "$overall_status" -ne 0 ]; then
  echo "stage-dev-image-context.test.sh: FAILED"
  exit 1
fi
echo "stage-dev-image-context.test.sh: all cases passed"

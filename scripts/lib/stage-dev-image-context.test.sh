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

# want_message (optional): a substring `out.log` must contain. Asserting on content, not just
# exit code, matters here — a real bug (grep|sed exiting non-zero under `set -euo pipefail`,
# tripping errexit on the plain assignment before the intended "ERROR: could not read..." echo)
# produced the *same* exit code (1) as the correct path, with an empty log. An exit-code-only
# check couldn't tell those apart; this caught it in review (see the fix's comment at the
# require_min_sidecar_version call site) and is here so a regression doesn't slip through again.
run_guard_case() {
  local name="$1" package_json_body="$2" want_exit="$3" want_message="${4:-}"
  local tmp
  tmp=$(mktemp -d)
  printf '%s' "$package_json_body" >"$tmp/package.json"

  # A real `bash -c` child process, not `( require_min_sidecar_version ... )` run inline: a
  # subshell forked to evaluate the left side of `||` inherits this script's "currently being
  # tested, -e is suspended" state, so a plain-assignment errexit bug *inside* the function would
  # never fire there either — exactly how the original bug passed "under test" despite being
  # live at the function's real call sites (top-level scripts, not inside a conditional). A
  # freshly exec'd `bash -c` with its own explicit `set -euo pipefail` decides errexit fresh,
  # matching how vendor-container-image.sh/build-podman-image.sh actually invoke this.
  local exit_code=0
  bash -c "set -euo pipefail; source '$SCRIPT_DIR/stage-dev-image-context.sh'; require_min_sidecar_version '$tmp' '1.9.0'" \
    >"$tmp/out.log" 2>&1 || exit_code=$?

  local case_status="ok"
  if [ "$exit_code" != "$want_exit" ]; then
    echo "FAIL [$name]: exit=$exit_code, want $want_exit"
    case_status="fail"
  fi
  if [ -n "$want_message" ] && ! grep -qF "$want_message" "$tmp/out.log"; then
    echo "FAIL [$name]: out.log missing expected message \"$want_message\""
    case_status="fail"
  fi

  if [ "$case_status" = "ok" ]; then
    echo "PASS [$name]: exit=$exit_code"
  else
    echo "--- $name: out.log ---"
    cat "$tmp/out.log"
    echo "---"
    overall_status=1
  fi
  rm -rf "$tmp"
}

run_guard_case "at minimum version" '{"name": "anglesite-skills", "version": "1.9.0"}' 0
run_guard_case "above minimum version" '{"name": "anglesite-skills", "version": "1.10.2"}' 0
run_guard_case "below minimum version" '{"name": "anglesite-skills", "version": "1.8.0"}' 1 "requires >= v1.9.0"
run_guard_case "missing version field" '{"name": "anglesite-skills"}' 1 "could not read"

if [ "$overall_status" -ne 0 ]; then
  echo "stage-dev-image-context.test.sh: FAILED"
  exit 1
fi
echo "stage-dev-image-context.test.sh: all cases passed"

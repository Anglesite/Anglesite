#!/usr/bin/env bash
#
# Builds the repro once, signs it three ways (ad-hoc), and runs each variant.
#
# Expected on macOS 26.x and macOS 27 seeds up to 26A5378j:
#   sandboxed                : RESULT: PASS
#   sandboxed-with-exception : RESULT: PASS
#   unsandboxed              : RESULT: PASS
#
# Actual on macOS 27 seeds 26A5378n, 26A5388g, 26A5406e, 26A5425a:
#   sandboxed                : RESULT: FAIL (VMNET_MEM_FAILURE) or RESULT: HANG
#   sandboxed-with-exception : RESULT: PASS
#   unsandboxed              : RESULT: PASS

set -euo pipefail
cd "$(dirname "$0")"

echo "== macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) =="

mkdir -p build
clang -mmacosx-version-min=26.0 -framework vmnet -framework CoreFoundation \
    -sectcreate __TEXT __info_plist Info.plist \
    -o build/repro main.c

for variant in sandboxed sandboxed-with-exception unsandboxed; do
    cp build/repro "build/repro-$variant"
    codesign --force --sign - \
        --entitlements "entitlements/$variant.entitlements" \
        "build/repro-$variant"
    echo
    echo "== $variant =="
    "./build/repro-$variant" || true
done

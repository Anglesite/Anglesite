#!/bin/bash
# DIAGNOSTIC (#1990): standalone reproducer variants, compiled and run on the CI toolchain.
set -u
cd "$(dirname "$0")"
W="${RUNNER_TEMP:-/tmp}/diag-1990"; mkdir -p "$W"
sed 's|  // VARIANT||' repro.swift > "$W/v1.swift"
sed 's|@Sendable public static func isTracked|public static func isTracked|; s|  // VARIANT||' repro.swift > "$W/v2.swift"
sed 's|= Inbox.isTracked  // VARIANT|= { await Inbox.isTracked($0, $1) }|' repro.swift > "$W/v3.swift"
sed 's|isTracked: @Sendable (URL, String) async -> Bool = Inbox.isTracked  // VARIANT|isTracked: (URL, String) async -> Bool = Inbox.isTracked|' repro.swift > "$W/v4.swift"
for v in v1 v2 v3 v4; do
  echo "=== REPRO $v: build ==="
  FLAGS=(-Onone -parse-as-library -swift-version 5 -enable-upcoming-feature StrictConcurrency)
  if swiftc "${FLAGS[@]}" "$W/$v.swift" -o "$W/$v"; then
    echo "=== REPRO $v: run ==="
    "$W/$v"; echo "=== REPRO $v: exit $? ==="
  else
    echo "=== REPRO $v: BUILD FAILED ==="
  fi
done
echo "=== REPRO v1: SIL (default-argument generator + implicit closure) ==="
swiftc -Onone -parse-as-library -swift-version 5 -enable-upcoming-feature StrictConcurrency -emit-sil "$W/v1.swift" -o "$W/v1.sil" && python3 - "$W/v1.sil" <<'PY'
import sys,re
text=open(sys.argv[1]).read()
blocks=re.split(r'\n\n', text)
for b in blocks:
    comments='\n'.join(l for l in b.split('\n') if l.startswith('// '))
    if ('default argument' in comments or 'implicit closure' in comments or 'isTracked' in comments) and 'sil ' in b and 'print(' not in comments:
        print(b.strip()); print()
PY
echo "=== REPRO v1: disassembly of the default-argument thunk ==="
objdump -d --no-show-raw-insn "$W/v1" | swift demangle | python3 -c '
import sys,re
out=sys.stdin.read()
for blk in re.split(r"\n\n", out):
    if "default argument" in blk.split("\n",1)[0] or "isTracked" in blk.split("\n",1)[0]:
        print(blk); print()
'

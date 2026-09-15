#!/bin/bash
# DIAGNOSTIC (#1990): two-module reproducer (a client module omitting a defaulted async
# closure argument whose default references a @Sendable static async func).
set -u
cd "$(dirname "$0")/repro-pkg"
echo "=== PKG: build ==="
swift build -c debug 2>&1 | tail -5
BIN="$(swift build -c debug --show-bin-path)/App"; echo "binary: $BIN"
for v in sendable plain literal; do
  echo "=== PKG: run $v ==="
  "$BIN" "$v"; echo "=== PKG: run $v exit $? ==="
done
echo "=== PKG: AFP records (linked App) ==="
python3 ../afp.py "$BIN" "Committer.via" "Inbox.isTracked" 2>&1 | grep -v "^\s*[0-9a-f]\{8,\}:" | head -80
for o in $(find .build -type f \( -name 'Lib.o' -o -name 'Lib.swift.o' -o -name 'main.o' -o -name 'main.swift.o' \) | grep -v ModuleCache); do
  echo "=== PKG: AFP records ($o) ==="
  python3 ../afp.py "$o" "Committer.via" "Inbox.isTracked" 2>&1 | grep -v "^\s*[0-9a-f]\{8,\}:" | head -60
done

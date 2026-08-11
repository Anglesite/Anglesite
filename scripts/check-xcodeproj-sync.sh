#!/usr/bin/env bash
# Guards against project.yml ↔ source-tree drift for the gitignored Anglesite.xcodeproj.
#
# Anglesite.xcodeproj/ is regenerated from project.yml via XcodeGen and never committed,
# so a stale or malformed spec never fails `swift build` CI — it only surfaces later as
# `error: cannot find 'X' in scope` from `xcodebuild` on a contributor's machine (#123).
#
# This check regenerates the project, then asserts that every application target actually
# *compiles* every Swift file under Sources/AnglesiteApp. It catches the drift modes CI can
# see on a fresh generate:
#   1. A malformed/typo'd path in project.yml — XcodeGen exits non-zero on spec validation.
#   2. A narrowed/removed `sources:` entry that silently drops files from a target's compile
#      phase — XcodeGen exits 0, but the dropped files are then absent from that target's
#      Sources build phase (this script fails, naming the target and files).
#
# Membership is checked per application target (via the target's PBXSourcesBuildPhase), not by mere
# presence of a file reference. Files are compared by their path *relative to*
# Sources/AnglesiteApp (reconstructed from the PBX group hierarchy), not by bare basename, so two
# same-named files in different subdirs (e.g. Views/Settings.swift vs Overlays/Settings.swift) are
# distinguished.
#
# It deliberately does NOT run a full `xcodebuild` of the app: the app target needs the
# macOS 27 SDK (Xcode 27), which CI runners don't yet ship (see #128). XcodeGen only needs
# the spec + sources, so this guard runs anywhere xcodegen + python3 + plutil are installed.
# `plutil` (used below to convert the pbxproj plist to JSON) is macOS-only, so in practice
# this script requires macOS.
#
# XcodeGen version: CI pins 2.45.4 (see .github/workflows/ci.yml). This script requires at
# least the MIN_XCODEGEN below; the project graph keys it reads (PBXSourcesBuildPhase,
# productType, --quiet) are stable across the 2.x line.
set -euo pipefail

MIN_XCODEGEN="2.38.0"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found on PATH." >&2
  echo "       Install with: brew install xcodegen" >&2
  exit 1
fi

# Fail loudly on an xcodegen too old to be trusted, rather than silently accepting whatever
# the local/Homebrew formula happens to provide.
xcodegen_version="$(xcodegen --version 2>/dev/null | sed -n 's/^Version: //p')"
if [[ -z "$xcodegen_version" ]]; then
  # An unparseable --version means an unexpected build; warn rather than silently skipping, so a
  # stale xcodegen can't masquerade as "checked" and produce a confusing result downstream.
  echo "warning: could not parse 'xcodegen --version'; skipping minimum-version ($MIN_XCODEGEN) check." >&2
elif [[ "$(printf '%s\n%s\n' "$MIN_XCODEGEN" "$xcodegen_version" | sort -V | head -1)" != "$MIN_XCODEGEN" ]]; then
  echo "error: xcodegen $xcodegen_version is older than the required $MIN_XCODEGEN." >&2
  echo "       Upgrade with: brew upgrade xcodegen" >&2
  exit 1
fi

# Regenerate the project. A spec-validation error (e.g. a path typo) exits non-zero here and
# `set -e` aborts. --quiet suppresses the success banner but still emits warnings/errors.
echo "Regenerating Anglesite.xcodeproj via xcodegen…"
xcodegen generate --quiet

pbxproj="Anglesite.xcodeproj/project.pbxproj"
if [[ ! -f "$pbxproj" ]]; then
  echo "error: $pbxproj not found after xcodegen generate." >&2
  exit 1
fi

# Resolve, per application target, the set of Swift files it compiles, and compare against the
# Swift files on disk under $sources_root. plutil reads the old-style pbxproj plist; python3
# walks the object graph (target → PBXSourcesBuildPhase → PBXBuildFile → PBXFileReference),
# rebuilding each file's path from its enclosing PBXGroup chain.
pbx_json="$(mktemp "${TMPDIR:-/tmp}/anglesite-pbxproj.XXXXXX.json")"
trap 'rm -f "$pbx_json"' EXIT
plutil -convert json -o "$pbx_json" "$pbxproj"

python3 - "$pbx_json" <<'PY'
import json, os, sys

pbx_json = sys.argv[1]

# Each application target's `sources:` root in project.yml. The AnglesiteCore/Bridge/Intents
# trees are SwiftPM package products (compiled by SwiftPM, not file-referenced in the pbxproj),
# so only these app-target trees are verifiable against the generated project. A new
# application target must be added here or the check fails loudly below — the unmapped-target
# error, not a silent pass, is the contract.
SOURCES_ROOTS = {
    "Anglesite": "Sources/AnglesiteApp",
    "AnglesiteMobile": "Sources/AnglesiteMobile",
    # The AnglesiteRemote *app target* only directly compiles the thin executable — the
    # reusable AnglesiteRemote library (Sources/AnglesiteRemote) is linked in as a SwiftPM
    # package product (project.yml dependencies:), not inlined into this target's own
    # sources, so this root matches what the target actually compiles.
    "AnglesiteRemote": "Sources/anglesite-remote-helper",
}

def on_disk_swift(sources_root):
    # On-disk Swift files, as paths relative to sources_root (e.g. "Foo.swift", "Views/Bar.swift").
    files = {
        os.path.relpath(os.path.join(root, f), sources_root)
        for root, _dirs, names in os.walk(sources_root)
        for f in names if f.endswith(".swift")
    }
    if not files:
        sys.exit(f"error: no .swift files found under {sources_root} — is the working tree intact?")
    return files

with open(pbx_json) as fh:
    objects = json.load(fh)["objects"]

# child id → enclosing PBXGroup id, so a file reference's full path can be rebuilt from the
# chain of group `path` components (XcodeGen emits one group per source directory).
parent = {
    child: gid
    for gid, obj in objects.items() if obj.get("isa") == "PBXGroup"
    for child in obj.get("children", [])
}

def full_path(obj_id):
    # `seen` guards against a malformed pbxproj with a circular group hierarchy (A → B → A).
    # XcodeGen's generated output won't cycle, but the set keeps the failure mode obvious.
    parts, node, seen = [], obj_id, set()
    while node is not None and node not in seen:
        seen.add(node)
        path = objects.get(node, {}).get("path")
        if path:
            parts.append(path)
        node = parent.get(node)
    return os.path.normpath(os.path.join(*reversed(parts))) if parts else ""

app_targets = [
    v for v in objects.values()
    if v.get("isa") == "PBXNativeTarget"
    and v.get("productType") == "com.apple.product-type.application"
]
if not app_targets:
    sys.exit("error: no application targets found in the generated project.")

failed = False
checked = []
for target in sorted(app_targets, key=lambda t: t["name"]):
    name = target["name"]
    sources_root = SOURCES_ROOTS.get(name)
    if sources_root is None:
        failed = True
        print(
            f"error: application target '{name}' has no sources root mapped in "
            f"SOURCES_ROOTS (scripts/check-xcodeproj-sync.sh) — add it so its compile "
            "phase is verified.", file=sys.stderr)
        continue
    on_disk = on_disk_swift(sources_root)

    compiled = set()
    for phase_id in target.get("buildPhases", []):
        phase = objects.get(phase_id, {})
        if phase.get("isa") != "PBXSourcesBuildPhase":
            continue
        for build_file_id in phase.get("files", []):
            ref_id = objects.get(build_file_id, {}).get("fileRef")
            ref = objects.get(ref_id, {})
            if str(ref.get("path", "")).endswith(".swift"):
                compiled.add(os.path.relpath(full_path(ref_id), sources_root))

    missing = sorted(on_disk - compiled)
    if missing:
        failed = True
        print(
            f"error: target '{name}' does not compile {len(missing)} file(s) that "
            f"exist under {sources_root}.", file=sys.stderr)
        print(
            "       project.yml's sources have drifted from disk; an xcodebuild of this target "
            "would fail with 'cannot find … in scope':", file=sys.stderr)
        for rel in missing:
            print(f"         - {sources_root}/{rel}", file=sys.stderr)
    else:
        checked.append(f"{name} ({len(on_disk)} file(s) under {sources_root})")

if failed:
    sys.exit(1)

print("✓ Anglesite.xcodeproj is in sync: " + "; ".join(checked) + ".")
PY

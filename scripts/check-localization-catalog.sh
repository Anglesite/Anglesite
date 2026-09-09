#!/usr/bin/env bash
# Guards against user-facing string literals silently missing from
# Sources/AnglesiteApp/Localizable.xcstrings (#811).
#
# SWIFT_EMIT_LOC_STRINGS only performs the real String Catalog merge during an interactive
# Xcode IDE build; a CLI-only `xcodebuild build` (the only option for a headless/agent
# workflow) never merges new/removed keys into the catalog (see CONTRIBUTING.md's "Commit
# String Catalog updates" section). That leaves CLI-only contributors with no automated
# feedback when they add localizable text — every app-side PR merged since the CONTRIBUTING.md
# rule landed (#755) has silently missed it.
#
# This is a static, heuristic check (not a real extraction): it scans Sources/AnglesiteApp for
# common SwiftUI call sites whose first positional argument is a LocalizedStringKey-typed string
# literal (Text, Button, Label, Toggle, TextField, SecureField, Menu, Section, Picker, GroupBox,
# ContentUnavailableView) plus explicit String(localized:) and LocalizedStringKey(...) calls, and
# checks each literal is a key in Localizable.xcstrings. It does NOT type-check call sites (so a
# same-named local type/function would false-positive) and does NOT catch every extraction vector
# Xcode recognizes (e.g. a custom view whose init parameter happens to be typed
# LocalizedStringKey) - it only catches the shapes actually used in this codebase today. It also
# only recognizes standard double-quoted literals: a multi-line (`"""..."""`) or raw (`#"..."#`)
# literal at one of these call sites is invisible to it either way - neither flagged as missing
# nor required to be present - so a genuinely un-cataloged one of those would pass silently (no
# such usage exists in Sources/AnglesiteApp today). Treat a pass here as necessary, not
# sufficient: it complements, not replaces, the manual `.xcstrings` diff review CONTRIBUTING.md
# asks for.
#
# It separately flags model-layer error/status properties (see ERROR_PROPERTY_NAMES below)
# assigned a bare string literal instead of going through `String(localized:)` — that shape has
# no SwiftUI call site for either Xcode's real extractor or the checks above to see, so it
# silently ships untranslated (#1800, #1852).
#
# For a string literal containing interpolation (`\(expr)`), Xcode's real extractor turns each
# interpolation into a positional format specifier (%@, %lld, ...) chosen from the interpolated
# expression's type - this script can't type-check, so it matches any interpolation against a
# permissive `%<spec>` wildcard at that position instead of a specific specifier.
#
# Third, it lints the catalog's keys for owner-surface vocabulary the product direction forbids
# (#1963, decision D1 in docs/specs/2026-09-08-product-direction-review-decisions.md): git,
# commit, push, branch, SHA, packfile, bundle, npm, semver, package.json, wrangler, MCP,
# "dev server", Astro, `.git`/`.json`/`.toml` file names, `Source/`/`Config/` layout, and exit
# codes (see OWNER_VOCABULARY below). Keys whose only call sites are the Debug pane
# (Sources/AnglesiteApp/DebugPaneView*.swift) are exempt - that surface is for developers by
# definition - and reviewed exceptions live one per line in scripts/lib/owner-vocabulary-allowlist.txt
# (exact catalog key; `#` comments and blank lines ignored). An allowlist entry that no longer
# matches any catalog key is reported as a warning so the list can be pruned, not as a failure.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

sources_root="Sources/AnglesiteApp"
catalog="$sources_root/Localizable.xcstrings"

allowlist="scripts/lib/owner-vocabulary-allowlist.txt"

if [[ ! -f "$catalog" ]]; then
  echo "error: $catalog not found." >&2
  exit 1
fi

python3 - "$sources_root" "$catalog" "$allowlist" <<'PY'
import json
import re
import sys
from pathlib import Path

sources_root, catalog_path, allowlist_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])

with open(catalog_path, encoding="utf-8") as f:
    catalog_keys = set(json.load(f)["strings"].keys())

# First-positional-argument call sites whose parameter is LocalizedStringKey in stock SwiftUI.
CALL_NAMES = [
    "Text", "Button", "Label", "Toggle", "TextField", "SecureField",
    "Menu", "Section", "Picker", "GroupBox", "ContentUnavailableView",
]
# These only match up to and including the opening quote - the scanner below (which
# understands nested string literals inside `\(...)` interpolations, e.g.
# `\(x.joined(separator: ", "))`) finds the true end of the literal.
CALL_PATTERN = re.compile(r'\b(?:' + "|".join(CALL_NAMES) + r')\(\s*"')
LOCALIZED_PATTERN = re.compile(r'String\(localized:\s*"')
KEY_PATTERN = re.compile(r'LocalizedStringKey\(\s*"')

# Model-layer error/status properties assigned a bare string literal instead of
# String(localized: "...") are invisible to every pattern above (they're not one of the
# recognized call sites, and Xcode's real extractor never sees them either) - so they ship
# untranslated the moment a second locale lands (#1800). This list is deliberately just the
# handful of property names audited so far, not a general "*Error" heuristic - matching on name
# suffix alone would also flag every other similarly-named error property that hasn't been
# migrated yet, which would fail this check for code no current change touches. Extend this list
# deliberately as more properties are migrated (#1800 added the first batch, #1852 the second).
ERROR_PROPERTY_NAMES = [
    "errorMessage", "lastError", "loadError", "saveError", "renameError",
    "licenseGateError", "workerNameConflictError", "redirectsError", "utmCodesError",
    "licensingError", "langError", "mtaStsError", "securityReportingError", "deleteError",
    "redirectSaveError", "contentActionError",
]
BARE_ERROR_ASSIGN_PATTERN = re.compile(r'\b(?:' + "|".join(ERROR_PROPERTY_NAMES) + r')\s*=\s*"')

# Any interpolation could extract to %@, %lld, %ld, %d, %f, %u, or a positional variant
# (%1$@ etc.) depending on the interpolated expression's type - match permissively.
FORMAT_SPEC = r"%(?:[0-9]+\$)?[a-zA-Z@]+"

# Owner-surface vocabulary the primary UI must not use (#1963, D1). Word-bounded and
# case-insensitive; the file-name/layout entries deliberately match the extension or trailing
# slash so "anglesite.json" and "Source/" are caught but "JSON feed" or "source code" are not.
OWNER_VOCABULARY = re.compile(
    r"\bgit\b|\bcommit(?:s|ted|ting)?\b|\bpush(?:es|ed|ing)?\b|\bpull(?:s|ed|ing)?\b"
    r"|\bbranch(?:es)?\b|\bSHA\b|packfile|\bbundles?\b|\bnpm\b|\bsemver\b|package\.json"
    r"|\bwrangler\b|\bMCP\b|\bdev[ -]server\b|\bAstro\b|\.git\b|\.json\b|\.toml\b"
    r"|\bSource/|\bConfig/|\bexit code\b|\(exit ",
    re.IGNORECASE,
)
# The Debug pane is a developer surface - every key whose call sites are all in these files
# is exempt (matched against the pane's own string literals, interpolations and all).
DEBUG_PANE_GLOB = "DebugPaneView*.swift"

ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'", "0": "\0"}


def scan_literal(text, start):
    """text[start] is the character right after a string literal's opening quote.
    Returns (tokens, end_index): end_index is the closing quote's index, and tokens
    alternates ('text', decoded_str) / ('interp', raw_expr_str). Recurses into nested
    string literals inside `\\(...)` interpolations so an embedded quote (e.g.
    `\\(x.joined(separator: ", "))`) doesn't end the outer literal early."""
    tokens, buf, i, n = [], [], start, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            tokens.append(("text", "".join(buf)))
            return tokens, i
        if c == "\\" and i + 1 < n:
            nc = text[i + 1]
            if nc == "(":
                tokens.append(("text", "".join(buf)))
                buf = []
                expr, after = scan_interpolation(text, i + 2)
                tokens.append(("interp", expr))
                i = after
                continue
            if nc == "u" and i + 2 < n and text[i + 2] == "{":
                close = text.find("}", i + 3)
                if close != -1:
                    try:
                        buf.append(chr(int(text[i + 3 : close], 16)))
                        i = close + 1
                        continue
                    except ValueError:
                        pass
            if nc in ESCAPES:
                buf.append(ESCAPES[nc])
                i += 2
                continue
            # Unrecognized escape - best effort, keep the backslash literally.
            buf.append(c)
            i += 1
            continue
        buf.append(c)
        i += 1
    # Unterminated literal (shouldn't happen in valid Swift) - return what we have.
    tokens.append(("text", "".join(buf)))
    return tokens, n


def scan_interpolation(text, start):
    """text[start] is the character right after `\\(`. Returns (raw_expr, index_after_close_paren)."""
    depth, i, n = 1, start, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            _tokens, end = scan_literal(text, i + 1)
            i = end + 1
            continue
        if c == "(":
            depth += 1
            i += 1
            continue
        if c == ")":
            depth -= 1
            i += 1
            if depth == 0:
                return text[start : i - 1], i
            continue
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        i += 1
    return text[start:i], i


def render(tokens):
    """Best-effort human-readable reconstruction of a token list, for error messages."""
    return "".join(val if kind == "text" else f"\\({val})" for kind, val in tokens)


def literal_present(tokens):
    if not any(kind == "interp" for kind, _ in tokens):
        return "".join(val for _, val in tokens) in catalog_keys
    # A string with interpolation is extracted as a format string, so any literal `%`
    # in the text portions is escaped to `%%` in the catalog key.
    parts = []
    for kind, val in tokens:
        if kind == "text":
            parts.append(re.escape(val.replace("%", "%%")))
        else:
            parts.append(FORMAT_SPEC)
    pattern = re.compile("^" + "".join(parts) + "$")
    return any(pattern.match(key) for key in catalog_keys)


missing = []
bare_assignments = []
for path in sorted(sources_root.rglob("*.swift")):
    text = path.read_text(encoding="utf-8")
    for pattern in (CALL_PATTERN, LOCALIZED_PATTERN, KEY_PATTERN):
        for m in pattern.finditer(text):
            tokens, _end = scan_literal(text, m.end())
            if not tokens or all(kind == "text" and not val for kind, val in tokens):
                continue
            if not literal_present(tokens):
                line = text.count("\n", 0, m.start()) + 1
                missing.append((str(path), line, render(tokens)))
    for m in BARE_ERROR_ASSIGN_PATTERN.finditer(text):
        tokens, _end = scan_literal(text, m.end())
        if not tokens or all(kind == "text" and not val for kind, val in tokens):
            continue
        line = text.count("\n", 0, m.start()) + 1
        bare_assignments.append((str(path), line, render(tokens)))

# --- Owner vocabulary lint (#1963) ---------------------------------------------------------
# Every string literal in the Debug pane, as a (has_interpolation, key-or-pattern) pair, so a
# catalog key can be tested for "is this one of the Debug pane's own strings".
debug_literals = []
for path in sorted(sources_root.rglob(DEBUG_PANE_GLOB)):
    text = path.read_text(encoding="utf-8")
    pos = 0
    while True:
        start = text.find('"', pos)
        if start == -1:
            break
        tokens, end = scan_literal(text, start + 1)
        pos = end + 1
        if not tokens or all(kind == "text" and not val for kind, val in tokens):
            continue
        if any(kind == "interp" for kind, _ in tokens):
            parts = []
            for kind, val in tokens:
                parts.append(re.escape(val.replace("%", "%%")) if kind == "text" else FORMAT_SPEC)
            debug_literals.append(re.compile("^" + "".join(parts) + "$"))
        else:
            debug_literals.append("".join(val for _, val in tokens))


def is_debug_pane_key(key):
    for lit in debug_literals:
        if isinstance(lit, str):
            if lit == key:
                return True
        elif lit.match(key):
            return True
    return False


allowlisted = set()
if allowlist_path.exists():
    for raw in allowlist_path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        allowlisted.add(line)

vocabulary_hits = []
for key in sorted(catalog_keys):
    m = OWNER_VOCABULARY.search(key)
    if not m:
        continue
    if key in allowlisted or is_debug_pane_key(key):
        continue
    vocabulary_hits.append((key, m.group(0)))

stale_allowlist = sorted(entry for entry in allowlisted if entry not in catalog_keys)

had_error = False

if missing:
    had_error = True
    missing.sort()
    print(
        f"error: {len(missing)} localizable string literal(s) in {sources_root} have no "
        f"matching key in {catalog_path}:",
        file=sys.stderr,
    )
    for path, line, raw in missing:
        print(f"  {path}:{line}: \"{raw}\"", file=sys.stderr)
    print(
        "\nSee CONTRIBUTING.md's \"Commit String Catalog updates\" section for how to "
        "regenerate the catalog locally, then review and commit the .xcstrings diff.",
        file=sys.stderr,
    )

if bare_assignments:
    had_error = True
    bare_assignments.sort()
    print(
        f"error: {len(bare_assignments)} assignment(s) in {sources_root} give "
        + "/".join(ERROR_PROPERTY_NAMES)
        + " a bare string literal instead of String(localized: \"...\") (#1800, #1852):",
        file=sys.stderr,
    )
    for path, line, raw in bare_assignments:
        print(f"  {path}:{line}: \"{raw}\"", file=sys.stderr)
    print(
        "\nWrap the literal in String(localized: \"...\") so Xcode's extractor - and this "
        "script's own checks above - can see it.",
        file=sys.stderr,
    )

if vocabulary_hits:
    had_error = True
    print(
        f"error: {len(vocabulary_hits)} {catalog_path} key(s) use git/npm/wrangler/MCP/file-layout "
        "vocabulary on the owner-facing surface (#1963, decision D1):",
        file=sys.stderr,
    )
    for key, word in vocabulary_hits:
        print(f"  {word!r} in {json.dumps(key)}", file=sys.stderr)
    print(
        "\nRewrite the string in owner terms (what happened to the site, never git/npm/file "
        "layout) and keep the technical detail under a Details disclosure or in the Debug pane. "
        f"A reviewed exception goes in {allowlist_path}, one exact key per line.",
        file=sys.stderr,
    )

if stale_allowlist:
    print(
        f"warning: {len(stale_allowlist)} {allowlist_path} entr{'y' if len(stale_allowlist) == 1 else 'ies'} "
        "no longer match any catalog key - prune:",
        file=sys.stderr,
    )
    for entry in stale_allowlist:
        print(f"  {json.dumps(entry)}", file=sys.stderr)

if had_error:
    sys.exit(1)

print(
    f"✓ every scanned localizable literal in {sources_root} has a matching {catalog_path} key, "
    f"and no key uses owner-surface vocabulary outside {allowlist_path} or the Debug pane."
)
PY

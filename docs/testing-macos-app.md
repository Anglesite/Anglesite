# Building and Smoke-Testing the macOS App (headless / agent guide)

How to build, test, launch, and smoke-test the `Anglesite` macOS app from a
CLI-only session — the workflow every dispatched agent (and any human working
without the Xcode GUI) should follow. Human-facing IDE setup lives in
[xcode-setup.md](xcode-setup.md); the required pre-PR suites are listed in
[CONTRIBUTING.md ▸ Testing](../CONTRIBUTING.md#testing); scripted manual QA
runs live in [qa/](qa/).

**Prime directive: never conclude "the build/test tooling is not available"
without running the preflight below.** On this repo's dev machines the
toolchain *is* installed; every known case of an agent reporting it missing
was an environment-resolution problem — `xcode-select` pointing at
CommandLineTools, an ungenerated `.xcodeproj` in a fresh worktree, or `node`
loaded via nvm in one shell but not another — not absent tooling.

## Preflight (30 seconds)

| Probe | Expect | If not |
|---|---|---|
| `xcode-select -p` | a path inside an Xcode app, e.g. `/Applications/Xcode-beta.app/Contents/Developer` | If it prints `/Library/Developer/CommandLineTools`, do **not** try `xcode-select --switch` (needs sudo). Export `DEVELOPER_DIR` instead — see below. |
| `xcodebuild -version` | `Xcode 27.0` or newer | An older Xcode may be selected while a newer one sits in `/Applications`. Check `ls -d /Applications/Xcode*.app` and point `DEVELOPER_DIR` at a 27+ install. |
| `xcodegen --version` | any version | `brew install xcodegen` |
| `ls Anglesite.xcodeproj` | exists | Expected to be missing in a fresh worktree — run `xcodegen generate`. Not an error. |
| `node --version` | v22+ | Only needed for JS/edit-overlay and template checks. Node is often nvm-managed: absent from a bare hook/login shell but present in your interactive tool shell. Probe in the same shell you'll build in before concluding it's missing. |

When the selected Xcode is wrong or missing, prefix commands rather than
mutating machine state:

```sh
# Pick whichever /Applications/Xcode*.app is 27+ (check with -version):
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

Shell state does not persist between agent tool calls — re-export (or prefix
inline: `DEVELOPER_DIR=… swift test`) on every invocation that needs it.

The repo's Claude Code `SessionStart` hook
([`.claude/hooks/session-start.sh`](../.claude/hooks/session-start.sh)) prints
this preflight automatically at session start on macOS; read its report before
diagnosing toolchain problems from scratch.

## Build

```sh
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

- `scripts/build-app.sh` runs `xcodegen generate` itself before delegating to
  `xcodebuild`, so a stale or missing `.xcodeproj` is handled (#123). Use it
  instead of raw `xcodebuild`.
- Debug builds are ad-hoc signed — no Apple account, and the
  `com.apple.security.virtualization` entitlement works ad-hoc, so a Debug
  build can boot the local container runtime.
- A clean worktree build takes several minutes; incremental rebuilds are fast.
  Run it in the background and poll rather than sitting on a foreground
  timeout.

### Container boot artifacts (fresh worktrees)

`Resources/container-{image,kernel,initfs}/` are **gitignored** build
artifacts, so a fresh worktree has empty dirs. Consequences:

- **Debug** builds *warn* ("Check container resources") and continue.
- **Release** builds *fail* on the same check.
- An unprovisioned Debug app launches fine but every site preview fails at
  runtime with `imageLayoutNotProvisioned; kernelNotProvisioned;
  initfsNotProvisioned`.

For a runtime smoke you don't need Docker or the vendor scripts — copy the
artifacts from the main checkout (the first entry in `git worktree list`),
**before** building, since they're bundled into the app at build time:

```sh
MAIN=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
for d in container-image container-kernel container-initfs; do
  rsync -a --delete "$MAIN/Resources/$d/" "Resources/$d/"
done
```

Only re-vendor from scratch (`scripts/vendor-container-image.sh` +
`scripts/vendor-container-kernel.sh`, with `ANGLESITE_SIDECAR_SRC` pointing at
the real sidecar checkout — the default `../anglesite` resolves wrong from a
worktree) when the image itself changed; that path needs Docker and is slow.

## Automated tests

The canonical pre-PR suites and their gotchas are in
[CONTRIBUTING.md ▸ Testing](../CONTRIBUTING.md#testing). Agent-specific notes:

- Prefix `DEVELOPER_DIR=…` if the preflight said so; otherwise `swift test`
  runs against a broken/old CommandLineTools toolchain and fails in confusing
  ways.
- `swift test` hanging with no output usually means a stale SwiftPM process
  holds the `.build` lock — `pgrep -fl swift-test`, kill the orphan.
- **Run full suites through `scripts/swift-test.sh`, not bare `swift test`**
  (multiple agents!). It takes a machine-scoped lock —
  `/tmp/anglesite-swift-test.lock`, an atomic `mkdir` directory, released on
  exit/Ctrl-C — so two full runs on one Mac serialize instead of colliding, and
  it prints who holds the lock (pid, worktree, since) while it waits. Arguments
  pass straight through (`scripts/swift-test.sh --filter Foo`); a `--filter`
  run of suites that never touch the model skips the lock. Why (#1594):
  on-device FoundationModels inference is serialized by a **system-wide**
  daemon across all processes — six concurrent standalone probes completed one
  solo-length turn each at exact 10s intervals, pure FIFO — so two `swift test`
  processes issuing live-model turns multiply each other's per-turn wall clock
  past the suites' own timeouts (the "flake"/"hang"). It is not `.build`-lock,
  temp-path, or port contention, and compilation (`scripts/build-app.sh`) is
  unaffected. Hand-rolling the same `mkdir /tmp/anglesite-swift-test.lock` /
  `rmdir` pair is compatible with the wrapper (it waits on a bare lock and
  never reclaims one), but the wrapper adds holder info, stale-lock reclaim,
  and `ANGLESITE_TEST_LOCK_WAIT=fail` for fail-fast callers — see its header.
- `swift test --filter X` still *compiles* the whole package — a broken
  sibling target blocks a filtered run too.

## Smoke-testing the built app

1. **Locate the product:**

   ```sh
   APP="$(xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')/Anglesite.app"
   ```

2. **(Optional) create a site fixture** so there's something to open:
   `scripts/create-smoke-fixture.sh` mirrors `Resources/Template/` into
   `~/Sites/anglesite-smoke/` (idempotent).

3. **Launch and verify it's alive:**

   ```sh
   open "$APP"
   sleep 5 && pgrep -x Anglesite   # prints a PID if the app is running
   ```

   For stdout/stderr in your terminal, launch the binary directly instead:
   `"$APP/Contents/MacOS/Anglesite" &`. System-log capture:
   `log stream --process Anglesite`. In-app, the Debug pane streams every
   spawned subprocess's output — that's the primary diagnostic surface.

4. **Visual check (optional):** if a screenshot-capable MCP tool is available
   in your session, use it (`mcp__computer-use__screenshot` is pre-allowlisted
   in [`.claude/settings.json`](../.claude/settings.json)); otherwise
   `screencapture -x /tmp/anglesite-smoke.png` (requires the host terminal to
   have Screen Recording permission — if the capture comes back without the
   app window, that permission is the reason, not the app).

5. **Quit:** `osascript -e 'tell application "Anglesite" to quit'` (graceful;
   first use may prompt the user for Automation permission) — fall back to
   `pkill -x Anglesite`.

A smoke launch on the user's machine opens visible UI — fine for a
verification pass, but quit the app when you're done.

### Accessibility identifiers (AX automation)

Key controls carry stable `accessibilityIdentifier`s (#1535), defined in
[`Sources/AnglesiteApp/AXID.swift`](../Sources/AnglesiteApp/AXID.swift):
site-window toolbar items derive `toolbar.<SiteToolbarItemID>` (e.g.
`toolbar.deploy`), and the navigator, launcher, shared sheet header, Website
Settings takeover, and debug pane have hand-assigned dotted IDs (`navigator.list`,
`launcher.list`, `sheet.header`, `settings.tabs`, `debug.pause`). Per-item rows
derive theirs from an already-stable, non-localized key: Workers-tab rows from
the catalog worker id (`settings.workers.toggle.<workerID>`,
`settings.workers.status.<workerID>`) and the debug pane's Local Workers rows
from the site id (`debug.worker.<siteID>` for the row group, then `.name`,
`.status`, `.url`, `.copy`, `.failure` beneath it). `AXIDTests` freezes format
and uniqueness — treat the strings as automation API: renaming one breaks
external scripts, same contract as `SiteToolbarItemID`.

They surface as the AX element's `AXIdentifier` attribute (what XCUITest
matches as `identifier`), so UI scripting can target controls without
depending on localized labels. **Gate:** reading another app's AX tree
requires the agent-host process to have Accessibility permission — without it
every System Events query fails with `osascript is not allowed assistive
access`, an owner-only grant in System Settings ▸ Privacy & Security ▸
Accessibility. Example (once granted):

```sh
osascript -e 'tell application "System Events" to tell process "Anglesite" to get value of attribute "AXIdentifier" of buttons of toolbar 1 of window 1'
```

### Re-verifying navigator keyboard-focus gating (#1732, #1747)

The navigator's Return-to-rename **and** ⌘⌫-to-delete key equivalents
([`SiteNavigatorView.swift`](../Sources/AnglesiteApp/SiteNavigatorView.swift))
are each attached only while the navigator `List` holds keyboard focus (⌘⌫ is
additionally ANDed with `!previewHasKeyboardFocus`, #1715/#1730), and a click
on a row gives the list that focus via a `simultaneousGesture(TapGesture())`.
None of this has automated coverage: `@FocusState` only reflects focus for a
key window in an active app, and a hosted `swift test` process is not reliably
either (a synthesized `NSWindow.sendEvent` click doesn't even select a row
there), so a hosted test would flake. If you touch that file's `.focused`,
`simultaneousGesture`, `if listHasKeyboardFocus` (Return), or
`if listHasKeyboardFocus && !previewHasKeyboardFocus` (⌘⌫) blocks, re-verify by
hand on a Debug build (launch per the steps above; Full Keyboard Access off):

1. **Return leak check — the #1732 repro.** Select a navigator row → Website ▸
   Graph… → Tab until focus is in the takeover's Explorer outline → ↓ →
   Return. The navigator must not show a rename field
   (`navigator.renameField` absent from the AX tree), its selection must be
   unchanged, and focus must stay in the Explorer.
2. **⌘⌫ leak check — the #1747 repro.** Same setup, but press ⌘⌫ instead of
   Return once focus is in the Explorer outline. No delete confirmation for
   the navigator's selection must appear, the selection must be unchanged, and
   focus must stay in the Explorer.
3. **Click-to-focus.** Fresh launch → click a row, with no Tab first. ↓ must
   move the selection, Return must open the rename field (Esc cancels), and
   ⌘⌫ (with the rename field not open) must show the delete confirmation.
   Repeat with the Graph takeover open and a navigator click closing it.
4. **Commit path.** Return inside an active rename field commits it: the field
   disappears, focus returns to the list, and Return renames again.

With Accessibility permission granted (see above), `AXFocusedUIElement` of the
app's window via System Events tells you which control holds focus at each
step; `navigator.list` and `navigator.renameField` are the two identifiers
involved. The one premise that *can* be checked in-process — that `.focused`
on the `List` stays true while the descendant rename `TextField` is first
responder — is a ~60-line `NSHostingView` probe of the same
List › OutlineGroup › TextField nesting; the click-to-focus gap is not
reproducible that way.

### Cloudflare OAuth sign-in needs a company-team build (#1767)

"Sign in with Cloudflare" (#1204) round-trips through `ASWebAuthenticationSession`'s
`.https(host:path:)` callback matching, which Apple resolves via Associated
Domains — a capability Xcode refuses to provision for a personal development
team ("Personal development teams... do not support the Associated Domains and
iCloud capabilities"). Only a build signed with the `M34HBJZNYA` company team
can complete the flow; an ad-hoc/personal-team Debug build cannot, regardless
of whether the callback Worker's DNS and deployment (tracked separately in
#1767) are otherwise in place. On a personal-team Debug build, use the legacy
pasted API token instead (Settings ▸ Advanced) to exercise deploy/harden flows
that need a Cloudflare credential.

## Xcode MCP (optional, richer control)

Xcode 27 ships an MCP server (`xcrun mcpbridge`) that gives external agents
Xcode's own capabilities: build with Issue Navigator diagnostics, run/stop
with console output, list/run tests, LLDB commands, SwiftUI preview
rendering, simulator interaction, and documentation search. See Apple's
[Giving external agents access to Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode).

One-time setup (needs the human at the keyboard):

1. Xcode ▸ Settings ▸ Intelligence ▸ Model Context Protocol → enable
   **Allow external agents to use Xcode tools**.
2. Register the server with your agent, e.g. for Claude Code:

   ```sh
   claude mcp add --transport stdio xcode -- xcrun mcpbridge
   ```

At use time the bridge requires a **running** Xcode 27+ with
`Anglesite.xcodeproj` open (`open Anglesite.xcodeproj` — never `xed .`, which
opens `Package.swift` with no runnable target). Xcode alerts the user when an
agent connects. With no running Xcode, `mcpbridge` exits with a fatal error —
which is why this repo deliberately does **not** commit a project-scoped
`.mcp.json`: most agent sessions here are headless, and a committed entry
would fail on connect in every one of them.

Ground rules:

- The CLI path above is **authoritative** for build/test pass-fail. Xcode MCP
  is additive — never block or fail a task because it's unavailable.
- Prefer it when you specifically need what the CLI can't give you: Issue
  Navigator diagnostics, LLDB on a running instance, SwiftUI preview renders,
  or driving the app's UI.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `xcodebuild: error: … does not contain an Xcode project` | Fresh worktree; `.xcodeproj` is gitignored | `xcodegen generate` (or just use `scripts/build-app.sh`) |
| `swift` missing, ancient, or failing with toolchain errors | `xcode-select` points at CommandLineTools | `export DEVELOPER_DIR=/Applications/Xcode…app/Contents/Developer` (27+) |
| `error: cannot find 'X' in scope` on code that clearly exists | Stale generated `.xcodeproj` (checkout synced via fetch+reset) | `scripts/build-app.sh` regenerates before building |
| `vendor-node.sh: Operation not permitted` during build | Stale `.xcodeproj` picked up `ENABLE_USER_SCRIPT_SANDBOXING=YES` (Xcode's "recommended settings") | `xcodegen generate`; decline Xcode's recommended-settings prompt |
| "Check container resources" build warning (Debug) / error (Release) | Gitignored container artifacts absent in this worktree | rsync the three `Resources/container-*` dirs from the main checkout (see above), then rebuild |
| App runs but previews fail: `imageLayoutNotProvisioned; …` | Same as above — app was built without the artifacts | Same rsync, then rebuild |
| `swift test` produces no output for minutes | Stale SwiftPM process holds the `.build` lock | `pgrep -fl swift-test`; kill the orphan |
| FoundationModels test suites flake or hang | Two `swift test` runs issuing live-model turns on one machine — the on-device inference daemon is a system-wide FIFO queue (#1594) | Run full suites via `scripts/swift-test.sh` (machine-scoped lock); a bare `swift test` bypasses it |
| `scripts/swift-test.sh` sits at "waiting for swift test lock held by …" | Another full run holds `/tmp/anglesite-swift-test.lock` — expected; a *stale* lock (dead holder pid) is reclaimed automatically | Wait (Ctrl-C bails out at once with exit 130 and leaves the holder's lock alone), or `ANGLESITE_TEST_LOCK_WAIT=fail` to fail fast (exit 75). A bare `mkdir` lock with no `holder` file and no live `swift test` anywhere (`pgrep -fl swift-test`) was left by a killed hand-rolled run: `rmdir` it |
| `xed .` opened the wrong thing | `Package.swift` has no runnable target | `open Anglesite.xcodeproj` |
| `xcrun mcpbridge` → `Fatal error: … no running Xcode processes found` | Xcode MCP needs a live Xcode | Start Xcode with the project open, or use the CLI path |

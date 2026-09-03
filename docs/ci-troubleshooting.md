# CI Troubleshooting Runbook

`.github/workflows/ci.yml` gates every PR with ~20 jobs. This runbook lifts the
hard-won facts out of that file's inline comments — why a lane is shaped the
way it is, what a red run there usually means, and what to check first —
into one place, organized by lane. When a lane goes red, find its section
below before re-deriving the diagnosis from scratch.

For the day-to-day mechanics of running these suites locally, see
[`CONTRIBUTING.md`](../CONTRIBUTING.md) ▸ Testing and
[`docs/testing-macos-app.md`](testing-macos-app.md). This document is about
diagnosing a *red CI run*, not about how to run the suites yourself.

## How the workflow is gated

The `changes` job (first in the workflow) diffs the push/PR against its base
and sets one boolean output per path group (`swift`, `js`, `wysiwyg`,
`safariExt`, `template`, `helpBook`, `workers`). Every other job except
`reuse-lint` and the final `ci` aggregator is conditional on one of those
outputs, so most red runs are scoped to the area you actually touched. If a
job you expected to run shows as *skipped* instead, check `changes`' own
"Detect changed paths" step output first — a path you touched may not be in
any group's match list (see the `matches` patterns in that step).

The `ci` job at the end is the single required-status-check: it fails loudly
if `changes` itself errored (which would otherwise silently skip everything
downstream) or if any of its `needs` jobs failed. If GitHub shows "CI" red
but every individual lane looks green, re-read `ci`'s own step — it's telling
you `changes` didn't succeed.

## macOS toolchain selection, across every macOS lane

Every macOS job (`build-test`, `xcode27-compile`, `ios-build`,
`concurrency-tsan` — deliberately only four per Swift PR, see
[#1865](https://github.com/Anglesite/Anglesite/issues/1865)) picks
"newest installed Xcode" itself rather than relying on the runner's default,
via a `ls -d /Applications/Xcode*.app | sort -V | tail -1` + `xcode-select -s`
step. Most of these also `grep -vE` out `Xcode_26.3`: that toolchain builds
test targets linking `libswift_DarwinFoundation3.dylib`, which the current
runner image doesn't ship, so `swift test` fails to load
`AnglesitePackageTests.xctest` with "Library not loaded". If a lane fails at
the "Select latest available Xcode" step itself, or immediately after with a
dyld/"Library not loaded" error, check whether a new Xcode version landed on
the runner image that needs excluding the same way — the fix is almost never
in this repo's Swift code.

## `build-test` — main macOS build/test (macos-26)

**What it runs:** checks out the sibling `anglesite-skills` plugin (pinned to
a specific tag — see `ref: v1.9.0` in the job), installs its deps, verifies
the `container-image.json` and `website-template.json` attributions
manifests, builds the package in debug, runs the full `swift test --parallel`
(skipping the timing-sensitive filter), then runs the timing-sensitive
suites in their own isolated `swift test` process (see below), checks for
leaked test `UserDefaults` suites, builds the DocC documentation for the
library targets (see below), builds in release, and — only on `main` —
saves the SwiftPM `.build` cache. The timing-sensitive and DocC steps were
separate macOS jobs until [#1865](https://github.com/Anglesite/Anglesite/issues/1865):
each rebuilt the same package for minutes to run seconds of checks, and each
queued up to an hour for one of the org's five concurrent macOS runner
slots. As steps here they reuse this job's warm build. A red in one of them
is reported under `build-test`, so read the step name in the job summary
before assuming the main `Test` step failed.

**macOS job budget:** every Swift PR fans out to exactly four macOS jobs
(`build-test`, `concurrency-tsan`, `ios-build`, `xcode27-compile`) on
purpose. The org's plan allows five concurrent macOS jobs in total, so any
new macOS *job* — even a 12-second script — costs every other open PR an
hour of runner queue. Add a new Swift check as a step in the lane that
already has the build it needs (this one for SwiftPM, `ios-build` for the
Xcode project), never as a new job.

**Why macos-26, not macos-15:** the `macos-15` image's OS
`libswift_Concurrency` (Swift 6.2.3-era, no assertions) carries a
task-allocator bug (`swiftlang/swift#86204`-class) that crashed a test run
5/5 with "freed pointer was not the last allocation" — the trigger is an
allocation pattern in the compiled binary, not any specific test, so any PR
can trip it on that image. macOS 26.4's runtime (Swift 6.3+) has the fix.
See [#644](https://github.com/Anglesite/Anglesite/issues/644) /
[#646](https://github.com/Anglesite/Anglesite/issues/646).

**What a red usually means, and what to check first:**

- **Fails at "Check container-image attributions manifest" or "Check
  website-template attributions manifest":** you added/removed/upgraded an
  npm dependency in the sidecar's `node_modules` or `Resources/Template/`
  without regenerating the committed manifest. Run
  `scripts/generate-npm-attributions.mjs` locally against the same input and
  commit the diff. The website-template manifest is arm64-only (`npm ci`
  pulls `@esbuild/darwin-arm64` and friends), which is why this check lives
  here (macos-26) and not in the Linux `template-worker` lane.
- **Fails at "Check app-binary attributions manifest":** same idea, but for
  the full macOS app's Swift Package dependency graph. This step restores
  `Package.resolved` from git and re-resolves rather than deleting the lock
  file — deleting it would let SwiftPM pick whatever is newest upstream at
  CI-run time, which drifts independently of any change in this repo
  (confirmed: an unrelated upstream `swift-service-lifecycle` bump broke this
  exact check on `main` with no local diff, 2026-08-18). If you see this red
  with no attribution-relevant change of your own, suspect upstream drift in
  a pinned dependency before your PR.
- **Fails at "Test" with a compile error you can't find in the log:** the
  "Surface Swift errors" step re-derives it from `$RUNNER_TEMP/swift-test.log`
  via `scripts/annotate-swift-log.sh` — a test-target compile error can
  scroll ~95s of Swift-6-language-mode warnings past it and leave only a bare
  `error: fatalError` sentinel at the tail otherwise (misdiagnosed as a
  toolchain crash four times before this annotation step existed — see
  [#1335](https://github.com/Anglesite/Anglesite/issues/1335)). Check the job
  summary/annotations, not just the raw log tail.
- **Fails at "Check no test UserDefaults suites leaked":** a test used a
  hand-rolled `UserDefaults(suiteName:)` instead of
  `AnglesiteTestSupport`'s `TemporaryUserDefaults` and left a plist behind.
  See `CONTRIBUTING.md` ▸ Testing and
  [#1727](https://github.com/Anglesite/Anglesite/issues/1727).
- **Fails at "Test" with suites named in the timing-sensitive filter still
  showing up:** they shouldn't run here at all — see the timing-sensitive step
  below; if one of them still executed in this lane, the skip filter and the
  lane's suite list have drifted apart.

## `xcode27-compile` — Swift 6.4 compile check (Xcode 27 preview, non-required)

**What it runs:** `swift build --build-tests` (compile only, never `swift
test`) on the `xcode-27` preview runner image, covering the
`#if compiler(>=6.4) && canImport(Darwin)`-gated targets (`AnglesiteAppCore`,
`AnglesiteAppTests`, `AnglesiteIntentsTests`) that `build-test`'s Xcode 26.6
toolchain can't even see in its package graph.

**Why compile-only, and why non-required:** the `xcode-27` image pairs the
Xcode 27 SDK with a **macOS 26.x host**, and this package's `.macOS("27.0")`
deployment target makes every macOS-27-only symbol a hard dyld bind — so
built test bundles can't be *loaded* on that host, only compiled. Verified
live across four runs, each clearing one dyld wall only to hit the next
27-only bind (a CoreSpotlight/FoundationModels cross-import overlay,
CloudKit's async overlay, and finally `AppIntents.EntityQuery
.allowedExecutionTargets` — inside `AnglesiteIntentsTests` itself, one of the
suites this lane exists for). Run coverage has to wait for a hosted image
whose **host OS** is macOS 27, not just its SDK. Until then, this lane
`continue-on-error: true`s and is deliberately excluded from `ci`'s `needs`
list — the runner image is a preview (possible instability/queueing) and its
Xcode is a beta build, so it must not block unrelated PRs. See
[#855](https://github.com/Anglesite/Anglesite/issues/855).

**What a red (or ⚠️ orange) usually means:** a genuine compile error in one
of the three gated targets — this is real signal even though the job is
non-required, since it's the *only* CI coverage those targets get at all
(`build-test` can't see them, and this lane can't execute them either). If
the "Select latest available Xcode" step itself fails with "has no Xcode 27",
the preview image regressed to an older default Xcode; that's an
infrastructure issue, not a code issue. Once the `xcode-27` image reaches GA,
this lane should flip its build step back to `swift test`, drop
`continue-on-error`, and join `ci`'s `needs` (per the
[#855](https://github.com/Anglesite/Anglesite/issues/855) owner decision,
2026-08-15) — if you're revisiting this lane, check whether that promotion is
now overdue. Until then, run `swift test` locally on Xcode 27 for actual
execution coverage of these targets before opening a PR that touches them
(see `CONTRIBUTING.md` ▸ Testing).

## Timing-sensitive suites — `build-test`'s isolated-process step (macos-26)

*Was the separate `timing-sensitive-tests` job until #1865.*

**What it runs:** `scripts/test-timing-sensitive.sh`, which runs (via
`scripts/lib/timing-sensitive-tests.sh`'s `TIMING_SENSITIVE_TEST_FILTER`) a
named subset of suites that assert real wall-clock budgets — real sockets,
real subprocess spawns, `ContinuousClock` deadlines — in their own
low-concurrency `swift test` invocation, isolated from `build-test`'s
~4,700-test `--parallel` run. `build-test`'s main `Test` step explicitly
`--skip`s this same filter, so each suite runs exactly once, in the "Test
(timing-sensitive suites, isolated process)" step that follows it. No
`ANGLESITE_PLUGIN_PATH` is set for that step (matching the old lane), so the
e2e-gated variants inside these suites stay skipped.

**Why this step exists:** `build-test`'s shared GCD/dispatch thread pool gets
oversubscribed badly enough under full parallel load that these suites miss
their own real-I/O deadlines — a scheduling artifact, not a code defect. PR
[#1289](https://github.com/Anglesite/Anglesite/issues/1289) saw `build-test`
fail 7/7 times on an unmodified commit, rotating through different timed-out
suites with no code change between retries. See
[#1344](https://github.com/Anglesite/Anglesite/issues/1344) for the full
writeup and inclusion criteria for which suites belong in the filter.

**What a red usually means, and what to check first:** a suite timing out
in this step (a low-concurrency process with nothing else running on the
runner) is much more likely to be a *real* regression than the same suite
flaking under the main `Test` step's full parallel load — don't reflexively
blame scheduler contention for a failure that shows up here. If a *new* suite you added is
flaky specifically under `build-test`'s parallel run but stable alone or
here, it's a candidate to add to `scripts/lib/timing-sensitive-tests.sh`
(each entry there documents its own evidence — follow that pattern). Same
"Surface Swift errors" annotation step and same
`check-test-userdefaults-leak.sh` belt-and-suspenders check as `build-test` —
see that section above for both.

## `concurrency-tsan` — ThreadSanitizer suites (macos-26)

**What it runs:** `scripts/test-concurrency-tsan.sh`, `--sanitize thread`
against a fixed suite filter (`TurnRelay|TextStreamRelay|ProcessSupervisor|
DomainConfigStore`) — deliberately scoped, not "every concurrency suite", to
keep the run fast and avoid sanitizing the model-gated FoundationModels
tests.

**Why this lane exists:** the relay suites' `concurrentDeliver*` tests
exercise a producer/consumer race only *probabilistically* under a normal
Debug build — a regression (dropped lock, torn read, wrong terminal-event
ordering) can slip through plain CI by timing luck. TSan flags data races
deterministically regardless of timing. `ProcessSupervisor`/
`InProcessBackend` joined per
[#856](https://github.com/Anglesite/Anglesite/issues/856) (a `swift test
--parallel` run crashed signal 6 inside a concurrently-mutated Dictionary,
did not reproduce on rerun, and passed a manual actor-isolation audit —
this lane exists to catch it deterministically if it's real).
`DomainConfigStore` joined per
[#1255](https://github.com/Anglesite/Anglesite/issues/1255), though note
that one is a **file-on-disk** lost-update race, not an in-process memory
race TSan actually instruments — running it here just perturbs scheduling,
which can help surface the interleaving its concurrent-producers test
relies on, but is not sanitizer-guaranteed the way the relay suites are.

**What a red usually means:** treat a TSan failure here as a real data race
until proven otherwise — that's the whole point of the lane. Read the race
report's two stack traces; the "same class as #203/#856" precedent above is
a starting hypothesis, not a default verdict. If you're adding a new suite
here, keep the `--filter` scoped the way the job comment describes: a bare
`Relay` pattern would also match `AnglesiteP2PTests`/`HMRRelayTests`, whose
20ms timing windows balloon 5-15x under the sanitizer and are intentionally
excluded.

## `linux-flatpak-build` — Flatpak manifest + AnglesiteLinux (non-required)

**What it runs:** builds `packaging/flatpak/io.dwk.anglesite.linux.yml` for
real inside a GNOME-SDK Flatpak sandbox and runs `AnglesiteLinuxTests`
(`ShellModel`'s pure overlay-candidate logic — the only Linux-portable target
today; `AnglesiteCoreTests` is out of scope, tracked in
[#1284](https://github.com/Anglesite/Anglesite/issues/1284)) inside the build
shell via `flatpak-builder --build-shell`.

**Why this lane is `continue-on-error: true`:** `adwaita-swift` is pinned to
a revision in `Package.swift`, but *its own* dependencies (Meta and friends)
are branch-based and float — SwiftPM rejects a root-level revision pin of a
dependency another package requires by branch ("required using two different
revision-based requirements"), so those transitive deps cannot be frozen
from this repo. An upstream push to their `main` can break this lane with
**no change here**. This has happened twice:
[#1385](https://github.com/Anglesite/Anglesite/issues/1385) (Meta's `main`
dropped `WidgetData.stateManager`, then restored it days later) and
[#1760](https://github.com/Anglesite/Anglesite/issues/1760) (Meta's `main`
switched to Swift 6 language mode, breaking every pre-Swift-6
`adwaita-swift` revision until it followed an hour later). Because upstream
drift can wedge this lane red with zero relevant diff, it must not block
unrelated PRs — `AnglesiteLinux` also stays behind the
`ANGLESITE_LINUX_SHELL=1` opt-in gate regardless, so a red run here never
affects what ships.

**What a red usually means, and what to check first:**

1. **Check whether the failure is inside `.build/checkouts`** (a Swift
   compile error attributed to `adwaita-swift`'s or a transitive
   dependency's own source, not this repo's) **before suspecting your own
   change.** That's the upstream-drift pattern above, not a regression in
   this PR.
2. **The fix is bumping the `adwaita-swift` pin** in `Package.swift` (under
   the `ANGLESITE_LINUX_SHELL == "1"` block) to the first commit that
   compiles against the transitive dependency's new `main` — the pin
   comment documents the exact commits from both past incidents as a
   worked example of how to read the error and find the fix commit.
3. A cached Flatpak runtime (`~/.local/share/flatpak`, keyed on the manifest
   file) can keep a stale run green even while fresh runs fail — don't
   trust a lone green run to mean upstream has stabilized; see
   [#1762](https://github.com/Anglesite/Anglesite/issues/1762) (a proposed
   scheduled canary for this exact lane, so upstream drift surfaces on its
   own tracking issue instead of on someone's unrelated PR — check whether
   that canary exists yet before manually re-diagnosing from scratch).
4. If the failure is a `flatpak install`/remote error instead, check whether
   `org.freedesktop.Sdk.Extension.swift6` has published a new branch on
   Flathub — the branch is pinned explicitly (`//25.08`) because an
   ambiguous multi-branch match fails `--noninteractive` installs outright.

## `ios-build` — Xcode project lane: project.yml sync, AnglesiteMobile, AppIntents schema (macos-26)

**What it runs:** installs the pinned XcodeGen, runs
`scripts/check-xcodeproj-sync.sh` (which itself runs `xcodegen generate`
and then the drift assertion — see below), builds `xcodebuild … -scheme
AnglesiteMobile -destination 'generic/platform=iOS Simulator' build`, and
finally the Xcode-27-gated AppIntents schema validation (see below). The
sync check and the AppIntents check were the separate `xcodeproj-sync` and
`appintents-schema` jobs until #1865 — 12-second scripts that each queued
up to 100 minutes for a macOS runner. This is the one lane that needs the
generated `Anglesite.xcodeproj`, so everything project-shaped lives here.
There is no SwiftPM `.build` cache: `xcodebuild` resolves and builds
packages under DerivedData, so the cache this lane once declared never
saved anything.

**Why the AnglesiteMobile build exists:** no other lane ever compiles an iOS app target —
the sync check only verifies source-file membership in the generated
project (explicitly not a full `xcodebuild`), and every other
`xcodebuild`-based lane builds only the macOS `Anglesite`/`AnglesiteIntents`
schemes. This closes that gap: an iOS-incompatible change to
`AnglesiteCore`/`AnglesiteBridge`/`AnglesiteIOS` (the modules this target
links) now fails CI instead of surfacing only on a contributor's local
build. See [#864](https://github.com/Anglesite/Anglesite/issues/864) and
[#886](https://github.com/Anglesite/Anglesite/pull/886).

**What a red usually means:** almost always a genuine iOS-incompatible
change in a module `AnglesiteMobile` links — check the build log for the
first `error:` the way you would for `build-test`. If it fails at
"Install XcodeGen (pinned)" with a checksum mismatch, the pinned
`XCODEGEN_VERSION`/`XCODEGEN_SHA256` pair (kept in sync with
`MIN_XCODEGEN` in `scripts/check-xcodeproj-sync.sh`) needs updating in both
places, not just here.

## DocC build — `build-test`'s documentation steps (macos-26)

*Was the separate `docs-docc` job until #1865; it built the package cold for
~7 minutes to spend ~20 seconds extracting symbol graphs. As two steps in
`build-test` it reuses the warm debug build.*

**What it runs:** `swift package generate-documentation --warnings-as-errors`
against an explicit, deliberate target list (not "every target") via the
SwiftPM library targets directly — no `xcodegen`/`xcodebuild` involved.

**Why an explicit target list, and why two build steps:** a target-less run
sweeps in dependency packages this repo doesn't own (e.g. MarkdownEngine's
own doc comments) and `AnglesiteLANHost` fails symbol-graph extraction with
an unrelated tooling issue. `AnglesiteAppCore` is `compiler(>=6.4)`-gated in
`Package.swift`, so on a pre-Xcode-27 runner it's simply absent from the
manifest — `build-test`'s Xcode-selection step detects that (`has27`
output) and the job runs a *second*, gated documentation step for `AnglesiteAppCore` + `AnglesiteP2P` (the latter
rides along because `swift-symbolgraph-extract` fails to load WebRTC's
binary xcframework module on Xcode 26.6, confirmed clean under Xcode 27) —
green with a `::warning::` until a runner ships Xcode 27, at which point it
auto-activates with no edit needed.

**What a red usually means:** a broken DocC symbol link or malformed
doc-comment markup in a public API you touched — see
[`docs/comment-style-guide.md`](comment-style-guide.md) for the conventions
this lane enforces via `--warnings-as-errors`. If the first (unconditional)
step fails on a target you didn't touch, check whether a dependency version
bump changed that target's exported symbol surface.

## Project sync check — `ios-build`'s first step

*Was the separate `xcodeproj-sync` job (the last one on macos-15, #1795)
until #1865.*

**What it runs:** `scripts/check-xcodeproj-sync.sh` regenerates the Xcode
project via pinned XcodeGen and asserts every app target still compiles the
full tree under its `Sources/` root — needs only `xcodegen` + `python3`, and
the regenerated project is what the AnglesiteMobile build step then builds.

**Why this step exists:** `Anglesite.xcodeproj` is gitignored and
regenerated from `project.yml` — a stale or drifted spec never trips `swift
build` (which doesn't use the `.xcodeproj` at all), it only bites a
contributor running `xcodebuild` locally with "cannot find … in scope"
errors. See [#123](https://github.com/Anglesite/Anglesite/issues/123).

**What a red usually means:** you added/removed/renamed a file under
`Sources/AnglesiteApp` (or a related target) without a matching
`project.yml` change, or hand-edited `Anglesite.xcodeproj` directly (never
do this — edit `project.yml` and regenerate). Run
`scripts/check-xcodeproj-sync.sh` locally to reproduce. If it fails at
"Install XcodeGen (pinned)", see the `ios-build` note above about keeping
`XCODEGEN_VERSION`/`XCODEGEN_SHA256` in sync with `MIN_XCODEGEN`.

## `localization-catalog` — String Catalog checks (ubuntu-latest)

**What it runs:** `scripts/check-localization-catalog.sh` (a static
heuristic scan for `Text`/`Button`/`Label`/`String(localized:)` call sites
with no matching catalog key) and `scripts/check-xcstrings-newline.sh`.

**Why a static heuristic, and not the real Xcode merge:**
`SWIFT_EMIT_LOC_STRINGS`'s String Catalog merge only happens inside the
**interactive Xcode IDE** — a CLI-only `xcodebuild build` (the only option
in CI or any headless/agent workflow) emits `.stringsdata` per file but
never merges it into `Localizable.xcstrings`. This lane is a substitute
that needs no Xcode at all, so it runs on `ubuntu-latest`. See
[#811](https://github.com/Anglesite/Anglesite/issues/811).

**What a red usually means:** you added/changed user-visible text without
running the local `.xcstrings` sync recipe (`CONTRIBUTING.md` ▸ Development
setup, "Commit String Catalog updates") and committing the result, or the
committed catalog's trailing newline got stripped by an interactive Xcode
save outside the pre-commit hook (`scripts/check-xcstrings-newline.sh`
catches this — see [#970](https://github.com/Anglesite/Anglesite/issues/970)
for a past bypass). This heuristic doesn't type-check call sites, so it can
still miss some extraction vectors Xcode itself would catch — a clean run
here is necessary, not sufficient.

## `test-userdefaults-suite-lint` — no direct `UserDefaults(suiteName:)` literals (ubuntu-latest)

**What it runs:** `scripts/check-test-userdefaults-suite-literal.sh`, a
static grep over `Tests/*.swift` — no Xcode/xcodegen needed.

**Why this lane exists:** catches the
[#1727](https://github.com/Anglesite/Anglesite/issues/1727) bypass **at
review time**, before any test even runs. The separate
`check-test-userdefaults-leak.sh` step in `build-test` (after both of its
test steps) and `concurrency-tsan` catches the *leak itself*,
after the fact, from a process that already ran — see
[#1745](https://github.com/Anglesite/Anglesite/issues/1745). The two checks
are deliberately redundant (static lint + runtime leak detection).

**What a red usually means:** a test uses `UserDefaults(suiteName: "...")`
directly instead of `AnglesiteTestSupport`'s `TemporaryUserDefaults` /
`withTemporaryUserDefaults`. Fix at the source — see `CONTRIBUTING.md` ▸
Testing.

## AppIntents schema conformance — `ios-build`'s last step (macos-26)

*Was the separate `appintents-schema` job until #1865 — a 12-second no-op on
macos-26 (its Xcode 27 gate never fires there) that still queued up to 100
minutes for a macOS runner.*

**What it runs:** builds only the `AnglesiteIntents` target via `xcodebuild`
(never `swift build`/`swift test`, since the AppIntents metadata processor
only runs during an actual Xcode *build* phase), which runs
`appintentsmetadataprocessor --validate-assistant-intents`.

**Why this step exists:** an `AppSchema` conformance regression (e.g.
`SiteEntity` dropping a required `.wordProcessor.document` property) passes
every SwiftPM lane and would otherwise surface only on a contributor's
local `xcodebuild`. The `AppSchema.WordProcessor` surface and its validator
are macOS-27 symbols, so this needs the same `has27`-gated,
skips-gracefully-until-Xcode-27 pattern as `build-test`'s `AnglesiteAppCore`
DocC step — green with a `::warning::` on older runners, auto-activating once
Xcode 27 is available.

**What a red usually means:** a genuine required-property regression in an
`AppSchemaEntity` conformance — the validator's own error message
("Missing required property … from AppSchemaEntity …") names the exact gap.
If it fails at "Install XcodeGen (pinned)" or the Xcode-selection step, see
the shared notes above (toolchain selection, XcodeGen pin sync).

## `reuse-lint` — REUSE licensing lint (ubuntu-latest)

**What it runs:** `pipx run --spec reuse[charset-normalizer]==6.2.0 reuse
lint` against the whole tree — **not** gated on the `changes` path filter,
since REUSE compliance is a whole-tree property and the lint costs only
seconds.

**What a red usually means:** a new file lacks licensing coverage under
`REUSE.toml`'s `path = "**"` default annotation, or you vendored
third-party code without adding its license text to `LICENSES/` and its own
`[[annotations]]` block. See `CONTRIBUTING.md` ▸ License for the vendoring
recipe (`reuse download <SPDX-ID>`) and why `REUSE.toml`'s `precedence =
"override"` matters for vendored files specifically. If `REUSE.toml` is
absent entirely, this lane skips gracefully with a `::warning::` — that's
expected only until [#1467](https://github.com/Anglesite/Anglesite/issues/1467)
lands; if you see the skip warning after that PR merged, something removed
`REUSE.toml`.

## The JS/Node lanes (`edit-overlay`, `safari-extension`, `wysiwyg-engine`, `template-worker`, `workers-tests`, `help-book-links`)

These are the straightforward `ubuntu-latest` lanes: `npm ci` +
lint/typecheck/test (plus Playwright e2e for `wysiwyg-engine`, and
`build`/`check:packs`/`build:packs` for `template-worker`). They have no
special CI-only behavior beyond the standard `npm run lint && npm run
typecheck && npm test` cycle described in `CONTRIBUTING.md` ▸ Development
setup — a red run here reproduces locally in the corresponding directory
(`JS/edit-overlay`, `JS/safari-extension`, `JS/wysiwyg-engine`,
`Resources/Template`, `Workers/<project>`). `help-book-links` is a
plain-bash link checker (`scripts/check-help-links.sh`) split out of
`edit-overlay` so a Help Book-only change doesn't pay for a full npm
install/lint/typecheck/test cycle just to reach it.

`linux-build-test` (portable SwiftPM targets, `swift:6.3.3-noble`
container) is the Linux counterpart to `build-test`, but only compiles and
tests the subset of targets that are Darwin-independent so far
(`AnglesiteSiteModel`, `AnglesiteCore` as of this writing — the portable set
expands as more of the cross-platform port lands). A red here is either a
genuine cross-platform-purity regression, or a change that needs the
target's Linux compatibility explicitly extended in `Package.swift`.

## Cache-key troubleshooting (all lanes)

Every SwiftPM-caching lane (`linux-build-test`, `build-test`,
`xcode27-compile`, `concurrency-tsan`)
keys its `.build` cache on a namespace specific to that lane (`swiftpm-linux-…`,
`swiftpm-macos-…`, `swiftpm-xcode27-…`, `swiftpm-tsan-macos-…`) plus the
toolchain version and `Package.resolved` hash — sharing a cache namespace across lanes that
produce genuinely different object files (different Xcode version,
different sanitizer flags, different SDK) would just churn without ever
hitting. If you ever see a cache-restore step pull in stale-looking object
files (e.g. "missing required module 'SwiftShims'" referencing an old
workspace path), the key's version segment (`v1`/`v2`/…) needs bumping —
this has happened once already, after the `Anglesite-app` → `Anglesite`
repository rename baked the old workspace path into cached `.pcm` files;
bump the segment again if it recurs after a similar structural change.

**Caches are written only from `main` (#1865).** Each lane *restores* its
cache on every run (`actions/cache/restore`, prefix `restore-keys`) but only
*saves* it (`actions/cache/save`, keyed on the restore step's
`cache-primary-key` output) when the run is a push to `main`. Before this
split, every PR push saved a fresh ~1 GB sha-suffixed cache per lane and the
repo's 10 GB cache cap evicted everything within a few pushes — and a cache
saved on a `refs/pull/N/merge` ref is invisible to every other PR anyway.
So "Cache not found" on a PR is expected until `main` has completed a run
since the last `Package.resolved` or toolchain change; check
`gh cache list` for entries on `refs/heads/main`. Because a cancelled `main`
run never reaches its save step, `main` runs are no longer cancelled by the
next push (GitHub keeps one running + one pending per concurrency group).

## Related tracking issues

[#646](https://github.com/Anglesite/Anglesite/issues/646),
[#855](https://github.com/Anglesite/Anglesite/issues/855),
[#1344](https://github.com/Anglesite/Anglesite/issues/1344),
[#1762](https://github.com/Anglesite/Anglesite/issues/1762),
[#1865](https://github.com/Anglesite/Anglesite/issues/1865) are the primary
"why is this lane shaped this way" issues referenced above. Reopen the
relevant one (rather than filing fresh) if a new failure matches its
pattern exactly; file a new issue if it's a genuinely new failure mode for
that lane.

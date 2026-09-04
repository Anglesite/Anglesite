# Contributing to Anglesite (Mac app)

Thanks for your interest in contributing! This repo is the native macOS app that consumes the MCP server from the published [Anglesite Claude Skill](https://github.com/Anglesite/anglesite-skills). It's pre-release and moving fast, so a quick read of this page will save you time.

## Before you start

- **Issues are the source of truth.** Check [`gh issue list`](https://github.com/Anglesite/Anglesite/issues) and [`docs/build-plan.md`](docs/build-plan.md) for what's planned and in flight.
- **Claim your issue.** Multiple contributors (and agents) work this repo concurrently. Before starting on a tracked issue, check it isn't already claimed (`gh issue list --label "🛠️ In Progress"`), then add the `🛠️ In Progress` label. Don't remove the label when you open your PR — leave it. A PR body with a closing keyword for the issue (see below) closes the issue on merge, and `gh issue list` shows open issues by default, so a closed issue drops out of the claimed-issue search on its own. Stray labels on issues that are already closed can be cleaned up in a batch later; they don't cause collisions.
- **Discuss big changes first.** For anything beyond a bug fix or small improvement, open an issue before writing code. In particular, new features should not add `claude --print` / markdown-skill paths — that dependency is being retired under epic [#459](https://github.com/Anglesite/Anglesite/issues/459).

For architecture and project direction, read [`AGENTS.md`](AGENTS.md) — it's the canonical development-context document (mirrored as `CLAUDE.md` for Claude Code users). For the module layout, read [`Package.swift`](Package.swift) and `Sources/`.

## Development setup

Prerequisites and full build instructions live in the [README](README.md#requirements). The short version:

```sh
git clone https://github.com/Anglesite/Anglesite.git
cd Anglesite

# One-shot environment check/bootstrap: verifies prerequisites, generates the
# Xcode project, and enables the git hooks that keep it regenerated.
scripts/setup-dev-env.sh

# Build (ad-hoc signed — no Apple account required). Use scripts/build-app.sh
# instead of a raw `xcodebuild` — it regenerates the project first, so a checkout
# that went stale without tripping the git hooks above never builds a stale one (#123).
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```

Key things to know:

- **macOS 27+ and Xcode 27+ (Swift 6.4)** are required for the app itself. The `.xcodeproj` is gitignored and generated from [`project.yml`](project.yml) with [XcodeGen](https://github.com/yonaskolb/XcodeGen) — never edit or commit the project file; edit `project.yml`.
- **Open `Anglesite.xcodeproj`, not `xed .`** — the latter opens `Package.swift`, which has no runnable target.
- **Commit String Catalog updates.** App builds extract SwiftUI and `String(localized:)` literals into `Sources/AnglesiteApp/Localizable.xcstrings` because `SWIFT_EMIT_LOC_STRINGS` is enabled — but that catalog merge only happens in the **Xcode IDE**. A CLI-only `xcodebuild build` (the only option in a headless/agent workflow) still emits `.stringsdata` per file, it just never merges them into the `.xcstrings` catalog. If you add, remove, or rename user-visible text without an interactive Xcode session, run the merge yourself after building:
  ```sh
  scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
  BUILD_DIR=$(xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILD_DIR =/{print $3}')
  xcrun xcstringstool sync Sources/AnglesiteApp/Localizable.xcstrings \
    --stringsdata $(find "$(dirname "$BUILD_DIR")/Intermediates.noindex/Anglesite.build/Debug/Anglesite.build/Objects-normal/arm64" -name "*.stringsdata") \
    --skip-marking-strings-stale
  ```
  Derive the `.stringsdata` path from `-showBuildSettings` rather than globbing `~/Library/Developer/Xcode/DerivedData/Anglesite-*` — this repo's workflow puts every feature/agent task in its own worktree (see `AGENTS.md` ▸ "Worktrees"), so a machine running several agents concurrently accumulates one `Anglesite-*` DerivedData directory per worktree, and the glob pulls `.stringsdata` from all of them. Confirmed the hard way: a sync scoped to the wrong worktree pulled `.stringsdata` from 13 sibling worktrees and produced a 76-line diff with ~25 keys belonging to unrelated in-flight branches. Always pass `--skip-marking-strings-stale`: without it, `sync` deletes any catalog key it can't find in the given `.stringsdata` files, and unless every one of them came from the exact same complete build, that silently nukes real entries — confirmed the hard way while writing this: a from-scratch `-derivedDataPath` build's `.stringsdata` set made `sync` empty the entire 700+-key catalog. This CLI recipe is only known-good against the `DerivedData` your own machine has already accumulated from normal `xcodebuild`/Xcode use — there is no known way yet to make it work reliably from an isolated, from-scratch build (e.g. in CI); review the `.xcstrings` diff yourself and include it in the same commit. Do not blindly restore the catalog when it appears after a build. If the diff contains keys you didn't add or touch — not just missing ones — discard it and re-sync scoped to this worktree's own `BUILD_DIR` as above; a bare `Anglesite-*` glob is the usual cause. If extraction looks incomplete or unexpectedly large, run a clean build first (`xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug clean build`) and review the stabilized result before committing it. CI's `localization-catalog` lane (`scripts/check-localization-catalog.sh`, #811) is a static backstop, not a substitute: it heuristically scans `Sources/AnglesiteApp` for common SwiftUI call sites (`Text`, `Button`, `Label`, …) and `String(localized:)`/`LocalizedStringKey(...)` literals with no matching catalog key, but it doesn't type-check call sites and can't catch every extraction vector Xcode recognizes.
- **Linux contributors welcome.** The portable SwiftPM targets build and test on Linux (Swift 6.3+, no Xcode or Node needed) — see [Developing on Linux](README.md#developing-on-linux). The cross-platform port ([#571](https://github.com/Anglesite/Anglesite/issues/571)) is an active track.
- **Plugin sibling checkout (optional).** Some end-to-end tests expect the Anglesite plugin repo checked out next to this one (`../anglesite`); they skip cleanly when it's absent.

## Testing

Working headless (CI, agents, or just no Xcode GUI)? [`docs/testing-macos-app.md`](docs/testing-macos-app.md) is the how-to for building, launching, and smoke-testing the app from a CLI-only session — including the toolchain preflight, fresh-worktree gotchas, and the optional Xcode MCP (`xcrun mcpbridge`) setup.

CI lane went red? [`docs/ci-troubleshooting.md`](docs/ci-troubleshooting.md) is the runbook — one section per `.github/workflows/ci.yml` job, covering what it runs, what a red usually means, and what to check first.

Run the relevant suites before opening a PR:

```sh
# Swift package tests (AnglesiteSiteModel, AnglesiteCore, AnglesiteBridge, AnglesiteIntents).
# The wrapper is `swift test` behind a machine-scoped lock — use it for local
# full runs so two runs on one Mac don't collide (#1594, see below); args pass through.
scripts/swift-test.sh

# App target builds
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build

# JS edit overlay (from JS/edit-overlay/, Node 22+)
npm run lint && npm run typecheck && npm test
```

Notes:

- Container runtime tests are opt-in: `ANGLESITE_CONTAINER_TESTS=1` (plus `ANGLESITE_CONTAINER_E2E=1` for end-to-end cases). If a preview or those tests need the bundled container boot artifacts vendored or re-vendored, see [`docs/container-image-vendoring.md`](docs/container-image-vendoring.md) for the build → vendor → verify loop and the kernel/initfs lock-bump procedure.
- MCP/apply-edit e2e tests run only when `ANGLESITE_PLUGIN_PATH` points at an Anglesite plugin checkout; otherwise they skip.
- If you touch `Resources/Template/`, run `swift test` too — some Swift tests couple to the template markup.
- Test `UserDefaults` suites must come from `AnglesiteTestSupport`'s `TemporaryUserDefaults` / `withTemporaryUserDefaults`, never a hand-rolled `UserDefaults(suiteName:)` — a plain suite name leaks a plist into `~/Library/Preferences` on every run that nothing can reclaim (#1727). `scripts/check-test-userdefaults-suite-literal.sh` (CI runs it too) statically rejects a direct `UserDefaults(suiteName: "...")` literal anywhere under `Tests/` before a PR can even run the suite (#1745). After `swift test` exits, `scripts/check-test-userdefaults-leak.sh` (CI runs it after every macOS lane that calls `swift test` — build-test, which since #1865 also hosts the timing-sensitive suites as an isolated step, and concurrency-tsan) fails if a suite was left behind in `$TMPDIR` or `~/Library/Preferences`; a Mac still carrying the pre-#1727 backlog needs a one-time `rm ~/Library/Preferences/test-anglesite-*.plist` before it comes back clean.
- **One full `swift test` per Mac at a time.** The FoundationModels suites issue live on-device model turns, and on-device inference is serialized by a system-wide daemon across *all* processes (a FIFO queue — #1594 measured six concurrent callers finishing at exact one-turn intervals), so a second concurrent run multiplies every turn's wall clock past the suites' timeouts. `scripts/swift-test.sh` enforces this with a lock at `/tmp/anglesite-swift-test.lock` (an atomic `mkdir` directory — compatible with taking it by hand the same way) and waits, naming the holder; `--filter` runs that don't touch the live-model suites (`scripts/lib/live-model-tests.sh`) skip the lock. CI is unaffected (its runners have no on-device model and never run concurrent suites). Details in [`docs/testing-macos-app.md`](docs/testing-macos-app.md#automated-tests).
- CI runs the JS overlay checks, Linux portable-target builds, macOS `swift test` (with the timing-sensitive suites in an isolated process, the concurrency suites under ThreadSanitizer in their own lane, and the DocC doc-comment check on the same warm build), and one Xcode-project lane that regenerates `Anglesite.xcodeproj` from `project.yml` and checks it for drift, builds `AnglesiteMobile`, and (once a runner ships Xcode 27) validates the AppIntents schema. All must pass. Every Swift PR fans out to just four macOS jobs on purpose — the org's plan allows five concurrent macOS jobs in total, so a lane that exists only to rebuild the package for a few seconds of checking costs everyone else an hour of runner queue (#1865); add a new Swift check as a step in the lane that already has the build it needs, not as a new macOS job.
- **A `scripts/*.test.sh` / `scripts/*.test.mjs` file needs to be wired into a CI lane explicitly** — dropping one next to the script it covers isn't enough on its own. The existing script tests run in two places in `ci.yml`: self-contained `.sh` tests (stub every external dependency, e.g. `swift`, `gh`, `lsof`) run as extra steps in `linux-build-test` right after the `Test` step; a `.mjs` test that needs Node runs as a step in whichever job already sets up Node for the file it covers (e.g. `template-worker` for `scripts/generate-npm-attributions.test.mjs`, since that job's `template` change filter already triggers on that script). Wire the next one the same way, and confirm it passes in the actual `swift:6.3.3-noble` container locally first if it's going in `linux-build-test` — `podman machine start` + `podman run --rm -v "$PWD/scripts:/work/scripts:ro" -w /work swift:6.3.3-noble bash scripts/your-test.test.sh` catches GNU/BSD userland or missing-tool surprises that a macOS-only run won't.
- **CI never *executes* `AnglesiteAppTests` or `AnglesiteIntentsTests`** — local `swift test` on Xcode 27 is the only run coverage for them (#855). The `macos-26` lanes' Xcode 26.6 (Swift 6.3.3) excludes those `compiler(>=6.4)`-gated targets from the package graph entirely, and the non-required `xcode-27` preview lane can only *compile* them: that image pairs the Xcode 27 SDK with a macOS 26.x **host**, and test bundles built for macOS 27 hard-link 27-only symbols (verified live: FoundationModels' CoreSpotlight cross-import overlay, CloudKit's async overlay, `AppIntents.EntityQuery.allowedExecutionTargets`) that dyld cannot resolve there, so the bundles can never even be loaded. If your change touches `Sources/AnglesiteApp`, `Sources/AnglesiteIntents`, or their tests, run `swift test` locally on Xcode 27 before opening the PR — CI will not catch a runtime regression in those suites. Revisit when a hosted runner image ships with a macOS 27 *host OS* (not just the SDK): flip the `xcode-27` lane's build step back to `swift test` and delete this note.

## Code guidelines

- **Swift/SwiftUI with Apple frameworks only** — plain SwiftUI + actors, no TCA or third-party state libraries. New dependencies need explicit approval in an issue first.
- **Process spawning is centralized** in `AnglesiteCore/ProcessSupervisor` — never call `Process()` from a view.
- **Logs are sacred** — every spawned subprocess streams stdout+stderr to the debug pane. Don't silently discard output.
- **Git is the source of truth for sites** — the app must never become the only way to edit a site. A site's `Source/` repo stays clonable and editable outside the app.
- **The app cannot bypass the template security gate** — `pre-deploy-check.ts` runs before every deploy; surface failures, don't add overrides.
- **JS/TypeScript** (edit overlay) uses ES modules, vanilla APIs, and the existing oxlint/tsc/vitest toolchain.
- **Comment and doc-comment conventions** are in [`docs/comment-style-guide.md`](docs/comment-style-guide.md) — read it before writing `///` doc comments on public API; CI fails on broken DocC symbol links or markup.

## Design docs

Specs, spike notes and decision records live in `docs/specs/` (project-wide) and `docs/superpowers/specs/` (per-feature designs from the brainstorming skill); implementation plans live in `docs/superpowers/plans/`. Filenames are `YYYY-MM-DD-<topic>.md`. Each tree has a **generated** index — [`docs/specs/README.md`](docs/specs/README.md) and [`docs/superpowers/README.md`](docs/superpowers/README.md) — listing date, title, linked issue and status. Read the index first to learn what is current instead of opening files by date (#1816).

- **Every new design doc carries a one-line `Status:` header** in its header block (the lines before the first `##`), with one of four values: `**Status:** draft` (proposed, not yet agreed), `**Status:** current` (agreed — the reference for how things work or should work), `**Status:** superseded by <file or #issue>`, or `**Status:** historical` (executed plan, retired design, or spike notes kept for the record). When a spec replaces another, flip the old one to `superseded by …` in the same PR. Pre-convention files with free-form status text are classified by keyword ("approved" → `current`, "shipped" → `historical`, …); files dated 2026-09-04 or later must use the four values verbatim or CI fails.
- **Regenerate the index whenever you add, rename or re-status a doc:** run `scripts/generate-docs-index.py` and commit the two READMEs with your change. CI's `docs-index` lane runs `scripts/generate-docs-index.py --check` (same pattern as the Help Book link check) and fails if a README is stale or a new file has no recognised `Status:`. It also warns — without failing — when `CLAUDE.md`, this file, the README or a `docs/*.md` page points at a superseded spec, so the pointer can be moved to the replacement.
- **Architecture decision records (ADRs)** are specs whose filename ends `-decision.md` (or `-decisions.md` for a decision set), e.g. [`docs/specs/2026-06-29-c1-indieweb-content-model-decision.md`](docs/specs/2026-06-29-c1-indieweb-content-model-decision.md) and [`docs/superpowers/specs/2026-08-18-audience-limited-posting-decisions.md`](docs/superpowers/specs/2026-08-18-audience-limited-posting-decisions.md). An ADR records a choice and its consequences rather than a design, carries `current` (accepted) or `superseded by …`, and surfaces under "Decision records" at the top of each generated index. Put project-wide decisions in `docs/specs/`, epic-scoped ones in `docs/superpowers/specs/`.

## Commits and pull requests

- **Conventional commits** — `feat(scope): …`, `fix(scope): …`, `ci: …`, etc. Reference the issue number in the subject when there is one (see `git log` for examples). Keep the whole subject line to **72 characters or fewer** (aim for ~50) — `type(scope): summary (#123)` adds up faster than it looks, and an over-length subject gets silently wrapped or split across `git log --oneline`, GitHub's commit/PR views, and `gh`'s own output. If it doesn't fit, shorten the summary and put the extra detail in the commit body, not the subject.
- **Use the [PR template](.github/PULL_REQUEST_TEMPLATE.md) as-is.** Open the file and copy its exact section headings into the PR body — **Summary**, **Paired PR check**, and **Test plan** — even for a trivial change. Don't substitute a generic "Summary / Test plan" body from a different tool's default PR format: that shape silently drops the Paired PR check. Extra sections (Design notes, screenshots, etc.) are welcome appended after the template's own sections — never in place of them.
- **Link the issue with a closing keyword.** Every PR that resolves an issue must say so with a GitHub closing keyword (`Closes #123`, `Fixes #123`) per the template's `Closes #` line, not just a prose mention (e.g. "tracked in #123") — only the keyword form creates the issue link and auto-closes it on merge.
- **Multi-PR tracking issues: watch the commit-scope/closing-keyword collision.** When a tracking issue is deliberately split across several PRs (an interim PR's body says "does not close #N"), don't scope individual commits to that issue number with `fix`/`close`/`resolve` as the commit type — e.g. `fix(#1225): ...`. GitHub's closing-keyword linker scans every commit that lands on the default branch, not just the PR body, and a squash-merge bakes all of a PR's sub-commit messages into the merge commit; a chain of `fix(#1225): ...` review-fix commits auto-closed #1225 with two of its three planned PRs still unshipped (confirmed the hard way, 2026-08-19 — see #1221's reopening of #1225). For an interim commit that fixes a review finding within a not-yet-closing PR, scope it to the PR itself (e.g. `fix(#1400): ...`) or use a non-closing commit type (`feat`/`test`/`docs`) with the tracking issue number instead.
- **Paired PRs.** Changes to the MCP message schema need a paired PR in [`Anglesite/anglesite-skills`](https://github.com/Anglesite/anglesite-skills): the sidecar PR ships first in a tagged release, then the app PR consumes it. Template changes (`Resources/Template/`) are app-only. See `AGENTS.md` ▸ "Two-repo coordination".
- **`@dwk/workers` catalog coordination.** The Worker catalog (`WorkerCatalog.swift` and friends) consumes `catalog.json` published by the separate [`davidwkeith/workers`](https://github.com/davidwkeith/workers) monorepo — a third repo outside the `Anglesite/anglesite-skills` pairing above. Schema extensions there land the same way: keep the app-side decoding **backward-compatible** (new manifest fields optional, feature inert until the catalog publishes them) so the app PR can merge first, and note the pending catalog change in the PR body. Example: the #746 route-claims PR ([#829](https://github.com/Anglesite/Anglesite/pull/829)) shipped an optional `routes` field the catalog can adopt later.
- Keep PRs focused; opportunistic cleanup near the code you're touching is fine, drive-by refactors of unrelated code are not.

## License

By contributing, you agree that your contributions are licensed under the [ISC License](LICENSE) that covers this project.

The repo is [REUSE](https://reuse.software)-compliant, and CI's `reuse-lint` lane enforces it. You almost never need to do anything about this: [`REUSE.toml`](REUSE.toml) declares ISC + the project copyright for the whole tree (`path = "**"`), so a new file is covered the moment you add it — **don't** add per-file `SPDX-License-Identifier` headers to ordinary source files. Two cases do need action:

- **Vendoring third-party code.** Add its license text to `LICENSES/` (`reuse download <SPDX-ID>` fetches the canonical text) and give the vendored paths their own `[[annotations]]` block in `REUSE.toml`. This is required, not optional: the top-level annotation uses `precedence = "override"`, so a vendored file's own SPDX header would otherwise be silently replaced by the ISC default — see the comment in `REUSE.toml` for why that precedence is set the way it is.
- **Checking locally.** `uvx reuse lint` or `pipx run reuse lint` (the tool isn't committed; CI pins `reuse[charset-normalizer]==6.2.0`).

`LICENSES/ISC.txt` is the canonical SPDX text, so it carries the SPDX template's own placeholder copyright lines rather than this project's — that's expected. The human-facing grant with the real copyright holder is the root [`LICENSE`](LICENSE), and the machine-readable holder is the `SPDX-FileCopyrightText` in `REUSE.toml`.

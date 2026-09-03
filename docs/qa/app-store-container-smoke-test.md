# App Store Container Runtime Smoke Test

**Issue:** [#81](https://github.com/Anglesite/Anglesite/issues/81)  
**Scope:** real-signed, write-heavy smoke for the single sandboxed `Anglesite` App Store target.  
**Target runtime:** `LocalContainerSiteRuntime` through Apple Containerization.

## Purpose

Validate the release-signing shape that CI cannot exercise:

- the App Store-sandboxed app carries the `com.apple.security.virtualization` entitlement;
- the app selects `LocalContainerSiteRuntime`, not any retired host Node preview path;
- preview, MCP/edit, image writes, build/preflight, deploy prompting, and teardown all work through the package security-scoped grant;
- sandbox denials and container failures are visible in logs.

This is an interactive author-run smoke. An ad-hoc build boots containers fine (the virtualization entitlement is unrestricted), but is not sufficient here — this smoke validates the *release signing shape* (Team ID, profile embedding, sandbox under a real identity), which only a real-signed build exercises.

## Preconditions

- Apple Silicon Mac on the supported macOS/Xcode versions.
- Apple Development or distribution signing identity for the app team.
- Standard Mac App Store (or Development) provisioning profile for the app id. No
  entitlement grant is involved — `com.apple.security.virtualization` is unrestricted.
- Container artifacts provisioned in the app bundle, or equivalent release artifact path:
  - `Resources/container-image/index.json`
  - `Resources/container-kernel/vmlinux`
  - `Resources/container-initfs/index.json`
- Cloudflare token available if the deploy step should reach a real `wrangler deploy`.

Run the local runtime probes first:

```sh
scripts/run-container-probe.sh echo
scripts/run-container-probe.sh boot
```

(The probe's default ad-hoc signing is sufficient — the entitlement needs no real identity.)

Make the #715 concurrent-vmnet regression gate deterministic instead of relying on ambient
machine state. Create and inspect a second shared-mode network, keep it alive during `boot`,
then remove it:

```sh
(
    set -e
    container system start
    container network create anglesite-715-regression
    trap 'container network delete anglesite-715-regression' EXIT
    container network inspect anglesite-715-regression
    scripts/run-container-probe.sh boot
)
```

The probe runtime log must show an allocated guest subnet that does not overlap the subnet in
the `container network inspect` output. The probe fixture has no lockfile, so reaching `BOOT:
PASS` also proves its in-guest `npm install` retained outbound DNS and HTTPS while the second
vmnet consumer was active. The subshell trap removes the regression network even when the probe
fails.

Both must pass, or the App Store smoke is expected to fail at runtime startup.

## Build Fixture And App

Use the helper script to create the site fixture and a real-signed app:

```sh
DEVELOPMENT_TEAM=<TEAMID> scripts/create-smoke-fixture.sh
```

The script prints the built app path and the interactive steps. Copy the built app to `~/Applications/` before launching; signed sandboxed apps should not be launched from temporary build directories.

## Smoke Matrix

Re-run 2026-07-27, real-signed Debug build of `main` @ `13131027`, Apple Development team `UX3L9R8RSL` (`codesign -dv` confirmed non-ad-hoc), on Xcode 27 / macOS with `container` CLI 1.1.0.

| Case | Result | Evidence |
|---|---|---|
| Real-signed app launches from `~/Applications` | PASS | `codesign -dv` on the copied app: `Authority=Apple Development…`, `TeamIdentifier=UX3L9R8RSL` (not ad-hoc). Launched via `open -n`. |
| App signature has expected Team ID | PASS | Same as above. |
| App signature carries `com.apple.security.virtualization` | PASS | `codesign -d --entitlements :-` shows `com.apple.security.virtualization = true`, plus `app-sandbox`, `files.user-selected.read-write`, `files.bookmarks.app-scope`. |
| Imported fixture package opens with a security-scoped grant | PASS | File ▸ Import Site… → save panel Powerbox grant on `anglesite-smoke.anglesite`; package readable/writable across relaunch and reopen. |
| Runtime selection logs `LocalContainerSiteRuntime` | PASS | Debug pane `runtime` source: repeated `selected LocalContainerSiteRuntime`. |
| No host Node preview fallback starts | PASS | Debug pane search for `LocalSiteRuntime`: zero matches. |
| Preview loads through loopback proxy | PASS | `http://127.0.0.1:<port>` preview loads and live-reloads (Astro HMR) on edit. |
| MCP/edit path applies a text edit through the in-container sidecar | **PASS** (2026-08-10, was FAIL/regression) | Originally: heading edit committed in preview + container (MCP `accepted`/`dial-ok`, Astro HMR reload), but host `Source/index.astro` never changed — reproduced #718 despite merged #737, filed as [#1066](https://github.com/Anglesite/Anglesite/issues/1066). Root cause (missing guest git identity) fixed upstream and now confirmed against a real container guest boot via `scripts/run-container-probe.sh apply-edit` — see "Case 8 root-cause fix landed and confirmed in the real container guest" below. |
| Example photo highlights as an image drop target; dropping a Finder image writes optimized assets under `Source/public/images/` | **FAIL** (2026-08-12, was INCONCLUSIVE) | Resolved by a literal human drag — see "Human image-drop re-run (2026-08-12)" below. The drag payload, drop-target highlight, MCP round-trip, and in-guest apply all work under the signed sandbox, but no optimized asset ever reaches host `Source/public/images/`: replace-on-example-photo fails (`edit-failed`/`no-match`/"no .mdoc files found" — [#1421](https://github.com/Anglesite/Anglesite/issues/1421)), and drop-to-insert applies in the guest but never persists to the host ([#1422](https://github.com/Anglesite/Anglesite/issues/1422)). Not a sandbox/container/signing failure — both are sidecar edit-pipeline defects with follow-up issues filed. |
| Build/preflight/deploy path reaches the expected Cloudflare token or wrangler result | PASS (partial) | Publish Site button correctly opens the "Connect to Cloudflare" one-time API token dialog (link to Cloudflare API tokens page, paste-token field, disabled "Connect and Publish" until filled). Stopped there — entering/creating a Cloudflare API token is credential entry an agent should not perform; a full real `wrangler deploy` round-trip needs a human to paste their own token. |
| Foundation Models chat is present | PASS | Chat toolbar icon opens a working "Ask the assistant…" panel. |
| GitHub `gh` settings/auth UI is absent in App Store build | PASS (clarified) | No `gh`-CLI-based auth UI anywhere. Settings ▸ Advanced ▸ Credentials does have a manual "GitHub personal access token" paste field — that's the deterministic git-push credential (#653), unrelated to and not a reappearance of the retired `gh` CLI/Claude Code auth flow. |
| Window close tears down VM/proxies | PASS | Closing the site window dropped its loopback proxy ports (`lsof` before/after); main app process stayed alive with no orphaned listeners. |
| No relevant sandbox denials appear during the run | PASS | `log stream --predicate 'eventMessage CONTAINS "deny"'` captured for the full run, filtered to our PID: only benign `system-info net.link.addr` and `mach-lookup com.apple.Safari.SafeBrowsing.Service` noise (common to any sandboxed/WebKit-using app) — nothing touching `Source/`, container mounts, MCP, or deploy paths. |

### #715 regression gate + probes

Also re-verified before the app build: `scripts/run-container-probe.sh echo` → `GATE: PASS`. `scripts/run-container-probe.sh boot` run concurrently with a second `container network create` (mirroring another vmnet consumer) → guest allocated `192.168.69.0/24` while the concurrent network held `192.168.68.0/24` (no overlap), and `BOOT: PASS` (the probe's `npm install` retained outbound DNS/HTTPS throughout). #715 stays fixed.

Use `PASS`, `FAIL`, or `N/A`, and record exact failure logs for every non-pass.

## Log Capture

In a separate terminal, capture sandbox denials while running the smoke:

```sh
log stream --predicate 'eventMessage CONTAINS "deny"' --style compact
```

Also save the app debug pane logs for these sources when present:

- `runtime`
- `container:<siteID>`
- `deploy:<siteID>:build`
- `deploy:<siteID>:preflight`
- `deploy:<siteID>:wrangler`

## Acceptance

#81 can close when the matrix passes on a real-signed App Store-target build, or when every failure has a follow-up issue with captured logs and a clear owner.

## Re-run scope (2026-07-16)

The 2026-07-13/14 run (see #81 comments) executed the full matrix above on a
real-signed build and found one blocking failure plus six other bugs, all now
fixed and merged:

| Issue | Problem | Fixed by |
|---|---|---|
| #718 | Edit-overlay writes never reached host `Source/` — lost on next boot | #737 |
| #715 | Guest lost all outbound network when another vmnet consumer ran | #736 |
| #719 | Template `.gitignore` missed `node_modules`, etc. | #733 |
| #720 | Import didn't git-bootstrap plain (non-package) sites | #727 |
| #721 | Post-crash boot retry failed once (stale rootfs) | #729 |
| #722 | `create-smoke-fixture.sh` team-ID derivation + missing git init | #767 |
| #713 | `vendor-container-image.sh` broken since #698 | #730 |

None of this has been re-verified against a fresh build yet, and the
image-drop row was already inconclusive before these fixes landed. #81 stays
open until a re-run confirms the fixes hold and image-drop gets a human check.
This is a **focused re-run**, not a full matrix from scratch:

1. **Case 8 — MCP edit persistence (regression-critical).** Apply a text edit
   through the overlay, confirm the write lands in host `Source/`
   immediately (not just in-container), then close/reopen the window (or
   restart the app) and confirm the edit survived. This is the row #737 must
   fix; it's the reason #81 is still open.
2. **Image drop (still inconclusive).** Needs a literal human hand — drag a
   Finder image onto an `<img>` in the preview, confirm optimized assets land
   under `Source/public/images/`. No scripted/synthetic drag session
   substitutes for this (same tooling limit hit during the #491 run).
3. **Full wrangler round-trip.** #715 fixed the vmnet conflict that gated
   this in the first run — with it fixed, push a real `wrangler deploy`
   (needs a Cloudflare token in Keychain) instead of stopping at "reaches the
   expected token prompt."
4. **Spot-check, not full re-verification, of the other fixed rows:**
   - `create-smoke-fixture.sh` team-ID derivation (#722) — confirm the script
     picks the right identity/team with no manual correction.
   - Import → git-bootstrap (#720) — confirm a plain site import auto-inits
     without the earlier manual `git init` workaround.
   - `.gitignore` (#719) — confirm a freshly scaffolded site doesn't commit
     `node_modules`.
   - Boot retry after crash (#721) — low priority; only worth reproducing if
     a crash happens organically during the run.
   - `vendor-container-image.sh` (#713) — already proven working (it built
     the 07-13 image); just confirm the image still provisions cleanly since
     #730 landed.
5. **Everything that fully passed the first time** (sandbox/entitlement,
   runtime selection, chat presence, `gh` absence, teardown, log
   cleanliness) needs no re-execution — nothing on those paths changed since
   07-14.

### Re-run results (2026-07-27)

Executed on an Apple Silicon Mac with a real Apple Development signing
identity — see the Smoke Matrix above for full per-row evidence. Summary:

1. **Case 8 — MCP edit persistence: still FAILS.** Reproduced #718 despite
   merged #737 — see [#1066](https://github.com/Anglesite/Anglesite/issues/1066)
   for the fresh repro. This remains the reason #81 stays open.
2. **Image drop: still inconclusive**, now for a possibly different reason —
   synthetic drag tooling (`left_click_drag`, manual press/move/release) gets
   the drop-zone highlight to fire but produces no observable write on either
   side (container or host), so it's unclear whether this is the same
   persistence bug or a synthetic-drag limitation. Still needs a human hand.
3. **Wrangler round-trip: reaches the token dialog, stops there by design.**
   Publish Site correctly opens the "Connect to Cloudflare" one-time-token flow.
   Completing a real deploy needs a human to paste their own Cloudflare API
   token — that's not something to automate.
4. **Spot-checks:** `create-smoke-fixture.sh` needed one additional fix not
   in the #722 list — it never stamped `.site-config` (scaffold.sh's job,
   skipped by the rsync-based fixture script), so Import Site rejected the
   fixture as "missing required files". Fixed in this same pass. Import →
   git-bootstrap and `.gitignore` both confirmed working as part of the
   normal fixture flow.
5. **Previously-passing rows:** all re-confirmed (see matrix) — sandbox/
   entitlement, runtime selection, no host fallback, chat presence, `gh`
   absence (clarified: a GitHub PAT field exists for git push, unrelated to
   the retired `gh` CLI flow), teardown, and log cleanliness.

#81 stays open on the strength of case 8 (tracked at
[#1066](https://github.com/Anglesite/Anglesite/issues/1066)) and the
still-unresolved image-drop row.

### Case 8 root-cause fix landed and confirmed in the real container guest (2026-08-10)

[#1066](https://github.com/Anglesite/Anglesite/issues/1066)'s root cause (guest
`commit-tree` calls had no git identity, so `recordEdit` silently returned
`undefined` and the app's persistence hook never fired) is fixed upstream:
`anglesite-skills` [#429](https://github.com/Anglesite/anglesite-skills/pull/429)
adds `server/git-identity.mjs`, passing explicit `GIT_AUTHOR_*`/`GIT_COMMITTER_*`
env into every `commit-tree` call. Released in `anglesite-skills` v1.8.0; the
app's CI pin was bumped to consume it in
[#1070](https://github.com/Anglesite/Anglesite/pull/1070) (merged 2026-07-28).

First verified from a non-GUI session against the sibling checkout at v1.9.0:
`AppliesEditEndToEndTests` passes, and `recordEdit` was exercised directly
against a repo with no git identity configured anywhere — it returns a real
commit SHA. But that check runs the sidecar directly on the host, and a
negative control (calling `commit-tree` with no identity env at all, in the
same identity-less setup) *also* succeeded on macOS — its git falls back to a
guessed identity in a way the original bug report says the Linux container
guest's `node:22-bookworm-slim` base image does not. So it confirmed the fix
was real and correctly wired, but not a true before/after inside the actual
failure environment.

**Since resolved for real:** `scripts/run-container-probe.sh` gained a new
`apply-edit` subcommand (added alongside this note) that boots a real
`LocalContainerSiteRuntime` under `com.apple.security.virtualization`, drives
an actual `apply_edit` through `MCPApplyEditRouter` wired exactly like
production (`PreviewModel.editPersister` — `persistEdit` only runs when the
reply carries a non-nil `commit`), and asserts the host-side `Source/` file
changed. Run twice against a real Apple Containerization VM (not a synthetic
host-level substitute):

```
APPLY-EDIT: PASS (boot: 44.1s, commit: ea79416f9ca2de095b160b005dd445510cca4175, host Source/ updated)
APPLY-EDIT: PASS (boot: 41.9s, commit: cca7fcfb22dfe9e1e74d333504ee0ba7836c85a5, host Source/ updated)
```

Two different real commit SHAs, two independent VM boots — case 8's specific
regression (an `.applied` reply with a nil `commit`, silently skipping
persistence) is confirmed fixed in the real guest. This subcommand is now the
repeatable, no-GUI-required gate for this row: rerun it any time #81's
persistence case needs re-checking (e.g. after a future sidecar bump) instead
of a full manual smoke pass. It does **not** cover the image-drop row, which
still has no non-human substitute (see above).

### Human image-drop re-run (2026-08-12)

The literal-human-hand check finally happened: real-signed Debug build of
`main` @ `b9d66c57` (team `UX3L9R8RSL`, `codesign -dv` confirmed non-ad-hoc,
sidecar v1.9.0-era container image), launched from `~/Applications`, fixture
imported fresh via File ▸ Import Site… (which also re-confirmed the #720
git-bootstrap and #722 fixture-script spot-checks in passing). Two drops:

1. **Replace, onto the example photo** (`photos/hello-photo`): the drop-target
   highlight fired, the image swapped optimistically in the preview, then the
   edit failed and reverted with
   `{"type":"anglesite:edit-failed","id":"e-msqhyvn1-2","reason":"no-match","detail":"no .mdoc files found"}`.
   Root cause: `replace-image-src` has no resolver for images whose `src`
   comes from `.md` frontmatter — the stock template's example photo can't be
   replaced by drag-drop at all. Filed as
   [#1421](https://github.com/Anglesite/Anglesite/issues/1421).
2. **Insert, onto the image-less Welcome page** (the #1408 drop-to-insert
   path): applied cleanly in the guest (preview showed the image, no error),
   but nothing persisted to the host — no commit on the site repo, no `<img>`
   in host `src/pages/index.astro`, no asset under host `public/images/`.
   Same silent nil-commit skip shape as #718/#1066, now for `insert-image`;
   plus, by inspection, the sidecar's persist commit only ever includes the
   patched source file, never the optimized image binaries. Filed as
   [#1422](https://github.com/Anglesite/Anglesite/issues/1422).

What the human run **did** establish for the release-signing questions this
smoke exists to answer: a real Finder drag delivers its file payload into the
sandboxed WKWebView preview fine (the earlier synthetic-drag ambiguity is
resolved — the tooling was the limit, not the app), the MCP round-trip and
in-guest apply work under the signed sandbox, and container→host persistence
itself works in the same session (two `anglesite: duplicate page …` edits
landed as real host commits). Both failures are sidecar edit-pipeline
defects, orthogonal to sandboxing, signing, entitlements, and the container
runtime.

Also closed out in this pass: the **"updates are App Store-managed"** row.
Verified structurally against the same build: no Sparkle/`SUUpdater`/appcast
or update-check code anywhere in `Sources/`, no embedded frameworks in the
built bundle at all, no update-related `Info.plist` keys, and `Anglesite` is
the only Mac app target — the App Store is the only update channel.

**Matrix disposition:** every row now has a PASS or a FAIL with a filed,
root-caused follow-up issue (#1421, #1422) — which is the #81 acceptance
bar ("or when every failure has a follow-up issue with captured logs and a
clear owner"). Image-drop re-verification after the fixes land should get a
no-GUI probe gate (see #1422's suggested `insert-image` probe subcommand)
rather than another full manual pass.

### Image-drop persistence gate added, not yet green (2026-08-12, tracking #1422)

Following up on the re-run above: `scripts/run-container-probe.sh` gained an
`insert-image` subcommand mirroring `apply-edit` above, extended with the
assertion `apply-edit` has no equivalent of — after the commit lands, resolve
the patched `<img>`'s `src` and confirm the host `public/images/…` asset it
points at actually exists on disk, not just that the source file changed.
This is the no-GUI regression gate the image-drop row was missing.

The sidecar-side fix for the second (asset-bytes) defect is
[anglesite-skills#441](https://github.com/Anglesite/anglesite-skills/pull/441)
— not yet tagged/released, so this gate cannot pass yet even once that PR
merges, until the app's vendored container image is bumped to consume it.
The first defect (why the guest reply's `commit` can come back nil for
`insert-image` specifically) is still unconfirmed; guest debug-pane output
was not captured during the human repro, and `recordEdit` failures only log
to the guest console by design (they deliberately don't fail the edit). Once
both land, rerun `scripts/run-container-probe.sh insert-image` and record the
result here the same way the case-8 gate's PASS output is recorded above.

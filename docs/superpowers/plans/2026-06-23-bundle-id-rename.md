# Bundle-ID + Package-UTI Rename Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status (2026-06-23): EXECUTED in PR #302** via subagent-driven development — all 6 tasks implemented, each spec+quality reviewed clean, full `swift test` green, both schemes build. The single still-open box (Task 2 Step 5) is the manual GUI package-open smoke, deferred to the developer; App Store Connect registration of `io.dwk.anglesite` is out of scope (tracked separately). Do not re-execute completed tasks.

> **CORRECTION (2026-08-14):** the account situation is more complicated than this plan assumed.
> `M34HBJZNYA` does carry usable certificates, and it is the team holding the paid Apple Developer
> Program membership that #1208's portal-gated capabilities — CloudKit, App Groups, and the
> provisioning-profile-backed half of Keychain Sharing — depend on. `KH7H8Y25RT` remains a usable
> personal-team Development certificate for local signing, but carries no paid-membership
> capabilities. The original text below is left as written, as the record of what was believed at
> the time.

**Goal:** Move the app identity from the dead `dev.anglesite.*` namespace (old team `M34HBJZNYA`) to `io.dwk.anglesite.*` under the signable `KH7H8Y25RT` team, unblocking #81's real-signed MAS smoke.

**Architecture:** A mechanical rename across `project.yml`, two per-target `Info.plist`s, the Help Book plist, and four Swift identifier constants, verified by existing tests + scheme builds + a grep gate + a Launch-Services package-open smoke. No new runtime code; no migration shims.

**Tech Stack:** XcodeGen (`project.yml` → `Anglesite.xcodeproj`), Swift 6.4 / SwiftUI, `swift test` (Swift Testing + XCTest), macOS Launch Services / UTType.

**Spec:** `docs/superpowers/specs/2026-06-23-bundle-id-rename-design.md`

## Global Constraints

- Exact identity mapping (copy verbatim):
  - MAS app bundle ID: `dev.anglesite.app.mas` → `io.dwk.anglesite`
  - DevID app bundle ID: `dev.anglesite.app` → `io.dwk.anglesite.devid`
  - Package UTI: `dev.anglesite.site` → `io.dwk.anglesite.site`
  - Help Book ID: `dev.anglesite.app.help` → `io.dwk.anglesite.help`
  - NSUserActivity type: `dev.anglesite.app.site-window` → `io.dwk.anglesite.site-window`
  - Keychain service: `dev.anglesite.app` → `io.dwk.anglesite`
  - OSLog subsystem: `dev.anglesite.app` → `io.dwk.anglesite`
- **Preserve** the `UTTypeTagSpecification` `public.filename-extension = anglesite` so existing `.anglesite` packages still open.
- **Do not** rename the DevID target's *bundle id* to the bare `io.dwk.anglesite` — that is the MAS app's. DevID is `…devid`.
- Keychain rename is a **hard rename**, no migration code (pre-release; one manual token re-entry).
- Worktree builds: run `xcodegen generate` first and set `ANGLESITE_PLUGIN_SRC` to the real plugin checkout (`…/github.com/Anglesite/anglesite`) so `copy-plugin.sh` resolves; the default `../anglesite` is wrong from inside a worktree.
- Commit after each task. Branch: `worktree-bundle-id-rename`.

---

### Task 0: Worktree build prerequisites

**Files:** none (environment setup)

- [x] **Step 1: Set the plugin source and generate the project**

```bash
export ANGLESITE_PLUGIN_SRC="$HOME/Developer/github.com/Anglesite/anglesite"
xcodegen generate
```

Expected: `Created project at .../Anglesite.xcodeproj`.

- [x] **Step 2: Confirm a clean baseline build of both schemes**

```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -1
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -1
```

Expected: `** BUILD SUCCEEDED **` for both. If a baseline build fails, stop and report — do not start the rename on a red baseline.

---

### Task 1: Rename the two app bundle IDs in `project.yml`

**Files:**
- Modify: `project.yml` (the `PRODUCT_BUNDLE_IDENTIFIER` for the DevID target ≈ line 76, and the MAS target ≈ line 161)

**Interfaces:**
- Produces: the bundle IDs that App Store Connect / provisioning key on. No Swift consumes these directly.

- [x] **Step 1: Edit the DevID target's bundle id**

In `project.yml`, the `Anglesite` (DevID) target:
```yaml
        PRODUCT_BUNDLE_IDENTIFIER: io.dwk.anglesite.devid
```
(was `dev.anglesite.app`)

- [x] **Step 2: Edit the MAS target's bundle id**

In `project.yml`, the `AnglesiteMAS` target:
```yaml
        PRODUCT_BUNDLE_IDENTIFIER: io.dwk.anglesite
```
(was `dev.anglesite.app.mas`)

- [x] **Step 3: Regenerate and verify the IDs landed**

```bash
xcodegen generate
grep -n "PRODUCT_BUNDLE_IDENTIFIER" Anglesite.xcodeproj/project.pbxproj | grep -i anglesite
```
Expected: shows `io.dwk.anglesite.devid` and `io.dwk.anglesite` (no `dev.anglesite.app*`).

- [x] **Step 4: Build both schemes**

```bash
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -1
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -1
```
Expected: `** BUILD SUCCEEDED **` for both.

- [x] **Step 5: Commit**

```bash
git add project.yml
git commit -m "refactor(bundle-id): rename app bundle IDs to io.dwk.anglesite[.devid]"
```

---

### Task 2: Rename the package UTI (`io.dwk.anglesite.site`)

**Files:**
- Modify: `Sources/AnglesiteCore/UTType+Anglesite.swift:12` (and the doc comments at :5, :7, :11)
- Modify: `Resources/Info.plist` (`LSItemContentTypes` ≈ :74, `UTTypeIdentifier` ≈ :82)
- Modify: `Resources/AnglesiteMAS-Info.plist` (`LSItemContentTypes` ≈ :58, `UTTypeIdentifier` ≈ :66)
- Test: existing `swift test` (no UTI-string test exists; `.anglesiteSite` symbol is unchanged)

**Interfaces:**
- Produces: `UTType.anglesiteSite` now `exportedAs: "io.dwk.anglesite.site"`. All call sites (`SiteActions.swift:102`, `NSOpenPanel`) use the symbol and are unaffected.

- [x] **Step 1: Edit the Swift UTType constant**

`Sources/AnglesiteCore/UTType+Anglesite.swift:12`:
```swift
    static let anglesiteSite = UTType(exportedAs: "io.dwk.anglesite.site")
```
Update the surrounding doc comments (:5, :7, :11) that quote `dev.anglesite.site` to the new string.

- [x] **Step 2: Edit both Info.plists**

In `Resources/Info.plist` AND `Resources/AnglesiteMAS-Info.plist`, replace **both** occurrences of `dev.anglesite.site` (the `LSItemContentTypes` string and the `UTTypeIdentifier` string) with `io.dwk.anglesite.site`. **Leave the `UTTypeTagSpecification` → `public.filename-extension` → `anglesite` entry unchanged.**

- [x] **Step 3: Verify no UTI string remains and the extension tag is intact**

```bash
grep -rn "dev.anglesite.site" Resources/ Sources/
grep -n "anglesite" Resources/Info.plist | grep -i "filename-extension" -A2 || grep -n "<string>anglesite</string>" Resources/Info.plist
```
Expected: first grep returns nothing; the `anglesite` extension string still present in the plist.

- [x] **Step 4: Build + test**

```bash
swift test --package-path . 2>&1 | tail -5
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -1
```
Expected: tests pass; `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual Launch-Services smoke (package still opens)**

```bash
APP=$(xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{d=$3} / FULL_PRODUCT_NAME /{n=$3} END{print d"/"n}')
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
# Then: double-click an existing ~/Sites/*.anglesite package (or `open` it) and confirm it opens in Anglesite,
# and File ▸ Open Site… still filters to the package type.
```
Expected: an existing `.anglesite` package opens; the open panel filters correctly. Record PASS/FAIL.

- [x] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/UTType+Anglesite.swift Resources/Info.plist Resources/AnglesiteMAS-Info.plist
git commit -m "refactor(bundle-id): rename package UTI to io.dwk.anglesite.site"
```

---

### Task 3: Rename the Help Book ID (`io.dwk.anglesite.help`)

**Files:**
- Modify: `Resources/Anglesite.help/Contents/Info.plist:8` (`CFBundleIdentifier`)
- Modify: `Resources/Info.plist:14` (`CFBundleHelpBookName`)
- Modify: `Resources/AnglesiteMAS-Info.plist:14` (`CFBundleHelpBookName`)

**Interfaces:**
- Produces: help book identity. `CFBundleHelpBookName` in both app plists MUST equal the help book's `CFBundleIdentifier`.

- [x] **Step 1: Edit all three strings**

Set each of the three `dev.anglesite.app.help` occurrences to `io.dwk.anglesite.help`.

- [x] **Step 2: Verify consistency**

```bash
grep -rn "anglesite.app.help" Resources/   # expect: nothing
grep -rn "io.dwk.anglesite.help" Resources/Info.plist Resources/AnglesiteMAS-Info.plist Resources/Anglesite.help/Contents/Info.plist
```
Expected: three matches, all identical strings.

- [x] **Step 3: Build**

```bash
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -1
```
Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 4: Commit**

```bash
git add Resources/Info.plist Resources/AnglesiteMAS-Info.plist Resources/Anglesite.help/Contents/Info.plist
git commit -m "refactor(bundle-id): rename Help Book id to io.dwk.anglesite.help"
```

---

### Task 4: Rename the NSUserActivity type (`io.dwk.anglesite.site-window`)

**Files:**
- Modify: `Sources/AnglesiteIntents/SiteEntityAnnotation.swift:19` (`activityType`)
- Modify: `Resources/Info.plist:37` (`NSUserActivityTypes` entry)
- Modify: `Resources/AnglesiteMAS-Info.plist:37` (`NSUserActivityTypes` entry)

**Interfaces:**
- Consumes: nothing new.
- Produces: `SiteEntityAnnotation.activityType == "io.dwk.anglesite.site-window"`, matching the `NSUserActivityTypes` array in both plists (App Intents / Spotlight donation rely on this match).

- [x] **Step 1: Edit the Swift constant**

`Sources/AnglesiteIntents/SiteEntityAnnotation.swift:19`:
```swift
    public static let activityType = "io.dwk.anglesite.site-window"
```

- [x] **Step 2: Edit both plists' `NSUserActivityTypes`**

Replace `dev.anglesite.app.site-window` with `io.dwk.anglesite.site-window` in both `Resources/Info.plist` and `Resources/AnglesiteMAS-Info.plist`.

- [x] **Step 3: Verify match + no stale string**

```bash
grep -rn "site-window" Sources/ Resources/
grep -rn "dev.anglesite.app.site-window" .   # expect: nothing outside historical docs
```
Expected: Swift constant and both plist entries all read `io.dwk.anglesite.site-window`.

- [x] **Step 4: Test (AppIntents schema conformance) + build**

```bash
swift test --package-path . --filter AnglesiteIntents 2>&1 | tail -5
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -1
```
Expected: tests pass; `** BUILD SUCCEEDED **`.

- [x] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/SiteEntityAnnotation.swift Resources/Info.plist Resources/AnglesiteMAS-Info.plist
git commit -m "refactor(bundle-id): rename site-window activity type to io.dwk.anglesite.site-window"
```

---

### Task 5: Rename the Keychain service + its help text (`io.dwk.anglesite`)

**Files:**
- Modify: `Sources/AnglesiteCore/KeychainStore.swift:32` (`defaultService`) and the doc comment at :8
- Modify: `Sources/AnglesiteApp/SettingsView.swift:73` (help text)
- Modify: `Tests/AnglesiteCoreTests/KeychainStoreTests.swift:14` (scratch-service prefix)

**Interfaces:**
- Produces: `KeychainStore.defaultService == "io.dwk.anglesite"`. Hard rename — existing tokens under the old service are abandoned (developer re-enters once).

- [x] **Step 1: Edit the default service constant + comment**

`Sources/AnglesiteCore/KeychainStore.swift:32`:
```swift
    public static let defaultService = "io.dwk.anglesite"
```
Update the doc comment at :8 (`dev.anglesite.app` → `io.dwk.anglesite`).

- [x] **Step 2: Update the Settings help text**

`Sources/AnglesiteApp/SettingsView.swift:73` — change the inline `dev.anglesite.app` in the `Text(...)` to `io.dwk.anglesite`.

- [x] **Step 3: Update the test scratch prefix**

`Tests/AnglesiteCoreTests/KeychainStoreTests.swift:14`:
```swift
        service = "io.dwk.anglesite.tests." + UUID().uuidString
```

- [x] **Step 4: Test**

```bash
swift test --package-path . --filter KeychainStore 2>&1 | tail -5
```
Expected: KeychainStore round-trip tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/KeychainStore.swift Sources/AnglesiteApp/SettingsView.swift Tests/AnglesiteCoreTests/KeychainStoreTests.swift
git commit -m "refactor(bundle-id): rename Keychain service to io.dwk.anglesite (hard rename)"
```

---

### Task 6: Cosmetic — logger subsystems, then the global grep gate + docs

**Files:**
- Modify: `Sources/AnglesiteCore/FoundationModelAssistant.swift:58` (logger subsystem)
- Modify: `Sources/AnglesiteIntents/Bootstrap.swift:5,6,7` (three logger subsystems)
- Modify: docs — `CLAUDE.md` (target table ~:48-49), `README.md` (~:73-74), `docs/build-plan.md` (:15, :164 incl. the decision-reversal note, :78 Keychain service), `docs/xcode-setup.md` (:18-21)

**Interfaces:** none (diagnostics + docs only).

- [x] **Step 1: Update logger subsystems**

In `FoundationModelAssistant.swift:58` and `Bootstrap.swift:5-7`, change `subsystem: "dev.anglesite.app"` → `subsystem: "io.dwk.anglesite"`.

- [x] **Step 2: Update the live docs**

In `CLAUDE.md`, `README.md`, `docs/xcode-setup.md`, and `docs/build-plan.md`, update the bundle-ID table rows and inline mentions to the new IDs. In `docs/build-plan.md:164`, replace the "the earlier `io.dwk.anglesite` candidate is dropped" line with a note that the project moved **to** `io.dwk.anglesite.*` on 2026-06-23 (team → `KH7H8Y25RT`, MAS-only), superseding the 2026-06-09 decision.

- [x] **Step 3: Global grep gate**

```bash
grep -rn "dev\.anglesite\.\(app\|site\)" --include="*.swift" --include="*.plist" --include="*.yml" --include="*.json" Sources/ Resources/ project.yml
```
Expected: **no matches.** (Dated historical spec/plan docs under `docs/specs/` and `docs/superpowers/` that describe the old design at a point in time may retain the old strings; if any are confusing, annotate rather than rewrite. The gate above intentionally excludes `docs/`.)

- [x] **Step 4: Full test + both builds (regression sweep)**

```bash
swift test --package-path . 2>&1 | tail -5
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -1
xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -1
```
Expected: all tests pass; both `** BUILD SUCCEEDED **`.

- [x] **Step 5: Commit**

```bash
git add Sources/ docs/ CLAUDE.md README.md
git commit -m "refactor(bundle-id): update logger subsystems + docs to io.dwk.anglesite.*"
```

---

## Self-Review

**Spec coverage:** Every identity-mapping row in the spec maps to a task — bundle IDs (T1), package UTI (T2), Help Book (T3), NSUserActivity (T4), Keychain + help text + test prefix (T5), loggers + docs + grep gate (T6). The decision-reversal note (spec) → T6 Step 2. Launch-Services verification (spec) → T2 Step 5. The "hard rename, no migration" decision → T5 (no shim). Out-of-scope items (DevID retirement, App Store Connect record, helper docs) are not implemented, matching the spec.

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every edit step shows the exact string or code; every verify step shows the command and expected output.

**Type consistency:** `UTType.anglesiteSite` (T2), `SiteEntityAnnotation.activityType` (T4), `KeychainStore.defaultService` (T5) are referenced by the exact symbol/name their definitions use; the `.anglesiteSite` symbol is explicitly unchanged so call sites stay valid. The DevID-vs-MAS bundle IDs are kept distinct per the Global Constraints (no accidental collision on the bare `io.dwk.anglesite`).

# View Annotations for Siri Onscreen Awareness Implementation Plan

**Status:** historical

> ⚠️ **Archive — executed in PR #167.** This plan is preserved as a trace artifact, not a live work item. The unchecked `- [ ]` boxes are the *original* task list, not current state. Three of the code snippets below were corrected against the Xcode 27 SDK during execution and **do not match what shipped**:
>
> - Task 1 specified `extension SiteEntity: AppEntityAnnotatable {}` — dropped. `AppEntityAnnotatable` is a holder-side protocol (NSUserActivity, NSView conform via the SDK), not an entity-side marker. The functional goal is met by setting `activity.appEntityIdentifier` directly on `NSUserActivity`.
> - Task 1 specified `EntityIdentifier(entity.id, ofType: SiteEntity.self)` — that initializer does not exist. Replaced with `EntityIdentifier(for: entity)`.
> - Task 2 specified `View.appEntityIdentifier(entity.id)` (a `String`) — actual signature is `appEntityIdentifier(_ identifier: EntityIdentifier?)`. Replaced with `EntityIdentifier(for: entity)` here too.
>
> Task 4 also undercounted the new tests: 3 added (`activityRegistersRoutingType`, `activityCarriesEntityIDAndTitle`, `activityIsSessionLocal`), not 2 — total is 273, not 272.
>
> The shipped code is the source of truth; read `Sources/AnglesiteIntents/SiteEntityAnnotation.swift` and `Sources/AnglesiteApp/SiteAnnotationModifier.swift` over the snippets below if you're using this as reference for future work.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adopt the macOS 27 View Annotations API on `SiteWindow` so that "deploy this site" / "back this up" via Siri (or onscreen-aware Apple Intelligence prompts) resolve to the frontmost site without the user having to name it. Closes #103 and the remaining tracked checkbox in #124.

**Architecture:** Two surfaces work together. **Entity-side** — `SiteEntity` conforms to `AppEntityAnnotatable` (marker) so the runtime knows the type can be annotated on views. **View-side** — a SwiftUI modifier `.annotatedAsSite(_:)` lives on the `SiteWindow` root content. It does two things: (a) `.appEntityIdentifier(entity.id)` so view-hit-test based resolution sees the entity, and (b) publishes an `NSUserActivity` carrying `appEntityIdentifier` so the system AI can resolve "this" even when not hit-testing through the view tree (Siri voice path, frontmost-window query). The activity construction is extracted to a testable Foundation-only helper in `AnglesiteIntents`; the SwiftUI wiring stays in `AnglesiteApp`. Everything is gated `#if compiler(>=6.4)` so Xcode 26.3 fallback continues to build.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27), App Intents framework (`AppEntityAnnotatable`, `View.appEntityIdentifier`, `NSUserActivity.appEntityIdentifier`), Swift Testing.

---

## File Structure

New files (all auto-discovered — `AnglesiteIntents` is SPM globbed; `AnglesiteApp` is xcodegen directory-globbed):

- `Sources/AnglesiteIntents/SiteEntityAnnotation.swift` — `AppEntityAnnotatable` conformance + `makeSiteUserActivity(_:)` helper. Foundation only, no SwiftUI.
- `Sources/AnglesiteApp/SiteAnnotationModifier.swift` — SwiftUI `View.annotatedAsSite(_:)` modifier wiring (view annotation + user-activity publication).
- `Tests/AnglesiteIntentsTests/SiteEntityAnnotationTests.swift` — covers the activity-builder payload.

Modified files:

- `Sources/AnglesiteApp/SiteWindow.swift` — apply `.annotatedAsSite(site)` to the `siteUI(for:)` root container.
- `docs/build-plan.md` — flip #103 to ✅ in the Phase 10.2+ list.

**Why the entity conformance lives in `AnglesiteIntents`, not `AnglesiteApp`:** `SpotlightIndexer.swift` already extends `SiteEntity` with `IndexedEntity` in the Intents module — keeping all App Intents protocol conformances colocated keeps the entity's "what it can do in the system" surface area in one place. The SwiftUI modifier must live in `AnglesiteApp` because it imports SwiftUI and references the view tree.

**Why a separate user-activity helper rather than inlining in the modifier:** `NSUserActivity` payload setup is pure Foundation — unit-testable under `swift test`. SwiftUI modifiers are not. Following the same split that #122 and #129 used (testable core in `AnglesiteCore`/`AnglesiteIntents`, thin SwiftUI adapter in `AnglesiteApp`).

---

## Task 1: `AppEntityAnnotatable` conformance + user-activity builder

**Files:**
- Create: `Sources/AnglesiteIntents/SiteEntityAnnotation.swift`
- Test: `Tests/AnglesiteIntentsTests/SiteEntityAnnotationTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteIntentsTests/SiteEntityAnnotationTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteIntents

extension AppIntentsTests {
    /// Covers acceptance: NSUserActivity payload carries the entity identifier so Siri can
    /// resolve "deploy this" against the frontmost SiteWindow even when the voice path
    /// doesn't hit-test through SwiftUI.
    @Suite("SiteEntityAnnotation")
    struct SiteEntityAnnotationTests {
        @Test("activity carries the entity id and a display title")
        func activityCarriesEntityIDAndTitle() throws {
            let site = TestStore.site(id: "s1", name: "Portfolio")
            let activity = SiteEntityAnnotation.makeSiteUserActivity(SiteEntity(site))

            #expect(activity.activityType == SiteEntityAnnotation.activityType)
            #expect(activity.title == "Portfolio")
            #expect(activity.userInfo?["siteID"] as? String == "s1")
        }

        @Test("activity is configured for the current app session, not handoff")
        func activityIsSessionLocal() throws {
            let site = TestStore.site(id: "s1", name: "Portfolio")
            let activity = SiteEntityAnnotation.makeSiteUserActivity(SiteEntity(site))

            // We don't want this activity syncing to other devices — the frontmost-site
            // signal is local to this Mac's UI state. Until #71's iOS thin client + #124's
            // SyncableEntity work lands, eligibility must stay off.
            #expect(activity.isEligibleForHandoff == false)
            #expect(activity.isEligibleForPublicIndexing == false)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SiteEntityAnnotationTests`
Expected: FAIL — `Cannot find 'SiteEntityAnnotation' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteIntents/SiteEntityAnnotation.swift`:

```swift
import AppIntents
import Foundation

/// Marker conformance: tells the App Intents runtime that `SiteEntity` can be annotated on a
/// view, so the system AI can resolve implicit references ("this site") against the frontmost
/// SwiftUI scene. The actual annotation is applied view-side via `View.appEntityIdentifier(_:)`
/// (see `SiteAnnotationModifier` in the app target).
///
/// Gated until #128 retires the Xcode 26.3 fallback, matching every other macOS 27 App Intents
/// adoption in this module (LongRunningIntent, CancellableIntent, IndexedEntity).
#if compiler(>=6.4)
extension SiteEntity: AppEntityAnnotatable {}
#endif

/// Builds the `NSUserActivity` published by a `SiteWindow` while the window is frontmost.
/// Kept Foundation-only so it's unit-testable under `swift test` without dragging SwiftUI in.
///
/// The activity gives the system AI a second channel to resolve "this site" — distinct from
/// `View.appEntityIdentifier`. Siri voice invocations don't always traverse the view tree, but
/// they reliably see the frontmost window's `NSUserActivity`, so publishing the entity id here
/// covers that path. On Xcode 27 we also set the typed `appEntityIdentifier` so the system can
/// resolve without parsing `userInfo`.
public enum SiteEntityAnnotation {
    /// Reverse-DNS style; the suffix matches the SwiftUI scene that publishes it.
    public static let activityType = "dev.anglesite.app.site-window"

    public static func makeSiteUserActivity(_ entity: SiteEntity) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        activity.title = entity.displayName
        activity.userInfo = ["siteID": entity.id]
        // Local UI state, not a portable user document — opt out of every cross-device path.
        // #71 (iOS thin client) will revisit this with SyncableEntity.
        activity.isEligibleForHandoff = false
        activity.isEligibleForPublicIndexing = false
        activity.isEligibleForSearch = false
        #if compiler(>=6.4)
        // Typed entity identifier — the system AI uses this in preference to userInfo parsing
        // when resolving onscreen entities. The string + type form mirrors what
        // CSSearchableIndex.indexAppEntities publishes for SiteEntity in SpotlightIndexer.
        activity.appEntityIdentifier = .init(entity.id, ofType: SiteEntity.self)
        #endif
        return activity
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SiteEntityAnnotationTests`
Expected: PASS — both tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteIntents/SiteEntityAnnotation.swift \
        Tests/AnglesiteIntentsTests/SiteEntityAnnotationTests.swift
git commit -m "$(cat <<'EOF'
feat(intents): SiteEntity is AppEntityAnnotatable + frontmost-site NSUserActivity helper (#103)

Marker conformance + a Foundation-only activity builder. The SwiftUI wiring
lands in the next commit; this commit is testable in isolation under `swift test`.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: SwiftUI modifier wiring view annotation + user activity

**Files:**
- Create: `Sources/AnglesiteApp/SiteAnnotationModifier.swift`

> No unit test for this file. SwiftUI view modifiers don't have a useful test seam at this layer (you can't observe `.appEntityIdentifier` or `.userActivity` from outside a hosting NSView), and the testable surface (the activity payload) is already covered by Task 1. The Xcode-build verification in Task 4 is the gate for this file.

- [ ] **Step 1: Write the implementation**

Create `Sources/AnglesiteApp/SiteAnnotationModifier.swift`:

```swift
import SwiftUI
import AnglesiteCore
import AnglesiteIntents

/// `View.annotatedAsSite(_:)` declares to the system AI that the receiver is currently
/// presenting a particular `SiteEntity`. Two channels are wired:
///
/// 1. **View Annotations** (`View.appEntityIdentifier`) — onscreen-awareness path. When the
///    user invokes an intent with an implicit reference ("deploy this site"), the App Intents
///    runtime walks the SwiftUI hit-test tree, finds the annotated view, and fills the
///    intent's `SiteEntity` parameter with the matching entity from `SiteEntityQuery`.
///
/// 2. **NSUserActivity** — voice-invocation path. Siri doesn't always traverse the view tree,
///    but it reliably reads the frontmost window's user activity. Publishing the entity id
///    there covers "deploy this" said into the global Siri box while a SiteWindow is up front.
///
/// Both are gated on `#if compiler(>=6.4)` because the macOS 27 APIs they call (the modifier
/// itself and `NSUserActivity.appEntityIdentifier`) don't exist on Xcode 26.3. On the fallback
/// toolchain the modifier becomes a no-op — voice "deploy this" falls back to the
/// EntityStringQuery prompt, which is the pre-#103 behavior.
extension View {
    @ViewBuilder
    func annotatedAsSite(_ site: SiteStore.Site) -> some View {
        let entity = SiteEntity(site)
        #if compiler(>=6.4)
        self
            .appEntityIdentifier(entity.id)
            .userActivity(SiteEntityAnnotation.activityType, isActive: true) { activity in
                // The closure is invoked each time SwiftUI activates the activity, so we
                // rebuild the payload from scratch — site renames propagate without us
                // having to invalidate anything.
                let fresh = SiteEntityAnnotation.makeSiteUserActivity(entity)
                activity.title = fresh.title
                activity.userInfo = fresh.userInfo
                activity.isEligibleForHandoff = fresh.isEligibleForHandoff
                activity.isEligibleForPublicIndexing = fresh.isEligibleForPublicIndexing
                activity.isEligibleForSearch = fresh.isEligibleForSearch
                activity.appEntityIdentifier = fresh.appEntityIdentifier
            }
        #else
        self
        #endif
    }
}
```

- [ ] **Step 2: Verify the file compiles in isolation**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build -quiet 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

> If the build fails with "Cannot find 'appEntityIdentifier' in scope" or "no member 'appEntityIdentifier'" inside the `#if compiler(>=6.4)` block, the local Xcode is still 26.3. Confirm with `xcodebuild -version` (should be 27.x per CLAUDE.md). Do not delete the guards — they're load-bearing for CI until #128 lands.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/SiteAnnotationModifier.swift
git commit -m "$(cat <<'EOF'
feat(app): View.annotatedAsSite modifier — view annotation + user activity (#103)

Thin SwiftUI wrapper over the SiteEntityAnnotation helper from the previous
commit. Doesn't change behavior until SiteWindow applies it (next commit).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Apply the modifier on `SiteWindow`'s root content

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

- [ ] **Step 1: Locate the existing `siteUI(for:)` return block**

The current shape (lines ~64–131) is:

```swift
@ViewBuilder
private func siteUI(for site: SiteStore.Site) -> some View {
    ZStack(alignment: .bottom) {
        // ...
    }
    .animation(.easeInOut(duration: 0.18), value: deploy.drawerPresented)
    .animation(.easeInOut(duration: 0.18), value: backup.drawerPresented)
    .navigationTitle(site.name)
    .sheet(isPresented: $deploy.blockedPresented) { ... }
    .sheet(isPresented: $deploy.tokenPromptPresented) { ... }
    .sheet(isPresented: $audit.sheetPresented) { ... }
}
```

The annotation belongs at the **outermost** modifier position so it covers the whole window's content, including the deploy/backup drawers and the chat side-panel. Voice "deploy this" should resolve regardless of whether the drawer is up.

- [ ] **Step 2: Apply the modifier**

Edit `Sources/AnglesiteApp/SiteWindow.swift`. Find the `.sheet(isPresented: $audit.sheetPresented)` line (the last existing modifier on `siteUI(for:)`) and append `.annotatedAsSite(site)` after it:

```swift
.sheet(isPresented: $audit.sheetPresented) {
    AuditSheetView(
        model: audit,
        siteName: site.name,
        onRunAgain: { audit.audit(siteID: site.id, siteDirectory: site.path) }
    )
}
.annotatedAsSite(site)   // #103 — view annotation + NSUserActivity for "deploy this"
```

- [ ] **Step 3: Verify the change with `git diff`**

Run: `git diff -- Sources/AnglesiteApp/SiteWindow.swift`
Expected: Exactly one added line (the `.annotatedAsSite(site)` call), and one added comment line. No other deltas.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift
git commit -m "$(cat <<'EOF'
feat(app): annotate SiteWindow with its SiteEntity for Siri onscreen awareness (#103)

Apply the annotatedAsSite modifier at the SiteWindow root so View Annotations
and the published NSUserActivity both carry the entity id for the frontmost
site. "Deploy this site" / "back this up" via Siri now resolve without the
user naming the site.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Build verification on both schemes

**Files:** none (validation only)

Per `feedback_verify_app_changes_with_xcodebuild.md`: `swift test` alone doesn't prove the `.app` links. Both targets must build clean before we mark #103 done.

- [ ] **Step 1: Build the DevID scheme**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Build the MAS scheme**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme AnglesiteMAS -configuration Debug build 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`.

> The annotation modifier is target-agnostic — `AnglesiteIntents` already builds in MAS (it's how #129's Spotlight indexer ships there). If MAS fails with a symbol that DevID accepted, it's a `#if !ANGLESITE_MAS` collision; recheck Task 2 and 3 for accidental chat or direct-download-adjacent imports.

- [ ] **Step 3: Run the full SwiftPM test suite**

Run: `swift test --package-path .`
Expected: 272 tests pass (270 previous + the 2 added in Task 1).

- [ ] **Step 4: Run the App Intents suite in isolation as a smoke**

Run: `swift test --package-path . --filter AppIntentsTests`
Expected: All App Intents suites pass, including `SiteEntityAnnotation` with 2 tests.

---

## Task 5: Manual Siri verification (smoke)

**Files:** none — interactive verification.

The automated tests cover the activity payload. The view-side wiring and Siri's resolver are integration territory that no test seam exists for; a manual smoke confirms acceptance criterion 1.

> If you don't have a Siri-enabled test Mac available (CI runners typically don't), record this step as **deferred** in the PR description and link the manual checklist below for the next person to run before close. Don't block the merge — Phase B already ships voice via the `AppShortcutsProvider` exact phrases; #103 is an enhancement layer on top.

- [ ] **Step 1: Launch the app and open a site window**

Run from Xcode: ⌘R on the `Anglesite` scheme. Pick or add a site so a `SiteWindow` is frontmost.

- [ ] **Step 2: Invoke Siri with an implicit reference**

Open Siri (microphone in menu bar / global shortcut). Say: **"Hey Siri, back up this site."**

Expected:
- Siri resolves "this site" to the frontmost window's site name.
- The Backup confirmation dialog shows the correct site.

> If Siri prompts "Which site?" instead, the annotation didn't take. Check (a) `xcrun appintentsmetadataprocessor` output in the build log — `assistantEntities` should now list `SiteEntity`; (b) the AnglesiteMAS guard isn't compiling the modifier file out (it shouldn't — `SiteAnnotationModifier.swift` has no `#if ANGLESITE_MAS`).

- [ ] **Step 3: Repeat for deploy**

Say: **"Hey Siri, deploy this site."**

Expected: the Deploy confirmation dialog (the `requestConfirmation` in `DeploySiteIntent.perform`) shows the correct site name.

- [ ] **Step 4: Document the result in the PR description**

Either "Manual Siri smoke green on macOS 27.x build XYZ" or "Deferred — needs a Siri-enabled Mac to verify."

---

## Task 6: Mark #103 done in `docs/build-plan.md`

**Files:**
- Modify: `docs/build-plan.md`

- [ ] **Step 1: Update the Phase 10.2+ checkbox**

In `docs/build-plan.md`, find the line:

```markdown
- 🔲 **View Annotations for Siri** (#103) — onscreen awareness on the preview pane.
```

Replace with:

```markdown
- ✅ **View Annotations for Siri** (#103) — `SiteEntity: AppEntityAnnotatable` + `View.annotatedAsSite(_:)` modifier applied at the `SiteWindow` root. Two channels: `View.appEntityIdentifier` for hit-test resolution, `NSUserActivity.appEntityIdentifier` for the Siri voice path. Activity payload is Foundation-only and unit-tested in `SiteEntityAnnotationTests`. Closes the last tracked checkbox in #124.
```

- [ ] **Step 2: Commit**

```bash
git add docs/build-plan.md
git commit -m "$(cat <<'EOF'
docs: mark #103 (View Annotations) done in build-plan.md

Closes the last tracked checkbox in #124 — Phase B is now complete.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Push and open the PR

- [ ] **Step 1: Push the branch**

Run: `git push -u origin HEAD`

- [ ] **Step 2: Open the PR (stacked into `main` per `feedback_stacked_prs_into_main.md`)**

Run:

```bash
gh pr create --base main --title "feat(intents): View Annotations for Siri onscreen awareness (#103)" --body "$(cat <<'EOF'
## Summary

- `SiteEntity: AppEntityAnnotatable` + a Foundation-only `SiteEntityAnnotation.makeSiteUserActivity(_:)` helper (unit-tested).
- `View.annotatedAsSite(_:)` SwiftUI modifier wires both `View.appEntityIdentifier` and an `NSUserActivity` carrying the entity id.
- Applied at the `SiteWindow` root so "deploy this site" / "back this up" via Siri resolve to the frontmost site without naming it.
- Closes #103. Closes the last tracked checkbox in #124 — Phase B is now complete.

## Test plan

- [x] `swift test --package-path .` — 272 tests green (270 previous + 2 added in `SiteEntityAnnotationTests`).
- [x] `xcodebuild -scheme Anglesite -configuration Debug build` — green.
- [x] `xcodebuild -scheme AnglesiteMAS -configuration Debug build` — green.
- [ ] Manual Siri smoke: "Hey Siri, back up this site" with a `SiteWindow` frontmost resolves to the correct site. *(Deferred / Green — fill in.)*

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Mark #103 in-progress on GitHub**

Per `feedback_mark_gh_issues_in_progress.md`: drop a one-liner comment on #103 referencing the PR so the parallel-agent claim signal is in place.

Run: `gh issue comment 103 --body "Implementing in <PR_URL_FROM_STEP_2>."`

---

## Out of scope (deferred follow-ups)

Captured here so they're not lost, not added as tasks:

- **Finer-grained annotation on annotation-feed rows / deploy drawer.** Issue #103 mentions this as a "consider if the API supports it cheaply." It doesn't — row-level annotation would require lifting each row's site context into a SiteEntity, and the feed rows are about *annotations within* a site, not the site itself. Window-level coverage already satisfies the acceptance criterion. Revisit if a real "deploy this annotation"-style intent emerges.
- **`RelevantEntities` for "most-recent site" suggestions.** Tracked separately on #124.
- **`SyncableEntity` for cross-device stable IDs.** Tracked separately on #124, gated on #71.
- **Schema-based natural-language adoption** (`@AppIntent(schema:)`). #124's key finding is that no publishing/dev-tooling schema exists in WWDC26. Re-evaluate per WWDC.

---

## Self-review checklist (for the author, run after writing)

- [x] **Spec coverage** — #103's three acceptance criteria mapped: voice "deploy this" / "back up this" → Task 3 + Task 5; no preview/edit-overlay regressions → Task 4 build green + existing test suite green; both targets → Task 4 explicit MAS build. #124's "View Annotations on the preview pane" checkbox → Task 3 + Task 6.
- [x] **No placeholders** — every step has the actual code, command, or expected output. No "add appropriate error handling" / "TBD" / "similar to Task N".
- [x] **Type consistency** — `SiteEntityAnnotation` (enum namespace), `activityType` (String constant), `makeSiteUserActivity(_:)` (function name), `annotatedAsSite(_:)` (modifier name) are stable across Tasks 1–3.
- [x] **Toolchain guards** — every macOS-27-only API call (`AppEntityAnnotatable`, `View.appEntityIdentifier`, `NSUserActivity.appEntityIdentifier`) is inside `#if compiler(>=6.4)`, matching the pattern established by `SiteIntents.swift`. The fallback degrades to existing pre-#103 behavior (EntityStringQuery prompt), not a build break.

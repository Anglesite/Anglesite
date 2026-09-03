# Booking `button` Placement Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the already-built `button` variant of `BookingWidget.astro` as a third booking placement choice that injects an in-flow CTA button into the home page hero.

**Architecture:** The booking integration is declarative — `IntegrationCatalog.booking` (a data descriptor) lists placement choices and `Operation`s; `IntegrationPlanner` turns a descriptor + owner answers into a step list; `MarkerInjector` applies `injectAtAnchor` snippets at named anchors. This plan (1) adds a `Condition.fieldIn` enum case so the `buttonText` field can show for two styles, (2) adds homepage injection anchors, and (3) adds the `button` choice + two `injectAtAnchor` ops to the booking descriptor. `BookingWidget.astro` already renders `button` for both providers — no component change.

**Tech Stack:** Swift 6.4 (Swift Testing `@Test`), Astro template files.

## Global Constraints

- Worktree: `.claude/worktrees/booking-button-289/` on branch `worktree-booking-button-289`. Run all commands from there.
- Run `swift test` from the worktree: `swift test --package-path .`
- Editing template files (`index.astro`) trips `IntegrationTemplateAssetsTests` completeness guards — run `swift test --filter Integration` before pushing.
- In test files use the classic URL APIs (`URL(fileURLWithPath:)` / `appendingPathComponent` / `.path`), NOT `URL(filePath:)` / `appending(path:)` — the macOS-26 CI runner can't load the swift-foundation overlay (see `IntegrationTemplateAssetsTests` header note).
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- No new third-party dependencies (v0 rule).

---

### Task 1: `Condition.fieldIn` case

Add a multi-value visibility condition so a field can be shown for more than one choice value. Needed so `buttonText` shows for both `floating` and `button`.

**Files:**
- Modify: `Sources/AnglesiteCore/IntegrationDescriptor.swift` (the `Condition` enum, ~line 25-29)
- Modify: `Sources/AnglesiteCore/IntegrationPlanner.swift` (`isVisible`, ~line 101-107)
- Modify: `Sources/AnglesiteCore/IntegrationCatalog.swift` (`validate`'s `check`, ~line 10-19)
- Test: `Tests/AnglesiteCoreTests/IntegrationPlannerTests.swift` (new `@Test`)
- Test: `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift` (new `@Test`)

**Interfaces:**
- Produces: `Condition.fieldIn(key: String, values: [String])` — true when `answers[key]` is one of `values`. Consumed by Task 3's `buttonText` field.

- [x] **Step 1: Write the failing visibility test**

In `Tests/AnglesiteCoreTests/IntegrationPlannerTests.swift`, add inside the `IntegrationPlannerTests` suite:

```swift
    @Test func fieldInVisibilityMatchesAnyListedValue() {
        let cond = Condition.fieldIn(key: "style", values: ["floating", "button"])
        #expect(IntegrationPlanner.isVisible(cond, answers: ["style": "floating"], providerID: nil))
        #expect(IntegrationPlanner.isVisible(cond, answers: ["style": "button"], providerID: nil))
        #expect(!IntegrationPlanner.isVisible(cond, answers: ["style": "inline"], providerID: nil))
        #expect(!IntegrationPlanner.isVisible(cond, answers: [:], providerID: nil))
    }
```

- [x] **Step 2: Write the failing validation test**

In `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift`, add inside the suite (mirrors `validateCatchesDanglingFieldReference`):

```swift
    @Test func validateCatchesDanglingFieldInReference() {
        let bad = IntegrationDescriptor(
            id: .booking, displayName: "B", summary: "s",
            providers: [Provider(id: "cal", displayName: "Cal", cspDomains: ["app.cal.com"])],
            fields: [Field(key: "f", label: "F", kind: .text,
                           visibleWhen: .fieldIn(key: "nope", values: ["x"]))],
            operations: [])
        #expect(bad.validate().contains { $0.contains("nope") })
    }
```

- [x] **Step 3: Run both tests to verify they fail**

Run: `swift test --package-path . --filter "fieldInVisibilityMatchesAnyListedValue|validateCatchesDanglingFieldInReference"`
Expected: FAIL — compile error `type 'Condition' has no member 'fieldIn'`.

- [x] **Step 4: Add the enum case**

In `Sources/AnglesiteCore/IntegrationDescriptor.swift`, the `Condition` enum currently reads:

```swift
public enum Condition: Sendable, Equatable {
    case always
    case providerIs(String)
    case fieldEquals(key: String, value: String)
}
```

Add the new case:

```swift
public enum Condition: Sendable, Equatable {
    case always
    case providerIs(String)
    case fieldEquals(key: String, value: String)
    case fieldIn(key: String, values: [String])
}
```

- [x] **Step 5: Evaluate the case in `isVisible`**

In `Sources/AnglesiteCore/IntegrationPlanner.swift`, `isVisible` currently reads:

```swift
    static func isVisible(_ condition: Condition, answers: Answers, providerID: String?) -> Bool {
        switch condition {
        case .always: return true
        case .providerIs(let p): return providerID == p
        case .fieldEquals(let key, let value): return answers[key] == value
        }
    }
```

Add the new branch:

```swift
    static func isVisible(_ condition: Condition, answers: Answers, providerID: String?) -> Bool {
        switch condition {
        case .always: return true
        case .providerIs(let p): return providerID == p
        case .fieldEquals(let key, let value): return answers[key] == value
        case .fieldIn(let key, let values): return values.contains(answers[key] ?? "")
        }
    }
```

- [x] **Step 6: Validate the case in `validate`'s `check`**

In `Sources/AnglesiteCore/IntegrationCatalog.swift`, the `check` closure currently reads:

```swift
        func check(_ condition: Condition, _ context: String) {
            switch condition {
            case .always: break
            case .providerIs(let p) where !providerIDs.contains(p):
                problems.append("\(context): condition references unknown provider \"\(p)\"")
            case .fieldEquals(let key, _) where !fieldKeys.contains(key):
                problems.append("\(context): condition references unknown field \"\(key)\"")
            default: break
            }
        }
```

Add a `fieldIn` branch before `default`:

```swift
        func check(_ condition: Condition, _ context: String) {
            switch condition {
            case .always: break
            case .providerIs(let p) where !providerIDs.contains(p):
                problems.append("\(context): condition references unknown provider \"\(p)\"")
            case .fieldEquals(let key, _) where !fieldKeys.contains(key):
                problems.append("\(context): condition references unknown field \"\(key)\"")
            case .fieldIn(let key, _) where !fieldKeys.contains(key):
                problems.append("\(context): condition references unknown field \"\(key)\"")
            default: break
            }
        }
```

- [x] **Step 7: Run both tests to verify they pass**

Run: `swift test --package-path . --filter "fieldInVisibilityMatchesAnyListedValue|validateCatchesDanglingFieldInReference"`
Expected: PASS (2 tests).

- [x] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/IntegrationDescriptor.swift Sources/AnglesiteCore/IntegrationPlanner.swift Sources/AnglesiteCore/IntegrationCatalog.swift Tests/AnglesiteCoreTests/IntegrationPlannerTests.swift Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift
git commit -m "feat(#289): add Condition.fieldIn for multi-value field visibility

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Home page injection anchors

Add the two inert anchors the `button` placement injects into. They are no-op comments in the shipped template.

**Files:**
- Modify: `Resources/Template/src/pages/index.astro`
- Test: `Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift` (new `@Test`)

**Interfaces:**
- Produces: anchors `// anglesite:imports` (frontmatter) and `<!-- anglesite:hero-cta -->` (inside `.hero`). Consumed by Task 3's injection ops.

- [x] **Step 1: Write the failing anchor test**

In `Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift`, add inside the suite (mirrors `layoutsHaveImportAndBodyAnchors`):

```swift
    @Test func homepageHasImportAndHeroAnchors() throws {
        let root = templateRoot()
        let index = try String(contentsOf: root.appendingPathComponent("src/pages/index.astro"), encoding: .utf8)
        #expect(index.contains("// anglesite:imports"))
        #expect(index.contains("<!-- anglesite:hero-cta -->"))
    }
```

- [x] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --filter homepageHasImportAndHeroAnchors`
Expected: FAIL — `#expect(index.contains("// anglesite:imports"))` is false.

- [x] **Step 3: Add the anchors to `index.astro`**

Replace the full contents of `Resources/Template/src/pages/index.astro` with:

```astro
---
import BaseLayout from "../layouts/BaseLayout.astro";
// anglesite:imports — integration component imports are injected here on setup
---

<BaseLayout
  title="Welcome — Your New Anglesite Business Website"
  description="Your business website is ready to set up. Run /start in Claude to begin the guided setup."
>
  <main>
    <section class="hero">
      <h1>Welcome</h1>
      <p>This site is ready to set up. Type <code>/start</code> in Claude Desktop to get started.</p>
      <p><a href="/blog/">Read the blog</a></p>
      <!-- anglesite:hero-cta -->
    </section>
  </main>
</BaseLayout>
```

- [x] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path . --filter homepageHasImportAndHeroAnchors`
Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add Resources/Template/src/pages/index.astro Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift
git commit -m "feat(#289): add homepage injection anchors for booking button

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Booking descriptor `button` placement

Add the `button` choice, make `buttonText` visible for `button` too, and add the two homepage injection operations. Update the choice-set assertion.

**Files:**
- Modify: `Sources/AnglesiteCore/IntegrationCatalog.swift` (the `booking` descriptor, ~line 53-93)
- Test: `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift` (`bookingHasStyleChoiceDrivingPlacement`, ~line 15-20)
- Test: `Tests/AnglesiteCoreTests/IntegrationPlannerTests.swift` (new `@Test`)

**Interfaces:**
- Consumes: `Condition.fieldIn` (Task 1); homepage anchors `// anglesite:imports` and `<!-- anglesite:hero-cta -->` (Task 2).
- Produces: a `style == "button"` plan that emits two `.injectAnchor` steps targeting `src/pages/index.astro` (one `.line` import, one `.html` render) and no `book.astro` `createFile`.

- [x] **Step 1: Update the choice-set assertion (failing test)**

In `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift`, `bookingHasStyleChoiceDrivingPlacement` currently asserts:

```swift
        #expect(Set(choices.map { $0.value }) == Set(["inline", "floating"]))
```

Change it to:

```swift
        #expect(Set(choices.map { $0.value }) == Set(["inline", "floating", "button"]))
```

- [x] **Step 2: Write the failing planner test**

In `Tests/AnglesiteCoreTests/IntegrationPlannerTests.swift`, add inside the suite (mirrors `bookingFloatingInjectsIntoLayout`):

```swift
    @Test func bookingButtonInjectsIntoHomepageHero() {
        let r = try! IntegrationPlanner.plan(descriptor: IntegrationCatalog.descriptor(for: .booking),
            answers: ["provider": "cal", "username": "jane", "style": "button"],
            sourceDirectory: makeSource(), templateDirectory: makeTemplate()).get()
        let injects = r.steps.compactMap { step -> (String, MarkerInjector.CommentStyle)? in
            if case .injectAnchor(let f, _, _, _, let style) = step { return (f, style) }; return nil
        }
        #expect(injects.contains { $0.0.contains("index.astro") && $0.1 == .line })
        #expect(injects.contains { $0.0.contains("index.astro") && $0.1 == .html })
        #expect(!r.steps.contains { if case .createFile(let p, _) = $0 { return p == "src/pages/book.astro" }; return false })
    }
```

- [x] **Step 3: Run both tests to verify they fail**

Run: `swift test --package-path . --filter "bookingHasStyleChoiceDrivingPlacement|bookingButtonInjectsIntoHomepageHero"`
Expected: FAIL — choice set is `{inline, floating}`; no `index.astro` injection steps.

- [x] **Step 4: Add the `button` choice and fix `buttonText` visibility**

In `Sources/AnglesiteCore/IntegrationCatalog.swift`, the booking `fields` `style`/`buttonText` entries currently read:

```swift
            Field(key: "style", label: "Placement", kind: .choice([
                Choice(value: "inline", label: "On a /book page"),
                Choice(value: "floating", label: "Floating button (site-wide)"),
            ]), defaultValue: "inline"),
            Field(key: "buttonText", label: "Button text", kind: .text, isOptional: true,
                  defaultValue: "Book a time", visibleWhen: .fieldEquals(key: "style", value: "floating")),
```

Replace with:

```swift
            Field(key: "style", label: "Placement", kind: .choice([
                Choice(value: "inline", label: "On a /book page"),
                Choice(value: "floating", label: "Floating button (site-wide)"),
                Choice(value: "button", label: "Button on the home page"),
            ]), defaultValue: "inline"),
            Field(key: "buttonText", label: "Button text", kind: .text, isOptional: true,
                  defaultValue: "Book a time",
                  visibleWhen: .fieldIn(key: "style", values: ["floating", "button"])),
```

- [x] **Step 5: Add the two `button` injection operations**

In the same booking descriptor, the `operations` array currently has the two `floating`-gated `injectAtAnchor` ops (targeting `src/layouts/BaseLayout.astro`) followed by `.writeConfig`. Insert the two `button`-gated ops immediately **after** the second floating `injectAtAnchor` (the `.html` one ending `style: .html)` for `BaseLayout.astro`) and **before** `.writeConfig`:

```swift
            .injectAtAnchor(file: "src/pages/index.astro", anchor: "// anglesite:imports",
                            snippet: "import BookingWidget from \"../components/BookingWidget.astro\";\nimport { readConfig } from \"../../scripts/config\";",
                            when: .fieldEquals(key: "style", value: "button"), style: .line),
            .injectAtAnchor(file: "src/pages/index.astro", anchor: "<!-- anglesite:hero-cta -->",
                            snippet: "{readConfig(\"BOOKING_STYLE\") === \"button\" && (<BookingWidget provider={readConfig(\"BOOKING_PROVIDER\")} username={readConfig(\"BOOKING_USERNAME\")} eventSlug={readConfig(\"BOOKING_EVENT_SLUG\")} buttonText={readConfig(\"BOOKING_BUTTON_TEXT\")} style=\"button\" />)}",
                            when: .fieldEquals(key: "style", value: "button"), style: .html),
```

- [x] **Step 6: Run both tests to verify they pass**

Run: `swift test --package-path . --filter "bookingHasStyleChoiceDrivingPlacement|bookingButtonInjectsIntoHomepageHero"`
Expected: PASS (2 tests).

- [x] **Step 7: Run the full integration suite (regression + asset guards)**

Run: `swift test --package-path . --filter Integration`
Expected: PASS — all integration suites green, including `IntegrationCatalogTests.descriptorsValidate` (every descriptor's `validate()` returns `[]`), `bookingWritesEventSlugAndButtonText`, and `IntegrationTemplateAssetsTests`. If any asset-completeness fixture fails, update the expected fixture list to match.

- [x] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/IntegrationCatalog.swift Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift Tests/AnglesiteCoreTests/IntegrationPlannerTests.swift
git commit -m "feat(#289): booking 'button' placement injects CTA into homepage hero

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Full suite + app build verification

Prove the whole package still builds and that the app target links (per project memory, `swift test` alone doesn't prove the `.app` links).

**Files:** none (verification only).

- [x] **Step 1: Run the full Swift test suite**

Run: `swift test --package-path .`
Expected: PASS — full suite green (no regressions in `AnglesiteCoreTests`, `AnglesiteIntentsTests`, `AnglesiteBridgeTests`).

- [x] **Step 2: Generate the Xcode project (fresh worktree has none)**

Run: `ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite xcodegen generate`
Expected: `Created project at Anglesite.xcodeproj`.

- [x] **Step 3: Build the app target**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 4: No commit needed** (verification task — nothing changed).

---

## Self-Review

**Spec coverage:**
- Spec §1 (homepage anchors) → Task 2. ✓
- Spec §2 (descriptor: button choice, buttonText visibility, two button ops; copyFile/writeConfig/addCSPDomains unchanged) → Task 3 (Steps 4-5). ✓
- Spec §3 (`Condition.fieldIn` + two evaluation sites) → Task 1. ✓
- Spec §4 (testing: planner button plan, fieldIn visibility, validate passes, template asset guard) → Task 1 (visibility + validate), Task 2 (anchors), Task 3 Steps 2/7 (planner plan + asset guard). ✓
- Spec non-goals (no `BookingWidget.astro` change, no CSP change, no inline/floating change) → respected; `addCSPDomains`/`copyFile`/`writeConfig` untouched, floating regression covered by existing `bookingFloatingInjectsIntoLayout`. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**Type consistency:** `Condition.fieldIn(key:values:)` defined in Task 1 Step 4, evaluated in Task 1 Steps 5-6, consumed in Task 3 Step 4. Step types `.injectAnchor` / `.createFile` / `MarkerInjector.CommentStyle` match the existing planner test patterns. ✓

# Hover states for custom interactive controls Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the app's three hand-drawn selectable-card/button views (graph explorer nodes, New
Site theme chooser cards, Apply Theme built-in cards) a visible hover wash, matching what native
`List` rows already get for free.

**Architecture:** Each `ForEach` item that needs independent per-item hover state gets its own
private `View` struct owning `@State private var isHovering`, `@Environment(\.controlActiveState)`,
and `@Environment(\.accessibilityReduceMotion)`. Hover only paints when the window is key
(`controlActiveState != .inactive`) and never overrides the existing selected-state visual. The
opacity change animates with `.easeInOut(duration: 0.12)`, or is instant when Reduce Motion is on.

**Tech Stack:** Swift 6.4, SwiftUI (macOS). No new dependencies.

## Global Constraints

- Swift/SwiftUI with Apple frameworks only — no third-party state libraries (`AGENTS.md` ▸ "Editing
  guidelines").
- App-only change — no MCP schema change, no paired PR needed (`CONTRIBUTING.md` ▸ "Paired PRs").
- Reuse each view's existing selected-state visual language (accent-colored wash/stroke) rather
  than introducing a new hover language, per the approved design spec
  (`docs/superpowers/specs/2026-08-07-hover-states-custom-controls-design.md`).
- Hover feedback must be suppressed when `controlActiveState == .inactive` (window not key).
- Respect `accessibilityReduceMotion` — no animation when it's on, matching the existing pattern in
  `Sources/AnglesiteApp/SiteWindow.swift:46`.

---

## File Structure

- **Modify** `Sources/AnglesiteApp/SiteGraphExplorerView.swift` — `SiteGraphNodeButton` (existing
  private struct, already owns its own state) gains hover tracking.
- **Modify** `Sources/AnglesiteApp/NewSiteWizard.swift` — the `ForEach` item in `chooserStep`
  (currently a bare `Button` + `ThemePreviewCard` label) is extracted into a new private struct
  `ThemeChooserCard` that owns hover state and forwards it into `ThemePreviewCard`, which gains an
  `isHovering` parameter.
- **Modify** `Sources/AnglesiteApp/ThemeApplyWizard.swift` — the `themeCard(_:)` helper function
  (currently returns a `Button` built from `ThemeApplyWizard`'s own scope, so it can't hold
  per-item `@State`) is replaced by a new private struct `ThemeApplyCard` that owns hover state.

No test files change — there is no existing test target that exercises SwiftUI view rendering or
`onHover` (AppKit mouse-tracking isn't reachable from `swift test`); see "Testing" in the design
spec. Verification is a compile check per task plus one full manual-QA task at the end.

---

### Task 1: `SiteGraphNodeButton` hover state

**Files:**
- Modify: `Sources/AnglesiteApp/SiteGraphExplorerView.swift:304-342`

**Interfaces:**
- Consumes: nothing new — `SiteGraphNodeButton` already exists as a private struct with
  `node: SiteGraphNode`, `referenceCount: Int`, `selected: Bool`, `related: Bool`,
  `action: () -> Void`. No caller changes needed (`SiteGraphCanvas` or wherever it's instantiated
  keeps the same call signature).
- Produces: nothing consumed elsewhere — purely internal visual change.

- [ ] **Step 1: Replace the struct body**

Replace the full `SiteGraphNodeButton` struct (lines 304-342) with:

```swift
private struct SiteGraphNodeButton: View {
    let node: SiteGraphNode
    let referenceCount: Int
    let selected: Bool
    let related: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hover only paints while the window is key, so Cmd-Tabbing away mid-hover doesn't leave a
    /// ghost highlight behind in an inactive window (#677).
    private var isHoverActive: Bool { isHovering && controlActiveState != .inactive }

    private var backgroundOpacity: Double {
        if selected { return 0.24 }
        if related || isHoverActive { return 0.16 }
        return 0.1
    }

    private var tintBorderOpacity: Double { isHoverActive ? 0.55 : 0.35 }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: node.kind.systemImage)
                    .font(.headline)
                Text(node.title)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 112)
                if referenceCount > 0 {
                    Text("\(referenceCount) refs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(width: 132)
            .frame(minHeight: 76)
            .background(node.kind.tint.opacity(backgroundOpacity))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : node.kind.tint.opacity(tintBorderOpacity), lineWidth: selected ? 2 : 1)
            }
            .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHoverActive)
        .accessibilityLabel("\(node.kind.title), \(node.title)")
        .help(node.detail ?? node.title)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --package-path . --target AnglesiteAppCore`
Expected: `Build complete!` with no errors or new warnings referencing
`SiteGraphExplorerView.swift`.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/SiteGraphExplorerView.swift
git commit -m "feat(#677): add hover wash to site graph node buttons"
```

---

### Task 2: `NewSiteWizard` theme chooser card hover state

**Files:**
- Modify: `Sources/AnglesiteApp/NewSiteWizard.swift:33-56` (the `chooserStep` `ForEach` body)
- Modify: `Sources/AnglesiteApp/NewSiteWizard.swift:140-177` (`ThemePreviewCard`)

**Interfaces:**
- Consumes: `Theme` (from `AnglesiteCore`, unchanged), `model.draft.themeID`, `model.catalog.themes`
  — all pre-existing on `NewSiteWizardModel`.
- Produces: new private struct `ThemeChooserCard(theme: Theme, isSelected: Bool, onSelect: () ->
  Void, onCreate: () -> Void)`. `ThemePreviewCard` gains a required `isHovering: Bool` parameter —
  its only call site is inside `ThemeChooserCard`, updated in this same task.

- [ ] **Step 1: Replace the `chooserStep` `ForEach` body**

In `chooserStep` (currently lines 33-56), replace the `ForEach` block:

```swift
                    ForEach(model.catalog.themes) { theme in
                        Button { model.draft.themeID = theme.id } label: {
                            ThemePreviewCard(theme: theme, isSelected: model.draft.themeID == theme.id)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // Double-click = choose and create, the document-chooser convention.
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            model.draft.themeID = theme.id
                            create()
                        })
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(theme.name). \(theme.blurb)")
                        .accessibilityValue(model.draft.themeID == theme.id ? "Selected" : "")
                    }
```

with:

```swift
                    ForEach(model.catalog.themes) { theme in
                        ThemeChooserCard(
                            theme: theme,
                            isSelected: model.draft.themeID == theme.id,
                            onSelect: { model.draft.themeID = theme.id },
                            onCreate: {
                                model.draft.themeID = theme.id
                                create()
                            }
                        )
                    }
```

- [ ] **Step 2: Add the `ThemeChooserCard` struct**

Add this new private struct immediately above `ThemePreviewCard` (i.e. just before line 138's
`ThemePreviewCard` doc comment):

```swift
/// One selectable template card in the chooser grid — owns its own hover state so each
/// `ForEach` item tracks the mouse independently rather than sharing one flag across the grid
/// (#677).
private struct ThemeChooserCard: View {
    let theme: Theme
    let isSelected: Bool
    let onSelect: () -> Void
    let onCreate: () -> Void

    @State private var isHovering = false
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHoverActive: Bool { isHovering && controlActiveState != .inactive && !isSelected }

    var body: some View {
        Button(action: onSelect) {
            ThemePreviewCard(theme: theme, isSelected: isSelected, isHovering: isHoverActive)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Double-click = choose and create, the document-chooser convention.
        .simultaneousGesture(TapGesture(count: 2).onEnded(onCreate))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHoverActive)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(theme.name). \(theme.blurb)")
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}
```

- [ ] **Step 3: Give `ThemePreviewCard` an `isHovering` parameter and hover visual**

Replace the `ThemePreviewCard` struct (currently lines 140-177, i.e. from its doc comment through
its closing brace before the `Color(hex:)` extension) with:

```swift
/// One template card: a miniature page mock (nav bar, hero block, text lines) drawn from the
/// theme's own palette, so each card previews a page rather than a bare swatch strip (#1071).
private struct ThemePreviewCard: View {
    let theme: Theme
    let isSelected: Bool
    let isHovering: Bool

    private var primary: Color { Color(hex: theme.cssVars["color-primary"] ?? "#333333") }
    private var accent: Color { Color(hex: theme.cssVars["color-accent"] ?? "#888888") }

    private var borderColor: Color {
        if isSelected { return Color.accentColor }
        if isHovering { return Color.accentColor.opacity(0.4) }
        return Color.clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: 34, height: 4)
                    Spacer()
                }
                .padding(6)
                .background(primary)
                RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.85)).frame(height: 22)
                    .padding(.horizontal, 6)
                Capsule().fill(Color.primary.opacity(0.5)).frame(width: 70, height: 4)
                    .padding(.horizontal, 6)
                Capsule().fill(Color.primary.opacity(0.25)).frame(height: 3)
                    .padding(.horizontal, 6)
                Capsule().fill(Color.primary.opacity(0.25)).frame(width: 90, height: 3)
                    .padding(.horizontal, 6).padding(.bottom, 8)
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            .accessibilityHidden(true)
            Text(theme.name).font(.subheadline.bold())
            Text(theme.blurb).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isHovering ? Color.accentColor.opacity(0.08) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 2))
    }
}
```

(Only the struct body changed — the added `isHovering` field, `borderColor`, and the two lines
right before the closing brace. Everything else, including the `Color(hex:)` extension that
follows, stays as-is.)

- [ ] **Step 4: Verify it compiles**

Run: `swift build --package-path . --target AnglesiteAppCore`
Expected: `Build complete!` with no errors or new warnings referencing `NewSiteWizard.swift`.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/NewSiteWizard.swift
git commit -m "feat(#677): add hover wash to New Site theme chooser cards"
```

---

### Task 3: `ThemeApplyWizard` built-in theme card hover state

**Files:**
- Modify: `Sources/AnglesiteApp/ThemeApplyWizard.swift:57-102`

**Interfaces:**
- Consumes: `Theme` (unchanged), `model.selectedBuiltInID`, `model.catalog.themes` — pre-existing on
  `ThemeApplyWizardModel`.
- Produces: new private struct `ThemeApplyCard(theme: Theme, isSelected: Bool, onSelect: () ->
  Void)`, replacing the `themeCard(_:)` helper function. Nothing outside `pickBuiltInStep` calls
  `themeCard`, so no other call site changes.

- [ ] **Step 1: Replace `pickBuiltInStep` and remove `themeCard(_:)`**

Replace lines 57-102 (from `private var pickBuiltInStep` through the closing brace of
`themeCard(_:)`) with:

```swift
    private var pickBuiltInStep: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.catalog.themes) { theme in
                    ThemeApplyCard(theme: theme, isSelected: model.selectedBuiltInID == theme.id) {
                        model.selectedBuiltInID = theme.id
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
```

- [ ] **Step 2: Add the `ThemeApplyCard` struct**

The file (153 lines) ends with `applyingStep`'s closing brace followed by `ThemeApplyWizard`'s own
closing `}` on line 153, with nothing after it. Append this new private struct as a top-level sibling
type after that final `}`:

```swift
/// One selectable built-in theme card — owns its own hover state so each `ForEach` item tracks
/// the mouse independently rather than sharing one flag across the grid (#677).
private struct ThemeApplyCard: View {
    let theme: Theme
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHoverActive: Bool { isHovering && controlActiveState != .inactive && !isSelected }

    private var fillColor: Color {
        if isSelected { return Color.accentColor.opacity(0.15) }
        if isHoverActive { return Color.accentColor.opacity(0.08) }
        return Color.gray.opacity(0.08)
    }

    private var strokeColor: Color {
        if isSelected { return Color.accentColor }
        if isHoverActive { return Color.accentColor.opacity(0.4) }
        return Color.clear
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(theme.swatch, id: \.self) { hex in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: hex))
                            .frame(width: 24, height: 24)
                    }
                }
                Text(theme.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text(theme.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(fillColor))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(strokeColor, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHoverActive)
    }
}
```

This is a straight behavioral port of the removed `themeCard(_:)` function's view body (same
layout, same base colors for the selected/resting states) with `isHoverActive` added as a third
tier between them.

- [ ] **Step 3: Verify it compiles**

Run: `swift build --package-path . --target AnglesiteAppCore`
Expected: `Build complete!` with no errors or new warnings referencing `ThemeApplyWizard.swift`.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/ThemeApplyWizard.swift
git commit -m "feat(#677): add hover wash to Apply Theme built-in cards"
```

---

### Task 4: Full verification

**Files:** none (verification only).

**Interfaces:** none — this task consumes the finished state of Tasks 1-3 and produces a
verified, mergeable branch.

- [ ] **Step 1: Run the full SwiftPM test suite**

Run: `swift test --package-path .`
Expected: all suites pass (`AnglesiteSiteModelTests`, `AnglesiteCoreTests`, `AnglesiteBridgeTests`,
`AnglesiteAppTests`, and `AnglesiteIntentsTests` on Swift 6.4+/Xcode 27), no new failures.

- [ ] **Step 2: Build the app target**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`

(Run `xcodegen generate` first if the worktree's `.xcodeproj` hasn't been generated yet — it's
gitignored per-worktree.)

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual hover QA**

Launch the built app (or run it via the iOS-simulator-equivalent app launch tooling available in
this session) and check, in both light and dark appearance:

- Open a site with more than one page, open the Site Graph Explorer, hover a node that is neither
  selected nor already "related" — confirm the background/border visibly brighten, and that moving
  off the node reverts it.
- File ▸ New Site — hover a template card that isn't currently selected — confirm the accent wash
  and border appear.
- Open Apply Theme (via the site's theme-change entry point) ▸ Built-in themes — hover a card that
  isn't selected — confirm the same.
- Cmd-Tab to another app while the pointer is left resting over a hovering card, then Cmd-Tab back
  without moving the mouse — confirm the hover wash doesn't paint while the window was inactive
  (it will resume once you move the mouse again, since `onHover` re-fires on movement — the
  acceptance bar is "no stale wash noticeable while inactive/regaining focus", not "hover survives
  an app switch").
- Toggle System Settings ▸ Accessibility ▸ Motion ▸ Reduce motion on, repeat one hover check, and
  confirm the wash still appears (just without the fade-in).

- [ ] **Step 4: Fix any issues found in Step 3**

If manual QA surfaces a problem, fix it in the relevant file from Tasks 1-3, re-run Steps 1-2, and
commit the fix with a message like `fix(#677): <what was wrong>`. Skip this step if QA passed
clean.

# Component Editor Slice 5a: Media-Query Editing + Viewport Presets Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Component Editor's Styles panel collapsible `@media`-grouped sections (with a way to add a rule under a media condition), and give its canvas a viewport-width preset toolbar (Mobile/Tablet/Desktop/Fill) — the two "polish" items from Component Editor slice 5 (issue #495) that need no plugin changes, since `add-style-rule`'s `media` param already shipped in slice 2.

**Architecture:** Two new pure, testable types in `AnglesiteCore` (`ComponentStyleGrouping`, `ComponentViewportPreset`) back two `ComponentEditorView` (AnglesiteApp) changes: the Styles `GroupBox` renders one `DisclosureGroup` per media group instead of a flat rule list, and `canvas(_:)` gains a preset toolbar that constrains the harness `WKWebView`'s width. No new `EditMessage.Op`, no plugin PR, no MCP schema change — this is pure UI wired to the existing `ComponentEditorModel.addStyleRule(selector:media:declarations:)`.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27+), Swift Testing (`import Testing`, `@testable import AnglesiteCore`), existing `ComponentModel`/`ComponentEditorModel` types.

## Global Constraints

- Swift 6.4 / macOS 27+ toolchain (Xcode 27+). `Anglesite.xcodeproj` is gitignored — run `xcodegen generate` first if it's missing from this worktree.
- `ANGLESITE_PLUGIN_SRC` must point at the sibling checkout (`/Users/dwk/Developer/github.com/Anglesite/anglesite`), not the default `../anglesite` (wrong from inside a worktree).
- No new third-party dependencies. Pure logic goes in `AnglesiteCore` so it's covered by `swift test` (hosted `xcodebuild test` doesn't run reliably on this repo's CI runners — see `AGENTS.md` "Build" section).
- Follow existing file conventions exactly: `Sources/AnglesiteCore/Component*.swift` for pure logic, `Tests/AnglesiteCoreTests/Component*Tests.swift` (`import Testing` + `@testable import AnglesiteCore`, no XCTest) for their tests.
- Conventional commits (`feat(component-editor): …`), reference `#495` in the PR.

---

## File Structure

- **Create:** `Sources/AnglesiteCore/ComponentStyleGrouping.swift` — pure function grouping `[ComponentModel.StyleRule]` by `media`, preserving first-appearance order.
- **Create:** `Tests/AnglesiteCoreTests/ComponentStyleGroupingTests.swift`
- **Create:** `Sources/AnglesiteCore/ComponentViewportPreset.swift` — pure enum mapping a preset name to a label + fixed width (or `nil` for "Fill").
- **Create:** `Tests/AnglesiteCoreTests/ComponentViewportPresetTests.swift`
- **Modify:** `Sources/AnglesiteApp/ComponentEditorView.swift` — Styles `GroupBox` grouped rendering + media field on the "Add rule" form; new `viewportToolbar` + width-constrained canvas.

---

### Task 1: `ComponentStyleGrouping` (pure, Core)

**Files:**
- Create: `Sources/AnglesiteCore/ComponentStyleGrouping.swift`
- Test: `Tests/AnglesiteCoreTests/ComponentStyleGroupingTests.swift`

**Interfaces:**
- Consumes: `ComponentModel.StyleRule` (already public, `Sendable, Equatable, Codable`, fields `selector: String`, `media: String?`, `span: Span`, `declarations: [Declaration]` — `Sources/AnglesiteCore/ComponentModel.swift:117-122`).
- Produces: `ComponentStyleGrouping.IndexedRule { let index: Int; let rule: ComponentModel.StyleRule }`, `ComponentStyleGrouping.Group { let media: String?; let rules: [IndexedRule] }`, `ComponentStyleGrouping.groups(from styles: [ComponentModel.StyleRule]) -> [Group]`. Task 3 (`ComponentEditorView`) calls `groups(from:)` and reads `.media`/`.rules[].index`/`.rules[].rule`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/ComponentStyleGroupingTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

struct ComponentStyleGroupingTests {
    private func rule(_ selector: String, media: String? = nil) -> ComponentModel.StyleRule {
        ComponentModel.StyleRule(selector: selector, media: media, span: ComponentModel.Span(start: 0, end: 0), declarations: [])
    }

    @Test("rules with no media form a single base group")
    func baseGroupOnly() {
        let styles = [rule(".a"), rule(".b")]
        let groups = ComponentStyleGrouping.groups(from: styles)
        #expect(groups.count == 1)
        #expect(groups[0].media == nil)
        #expect(groups[0].rules.map(\.index) == [0, 1])
    }

    @Test("rules group by distinct media condition, preserving first-appearance order")
    func groupsByMediaInSourceOrder() {
        let styles = [
            rule(".a"),
            rule(".b", media: "(min-width: 768px)"),
            rule(".c"),
            rule(".d", media: "(min-width: 1024px)"),
        ]
        let groups = ComponentStyleGrouping.groups(from: styles)
        #expect(groups.map(\.media) == [nil, "(min-width: 768px)", "(min-width: 1024px)"])
        #expect(groups[0].rules.map(\.index) == [0, 2])
        #expect(groups[1].rules.map(\.index) == [1])
        #expect(groups[2].rules.map(\.index) == [3])
    }

    @Test("a repeated media condition reuses the same group, not a second one")
    func repeatedMediaReusesGroup() {
        let styles = [
            rule(".a", media: "(min-width: 768px)"),
            rule(".b"),
            rule(".c", media: "(min-width: 768px)"),
        ]
        let groups = ComponentStyleGrouping.groups(from: styles)
        #expect(groups.map(\.media) == ["(min-width: 768px)", nil])
        #expect(groups[0].rules.map(\.index) == [0, 2])
    }

    @Test("empty styles produce no groups")
    func emptyStylesProduceNoGroups() {
        #expect(ComponentStyleGrouping.groups(from: []).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter ComponentStyleGroupingTests`
Expected: FAIL — `ComponentStyleGrouping` does not exist (compile error).

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/ComponentStyleGrouping.swift`:

```swift
import Foundation

/// Groups a component's style rules by their `@media` condition (design spec §4.3: "Media
/// queries as collapsible sections"), preserving the order each distinct condition first
/// appears in the source. Pure/testable — `ComponentEditorView`'s Styles panel renders one
/// collapsible section per group, reusing the existing per-rule editing UI inside.
public enum ComponentStyleGrouping {
    /// One rule plus its original index in the model's flat `styles` array — callers need the
    /// index to re-derive a fresh span via `ComponentEditorModel.ruleSpan(atIndex:)` after a
    /// prior write in the same gesture may have shifted byte offsets (same reason the previous
    /// flat rendering carried `ruleIndex` alongside each rule).
    public struct IndexedRule: Sendable, Equatable {
        public let index: Int
        public let rule: ComponentModel.StyleRule
    }

    /// One media-scoped (or unscoped, `media == nil`) run of rules.
    public struct Group: Sendable, Equatable {
        public let media: String?
        public let rules: [IndexedRule]
    }

    /// Groups rules sharing the same `media` value into one `Group` each, in first-appearance
    /// order — NOT sorted alphabetically, so a component whose source interleaves base and
    /// media-scoped rules still reads top-to-bottom the way it's written. A `media` value
    /// re-encountered later in the array joins its existing group rather than starting a new one.
    public static func groups(from styles: [ComponentModel.StyleRule]) -> [Group] {
        var order: [String] = []
        var byKey: [String: [IndexedRule]] = [:]
        for (index, rule) in styles.enumerated() {
            let key = rule.media ?? ""
            if byKey[key] == nil {
                byKey[key] = []
                order.append(key)
            }
            byKey[key]?.append(IndexedRule(index: index, rule: rule))
        }
        return order.map { key in
            Group(media: key.isEmpty ? nil : key, rules: byKey[key] ?? [])
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ComponentStyleGroupingTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ComponentStyleGrouping.swift Tests/AnglesiteCoreTests/ComponentStyleGroupingTests.swift
git commit -m "feat(component-editor): add ComponentStyleGrouping for media-query sections (#495)"
```

---

### Task 2: `ComponentViewportPreset` (pure, Core)

**Files:**
- Create: `Sources/AnglesiteCore/ComponentViewportPreset.swift`
- Test: `Tests/AnglesiteCoreTests/ComponentViewportPresetTests.swift`

**Interfaces:**
- Consumes: nothing (self-contained enum).
- Produces: `public enum ComponentViewportPreset: String, CaseIterable, Identifiable, Sendable { case mobile, tablet, desktop, fill }` with `var label: String`, `var systemImage: String`, `var width: Double?` (nil for `.fill`). Task 4 (`ComponentEditorView`) iterates `ComponentViewportPreset.allCases` and reads `.label`/`.systemImage`/`.width`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/ComponentViewportPresetTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

struct ComponentViewportPresetTests {
    @Test("fill has no fixed width")
    func fillHasNoWidth() {
        #expect(ComponentViewportPreset.fill.width == nil)
    }

    @Test("mobile, tablet, and desktop have distinct, increasing widths")
    func devicePresetsHaveIncreasingWidths() {
        let mobile = try #require(ComponentViewportPreset.mobile.width)
        let tablet = try #require(ComponentViewportPreset.tablet.width)
        let desktop = try #require(ComponentViewportPreset.desktop.width)
        #expect(mobile < tablet)
        #expect(tablet < desktop)
    }

    @Test("every case has a non-empty label and system image")
    func allCasesHaveLabelAndImage() {
        for preset in ComponentViewportPreset.allCases {
            #expect(!preset.label.isEmpty)
            #expect(!preset.systemImage.isEmpty)
        }
    }

    @Test("id matches the raw value, for SwiftUI ForEach identity")
    func idMatchesRawValue() {
        for preset in ComponentViewportPreset.allCases {
            #expect(preset.id == preset.rawValue)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter ComponentViewportPresetTests`
Expected: FAIL — `ComponentViewportPreset` does not exist (compile error).

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/ComponentViewportPreset.swift`:

```swift
import Foundation

/// Canvas viewport-width presets for the Component Editor (design spec §3/§4.2): fixed device
/// widths for responsive work, pairing with media-query editing in the Styles panel (Task 1).
/// Pure/testable — `ComponentEditorView` maps each case to an SF Symbol and applies `.width` as
/// a `.frame` constraint on the harness `WKWebView`.
public enum ComponentViewportPreset: String, CaseIterable, Identifiable, Sendable {
    case mobile, tablet, desktop, fill

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .mobile: "Mobile"
        case .tablet: "Tablet"
        case .desktop: "Desktop"
        case .fill: "Fill"
        }
    }

    public var systemImage: String {
        switch self {
        case .mobile: "iphone"
        case .tablet: "ipad"
        case .desktop: "display"
        case .fill: "arrow.up.left.and.arrow.down.right"
        }
    }

    /// Fixed viewport width in points, or `nil` for "Fill" (canvas fills the available pane width).
    public var width: Double? {
        switch self {
        case .mobile: 375
        case .tablet: 768
        case .desktop: 1440
        case .fill: nil
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ComponentViewportPresetTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ComponentViewportPreset.swift Tests/AnglesiteCoreTests/ComponentViewportPresetTests.swift
git commit -m "feat(component-editor): add ComponentViewportPreset for canvas toolbar (#495)"
```

---

### Task 3: Styles panel — grouped, collapsible media sections

**Files:**
- Modify: `Sources/AnglesiteApp/ComponentEditorView.swift`

**Interfaces:**
- Consumes: `ComponentStyleGrouping.groups(from:)` (Task 1); existing `ComponentEditorModel.addStyleRule(selector:media:declarations:)` (`Sources/AnglesiteApp/ComponentEditorModel.swift:196-207`, unchanged); existing `selectorBinding(for:)`, `propertyBinding(for:)`, `declarationValueField(...)`, `commitSelector(...)`, `commitDeclaration(...)`, `removeDeclaration(...)`, `spanArray(...)` (all unchanged, already defined lower in the same file).
- Produces: no new public API — this is the Styles `GroupBox`'s rendering, consumed only by SwiftUI itself.

This task has no unit test of its own (SwiftUI view bodies in this codebase are not independently unit-tested — see `AGENTS.md` "Build": hosted `xcodebuild test` doesn't run reliably on CI, so app-target logic that needs coverage is pushed into testable `AnglesiteCore` types, which Task 1 already did). Verification is an `xcodebuild` build (Step 2) plus the manual GUI check in Task 5.

- [ ] **Step 1: Replace the flat Styles rendering with grouped sections**

In `Sources/AnglesiteApp/ComponentEditorView.swift`, first add two new `@State` properties next to the existing `newRuleSelector` declaration (around line 35-36):

```swift
    /// Selector text for the inline "Add rule" form at the bottom of the Styles panel.
    @State private var newRuleSelector: String = ""
    /// `@media` condition text for the inline "Add rule" form; blank means no wrapping media
    /// query (same as passing `nil` to `addStyleRule`).
    @State private var newRuleMedia: String = ""
    /// Media keys (via `mediaGroupKey`) the user has manually collapsed — a `DisclosureGroup`
    /// per media section defaults to expanded, matching the old flat list's always-visible rules.
    @State private var collapsedMediaKeys: Set<String> = []
```

Then replace the entire `GroupBox("Styles") { ... }` block (originally lines 529-588 — the block starting `GroupBox("Styles") {` and ending with the `Add rule` `HStack`'s closing `}` right before `GroupBox("Computed")`) with:

```swift
                GroupBox("Styles") {
                    if let styles = model.model?.styles, !styles.isEmpty {
                        let groups = ComponentStyleGrouping.groups(from: styles)
                        ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                            DisclosureGroup(isExpanded: mediaExpandedBinding(for: group.media)) {
                                ForEach(Array(group.rules.enumerated()), id: \.element.index) { position, indexed in
                                    ruleRow(model, ruleIndex: indexed.index, rule: indexed.rule)
                                    if position < group.rules.count - 1 {
                                        Divider()
                                    }
                                }
                            } label: {
                                Text(group.media.map { "@media \($0)" } ?? "Base styles")
                                    .font(.caption).bold()
                            }
                            if groupIndex < groups.count - 1 {
                                Divider()
                            }
                        }
                    } else {
                        Text("No scoped styles").foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("New selector, e.g. .card-footer", text: $newRuleSelector)
                                .font(.system(.caption, design: .monospaced))
                            TextField("@media (optional)", text: $newRuleMedia)
                                .font(.system(.caption, design: .monospaced))
                        }
                        Button("Add rule") {
                            let selector = newRuleSelector.trimmingCharacters(in: .whitespaces)
                            guard !selector.isEmpty else { return }
                            let media = newRuleMedia.trimmingCharacters(in: .whitespaces)
                            Task {
                                await model.addStyleRule(selector: selector, media: media.isEmpty ? nil : media, declarations: [])
                                newRuleSelector = ""
                                newRuleMedia = ""
                            }
                        }
                        .disabled(newRuleSelector.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
```

Then add two new helper methods right after `paletteView(_:)` (or anywhere among the other private helpers — e.g. directly above the existing `knobsBar` method):

```swift
    /// Stable dictionary/Set key for a media group — `""` for the unscoped "Base styles" group,
    /// the media condition string otherwise. Mirrors `ComponentStyleGrouping.groups`' own
    /// `key.isEmpty ? nil : key` convention so the two stay in sync.
    private func mediaGroupKey(_ media: String?) -> String { media ?? "" }

    /// Expand/collapse binding for one media group's `DisclosureGroup`, backed by
    /// `collapsedMediaKeys` — defaults to expanded (absent from the set) so the panel reads the
    /// same as the old always-expanded flat list until the user explicitly collapses a section.
    private func mediaExpandedBinding(for media: String?) -> Binding<Bool> {
        let key = mediaGroupKey(media)
        return Binding(
            get: { !collapsedMediaKeys.contains(key) },
            set: { expanded in
                if expanded {
                    collapsedMediaKeys.remove(key)
                } else {
                    collapsedMediaKeys.insert(key)
                }
            }
        )
    }

    /// One rule's editable selector + declaration rows — extracted from the old flat Styles
    /// rendering so both the grouped (Task 3) and (unchanged) declaration-editing logic below
    /// stay in one place.
    @ViewBuilder
    private func ruleRow(_ model: ComponentEditorModel, ruleIndex: Int, rule: ComponentModel.StyleRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("selector", text: selectorBinding(for: rule))
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.plain)
                .bold()
                .onSubmit { commitSelector(model, rule: rule) }
            ForEach(rule.declarations, id: \.property) { decl in
                HStack(spacing: 4) {
                    TextField("property", text: propertyBinding(for: decl))
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.plain)
                        .frame(width: 110)
                        .onSubmit { commitDeclaration(model, ruleIndex: ruleIndex, rule: rule, decl: decl) }
                    Text(":")
                    declarationValueField(model, ruleIndex: ruleIndex, rule: rule, decl: decl)
                    Button(role: .destructive) {
                        removeDeclaration(model, rule: rule, decl: decl)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Add declaration") {
                let newProperty = "new-property-\(UUID().uuidString.prefix(8))"
                Task { await model.setStyleProperty(ruleSpan: spanArray(rule.span), property: newProperty, value: "") }
            }
            .font(.caption2)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
```

Note the old per-rule `if let media = rule.media { Text("@media \(media)") }` line is intentionally dropped from `ruleRow` — the media condition is now shown once, as the enclosing `DisclosureGroup`'s label, instead of repeated on every rule in that group.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`

(If `Anglesite.xcodeproj` doesn't exist yet in this worktree, run `xcodegen generate` first.)

Expected: `** BUILD SUCCEEDED **`. If it fails on `ComponentStyleGrouping`/`ComponentViewportPreset` not found, confirm Task 1/2's files were saved under `Sources/AnglesiteCore/` (not `Sources/AnglesiteApp/`) — `ComponentEditorView.swift` already `import AnglesiteCore` (line 3), so no new import line is needed.

- [ ] **Step 3: Run the full Swift test suite to confirm no regressions**

Run: `swift test --package-path .`
Expected: PASS — all existing `ComponentEditorModel`/`ComponentOutline`/`ComponentStyleEditBuilder` tests untouched by this task still pass, plus Task 1/2's new tests.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/ComponentEditorView.swift
git commit -m "feat(component-editor): group Styles panel rules into collapsible @media sections (#495)"
```

---

### Task 4: Canvas viewport-preset toolbar

**Files:**
- Modify: `Sources/AnglesiteApp/ComponentEditorView.swift`

**Interfaces:**
- Consumes: `ComponentViewportPreset` (Task 2); existing `canvas(_:)`, `knobsBar(_:props:)`, `performCanvasDrop(...)`, `ComponentCanvasView` (all defined in this same file, unchanged).
- Produces: no new public API.

Same testing note as Task 3 — no unit test; verified by build (Step 2) + Task 5's manual check.

- [ ] **Step 1: Add viewport state and a toolbar view**

In `Sources/AnglesiteApp/ComponentEditorView.swift`, add a new `@State` property next to `webView` (around line 18):

```swift
    @State private var webView: WKWebView?
    /// Canvas viewport-width preset (design spec §3/§4.2) — "Fill" (the default) matches the
    /// pre-slice-5 behavior of the harness filling the available pane width.
    @State private var viewportPreset: ComponentViewportPreset = .fill
```

Add a new `viewportToolbar` view, placed directly above the existing `canvas(_:)` method:

```swift
    /// Device-width preset row above the canvas (design spec §3: "A viewport-width control
    /// (device presets + free resize)…"). "Free resize" isn't implemented in this pass — the
    /// four fixed presets are the "polish" scope issue #495 asks for; a drag handle can follow
    /// as its own increment if needed.
    private var viewportToolbar: some View {
        HStack(spacing: 2) {
            ForEach(ComponentViewportPreset.allCases) { preset in
                Button {
                    viewportPreset = preset
                } label: {
                    Image(systemName: preset.systemImage)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(viewportPreset == preset ? Color.accentColor : Color.secondary)
                .help(preset.label)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
```

- [ ] **Step 2: Extract the harness WKWebView into its own width-constrained view, and wire the toolbar into `canvas(_:)`**

Replace the existing `canvas(_:)` method body:

```swift
    @ViewBuilder private func canvas(_ model: ComponentEditorModel) -> some View {
        VStack(spacing: 0) {
            if let props = model.model?.frontmatter?.props, !props.isEmpty {
                knobsBar(model, props: props)
                Divider()
            }
            // Gated directly on `context.baseURL` (not just `model.harnessURL`)
            // so the live canvas replaces this placeholder the moment the dev
            // server becomes ready, in lockstep with the `loadKey`-driven
            // reload above.
            if context.baseURL != nil, let url = model.harnessURL {
                ComponentCanvasView(
                    url: url,
                    editRouter: context.editRouter,
                    onSelection: { model.canvasSelected($0) },
                    onComputedStyles: { model.computedStyles = $0.styles },
                    onWebView: { webView = $0 }
                )
                .dropDestination(for: OutlineDragPayload.self) { items, location in
                    guard let item = items.first, case .insert(let payload) = item, let webView else { return false }
                    Task { await performCanvasDrop(model, payload: payload, location: location, webView: webView) }
                    return true
                }
            } else {
                ContentUnavailableView("Dev Server Starting…", systemImage: "hourglass")
            }
        }
    }
```

with:

```swift
    @ViewBuilder private func canvas(_ model: ComponentEditorModel) -> some View {
        VStack(spacing: 0) {
            viewportToolbar
            Divider()
            if let props = model.model?.frontmatter?.props, !props.isEmpty {
                knobsBar(model, props: props)
                Divider()
            }
            canvasWebView(model)
        }
    }

    /// The harness `WKWebView` itself (drop-destination wiring unchanged from before this
    /// task), width-constrained to `viewportPreset.width` when a fixed preset is active. `.fill`
    /// (`width == nil`) renders identically to the pre-slice-5 behavior — no frame constraint,
    /// canvas fills the available pane width.
    @ViewBuilder private func canvasWebView(_ model: ComponentEditorModel) -> some View {
        // Gated directly on `context.baseURL` (not just `model.harnessURL`)
        // so the live canvas replaces this placeholder the moment the dev
        // server becomes ready, in lockstep with the `loadKey`-driven
        // reload above.
        if context.baseURL != nil, let url = model.harnessURL {
            let content = ComponentCanvasView(
                url: url,
                editRouter: context.editRouter,
                onSelection: { model.canvasSelected($0) },
                onComputedStyles: { model.computedStyles = $0.styles },
                onWebView: { webView = $0 }
            )
            .dropDestination(for: OutlineDragPayload.self) { items, location in
                guard let item = items.first, case .insert(let payload) = item, let webView else { return false }
                Task { await performCanvasDrop(model, payload: payload, location: location, webView: webView) }
                return true
            }
            if let width = viewportPreset.width {
                ScrollView(.horizontal) {
                    content.frame(width: width, height: 800)
                }
            } else {
                content
            }
        } else {
            ContentUnavailableView("Dev Server Starting…", systemImage: "hourglass")
        }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full Swift test suite to confirm no regressions**

Run: `swift test --package-path .`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/ComponentEditorView.swift
git commit -m "feat(component-editor): add viewport-preset toolbar to the canvas pane (#495)"
```

---

### Task 5: Manual GUI verification

**Files:** none (verification only).

- [ ] **Step 1: Launch the app and open a component with existing styles**

Build and run `Anglesite` (⌘R in Xcode, or `xcodebuild ... build` then launch `Anglesite.app` from `DerivedData`). Open (or create) a site with a component under `src/components/` that has a scoped `<style>` block with at least one plain rule and one rule wrapped in `@media (min-width: 768px) { ... }` (add one by hand in the Source tab first if none exists, then reload the Design tab).

- [ ] **Step 2: Verify the grouped Styles panel**

Open that component in the Component Editor (Design mode). Confirm:
- The Styles panel shows a "Base styles" section and a "@media (min-width: 768px)" section, each a collapsible `DisclosureGroup`.
- Clicking a section's disclosure triangle collapses/expands just that section.
- Typing a selector and a `@media` condition into the "Add rule" form's two fields and clicking "Add rule" creates a new rule that appears under a (new, if the condition didn't already exist) matching media section.
- Leaving the `@media` field blank and adding a rule adds it to "Base styles".

- [ ] **Step 3: Verify the viewport toolbar**

In the same component's canvas pane, confirm a small icon row (phone/tablet/display/arrows) appears above the canvas. Click each preset and confirm:
- "Mobile"/"Tablet"/"Desktop" visibly narrow the rendered harness to a fixed width (with horizontal scrolling available if the pane is narrower than the preset).
- "Fill" returns the canvas to filling the full pane width (today's pre-slice-5 behavior).
- The selected preset's icon is highlighted (accent color) vs. the others (secondary).

- [ ] **Step 4: Report results**

If all checks pass, proceed to Task 6. If anything fails, fix it in the relevant task's file before continuing (do not skip ahead with a known-broken UI).

---

### Task 6: Open the pull request

**Files:** none (git/gh only).

- [ ] **Step 1: Push the branch**

```bash
git push -u origin claude/issue-495-fd0042
```

(If this branch was already pushed earlier in the session, a plain `git push` suffices.)

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "feat(component-editor): media-query editing + viewport presets (#495)" --body "$(cat <<'EOF'
## Summary
- Groups the Component Editor's Styles panel rules into collapsible `@media` sections (design spec §4.3), reusing the existing `add-style-rule` op's `media` param (already shipped in slice 2 — no plugin change needed).
- Adds a Mobile/Tablet/Desktop/Fill viewport-preset toolbar above the canvas (design spec §3/§4.2), constraining the harness `WKWebView`'s width.
- Part of Component Editor slice 5 (#495) — the two pieces of that issue that need no plugin/MCP schema change. The `extract-component` op and the app's "Extract into Component…"/"Duplicate & Modify" UI ship as follow-up PRs.

## Test plan
- [x] `swift test --package-path .` — new `ComponentStyleGroupingTests`/`ComponentViewportPresetTests` plus full existing suite pass.
- [x] `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` succeeds.
- [x] Manual GUI check: grouped/collapsible media sections, add-rule-with-media, and all four viewport presets verified in a running component editor.
EOF
)"
```

- [ ] **Step 3: Remove the in-progress label from #495 only if this PR fully closes it**

This PR does not fully close #495 (extract-component and duplicate-and-modify are still outstanding). Leave the `🛠️ In Progress` label on #495 and do NOT reference "Closes #495" in the PR body — reference it as "Part of #495" instead (already done in Step 2's body). Do not remove the label until the final follow-up PR lands.

---

## Self-Review Notes

- **Spec coverage:** design spec §3 ("viewport-width control… device presets") → Task 4. §4.2 ("viewport presets") → Task 4. §4.3 ("Media queries as collapsible sections; 'add media query' scaffolds a block") → Task 3 (a new media condition typed into the Add Rule form scaffolds its own section the moment the first rule under it exists — no separate empty-section affordance needed, since sections are derived directly from existing rules). Free-resize (also mentioned in §3) is explicitly deferred — noted in Task 4 Step 1's doc comment rather than silently dropped.
- **Out of scope for this plan (tracked separately under #495):** `extract-component` plugin op + "Extract into Component…" UI; "duplicate-and-modify" from a component-listing context menu; named-slot sample content (already shipped, #490).

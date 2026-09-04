# AppKit Shell Slice 1 (columns) Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the flag-gated `NSSplitViewController` shell (sidebar | content | inspector) for the site window, per Stage 3 slice 1 of `docs/superpowers/specs/2026-09-01-site-window-appkit-shell-design.md`.

**Architecture:** A generic `SiteShellSplitController` (three `NSHostingController` columns, all `sizingOptions = []`, constant `NSSplitViewItem` thicknesses) bridged by `SiteShellView: NSViewControllerRepresentable`; pure convergence rules live in `SiteShellState`. `SiteWindow.siteUI` branches at the chrome root on `SiteShellFlag`; sidebar/detail column content is extracted so both branches share it verbatim. Two `@SceneStorage` tab keys are hoisted out of soon-to-be-hosted content. SwiftUI toolbar/search/title modifiers stay attached outside the shell (slice 2 owns them later).

**Tech Stack:** Swift 6.4, SwiftUI + AppKit (no new dependencies), Swift Testing.

## Global Constraints

- Apple frameworks only; no new dependencies.
- Doc comments per `docs/comment-style-guide.md`; CI fails on broken DocC links.
- Commit subjects conventional, ≤72 chars, scoped `feat(#1699)`/`test`/`docs` — never a closing type; slice 3's PR closes #1699, not this slice.
- No new user-visible strings (columns re-host existing views) → no String Catalog sync. If one sneaks in, run the CONTRIBUTING sync recipe scoped to this worktree's `BUILD_DIR`.
- Work in this worktree (branch `claude/issue-1699-6ba2fd`); container artifacts provisioned; use `scripts/build-app.sh`, never raw `xcodebuild`.
- Design-doc rules that bind every task: no `focusedSceneValue` inside hosted columns; the inspector state machine's code is untouched except where this plan says otherwise.

---

### Task 1: `SiteShellFlag` + `SiteShellState` (pure logic)

**Files:**
- Create: `Sources/AnglesiteApp/SiteShell/SiteShellFlag.swift`
- Create: `Sources/AnglesiteApp/SiteShell/SiteShellState.swift`
- Test: `Tests/AnglesiteAppTests/SiteShellStateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `SiteShellFlag.isEnabled: Bool`, `SiteShellFlag.defaultsKey: String`; `SiteShellState.collapseMutation(visible:isCollapsed:) -> Bool?`; `SiteShellState.visibilityWriteBack(isCollapsed:bindingVisible:) -> Bool?`. Tasks 2/3/5 use these exact names.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteAppTests/SiteShellStateTests.swift`:

```swift
import Testing
@testable import AnglesiteAppCore

/// Freezes the shell's SwiftUI↔AppKit convergence rules (#1699 slice 1): mutations fire only
/// when the sides disagree, and KVO echoes of our own mutations produce no write-back — the
/// re-entrancy guarantee the whole bridge leans on.
@Suite("SiteShellState convergence (#1699)")
struct SiteShellStateTests {
    @Test("collapse mutation fires only on disagreement")
    func collapseMutation() {
        #expect(SiteShellState.collapseMutation(visible: true, isCollapsed: true) == false)
        #expect(SiteShellState.collapseMutation(visible: false, isCollapsed: false) == true)
        #expect(SiteShellState.collapseMutation(visible: true, isCollapsed: false) == nil)
        #expect(SiteShellState.collapseMutation(visible: false, isCollapsed: true) == nil)
    }

    @Test("write-back fires only when the binding disagrees (KVO echo is a no-op)")
    func visibilityWriteBack() {
        #expect(SiteShellState.visibilityWriteBack(isCollapsed: true, bindingVisible: true) == false)
        #expect(SiteShellState.visibilityWriteBack(isCollapsed: false, bindingVisible: false) == true)
        #expect(SiteShellState.visibilityWriteBack(isCollapsed: true, bindingVisible: false) == nil)
        #expect(SiteShellState.visibilityWriteBack(isCollapsed: false, bindingVisible: true) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter SiteShellStateTests 2>&1 | tail -8`
Expected: compile FAILURE — `cannot find 'SiteShellState' in scope`.

- [ ] **Step 3: Write the implementations**

Create `Sources/AnglesiteApp/SiteShell/SiteShellState.swift`:

```swift
import Foundation

/// Pure convergence rules for the AppKit shell bridge (#1699 slice 1, design doc
/// §Architecture): given SwiftUI's desired visibility and AppKit's observed collapse state,
/// decide the one mutation (or write-back) needed — or nothing when already converged.
/// Factored out of the controller/representable so SwiftPM tests can freeze the re-entrancy
/// behavior without a window: our own programmatic collapse produces a KVO echo whose
/// write-back must be a no-op, or the bridge would oscillate.
enum SiteShellState {
    /// The `isCollapsed` value to set to honor `visible`, or nil when already converged.
    static func collapseMutation(visible: Bool, isCollapsed: Bool) -> Bool? {
        let target = !visible
        return target == isCollapsed ? nil : target
    }

    /// The visibility value to write back for an observed collapse change, or nil when the
    /// binding already agrees (which is exactly the KVO echo of our own mutation).
    static func visibilityWriteBack(isCollapsed: Bool, bindingVisible: Bool) -> Bool? {
        let observedVisible = !isCollapsed
        return observedVisible == bindingVisible ? nil : observedVisible
    }
}
```

Create `Sources/AnglesiteApp/SiteShell/SiteShellFlag.swift`:

```swift
import Foundation

/// Slice-1 rollout gate for the AppKit site-window shell (#1699 Stage 3 design §Rollout):
/// off by default so `main` keeps shipping the legacy `NavigationSplitView` chrome; enabled
/// per-machine via defaults or per-launch via environment for harness runs. Deleted in
/// slice 3 when the shell becomes the only chrome.
enum SiteShellFlag {
    static let defaultsKey = "experimental.appKitShell"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ANGLESITE_APPKIT_SHELL"] == "1"
            || UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter SiteShellStateTests 2>&1 | tail -6`
Expected: 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteShell/ Tests/AnglesiteAppTests/SiteShellStateTests.swift
git commit -m "feat(#1699): shell flag + pure convergence rules (slice 1)"
```

---

### Task 2: `SiteShellSplitController`

**Files:**
- Create: `Sources/AnglesiteApp/SiteShell/SiteShellSplitController.swift`
- Test: `Tests/AnglesiteAppTests/SiteShellSplitControllerTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 (the controller is deliberately rule-free; convergence lives in the representable).
- Produces: `SiteShellSplitController<Sidebar: View, Content: View, Inspector: View>: NSSplitViewController` with `init(sidebar:content:inspector:)`, `update(sidebar:content:inspector:)`, `setSidebarCollapsed(_:animated:)`, `setInspectorCollapsed(_:animated:)`, `sidebarItem`/`inspectorItem: NSSplitViewItem`, `onSidebarCollapseChange`/`onInspectorCollapseChange: (@MainActor (Bool) -> Void)?`, `static sidebarThickness`/`inspectorThickness: (min: CGFloat, max: CGFloat)`. Task 3 uses all of these exactly as named.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteAppTests/SiteShellSplitControllerTests.swift`:

```swift
import Testing
import AppKit
import SwiftUI
@testable import AnglesiteAppCore

/// Freezes the shell controller's crash-class invariants (#1699 slice 1, design doc §"Why
/// this fixes the crash"): no column may publish sizing constraints, thicknesses are the
/// legacy chrome's constants, and collapse setters are idempotent. The crash itself is only
/// provable in the windowed 5× harness (plan Task 6); these tests pin what makes the shell
/// negotiation-free by construction.
@MainActor
@Suite("SiteShellSplitController invariants (#1699)")
struct SiteShellSplitControllerTests {
    private func makeController() -> SiteShellSplitController<Text, Text, Text> {
        let controller = SiteShellSplitController(
            sidebar: Text("s"), content: Text("c"), inspector: Text("i"))
        _ = controller.view // force viewDidLoad
        return controller
    }

    @Test("no hosting column publishes sizing constraints")
    func sizingOptionsEmpty() {
        let controller = makeController()
        #expect(controller.sidebarHost.sizingOptions == [])
        #expect(controller.contentHost.sizingOptions == [])
        #expect(controller.inspectorHost.sizingOptions == [])
    }

    @Test("three items with sidebar/inspector behaviors and legacy thicknesses")
    func itemsAndThicknesses() {
        let controller = makeController()
        #expect(controller.splitViewItems.count == 3)
        #expect(controller.sidebarItem.behavior == .sidebar)
        #expect(controller.inspectorItem.behavior == .inspector)
        #expect(controller.sidebarItem.minimumThickness == 200)
        #expect(controller.sidebarItem.maximumThickness == 360)
        #expect(controller.inspectorItem.minimumThickness == 260)
        #expect(controller.inspectorItem.maximumThickness == 420)
        #expect(controller.splitView.autosaveName == "site-shell")
    }

    @Test("collapse setters converge and are idempotent")
    func collapseSetters() {
        let controller = makeController()
        controller.setSidebarCollapsed(true, animated: false)
        #expect(controller.sidebarItem.isCollapsed)
        controller.setSidebarCollapsed(true, animated: false) // no-op, must not throw/toggle
        #expect(controller.sidebarItem.isCollapsed)
        controller.setInspectorCollapsed(true, animated: false)
        #expect(controller.inspectorItem.isCollapsed)
        controller.setInspectorCollapsed(false, animated: false)
        #expect(!controller.inspectorItem.isCollapsed)
    }

    @Test("update replaces the hosted root views")
    func updateReplacesRoots() {
        let controller = makeController()
        controller.update(sidebar: Text("s2"), content: Text("c2"), inspector: Text("i2"))
        // No public accessor for rootView equality on Text; the contract here is just that
        // update() executes without touching the split structure.
        #expect(controller.splitViewItems.count == 3)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter SiteShellSplitControllerTests 2>&1 | tail -8`
Expected: compile FAILURE — `cannot find 'SiteShellSplitController' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteApp/SiteShell/SiteShellSplitController.swift`:

```swift
import AppKit
import SwiftUI

/// The site window's AppKit split shell (#1699 Stage 3, slice 1): sidebar | content |
/// inspector as native `NSSplitViewItem`s over `NSHostingController` columns.
///
/// The crash-class mechanism this replaces is absent by construction (design doc §"Why this
/// fixes the crash"): every hosting controller sets `sizingOptions = []`, so no column
/// publishes min/ideal/max constraints, and the private SwiftUI `SplitViewChildController`
/// negotiation that aborted the app (#1696, 5/5 on 26A5425a) has no counterpart here. Column
/// widths are governed solely by the constant thicknesses below plus the split view's own
/// autosave. Collapse changes are explicit, app-ordered mutations; the KVO hooks report
/// user/AppKit-driven changes (drag-collapse, `toggleSidebar:` from the stock View-menu
/// item, which `NSSplitViewController` answers natively) back to the SwiftUI bindings.
@MainActor
final class SiteShellSplitController<Sidebar: View, Content: View, Inspector: View>:
    NSSplitViewController {
    /// Matches the legacy `navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)`.
    static var sidebarThickness: (min: CGFloat, max: CGFloat) { (200, 360) }
    /// Matches the legacy `.inspectorColumnWidth(min: 260, ideal: 300, max: 420)`.
    static var inspectorThickness: (min: CGFloat, max: CGFloat) { (260, 420) }
    /// Legacy ideal widths, applied once on first run (afterwards autosave restores).
    private static var idealSidebarWidth: CGFloat { 240 }
    private static var idealInspectorWidth: CGFloat { 300 }

    let sidebarHost: NSHostingController<Sidebar>
    let contentHost: NSHostingController<Content>
    let inspectorHost: NSHostingController<Inspector>
    let sidebarItem: NSSplitViewItem
    let inspectorItem: NSSplitViewItem

    /// Fired on every `isCollapsed` change, including the KVO echo of our own setters —
    /// `SiteShellState.visibilityWriteBack` filters echoes to no-ops on the SwiftUI side.
    var onSidebarCollapseChange: (@MainActor (Bool) -> Void)?
    var onInspectorCollapseChange: (@MainActor (Bool) -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private var appliedInitialLayout = false

    init(sidebar: Sidebar, content: Content, inspector: Inspector) {
        sidebarHost = NSHostingController(rootView: sidebar)
        contentHost = NSHostingController(rootView: content)
        inspectorHost = NSHostingController(rootView: inspector)
        sidebarHost.sizingOptions = []
        contentHost.sizingOptions = []
        inspectorHost.sizingOptions = []

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = Self.sidebarThickness.min
        sidebarItem.maximumThickness = Self.sidebarThickness.max
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        inspectorItem.minimumThickness = Self.inspectorThickness.min
        inspectorItem.maximumThickness = Self.inspectorThickness.max

        super.init(nibName: nil, bundle: nil)

        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: contentHost))
        addSplitViewItem(inspectorItem)
        splitView.autosaveName = "site-shell"

        for (item, callback) in [
            (sidebarItem, \SiteShellSplitController.onSidebarCollapseChange),
            (inspectorItem, \SiteShellSplitController.onInspectorCollapseChange),
        ] {
            observations.append(item.observe(\.isCollapsed, options: [.new]) {
                [weak self] item, _ in
                // NSSplitViewItem state changes land on the main thread; assumeIsolated
                // documents that rather than hopping through a Task that could reorder
                // against a subsequent programmatic mutation.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self[keyPath: callback]?(item.isCollapsed)
                }
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SiteShellSplitController is code-constructed only") }

    /// Re-pushes SwiftUI content into the hosted columns — called from
    /// `SiteShellView.updateNSViewController` on every SwiftUI update so the columns stay live.
    func update(sidebar: Sidebar, content: Content, inspector: Inspector) {
        sidebarHost.rootView = sidebar
        contentHost.rootView = content
        inspectorHost.rootView = inspector
    }

    func setSidebarCollapsed(_ collapsed: Bool, animated: Bool) {
        guard sidebarItem.isCollapsed != collapsed else { return }
        (animated ? sidebarItem.animator() : sidebarItem).isCollapsed = collapsed
    }

    func setInspectorCollapsed(_ collapsed: Bool, animated: Bool) {
        guard inspectorItem.isCollapsed != collapsed else { return }
        (animated ? inspectorItem.animator() : inspectorItem).isCollapsed = collapsed
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialLayoutIfNeeded()
    }

    /// First-run column widths (the legacy chrome's ideals). Subsequent runs are restored by
    /// `autosaveName`; the guard keys off the autosave defaults entry AppKit writes.
    private func applyInitialLayoutIfNeeded() {
        guard !appliedInitialLayout, view.frame.width > 0 else { return }
        appliedInitialLayout = true
        let autosaveDefaultsKey = "NSSplitView Subview Frames site-shell"
        guard UserDefaults.standard.object(forKey: autosaveDefaultsKey) == nil else { return }
        splitView.setPosition(Self.idealSidebarWidth, ofDividerAt: 0)
        if !inspectorItem.isCollapsed {
            splitView.setPosition(
                view.frame.width - Self.idealInspectorWidth, ofDividerAt: 1)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter SiteShellSplitControllerTests 2>&1 | tail -8`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SiteShell/SiteShellSplitController.swift Tests/AnglesiteAppTests/SiteShellSplitControllerTests.swift
git commit -m "feat(#1699): SiteShellSplitController (slice 1 columns)"
```

---

### Task 3: `SiteShellView` representable

**Files:**
- Create: `Sources/AnglesiteApp/SiteShell/SiteShellView.swift`

**Interfaces:**
- Consumes: `SiteShellSplitController` (Task 2), `SiteShellState` (Task 1) — exact signatures per their Produces blocks.
- Produces: `SiteShellView<Sidebar: View, Content: View, Inspector: View>` with `init(sidebarVisible: Binding<Bool>, inspectorPresented: Binding<Bool>, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: () -> Content, @ViewBuilder inspector: () -> Inspector)`. Task 5 instantiates it exactly so.

- [ ] **Step 1: Write the implementation** (no unit test — the type is a thin bridge whose
  rules are already frozen by Tasks 1–2; its behavior gate is Task 6's windowed harness)

Create `Sources/AnglesiteApp/SiteShell/SiteShellView.swift`:

```swift
import AppKit
import SwiftUI

/// Bridges SwiftUI chrome state into `SiteShellSplitController` (#1699 slice 1). Column
/// contents are re-pushed as `rootView`s on every update so the hosted columns stay live;
/// visibility bindings converge through `SiteShellState`'s rules, whose no-op answers on
/// KVO echoes are what keeps the bridge from oscillating. The coordinator re-captures the
/// bindings each update so collapse callbacks never write through a stale binding.
struct SiteShellView<Sidebar: View, Content: View, Inspector: View>: NSViewControllerRepresentable {
    @Binding var sidebarVisible: Bool
    @Binding var inspectorPresented: Bool
    let sidebar: Sidebar
    let content: Content
    let inspector: Inspector

    init(
        sidebarVisible: Binding<Bool>,
        inspectorPresented: Binding<Bool>,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder content: () -> Content,
        @ViewBuilder inspector: () -> Inspector
    ) {
        _sidebarVisible = sidebarVisible
        _inspectorPresented = inspectorPresented
        self.sidebar = sidebar()
        self.content = content()
        self.inspector = inspector()
    }

    @MainActor
    final class Coordinator {
        var sidebarBinding: Binding<Bool>
        var inspectorBinding: Binding<Bool>
        init(sidebar: Binding<Bool>, inspector: Binding<Bool>) {
            sidebarBinding = sidebar
            inspectorBinding = inspector
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sidebar: $sidebarVisible, inspector: $inspectorPresented)
    }

    func makeNSViewController(context: Context) -> SiteShellSplitController<Sidebar, Content, Inspector> {
        let controller = SiteShellSplitController(
            sidebar: sidebar, content: content, inspector: inspector)
        controller.setSidebarCollapsed(!sidebarVisible, animated: false)
        controller.setInspectorCollapsed(!inspectorPresented, animated: false)
        let coordinator = context.coordinator
        controller.onSidebarCollapseChange = { collapsed in
            if let visible = SiteShellState.visibilityWriteBack(
                isCollapsed: collapsed,
                bindingVisible: coordinator.sidebarBinding.wrappedValue) {
                coordinator.sidebarBinding.wrappedValue = visible
            }
        }
        controller.onInspectorCollapseChange = { collapsed in
            if let visible = SiteShellState.visibilityWriteBack(
                isCollapsed: collapsed,
                bindingVisible: coordinator.inspectorBinding.wrappedValue) {
                coordinator.inspectorBinding.wrappedValue = visible
            }
        }
        return controller
    }

    func updateNSViewController(
        _ controller: SiteShellSplitController<Sidebar, Content, Inspector>, context: Context
    ) {
        context.coordinator.sidebarBinding = $sidebarVisible
        context.coordinator.inspectorBinding = $inspectorPresented
        controller.update(sidebar: sidebar, content: content, inspector: inspector)
        if let target = SiteShellState.collapseMutation(
            visible: sidebarVisible, isCollapsed: controller.sidebarItem.isCollapsed) {
            controller.setSidebarCollapsed(target, animated: true)
        }
        if let target = SiteShellState.collapseMutation(
            visible: inspectorPresented, isCollapsed: controller.inspectorItem.isCollapsed) {
            controller.setInspectorCollapsed(target, animated: true)
        }
    }
}
```

- [ ] **Step 2: Verify the package builds**

Run: `swift build --package-path . 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/SiteShell/SiteShellView.swift
git commit -m "feat(#1699): SiteShellView representable bridge (slice 1)"
```

---

### Task 4: Hoist the two in-column `@SceneStorage` tab keys

`@SceneStorage` does not resolve inside an `NSHostingController` (no scene context) — the
shell-hosted inspector would silently stop persisting its tab (design doc §Contract
preservation). Keys are unchanged, so existing scenes restore their values.

**Files:**
- Modify: `Sources/AnglesiteApp/SiteInspectorView.swift:17-24`
- Modify: `Sources/AnglesiteApp/WebsiteInspectorView.swift:6-11`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (declarations near line 34; call sites at 1418 and 1467)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `SiteInspectorView(selection:canvasWebView:previewBaseURL:tab:)` and `WebsiteInspectorView(model:openStylesheet:openMoreSettings:tab:)` where `tab: Binding<SiteInspectorTab>`; `SiteWindow` gains `@SceneStorage("siteInspector.tab") siteInspectorTab` and `@SceneStorage("websiteInspector.tab") websiteInspectorTab`.

- [ ] **Step 1: Check for other instantiations (tests included)**

Run: `grep -rn "SiteInspectorView(\|WebsiteInspectorView(" Sources/ Tests/ | grep -v "struct \|//"`
Expected: only `SiteWindow.swift:1418` and `SiteWindow.swift:1467`. If a test constructs
either view, add `tab: .constant(.metadata)` there in the same edit wave.

- [ ] **Step 2: Convert `SiteInspectorView`**

In `Sources/AnglesiteApp/SiteInspectorView.swift`, replace line 24:

```swift
    @SceneStorage("siteInspector.tab") private var tab: SiteInspectorTab = .metadata
```

with:

```swift
    /// Hoisted to `SiteWindow` (#1699 slice 1): `@SceneStorage` does not resolve inside an
    /// `NSHostingController`, so the shell-hosted inspector must receive the persisted tab
    /// from the scene-owning window instead of reading scene storage itself.
    @Binding var tab: SiteInspectorTab
```

- [ ] **Step 3: Convert `WebsiteInspectorView`**

In `Sources/AnglesiteApp/WebsiteInspectorView.swift`, replace line 11:

```swift
    @SceneStorage("websiteInspector.tab") private var tab: SiteInspectorTab = .metadata
```

with:

```swift
    /// Hoisted to `SiteWindow` (#1699 slice 1) — same `NSHostingController`/scene-storage
    /// constraint as `SiteInspectorView.tab`.
    @Binding var tab: SiteInspectorTab
```

- [ ] **Step 4: Declare the keys in `SiteWindow` and pass them down**

In `Sources/AnglesiteApp/SiteWindow.swift`, directly after the `activeInspector` declaration
(line 34), add:

```swift
    /// Hoisted from `SiteInspectorView`/`WebsiteInspectorView` (#1699 slice 1): scene storage
    /// must live in the scene-owning window once those views are hosted inside the AppKit
    /// shell's `NSHostingController` columns. Keys unchanged, so existing scenes restore.
    @SceneStorage("siteInspector.tab") private var siteInspectorTab: SiteInspectorTab = .metadata
    @SceneStorage("websiteInspector.tab") private var websiteInspectorTab: SiteInspectorTab = .metadata
```

At line 1418 add the argument to the `SiteInspectorView` call:

```swift
                SiteInspectorView(
                    selection: selection,
                    canvasWebView: componentCanvasWebView,
                    previewBaseURL: model.preview.readyURL,
                    tab: $siteInspectorTab
                )
```

At line 1467 add the argument to the `WebsiteInspectorView` call:

```swift
                    WebsiteInspectorView(
                        model: websiteModel,
                        openStylesheet: { model.openFile($0) },
                        openMoreSettings: { model.openWebsiteSettings() },
                        tab: $websiteInspectorTab
                    )
```

- [ ] **Step 5: Run the full suite and app build**

Run: `swift test --package-path . 2>&1 | tail -3`
Expected: 0 failures.
Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -2`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/SiteInspectorView.swift Sources/AnglesiteApp/WebsiteInspectorView.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#1699): hoist inspector tab scene storage to SiteWindow"
```

---

### Task 5: Branch `SiteWindow.siteUI` on the flag

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift:423-533` (the `NavigationSplitView` +
  `.animation` + `.inspector` run inside `siteUI(for:)`) plus new private helpers below
  `siteUI`.

**Interfaces:**
- Consumes: `SiteShellFlag.isEnabled` (Task 1), `SiteShellView(sidebarVisible:inspectorPresented:sidebar:content:inspector:)` (Task 3).
- Produces: nothing new outside the file.

- [ ] **Step 1: Extract the sidebar column**

Add below `siteUI(for:)` (content is a verbatim move of lines 427-454, minus the
`navigationSplitViewColumnWidth`, which is legacy-only and moves to the call site):

```swift
    /// Sidebar column content, shared verbatim by the legacy `NavigationSplitView` and the
    /// AppKit shell (#1699 slice 1). `navigationSplitViewColumnWidth` stays at the legacy
    /// call site — the shell expresses the same limits as `NSSplitViewItem` thicknesses.
    @ViewBuilder
    private func sidebarColumn(for site: SiteStore.Site) -> some View {
        if let navigator = model.navigator {
            SiteNavigatorView(
                model: navigator,
                canvasHasKeyboardFocus: model.preview.wysiwygCanvas?.hasKeyboardFocus == true,
                onDeleteRequested: { item in
                    contentDeleteTitle = "Delete “\(item.title)”?"
                    model.deleteConfirmation = item
                },
                onDuplicateRequested: { item in
                    Task { await model.duplicate(id: item.id) }
                },
                onRepurposeRequested: { item in
                    Task { await model.presentRepurpose(postRowID: item.id) }
                },
                onPublishRequested: { item in
                    Task { await model.publish(id: item.id) }
                },
                onUnpublishRequested: { item in
                    Task { await model.unpublish(id: item.id) }
                }
            )
                .onChange(of: navigator.selection) { _, newID in
                    model.applyNavigatorSelection(newID)
                }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
```

- [ ] **Step 2: Extract the detail column, moving the drawer animations inside**

Add a `detailColumn(for:)` helper whose body is a verbatim move of the detail `ZStack`
(lines 456-527), with ONE change: the two `.animation` modifiers currently at lines 528-529
(`value: model.deploy.drawerPresented` / `value: model.backup.drawerPresented`) move onto
the `ZStack` itself, with this comment above them:

```swift
        // Moved inside the column (#1699 slice 1): `.animation(value:)` on an ancestor does
        // not cross an `NSHostingController` boundary, so on a shell ancestor the drawer
        // transitions would stop animating. Inside the column it serves both chromes.
```

The helper's signature:

```swift
    /// Detail column content — banner, palette │ main pane │ chat │ related-pages, drawers —
    /// shared verbatim by both chromes (#1699 slice 1).
    @ViewBuilder
    private func detailColumn(for site: SiteStore.Site) -> some View {
```

- [ ] **Step 3: Add the two chrome builders**

```swift
    /// The legacy SwiftUI chrome — exactly the pre-#1699 structure, now fed by the shared
    /// column builders. Removed in slice 3.
    private func legacyChrome(for site: SiteStore.Site, inspectorPresented: Binding<Bool>) -> some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = ($0 != .detailOnly) }
        )) {
            sidebarColumn(for: site)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            detailColumn(for: site)
        }
        .inspector(isPresented: inspectorPresented) {
            inspectorContent
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
    }

    /// The AppKit shell chrome (#1699 Stage 3 slice 1) — same columns, negotiation-free by
    /// construction; see `SiteShellSplitController`'s doc comment.
    private func shellChrome(for site: SiteStore.Site, inspectorPresented: Binding<Bool>) -> some View {
        SiteShellView(
            sidebarVisible: $sidebarVisible,
            inspectorPresented: inspectorPresented
        ) {
            sidebarColumn(for: site)
        } content: {
            detailColumn(for: site)
        } inspector: {
            inspectorContent
        }
    }
```

- [ ] **Step 4: Branch at the chrome root**

In `siteUI(for:)`, replace the whole `NavigationSplitView … .inspector(…) { … }` run
(original lines 423-533, already gutted by Steps 1-3's extraction) with:

```swift
        Group {
            if SiteShellFlag.isEnabled {
                shellChrome(for: site, inspectorPresented: inspectorPresented)
            } else {
                legacyChrome(for: site, inspectorPresented: inspectorPresented)
            }
        }
        .navigationTitle(model.preview.editingPageTitle ?? site.name)
```

(everything from `.navigationTitle` on — subtitle, document, edited-state bridge,
`toolbarRole`, `.toolbar(id: "site")`, `SiteSearchFieldModifier`, sheets, drop/paste,
overlay, `annotatedAsSite` — continues unchanged on the `Group`.)

- [ ] **Step 5: Full suite + app build**

Run: `swift test --package-path . 2>&1 | tail -3`
Expected: 0 failures.
Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -2`
Expected: `** BUILD SUCCEEDED **`. (If `siteUI` blows the type-checking budget, the fix is
further extraction — e.g. move the `Group` branch into a `chromeCore(for:inspectorPresented:)`
helper — never `AnyView`.)

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(#1699): branch site chrome on SiteShellFlag (slice 1)"
```

---

### Task 6: Windowed gate — 5× harness + sanity pass under the flag

Preconditions: Debug app built from Task 5; `Untitled 4.anglesite` in recents (`Hcard.astro`
+ seeded `profile.json`); `osascript` has Accessibility permission; screen unlocked; no other
agent driving the GUI. The keychain wedge (#1705): flip
`…/Untitled 4.anglesite/Config/invisible-publish-queue.json` `"pending"` to `false` before
the runs and restore the original afterwards (back it up first).

- [ ] **Step 1: Enable the flag and record the baseline**

```bash
defaults write io.dwk.anglesite experimental.appKitShell -bool true
ls -t ~/Library/Logs/DiagnosticReports/Anglesite-*.ips 2>/dev/null | head -3
```

- [ ] **Step 2: Run the 5× #1696 repro harness**

Use the exact harness from `docs/superpowers/plans/2026-08-31-webview-layout-firewall-1699.md`
Task 3 Step 2 (launch → Reopen → wait for `*http*` title → Website ▸ Graph… → search field
`Hcard` → click node `{857, 524}` → click Open File `{1217, 253}` → 12 s liveness watch →
quit), with the flag-check line added at the top of each run:

```bash
defaults read io.dwk.anglesite experimental.appKitShell
```

Expected: `1` before every run; `RUN1..RUN5: ALIVE (canvas mounted)`; no new `.ips` newer
than Step 1's baseline. **Any crash: STOP.** Capture the report, verify whether the
fingerprint is the `SplitViewChildController` class or something new, and report to the
owner before any further change — the design's falsifiability contract applies to the shell
too.

- [ ] **Step 3: Scripted sanity pass (shell run, app left open after run 5)**

With the app open on the site window:

```bash
# Sidebar toggle round-trip via the stock View-menu item (NSSplitViewController answers toggleSidebar:)
osascript -e 'tell application "System Events" to tell process "Anglesite" to click menu item "Hide Sidebar" of menu "View" of menu bar item "View" of menu bar 1'
sleep 2; screencapture -x "$SCRATCH/shell-sidebar-hidden.png"
osascript -e 'tell application "System Events" to tell process "Anglesite" to click menu item "Show Sidebar" of menu "View" of menu bar item "View" of menu bar 1'
# Inspector toggles
osascript -e 'tell application "System Events" to keystroke "i" using {option down, command down}'   # ⌥⌘I
sleep 2
osascript -e 'tell application "System Events" to keystroke "j" using {option down, command down}'   # ⌥⌘J
sleep 2; screencapture -x "$SCRATCH/shell-inspector.png"
# Chat panel
osascript -e 'tell application "System Events" to keystroke "k" using {control down, command down}'  # ⌃⌘K
sleep 2; screencapture -x "$SCRATCH/shell-chat.png"
```

Read each screenshot and confirm: sidebar actually hid/showed, an inspector column opened,
the chat panel appeared, and the window layout is sane (no zero-width columns, no
overlapping panes). App stays alive throughout (`pgrep -x Anglesite`).

- [ ] **Step 4: Clean up and restore**

```bash
defaults delete io.dwk.anglesite experimental.appKitShell
# restore the invisible-publish-queue.json backup
```

- [ ] **Step 5: Record the verdict**

Append the slice-1 gate outcome (date, OS build, 5-run table, sanity findings) to the
design doc's Rollout §Slice 1, commit as
`docs(#1699): record slice 1 gate verdict`, and post the same summary as a comment on #1699.

- [ ] **Step 6: Hand off**

Slice 1 ends here (flag stays default-off; no PR yet unless the owner asks — slices land
per the design's rollout section). Report to the owner with the gate results and the
slice-2 outline.

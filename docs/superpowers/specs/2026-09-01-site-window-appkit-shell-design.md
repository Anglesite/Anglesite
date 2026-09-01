# Site-window AppKit shell (Stage 3 of #1699)

**Date:** 2026-09-01
**Issue:** #1699 (owner decision 2026-09-01: proceed directly to Stage 3)
**Parent spec:** `2026-08-31-wkwebview-split-chrome-crash-design.md` (evidence trail: Stage 0
5/5 on Beta 8, Stage 2 firewall falsified, takeover-swap-alone exonerated, `.inspector()`
presentation concurrent with detail-column changes identified as prime suspect)
**Status:** Draft for owner review

## Goal

Replace `SiteWindow`'s `NavigationSplitView` + `.inspector()` chrome with an app-owned
AppKit `NSSplitViewController` shell, removing SwiftUI's private
`SplitViewChildController`/`NSHostingView.SizeConstraints` negotiation machinery — the
confirmed crash site — from every site window, while preserving every behavioral contract
the current chrome provides (inventoried 2026-09-01; contracts cited below).

Non-goals: `EffectsGalleryView` and `AcknowledgmentsView` keep their `NavigationSplitView`s
(sheet / secondary window, no inspector, no takeover swaps — not in the crash class). The
launcher window, mobile targets, and the inspector *state machine* semantics are untouched.

## Why this fixes the crash (mechanism, not hope)

The crash is a self-sustaining feedback loop: `NSHostingView` publishes new min/max sizes →
`SplitViewChildController` re-lays-out → publishes again, until AppKit's runaway-constraints
guard aborts. Two properties of the shell remove the loop *by construction*:

1. **No negotiation channel.** Columns are `NSHostingController`s with
   `sizingOptions = []` (API presence typechecked against this SDK, 2026-09-01): the hosting
   views publish no min/ideal/max constraints at all. Column sizing is governed solely by
   constant `NSSplitViewItem.minimumThickness`/`maximumThickness` values we set once. The
   private SwiftUI split controller is simply not present.
2. **Owned presentation timing.** Sidebar/inspector collapse–expand become explicit
   `splitViewItem.animator().isCollapsed` mutations the app orders relative to detail-pane
   swaps, instead of `.inspector(isPresented:)` transitions AppKit coalesces on its own
   schedule. The `AppKitConstraintStormMitigation` sleeps at the four split-chrome call
   sites (`clearInspectorThenSwitchPane` ×2, `openFile`'s component branch,
   `focusSearchField`) exist only to keep those framework transactions apart; with the shell
   they are retired (the sheet-sequencing sites — `loadAndStart` ×2, launcher ×2 — stay).

Residual risk is stated honestly: the loop's food was never directly observed (all fixes to
date are falsified inferences), so the shell is validated the same way everything else in
this trail is — the 5× windowed #1696 repro harness — at every slice, not asserted from
theory.

## Architecture

### What stays SwiftUI

The scene graph is untouched: `WindowGroup(for: String.self)` (`AnglesiteApp.swift:326`),
all `Commands` scenes, `.frame(minWidth: 960, minHeight: 600)`, `.windowStyle(.titleBar)`,
`.windowToolbarStyle(.unified)`. `SiteWindow` remains the scene content view; everything
attached at its outer level today survives verbatim because it never enters the shell:

- all 41 window-level `.sheet`s, 2 `.alert`s, 1 `.confirmationDialog`;
- every `focusedSceneValue` export (`focusedValues(for:)`, `SiteWindow.swift:251-283`, plus
  `SiteSearchFieldModifier`'s) — **design rule: no `focusedSceneValue` may ever move inside
  a hosted column**, since each `NSHostingController` is its own view graph and its focus
  exports do not merge into the scene's;
- `WindowEditedStateBridge`, `QuickLookPreviewHost` (its `body`-level placement is
  load-bearing — `SiteWindow.swift:114-131` — and unaffected);
- the inspector state machine: `inspectorShown`/`activeInspector` scene storage, the
  `inspectorPresented` binding with its three guards (`SiteWindow.swift:397-420`),
  `InspectorActivationPolicy`, suppress/suspend flags, and every `SiteWindowModel`
  touchpoint. The shell swaps the presentation *primitive*, not the policy.

### The shell

New directory `Sources/AnglesiteApp/SiteShell/`:

- **`SiteShellSplitController`** (`NSSplitViewController` subclass): three items —
  - sidebar: `NSSplitViewItem(sidebarWithViewController:)` hosting `SiteNavigatorView`
    (min 200 / max 360, matching `SiteWindow.swift:448`; native sidebar material, and the
    stock `SidebarCommands()` menu item keeps working because `NSSplitViewController`
    natively answers `toggleSidebar(_:)` down the responder chain);
  - content: standard item hosting the existing detail `ZStack` (banner, palette │ main │
    chat │ related-pages `HStack`, drawers — all unchanged SwiftUI);
  - inspector: `NSSplitViewItem(inspectorWithViewController:)` hosting `inspectorContent`
    (min 260 / max 420, matching `SiteWindow.swift:532`).
  Every hosting controller sets `sizingOptions = []`. `splitView.autosaveName = "site-shell"`
  provides width persistence (divergence from today, accepted: widths become per-app rather
  than per-scene — `NavigationSplitView`'s per-scene width restoration is not reproducible
  without private state, and cross-window width consistency is defensible Mac behavior).
- **`SiteShellView`** (`NSViewControllerRepresentable`): bridges SwiftUI state into the
  controller. `updateNSViewController` diffs `sidebarVisible` and the `inspectorPresented`
  binding's value into `isCollapsed` (animated); controller callbacks (user drag-collapse,
  `toggleSidebar:`) write back through the same bindings, preserving the write-back guards.
  Column *content* is passed as closures/rootViews once; per-frame updates flow through the
  observable models exactly as today.

### Contract preservation (from the 2026-09-01 inventory)

| Contract | How the shell honors it |
|---|---|
| `@SceneStorage` `siteNavigator.sidebarVisible`, `siteInspector.shown`, `siteInspector.active` | unchanged — they live in `SiteWindow`, outer graph |
| `@SceneStorage` `siteInspector.tab` (`SiteInspectorView.swift:24`), `websiteInspector.tab` (`WebsiteInspectorView.swift:11`) | **must be hoisted** into `SiteWindow` and passed down as `Binding`s — `@SceneStorage` does not resolve inside an `NSHostingController` (no scene context) and would silently stop persisting. Slice 1 task. |
| Environment/scene-dependent APIs inside hosted columns | slice 1 includes an audit of the three hosted subtrees for `@SceneStorage`, `openWindow`/`openURL`/`dismiss` env actions, and `focusedSceneValue` — each found use is hoisted or bridged explicitly before the flag flips |
| Navigator selection → `model.applyNavigatorSelection` (`SiteWindow.swift:449`) | `onChange` moves inside the sidebar's hosted root — it reads the navigator model, not scene state |
| Inspector guards (`suppressNextInspectorWriteBack`, `websiteInspectorSuspended`, #968 transient-nil rule) | unchanged code; the shell's write-back path funnels through the same `inspectorPresented` binding |
| Toolbar: 23 frozen `SiteToolbarItemID`s, `AXID.toolbar(_:)`, unconditional-items rule | slice 1 keeps the SwiftUI `.toolbar(id: "site")` attached to the shell's container (outer graph); slice 2 replaces it with an app-owned `NSToolbar` (below) |
| Search (⇧⌘F, scopes, suggestions, `siteSearchActions`) | slice 1 keeps `SiteSearchFieldModifier` attached outside the shell; its settle-before-focus dance is retired only when the inspector primitive is the shell's (the dismissal it guards becomes an owned transaction) |
| `navigationTitle`/`Subtitle`/`Document` (title, URL subtitle, proxy icon/drag) | slice 1 keeps the SwiftUI modifiers (they are window-level, not split-level); if the unified-toolbar layout regresses under the shell they move to `window.title`/`subtitle`/`representedURL` set by the controller in slice 2 |
| Menu commands reaching `mainPaneMode`, chat/related toggles, `InspectorPanelActions` | untouched — all flow through focused scene values exported from the outer graph |
| Sidebar toggle | native `toggleSidebar:` responder path + the shell adds its own toolbar toggle item in slice 2 (SwiftUI stops auto-inserting one once `NavigationSplitView` is gone) |

### Toolbar (slice 2): owned `NSToolbar`

SwiftUI's `.toolbar(id:)` continues to work over a plain window content view, so slice 1
does not touch it — but two facts make an owned `NSToolbar` the end state: (a) the saved
`"NSToolbar Configuration site"` format embeds SwiftUI-internal identifiers and traps on OS
updates (#1704 — a launch crash this design gets to fix structurally); (b) tracking
separators over the sidebar/inspector dividers (`NSTrackingSeparatorToolbarItem`) require
the toolbar and the split view to know each other, which SwiftUI's toolbar cannot do for a
represented split. Slice 2:

- toolbar delegate generated from `SiteToolbarItemID` (raw values become
  `NSToolbarItem.Identifier`s verbatim — the frozen-id and `AXID.toolbar(_:)` contracts
  carry over; `SiteToolbarItemIDTests` keeps enforcing them);
- `allowsUserCustomization = true`, `autosavesConfiguration = true`, identifier
  **`"site.shell"`** — a fresh defaults key, deliberately abandoning Beta-7-poisoned
  `"NSToolbar Configuration site"` blobs (existing user customizations reset once; accepted
  and release-noted);
- item views are the existing SwiftUI controls in `NSHostingView`s (`sizingOptions` default
  is fine here — toolbar items are not split children); the `insert` menu uses
  `NSMenuToolbarItem`; search becomes `NSSearchToolbarItem` with the same `SiteSearchModel`
  behind a suggestions menu; default-visible set mirrors `isDefaultVisible`;
- `NSTrackingSeparatorToolbarItem`s for both dividers — a strict chrome upgrade over today.

### Rollout: flag-gated slices

The shell lands behind `UserDefaults` key **`experimental.appKitShell`** (env override
`ANGLESITE_APPKIT_SHELL=1` for harness runs); `siteUI(for:)` branches at the chrome root.
The old path remains default until slice 3.

1. **Slice 1 — columns.** `SiteShellSplitController` + `SiteShellView`; hoist the two
   in-column `@SceneStorage` tabs; hosted-subtree audit; SwiftUI toolbar/search/title kept.
   Exit gate: 5× #1696 harness green under the flag, plus a manual sanity pass over sidebar
   toggle, inspector show/hide (⌥⌘I/⌥⌘J), chat/related panels, drawers, and the Component
   Editor open.
2. **Slice 2 — owned toolbar + search + title plumbing.** Exit gate: toolbar customization
   round-trips (palette, reorder, remove, restore-default), AX ids verified via the
   `AXIdentifier` probe, tracking separators behave, ⇧⌘F focuses search.
3. **Slice 3 — flip and retire.** Default the flag on; delete the `NavigationSplitView`
   path, the flag, and mitigation sites 1–3 + 6 (`SiteWindowModel.swift:668`, `:684`,
   `:1659`, `SiteSearchField.swift:86`); update `AppKitConstraintStormMitigation`'s doc to
   its remaining sheet-sequencing scope. Exit gate: the full #679-class keyboard/VoiceOver
   QA pass, the #910 checklist proceeding past Open File, and the 5× harness one last time.
   This closes #1699.

Each slice is a PR against this design; `Closes #1699` rides only on slice 3's.

## Testing

- **Unit (SwiftPM, CI):** shell state-bridging logic — collapse diffing, write-back
  guard interplay — factored into a plain type (`SiteShellState`) testable without a
  window; `NSHostingController.sizingOptions` and thickness constants frozen by test the
  same way `WebViewLayoutFirewallTests` froze its invariants (that pattern is in branch
  history).
- **Windowed (the authority):** the proven AX harness (Stage 0/2 runs, exact scripts in
  `docs/superpowers/plans/2026-08-31-webview-layout-firewall-1699.md` Task 3) — 5×
  crash-free per slice gate, screenshot-verified positive function, crash-report diffing
  against a recorded baseline.
- CI cannot run any of the windowed parts (macOS-27 host requirement — CONTRIBUTING
  "hosted app tests" note); every slice PR's test plan must say which checks ran where.

## Risks and mitigations

- **Focus/commands regressions** (focused scene values, first-responder handoffs around
  WKWebView): outer-graph rule above; slice 1's manual gate exercises every View-menu
  toggle and the Edit ▸ Find paths.
- **Unknown SwiftUI chrome dependencies** surfacing late (e.g. `.searchable` rendering
  differently without a navigation root): flag keeps `main` shippable; discoveries become
  slice-1 fixes, not release blockers.
- **The shell fails to fix the crash** (the loop reappears through some other AppKit path):
  the harness catches it at slice 1's gate, before any user-visible flip; the fallback
  conversation is then Apple-Feedback-and-hold (parent doc Stage 1 / "hold for GM"), with
  the shell shelved behind its flag — not a rewrite of the rewrite.
- **Scope creep into a general chrome redesign:** the shell reproduces today's chrome;
  every intentional divergence is listed here (width persistence granularity, toolbar
  defaults-key reset, tracking-separator upgrade) and nothing else.

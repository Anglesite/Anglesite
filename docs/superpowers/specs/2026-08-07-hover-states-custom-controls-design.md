# Hover states for custom interactive controls

**Date:** 2026-08-07
**Status:** Approved — ready for an implementation plan
**Issue:** [#677 — Hover states for custom interactive controls (launcher rows, graph nodes, wizard cards)](https://github.com/Anglesite/Anglesite/issues/677)

## Problem

Part of the Mac-assed app polish audit against
[pfandrade.me's mac-assed-app checklist](https://pfandrade.me/blog/mac-assed-swiftui-app/) — hover
states are on that article's checklist. Native `List` rows (e.g. `SitesLauncherView`'s site list)
get system hover behavior for free, but the app's custom-drawn interactive surfaces don't: they use
`Button(action:)` with `.buttonStyle(.plain)` and a hand-rolled selected-state background/border,
with no equivalent treatment for hover.

## Scope

Three views, matching the issue's concrete file pointers:

1. **`SiteGraphNodeButton`** — `Sources/AnglesiteApp/SiteGraphExplorerView.swift:304` — the
   clickable node buttons in the Site Graph Explorer canvas.
2. **`ThemePreviewCard`**'s selecting `Button` — `Sources/AnglesiteApp/NewSiteWizard.swift:39` —
   the New Site template chooser grid.
3. **`themeCard`** — `Sources/AnglesiteApp/ThemeApplyWizard.swift:68` — the built-in theme picker
   grid in the Apply Theme wizard.

Out of scope: `SitesLauncherView`'s site `List` rows (native `List` already supplies hover
highlighting), and cursor/pointer-style changes (`NSCursor.pointingHand`) — the issue's Acceptance
section only requires a visible hover wash, there's no existing push/pop cursor pattern in this
codebase to build on safely, and a link-style cursor is not needed for a selection card. Left as a
possible fast-follow rather than bundled here (YAGNI).

## Design

Each of the three views gains:

- `@State private var isHovering = false` + `.onHover { isHovering = $0 }` on the button.
- `@Environment(\.controlActiveState) private var controlActiveState`, matching the existing
  pattern in `SiteWindow.swift`/`MainPaneEditorView.swift`/`PlistEditorView.swift`/
  `PageInspectorView.swift`. The hover wash only applies when `controlActiveState != .inactive`,
  so a hover state left behind when the window resigns key (e.g. Cmd-Tab away mid-hover) doesn't
  paint a ghost highlight in an inactive window.
- `@Environment(\.accessibilityReduceMotion) private var reduceMotion`, matching `SiteWindow.swift`.
  The opacity change is wrapped in `.animation(reduceMotion ? nil : .easeInOut(duration: 0.12),
  value: isHovering)` — instant under Reduce Motion, a quick fade otherwise.

Visual treatment reuses each view's existing selected-state language rather than introducing a new
one — a hover tier slotted between the existing "at rest" and "selected" opacities:

- **`SiteGraphNodeButton`**: background opacity goes from `selected ? 0.24 : related ? 0.16 : 0.1`
  to include a hovering-but-not-selected tier (e.g. `0.16`, matching `related`'s existing wash so
  hover reads as "about to be related" without competing with true selection); border opacity gets
  a small bump the same way.
- **`ThemePreviewCard`** (`NewSiteWizard.swift`) and **`themeCard`** (`ThemeApplyWizard.swift`):
  both already use `Color.accentColor.opacity(...)` for the selected background/stroke wash. Hover
  adds a lighter accent-colored wash at roughly half the selected opacity, only when not already
  selected (a selected card shouldn't visually change on hover).

No new files, no new dependencies, no MCP/schema changes — this is an app-only SwiftUI change
confined to the three view files above.

## Testing

This is pure SwiftUI view state with no unit-testable logic (hover is driven by AppKit mouse
tracking that `swift test` can't exercise). Verification is:

- `swift test --package-path .` and `scripts/build-app.sh` stay green (no regressions elsewhere).
- Manual verification: run the app, hover a graph node and both wizard cards, confirm a visible
  wash appears before click, in both light and dark appearance, and that it doesn't animate when
  Reduce Motion is on (System Settings ▸ Accessibility).

## Acceptance (from the issue)

- Hovering a graph node and a theme card gives visible feedback before click.
- No hover artifacts in inactive windows (feedback is suppressed when the window isn't key).

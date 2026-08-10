# iOS multi-site switcher polish — design

**Date:** 2026-08-10
**Issue:** #71 follow-up ("multi-site UX," tracked in the issue's 2026-07-22 comment). Builds on
`SitePickerModel` (#866), `MicropubOnboardingModel` (#868), and `SiteSplitScreen` (#869).
**Status:** Approved design; ready for implementation planning.

## Scope

By the time this design was written, "multi-site UX" already had substantial coverage that
predates this slice: `SitePickerModel` discovers every `.anglesite` package in the user's iCloud
container, `SiteSplitScreen`'s sidebar lets you switch between them, and each site gets its own
IndieAuth token, DPoP key pair, Micropub session, and drafts, all keyed by `siteID`. That base
implementation is not revisited here.

What's missing is UX polish around that existing switching mechanism, found by reading the current
`SiteSplitScreen`/`PostListScreen`/`ComposeScreen` code rather than assumed:

1. **No site-name context** in the post-list or composer navigation titles. On iPad the sidebar
   stays visible so the selected site is never really ambiguous, but on iPhone (`NavigationSplitView`
   collapses to a plain `NavigationStack`) you can be several screens deep in a post list or
   composer with nothing on screen naming which site you're editing.
2. **No remembered site across launches.** `selectedSite` is a bare `@State` in `SiteSplitScreen`,
   so every cold launch lands back on "pick a site" even if you posted to the same site five
   minutes ago.
3. **No fast way to switch sites on iPhone** short of navigating back to the sidebar screen.

This is app-side only — no changes to `AnglesiteCore`'s Micropub/IndieAuth machinery, no MCP schema
changes, no paired sidecar PR.

## Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Persisted-site-not-found fallback | Silently fall back to no selection | Not a real error — matches today's cold-launch behavior; owner call during brainstorming |
| Switcher UI pattern | Toolbar button (site name + chevron) opening a `Menu` | Owner preference over a pull-down-title pattern; works identically from the post list or the composer |
| Switcher visibility | Hidden entirely below 2 sites | A switcher for one site is noise, not signal |
| Selection-persistence ownership | New dedicated `SiteSelectionModel`, not inline in `SiteSplitScreen` and not bolted onto `SitePickerModel` | Matches this codebase's strict convention that every stateful concern is a unit-testable `@Observable` model behind a plain view; `SitePickerModel` is also used standalone by `SitePickerScreen`, which has no selection concept, so adding it there would blur that model's one job |

## Components

### 1. `SiteSelectionModel` (`AnglesiteIOS`, new)

`@MainActor @Observable`, same shape as `SitePickerModel`/`RemoteSessionModel`:

```swift
@MainActor
@Observable
public final class SiteSelectionModel {
    public private(set) var selectedSite: SitePickerModel.DiscoveredSite?

    public init(defaults: UserDefaults = .standard)

    /// User-driven selection (sidebar row, switcher menu). Always wins immediately and persists.
    public func select(_ site: SitePickerModel.DiscoveredSite?)

    /// Called once discovery produces a list. Looks up the persisted site ID in `sites`; selects
    /// it if found. Never overwrites an already-active `selectedSite` (a user tapping around
    /// before discovery/restore settles must not be clobbered by a late restore).
    public func restoreSelection(from sites: [SitePickerModel.DiscoveredSite])
}
```

- `select(_:)` persists `site?.id.uuidString` to `UserDefaults` (or removes the key for `nil`) via
  the same `didSet`-on-assignment idiom `RemoteSessionModel` uses, then updates `selectedSite`.
- `restoreSelection(from:)` is a no-op if `selectedSite != nil` or no persisted ID exists or the
  persisted ID isn't in `sites` — in every one of those cases the screen's existing empty/picker
  state is exactly right already, so there is nothing else for it to do.
- Injectable `UserDefaults` in `init`, matching `RemoteSessionModel`'s pattern, so tests don't touch
  real defaults.

### 2. `SiteSplitScreen` changes (`AnglesiteMobile`)

- Replaces `@State private var selectedSite: SitePickerModel.DiscoveredSite?` with
  `@State private var siteSelection = SiteSelectionModel()`; every existing read of `selectedSite`
  becomes `siteSelection.selectedSite`.
- The sidebar's `sidebarSelection` binding's `.site(let id)` case and the new switcher menu's tap
  handler both route through one new private helper, `selectSite(_:)`, which calls
  `siteSelection.select(site)` and resets `selectedTypeID`/`selection` — the existing
  reset-on-switch side effect, now defined once instead of duplicated between two call sites.
- A new `.task(id: sitePicker.state)`-driven call (or equivalent — reacting to `sitePicker.state`
  transitioning into `.sites(...)`) invokes `siteSelection.restoreSelection(from: sites)`. Existing
  `.task(id: siteSelection.selectedSite?.id)` (session resolution) is unchanged; a successful
  restore drives it exactly like a manual tap does.
- Both `contentPane` and `detailPane` gain a `ToolbarItem(placement: .navigation)` holding
  `SiteSwitcherMenu`, populated only when `sitePicker.state` is `.sites` with 2+ entries.

### 3. `SiteSwitcherMenu` (`AnglesiteMobile`, new)

```swift
struct SiteSwitcherMenu: View {
    let sites: [SitePickerModel.DiscoveredSite]
    let selected: SitePickerModel.DiscoveredSite?
    var onSelect: (SitePickerModel.DiscoveredSite) -> Void

    var body: some View {
        Menu {
            ForEach(sites) { site in
                Button {
                    onSelect(site)
                } label: {
                    if site == selected {
                        Label(site.displayName, systemImage: "checkmark")
                    } else {
                        Text(verbatim: site.displayName)
                    }
                }
            }
        } label: {
            Label(selected?.displayName ?? "", systemImage: "chevron.down")
                .labelStyle(.titleAndIcon)
        }
    }
}
```

Pure view, no model of its own — `SiteSplitScreen` owns all state and passes it down, same
convention as `ComposerPane`.

## Data flow

1. **Cold launch:** `sitePicker.refresh()` (existing) → `.sites(sites)` → `restoreSelection(from:
   sites)` → if a persisted site ID matches, `siteSelection.selectedSite` is set → existing
   `.task(id: siteSelection.selectedSite?.id)` resolves that site's Micropub session, landing
   directly on its post list instead of the picker.
2. **Manual switch (sidebar or menu):** tap → `selectSite(_:)` → `siteSelection.select(site)` →
   persists + updates `selectedSite` → same session-resolution task re-runs.
3. **Persisted site missing:** `restoreSelection` finds no match → `selectedSite` stays `nil` →
   today's existing "Pick a Site" content-pane empty state renders, unchanged.

## Error handling & edge cases

- Persisted site no longer discoverable (deleted, package moved, iCloud not yet synced): silent
  fallback to no selection, per the locked decision above — this is not a failure state and gets no
  new UI.
- Exactly 0 or 1 discovered sites: `SiteSwitcherMenu` is omitted from the toolbar entirely (checked
  where it's constructed in `SiteSplitScreen`, not inside the view itself, so there's no
  disabled/greyed-out state to design for).
- A restore racing a manual tap (e.g., discovery resolves just as the user taps a different site in
  the sidebar): `restoreSelection`'s "never overwrite an already-active selection" rule means
  whichever happens last only matters if `selectedSite` was still `nil` beforehand — a manual tap
  always wins once it lands, since it happens synchronously against `@State`.

## Testing

- `SiteSelectionModelTests` (new, Swift Testing, `Tests/AnglesiteIOSTests/`):
  - `select` persists the ID and updates `selectedSite`; `select(nil)` clears the persisted key.
  - `restoreSelection` selects the persisted site when present in the given list.
  - `restoreSelection` leaves `selectedSite` as `nil` when the persisted ID isn't in the list.
  - `restoreSelection` is a no-op when `selectedSite` is already set (doesn't get overwritten by a
    stale persisted value).
  - All against an injected `UserDefaults(suiteName:)` instance, never `.standard`.
- No new tests for `SiteSwitcherMenu` or the `SiteSplitScreen` wiring itself — consistent with this
  codebase's existing practice of not unit-testing SwiftUI view bodies. Verified instead by building
  the `AnglesiteMobile` scheme and a manual simulator smoke: site name appears in post-list/composer
  toolbars, switcher menu changes site and refreshes the post list, relaunching the app after
  picking a site lands directly on that site's post list, switcher is absent with only one
  discovered site.

## Open items (verify during implementation; non-blocking)

- Exact SwiftUI mechanism for reacting to `sitePicker.state` becoming `.sites(...)` to call
  `restoreSelection` — `.onChange(of:)` vs. folding it into the existing `.task`. Either is
  consistent with the design; pick whichever reads cleaner once the code is in front of you.
- `SiteSwitcherMenu`'s exact toolbar placement (`.navigation` vs. `.topBarLeading` vs.
  `.principal`) should be settled by how it actually renders next to the existing `newPostButton`
  and `ComposeScreen`'s `ToolbarItemGroup(placement: .primaryAction)` — verify visually in the
  simulator rather than guessing from the API alone.

## Epic touchpoints

- **#71 iOS thin client** — closes out the "multi-site UX" line from the issue's 2026-07-22 comment.
- **#866 / #868 / #869** — the discovery, auth, and split-shell foundation this polish sits on top
  of; no changes to any of their models beyond `SiteSplitScreen`'s own state ownership.

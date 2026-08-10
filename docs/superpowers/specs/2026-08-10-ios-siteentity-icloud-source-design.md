# iOS `SiteEntity` source: bind to iCloud package discovery — design

**Date:** 2026-08-10
**Issue:** Part of #71. Follow-up to #1386 (iOS UIKit Siri-annotation provider) — surfaced by that
PR's final whole-branch review: linking `AnglesiteIntents` into `AnglesiteMobile` exposes
`AnglesiteShortcuts` and ~28 `AppIntent` conformances to iOS Siri/Shortcuts with no
`bootstrap(contentGraph:)` call behind them, and (independent of that) most of those intents are
additionally blocked because `SiteEntity`/`SiteEntityQuery` is hardwired to the macOS-only
`SiteStore.shared`. This design covers the first, foundational sub-project of fixing that: giving
`SiteEntity` a real iOS-appropriate source. Not yet filed as its own issue — will be filed
alongside the implementation plan.
**Status:** Approved design; ready for implementation planning.

## Scope

An investigation (`Explore` agent pass, 2026-08-10) mapped every `AppIntent`/`AppShortcutsProvider`
in `Sources/AnglesiteIntents/` against what would be needed to make it iOS-safe. It found the work
splits into independent pieces:

- **A (this design):** an iOS-appropriate source for `SiteEntity` resolution. Foundational — 18 of
  24 intents are `SiteEntity`-parameterized and currently resolve against an always-empty
  `SiteStore.shared` on iOS.
- **B:** an iOS-capable `ContentOperationsService` conformance (Add Page / Add Post).
- **C:** an iOS-capable `IntegrationOperationsService` conformance (Booking / Donations / Giscus /
  Store).
- **D:** wiring `EditContentIntent` to iOS's existing `MCPApplyEditRouter` instead of the
  macOS-only `EditRouterRegistry`.
- **E:** platform-gating the intents that can never run on iOS regardless of A-D — `DeploySiteIntent`
  /`BackupSiteIntent`/`AuditSiteIntent` (`ProcessSupervisor` subprocess spawning), `OpenSiteIntent`/
  `PreviewSiteIntent`/`StartDesignInterviewIntent` (`WindowRouter`, a macOS multi-window
  assumption), and `ReviewCopyIntent`/`PlanSocialMediaIntent`/`RepurposePostIntent` (which, unlike
  the rest, have no `@Dependency` seam at all — see Open Items).

Each is its own spec → plan → implementation cycle. **This design covers A only.** B, C, D, and E
are out of scope here and untouched by this work; #1386's own PR is not blocked on this landing.

## Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Site source | Bind to the same iCloud `.anglesite` package discovery `SitePickerModel` already uses in production | It's the app's real, shipping, populated site list (per #800's 2026-07-17 owner decision, the iCloud+Micropub flow is iOS's *default* experience — not the dormant `RemoteSessionModel`/`SiteStore` path). Reusing it avoids inventing a second site concept. |
| Query implementation | New `#if os(iOS)` `SiteEntityQuery` conformance, parallel to the existing `#if os(macOS)`-implied one (today unguarded, since it's the only one) | `SiteEntityQuery` is `EntityStringQuery`-conforming with a no-argument `init()` AppIntents requires — a single implementation can't serve two backing stores. A platform-gated second conformance matches this codebase's established pattern (e.g. the two `PreviewAnnotationProviderUIElements*` platform halves before #1386's fix wave merged them into one file). |
| Discovery primitives | Reuse `UbiquityContainerResolving` (`AnglesiteCore`) and `UbiquitousPackageDiscovering`/`NSMetadataQueryPackageDiscovery` (`AnglesiteIOS`) directly — not `SitePickerModel` itself | `SitePickerModel` is `@MainActor @Observable` with UI-shaped state (`.loading`/`.iCloudUnavailable`/`.empty`/`.sites`), not an `async throws` query interface, and AppIntents execution isn't guaranteed to share the running app's view-model instance. The lower-level protocols are already designed as injectable, non-UI-bound seams. |
| `SiteStore` itself | Left untouched | `SiteStore` carries macOS-specific bookmark/security-scope semantics throughout (`SiteAccess.withScopedAccess`). Teaching it a second, unrelated storage substrate risks scope creep and macOS regressions for a purely iOS-side need. |
| Cross-target dependency | `AnglesiteIntents` gains a `.when(platforms: [.iOS])`-conditioned dependency on `AnglesiteIOS` in `Package.swift`, rather than moving `UbiquitousPackageDiscovering`/`NSMetadataQueryPackageDiscovery` to `AnglesiteCore` | Standard SwiftPM API (`Target.Dependency.product(name:package:condition:)`) — this exact file already uses `.when(platforms:)` conditions on linker settings (e.g. the `weakLinkFoundationModels`/`webRTCTestRPath` arrays near the top), just not yet on a dependency edge, so the mechanism is proven in-repo even though this particular use is new. No file relocation needed, and `AnglesiteIOS` has no dependency back on `AnglesiteIntents` (confirmed by grep), so this doesn't create a cycle. |

## Components

### 1. `SiteEntityQueryIOS` (`Sources/AnglesiteIntents/SiteEntityQueryIOS.swift`, new, `#if os(iOS)`)

Same four `EntityStringQuery` methods as the existing (implicitly-macOS) `SiteEntityQuery`, all
funneling through one `allSites() async -> [SiteEntity]` helper:

1. Resolve the ubiquity container via `UbiquityContainerResolving.url(forUbiquityContainerIdentifier:)`
   (using `AppSettings.ubiquityContainerIdentifier`, matching `SitePickerModel.refresh()`) — `nil`
   → return `[]` from every method (see Error Handling).
2. `UbiquitousPackageDiscovering.discoverPackages()` → `[URL]`.
3. For each `URL`: `AnglesitePackage(url:).readMarker(fileManager:)` → on success, build a
   `SiteEntity` (`id: marker.siteID.uuidString`, `name: marker.displayName`, `directory: url`,
   `creationDate`/`modificationDate` read off `AnglesitePackage(url:).sourceURL`'s resource values,
   same keys `SiteEntity.init(_ site: SiteStore.Site)` already reads). On failure, drop the entry
   (`compactMap` + `try?`, matching `SitePickerModel.refresh()`).

`entities(for identifiers:)` filters `allSites()` by id (no id-indexed lookup exists in the
discovery API — full list + filter, same shape the existing macOS query already uses).
`entities(matching:)` is a case-insensitive substring match on `name`. `suggestedEntities()` returns
everything. `defaultResult()` returns the single site when there is exactly one, `nil` otherwise —
identical semantics to the macOS query, just a different backing store.

### 2. `Package.swift` dependency edge

`AnglesiteIntents`'s target dependencies gain:
```swift
.target(
    name: "AnglesiteCore",
    ...
),
.product(name: "AnglesiteIOS", package: "Anglesite", condition: .when(platforms: [.iOS])),
```
(exact syntax to match whatever form the existing `.when(platforms: [.macOS])` edges already use
in this file).

### 3. `SiteEntity.defaultQuery`

Currently `public static let defaultQuery = SiteEntityQuery()` unconditionally. Becomes
`#if os(macOS) SiteEntityQuery() #elseif os(iOS) SiteEntityQueryIOS() #endif` (or equivalent) — the
one call site both platform implementations plug into.

## Data flow

Siri/Shortcuts asks the system to resolve or disambiguate a `SiteEntity` → `AppIntents` calls
`SiteEntity.defaultQuery` → on iOS, `SiteEntityQueryIOS` → ubiquity container check → package
discovery → per-package marker read → `SiteEntity` values, `directory` pointing at the real
iCloud-materialized `.anglesite` package root (exactly what `SiteEntity.directory`'s existing doc
comment already expects: "the package root... NOT the `Source/` git repo").

## Error handling & edge cases

- **iCloud unavailable:** empty result set from every query method. `EntityQuery` has no slot for
  "iCloud is broken" vs. "genuinely no sites yet" — Siri's built-in "no matches" phrasing covers
  both. (`SitePickerScreen`'s dedicated `.iCloudUnavailable` UI state is UI-only; this query
  doesn't replicate it.)
- **A package whose marker fails to read** (mid-materializing iCloud item, corrupt `Info.plist`):
  dropped from the list, never thrown — matches `SitePickerModel.refresh()`'s existing behavior
  exactly.
- **Two sites with the same display name:** unaffected — `SiteEntity.displayRepresentation` already
  disambiguates with the package path as subtitle, and `id` (the marker's stable UUID) is what
  actually matters for resolution.

## Testing

- `SiteEntityQueryIOSTests` (new, `Tests/AnglesiteIntentsTests/`), `swift test`-only (no
  `xcodebuild`/simulator needed — matches how the macOS `SiteEntityQuery` is tested today). Inject
  fake `UbiquityContainerResolving`/`UbiquitousPackageDiscovering` implementations. Covers:
  container unavailable → empty; empty discovery → empty; a marker-read failure → dropped, not
  thrown; multiple sites → all returned; `entities(for:)` exact-id match; `entities(matching:)`
  substring match (case-insensitive); `defaultResult()` non-nil only when exactly one site exists.
- **Not covered by automated tests** (flagged, not silently skipped): live `NSMetadataQuery`
  behavior against a real iCloud container — the same limitation `SitePickerModel` itself already
  carries (no existing test exercises real iCloud I/O either).

## Open items (verify during implementation; non-blocking)

- Whether `ReviewCopyIntent`/`PlanSocialMediaIntent`/`RepurposePostIntent` — which read/write the
  local filesystem directly via `site.directory`/`AnglesitePackage` with **no** `@Dependency` seam
  at all — become usable on iOS "for free" once `SiteEntity.directory` points at a real,
  iCloud-materialized package (since iOS apparently has genuine local file access to these
  packages, unlike the original investigation's assumption that all filesystem-writing intents are
  macOS-only substrate). This is worth checking after A lands, but is explicitly **not** part of A
  itself, and not a blocker for A's own scope (A only fixes entity *resolution*, not what any
  intent's `perform()` then does with the resolved site).
- Whether `AnglesiteMobile`'s current entitlements/sandbox already grant the read (and, later,
  write) access these intents would need against iCloud-discovered packages, or whether that needs
  its own verification pass — `SitePickerModel`'s existing discovery only reads (`readMarker`), it
  never writes.

## Epic touchpoints

- **#71 iOS thin client** — indirect: this fixes a gap surfaced by #1386, itself a #71 follow-up.
- **#1386 iOS UIKit Siri-annotation provider** — the PR that surfaced this gap; not blocked on this
  design landing (its own scope, the annotation-resolution path, only ever touched
  `PreviewAnnotationProvider`/`PreviewAnnotationProviderRegistry`, not `SiteEntity`).
- **#800** — the 2026-07-17 owner decision that iCloud discovery + Micropub, not the remote-sandbox
  thin client, is iOS's default experience; this design is a direct consequence of that decision
  now reaching into the AppIntents surface.
- **Sub-projects B, C, D, E** (§Scope) — each is separately spec'd once this lands.

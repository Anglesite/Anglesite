# Semantic Accessibility Audit (SwiftUI)

**Issue:** [#1096](https://github.com/Anglesite/Anglesite/issues/1096)
**Date:** 2026-08-16
**Checklist source:** [Semantic Accessibility in SwiftUI](https://wesleydegroot.nl/blog/semantic-accessibility-in-swiftui) (Wesley de Groot, 28 Jul 2026)
**Scope decision (owner, 2026-08-15):** audit-first — this document is the deliverable for #1096. Fixes are **not** applied here; they land as scoped follow-up issues per the "Recommended follow-ups" section below, not as one sweep PR.

## Why this audit exists

#1096 asked for a check of the app's SwiftUI surface against semantic-accessibility best
practice — explicit labels, hints, values, element grouping, hidden decoratives, custom
actions, traits, and reading order — beyond what SwiftUI infers automatically. The original
ask named no specific views, so the owner scoped it to an audit report first: find where the
pattern already exists and works, find where it's missing, and let the findings drive
right-sized follow-up issues instead of one large sweep PR touching dozens of files at once.

## Scope

Audited: all 84 SwiftUI `View`-conforming types in `Sources/AnglesiteApp/` — the primary
macOS app target (`grep -rl "View {" Sources/AnglesiteApp | xargs grep -l ": View\b"`).
Files that import SwiftUI only for `ObservableObject`/`@Bindable` model state (no `View`
body) were excluded; they carry no UI to audit.

**Not covered by this pass** — flagged as separate scope, not folded into the findings below:

- `Sources/AnglesiteMobile/` (10 SwiftUI files) and `Sources/AnglesiteIOS/` (5 SwiftUI files)
  — early-stage cross-platform targets (see `docs/ios-ipados-assed-app-spec.md`), not yet the
  shipping surface. A future iOS/iPadOS accessibility pass should audit these against the
  same checklist plus the mobile-specific spec (Dynamic Type at large sizes, VoiceOver rotor
  on touch, Larger Text layout).
- `Sources/AnglesiteCore/` (2 SwiftUI files) — thin shared view helpers with negligible
  surface; not a meaningful audit target on their own.
- Dynamic Type sizing, color contrast, and Reduce Motion — real accessibility axes, but
  outside the linked article's semantic-labeling checklist and #1096's scope as decided.

## Method

The 84 files were split into six feature-area groups (component/content editor, site
navigation & window chrome, wizards & onboarding, domain/deploy/sync sheets,
auth/integrations/settings, status/badge/report views) and each audited independently
against the article's eight checklist items, reading full file bodies rather than
grepping for modifier names (a grep for `.accessibilityLabel` finds adoption but not
*absence*, which is most of what an audit like this needs to surface).

## Checklist source (verbatim, for reference)

1. **Accessibility Labels** — icon-only controls/images need explicit `.accessibilityLabel`; SwiftUI infers labels from visible text, not from SF Symbol images alone.
2. **Accessibility Hints** — `.accessibilityHint` describes the outcome of activating a control, only when it isn't obvious from the label.
3. **Accessibility Values** — custom controls conveying state (not native `Slider`/`Toggle`) need explicit `.accessibilityValue`.
4. **Grouping Elements** — `.accessibilityElement(children: .combine/.ignore)` so compound rows read as one VoiceOver stop instead of several.
5. **Hiding Decorative Elements** — `.accessibilityHidden(true)` on images/dividers that add no information beyond adjacent text.
6. **Custom Actions** — `.accessibilityAction(named:)` instead of cramming several small buttons into one row.
7. **Traits** — `.accessibilityAddTraits(...)` for `.isHeader`, `.updatesFrequently`, `.isSelected`, `.isButton` where SwiftUI can't infer the role.
8. **Sorting Order** — `.accessibilitySortPriority` to fix VoiceOver reading order when it doesn't match visual/logical order.

## Findings against the checklist

### 1. Accessibility Labels — PARTIAL

Text-labeled buttons and `Label("text", systemImage:)` (even under `.labelStyle(.iconOnly)`)
correctly inherit an accessible name throughout the app — this is the majority case and
needs no action. The gap is narrower but recurs: **bare `Image(systemName:)` glyphs used as
the entire content of a `Button`, with only a `.help()` tooltip**, which VoiceOver reads as
the raw SF Symbol name instead of the action.

- `ComponentMetadataInspectorPane.swift:47-53,103-108`, `ComponentStyleInspectorPane.swift:123-128`,
  `TypedEntryEditorView.swift:113-116,179-183`, `PlistEditorView.swift:465-472` — six near-identical
  "remove row" `minus.circle`/trash glyph buttons across the component/typed-entry editors.
- `RelatedPagesPanel.swift:112-119,121-126` — copy-link/dismiss icon buttons, `.help()` only.
- `DomainSheetView.swift:220-224,234-238,254-259` — dismiss and delete-record icon buttons.
- `ChatView.swift:84` (`ellipsis.circle` options menu), `RepurposeView.swift:67` (`ShareLink` icon).
- `ComponentStyleInspectorPane.swift:173-186` — `ColorPicker("", …).labelsHidden()` never states which CSS property it edits.

Good exemplars already in the codebase (worth pointing follow-up work at directly rather than
inventing a new pattern): `PlistEditorView.swift:116-128` replaces an icon-only tab bar with
`.accessibilityRepresentation { Picker(...) }`; `CommunitiesView.swift:109-119` and
`DevicePairingSettingsView.swift:35` label a search glyph and a QR image respectively, citing
the mac accessibility spec in a comment; `CitationRowView.swift:75` labels an icon+text chip.

### 2. Accessibility Hints — PASS

No gaps found. Where hints exist they're used correctly — short, verb-led, conditional on
whether the outcome is already obvious: `SyncStatusView.swift:29-31` (state-dependent hint,
"Opens the sync conflict resolution sheet" vs. "Shows this site's iCloud sync status"),
`ChatView.swift:307-310` (empty when enabled, explains why when disabled),
`SiteGraphExplorerView.swift:299`, `StartupProgressView.swift:33`. No control was found
crying out for a hint it lacks — the app mostly relies on labels alone, which the article
treats as correct when the outcome is self-evident.

### 3. Accessibility Values — PARTIAL, but the good examples are strong

Native `Slider`/`Toggle`/`ProgressView` usage is fine by construction. The gap is
hand-rolled stateful widgets:

- `DeployDrawerView.swift:129-139` — `PhaseProgressStrip`, a custom multi-step deploy
  progress indicator, gets `.accessibilityLabel("Deploying")` but no `.accessibilityValue`
  conveying which phase or how far along; a VoiceOver user can't tell "just started" from
  "nearly done."
- `PhaseProgressStrip.swift:52-54` — progress state is folded into the label text rather
  than split into label+value; works today, not idiomatic.
- `DesignInterviewPanel.swift:93-102` — five bipolar axis `Slider`s ("Cool"↔"Warm" etc.)
  have no `.accessibilityLabel` at all; the axis identity lives only in adjacent, unwired
  `Text` captions, so VoiceOver announces a bare percentage with no indication of which axis.

Exemplary patterns already shipped and worth reusing verbatim: `SyncStatusView.swift:16-34`
(status dot as a `Button` with `.accessibilityLabel` + `.accessibilityValue` +
state-dependent `.accessibilityHint`, plus `.accessibilityDifferentiateWithoutColor` handling
via SF Symbol swap); `SettingsView.swift:626-631` (`KeychainTokenRow` — redacted
`SecureField` gets a `.accessibilityValue` describing sign-in state instead of the
meaningless redacted text); `HealthBadgeView.swift:39-40` /
`SecurityReportsBadgeView.swift:31-32,151-164` (color-coded status dots — the textbook
"state conveyed by color alone" risk — already pair color with a spoken label/value and
never rely on color as the only signal); `NewSiteWizard.swift:200-213`
(`ThemeChooserCard` — combine + label + `.accessibilityValue("Selected"/"")`).

### 4. Grouping Elements — the most common, most systemic gap

By far the largest and most repetitive finding across every chunk: a hand-built
`HStack`/`VStack` compound row (icon + title + subtitle, or status icon + title/subtitle
header) with no `.accessibilityElement(children: .combine)`, so VoiceOver stops on each
subview individually instead of reading the row as one unit.

The clearest instance of this is a **single duplicated shape** — `statusIcon` +
`VStack(title, subtitle)` as a sheet header — copy-pasted (not shared as a component) across
at least eight files: `DomainSheetView.swift:22-49`, `DomainConfigAuditSheetView.swift:26-60`,
`OnionRoutingSheetView.swift:168-197`, `BackupDrawerView.swift:28-66`,
`AuditSheetView.swift:31-44`, `HardenSheetView.swift:21-55`,
`AgentReadinessSheetView.swift:21-51`, `AISearchSheetView.swift:22-50`. None group the header;
none hide the redundant status glyph (see §5). Because the shape is duplicated rather than
shared, fixing it means editing eight call sites the same way — a good candidate to first
extract into one shared header view, then fix accessibility once.

Compound *row* (not header) instances of the same gap: `ComponentEditorOutlinePane.swift:27-38`,
`RelatedPagesPanel.swift:99-107`, `SiteGraphExplorerView.swift:123-151`,
`SiteSearchField.swift:100-124`, `DebugPaneView.swift:139-173`, `FollowersView.swift:115-129`,
`CommunitiesView.swift:150-158`, and finding rows in `AuditSheetView.swift:185-208`,
`HardenSheetView.swift:180-193,258-273`, `AgentReadinessSheetView.swift:145-161`.

Good exemplars, all reachable today: `SiteNavigatorView.swift:116` and
`SiteGraphExplorerView.swift:471-473,529-531` use `Label { } icon: { }` or
`.accessibilityElement(children: .contain)`; `PlistEditorView.swift:813-848`
(`advisoryRow`/`alertRow`) hides the severity glyph and folds severity into one spoken
label; `DeployDrawerView.swift:194-211` and `AcknowledgmentsView.swift:21-30` correctly
combine a multi-`Text` `VStack` into one element.

### 5. Hiding Decorative Elements — PARTIAL, inconsistent by file "age"

Several files get this right consistently and are worth naming as the house pattern:
`ConnectDomainSheetView.swift:24-28`, `BuyDomainSheetView.swift:33-37`,
`DomainConfigDriftSheetView.swift:41-45,62-65`, `BlockedDeploySheetView.swift:48-52`,
`SiteNavigatorView.swift:57,72`, `SiteSearchField.swift:103`, `DebugPaneView.swift:144`,
`DeployDrawerView.swift:129-152` (deliberately hides static icons, keeps the one that's
actually informative), `FollowerAvatar` in `FollowersView.swift:187-210` (avatar hidden with
a comment explaining the row's text already carries the information — the clearest exemplar
found in the whole audit), and `PlistEditorView.swift:813,821,842,848`.

The gap is the same duplicated header shape flagged in §4 — its `statusIcon` is redundant
with the adjacent title text but isn't hidden, at all eight sites listed there — plus a
handful of one-off misses: `ComponentEditBannerViews.swift:15,41`,
`ComponentEditorView.swift:132`, `IntegrationWizard.swift:29-45`,
`SettingsView.swift:664-673` (`KeychainTokenRow.connectedLabel`, inconsistent with
`FollowerAvatar`'s treatment of the same avatar-next-to-text shape),
`MicropubSiteConnectSheet.swift:184-189`, `EmailSetupSheetView.swift:43-55`.

### 6. Custom Actions — PASS, no material gap found

No row in the audited surface crams enough small buttons to warrant
`.accessibilityAction(named:)` over separate `Button`s. The one borderline case
(`CopyEditReportView.swift:101-110`'s three per-finding buttons) was judged reasonable as
separate, independently-enabled actions rather than a grouping candidate. `RelatedPagesPanel.swift:99-129`
is the closest thing to a real instance (copy + dismiss on one row) but is minor.

### 7. Traits — systemic gap, same shape as §4

**Section/dialog headers implemented as plain styled `Text`** (`.font(.headline)` or
similar) carry no `.accessibilityAddTraits(.isHeader)`, unlike native `Section("...")`
headers elsewhere in the app which get this for free. This traces to one shared component:
`SettingsBox.swift:20` renders `title.font(.headline)` with no header trait, and that
propagates silently to every call site — four in `ContentLicensingTab.swift:67-70` alone,
plus the same pattern hand-rolled (not via `SettingsBox`) in `RelatedPagesPanel.swift:53-55,66-68`,
`SiteGraphExplorerView.swift:42,80`, `SitesLauncherView.swift:203`, `DebugPaneView.swift:124`,
seven wizard/sheet titles across `NewSiteWizard.swift`, `NewCommunityWizard.swift`,
`BrandVoiceInterviewView.swift`, `DesignInterviewPanel.swift`, `IntegrationWizard.swift`, and
five more in `DomainConfigAuditSheetView.swift`, `BlockedDeploySheetView.swift`,
`AuditSheetView.swift`, `HardenSheetView.swift`, `AgentReadinessSheetView.swift`. This is the
single largest count of individual findings in the audit, but structurally it's one fix
(`SettingsBox` plus a small number of hand-rolled call sites) rather than dozens of
independent ones.

Custom selection state is inconsistently exposed on hand-built selectable controls — via two
different, non-interchangeable mechanisms, both legitimate: `LicenseGateSheetView.swift:169-195`
uses `.accessibilityAddTraits(.isSelected)` (the `.isSelected` trait); `NewSiteWizard.swift:200-213`
(`ThemeChooserCard`) instead uses `.accessibilityValue("Selected"/"")` (a value, not a trait) —
both are correct, checklist-consistent ways to convey selection, just not the same one.
The structurally-identical `ThemeApplyWizard.swift:123-174` (`ThemeApplyCard`) — same
selectable-theme-card idiom, same `isSelected` bool already in scope — has **no accessibility
modifiers at all** (no combine, label, value, or trait), not merely a missing selection
indicator: a VoiceOver user gets nothing usable from that card, let alone which theme is
selected, even though its sibling wizard handles the identical case correctly.
`SiteGraphExplorerView.swift:304-359` (`SiteGraphNodeButton`) and
`ComponentEditorCanvasPane.swift:44-54` (viewport preset buttons acting as a segmented
selector) have the missing-selection-indicator version of this gap (they do have a label,
just no selection signal).

Live-updating status text (the `.updatesFrequently` case) is handled two ways: correctly
via a purpose-built `LiveRegionAnnouncer` + `AccessibilityNotification.Announcement` in
`ChatView.swift:128-144` and `DeployDrawerView.swift:249-268` (announces state transitions,
arguably better than `.updatesFrequently` since it avoids per-token noise); not handled at
all in `StartupProgressView.swift:24-28`, whose message `Text` re-renders on every startup
phase change with no trait or live-region equivalent.

### 8. Sorting Order — PASS, no gap found

No side-by-side "before/after" or reading-order mismatch was found in any audited file;
every compound layout's visual order already matches its logical reading order. No action
needed against this checklist item.

## Cross-cutting observation

Three of the eight checklist items (§4, §5, §7) trace back to the **same duplicated
header shape** — `statusIcon` + `VStack(title, subtitle)` — copy-pasted across at least
eight status/report sheets instead of being a shared component. That one extraction (a
`SheetHeader` or similar view, built once with grouping + hidden decorative icon + a design
that doesn't need a manual `.isHeader` because it either uses a real `Text` header role or a
native mechanism) would resolve a large fraction of the individual findings above in one
change, rather than eight near-identical ones. `SettingsBox.swift`'s missing `.isHeader`
similarly propagates to every one of its call sites from a single source.

The overall codebase is **not** starting from zero — `PlistEditorView.swift`,
`SyncStatusView.swift`, `FollowersView.swift`, `HealthBadgeView.swift`/
`SecurityReportsBadgeView.swift`, `NewSiteWizard.swift`, and `LicenseGateSheetView.swift`
all contain deliberate, sometimes explicitly-commented accessibility work that fully meets
the checklist. The recurring failure mode is **inconsistent replication** — a correct pattern
shipped in one file/component doesn't get carried into the next structurally-identical one
(`ThemeChooserCard` vs. `ThemeApplyCard`; `FollowerAvatar` vs. `KeychainTokenRow`'s avatar;
the newer domain/sync sheets vs. the older `DomainSheetView`/`OnionRoutingSheetView`/
`BackupDrawerView` family) — rather than the pattern being unknown to the codebase.

## Recommended follow-ups

Per the owner's audit-first decision, this report does not apply fixes. Candidate follow-up
issues, roughly ordered by leverage (shared-component fixes first, since they close the most
individual findings per change):

1. **Extract a shared sheet/status header view** (icon + title/subtitle, grouped +
   decorative icon hidden) and migrate the ~8 duplicated call sites in §4/§5/§7 —
   `DomainSheetView`, `DomainConfigAuditSheetView`, `OnionRoutingSheetView`,
   `BackupDrawerView`, `AuditSheetView`, `HardenSheetView`, `AgentReadinessSheetView`,
   `AISearchSheetView`. Filed as [#1520](https://github.com/Anglesite/Anglesite/issues/1520).
2. **Add `.accessibilityAddTraits(.isHeader)` to `SettingsBox`'s title** and audit its call
   sites (`ContentLicensingTab` + others) for correctness once it's on by default.
3. **Label the remaining icon-only "remove row" buttons** across the component/typed-entry
   editors (`ComponentMetadataInspectorPane`, `ComponentStyleInspectorPane`,
   `TypedEntryEditorView`, `PlistEditorView`) — mechanical, low-risk, one pattern repeated.
4. **Bring `ThemeApplyCard` (`ThemeApplyWizard.swift:123-174`) up to `ThemeChooserCard`'s
   standard** — it currently has no accessibility modifiers at all. Copy
   `ThemeChooserCard`'s exact mechanism (`NewSiteWizard.swift:200-213`): combine + label +
   `.accessibilityValue("Selected"/"")` for selection state — a **value**, not the
   `.isSelected` **trait** (that's a different, equally valid mechanism used elsewhere, e.g.
   `LicenseGateSheetView.swift:169-195`, but not the one this sibling wizard established).
5. **Add `.accessibilityValue` to `PhaseProgressStrip`** (deploy progress) and to
   `DesignInterviewPanel`'s five axis sliders (label them with the axis name).
6. **Group remaining ungrouped compound rows** not covered by #1 —
   `ComponentEditorOutlinePane`, `RelatedPagesPanel`, `SiteGraphExplorerView` tree rows,
   `SiteSearchField` suggestions, `DebugPaneView` worker rows, `FollowersView`/
   `CommunitiesView` list rows.
7. **iOS/iPadOS SwiftUI accessibility audit** (`AnglesiteMobile`, `AnglesiteIOS`) — out of
   scope here; worth its own issue once those targets carry more real UI, per
   `docs/ios-ipados-assed-app-spec.md`.

These are sized so each can land as its own PR without a cross-cutting sweep, per the
owner's audit-first / scoped-follow-up decision on #1096.

# Cloudflare Bot Preference Sync Support — Design

**Date:** 2026-08-23
**Issue:** [#1628](https://github.com/Anglesite/Anglesite/issues/1628) — implementation; [#1627](https://github.com/Anglesite/Anglesite/issues/1627) — follow-up (flip default flag once Cloudflare GA)
**Related:** [Cloudflare: Bot Preference Sync](https://blog.cloudflare.com/bot-preference-sync/); #689 (per-content-type content licensing), #991 (Content-Signal / named-bot blocklist clamp), #992 (RSL phase 3), #1093 (per-route robots-config.json)
**Scope:** Let a site owner choose, per site, whether Anglesite's own named-bot blocklist or Cloudflare's Bot Preference Sync is responsible for blocking AI crawlers in `robots.txt`. Anglesite's `Content-Signal` permissions (search/aiInput/aiTrain) keep being emitted by Anglesite either way — Cloudflare's feature doesn't produce that directive. Ships behind a feature flag, off by default.

## Background

Cloudflare's Bot Preference Sync is a zone-level dashboard setting (not yet GA — "keep an eye on our changelog for availability") that periodically writes a `# BEGIN/END Cloudflare Bot Preference Sync` block into the edge-served `robots.txt`, grouping named bots (from Cloudflare's BotBase registry) under three owner-chosen categories — Search, Agent, Training — each Allow / Block-on-ad-pages / Block (Training is Allow/Disallow only). It **prepends** above whatever `robots.txt` the origin already serves; existing `Disallow` directives are left alone. There is no public API for it — dashboard only — and the article names no exact settings path yet.

Anglesite already has an overlapping, independent mechanism. `src/data/licensing.json`'s `AIUsage` (`search`/`aiInput`/`aiTrain`, each `"yes"|"no"|"unset"`) drives two projections in `buildRobotsTxt` ([edge-artifacts.ts](../../../Resources/Template/scripts/edge-artifacts.ts)):

1. A `Content-Signal:` directive (Cloudflare's own [Content Signals Policy](https://blog.cloudflare.com/content-signals-policy/) — a *different*, earlier Cloudflare spec, unrelated to Bot Preference Sync).
2. When `blockAICrawlers` is on and `aiInput`/`aiTrain` are both `"no"` (`mayBlockAICrawlers`), a hardcoded 17-named-bot `Disallow: /` block, built into the committed template and updated only when Anglesite ships a new bot list.

(2) is the real duplicate: Cloudflare's sync does the same job, driven by a registry Cloudflare keeps current, without needing a rebuild. (1) has no Cloudflare-managed equivalent and must keep working regardless of which system owns the blocklist.

## Decisions (brainstorm 2026-08-23, owner-approved)

1. **Content-Signal is unconditional.** It keeps emitting from Anglesite's own policy in both modes — losing it when Cloudflare takes over blocking would be a regression, not a simplification, since Cloudflare's sync doesn't produce it.
2. **The Cloudflare-managed option is gated on a resolved Cloudflare zone.** Reuses the same zone-resolution flow `HardenModel`/`AgentReadinessModel` already use. No token, no domain, or no resolved zone → only "Anglesite managed" is offered; the option isn't shown disabled, it's absent.
3. **Defaults, computed without ever silently rewriting a file.** New sites default to Cloudflare-managed only when a zone resolves *and* the site's `usage` is still at its pristine default (`NO_USAGE`-equivalent); any site with an expressed preference — including an old file that only has `blockAICrawlers: true` — is left exactly as it behaves today. This is a data-driven rule (pristine vs. expressed), not a site-age check, so it naturally covers "new site" and "existing untouched site" the same way.
4. **The mode is persisted in `licensing.json` itself** (Approach A), not app-only `Config/` state — consistent with `Source/`'s git repo being the canonical, externally-editable copy of a site (per this repo's package-model principle). The build script enforces the mode defensively, the same way it already treats `mayBlockAICrawlers` as an invariant the function owns, not just its caller.
5. **The whole feature sits behind a new `AppSettings` flag, off by default.** Cloudflare's sync isn't GA and its dashboard path isn't documented yet, so there's nothing correct to ship into the default UI today. Follows the existing `debugPaneEnabled` → `showsLANRuntimeSection` precedent in `SettingsView.swift`: a diagnostics-style toggle gates a whole downstream section, including its network calls.

## Architecture

```
licensing.json (Source/, git-tracked)
  AIUsage { search, aiInput, aiTrain, blockAICrawlers, botBlocklistManagedBy }
       │                                              │
       │ read at build                                │ read/written by the app
       ▼                                              ▼
edge-artifacts.ts::buildRobotsTxt              ContentLicensingTab (SwiftUI)
  • Content-Signal ← usage (always)                   │  gated by AppSettings.botPreferenceSyncUIEnabled
  • 17-bot Disallow ← blockAICrawlers               PlistEditorModel
      && mayBlockAICrawlers(usage)                    │  DeployCoordinator.resolveSiteURL → domain
      && botBlocklistManagedBy != "cloudflare"         │  CloudflareAPICredentials.resolve → token
       │                                              │  CloudflareReading.resolveZoneID(domain:apiToken:)
       ▼                                              ▼
   public/robots.txt (committed)              zone resolved? → offer "Cloudflare managed"
                                                         │
                                          picks Cloudflare → BotPreferenceSyncDashboardLinks
                                                         → https://dash.cloudflare.com/?to=/:account/:zone/…
```

Cloudflare's own edge then prepends its Bot Preference Sync block in front of whatever `public/robots.txt` says, at request time — untouched by anything in this diagram.

## Components

### Schema — `AIUsage.botBlocklistManagedBy`

New field, both sides of the existing TS/Swift mirror:

```ts
export interface AIUsage {
  search: UsagePermission;
  aiInput: UsagePermission;
  aiTrain: UsagePermission;
  blockAICrawlers: boolean;           // unchanged meaning: is Anglesite's own blocklist on
  botBlocklistManagedBy: "anglesite" | "cloudflare"; // new
}
```

`blockAICrawlers` keeps its exact current meaning and is only *actionable* when `botBlocklistManagedBy` is `"anglesite"` (the default). Absent key decodes to `"anglesite"` — same `decodeIfPresent ?? default` idiom `LicensingStore.swift` already uses for `blockAICrawlers`, and the same `toPermission`-style tolerant parse `normalizeUsage` already applies in `licensing.ts`. No migration script, no rewritten JSON: old files behave identically the moment they're read.

### Build-time gating — `edge-artifacts.ts`

```ts
if (usage.blockAICrawlers && mayBlockAICrawlers(usage) && usage.botBlocklistManagedBy !== "cloudflare") {
  // emit the 17-bot Disallow block, exactly as today
}
```

This is a defensive backstop, not just a UI gate — mirrors the existing comment in `buildRobotsTxt` that the blocklist-never-exceeds-permissions invariant "belongs to this function, not just its one caller." `Content-Signal` emission is untouched by this field.

### Zone resolution — `PlistEditorModel`

Lazy, on tab appearance, only when the feature flag is on (see below). Mirrors the existing `setCloudflareAnalyticsEnabled` pattern already in this file:

```
DeployCoordinator.resolveSiteURL(siteDirectory:) → domain
  → CloudflareAPICredentials.resolve(secretStore:diagnosticSource:) → token
  → CloudflareReading.resolveZoneID(domain:apiToken:) → zoneID?
```

No domain, no token, a thrown error, or `nil` zoneID → treated identically: the Cloudflare option stays hidden. This is advisory, not cached as final — same posture `CloudflareCapabilityProber` already documents for its own probes.

### Default-selection algorithm

Runs when the policy loads into the editor, in memory only:

```
if usage == NO_USAGE && zoneResolved {
  preselect botBlocklistManagedBy = "cloudflare"
} else {
  preselect/keep botBlocklistManagedBy = "anglesite"
}
```

Nothing is written to disk by this step — it only becomes real on the user's next save, exactly like every other field `isLicensingDirty`/`savedLicensingPolicy` already track in this editor. `usage == NO_USAGE` is the load-bearing condition: it's true for a genuinely fresh site and equally true for a two-year-old site nobody ever configured, and false the moment an owner has expressed *any* preference (including just `blockAICrawlers: true` on the old schema) — so "existing sites: unchanged" falls out of the same rule without a separate site-age check.

### UI — `ContentLicensingTab`

- Whole section gated by the feature flag (below); flag off → tab renders exactly as it does today, no new control, no zone-resolution call.
- Flag on: a "Bot blocklist managed by" control (Anglesite / Cloudflare) appears above the AI-usage section, but only once a zone has resolved — otherwise it's simply absent and the tab looks like today's.
- `search`/`aiInput`/`aiTrain` pickers: unchanged, always visible in both modes.
- **Anglesite mode:** `blockAICrawlers` toggle exactly as today.
- **Cloudflare mode:** toggle replaced by explanatory copy + a "Manage in Cloudflare Dashboard →" link (see below).

### Feature flag — `AppSettings.Key.botPreferenceSyncUIEnabled`

```swift
public static let botPreferenceSyncUIEnabled = "anglesite.botPreferenceSyncUIEnabled"
```

`@AppStorage(AppSettings.Key.botPreferenceSyncUIEnabled) private var botPreferenceSyncUIEnabled: Bool = false`, surfaced as a toggle in `SettingsView`'s Advanced tab, in the existing "Diagnostics" section next to `debugPaneEnabled` ("Show Cloudflare bot management option in Content Licensing"). `ContentLicensingTab`/`PlistEditorModel` read it the same way `showsLANRuntimeSection` reads `debugPaneEnabled` today: a single gate at the top of the relevant view/model logic, not scattered checks.

### Dashboard deep link — `BotPreferenceSyncDashboardLinks`

New helper, same shape as `WorkerDashboardLinks.swift`:

```swift
public enum BotPreferenceSyncDashboardLinks {
    public static func settingsURL(zoneID: String) -> URL {
        // Provisional path — Cloudflare's blog post doesn't name the exact settings location
        // yet ("keep an eye on our changelog"). Follows the documented `?to=/:account/:zone/…`
        // deep-link family other dashboard links in this codebase already use. A wrong path
        // degrades to the zone overview (one more click), never a dead end — same resilience
        // note WorkerDashboardLinks carries for its own paths. Fix here, in one place, once
        // Cloudflare documents the real path.
        URL(string: "https://dash.cloudflare.com/?to=/:account/:zone/security/settings")!
    }
}
```

## Migration / backward compatibility

- Old `licensing.json` files (no `botBlocklistManagedBy` key): decode to `"anglesite"`, robots.txt output unchanged, no file rewrite triggered by reading.
- A site with `blockAICrawlers: true` already set keeps blocking exactly as before — it has an expressed preference, so the default-selection algorithm never touches it.
- Turning the feature flag off after some sites have already picked `"cloudflare"` does **not** revert their `botBlocklistManagedBy` — the build script still honors it (the flag only gates the *editor UI and zone-resolution calls*, never the build's read of the persisted field). Turning the flag back on simply makes the control visible again.

## Error handling

| Condition | Behavior |
|---|---|
| No Cloudflare token in Settings → Credentials | Cloudflare option hidden; tab behaves as flag-off |
| Domain doesn't resolve to a zone | Same — hidden, not disabled |
| `resolveZoneID` throws (network, auth) | Treated as "not resolved" — advisory, re-probed next tab load, never surfaced as an error in this tab (matches `CloudflareCapabilityProber`'s posture) |
| Dashboard deep-link path is stale/wrong once Cloudflare ships real navigation | Lands on the zone overview — one extra click, not a dead link |
| Owner picks Cloudflare-managed but never actually enables Cloudflare's sync (no API to verify) | Out of scope to detect — Anglesite trusts the declared mode, same as it already trusts a declared `blockAICrawlers` today. Explanatory copy in Cloudflare mode should say plainly that this only takes effect once Bot Preference Sync is turned on in the linked dashboard. |

## Testing

- **TS** (`robots-config.test.ts` / licensing build tests): `botBlocklistManagedBy: "cloudflare"` suppresses the 17-bot block even with `blockAICrawlers: true` and both permissions `"no"`; absent key behaves identically to today; `Content-Signal` unaffected by the field in either mode.
- **Swift** (`LicensingStore` tests): encode/decode round-trip including the absent-key default.
- **Swift** (`PlistEditorModel`/`ContentLicensingTab` tests): `NO_USAGE` + zone-resolved → preselects `"cloudflare"` in memory only (no write until save); any non-default `usage` → always preselects `"anglesite"` regardless of zone; flag off → no zone-resolution call is made at all (assert on the test double); flag on + no zone → option absent, not disabled.
- **Manual** (`docs/testing-macos-app.md` build/launch flow): exercise both modes on a site with a resolvable zone and one without, with the flag on; confirm flag-off leaves the tab pixel-identical to pre-feature behavior.

## Open questions / risks

- **Exact Cloudflare dashboard settings path is unknown** pending GA — `BotPreferenceSyncDashboardLinks.settingsURL` is a best guess, isolated to one file for an easy fix.
- **No way to verify Cloudflare's sync is actually enabled** for a zone that resolves — Anglesite can confirm the *zone*, not the *setting*. Copy needs to be honest about this trust boundary.
- **Flag removal criteria**: flip the default on (or remove the flag) once Cloudflare's feature is GA and the dashboard path is confirmed — tracked in [#1627](https://github.com/Anglesite/Anglesite/issues/1627), not part of this spec's implementation.

## Rollout plan

Ship code-complete behind `botPreferenceSyncUIEnabled` (default off) so schema/build-script/tests land now; enable manually via Settings ▸ Advanced ▸ Diagnostics for testing against a real zone. Flip the default once Cloudflare's dashboard path is confirmed post-GA.

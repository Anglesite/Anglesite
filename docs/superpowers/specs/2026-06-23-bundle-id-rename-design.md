# Bundle-ID + Package-UTI Rename → `io.dwk.anglesite.*`

**Date:** 2026-06-23
**Status:** Implemented (PR #302, 2026-06-23)
**Related:** #81 (real-signed MAS smoke, blocked on provisionable bundle ID), Phase 10.1 (#34), `project-mas-distribution-and-bundle-id` memory

> **CORRECTION (2026-08-14):** the account situation is more complicated than this doc assumed.
> `M34HBJZNYA` does carry usable certificates, and it is the team holding the paid Apple Developer
> Program membership that #1208's portal-gated capabilities — CloudKit, App Groups, and the
> provisioning-profile-backed half of Keychain Sharing — depend on. `KH7H8Y25RT` remains a usable
> personal-team Development certificate for local signing, but carries no paid-membership
> capabilities. The original text below is left as written, as the record of what was believed at
> the time.

## Motivation

The app currently ships under `dev.anglesite.app` (DevID) and `dev.anglesite.app.mas`
(Mac App Store). Two facts make these unusable going forward:

1. **Team change.** The signable Apple Developer team is now `KH7H8Y25RT`
   (`dwk@mac.com`). The `dev.anglesite.*` App IDs were registered under the old
   `M34HBJZNYA` ("Beyond Certified, Inc.") team, whose cert has no usable private
   key on the current machine. An App ID cannot be re-homed across teams, so a new
   ID under the personal namespace is required to mint a development provisioning
   profile — the exact blocker that stops #81's real-signed smoke from signing.
2. **MAS is the only channel.** The direct-download track is deprioritized;
   the App Store build is the flagship, so it earns the canonical ID.

> **Decision reversal note.** `docs/build-plan.md:164` recorded (2026-06-09) that the
> `io.dwk.anglesite` candidate was *dropped* in favor of `dev.anglesite.app`. This
> spec reverses that decision. The reason is new: the team moved to `KH7H8Y25RT` and
> MAS became the sole channel — neither was true in June. The build-plan note is
> updated as part of this work so the next reader doesn't see whiplash.

## Identity mapping

| Identifier | Kind | From | To |
|---|---|---|---|
| MAS app (shipping) | bundle ID | `dev.anglesite.app.mas` | `io.dwk.anglesite` |
| DevID app (local dev loop) | bundle ID | `dev.anglesite.app` | `io.dwk.anglesite.devid` |
| Package document type | UTI | `dev.anglesite.site` | `io.dwk.anglesite.site` |
| Help Book | bundle ID | `dev.anglesite.app.help` | `io.dwk.anglesite.help` |
| Site window activity | NSUserActivity type | `dev.anglesite.app.site-window` | `io.dwk.anglesite.site-window` |
| Cloudflare token store | Keychain service | `dev.anglesite.app` | `io.dwk.anglesite` |
| Diagnostic logs | OSLog subsystem | `dev.anglesite.app` | `io.dwk.anglesite` |

Rationale for the scheme ("MAS clean, DevID suffixed"): the App Store build is the
product, so it gets the bare `io.dwk.anglesite`; the DevID target survives only as a
non-sandboxed local dev-loop convenience, so it takes the explicit `.devid` suffix.

## Components and files

### Functional (must stay internally consistent)

- **`project.yml`** — two `PRODUCT_BUNDLE_IDENTIFIER` values (DevID target → `…devid`,
  MAS target → `io.dwk.anglesite`). This is the single source of the real bundle IDs;
  `Anglesite.xcodeproj` is gitignored and regenerated via `xcodegen generate`.
- **`Resources/Info.plist`** and **`Resources/AnglesiteMAS-Info.plist`** (per-target):
  - `CFBundleHelpBookName` → `io.dwk.anglesite.help`
  - `NSUserActivityTypes` entry → `io.dwk.anglesite.site-window`
  - `UTExportedTypeDeclarations` → `UTTypeIdentifier` `io.dwk.anglesite.site`.
    **The `UTTypeTagSpecification` `public.filename-extension = anglesite` is
    preserved**, so Launch Services keeps mapping the `.anglesite` extension to the
    (renamed) UTI and existing packages still open.
  - `LSItemContentTypes` (under the document type / `LSTypeIsPackage`) →
    `io.dwk.anglesite.site`.
- **`Resources/Anglesite.help/Contents/Info.plist`** — help book `CFBundleIdentifier`
  → `io.dwk.anglesite.help` (must equal `CFBundleHelpBookName` in both app plists).
- **`Sources/AnglesiteCore/UTType+Anglesite.swift`** — the single
  `UTType(exportedAs: "io.dwk.anglesite.site")` string. All call sites reference the
  `.anglesiteSite` symbol and need no change.
- **`Sources/AnglesiteCore/KeychainStore.swift`** — `defaultService = "io.dwk.anglesite"`.
- **`Sources/AnglesiteIntents/SiteEntityAnnotation.swift`** — `activityType =
  "io.dwk.anglesite.site-window"` (paired with `NSUserActivityTypes`).

### Cosmetic (consistency only; no behavior change)

- OSLog subsystems: `Sources/AnglesiteCore/FoundationModelAssistant.swift`,
  `Sources/AnglesiteIntents/Bootstrap.swift` (3 loggers).
- `Sources/AnglesiteApp/SettingsView.swift` — help text naming the Keychain service.
- `Tests/AnglesiteCoreTests/KeychainStoreTests.swift` — scratch-service prefix
  (`dev.anglesite.tests.` → `io.dwk.anglesite.tests.`); independent UUID namespace,
  not load-bearing.
- Docs: `CLAUDE.md`, `README.md`, `docs/build-plan.md` (incl. the decision-reversal
  note at :164), `docs/xcode-setup.md`, and the dated spec/plan docs that quote the
  old IDs. Historical specs are updated only where they describe current config, not
  retroactively rewritten.

## Decisions

### Keychain: hard rename, no migration code

The Keychain service moves from `dev.anglesite.app` to `io.dwk.anglesite` with **no
migration shim**. Justification: the app is pre-release and unshipped on MAS; the only
stored Cloudflare token is on the developer's machine. A migration-on-read fallback is
throwaway code for a single one-time re-entry. Cost: the developer re-pastes the
Cloudflare token once via Settings → Advanced → Credentials after the rename. (If a
zero-touch migration is later wanted, add a one-time read from the old service in
`KeychainStore` and delete it after a release.)

### Launch Services / package recognition

Because `.anglesite` packages are recognized by **filename extension** (declared in the
app's `UTExportedTypeDeclarations` → `UTTypeTagSpecification`), not by a UTI string
embedded in each package, changing the UTI **identifier** is transparent to packages on
disk. The only risk is a stale Launch Services type cache. Mitigation is an explicit
verification step (below), not migration code.

### Out of scope

- **Retiring the DevID target** — kept; only re-IDed. (Collapsing to a single target is
  a separate decision.)
- **App Store Connect record creation** for `io.dwk.anglesite` — requires the developer
  portal; tracked separately, unblocked by this rename.
- **The `dev.anglesite.app.mas.helper` references** in spec docs — no helper target was
  ever built (`project.yml` has zero helper refs); those docs are annotated as
  describing an unbuilt design, not renamed as if real.

## Testing and verification

1. `swift test --package-path .` — KeychainStore round-trips (scratch service) and
   AppIntents schema conformance pass under the new identifiers.
2. `xcodegen generate` succeeds and the "Anglesite.xcodeproj ↔ project.yml in sync" CI
   check passes; both `Anglesite` and `AnglesiteMAS` schemes build.
3. AppIntents-schema CI check (metadata processor) passes — the `activityType` change is
   reflected consistently.
4. **Manual Launch-Services smoke:** build the DevID app, register it (`open` once or
   `lsregister -f <app>`), confirm an existing `~/Sites/*.anglesite` package still
   double-click-opens and `File ▸ Open Site…` still filters on the package type.
5. Grep gate: no remaining `dev\.anglesite\.(app|site)` references outside intentionally
   historical doc passages.

## Acceptance

- Both targets carry the new IDs; `swift test` and both scheme builds are green.
- An existing `.anglesite` package still opens via Finder and `File ▸ Open Site…`.
- No `dev.anglesite.*` references remain except annotated historical doc text.
- The rename unblocks #81: `io.dwk.anglesite` is registrable under `KH7H8Y25RT`, so
  automatic provisioning can mint the Mac Development profile for a real-signed build.

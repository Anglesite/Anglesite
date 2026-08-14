# First-publish license gate

Design for #999 item 1 (of 4). Items 2-4 — embedded per-file license metadata, attach-time
application, and drop-and-inspect editing — are a separate design, out of scope here.

## Problem

`Source/src/data/licensing.json` and the Website Settings ▸ Content Licensing facet
(`ContentLicensingTab`, #991) already give a site one coherent licensing policy. But nothing
prompts the owner to actually choose one: a scaffolded site's `default` is `null` ("all rights
reserved") because Anglesite never picks a license on the user's behalf, and a site can be
published with that question never having been put to its owner.

The fix is a gate: block the *first* deploy on an explicit license choice, presented as a
Creative Commons comparison table with an "how AI systems interpret this" column — the
differentiating content that connects the choice to the AI-usage permissions #991 already
derives crawler signals from.

This is a **product** gate in the app, not a rule added to `pre-deploy-check.ts` — that script
is the security gate that catches things that must never ship; an unmade licensing decision is a
decision the owner is entitled to make, not a security defect.

## Data model

`LicensingPolicy` (`Sources/AnglesiteCore/LicensingStore.swift`) gains one new field:

```swift
public var licenseChosen: Bool
```

Defaults to `false`, like every other field's conservative default in this type. It is what
lets the model distinguish "never asked" from "explicitly chose All rights reserved" — both of
which collapse to `defaultLicense == nil` today, and the gate's hard-block behavior (below)
needs to tell them apart.

Persisted in `licensing.json` alongside `default`/`usage`/`publishRSL`, following `publishRSL`'s
own precedent as a non-content policy flag living in the same document (`Codable`
implementation: always encoded; decodes to `false` when the key is absent, matching every other
lenient field in this type's `init(from:)`).

**No migration path for existing sites.** Anglesite has not shipped to TestFlight; any site that
already set an explicit license through the current Settings UI can simply be re-saved (or the
test site recreated) against the new field. See the `no-migration-before-testflight` memory —
this exemption ends once the app ships externally.

## Gate behavior

**Dismissibility:** hard block, no dismiss. The sheet must resolve to an explicit choice —
including "All rights reserved" — before the parked deploy proceeds. Once `licenseChosen` is
`true`, the gate never fires again for that site.

**Trigger — `DeployModel.deploy(...)`:** this method already has exactly this shape of
precondition, for Cloudflare token availability:

```swift
guard !isRunning else { return }
if !hasUsableToken() {
    pendingDeploy = (...)
    tokenVerification = .idle
    tokenPromptPresented = true
    return
}
```

The license gate adds an identical guard, checked alongside (order: token check, then license
check — either can park the deploy and present its own sheet):

```swift
guard licenseChosen else {
    pendingDeploy = (...)
    licenseGatePresented = true
    return
}
```

Confirming a choice in the sheet saves the policy (see below) and resumes the parked deploy —
the same shape `signInWithCloudflare()` already uses to resume after the token-prompt sheet.

**Background path — `deployAutomatically(...)`:** never presents UI, so it defers instead of
blocking, matching its existing treatment of `!hasUsableToken()` and an unready container:

```swift
guard licenseChosen else { return .deferred(reason: "a content license hasn't been chosen yet") }
```

## UI

**`LicenseGateSheet`** (new SwiftUI view): the row-click comparison table. One row per
`LicenseCatalog.entries` entry (CC0 through CC BY-NC-ND, in catalog order), plus "All rights
reserved" and "Custom…". Clicking a row selects it (highlighted, like a radio group); "Custom…"
reveals inline URL/name fields using the same `PendingCustomLicense` pattern
`ContentLicensingTab` already has (Continue stays disabled until a URL is typed).

Columns: license name, what it permits (plain-language summary), and an AI-systems column
rendering `LicenseCatalog.Entry.permitsAIUse`:

- `true` → "✅ Permits" (CC0, CC BY, CC BY-SA)
- `false` → "❔ Unclear" (CC BY-NC, CC BY-ND, and the two combined variants)
- "All rights reserved" and "Custom…" → no claim rendered (unclassified, not guessed)

This reuses `LicenseCatalog`'s existing classification outright — no new interpretive logic.
The type's own doc comment already establishes why NC/ND stay unclassified (a live legal
question Anglesite refuses to resolve on the user's behalf), so the gate's table must render
that honestly rather than picking a symbol for "unclear."

Pressing **Continue**:

1. Sets `defaultLicense` from the selected row (`nil` for "All rights reserved").
2. Runs `LicenseCatalog.prefilled(usage, for:)` — fills only *unset* AI-usage purposes, matching
   `ContentLicensingTab`'s existing picker behavior, so this never clobbers a manual override
   made later.
3. Sets `licenseChosen = true`.
4. Saves via a `LicensingStore(sourceDirectory: siteDirectory)` the gate flow owns directly (no
   dependency on `PlistEditorModel` or the Settings window being open).
5. Resumes the parked deploy.

Out of scope for this sheet: per-collection overrides and the "Refuse AI crawlers" toggle. Those
stay in Settings ▸ Content Licensing, reachable afterward — the gate only needs one decision
made, not the full facet.

**Wiring:** `.sheet(isPresented: $deployModel.licenseGatePresented)`, attached alongside the
existing token-prompt/worker-conflict/domain-drift sheets in whichever view currently hosts
those (`SiteWindow.swift` / `DeployDrawerView.swift`) — no new presentation mechanism.

## Testing

- `DeployModelTests`: mirroring the existing token-prompt tests —
  - `deploy(...)` with `licenseChosen == false` parks the deploy and presents the gate instead
    of running.
  - Confirming a choice saves the policy and resumes the parked deploy.
  - `deployAutomatically` defers with the "hasn't been chosen yet" reason when unresolved.
- `LicensingStoreTests` / `LicenseCatalogTests`: round-trip coverage for the new field
  (encodes always, decodes absent-key to `false`).
- `LicenseGateSheet`'s row-selection and custom-license-reveal logic extracted as testable pure
  functions/state structs, the way `ContentLicensingTab.shouldRevealCustomFields` /
  `PendingCustomLicense` already are — sidesteps needing a hosted SwiftUI render pass to test
  `@State` transitions, per this codebase's established pattern.

## Non-goals

Per-file embedded license metadata (ImageIO/AVFoundation/PDFKit), the file-open-dialog
checkbox, and drop-and-inspect editing — #999 items 2-4 — are a separate design.

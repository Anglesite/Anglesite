# iOS/iPadOS v2.0 — the phone and iPad as a complete publishing companion

**Status:** Approved design (owner-reviewed 2026-08-12) — closes epic #342's design mandate
**Relates to:** #342 (this epic), #1208 (Anywhere runtime — the editing transport; its spec
`2026-08-03-anywhere-runtime-webrtc-design.md` remains the transport's implementation
authority), #71 (iOS thin client, closed — shipped the `AnglesiteMobile` scaffold), #800/#869
(the shipped Micropub posting shell), #66 (Cloudflare remote runtime — stays deferred),
#894 (Control Worker template — stays deferred with #66), `docs/ios-ipados-assed-app-spec.md`
(the platform-UX acceptance standard for everything below).

## Problem

Epic #342 mandated a dedicated design before iOS/iPadOS work enters a phase: scene/navigation
model, runtime choice, App Store submission, and a per-device feature set (pivot analysis
§5.8). Since it was filed, much of that scope shipped piecemeal: #71 delivered the
`AnglesiteMobile` target with the remote-only runtime seam, and #800/#869 shipped an
iCloud-discovery + Micropub posting shell as the v1 iOS experience. What never got a unified
design is the v2.0 product: how *site editing* — live preview, page and singleton edits,
publish — reaches the phone, how it composes with the posting shell, and what a separate App
Store submission requires. This spec is that design. It is standalone: it restates the
client-side architecture it consumes, and defers only transport internals to the
anywhere-runtime spec.

## Owner-approved scope decisions (2026-08-12)

1. **Runtime: P2P-first.** v2.0 iOS editing rides the #1208 Anywhere runtime exclusively —
   the owner's Mac is the runtime, the phone is a WebRTC P2P client. The Cloudflare sandbox
   path (#66) stays parked until #894 unblocks, as a future "Mac offline" fallback only.
2. **Navigation: integrated per-site "Edit Site".** Editing is a verb on a site already
   selected in the posting shell (`SiteSplitScreen`) — not a separate mode, tab, or second
   site picker.
3. **This spec is the standalone iOS/iPadOS v2.0 design** with its own issue chain (§8),
   superseding #342's checklist.

## §1 Product definition & per-device feature matrix

One Apple app, per-device feature sets (locked by the pivot analysis §5.8). v2.0 makes the
iPhone/iPad app a *complete publishing companion*: everything about your site you'd want away
from your desk, with the Mac remaining the studio.

| Capability | Mac | iPhone | iPad |
|---|---|---|---|
| Create/import/scaffold a site | ✅ | ❌ Mac-only | ❌ Mac-only |
| Micropub posting (notes, posts) | n/a (full editor) | ✅ shipped (#869) | ✅ shipped (#869) |
| Live preview + page/singleton editing | ✅ local container | ✅ new: P2P session | ✅ new: P2P session |
| Publish/deploy | ✅ local gate | ✅ request → Mac runs gate (#1208 P5) | ✅ same |
| Theme/template chooser, component editor | ✅ | ❌ v2.0 non-goal | ❌ v2.0 non-goal |
| Site settings (tokens, domains) | ✅ | ❌ v2.0 non-goal | ❌ v2.0 non-goal |

iPhone is focused capture-and-publish plus "fix that typo from the train." iPad is the same
plus adaptive multi-column layout, keyboard shortcuts, and pointer support per
`docs/ios-ipados-assed-app-spec.md` — an adaptive iPadOS experience, not a shrunken Mac app.

## §2 Runtime architecture (P2P-first)

The only v2.0 editing runtime is **`P2PSiteRuntime: SiteRuntime`** over the #1208 Anywhere
stack. Restated here so this spec stands alone; the anywhere-runtime spec owns transport
implementation detail:

- **MCP** rides a WebRTC data channel via `WebRTCTransport: MCPTransport`. All edit journeys
  use the same MCP tools the Mac app uses — no iOS-only edit path.
- **Preview** loads through a custom scheme (`anglesite-p2p://…`) resolved by a
  `WKURLSchemeHandler` backed by the fetch-over-data-channel bridge. HMR has a dedicated
  relay channel so live reload works mid-edit. A `control` channel carries session lifecycle,
  heartbeat, and deploy request/progress events.
- **Trust** is QR pairing with pinned device keys; CloudKit's private database is only a
  signaling mailbox, never a trust root. There are no tokens or URLs to type. This
  **retires `RemoteConnectForm` entirely** — Worker-URL/bearer-token entry is
  Cloudflare-sandbox-shaped and has no P2P equivalent.
- **Site identity:** the phone names a site by its **stable package UUID** — the same UUID
  iCloud discovery (`SitePickerModel`) already yields from each package's `Info.plist`. The
  Mac helper resolves UUID → package via its recents registry and boots or bridges the
  container (one container owner per site, per the anywhere spec §5).
- **Cloudflare sandbox scaffold disposition:** `RemoteSandboxSiteRuntime` and
  `RemoteSessionModel`'s control-client plumbing stay in-tree behind the `SiteRuntime` seam
  as the deferred #66 "Mac offline" fallback (anywhere spec §4). Not reachable from any UI
  in v2.0.

## §3 Scene & navigation: integrated per-site "Edit Site"

Editing is a verb on a site the owner has already selected in `SiteSplitScreen` — no second
site picker, no separate mode.

- **Entry points:** an "Edit Site" toolbar action in the content pane; a context-menu item on
  the site's sidebar row; and an App Intent so Siri/Shortcuts/Spotlight can open a site for
  editing directly.
- **Presentation:** full-screen cover on both iPhone and iPad — the live preview plus edit
  overlay wants the whole canvas; the split-view columns remain the posting layout.
  Dismissing the cover *suspends* the session UI but keeps the P2P session warm for quick
  re-entry; an explicit "Stop" toolbar action ends the session.
- **Session states map to owner-comprehensible UI**, reusing the shipped
  idle/starting/ready/failed state-machine shape from `RemoteSessionScreen`, re-skinned for
  P2P per the anywhere spec's failure modes: "Waking your Mac…", "Starting your site…",
  "Your Mac was last reachable at 3:12 PM", "This network blocks direct connections."
  Messages speak about the owner's site and network — never about ICE, SDP, or WebRTC.
- **Preview leg reused nearly verbatim:** the `RemoteSandboxPreview` composition —
  `AnglesiteScriptHandler` + `MCPApplyEditRouter` + the shared edit-overlay user script +
  the `appEntityUIElementProvider` Siri annotation hookup — is already transport-agnostic.
  It receives the P2P `MCPClient` and the `anglesite-p2p://` preview URL. The
  session-token-cookie injection (#67) drops out: DTLS with pinned certificates replaces
  bearer auth end to end.
- **Pairing onboarding:** the first "Edit Site" tap with no paired Mac walks into the QR
  pairing flow (scan the code shown in the Mac app's Settings). Camera permission is
  requested in context at that moment, per the platform spec §5. With no paired Mac and no
  camera grant, the screen explains what pairing is and what it requires — an honest
  explainer, never a dead end.
- **Content coverage:** pages and singletons — filtered out of the posting sidebar today
  (`SiteSplitScreen` posts only collection-stored types) — become reachable through the
  session's live preview + overlay, resolving that code comment's "v2.0 scope" deferral.

## §4 App Store submission & sandbox rules

The iOS app ships as its **own App Store product**, a separate submission from the Mac app.

- **Bundle identity & signing:** `AnglesiteMobile` gets a real bundle ID under the same team,
  its own provisioning profile, and a `Signing-Release` xcconfig override mirroring the Mac
  target's pattern (#1414). TestFlight is the distribution lane for the whole v2.0 cycle;
  App Store submission is the exit criterion.
- **Entitlements**, each traced to a feature: iCloud ubiquity container (site discovery —
  already in use), CloudKit (P2P signaling mailbox), Keychain (Cloudflare token, pinned
  device keys), Associated Domains (`webcredentials:auth.anglesite.dwk.io` for the OAuth
  callback), camera (QR pairing scan). No local-network entitlement and no background modes:
  the phone dials out per-session only.
- **Privacy:** a privacy manifest and App Store nutrition label declaring iCloud-synced site
  content and no tracking; export-compliance annotation for the E2E-encrypted transport
  (standard-algorithms exemption — DTLS/WebRTC).
- **App Review reality check:** a reviewer has no paired Mac, so the app must be
  *reviewable standalone*. Micropub posting works against any IndieAuth-capable site, and
  "Edit Site" with no paired Mac shows the pairing explainer rather than a dead end. Review
  notes include a demo video of the paired flow and a demo Micropub account. This constraint
  is why the posting shell stays the root experience.
- **iOS sandbox differences are documented, not fought:** there are no security-scoped
  bookmark panels on iOS — the powerbox grant for non-iCloud sites lives Mac-side in the
  helper (anywhere spec, Mac helper §2). iOS file access is ubiquity-container-only.

## §5 Testing

- **Session UI:** Swift Testing suites drive the "Edit Site" flow against a fake
  `P2PSiteRuntime` behind the `SiteRuntime` seam (the same pattern as the Mac's
  `PreviewModel` tests): state transitions, reconnect, suspend/resume across cover
  dismissal, and "Mac last seen" rendering.
- **Edit journeys:** the existing MCP apply-edit e2e pattern is reused with
  `WebRTCTransport` swapped in over the in-process loopback pair from #1208 P0, gated
  `ANGLESITE_P2P_E2E=1`. No new test infrastructure is invented for this epic.
- **Devices:** the UTM rig (#589) plus a real phone cover the NAT-traversal matrix manually.
  The `docs/ios-ipados-assed-app-spec.md` release-acceptance checklist (VoiceOver, Dynamic
  Type, iPad multitasking sizes, keyboard/pointer) runs per feature PR, not once at the end.
- **CI:** the `AnglesiteMobile` build lane stays on the pinned toolchain; the
  `#if compiler(>=6.4)` gates around `appEntityUIElementProvider` remain until CI's Xcode
  catches up.

## §6 Failure modes

Inherited from the anywhere-runtime spec and rendered per "the app advises; it does not
delegate the decision": Mac asleep/offline → honest last-reachable message from the CloudKit
presence heartbeat; P2P unreachable → automatic TURN retry, then a clear terminal error
naming the likely cause; container boot latency → streamed `SiteRuntimeState` progress
("Starting your site…"); both editors live → one container owner per site, MCP serializes
edits; mid-session drop → runtime re-enters `.starting` and auto-reconnects, in-flight MCP
requests fail loudly, never silently.

## §7 Non-goals

- No browser/web client (anywhere spec non-goal, restated).
- No site creation, theme choosing, component editing, or site settings on iOS in v2.0 (§1).
- No Cloudflare-sandbox UI — #66/#894 stay deferred; the scaffold survives only behind the
  runtime seam.
- No multi-user collaboration (#399) — one owner, their own devices.
- No iPhone/iPad multi-window in v2.0; a single scene with the session as a full-screen
  cover. Multiple scenes are an explicit platform-spec non-requirement, revisited if iPad
  usage demands it.

## §8 Issue set & phasing

Sequenced so each lands independently; the first two ride #1208's P4/P5 exit criteria rather
than duplicating them. All carry the v2.0 milestone.

| Issue | Deliverable | Depends on |
|---|---|---|
| #1431 | "Edit Site" session UI in `SiteSplitScreen`: entry points, full-screen cover, session-state UI, pairing-onboarding walk-in, consuming `P2PSiteRuntime` | #1208 P2 (informs P4) |
| #1432 | Publish-from-phone UI: deploy request/progress/log streaming over `control` in the session UI | #1208 P5, #1431 |
| #1433 | `RemoteConnectForm` retirement + scaffold disposition: delete the form; keep `RemoteSandboxSiteRuntime` + control-client plumbing behind the seam; prune `RemoteSessionModel` to what the session UI uses | #1431 |
| #1434 | App Store lane: bundle ID/provisioning/TestFlight, entitlements, privacy manifest, review notes + standalone-reviewable demo path (§4) — largely maintainer ops, issue documents the checklist | — |
| #1435 | iPad externals polish: Command-key shortcuts, pointer hover on overlay targets, Split View/Stage Manager session behavior (platform spec §3–4) | #1431 |
| #1436 | State restoration: scene restores selected site/post/draft and re-offers a warm session after relaunch (platform spec §4) | #1431 |

Epic #342 closes when this spec and the issues above exist, pointing at #1208 as the
runtime's implementation epic.

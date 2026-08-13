# Remote Development Server settings: copy fixes + LAN discovery — design

**Date:** 2026-08-13
**Issue:** [#858](https://github.com/Anglesite/Anglesite/issues/858) ("LAN site runtime UI issues")
**Status:** Approved design; ready for implementation planning.

## Scope

Settings ▸ Advanced ▸ "LAN site runtime" (`AdvancedSettingsView`, [`Sources/AnglesiteApp/SettingsView.swift:293-406`](../../../Sources/AnglesiteApp/SettingsView.swift)) has four reported issues:

1. Section title reads "LAN site runtime" instead of "Remote Development Server."
2. The host-field placeholder reads `mac-studio.local` instead of `my-mac.local`.
3. Port placeholders render with locale grouping (`4,321`) instead of plain digits (`4321`).
4. There is no way to discover a LAN host automatically — the owner must type host/ports by hand even when a compatible `anglesite-lan-host` process is already running and reachable on the same network.

Per the prior automated triage (issue comments), (1)-(3) are copy/formatting bugs with a clear mechanical fix; (4) is a net-new feature (no Bonjour/discovery code exists anywhere in the codebase today). All four land in one PR per owner decision during scoping.

This is app-side plus one host-side executable target (`AnglesiteLANHost`) — no MCP schema changes, no paired sidecar PR. No changes to `LiveSiteRuntimeFactory` wiring; this issue is Settings UI only, per [`docs/specs/2026-07-09-lan-site-runtime-design.md`](../../specs/2026-07-09-lan-site-runtime-design.md), which already documents where a LAN runtime plugs into the runtime factory (out of scope here).

## Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Discovery advertising | `anglesite-lan-host` advertises a custom Bonjour service type (`_anglesite-lan._tcp`) | Only real `anglesite-lan-host` instances are discovered; browsing generic `_http._tcp` and guessing would produce false positives from any LAN HTTP server |
| Scan trigger | Time-boxed scan (fixed window) started by the button, not continuous live browsing | Predictable, bounded, and the timeout/cutoff behavior is easy to reason about and test in isolation from the view lifecycle |
| Multiple-result UI | Inline list directly below the button, in the same `Form` section | No modal/sheet state machine; matches the settled, lightweight feel of the rest of this Settings pane |
| Zero-result / permission-denied UI | Inline secondary-text caption below the button | Matches the existing caption style used throughout this section (e.g. [`SettingsView.swift:384`](../../../Sources/AnglesiteApp/SettingsView.swift)) rather than introducing a new alert pattern |
| Row content | DNS name + IP address + site name | Site name (from a TXT record) disambiguates when the owner runs more than one `anglesite-lan-host` instance for different sites; DNS name + IP match the issue's literal wording |
| Architecture | Protocol seam (`LANHostDiscovering`) + `#if canImport(Network)`-guarded concrete implementation, plus a pure selection function | Mirrors this codebase's existing `ConnectivityMonitoring` pattern ([`Platform/ConnectivityMonitoring.swift:5-26`](../../../Sources/AnglesiteCore/Platform/ConnectivityMonitoring.swift)) exactly, and isolates the one part of this feature with real logic (the 0/1/N selection rule) behind a pure, unit-testable function |

## Components

### 1. Copy/format fixes (`AnglesiteApp`)

Extract the three current string literals into non-private, testable static helpers (naming follows this file's existing conventions — exact enum/namespace name decided at implementation time):

- `sectionTitle` → `"Remote Development Server"` (was `"LAN site runtime"`)
- `hostPlaceholder` → `"my-mac.local"` (was `"mac-studio.local"`), rendered via `Text(verbatim:)`
- `portPlaceholder(_ port: Int) -> String` → `String(port)` (e.g. `"4321"`), rendered via `Text(verbatim:)` instead of `Text("\(port)")`, which applies locale grouping through `LocalizedStringKey` interpolation — confirmed root cause of the comma bug.

These replace the three inline literals at [`SettingsView.swift:363`](../../../Sources/AnglesiteApp/SettingsView.swift), [`:365`](../../../Sources/AnglesiteApp/SettingsView.swift), [`:372`](../../../Sources/AnglesiteApp/SettingsView.swift), [`:379`](../../../Sources/AnglesiteApp/SettingsView.swift). Because they're pulled out of the `private struct AdvancedSettingsView`, a test can pin them directly (e.g. `portPlaceholder(4321) == "4321"`), closing the "no seam" gap the prior triage identified.

### 2. `LANHostAdvertiser` (`AnglesiteCore`, new) — host side

Used by `AnglesiteLANHost`'s `runServe` ([`Sources/AnglesiteLANHost/main.swift:38-102`](../../../Sources/AnglesiteLANHost/main.swift)):

```swift
#if canImport(Network)
public final class LANHostAdvertiser: @unchecked Sendable {
    public init()
    public func start(site: String, previewPort: Int, mcpPort: Int)
    public func stop()
}
#endif
```

- Advertises `_anglesite-lan._tcp` via `NWListener.Service`, bound to an ephemeral port used only to carry the Bonjour record — it never accepts real connections. The real preview/MCP ports live in the TXT record (`site`, `previewPort`, `mcpPort`), not the listener's own port, since those ports are already bound by the astro-dev/mcp-sidecar child processes `runServe` launches.
- Started immediately before `waitForShutdownSignal()` ([`main.swift:100`](../../../Sources/AnglesiteLANHost/main.swift)); stopped in the same shutdown path that calls `supervisor.shutdownAll()` ([`main.swift:101`](../../../Sources/AnglesiteLANHost/main.swift)), so a killed/Ctrl-C'd host stops advertising in step with its servers going down rather than leaving a stale, unreachable Bonjour record.

### 3. `DiscoveredLANHost` + `LANHostDiscovering` (`AnglesiteCore`, new) — app side

```swift
public struct DiscoveredLANHost: Sendable, Equatable {
    public let siteName: String
    public let dnsName: String
    public let ipAddress: String
    public let previewPort: Int
    public let mcpPort: Int
}

public protocol LANHostDiscovering: Sendable {
    func start(onUpdate: @escaping @Sendable ([DiscoveredLANHost]) -> Void)
    func stop()
}
```

Mirrors `ConnectivityMonitoring`'s shape exactly ([`Platform/ConnectivityMonitoring.swift:5-12`](../../../Sources/AnglesiteCore/Platform/ConnectivityMonitoring.swift)).

`NWBonjourLANHostDiscovery: LANHostDiscovering` (`#if canImport(Network)`) wraps `NWBrowser` browsing `_anglesite-lan._tcp`, resolves each result's endpoint to a DNS name + IP, parses the TXT record into `DiscoveredLANHost`, and calls `onUpdate` with the accumulated set on every browse-result change. Malformed or incomplete TXT records (missing `previewPort`/`mcpPort`/`site`) are skipped rather than crashing.

`PlatformLANHostDiscovery.make() -> any LANHostDiscovering` — factory selecting `NWBonjourLANHostDiscovery` where `Network` is importable, matching `PlatformConnectivityMonitor.make()` ([`Platform/ConnectivityMonitoring.swift:19-25`](../../../Sources/AnglesiteCore/Platform/ConnectivityMonitoring.swift)).

### 4. `selectLANHost(from:)` (`AnglesiteCore`, new) — pure selection logic

```swift
public enum LANHostSelection: Equatable {
    case empty
    case autoPopulate(DiscoveredLANHost)
    case chooseFrom([DiscoveredLANHost])
}

public func selectLANHost(from hosts: [DiscoveredLANHost]) -> LANHostSelection
```

Implements the issue's specified rule: zero hosts → `.empty`; exactly one → `.autoPopulate`; more than one → `.chooseFrom`. Pure data in/data out — no `Network` import, no timing, no view — so this is the piece a unit test pins directly with fixture arrays.

### 5. `AdvancedSettingsView` changes (`AnglesiteApp`)

- A "Find on local network" button starts `LANHostDiscovering.start(...)`, shows a spinner, waits a fixed window (e.g. 4 seconds), then calls `stop()` and evaluates `selectLANHost(from:)` on the accumulated results.
- `.autoPopulate(host)` → fills `lanRuntimeHost`, `lanRuntimePreviewPort`, `lanRuntimeMCPPort` directly.
- `.chooseFrom(hosts)` → renders an inline list below the button; each row shows `"\(dnsName) — \(ipAddress) — \(siteName)"`; tapping a row populates the three fields.
- `.empty` → a secondary-text caption below the button: "No anglesite-lan-host instances found on the local network." A local-network-permission-denial case uses the same caption slot with permission-specific wording (exact copy and detection mechanism confirmed during Tier-4 manual verification — see Testing below).

## Testing

**Tier 2 (unit-testable, lands with this PR):**

- The three copy/format helpers (`sectionTitle`, `hostPlaceholder`, `portPlaceholder(_:)`).
- `selectLANHost(from:)` — fixture arrays for 0/1/N hosts, asserting `.empty`/`.autoPopulate`/`.chooseFrom`.
- `DiscoveredLANHost` TXT-record parsing — given a raw TXT dictionary, decode into the struct; missing/malformed keys → that result is dropped, not a crash.

**Tier 4 (manual QA only, cannot be closed by this PR):** actual `NWBrowser` discovery across two real Macs, the local-network permission prompt and its denial path, and the rendered Settings pane for all four visual asks (title, placeholder, port formatting, discovery UI). This is inherent to Bonjour needing real network hardware to exercise; the design minimizes what's *only* provable by hand to the `Network`-framework glue itself (`NWBonjourLANHostDiscovery`, `LANHostAdvertiser`) — everything else is Tier 2.

## Entitlements / Info.plist

- `Resources/Anglesite.entitlements` already declares `com.apple.security.network.client`/`.server` ([`Anglesite.entitlements:7-11`](../../../Resources/Anglesite.entitlements)). Add `NSBonjourServices` (`["_anglesite-lan._tcp"]`) to [`Resources/Info.plist`](../../../Resources/Info.plist) so the sandboxed app is permitted to browse that service type, plus `NSLocalNetworkUsageDescription` for the local-network permission-prompt copy.
- `AnglesiteLANHost` is a separate host-side executable target, not sandboxed the same way as `Anglesite`; its build settings need the equivalent `NSBonjourServices` declaration on the advertising side. Confirmed at implementation time against whatever `Info.plist`/build-settings mechanism that target currently uses (it has none of its own today, per `Package.swift`'s executable-target shape).

## Non-goals

- No change to `LiveSiteRuntimeFactory` runtime-selection wiring — this issue is Settings UI only. The wiring point is already documented in [`docs/specs/2026-07-09-lan-site-runtime-design.md`](../../specs/2026-07-09-lan-site-runtime-design.md).
- No auth/security hardening for the Bonjour advertisement — same trusted-single-owner-LAN assumption as the rest of `LANRuntimeConfiguration` ([`2026-07-09-lan-site-runtime-design.md:64-66`](../../specs/2026-07-09-lan-site-runtime-design.md)).
- No continuous/live re-browsing — time-boxed scan only, per the locked decision above.
- No support for discovering hosts across subnets/VLANs — Bonjour/mDNS is link-local by nature; out of scope to work around.

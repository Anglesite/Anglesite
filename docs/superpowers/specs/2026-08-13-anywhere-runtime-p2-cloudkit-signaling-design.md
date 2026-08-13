# Anywhere Runtime P2 — CloudKit signaling, QR pairing, revocation UI

**Status:** Approved design (owner-reviewed 2026-08-13) — implementation plan to follow.
**Relates to:** [#1208](https://github.com/Anglesite/Anglesite/issues/1208) (epic), `docs/superpowers/specs/2026-08-03-anywhere-runtime-webrtc-design.md` (epic-level design, §Architecture 3, §Pairing and security), `docs/superpowers/plans/2026-08-10-anywhere-runtime-p1-mac-helper.md` (P1, merged via [PR #1405](https://github.com/Anglesite/Anglesite/pull/1405)).

## Problem

P1 shipped the Mac helper (`AnglesiteRemote`) with file-based signaling (`FileSignalingChannel`) — local dev/test infra only, explicitly documented as not a production rendezvous mechanism. P2 replaces it with the real cross-network signaling path the epic's design spec calls for: CloudKit private-database signaling, QR-code device pairing with key pinning, and a Settings UI to manage paired devices.

## Scope-setting findings (from codebase research, 2026-08-13)

Two things the epic-level design spec assumed are not actually true of the shipped P1 code, discovered before writing this design:

1. **The P1 helper has no `NSApplication` run loop.** The epic design's own rationale for making the helper "a real (faceless) app rather than a bare LaunchAgent binary" is "specifically so it can receive CloudKit push" — but `Sources/anglesite-remote-helper/main.swift` is a bare `Foundation` script (no `import AppKit`, no `NSApplicationDelegate`, no `NSApplication.shared.run()`). `registerForRemoteNotifications()` cannot be called at all without one. **Decision: fixing this is in scope for P2**, as its first task — a real, blocking prerequisite, not optional polish.
2. **No iOS client exists yet.** P4 ("iOS app v1") is a later phase. The epic design's P2 exit criterion, "two real devices pair and connect across networks," is literally unreachable right now — there is no phone to be the second real device. **Decision: P2's practical exit criterion is a two-Mac-process harness**, mirroring how P0 (two Mac processes, file signaling) and P1 (a second Mac process instead of a real phone) each already redefined their own exit criteria pragmatically. One process plays "Mac," one plays "phone" — the "phone" side consumes the QR payload as a string directly (no camera/image decode), the same way P1's E2E harness took `siteRoot` as a CLI argument instead of solving real cross-sandbox site discovery. Real CloudKit is used throughout (gated `ANGLESITE_CK_TESTS=1`) — only the QR *scan* step is simulated. The literal "real phone" proof is P4's job, once there's a phone.

Both decisions were confirmed with the owner before writing this design (see brainstorming session, 2026-08-13).

## Additional scope decisions (owner-approved, 2026-08-13)

- **Presence heartbeat** (design spec's Failure Modes: "Mac writes a lightweight presence heartbeat to CloudKit ~every 15 min") is built now, write-side only, even though nothing reads it yet (that's P4's job when a phone UI exists to render it).
- **CloudKit container:** reuses the existing `iCloud.io.dwk.anglesite` container (already used for iCloud Drive site storage) rather than a new dedicated one — one container, one entitlement to manage, no real isolation benefit from splitting since both live under the same Apple ID regardless.
- **Signing-layer architecture:** a `SignedSignalingChannel` decorator wraps *any* `SignalingChannel` conformer (see below) — not baked into `CloudKitSignalingChannel`, not an extension of P0's `SignalingEnvelope`. This was presented as a three-way choice (decorator / baked-in / envelope-extension) and the decorator was chosen because it matches P0's existing transport-agnostic layering and makes the adversarial pairing tests (tampered SDP, unknown key) runnable in CI without any CloudKit entitlement at all.

## Architecture

Seven pieces — six new, one fix to existing P1 code:

### 1. Helper `NSApplication` lifecycle fix

`Sources/anglesite-remote-helper/main.swift` gains a minimal `NSApplicationDelegate` + run loop, replacing its current bare-script structure. Everything the P1 session loop already does moves into `applicationDidFinishLaunching` (or is kicked off from there). No visible UI — `LSUIElement` is already set in `Resources/AnglesiteRemote-Info.plist`. This unblocks `registerForRemoteNotifications()`, which nothing calls yet either (that's part of wiring `CloudKitSignalingChannel` in, not this fix by itself).

### 2. `DevicePairingKeyPair` (`AnglesiteCore`)

A CryptoKit P-256 signing key pair, generated once per device, Keychain-persisted via the existing `SecretStore`/`KeychainStore` seam. Mirrors `DPoPKeyPair` exactly: `init()` generates fresh, `init?(persistedRepresentation:)` reconstructs, `persistedRepresentation: Data` exposes raw bytes for storage, plus a `publicKeyData: Data` (X9.63 uncompressed point — the format the QR payload and CloudKit records both use) and `sign(_:) -> Data` / a `static verify(signature:for:publicKeyData:) -> Bool`. New `SecretAccounts` slot (e.g. `devicePairingKey`) added alongside the existing DPoP-key slots.

### 3. `PairedDevice` + `PairedDeviceStore` (`AnglesiteCore`)

Mirrors `ACPAgentConnection`/`ACPAgentStore` exactly: a `Codable, Identifiable, Sendable, Equatable` `PairedDevice { id: UUID, deviceID: String, displayName: String, pinnedPublicKey: Data, pairedAt: Date, lastConnectedAt: Date? }`, persisted as JSON (`paired-devices.json`, same `Application Support/Anglesite/` location convention as `acp-agents.json`) via a plain (non-actor) `PairedDeviceStore` class with `load()`/`add(_:)`/`update(_:)`/`remove(id:)`. The pinned public key is not a secret (integrity, not confidentiality, is what matters), so it lives in the plain JSON record, not Keychain — matching the design spec's own framing ("The QR is the trust root; iCloud is just a mailbox").

### 4. `SignedSignalingChannel` (`AnglesiteP2P`)

```swift
public actor SignedSignalingChannel: SignalingChannel {
    public init(wrapping inner: any SignalingChannel, signingKey: DevicePairingKeyPair, peerPublicKey: Data)
    public func send(_ envelope: SignalingEnvelope) async throws
    public func envelopes() -> AsyncStream<SignalingEnvelope>
    public func close() async
}
```

Wraps only `SignalingEnvelope.payload` — `seq`/`sender`/`kind` stay in the clear so the inner channel's own delivery/ordering logic (see `FileSignalingChannel`'s per-sender seq buffering) keeps working unmodified. Wire format inside `payload`:

```json
{"payload": "<original SDP/ICE text>", "signature": "<base64 P-256 signature over payload>"}
```

`send` signs with `signingKey`, wraps, forwards to `inner`. `envelopes()` reverses: verifies against the single `peerPublicKey` this instance was constructed with (looked up from `PairedDeviceStore` *before* the channel is ever opened — an unpaired/unknown device never gets this far, see §Error handling). A bad or missing signature means that envelope is dropped from the stream entirely — never yielded to `WebRTCPeer` — logged loudly on the emitting side.

Fully testable today against `FileSignalingChannel` or a fake `SignalingChannel` — no CloudKit involved. This is where the adversarial pairing tests (tampered SDP, unknown key) live.

### 5. `CloudKitSignalingChannel` (`AnglesiteP2P`, Darwin-gated) + device-pairing CloudKit records

The real conformer. Private-database CKRecords, `CKQuerySubscription`-driven push delivery (falling back to polling if push registration isn't available — see §Error handling). Record schema:

- `SignalingEnvelopeRecord`: `seq` (Int64), `sender` (String), `kind` (String), `payload` (String), `sessionID` (String, so concurrent unrelated sessions in the same zone never cross-deliver). `CloudKitSignalingChannel` itself is signing-agnostic — it transports whatever `payload` string it's given, the same way `FileSignalingChannel` does. Production always constructs it wrapped in `SignedSignalingChannel` (§Data flow), so in practice `payload` always holds the signed-wrapper JSON; the channel type has no opinion about that itself, which is what keeps signing swappable/testable independent of the transport (§Architecture 4). CloudKit has no native TTL; the helper deletes records it has already delivered (acting as the "short TTL" the epic design calls for).
- `DeviceAnnounceRecord`: `deviceID` (String), `publicKey` (`Data`, X9.63), `displayName` (String), `createdAt` (Date) — the pairing handshake's own record type, distinct from signaling envelopes.
- `PresenceHeartbeatRecord`: one record per device, replaced in place each write — `lastSeenAt` (Date).

### 6. Settings UI

A 5th tab in the existing `SettingsView` `TabView` ("Anglesite on iPhone/iPad"), following the established `Form { Section { ... } }` house style:
- QR code (`CIFilter(name: "CIQRCodeGenerator")`) encoding `{macDeviceID, macPublicKey}` as its payload — generated fresh each time the pane is shown, not persisted.
- Paired-devices list mirroring `AgentsSettingsView`'s exact row pattern: name, last-connected time, Revoke button. `remove(_:)` deletes the `PairedDeviceStore` entry — no associated Keychain secret to clear (the pinned key isn't a secret), unlike `AgentsSettingsView`'s ACP-token cleanup.

### 7. Presence heartbeat writer

The helper writes/replaces its single `PresenceHeartbeatRecord` every ~15 min and on network-reachability change. Write-side only in this phase.

## Data flow

**Pairing (one-time per device):**
1. Owner opens the new Settings pane. `DevicePairingKeyPair` is generated if not already present, Keychain-persisted. The pane renders the QR code.
2. The phone scans it (P4) and writes its own `DeviceAnnounceRecord` to the shared CloudKit zone.
3. The helper, via `CKQuerySubscription` on `DeviceAnnounceRecord`, picks up the new record, pins the phone's public key into `PairedDeviceStore`, and writes its own `DeviceAnnounceRecord` back (confirming the exchange — the QR already gave the phone the Mac's key out-of-band).
4. Both sides hold each other's pinned public key. The Settings pane's device list updates.

**Signaling (every connection attempt, using an already-pinned key):**
1. Helper looks up the requesting device's pinned key in `PairedDeviceStore`. Unknown device → refused before any channel opens — this is where "the helper refuses unknown keys" (design spec) actually happens, not inside the signed channel itself.
2. `CloudKitSignalingChannel` opens, wrapped in `SignedSignalingChannel` keyed to that pinned key.
3. SDP/ICE flow as signed, short-TTL CKRecords. `WebRTCPeer` drives the handshake exactly as today, unaware signing is happening underneath.

**Presence heartbeat:** independent of any active session — write-only, per §Architecture 7.

## Error handling & security

- **Unknown device key** → refused at channel-construction time (signaling flow step 1), never reaches sign/verify.
- **Tampered SDP / bad signature** → silently dropped from the envelope stream (loud log, no distinct user-facing "attack" messaging — the caller just sees the same stall a network partition would produce, matching "the app advises; it does not delegate the decision").
- **Revoked device** → `PairedDeviceStore.remove` drops the pinned key immediately for *future* connection attempts. An already-open `SignedSignalingChannel` for that device holds its own copy of the key and is not torn down mid-session by a revocation — stated explicitly so it isn't assumed to kill a live session.
- **CloudKit/entitlement unavailable** (no iCloud sign-in, or the Apple Developer portal capability isn't provisioned yet — mirrors P1's own App-Groups gap) → code and tests work against injected seams regardless of production entitlement state; `CloudKitSignalingChannel`'s construction fails fast with an honest, owner-facing reason rather than crashing.
- **Push registration unavailable** (e.g. ad-hoc/Debug signing without the entitlement) → falls back to polling CloudKit, degrading latency only, never correctness.

## Testing strategy

- **Unit, no CloudKit:** `DevicePairingKeyPair` (mirrors `DPoPKeyPairTests`), `PairedDeviceStore` (mirrors `ACPAgentStore` tests), `SignedSignalingChannel` — including adversarial cases (tampered payload, wrong key) — against `FileSignalingChannel`/a fake.
- **Gated real-CloudKit:** `ANGLESITE_CK_TESTS=1` (matching the container-test env-var pattern) for `CloudKitSignalingChannel` against a real private DB.
- **Exit-criterion E2E:** `ANGLESITE_CK_TESTS=1 ANGLESITE_P2P_E2E=1` — two Mac processes, real CloudKit, one plays "Mac" (generates the QR payload), one plays "phone" (consumes that payload string directly, no image decode) — completes pairing, then a signed signaling handshake, then a live MCP round trip. This is P2's practical exit criterion (see §Scope-setting findings).
- **Adversarial pairing tests** (design spec's own testing section): tampered SDP, unknown device key, revoked device — all must refuse. Covered by the unit-level `SignedSignalingChannel` tests plus one gated E2E case for revocation specifically.

## Non-goals (this phase)

- The real iOS QR-scanning client — P4.
- Consuming the presence heartbeat in any UI — P4.
- TURN credential minting — P3.
- Publish-from-phone — P5.

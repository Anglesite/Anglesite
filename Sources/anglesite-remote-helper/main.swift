import Foundation
import AppKit
import AnglesiteCore
import AnglesiteContainer
import AnglesiteP2P
import AnglesiteRemote
#if canImport(ServiceManagement)
import ServiceManagement
#endif
#if canImport(CloudKit)
import CloudKit
#endif
#if canImport(Security)
import Security
#endif

// Anywhere runtime (#1208 P1) helper entry point: `anglesite-remote-helper session <signal-dir>
// <site-root>` accepts one P2P session over file signaling (matching P0's `anglesite-p2p-demo
// host` invocation shape), boots/reuses the site's container, and bridges the fetch, MCP, and
// control-heartbeat channels until the connection closes or the process receives SIGTERM.
//
// Anywhere runtime (#1208 P2) addition: a second, production invocation —
// `anglesite-remote-helper connect <session-id> <device-id> <site-id> [<expected-package-path>]`
// — which addresses a site by its *identity* rather than by a host filesystem path, refuses any
// device whose key this Mac has not pinned, and runs the handshake over a signed signaling channel
// (CloudKit-backed on a build entitled for it, a helper-local mailbox otherwise — see
// `makeSignalingTransport(sessionID:)`). See `HelperInvocation` for the two shapes and why P1's
// stays.

// Anywhere runtime (#1208 P2) addition: a real `NSApplication` run loop. P2 adds the run loop
// this file never had in P1 — a real gap: the design spec's own rationale for the helper being
// "a real (faceless) app rather than a bare LaunchAgent" is "specifically so it can receive
// CloudKit push" (design spec §Architecture 2), but `registerForRemoteNotifications()` cannot be
// called without an `NSApplication` event loop, which this file did not run until now. The
// session logic below is otherwise unchanged in substance — it is just driven from
// `applicationDidFinishLaunching` instead of running at file scope.
//
// `NSApplication.shared.run()` never returns on its own — the old top-level "fall off the end of
// main.swift" exit path is replaced by an explicit `exit(0)` at the end of `runSession()`,
// matching what `die(_:)` and the SIGTERM handler already did.

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Writes one line to this process's own log sink. Every branch below that degrades, refuses, or
/// falls back goes through here rather than failing quietly — "logs are sacred" (CLAUDE.md), and a
/// helper that silently downgraded its own signaling transport is exactly the kind of thing that
/// reads to an owner as "P2P is just broken".
func helperLog(_ message: String) {
    FileHandle.standardError.write(Data(("remote-helper: " + message + "\n").utf8))
}

// MARK: - CloudKit availability

/// The CloudKit container the whole Anywhere-runtime epic shares with iCloud Drive site storage
/// (design spec §Additional scope decisions: one container, one entitlement to manage).
let anglesiteCloudKitContainerIdentifier = "iCloud.io.dwk.anglesite"

/// Whether **this** process's own code signature actually carries the CloudKit capability for
/// `containerIdentifier` — answered by reading the process's entitlements directly, without
/// touching a single CloudKit API.
///
/// ## Why this check has to exist, and why it cannot be a `do`/`catch`
///
/// `CKContainer(identifier:)` does not throw, fail, or return `nil` on a binary that lacks the
/// CloudKit entitlement: it **traps the process** — SIGTRAP, no catchable Swift error, no crash
/// report, nothing after the call ever runs. That is documented in `CloudKitPairingService` and
/// `CloudKitSignalingChannel` (both of which had to grow an offline seam because of it), and it is
/// re-confirmed empirically for this task: a probe binary built against this SDK printed its
/// pre-flight line and then died with exit status 133 (128 + SIGTRAP) on the construction line,
/// both as a bare executable and inside a sandboxed `.app` bundle matching this helper's own
/// shape. The entitlement is **not provisioned in this repo today** (see
/// `Resources/AnglesiteRemote.entitlements`' own comment block — it needs an Apple Developer
/// portal change on Team `KH7H8Y25RT`), so an unconditional live construction here would crash the
/// helper on every single P2P session.
///
/// ## Why `SecTask` is safe to ask
///
/// `SecTaskCreateFromSelf` + `SecTaskCopyValueForEntitlement` read the entitlement dictionary out
/// of the running process's own code signature. They are Security.framework calls with no CloudKit
/// linkage whatsoever, so they cannot reach the trapping path no matter what the answer turns out
/// to be. Verified against this SDK in the helper's real deployment shape (a sandboxed, ad-hoc
/// signed `.app`): absent entitlements read back as `nil` and the process exits 0, an array-valued
/// entitlement bridges cleanly to `[String]`, and a boolean one reads back as `1`.
///
/// ## Why both keys are required
///
/// `com.apple.developer.icloud-container-identifiers` must *contain this container* (an
/// entitlement listing some other container does not make `CKContainer(identifier:)` safe for
/// ours), and `com.apple.developer.icloud-services` must contain `CloudKit` (the main app's
/// entitlements list only `CloudDocuments` today — enough for iCloud Drive site storage, not for
/// CloudKit). Requiring both makes the only reachable error a **false negative**, which degrades
/// to local signaling; a false positive would be a process abort.
///
/// A false positive is also not reachable by lying in an ad-hoc signature: this SDK's AMFI kills
/// (SIGKILL, exit 137) any locally-signed binary that claims a `com.apple.developer.*` entitlement
/// without a matching provisioning profile, so a *running* process that reports one necessarily
/// had it validated. That was confirmed by the same probe run.
func processCarriesCloudKitEntitlement(containerIdentifier: String) -> Bool {
    #if canImport(Security)
    guard let task = SecTaskCreateFromSelf(nil) else {
        helperLog("could not read this process's own entitlements; assuming CloudKit is unavailable")
        return false
    }
    let containers = SecTaskCopyValueForEntitlement(
        task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String]
    guard containers?.contains(containerIdentifier) == true else { return false }
    let services = SecTaskCopyValueForEntitlement(
        task, "com.apple.developer.icloud-services" as CFString, nil) as? [String]
    return services?.contains("CloudKit") == true
    #else
    return false
    #endif
}

// MARK: - Invocation

/// How this launch of the helper was asked to run one session.
///
/// Two shapes, deliberately — P1's is kept rather than replaced. `HelperContainerE2ETests` (the P1
/// exit criterion) spawns the helper with the `session` shape and drives the handshake through a
/// shared directory, which needs no pairing, no iCloud account, and no entitlement; deleting it to
/// make room for the production shape would trade a working end-to-end proof for nothing.
enum HelperInvocation {
    /// P1's local-only entry point: the site arrives as a host filesystem path and signaling runs
    /// through a shared directory, unsigned. Test/dev infra — `FileSignalingChannel`'s own doc
    /// comment says as much.
    case fileSignaling(signalDirectory: URL, siteRoot: URL)

    /// The production shape. Nothing here is a host path: the site is named by its
    /// `RemoteSiteIdentity` key and resolved through `RemoteSiteResolver` (bookmark or iCloud
    /// container), and the peer is named by its `deviceID`, whose signing key must already be
    /// pinned in `PairedDeviceStore` or the session is refused before anything opens.
    ///
    /// - `sessionID` scopes the signaling records so concurrent unrelated sessions in the same
    ///   private database never cross-deliver (`CloudKitSignalingChannel`'s own contract). Both
    ///   peers must agree on it out of band, which is why it is an input rather than something
    ///   this process invents.
    /// - `expectedPackageURL` only pre-targets the access-grant panel — best-effort UX, not a
    ///   security check (`RemoteSiteResolver.resolveSourceDirectory` says so itself). It is
    ///   optional for exactly that reason; see `defaultExpectedPackageURL(siteID:)`.
    case cloudKit(sessionID: String, deviceID: String, siteID: String, expectedPackageURL: URL)

    static let usage = """
        usage:
          anglesite-remote-helper session <signal-dir> <site-root>
          anglesite-remote-helper connect <session-id> <device-id> <site-id> [<expected-package-path>]
        """

    /// Parses `arguments` (a full `CommandLine.arguments`, argv[0] included). `nil` for anything
    /// that doesn't match one of the two shapes — the caller turns that into `usage`.
    static func parse(_ arguments: [String]) -> HelperInvocation? {
        guard arguments.count >= 2 else { return nil }
        switch arguments[1] {
        case "session" where arguments.count == 4:
            return .fileSignaling(
                signalDirectory: URL(fileURLWithPath: arguments[2], isDirectory: true),
                siteRoot: URL(fileURLWithPath: arguments[3], isDirectory: true))
        case "connect" where arguments.count == 5 || arguments.count == 6:
            let siteID = arguments[4]
            let expectedPackageURL = arguments.count == 6
                ? URL(fileURLWithPath: arguments[5], isDirectory: true)
                : defaultExpectedPackageURL(siteID: siteID)
            return .cloudKit(
                sessionID: arguments[2], deviceID: arguments[3], siteID: siteID,
                expectedPackageURL: expectedPackageURL)
        default:
            return nil
        }
    }

    /// Where to point the access-grant panel when the caller didn't say.
    ///
    /// A siteID is a package marker UUID (or a path digest — see `RemoteSiteIdentity`), so there is
    /// no way to *derive* the real package path from it; this is only a starting directory for the
    /// panel. It deliberately points under `~/Sites` (the non-iCloud fallback root, per
    /// `AppSettings.sitesRoot`) rather than at the iCloud container: a URL inside the ubiquity
    /// container would match `RemoteSiteResolver`'s iCloud fast path and make it return a
    /// confidently wrong `Source/` directory that never existed, instead of asking.
    static func defaultExpectedPackageURL(siteID: String) -> URL {
        FileManager.default.portableHomeDirectory
            .appendingPathComponent("Sites", isDirectory: true)
            .appendingPathComponent("\(siteID).anglesite", isDirectory: true)
    }
}

/// Everything one session needs that differs between the two invocation shapes, resolved before
/// the (minutes-long) container boot so a refusal costs nothing.
struct SessionPlan {
    /// The `RemoteSessionRegistry`/container-artifact key for this site.
    let siteID: String
    /// The site's `Source/` git repo on this host — supplied directly on the P1 path, resolved
    /// from `siteID` through `RemoteSiteResolver` on the production path.
    let siteRoot: URL
    /// Builds the channel `WebRTCPeer` will drive. Deferred behind a closure rather than built up
    /// front because constructing one starts reading the transport immediately —
    /// `SignedSignalingChannel` spins up its verifying forwarding task in `init`, which pulls
    /// `envelopes()` and so starts the inner channel's poll loop right there — and the container
    /// boot that sits between plan-building and `WebRTCPeer.connect` legitimately costs minutes.
    let makeSignalingChannel: @Sendable () -> any SignalingChannel
}

// MARK: - Building the production session plan

/// This helper's own `Application Support` directory. Under the sandbox this is the *helper's*
/// container, not the main app's — the same cross-bundle boundary `RemoteSessionRegistry` already
/// documents, and the reason `RemoteSiteResolver` keeps its own bookmark store rather than reading
/// the app's `recents.json`.
func helperApplicationSupportDirectory() -> URL {
    let base = (try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        ?? FileManager.default.portableHomeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("Anglesite", isDirectory: true)
}

/// This device's own signing identity, used to sign every outbound signaling payload.
///
/// Generated and Keychain-persisted on first use, mirroring what the Settings pane
/// (`DevicePairingSettingsView`) does on the main-app side — and, on a build entitled to the shared
/// keychain access group, reading the *same* Keychain item, so the key the owner's QR code
/// publishes is the key this process signs with (#1208 P2). This call site and
/// `DevicePairingSettingsView.generateQRCode()` must stay in step; one side alone only relocates
/// the mismatch.
///
/// **Not every build is so entitled.** `keychain-access-groups` needs a provisioning profile to
/// sign, so `Resources/AnglesiteRemote-Debug.entitlements` — the CI-safe default that keeps a
/// no-Apple-account clone building — omits it, and a Debug build falls into the ephemeral-key
/// branch below on every launch. On such a build, and for any peer that never saw this Mac's QR
/// code, the only way to learn the key this process actually signs with is this Mac's own
/// `DeviceAnnounceRecord`, which `startPairingObservation(signingKey:pairedDevices:)` publishes
/// with exactly this key. See `Resources/AnglesiteRemote.entitlements` ▸ step 2.
func helperSigningKey() -> DevicePairingKeyPair {
    let keychain = KeychainStore(accessGroup: KeychainStore.sharedPairingAccessGroup)
    do {
        if let existing = try keychain.readDevicePairingKeyPair() { return existing }
        let fresh = DevicePairingKeyPair()
        try keychain.writeDevicePairingKeyPair(fresh)
        helperLog("generated this helper's device pairing key")
        return fresh
    } catch {
        // An ephemeral key still signs correctly for the life of this session; it just won't match
        // anything a peer pinned earlier, so the peer will drop our envelopes and the handshake
        // will stall. Loud, not silent, for exactly that reason — and on a build without the
        // shared-access-group entitlement this is the *expected* path, not an anomaly: SecItem
        // rejects the access group above with errSecMissingEntitlement, which arrives here as
        // `KeychainStore.Error.unhandled(-34018)`.
        helperLog("device pairing key unavailable (\(error)); using an ephemeral key — a peer that pinned an earlier key will reject this session")
        return DevicePairingKeyPair()
    }
}

/// This helper's own stable device identifier — the record name its `DeviceAnnounceRecord` is
/// published under, and the string a peer uses to tell this Mac's announce apart from its own.
///
/// Generated once and persisted in this process's own `UserDefaults` domain, mirroring what
/// `DevicePairingSettingsView.ownDeviceID()` does on the main-app side. **It is still not the same
/// identifier, on any build.** `UserDefaults` is scoped per bundle ID unless the two bundles share
/// a *suite*, which needs the App Group capability still recorded as outstanding in
/// `Resources/AnglesiteRemote.entitlements`.
///
/// Do not read this as the same gap `helperSigningKey()` used to describe: that one was a *keychain
/// access group* and is closed (#1208 P2) on any build entitled to it. This one is a different
/// mechanism behind a different, still-unobtained entitlement, and closing the keychain half did
/// nothing for it. So a peer must keep learning this Mac's *helper* identity from the announce
/// record rather than from the QR code (see `startPairingObservation(signingKey:pairedDevices:)`).
func helperDeviceID() -> String {
    let defaults = UserDefaults.standard
    let key = "anglesite.remoteHelperDeviceID"
    if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
    let fresh = UUID().uuidString
    defaults.set(fresh, forKey: key)
    return fresh
}

/// The owner-facing name this Mac announces itself under, shown in the phone's paired-device list.
func helperDisplayName() -> String {
    Host.current().localizedName ?? "Mac"
}

// MARK: - Pairing observation

#if canImport(CloudKit)
/// Publishes this Mac's own `DeviceAnnounceRecord` and pins every *other* device that announces
/// itself — the Mac-side half of the design spec's pairing flow (§Data flow ▸ Pairing, step 3:
/// "the helper … picks up the new record, pins the phone's public key into `PairedDeviceStore`,
/// and writes its own `DeviceAnnounceRecord` back").
///
/// - Returns: whether observation actually started. `false` on a build with no CloudKit
///   entitlement, which is every build this repo produces today — see
///   `processCarriesCloudKitEntitlement(containerIdentifier:)`. The caller uses this to decide
///   whether waiting for a device to become paired could ever succeed.
///
/// ## Why this is trust-on-first-use, and why that is the accepted design
///
/// Nothing here checks an announce against a scanned QR payload, because on the Mac side there is
/// nothing to check it against: the QR only ever flows Mac → phone. The design spec accepts that
/// explicitly — the announce lands in the **owner's own private CloudKit database**, so writing one
/// already requires the owner's Apple ID. iCloud is the mailbox; the QR is the trust root for the
/// *phone's* view of this Mac, not for this Mac's view of the phone.
///
/// ## The one thing an announce cannot do: resurrect a revoked device
///
/// A revoke removes the row from `PairedDeviceStore`, but nothing in production withdraws the
/// peer's `DeviceAnnounceRecord` from CloudKit — so the stale announce is still there, and this
/// loop starts with an empty dedup set on every launch. Without a check, the next session would
/// silently re-pin the device the owner just revoked. `PairedDeviceStore.remove(id:)` therefore
/// records a revocation date, and `pinAnnouncedDevice` ignores any announce written at or before
/// it. See that method's doc comment for why the tombstone is dated rather than a plain deny-list.
///
/// ## Lifetime
///
/// The observation `Task` captures `service` strongly and never finishes on its own, which is what
/// keeps the actor (and therefore its poll loop and its `CKQuerySubscription`) alive for the life
/// of the process. `PairingServiceBox.shared` additionally holds it so
/// `HelperAppDelegate`'s `application(_:didReceiveRemoteNotification:)` can hand pushes back to it —
/// push is the latency optimization; the poll loop is the correctness floor (see
/// `CloudKitPairingService`'s own doc comment).
@discardableResult
func startPairingObservation(signingKey: DevicePairingKeyPair, pairedDevices: PairedDeviceStore) -> Bool {
    guard processCarriesCloudKitEntitlement(containerIdentifier: anglesiteCloudKitContainerIdentifier) else {
        helperLog("""
            pairing observation is off: this build's code signature does not carry the \
            \(anglesiteCloudKitContainerIdentifier) CloudKit entitlement (see \
            Resources/AnglesiteRemote.entitlements). Only a device whose key is already pinned in \
            paired-devices.json can open a session with this Mac.
            """)
        return false
    }
    let service = CloudKitPairingService(
        container: CKContainer(identifier: anglesiteCloudKitContainerIdentifier))
    PairingServiceBox.shared.service = service
    let ownDeviceID = helperDeviceID()
    let publicKeyData = signingKey.publicKeyData
    let displayName = helperDisplayName()
    Task {
        do {
            try await service.announce(
                deviceID: ownDeviceID, publicKeyData: publicKeyData, displayName: displayName)
            // Deliberately stable and parseable: this is how a peer that never saw this Mac's QR
            // code (the P2 two-process harness, and any peer whose Mac runs a build without the
            // shared-access-group entitlement — see `helperSigningKey()`) learns which announce
            // record carries the key this process actually signs with.
            helperLog("announced this Mac as device \(ownDeviceID) (\(displayName))")
        } catch {
            helperLog("""
                could not announce this Mac (\(error)); a peer that has not already pinned this \
                Mac's key has no way to verify the envelopes this process signs
                """)
        }
        for await announce in service.announcedDevices() where announce.deviceID != ownDeviceID {
            pinAnnouncedDevice(announce, into: pairedDevices)
        }
    }
    return true
}

/// Records one observed announce in `pairedDevices`, or explains why it wasn't. See
/// `startPairingObservation(signingKey:pairedDevices:)` for the trust model this implements.
///
/// Three outcomes: a device that isn't pinned yet is pinned; one that is pinned under a *different*
/// public key has that key replaced (the design spec's "pins the phone's public key" makes no
/// first-pin/re-pin distinction, and a phone that reinstalls or regenerates its identity must be
/// able to re-pair without the owner doing anything); and one whose announce predates a revocation
/// is ignored entirely.
func pinAnnouncedDevice(_ announce: DeviceAnnounceRecord, into pairedDevices: PairedDeviceStore) {
    do {
        // Ahead of every other branch: a revoked device must not be resurrected by *any* path,
        // whether it is currently absent from the store (the normal case after a revoke) or was
        // re-added since. `<=` rather than `<` because a same-instant announce is, by the only
        // ordering this Mac can observe, not newer than the revocation.
        if let revokedAt = try pairedDevices.revocationDate(deviceID: announce.deviceID),
           announce.createdAt <= revokedAt {
            helperLog("""
                ignoring an announce from revoked device \(announce.deviceID) \
                (\(announce.displayName)): it was written \(announce.createdAt), before this Mac \
                revoked it \(revokedAt). Pair the device again from Anglesite ▸ Settings ▸ \
                iPhone/iPad to have it announce itself afresh.
                """)
            return
        }
        if let existing = try pairedDevices.device(deviceID: announce.deviceID) {
            guard existing.pinnedPublicKey != announce.publicKeyData else { return }
            var rotated = existing
            rotated.pinnedPublicKey = announce.publicKeyData
            rotated.displayName = announce.displayName
            try pairedDevices.update(rotated)
            helperLog("device \(announce.deviceID) (\(announce.displayName)) announced a new public key; pinned it in place of the previous one")
            return
        }
        try pairedDevices.add(PairedDevice(
            deviceID: announce.deviceID, displayName: announce.displayName,
            pinnedPublicKey: announce.publicKeyData, pairedAt: Date()))
        helperLog("pinned newly announced device \(announce.deviceID) (\(announce.displayName))")
    } catch {
        helperLog("could not pin announced device \(announce.deviceID): \(error)")
    }
}

/// Hands the live `CloudKitPairingService` to the `NSApplicationDelegate`, which is the only
/// place a CloudKit push is delivered and is not otherwise on speaking terms with the session task
/// that built the service.
///
/// `@unchecked Sendable`: the single stored property is guarded by `lock`. A global rather than a
/// delegate property because `startPairingObservation` runs off the main actor, inside `runSession`.
final class PairingServiceBox: @unchecked Sendable {
    static let shared = PairingServiceBox()
    private let lock = NSLock()
    private var stored: CloudKitPairingService?

    var service: CloudKitPairingService? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
#endif

/// How long a `connect` waits for the requested device's announce to land before refusing.
///
/// A connect request and the announce that pairs the device can legitimately race: a freshly
/// scanned phone writes both, and CloudKit orders neither. Waiting is only ever attempted when
/// pairing observation actually started (see `startPairingObservation(signingKey:pairedDevices:)`);
/// on a build that cannot observe announces at all, an unpaired device is still refused instantly,
/// because no amount of waiting could change the answer.
let pairingWaitTimeout: Duration = .seconds(90)

/// How many times the grant panel is re-shown after the owner picks the wrong site. Two, not one:
/// the first mismatch is an honest mistake worth a second try with an explanation, and an owner who
/// misses twice is better served by the session failing than by a third identical panel.
let siteAccessPanelAttemptLimit = 2

/// Shows the one-time access-grant panel for a site this helper has no bookmark for, and confirms
/// that what the owner picked is *actually the site that was asked for*.
///
/// This is `RemoteSiteResolver`'s documented production `presentOpenPanel`, and it is only
/// possible at all because the helper now runs a real `NSApplication` (#1208 P2 Task 1) — a bare
/// LaunchAgent could not put a panel on screen. Mirrors `SiteActions.reauthorize`'s panel
/// configuration exactly (`.anglesiteSite` content type, packages opaque, "Grant Access" prompt),
/// with a message phrased about the consequence to the owner's site rather than about bookmarks or
/// sandboxing ("the app advises; it does not delegate the decision", CLAUDE.md).
///
/// ## Why the identity check, and why it is not optional
///
/// It also mirrors what `reauthorize` does *after* the panel — `SiteActions.swift`'s
/// `guard markerMatches(package, expectedID: site.id)`, added under #1208's sibling issue #776
/// against "silently rebinding to an unrelated package that happens to share a name". This call
/// site needs it more, not less, because nothing downstream would ever catch the mistake: a wrong
/// pick here is bookmarked by `RemoteSiteResolver` **under the correct siteID** and persisted, so
/// every later session resolves it from cache without ever asking again. The helper would boot a
/// container from the wrong repo and commit the phone's edits into another site's git history,
/// with the phone showing no sign anything is wrong. There is no owner sitting in front of this
/// process to notice.
///
/// The comparison is against `RemoteSiteIdentity.siteID(forSourceDirectory:)`, which is the exact
/// function that produced the `siteID` string `connect` was invoked with — for a real `.anglesite`
/// package that is the package marker's UUID, so this compares stable identity, not paths or names.
/// A directory that isn't a recognizable package falls back to a path digest, which will simply not
/// match and is refused: the safe direction.
@Sendable func presentSiteAccessPanel(for expectedPackageURL: URL, expecting siteID: String) async -> URL? {
    for attempt in 1...siteAccessPanelAttemptLimit {
        let mismatched = attempt > 1
        let picked = await MainActor.run { () -> URL? in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowedContentTypes = [.anglesiteSite]
            panel.treatsFilePackagesAsDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = expectedPackageURL.deletingLastPathComponent()
            panel.prompt = String(localized: "Grant Access")
            panel.message = mismatched
                ? String(localized: "That’s a different site than the one your iPhone or iPad asked to edit. Choose the site it’s expecting, so its changes don’t land in the wrong place.")
                : String(localized: "Locate this site so it can be edited from your iPhone or iPad while this Mac is unattended.")
            // A faceless (`LSUIElement`) helper is not the front app, so its panel would otherwise
            // open behind whatever the owner is actually looking at.
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
        guard let picked else { return nil }

        let pickedSiteID = RemoteSiteIdentity.siteID(
            forSourceDirectory: picked.appendingPathComponent("Source", isDirectory: true))
        if pickedSiteID == siteID { return picked }
        helperLog("""
            \(picked.lastPathComponent) is site \(pickedSiteID), not the requested \(siteID) — \
            refusing to bookmark it (attempt \(attempt) of \(siteAccessPanelAttemptLimit))
            """)
    }
    helperLog("no matching site was chosen for \(siteID); the session will be refused rather than bound to the wrong site")
    return nil
}

/// Waits (bounded by `timeout`) for `deviceID` to appear in `pairedDevices`, or exits with an
/// owner-facing reason. A `timeout` of `.zero` degenerates to the single immediate lookup this
/// used to do, which is exactly what a build that cannot observe announces should still do.
///
/// Polls rather than observing the store: `PairedDeviceStore` is a plain JSON file with no change
/// notification (by design — it is touched at pairing events and Settings edits, not in a loop),
/// and the writer here is a task in this same process, so a one-second poll is both sufficient and
/// simpler than inventing a notification seam for one call site.
func awaitPairedDevice(
    deviceID: String, in pairedDevices: PairedDeviceStore, sessionID: String, timeout: Duration
) async -> PairedDevice {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var announcedWaiting = false
    while true {
        do {
            if let device = try pairedDevices.device(deviceID: deviceID) { return device }
        } catch {
            die("refusing session \(sessionID): could not read this Mac's paired devices: \(error)")
        }
        guard ContinuousClock.now < deadline else {
            die("""
                refusing session \(sessionID): device \(deviceID) is not paired with this Mac, so \
                there is no pinned key to verify it against. Pair it first from Anglesite ▸ \
                Settings ▸ iPhone/iPad.
                """)
        }
        if !announcedWaiting {
            announcedWaiting = true
            helperLog("device \(deviceID) is not paired yet; waiting for its announce")
        }
        try? await Task.sleep(for: .seconds(1))
    }
}

/// Builds the production session plan, or exits with an owner-facing reason.
///
/// Order matters: the pinned-key lookup happens *first*, so an unpaired device is refused before
/// this process resolves a file grant or boots a VM for it (design spec §Error handling — "refused
/// at channel-construction time", and the flow's step 1 sits ahead of everything else).
///
/// Pairing observation starts just ahead of that lookup rather than after it: on the design spec's
/// own flow the announce that pairs a device and the connect request that uses it can arrive in
/// either order, so this process has to be listening before it decides the device is unknown.
func makeCloudKitSessionPlan(
    sessionID: String, deviceID: String, siteID: String, expectedPackageURL: URL
) async -> SessionPlan {
    // Resolved once, up front, and deliberately not lazily: the same key must both sign this Mac's
    // announce and sign its signaling envelopes, and `helperSigningKey()`'s error path mints a
    // *fresh ephemeral* key — so two calls could publish one key and sign with another, which is
    // strictly worse than the (idempotent, first-use-only) Keychain touch this costs on the
    // refusal path below.
    let signingKey = helperSigningKey()
    let pairedDevices = PairedDeviceStore()

    // `false` (today, on every build this repo produces) means no announce can ever arrive, so an
    // unpaired device is refused immediately instead of stalling for `pairingWaitTimeout` first.
    var pairingIsObservable = false
    #if canImport(CloudKit)
    pairingIsObservable = startPairingObservation(signingKey: signingKey, pairedDevices: pairedDevices)
    #endif
    let pinned = await awaitPairedDevice(
        deviceID: deviceID, in: pairedDevices, sessionID: sessionID,
        timeout: pairingIsObservable ? pairingWaitTimeout : .zero)
    helperLog("device \(deviceID) (\(pinned.displayName)) is paired; its key is pinned")

    let resolver = RemoteSiteResolver(
        bookmarkStore: RemoteBookmarkStore(
            fileURL: helperApplicationSupportDirectory()
                .appendingPathComponent("remote-site-bookmarks.json")),
        bookmarking: PlatformSecurityScopedBookmark.make(),
        // `presentOpenPanel`'s signature is `(URL) async -> URL?`, so the expected siteID — which
        // the panel needs in order to confirm the owner picked the right package — is closed over
        // rather than passed. It is a plain `String` captured by value, so the closure stays
        // `@Sendable`.
        presentOpenPanel: { expectedPackageURL in
            await presentSiteAccessPanel(for: expectedPackageURL, expecting: siteID)
        })
    let siteRoot: URL
    do {
        siteRoot = try await resolver.resolveSourceDirectory(
            siteID: siteID, expectedPackageURL: expectedPackageURL)
    } catch {
        die("refusing session \(sessionID): this Mac has no access to site \(siteID): \(error)")
    }
    helperLog("resolved site \(siteID) to \(siteRoot.path)")

    let pinnedPublicKey = pinned.pinnedPublicKey
    return SessionPlan(siteID: siteID, siteRoot: siteRoot, makeSignalingChannel: {
        SignedSignalingChannel(
            wrapping: makeSignalingTransport(sessionID: sessionID),
            signingKey: signingKey, peerPublicKey: pinnedPublicKey,
            onLog: { helperLog("signaling: \($0)") })
    })
}

/// The transport `SignedSignalingChannel` wraps on the production path: real CloudKit when this
/// binary is actually entitled for it, and a helper-local directory mailbox when it is not.
///
/// The fallback is a deliberate, precedented degradation rather than a hard failure — it is the
/// same shape P1 already uses for `RemoteSessionRegistry` when the App Group isn't provisioned. It
/// costs cross-network rendezvous (both peers must be processes on this Mac, which is exactly what
/// P2's own two-Mac-process exit criterion is), and it costs nothing else: the signing and
/// key-pinning layer above it is live either way, so the security half of this task is genuinely
/// exercised on a build with no CloudKit entitlement at all.
@Sendable func makeSignalingTransport(sessionID: String) -> any SignalingChannel {
    #if canImport(CloudKit)
    if processCarriesCloudKitEntitlement(containerIdentifier: anglesiteCloudKitContainerIdentifier) {
        helperLog("signaling over CloudKit container \(anglesiteCloudKitContainerIdentifier) (session \(sessionID))")
        return CloudKitSignalingChannel(
            container: CKContainer(identifier: anglesiteCloudKitContainerIdentifier),
            sessionID: sessionID, sender: "helper")
    }
    #endif
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("anglesite-remote-signaling", isDirectory: true)
        .appendingPathComponent(sessionID, isDirectory: true)
    helperLog("""
        CloudKit is not available to this build — its code signature does not carry the \
        \(anglesiteCloudKitContainerIdentifier) CloudKit entitlement (an Apple Developer portal \
        step this repo has not taken yet; see Resources/AnglesiteRemote.entitlements). Falling \
        back to local directory signaling at \(directory.path): signing and key pinning still \
        apply, but only a peer running on this Mac can reach this session.
        """)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        helperLog("local signaling directory creation failed: \(error)")
    }
    return FileSignalingChannel(directory: directory, sender: "helper")
}

@MainActor
final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The whole reason this helper is a faceless app rather than a bare LaunchAgent (design
        // spec §Architecture 2): only a registered `NSApplication` can receive the silent APNs
        // pushes CloudKit's `CKQuerySubscription` sends, which is what wakes this process when a
        // peer announces itself with the main app closed. Registration is a no-op-with-a-log on a
        // build whose CloudKit entitlement isn't provisioned yet (#1208 P2's manual portal step) —
        // `CloudKitPairingService` polls regardless, so pairing still works, just slower.
        NSApplication.shared.registerForRemoteNotifications()
        Task { await runSession() }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        // The AppKit shape, deliberately: macOS's delegate callback takes no completion handler
        // (that is UIKit's `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`),
        // so there is nothing to call back and the handler must return promptly.
        //
        // Routing: this is the seam where a CloudKit push reaches whichever service is listening.
        //
        // - `CloudKitPairingService` owns the only subscription in this epic, and (as of #1208 P2
        //   Task 10) this process does construct one — see `startPairingObservation`. Its
        //   `handleRemoteNotification(_:)` claims the payload if the push is for its subscription
        //   and kicks off an immediate re-query, which is the whole point of this helper being a
        //   faceless *app*: APNs can wake it when a peer announces itself. It is a latency
        //   optimization over the service's own poll loop, never a correctness requirement.
        // - `CloudKitSignalingChannel` is also constructed by this process (see
        //   `makeSignalingTransport(sessionID:)`), but it deliberately registers no subscription
        //   and polls only — its own doc comment explains why (a signaling session is seconds
        //   long, and a per-session subscription would leave server-side litter). So there is no
        //   signaling push to route.
        //
        // The consequence, stated rather than hidden: a push only reaches the pairing service if
        // one exists, and one is built inside `makeCloudKitSessionPlan` — i.e. only once a
        // `connect` invocation is already under way. Nothing in this process wakes an idle helper
        // for a plain *reconnect* from an already-paired device. The helper has to already be
        // running (login item) for a session to be served. Closing that gap needs a wake trigger
        // this phase does not define.
        #if canImport(CloudKit)
        let subscriptionID = CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID
        let claimed = PairingServiceBox.shared.service?.handleRemoteNotification(userInfo) ?? false
        #else
        let subscriptionID: String? = nil
        let claimed = false
        #endif
        helperLog("CloudKit push received (subscription \(subscriptionID ?? "unknown"), routed: \(claimed))")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Logs are sacred (CLAUDE.md): a helper that silently failed APNs registration and quietly
        // fell back to polling is exactly the kind of thing that reads as "P2P is just slow".
        helperLog("APNs registration failed, CloudKit push unavailable: \(error)")
    }
}

func runSession() async {
    #if canImport(ServiceManagement)
    do {
        try SMAppServiceLoginItem().register()
    } catch {
        FileHandle.standardError.write(Data("login item registration failed: \(error)\n".utf8))
    }
    #endif

    guard let invocation = HelperInvocation.parse(CommandLine.arguments) else {
        die(HelperInvocation.usage)
    }
    let plan: SessionPlan
    switch invocation {
    case let .fileSignaling(signalDirectory, root):
        // NOT `root.lastPathComponent`: `<site-root>` is a site's `Source/` git repo, so that is the
        // literal string "Source" for every site on the machine — and this key names both the
        // registry claim file and the container's on-disk boot artifacts. See `RemoteSiteIdentity`.
        plan = SessionPlan(
            siteID: RemoteSiteIdentity.siteID(forSourceDirectory: root), siteRoot: root,
            makeSignalingChannel: { FileSignalingChannel(directory: signalDirectory, sender: "helper") })
    case let .cloudKit(sessionID, deviceID, siteID, expectedPackageURL):
        plan = await makeCloudKitSessionPlan(
            sessionID: sessionID, deviceID: deviceID, siteID: siteID,
            expectedPackageURL: expectedPackageURL)
    }
    let siteID = plan.siteID
    let siteRoot = plan.siteRoot

    // Production wiring of RemoteSessionRegistry at a *shared* (App Group) location is blocked on an
    // owner-side provisioning-portal change (see the plan's Task 2/5 manual note); until then this
    // falls back to a helper-local temp directory, which degrades "one owner per site" to "one owner
    // per site among helper-only sessions" — an accepted, explicitly-logged P1 limitation.
    let registryDir = FileManager.default.temporaryDirectory.appendingPathComponent("anglesite-remote-sessions")
    do {
        try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
    } catch {
        FileHandle.standardError.write(Data("registry directory creation failed: \(error)\n".utf8))
    }
    let control = ContainerizationControl()
    let containerSession = RemoteContainerSession(
        control: control,
        registry: RemoteSessionRegistry(directory: registryDir))

    let session: LocalContainerSession
    do {
        session = try await containerSession.ensureRunning(
            siteID: siteID, sourceRepo: siteRoot, ref: "HEAD",
            onOutput: { line, stream in FileHandle.standardError.write(Data(("[\(stream)] " + line + "\n").utf8)) })
    } catch {
        die("container boot failed: \(error)")
    }

    // Lifecycle markers on stderr, alongside the guest's own `[stdout]`/`[stderr]` lines. Logs are
    // sacred (CLAUDE.md), and until now this process reported nothing about its *own* state — the
    // guest chatter stops after boot and a session waiting for a peer looked identical to a hung one.
    // `HelperContainerE2ETests` also uses the first marker as its sync point: it waits for it before
    // offering, so the client never trickles ICE into a directory nobody is polling yet.
    helperLog("container ready (preview \(session.previewURL), mcp \(session.mcpURL)); waiting for peer")

    let peer: WebRTCPeer
    do {
        peer = try await WebRTCPeer.connect(role: .answerer, signaling: plan.makeSignalingChannel())
    } catch {
        await containerSession.tearDown(siteID: siteID)
        die("P2P connect failed: \(error)")
    }
    helperLog("peer connected; bridging")

    let httpBridge = FetchBridgeServer(connection: peer, executor: LoopbackHTTPExecutor(baseURL: session.previewURL))
    let mcpBridge = LoopbackMCPBridge(mcpURL: session.mcpURL)
    // Persistence only runs for a container THIS process booted — a borrowed claim (another
    // process's container) has no in-process VM handle `control.exec` can reach (see
    // ContainerEditExport's doc comment). `await` is fine here: `isOwner` only reads actor state
    // already settled by the `ensureRunning` call above, no I/O.
    let mcpHandler: MCPChannelResponder.Handler
    if await containerSession.isOwner(siteID: siteID) {
        let persister = HelperEditPersister(
            wrapping: { message in await mcpBridge.handle(message) },
            siteID: siteID, control: control, sourceDirectory: siteRoot,
            onLog: { line, stream in FileHandle.standardError.write(Data(("[\(stream)] " + line + "\n").utf8)) })
        mcpHandler = { message in await persister.handle(message) }
    } else {
        helperLog("bridging a borrowed container — edits will not be persisted by this process")
        mcpHandler = { message in await mcpBridge.handle(message) }
    }
    let mcpResponder = MCPChannelResponder(connection: peer, handler: mcpHandler)
    let heartbeat = ControlHeartbeat(connection: peer, interval: .seconds(10), missLimit: 6, onMiss: { count in
        if count >= 6 { FileHandle.standardError.write(Data("control link presumed dead\n".utf8)) }
    })

    // Presence heartbeat writer — still deferred (#1208 P2 → P3), but no longer blocked on a
    // mechanism. Task 7 defines PresenceHeartbeatWriter (write-side only, tested with injection);
    // its production wiring was deferred because `CKContainer(identifier:)` SIGTRAPs on binaries
    // lacking the CloudKit entitlement. `processCarriesCloudKitEntitlement(containerIdentifier:)`
    // above is now the safe gate for exactly that, so wiring this is a small, mechanical change
    // whenever the epic wants it — deliberately left out of Task 9's diff because nothing reads a
    // presence record until P4 gives a phone somewhere to render it, so shipping it now would add a
    // periodic CloudKit write with no consumer. When it is wired, it belongs behind the same gate:
    //
    //   guard processCarriesCloudKitEntitlement(
    //       containerIdentifier: anglesiteCloudKitContainerIdentifier) else { ... }
    //
    //   let presenceWriter = PresenceHeartbeatWriter(save: { date in
    //       let container = CKContainer(identifier: "iCloud.io.dwk.anglesite")
    //       let database = container.privateCloudDatabase
    //       let record = CKRecord(recordType: "PresenceHeartbeatRecord",
    //                            recordID: CKRecord.ID(recordName: "presence"))
    //       record["lastReachableAt"] = date
    //       let (saveResults, _) = try await database.modifyRecords(
    //           saving: [record], deleting: [], savePolicy: .changedKeys, atomically: true)
    //       for (_, result) in saveResults { _ = try result.get() }
    //   })
    //
    // and add `async let presenceTask: Void = presenceWriter.run()` to the task group below.

    // A raw C `signal()` handler can't safely call async Swift code (tearDown/peer.close() are
    // actor-isolated), so route SIGTERM through a DispatchSourceSignal instead: it delivers on a
    // normal GCD queue, which is a safe place to kick off a `Task` that closes the peer (letting the
    // `async let`s below unwind naturally) and tears the container session down before exiting.
    // `signal(SIGTERM, ...)` first blocks the default disposition (immediate termination) so the
    // dispatch source is the only thing that actually observes the signal. The source itself must be
    // retained for the process lifetime — GCD sources stop firing if deallocated — hence keeping it
    // as a `let` local here rather than a throwaway expression: `runSession()` is a long-lived async
    // function that doesn't return until teardown, so this local's lifetime spans the source's whole
    // useful lifetime, the same guarantee the old top-level `let` gave for the whole process.
    //
    // A non-capturing closure handler is used instead of `SIG_IGN` deliberately, matching
    // `ProcessSupervisor.swift`'s own `ignoreSIGPIPE` precedent: the Swift-vended `Darwin.SIG_IGN`
    // constant is exported from the `libswift_DarwinFoundation3` overlay, which some of this repo's
    // CI images don't ship — referencing it can make a binary fail to load ("Library not loaded:
    // libswift_DarwinFoundation3.dylib"). The closure form avoids adding *this file's own*
    // reference to that symbol. Note this target still ends up linking the dylib regardless, via
    // `AnglesiteContainer`'s `apple/containerization` dependency (`ContainerizationOS/
    // AsyncSignalHandler.swift` references `SIG_IGN` directly) — a pre-existing characteristic
    // already shared by `AnglesiteContainerProbe`, not something this file can avoid on its own.
    signal(SIGTERM, { _ in })
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource.setEventHandler {
        Task {
            await peer.close()
            await containerSession.tearDown(siteID: siteID)
            exit(0)
        }
    }
    sigtermSource.resume()

    async let httpTask: Void = httpBridge.run()
    async let mcpTask: Void = mcpResponder.run()
    async let heartbeatTask: Void = heartbeat.run()
    _ = await (httpTask, mcpTask, heartbeatTask)

    await containerSession.tearDown(siteID: siteID)
    exit(0)
}

// `main.swift` top-level code has no actor isolation the compiler can see, but this file's very
// first instruction runs on the process's initial (main) thread by definition — the same
// guarantee `MainActor.assumeIsolated` exists to assert under Swift 6's strict concurrency
// checking, which is what actually surfaces this: `HelperAppDelegate`'s implicit `@MainActor`
// init is otherwise a main-actor-isolated call from a synchronous nonisolated context. Unrelated
// to #1208 P2 Task 8 — this is a pre-existing gap in Task 1's `NSApplication` run-loop addition
// that this build was simply the first to exercise via the full Xcode app scheme (prior tasks
// only ran `swift build`, whose default settings didn't catch it).
let delegate = MainActor.assumeIsolated { HelperAppDelegate() }
let app = NSApplication.shared
app.delegate = delegate
app.run()

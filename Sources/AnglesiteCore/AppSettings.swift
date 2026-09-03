import Foundation

/// User-configurable app settings, backed by `UserDefaults`.
///
/// Defined here in AnglesiteCore so non-UI code (e.g. `TemplateRuntime`) can read settings without
/// pulling in SwiftUI. The Settings UI in AnglesiteApp uses SwiftUI's `@AppStorage` against the
/// same keys, so changes are reactive without `AppSettings` needing to be `@Observable`.
public final class AppSettings: @unchecked Sendable {
    /// Shared instance bound to `UserDefaults.standard`. App code should use this; tests should
    /// construct their own instance with a scratch `UserDefaults` suite.
    public static let shared = AppSettings(defaults: .standard)

    /// UserDefaults keys. Public so the SwiftUI side can use them with `@AppStorage`.
    public enum Key {
        /// Backs ``AppSettings/templatePathOverride``.
        public static let templatePathOverride = "anglesite.templatePathOverride"
        /// Backs ``AppSettings/sitesRootOverride``.
        public static let sitesRootOverride    = "anglesite.sitesRootOverride"
        /// Host component of ``AppSettings/lanRuntimeConfiguration``; empty/absent means no
        /// LAN runtime is configured.
        public static let lanRuntimeHost        = "anglesite.lanRuntimeHost"
        /// Preview-port component of ``AppSettings/lanRuntimeConfiguration``. Stored as a string
        /// (the Settings text field's empty state means "default").
        public static let lanRuntimePreviewPort = "anglesite.lanRuntimePreviewPort"
        /// MCP-port component of ``AppSettings/lanRuntimeConfiguration``. Stored as a string
        /// (the Settings text field's empty state means "default").
        public static let lanRuntimeMCPPort     = "anglesite.lanRuntimeMCPPort"
        /// Backs ``AppSettings/debugPaneEnabled``.
        public static let debugPaneEnabled   = "anglesite.debugPaneEnabled"
        /// Backs ``AppSettings/botPreferenceSyncUIEnabled``.
        public static let botPreferenceSyncUIEnabled = "anglesite.botPreferenceSyncUIEnabled"
        /// Backs ``AppSettings/esiPreviewUnprocessed``.
        public static let esiPreviewUnprocessed = "anglesite.esiPreviewUnprocessed"
        /// Backs ``AppSettings/lastOpenedSiteID``.
        public static let lastOpenedSiteID   = "anglesite.lastOpenedSiteID"
        /// Backs ``AppSettings/sitesRootBookmark``.
        public static let sitesRootBookmark  = "anglesite.sitesRootBookmark"
        /// Backs ``AppSettings/autoGenerateAltText``.
        public static let autoGenerateAltText = "anglesite.autoGenerateAltText"
        /// Backs ``AppSettings/autoGeneratePageCopy``.
        public static let autoGeneratePageCopy = "anglesite.autoGeneratePageCopy"
        /// Backs ``AppSettings/announcesLiveUpdates``.
        public static let announcesLiveUpdates = "anglesite.announcesLiveUpdates"
        /// Backs ``AppSettings/notifiesOnCompletion``.
        public static let notifiesOnCompletion = "anglesite.notifiesOnCompletion"
        /// Backs ``AppSettings/playsDialupSoundEffect``.
        public static let playsDialupSoundEffect = "anglesite.playsDialupSoundEffect"
        /// One-shot flag consumed by ``AppSettings/removeLegacyChatBackendDefaultsIfNeeded()`` so
        /// the legacy-key cleanup runs exactly once per defaults suite.
        public static let didCleanLegacyChatBackendDefaults = "anglesite.didCleanLegacyChatBackendDefaults"
        /// Login component of ``AppSettings/gitHubAccount``; its presence is what makes the
        /// composite non-`nil`.
        public static let gitHubAccountLogin = "anglesite.gitHubAccount.login"
        /// Display-name component of ``AppSettings/gitHubAccount``.
        public static let gitHubAccountName = "anglesite.gitHubAccount.name"
        /// Avatar-URL component of ``AppSettings/gitHubAccount``.
        public static let gitHubAccountAvatarURL = "anglesite.gitHubAccount.avatarURL"
        /// Verified flag for ``AppSettings/cloudflareAccount`` — the gate for the composite,
        /// since a verified token may legitimately carry no name/email to show.
        public static let cloudflareAccountVerified = "anglesite.cloudflareAccount.verified"
        /// Account-name component of ``AppSettings/cloudflareAccount``.
        public static let cloudflareAccountName = "anglesite.cloudflareAccount.name"
        /// Account-email component of ``AppSettings/cloudflareAccount``.
        public static let cloudflareAccountEmail = "anglesite.cloudflareAccount.email"
        /// Backs ``AppSettings/activeAssistantBackend``.
        public static let activeAssistantBackend = "anglesite.activeAssistantBackend"
        /// Backs ``AppSettings/communitySearchInstance``.
        public static let communitySearchInstance = "anglesite.communitySearchInstance"
        /// Backs ``AppSettings/externalLLMBaseURL`` (#1482).
        public static let externalLLMBaseURL = "anglesite.externalLLM.baseURL"
        /// Backs ``AppSettings/externalLLMModel`` (#1482).
        public static let externalLLMModel   = "anglesite.externalLLM.model"
        /// Backs ``AppSettings/externalLLMVerifiedBaseURL`` (#1482).
        public static let externalLLMVerifiedBaseURL = "anglesite.externalLLM.verifiedBaseURL"
        /// Backs ``AppSettings/externalLLMVerifiedDetail`` (#1482).
        public static let externalLLMVerifiedDetail = "anglesite.externalLLM.verifiedDetail"
        /// Backs ``AppSettings/lastUsedFileLicenseSelection`` (#999).
        public static let lastUsedFileLicenseSelection = "anglesite.lastUsedFileLicenseSelection"
        /// Slice-1 rollout gate for the AppKit site-window shell (`SiteShellFlag`, #1699 Stage 3
        /// design §Rollout): off by default so `main` keeps shipping the legacy
        /// `NavigationSplitView` chrome; enabled per-machine via defaults or per-launch via
        /// `ANGLESITE_APPKIT_SHELL=1`. Deleted in slice 3 when the shell becomes the only chrome.
        public static let appKitShellEnabled = "experimental.appKitShell"
    }

    private enum LegacyKey {
        static let preferFoundationModels = "anglesite.preferFoundationModels"
        static let didMigrateAssistantDefault = "anglesite.didMigrateAssistantDefault"
        static let foundationModelTier = "anglesite.foundationModelTier"
    }

    private let defaults: UserDefaults
    #if canImport(Darwin)
    private let ubiquityContainerResolver: UbiquityContainerResolving

    /// Must match the `com.apple.developer.icloud-container-identifiers` entry in
    /// `Resources/Anglesite.entitlements` and the `NSUbiquitousContainers` key in
    /// `Resources/Info.plist`. The default `Resources/Anglesite-Debug.entitlements` deliberately
    /// omits this entitlement (#1038 — it requires a real provisioning profile, breaking the
    /// no-Apple-account Debug build); `Resources/Anglesite-Debug-iCloud.entitlements` is the
    /// opt-in local variant that carries it.
    /// Public so `AnglesiteIOS`'s site-discovery seam (#866) can reuse the exact same identifier
    /// instead of duplicating this literal — it's the same physical iCloud container on both
    /// platforms.
    public static let ubiquityContainerIdentifier = "iCloud.io.dwk.anglesite"

    private let ubiquityCacheLock = NSLock()
    /// `nil` = not resolved yet; `.some(nil)` = resolved, iCloud unavailable.
    private var cachedUbiquityContainerURL: URL??

    /// `url(forUbiquityContainerIdentifier:)` is documented as potentially slow (it may hit the
    /// network) and not to be called on the main thread — but `sitesRoot` is read synchronously
    /// from `@MainActor` code. Resolving at most once per `AppSettings` instance keeps that cost
    /// to a single call per process rather than one per save/import panel (#865 final review).
    ///
    /// Known limitation: this cache never invalidates for the process's lifetime, so signing in or
    /// out of iCloud mid-session (a real, OS-supported transition) won't move `sitesRoot`/
    /// `sitesRootSource` until the app relaunches (#865 PR review). `AppSettings.shared` is a
    /// long-lived singleton with no observer machinery today; invalidating on
    /// `NSUbiquityIdentityDidChangeNotification` would need that machinery added deliberately
    /// rather than folded into this cache, so it's left as a known limitation here.
    private func resolvedUbiquityContainerURL() -> URL? {
        ubiquityCacheLock.lock()
        defer { ubiquityCacheLock.unlock() }
        if let cached = cachedUbiquityContainerURL { return cached }
        let resolved = ubiquityContainerResolver.url(forUbiquityContainerIdentifier: Self.ubiquityContainerIdentifier)
        cachedUbiquityContainerURL = resolved
        return resolved
    }

    /// Creates a settings facade over an arbitrary defaults suite — the seam that lets tests use
    /// a scratch `UserDefaults` instead of polluting (and depending on) the developer's real
    /// `standard` domain; `ubiquityContainerResolver` is likewise injectable so tests can fake
    /// iCloud availability (#865). App code should use ``shared``.
    public init(defaults: UserDefaults, ubiquityContainerResolver: UbiquityContainerResolving = FileManager.default) {
        self.defaults = defaults
        self.ubiquityContainerResolver = ubiquityContainerResolver
    }
    #else
    /// Creates a settings facade over an arbitrary defaults suite — the seam that lets tests use
    /// a scratch `UserDefaults` instead of polluting (and depending on) the developer's real
    /// `standard` domain. App code should use ``shared``.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }
    #endif

    /// Optional override for the bundled website template path. Lets template authors iterate
    /// on `Resources/Template/` content without rebuilding the app.
    public var templatePathOverride: URL? {
        get {
            guard let path = defaults.string(forKey: Key.templatePathOverride), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            if let url = newValue {
                defaults.set(url.path, forKey: Key.templatePathOverride)
            } else {
                defaults.removeObject(forKey: Key.templatePathOverride)
            }
        }
    }

    /// Optional override for the default sites root (the iCloud container, or its `~/Sites/`
    /// fallback). Useful in development and tests so the app doesn't have to scribble into the
    /// user's real home directory.
    public var sitesRootOverride: URL? {
        get {
            guard let path = defaults.string(forKey: Key.sitesRootOverride), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            if let url = newValue {
                defaults.set(url.path, forKey: Key.sitesRootOverride)
            } else {
                defaults.removeObject(forKey: Key.sitesRootOverride)
            }
        }
    }

    /// Optional dev/test override pointing preview + MCP at a LAN-hosted runtime (#589/#601):
    /// `nil` (the default) unless a host is configured, so runtime selection is untouched for
    /// real users. Ports fall back to the container-guest convention when blank or invalid.
    /// See `LANRuntimeConfiguration` and `docs/specs/2026-07-09-lan-site-runtime-design.md`.
    public var lanRuntimeConfiguration: LANRuntimeConfiguration? {
        guard let host = defaults.string(forKey: Key.lanRuntimeHost)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return nil }
        return LANRuntimeConfiguration(
            host: host,
            previewPort: port(forKey: Key.lanRuntimePreviewPort, default: LANRuntimeConfiguration.defaultPreviewPort),
            mcpPort: port(forKey: Key.lanRuntimeMCPPort, default: LANRuntimeConfiguration.defaultMCPPort))
    }

    /// Ports are stored as strings (the Settings UI uses plain text fields whose empty state
    /// means "default"); `UserDefaults.string(forKey:)` also coerces a number if one was stored.
    private func port(forKey key: String, default defaultPort: Int) -> Int {
        guard let raw = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespaces),
              let port = Int(raw), (1...65535).contains(port) else { return defaultPort }
        return port
    }

    /// Effective root for site discovery (#865): `sitesRootOverride` when set (dev/test escape
    /// hatch), otherwise the "Anglesite" folder inside this app's iCloud ubiquity container —
    /// falling back to `~/Sites/` only when iCloud is unavailable (not signed in, iCloud Drive
    /// off, or the container isn't provisioned, which is true of every ad-hoc-signed Debug build
    /// since it has no Team ID) or on a platform with no iCloud API at all (Linux). No migration
    /// path for existing `~/Sites/` packages: the app is pre-1.0 with no real user base there yet
    /// (owner confirmation, 2026-07-21).
    public var sitesRoot: URL {
        if let sitesRootOverride { return sitesRootOverride }
        #if canImport(Darwin)
        if let container = resolvedUbiquityContainerURL() {
            return container.appendingPathComponent("Documents", isDirectory: true)
        }
        #endif
        return FileManager.default.portableHomeDirectory.appendingPathComponent("Sites", isDirectory: true)
    }

    /// Where `sitesRoot` resolved its value from — lets callers (e.g. the MAS sandbox flow) make a
    /// correctness decision based on the actual reason, instead of probing filesystem behavior that
    /// can't distinguish "no grant needed" from "directory already exists" (#865 final review).
    public var sitesRootSource: SitesRootSource {
        if sitesRootOverride != nil { return .override }
        #if canImport(Darwin)
        if resolvedUbiquityContainerURL() != nil { return .iCloudContainer }
        #endif
        return .homeFallback
    }

    /// Opt-in toggle (Settings → Advanced) that surfaces the Debug pane menu item in Release
    /// builds. Defaults to `false`; Debug builds always show the menu regardless. See
    /// `DebugPaneVisibility`.
    public var debugPaneEnabled: Bool {
        get { defaults.bool(forKey: Key.debugPaneEnabled) }
        set { defaults.set(newValue, forKey: Key.debugPaneEnabled) }
    }

    /// Opt-in toggle (Settings → Advanced) that reveals the "Bot blocklist managed by" control in
    /// Content Licensing. Off by default: Cloudflare's Bot Preference Sync isn't GA yet and its
    /// dashboard settings path isn't documented (docs/superpowers/specs/2026-08-23-bot-preference-sync-design.md).
    /// See #1627 for flipping this default once Cloudflare ships.
    public var botPreferenceSyncUIEnabled: Bool {
        get { defaults.bool(forKey: Key.botPreferenceSyncUIEnabled) }
        set { defaults.set(newValue, forKey: Key.botPreferenceSyncUIEnabled) }
    }

    /// Forces local preview to skip `EsiInclude`'s dev-only fetch shim, so `EsiRemove`'s fallback
    /// content can be previewed on demand instead of only by sabotaging the fragment URL
    /// (docs/superpowers/specs/2026-07-13-esi-astro-component-design.md §4a). Global rather than
    /// per-site: the Debug Pane this control lives in has no per-site scoping today. Defaults to
    /// `false` (live/resolved preview, today's existing behavior).
    public var esiPreviewUnprocessed: Bool {
        get { defaults.bool(forKey: Key.esiPreviewUnprocessed) }
        set { defaults.set(newValue, forKey: Key.esiPreviewUnprocessed) }
    }

    /// Which backend answers chat/content-help requests: `"foundationModels"` (default) or
    /// `"acp:<ACPAgentConnection.id>"`. Global, not per-site (#602 design decision). An unresolvable
    /// value (agent removed, malformed) is handled by `AssistantBackendResolver`, which falls back
    /// to Foundation Models rather than this property validating its own contents.
    public var activeAssistantBackend: String {
        get { defaults.string(forKey: Key.activeAssistantBackend) ?? "foundationModels" }
        set { defaults.set(newValue, forKey: Key.activeAssistantBackend) }
    }

    /// Which instance's own `/api/v3/search` the Communities join flow's Discovery step
    /// (`CommunitySearchClient`, V-5.4 #371) queries. Global, user-editable in the join sheet — not
    /// a fixed Anglesite-run directory, so the query only ever goes to a source the owner chose.
    /// Falls back to `CommunitySearchClient.defaultInstance` for both an absent *and* a
    /// blanked-out override, so clearing the field in the sheet can't leave search silently
    /// broken — mirrors `activeAssistantBackend`'s string-with-fallback shape.
    public var communitySearchInstance: String {
        get {
            let stored = defaults.string(forKey: Key.communitySearchInstance)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (stored?.isEmpty == false ? stored : nil) ?? CommunitySearchClient.defaultInstance
        }
        set { defaults.set(newValue, forKey: Key.communitySearchInstance) }
    }

    /// Base URL of the user-configured OpenAI-compatible endpoint (#1482) — `nil` until set.
    /// `ExternalLLMBackend` appends `/chat/completions`; this value should NOT include that
    /// suffix. Global, not per-site, matching `activeAssistantBackend`.
    public var externalLLMBaseURL: URL? {
        get {
            guard let raw = defaults.string(forKey: Key.externalLLMBaseURL), !raw.isEmpty else { return nil }
            return URL(string: raw)
        }
        set {
            if let url = newValue {
                defaults.set(url.absoluteString, forKey: Key.externalLLMBaseURL)
            } else {
                defaults.removeObject(forKey: Key.externalLLMBaseURL)
            }
        }
    }

    /// Model name sent as the `model` field of every request to ``externalLLMBaseURL`` (#1482).
    /// Empty string (the default) means "not configured" — `AssistantBackendResolver` requires
    /// this to be non-empty before resolving the backend.
    public var externalLLMModel: String {
        get { defaults.string(forKey: Key.externalLLMModel) ?? "" }
        set { defaults.set(newValue, forKey: Key.externalLLMModel) }
    }

    /// The exact (whitespace-trimmed) base URL text that last verified successfully — the
    /// cache-key half of the "Connected" state `KeychainTokenRow` shows for the external-LLM API
    /// key row, so opening Settings doesn't fire a live network call against the configured
    /// endpoint every time (#1482 review). `nil` until a verify succeeds. Compared against the
    /// live Base URL field's current text, not just read blindly: editing the endpoint after a
    /// successful verify must not keep showing "Connected" for a URL that was never actually
    /// checked. A mismatch falls back to `KeychainTokenRow`'s existing silent live-reverify path
    /// (the same one GitHub/Cloudflare use when nothing's cached yet), not a hard failure.
    public var externalLLMVerifiedBaseURL: String? {
        get {
            guard let value = defaults.string(forKey: Key.externalLLMVerifiedBaseURL), !value.isEmpty else { return nil }
            return value
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.externalLLMVerifiedBaseURL)
            } else {
                defaults.removeObject(forKey: Key.externalLLMVerifiedBaseURL)
            }
        }
    }

    /// Best-effort "N models available" detail string from the last successful verify — purely
    /// cosmetic, so a stale or absent value never blocks the "Connected" state itself (see
    /// ``externalLLMVerifiedBaseURL``, the field that actually gates it).
    public var externalLLMVerifiedDetail: String? {
        get { defaults.string(forKey: Key.externalLLMVerifiedDetail) }
        set { setOptionalString(newValue, forKey: Key.externalLLMVerifiedDetail) }
    }

    /// The attach-time license picker's last-used choice (#999) — `nil` until the picker has
    /// been used at least once. JSON-encoded because `FileLicenseSelection` is a small struct,
    /// not a primitive `UserDefaults` can store directly.
    public var lastUsedFileLicenseSelection: FileLicenseSelection? {
        get {
            guard let data = defaults.data(forKey: Key.lastUsedFileLicenseSelection) else { return nil }
            return try? JSONDecoder().decode(FileLicenseSelection.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.lastUsedFileLicenseSelection)
            } else {
                defaults.removeObject(forKey: Key.lastUsedFileLicenseSelection)
            }
        }
    }

    /// Security-scoped bookmark for the sites root, persisted so the sandboxed (MAS) build only
    /// has to prompt once for permission to create new site folders. `nil` until granted.
    public var sitesRootBookmark: Data? {
        get { defaults.data(forKey: Key.sitesRootBookmark) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.sitesRootBookmark) }
            else { defaults.removeObject(forKey: Key.sitesRootBookmark) }
        }
    }

    /// When on (the default), dropping an image onto the preview auto-generates alt text with the
    /// on-device vision model and applies it to the `<img>` (C.7, #157). Both targets. No-ops
    /// gracefully when Apple Intelligence is unavailable. Stored inverted-from-absent so an
    /// untouched install defaults to `true`.
    public var autoGenerateAltText: Bool {
        get {
            // Absent → on by default; an explicit stored value wins.
            guard defaults.object(forKey: Key.autoGenerateAltText) != nil else { return true }
            return defaults.bool(forKey: Key.autoGenerateAltText)
        }
        set { defaults.set(newValue, forKey: Key.autoGenerateAltText) }
    }

    /// When on (the default), creating a page/post auto-suggests a short SEO meta description
    /// with the on-device model (Slice 2 of the Claude Code removal roadmap). No-ops gracefully
    /// when Apple Intelligence is unavailable — the scaffold falls back to a title-derived
    /// default. Stored inverted-from-absent so an untouched install defaults to `true`.
    public var autoGeneratePageCopy: Bool {
        get {
            guard defaults.object(forKey: Key.autoGeneratePageCopy) != nil else { return true }
            return defaults.bool(forKey: Key.autoGeneratePageCopy)
        }
        set { defaults.set(newValue, forKey: Key.autoGeneratePageCopy) }
    }

    /// Whether the app posts VoiceOver live-region announcements for streaming chat and deploy
    /// state (`LiveRegionAnnouncer`). On by default; an assistive-technology user who finds the
    /// spoken cues noisy can switch them off. Stored inverted-from-absent so an untouched install
    /// defaults to `true`.
    public var announcesLiveUpdates: Bool {
        get {
            guard defaults.object(forKey: Key.announcesLiveUpdates) != nil else { return true }
            return defaults.bool(forKey: Key.announcesLiveUpdates)
        }
        set { defaults.set(newValue, forKey: Key.announcesLiveUpdates) }
    }

    /// Whether the app posts a completion notification (Notification Center) when a
    /// long-running site operation — Deploy, Backup, Audit — finishes while the app is in the
    /// background (#526). On by default; delivery starts quietly via provisional authorization,
    /// so the user manages prominence from System Settings. Stored inverted-from-absent so an
    /// untouched install defaults to `true`.
    public var notifiesOnCompletion: Bool {
        get {
            guard defaults.object(forKey: Key.notifiesOnCompletion) != nil else { return true }
            return defaults.bool(forKey: Key.notifiesOnCompletion)
        }
        set { defaults.set(newValue, forKey: Key.notifiesOnCompletion) }
    }

    /// Whether Anglesite plays a synthesized dial-up modem handshake sound while the dev server
    /// starts up (`StartupProgressModel`) or a deploy runs (`DeployModel`). Purely decorative —
    /// off by default, so `false` when absent needs no inversion trick.
    public var playsDialupSoundEffect: Bool {
        get { defaults.bool(forKey: Key.playsDialupSoundEffect) }
        set { defaults.set(newValue, forKey: Key.playsDialupSoundEffect) }
    }

    /// The site that was most-recently focused. Used by the Sites launcher to auto-open
    /// the user's last working window on a fresh launch instead of showing the picker.
    /// Cleared when the site disappears from `SiteStore`.
    public var lastOpenedSiteID: String? {
        get {
            guard let id = defaults.string(forKey: Key.lastOpenedSiteID), !id.isEmpty else { return nil }
            return id
        }
        set {
            if let id = newValue {
                defaults.set(id, forKey: Key.lastOpenedSiteID)
            } else {
                defaults.removeObject(forKey: Key.lastOpenedSiteID)
            }
        }
    }

    /// Best-effort GitHub identity from the last successful token verification, shown in Settings
    /// instead of a bare "token stored" — the same "who am I signed in as" surfacing Xcode's
    /// Accounts pane does. Non-secret display fields only; the token itself lives in the Keychain,
    /// never here. `nil` until a token verifies at least once (see `GitHubAPITokenVerifier`).
    public var gitHubAccount: GitHubAccount? {
        get {
            guard let login = defaults.string(forKey: Key.gitHubAccountLogin), !login.isEmpty else { return nil }
            let name = defaults.string(forKey: Key.gitHubAccountName)
            let avatarURL = defaults.string(forKey: Key.gitHubAccountAvatarURL).flatMap(URL.init(string:))
            return GitHubAccount(login: login, name: name, avatarURL: avatarURL)
        }
        set {
            guard let account = newValue else {
                defaults.removeObject(forKey: Key.gitHubAccountLogin)
                defaults.removeObject(forKey: Key.gitHubAccountName)
                defaults.removeObject(forKey: Key.gitHubAccountAvatarURL)
                return
            }
            defaults.set(account.login, forKey: Key.gitHubAccountLogin)
            setOptionalString(account.name, forKey: Key.gitHubAccountName)
            setOptionalString(account.avatarURL?.absoluteString, forKey: Key.gitHubAccountAvatarURL)
        }
    }

    /// Best-effort Cloudflare identity from the last successful token verification. A dedicated
    /// "verified" flag (rather than inferring presence from `name`/`email`) distinguishes a
    /// verified-but-uninformative token — a scoped token lacking `account:read` still verifies,
    /// just with nothing to show — from a token that's never been checked at all.
    public var cloudflareAccount: CloudflareAccount? {
        get {
            guard defaults.bool(forKey: Key.cloudflareAccountVerified) else { return nil }
            return CloudflareAccount(
                name: defaults.string(forKey: Key.cloudflareAccountName),
                email: defaults.string(forKey: Key.cloudflareAccountEmail)
            )
        }
        set {
            guard let account = newValue else {
                defaults.removeObject(forKey: Key.cloudflareAccountVerified)
                defaults.removeObject(forKey: Key.cloudflareAccountName)
                defaults.removeObject(forKey: Key.cloudflareAccountEmail)
                return
            }
            defaults.set(true, forKey: Key.cloudflareAccountVerified)
            setOptionalString(account.name, forKey: Key.cloudflareAccountName)
            setOptionalString(account.email, forKey: Key.cloudflareAccountEmail)
        }
    }

    private func setOptionalString(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// One-time cleanup for settings removed when chat became Foundation Models-only.
    public func removeLegacyChatBackendDefaultsIfNeeded() {
        guard !defaults.bool(forKey: Key.didCleanLegacyChatBackendDefaults) else { return }
        defaults.removeObject(forKey: LegacyKey.preferFoundationModels)
        defaults.removeObject(forKey: LegacyKey.didMigrateAssistantDefault)
        defaults.removeObject(forKey: LegacyKey.foundationModelTier)
        defaults.set(true, forKey: Key.didCleanLegacyChatBackendDefaults)
    }
}

/// Which of `AppSettings.sitesRoot`'s three branches produced the current value (#865).
///
/// Callers that need to behave differently per branch — notably the sandboxed (MAS) New Site flow,
/// which must show a security-scoped grant panel for everything *except* the app's own iCloud
/// container — read this instead of inferring the branch from the resolved path or from a
/// filesystem write probe.
public enum SitesRootSource: Sendable, Equatable {
    /// `sitesRootOverride` is set (dev/test escape hatch); the location is arbitrary.
    case override
    /// The app's iCloud ubiquity container — the default when iCloud is available.
    case iCloudContainer
    /// The `~/Sites/` fallback, used when iCloud is unavailable or the platform has no iCloud API.
    case homeFallback
}

/// Decides whether the "Show Debug Pane" menu item is present.
///
/// The pane streams every subprocess line and is the first thing a weird bug report needs — so it
/// is *always* available in Debug builds. In Release it stays hidden unless the user opts in
/// (Settings → Advanced) or holds ⌥ while launching the app.
public enum DebugPaneVisibility {
    /// True when any one of the three access routes applies — Debug build, the Settings opt-in
    /// (``AppSettings/debugPaneEnabled``), or ⌥ held at launch. A pure function of its inputs so
    /// the policy is testable without a real bundle or keyboard state.
    public static func menuItemVisible(isDebugBuild: Bool, settingEnabled: Bool, optionHeldAtLaunch: Bool) -> Bool {
        isDebugBuild || settingEnabled || optionHeldAtLaunch
    }
}

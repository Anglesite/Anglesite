import Foundation

/// The "Show developer tools" gate — Settings ▸ Advanced (#1964), decision D1 of the 2026-09-08
/// product-direction review (`docs/specs/2026-09-08-product-direction-review-decisions.md`): the
/// default surface has no code editor and no Terminal command, and the technical affordances
/// that remain live behind one explicit opt-in.
///
/// Pure policy over the persisted setting (``AppSettings/developerToolsEnabled``), so every
/// gated surface reads the same rule and tests can pin it without a `UserDefaults` suite.
/// Deliberately *not* `DebugPaneVisibility`'s rule: that one auto-reveals in Debug builds because
/// diagnostics are for whoever is debugging, whereas the editors are product surface — a Debug
/// build must show the owner's default so the gate can be reviewed exactly as shipped.
public struct DeveloperToolsVisibility: Sendable, Equatable {
    /// Whether the owner turned on Settings ▸ Advanced ▸ "Show developer tools".
    public let settingEnabled: Bool

    public init(settingEnabled: Bool) {
        self.settingEnabled = settingEnabled
    }

    /// The Component Editor's Source tab, and the code-level Style (CSS rules) and Metadata
    /// (HTML attributes, TypeScript props) inspector panes it feeds.
    public var showsCodeEditors: Bool { settingEnabled }

    /// The Safari bridge section in Settings ▸ Advanced (#1910) — its setup guidance is a
    /// Terminal command the owner is asked to run, so the whole section is a developer tool.
    public var showsSafariBridgeSetup: Bool { settingEnabled }

    /// The Worker error-tracking toggle in Settings ▸ Advanced (#2095) — the first Developer
    /// feature, since it hands diagnostics to Cloudflare Workers Issues on the owner's account.
    public var showsWorkerIssuesSetting: Bool { settingEnabled }

    /// Whether a publish opts the site's Worker into Cloudflare Workers Issues (#2095): only when
    /// developer tools are on *and* the owner turned the feature on. Hiding developer tools turns
    /// it off on the next publish without clearing the stored opt-in.
    public func tracksWorkerIssues(optedIn: Bool) -> Bool {
        settingEnabled && optedIn
    }

    /// Whether the editor `EditorKind.resolve` picked for a file may be shown. Only the raw
    /// text editor is gated: the Website Settings form (`.plist`), the post editor
    /// (`.markdown`) and the Component Editor's Design canvas (`.component`) are owner surfaces
    /// and stay visible regardless.
    public func showsEditor(_ kind: EditorKind) -> Bool {
        !Self.requiresDeveloperTools(kind) || settingEnabled
    }

    /// Which editors the gate covers — see ``showsEditor(_:)``. One list so the Settings
    /// caption, the main-pane fallback, and tests agree on what the toggle reveals.
    public static func requiresDeveloperTools(_ kind: EditorKind) -> Bool {
        kind == .text
    }
}

/// Consent for Worker error reports (#2095 slice 5). Turning the feature on asks the owner to
/// agree to a description of what is sent. Bump ``currentVersion`` whenever that changes (more
/// fields, a new destination, a wider audience): `AppSettings.tracksWorkerIssues` then stays off
/// until the owner agrees again, rather than silently sending more under an old consent.
public enum WorkerIssuesConsent {
    /// Version 1: the exception kind and the package and template code locations go to the
    /// package's public issue tracker. The error text, visitors' requests and the site's address
    /// are never sent.
    public static let currentVersion = 1

    public static func isCurrent(_ agreedVersion: Int) -> Bool {
        agreedVersion >= currentVersion
    }
}

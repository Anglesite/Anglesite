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

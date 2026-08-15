#if os(iOS)
import AppIntents
import AnglesiteIOS

/// "Edit Site" as a verb Siri/Shortcuts/Spotlight can run (#1431, iOS v2.0 design §3): opens
/// the app and walks straight into the site's P2P editing session. A plain `AppIntent`, not an
/// `OpenIntent` — `OpenSiteIntent` already owns the open-verb entity action on macOS, and this
/// is a distinct verb on the same entity. iOS-only: on the Mac, editing *is* the site window.
public struct EditSiteIntent: AppIntent {
    /// The verb Siri/Shortcuts display and match against.
    public static let title: LocalizedStringResource = "Edit Site"
    /// One-line explanation shown in the Shortcuts action gallery.
    public static let description = IntentDescription("Open a site's live preview for editing.")
    /// `true` because the session cover is the whole point — a background invocation with no
    /// foregrounded app would succeed invisibly.
    public static let openAppWhenRun = true

    /// The site to edit — resolved by the iOS entity query, so `id` is the site's stable
    /// package UUID (the identity the P2P session names sites by, design §2).
    @Parameter(title: "Site") public var site: SiteEntity

    /// Required by `AppIntent` — the runtime constructs the intent, then fills `@Parameter`s.
    public init() {}

    /// Shortcuts editor sentence: "Edit *site*".
    public static var parameterSummary: some ParameterSummary { Summary("Edit \(\.$site)") }

    /// Routes through ``EditSessionRouter`` because an intent can't present SwiftUI covers;
    /// the shell observes the router and presents the session. `@MainActor` since the router is.
    /// On iOS every entity id is a package UUID string (`SiteEntityUbiquitySource`); a
    /// non-UUID id would mean a stale Spotlight donation, answered honestly rather than crashed on.
    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let siteID = UUID(uuidString: site.id) else {
            return .result(dialog: "Couldn't find \(site.displayName).")
        }
        EditSessionRouter.shared.requestEditSession(siteID: siteID)
        return .result(dialog: "Opening \(site.displayName) for editing.")
    }
}
#endif

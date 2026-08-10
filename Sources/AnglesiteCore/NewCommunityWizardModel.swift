import Foundation
import Observation

/// Observable state behind the New Community wizard (V-5.1b, #907, design doc §3) — a
/// distinct flow from ``NewSiteWizardModel``: a hosted community is a different site kind
/// (own Worker, own Group actor, moderators), not a cosmetic theme pick, so it asks for a
/// name only and skips the theme grid entirely, reusing the "community" catalog theme
/// (the same palette `ThemeCatalog.defaultThemeID(for: .organization)` already maps to) as
/// its one consistent look.
@MainActor
@Observable
public final class NewCommunityWizardModel {
    /// Mirrors ``NewSiteWizardModel/Step`` — the chooser (name entry) and building (scaffold
    /// progress) states.
    public enum Step: Int, CaseIterable {
        case chooser
        case building
    }

    public private(set) var step: Step = .chooser
    /// The owner-entered community name; bound to the wizard's text field.
    public var communityName: String = ""
    /// Every ``SiteScaffolder/ScaffoldStep`` emitted so far, in order.
    public private(set) var progress: [SiteScaffolder.ScaffoldStep] = []
    /// The `.failed` step, if any.
    public private(set) var fatal: SiteScaffolder.ScaffoldStep?
    /// The new site's registered id once scaffolding reaches `.done`; `nil` until then.
    public private(set) var completedSiteID: String?

    /// Availability check for a candidate site name — same contract as
    /// ``NewSiteWizardModel/init(catalog:isNameTaken:)``'s parameter.
    private let isNameTaken: (String) -> Bool

    public init(isNameTaken: @escaping (String) -> Bool) {
        self.isNameTaken = isNameTaken
    }

    /// The draft `build(using:)` will scaffold, computed fresh from ``communityName`` each
    /// time it's read — there's no per-field mutation to track separately, unlike
    /// ``NewSiteWizardModel/draft``, since a community draft has exactly one owner-set field.
    public var draft: NewSiteDraft {
        var draft = NewSiteDraft(siteType: .community, name: trimmedName,
                                 saveFileName: "\(trimmedName).anglesite", headline: "")
        draft.themeID = "community"
        return draft
    }

    private var trimmedName: String {
        communityName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Gate for the chooser's Create button: a non-empty, not-already-taken name, and no
    /// build running.
    public var canCreate: Bool {
        step == .chooser && !trimmedName.isEmpty && !isNameTaken(trimmedName)
    }

    public var warnings: [String] {
        progress.compactMap { if case .warning(_, let message) = $0 { return message } else { return nil } }
    }

    public var hasWarnings: Bool { !warnings.isEmpty }

    public var didCompleteCleanly: Bool { completedSiteID != nil && !hasWarnings }

    /// Runs the scaffolder against ``draft``, accumulating progress. Returns the new site id
    /// on success. Mirrors ``NewSiteWizardModel/build(using:)`` exactly.
    public func build(using scaffolder: SiteScaffolder) async -> String? {
        step = .building
        for await s in scaffolder.scaffold(draft) {
            progress.append(s)
            if case .failed = s { fatal = s }
            if case .done(let id) = s { completedSiteID = id }
        }
        return completedSiteID
    }
}

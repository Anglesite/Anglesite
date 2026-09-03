import Foundation
import Observation
import AnglesiteCore

/// Drives the Social Media Plan sheet (#465): generate → preview markdown → explicit Save.
/// FM generates content; deterministic code renders and writes the file (spec §5.2).
@Observable @MainActor
final class SocialPlanModel: Identifiable {
    let id = UUID()
    let siteID: String
    let sourceDirectory: URL
    private let conventionsStore: ProjectConventionsStore
    private let planner: (any SocialMediaPlanning)?

    var weeks = 4
    var markdown: String?
    var running = false
    var saved = false
    var errorMessage: String?
    var unavailable: Bool { planner == nil }

    init(siteID: String, sourceDirectory: URL, conventionsStore: ProjectConventionsStore,
         planner: (any SocialMediaPlanning)? = SocialMediaPlannerFactory.makeDefault()) {
        self.siteID = siteID
        self.sourceDirectory = sourceDirectory
        self.conventionsStore = conventionsStore
        self.planner = planner
    }

    func generate() async {
        errorMessage = nil
        weeks = min(max(weeks, 1), 8)
        guard let planner, !running else { return }
        running = true
        saved = false
        defer { running = false }
        let conventions = await conventionsStore.load()
        let businessType = SiteBusinessType.read(sourceDirectory: sourceDirectory)
        let siteName = SiteConfigValues.siteName(sourceDirectory: sourceDirectory) ?? "this site"
        let preamble = BrandVoiceGuidance.preamble(conventions: conventions, businessType: businessType)
        guard let plan = await planner.plan(
            siteName: siteName, businessType: businessType, preamble: preamble,
            weeks: weeks, startDate: Date(), siteID: siteID, siteDirectory: sourceDirectory) else {
            errorMessage = ContentHelpDialogs.assistantUnavailable(feature: "Social planning")
            return
        }
        markdown = SocialCalendarMarkdown.render(plan: plan, siteName: siteName)
    }

    func save() {
        errorMessage = nil
        guard let markdown else { return }
        do {
            try SocialCalendarMarkdown.write(markdown: markdown, sourceDirectory: sourceDirectory)
            saved = true
        } catch {
            errorMessage = String(localized: "Couldn't save the plan: \(error.localizedDescription)")
        }
    }
}

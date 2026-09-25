import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteAppCore

/// Regression coverage for a PR #1980 review finding: `ModelTierNoticeView` was gated only on
/// `SocialPlanModel.unavailable` (the pre-6.4-toolchain case), not on `generate()` discovering
/// Apple Intelligence unavailable at runtime (`planner.plan` returning `nil`), which sets
/// `errorMessage` but left the badge showing right above it. `runtimeUnavailable`/
/// `showsModelTierBadge` are the fix.
@Suite struct SocialPlanModelTests {
    private struct StubPlanner: SocialMediaPlanning {
        let plan: SocialMediaPlan?
        func plan(siteName: String, businessType: String?, preamble: String?, weeks: Int,
                  startDate: Date, siteID: String, siteDirectory: URL) async -> SocialMediaPlan? {
            plan
        }
    }

    private func makeConventionsStore() -> ProjectConventionsStore {
        ProjectConventionsStore(configDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString))
    }

    private static let samplePlan = SocialMediaPlan(
        businessType: "bakery", platforms: [], bios: [:],
        pillars: [SocialPillar(name: "Behind the oven", detail: "process")], weeks: [])

    @MainActor
    @Test("badge is hidden when the toolchain has no planner at all")
    func hiddenWhenCompileTimeUnavailable() {
        let model = SocialPlanModel(
            siteID: "s", sourceDirectory: URL(fileURLWithPath: "/tmp"),
            conventionsStore: makeConventionsStore(), planner: nil)
        #expect(model.unavailable)
        #expect(!model.showsModelTierBadge)
    }

    @MainActor
    @Test("badge shows once a plan is generated")
    func showsWhenPlanGenerates() async {
        let model = SocialPlanModel(
            siteID: "s", sourceDirectory: URL(fileURLWithPath: "/tmp"),
            conventionsStore: makeConventionsStore(), planner: StubPlanner(plan: Self.samplePlan))
        await model.generate()
        #expect(model.markdown != nil)
        #expect(model.showsModelTierBadge)
    }

    @MainActor
    @Test("badge is hidden when Apple Intelligence is unavailable at runtime")
    func hiddenWhenRuntimeUnavailable() async {
        // `planner != nil` (a 6.4+ toolchain) but `plan()` returned `nil` — the exact case the
        // review finding named (Apple Intelligence toggled off, or pillar generation failing).
        let model = SocialPlanModel(
            siteID: "s", sourceDirectory: URL(fileURLWithPath: "/tmp"),
            conventionsStore: makeConventionsStore(), planner: StubPlanner(plan: nil))
        #expect(!model.unavailable)
        await model.generate()
        #expect(model.errorMessage != nil)
        #expect(!model.showsModelTierBadge)
    }

    @MainActor
    @Test("a later save() failure doesn't hide a badge for a plan that already generated")
    func saveFailureDoesNotAffectBadge() async throws {
        // A regular file (not a directory) as `sourceDirectory`: `save()` tries to create a
        // `docs/` subdirectory inside it, which fails because the "parent" isn't a directory.
        let bogusFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SocialPlanModelTests-\(UUID().uuidString)")
        try Data().write(to: bogusFile)
        defer { try? FileManager.default.removeItem(at: bogusFile) }

        let model = SocialPlanModel(
            siteID: "s", sourceDirectory: bogusFile,
            conventionsStore: makeConventionsStore(), planner: StubPlanner(plan: Self.samplePlan))
        await model.generate()
        #expect(model.showsModelTierBadge)
        model.save()
        #expect(model.errorMessage != nil)
        #expect(model.showsModelTierBadge)
    }
}

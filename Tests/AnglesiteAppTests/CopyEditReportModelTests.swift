import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteAppCore

/// Regression coverage for a PR #1980 review finding: `ModelTierNoticeView` was gated only on
/// `CopyEditReportModel.unavailable` (the pre-6.4-toolchain case), not on Apple Intelligence going
/// unavailable *at runtime* — which the model itself already surfaces via
/// `report?.unavailableMessage`. `showsModelTierBadge` is the fix: it folds in both signals.
@Suite struct CopyEditReportModelTests {
    private struct StubAuditor: CopyEditAuditing {
        let report: CopyEditReport
        func audit(chunks: [ContentChunk], preamble: String?, siteID: String, siteDirectory: URL) async -> CopyEditReport {
            report
        }
    }

    private func makeConventionsStore() -> ProjectConventionsStore {
        ProjectConventionsStore(configDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString))
    }

    @MainActor
    @Test("badge is hidden when the toolchain has no auditor at all")
    func hiddenWhenCompileTimeUnavailable() {
        let model = CopyEditReportModel(
            siteID: "s", sourceDirectory: URL(fileURLWithPath: "/tmp"),
            conventionsStore: makeConventionsStore(), auditor: nil)
        #expect(model.unavailable)
        #expect(!model.showsModelTierBadge)
    }

    @MainActor
    @Test("badge shows once a report with findings comes back")
    func showsWhenReportIsUsable() async {
        let report = CopyEditReport(findings: [], auditedCount: 1, skippedRoutes: [])
        let model = CopyEditReportModel(
            siteID: "s", sourceDirectory: URL(fileURLWithPath: "/tmp"),
            conventionsStore: makeConventionsStore(), auditor: StubAuditor(report: report))
        #expect(!model.unavailable)
        await model.run()
        #expect(model.showsModelTierBadge)
    }

    @MainActor
    @Test("badge is hidden when Apple Intelligence is unavailable at runtime")
    func hiddenWhenRuntimeUnavailable() async {
        // `auditor != nil` (a 6.4+ toolchain) but the audit stopped because Apple Intelligence
        // itself was off — the exact case the review finding named.
        let report = CopyEditReport(
            findings: [], auditedCount: 0, skippedRoutes: [],
            unavailableMessage: ContentHelpDialogs.assistantUnavailable(feature: "Copy review"))
        let model = CopyEditReportModel(
            siteID: "s", sourceDirectory: URL(fileURLWithPath: "/tmp"),
            conventionsStore: makeConventionsStore(), auditor: StubAuditor(report: report))
        #expect(!model.unavailable)
        await model.run()
        #expect(model.report?.unavailableMessage != nil)
        #expect(!model.showsModelTierBadge)
    }

    @MainActor
    @Test("badge shows before a report has arrived (nothing contradicts it yet)")
    func showsBeforeReportArrives() {
        let report = CopyEditReport(findings: [], auditedCount: 0, skippedRoutes: [])
        let model = CopyEditReportModel(
            siteID: "s", sourceDirectory: URL(fileURLWithPath: "/tmp"),
            conventionsStore: makeConventionsStore(), auditor: StubAuditor(report: report))
        #expect(model.report == nil)
        #expect(model.showsModelTierBadge)
    }
}

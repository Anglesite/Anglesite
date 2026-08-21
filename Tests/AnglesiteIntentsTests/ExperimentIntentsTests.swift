import Testing
import Foundation
@testable import AnglesiteIntents
import AnglesiteCore

extension AppIntentsTests {
    @Suite("ExperimentIntents")
    struct ExperimentIntentsTests {
        @Test("AnalyzeExperimentIntent reports a treatment win")
        func reportsTreatmentWin() async {
            var intent = AnalyzeExperimentIntent()
            intent.experimentName = "Hero headline"
            intent.controlName = "Original"
            intent.controlImpressions = 1000
            intent.controlConversions = 50
            intent.treatmentName = "New headline"
            intent.treatmentImpressions = 1000
            intent.treatmentConversions = 120
            let dialog = await intent.performForTesting()
            #expect(dialog.contains("Hero headline"))
            #expect(dialog.contains("New headline"))
            #expect(dialog.contains("outperforming"))
        }

        @Test("AnalyzeExperimentIntent flags insufficient data")
        func flagsInsufficientData() async {
            var intent = AnalyzeExperimentIntent()
            intent.experimentName = ""
            intent.controlName = "Original"
            intent.controlImpressions = 10
            intent.controlConversions = 1
            intent.treatmentName = "Variant"
            intent.treatmentImpressions = 10
            intent.treatmentConversions = 1
            let dialog = await intent.performForTesting()
            #expect(dialog.contains("Not much traffic yet"))
        }

        @Test("AnalyzeExperimentIntent flags a sample ratio mismatch")
        func flagsSampleRatioMismatch() async {
            var intent = AnalyzeExperimentIntent()
            intent.experimentName = "Skewed test"
            intent.controlName = "Original"
            intent.controlImpressions = 9000
            intent.controlConversions = 450
            intent.treatmentName = "Variant"
            intent.treatmentImpressions = 1000
            intent.treatmentConversions = 60
            let dialog = await intent.performForTesting()
            #expect(dialog.contains("traffic split looks off"))
        }

        @Test("AnalyzeExperimentIntent's zero-argument path reports the running experiment's live counts")
        func zeroArgumentPathReportsLiveExperiment() async {
            let experiment = DomainConfig.Experiments.Experiment(
                id: "hero-headline", name: "Hero headline", page: "/",
                variant: .init(id: "hero-2", name: "New headline", page: "/hero-2/"),
                split: 0.5, goal: .init(kind: "pageview", path: "/contact/"), status: "running",
                startedAt: "2026-08-01")
            let counts = ExperimentEventsD1Client.Counts(
                controlVisitors: 1000, controlConversions: 50, variantVisitors: 1000, variantConversions: 120)
            let fake = FakeExperimentResultsService(
                prefill: ExperimentResultsSync.Prefill(experiment: experiment, counts: counts))

            let intent = AnalyzeExperimentIntent()
            let dialog = await intent.performForTesting(service: fake)
            #expect(dialog.contains("Hero headline"))
            #expect(dialog.contains("New headline"))
            #expect(dialog.contains("outperforming"))
        }

        @Test("AnalyzeExperimentIntent's zero-argument path reports no running experiment in plain language")
        func zeroArgumentPathReportsNoRunningExperiment() async {
            let fake = FakeExperimentResultsService(prefill: nil)
            let intent = AnalyzeExperimentIntent()
            let dialog = await intent.performForTesting(service: fake)
            #expect(dialog.contains("don't see a running experiment"))
        }

        @Test("AnalyzeExperimentIntent takes the manual path — and never consults the service — once any count is supplied")
        func manualPathNeverConsultsService() async {
            var intent = AnalyzeExperimentIntent()
            intent.experimentName = "Hero headline"
            intent.controlName = "Original"
            intent.controlImpressions = 1000
            intent.controlConversions = 50
            intent.treatmentName = "New headline"
            intent.treatmentImpressions = 1000
            intent.treatmentConversions = 120
            // UnreachableExperimentResultsService (the default) traps if consulted — this test's
            // real assertion is that performForTesting() completes without invoking it.
            let dialog = await intent.performForTesting()
            #expect(dialog.contains("Hero headline"))
        }

        @Test("AnalyzeExperimentIntent asks for both counts when only one variant's visitors is supplied")
        func partiallyFilledCallAsksForBothCounts() async {
            var intent = AnalyzeExperimentIntent()
            intent.controlImpressions = 1000
            // treatmentImpressions left nil.
            let dialog = await intent.performForTesting()
            #expect(dialog.contains("both variants' visitor counts"))
        }
    }
}

private struct FakeExperimentResultsService: ExperimentResultsService {
    let prefill: ExperimentResultsSync.Prefill?
    func prefillForRunningExperiment() async -> ExperimentResultsSync.Prefill? { prefill }
}

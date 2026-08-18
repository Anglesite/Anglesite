import SwiftUI
import AnglesiteCore

/// UI for `ExperimentStatsModel` (#769): owner types in each variant's impression/conversion
/// counts, gets `ExperimentStats`' exact Bayesian analysis back in plain language, plus the
/// default test-idea playbook for owners who haven't started a test yet. As of #1518, also hosts
/// the lifecycle that leads up to manual entry — propose a suggestion, configure its
/// variant/goal, start it running — by switching on `model.step`.
struct ExperimentStatsSheetView: View {
    @Bindable var model: ExperimentStatsModel
    var deployModel: DeployModel
    var onDone: () -> Void
    var enterGoalPickMode: () -> Void
    var exitGoalPickMode: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch model.step {
                case .manual:
                    manualForm
                case .propose:
                    ExperimentProposeView(model: model)
                case .configure:
                    ExperimentConfigureView(model: model, enterGoalPickMode: enterGoalPickMode, exitGoalPickMode: exitGoalPickMode)
                case .starting:
                    ProgressView("Starting your test…")
                case .running(let experiment):
                    ExperimentRunningStatusView(experiment: experiment)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Experiment Results")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 620)
        .onChange(of: model.step) { oldStep, newStep in
            guard AppSettings.shared.announcesLiveUpdates else { return }
            // `newStep`'s activity needs `model.startFailureReason` too: a failed deploy reverts
            // `step` from `.starting` back to `.configure`, which on its own is indistinguishable
            // from a fresh, never-started `.configure` — losing the failure announcement entirely
            // if `activity(for:)` looked at `step` alone. Consumed here (read, not cleared) since
            // `experimentAnnouncement` already dedupes on `old != new`.
            if let announcement = LiveRegionAnnouncer.experimentAnnouncement(
                from: activity(for: oldStep, failureReason: nil),
                to: activity(for: newStep, failureReason: model.startFailureReason)) {
                AccessibilityNotification.Announcement(announcement).post()
            }
        }
        .onChange(of: deployModel.phase) { _, newPhase in
            model.observeDeployPhase(newPhase)
        }
        .onChange(of: model.goalPickController.state) { _, newState in
            if case .succeeded = newState { model.applyPickedVisibleGoal() }
        }
    }

    private func activity(for step: ExperimentStatsModel.Step, failureReason: String?) -> LiveRegionAnnouncer.ExperimentActivity {
        switch step {
        case .manual, .propose: return .inactive
        case .configure:
            // A `.configure` step reached via `observeDeployPhase`'s revert carries a
            // `startFailureReason`; a `.configure` step reached via propose/scaffold/goal-setting
            // never sets one (Task 12's methods don't touch it) — so this alone distinguishes the
            // two without `step` needing its own dedicated `.justFailed` case.
            if let failureReason { return .failed(reason: failureReason) }
            return .inactive
        case .starting: return .starting
        case .running(let e): return .running(name: e.name)
        }
    }

    @ViewBuilder
    private var manualForm: some View {
        Form {
            Section("Experiment") {
                TextField("What are you testing? (optional)", text: $model.experimentName)
            }
            variantSection(
                title: "Original (control)", name: $model.controlName,
                impressions: $model.controlImpressions, conversions: $model.controlConversions)
            variantSection(
                title: "Variant (treatment)", name: $model.treatmentName,
                impressions: $model.treatmentImpressions, conversions: $model.treatmentConversions)

            Section {
                Button("Analyze") {
                    model.analyze()
                }
                .disabled(!model.canAnalyze)
            }

            if let result = model.result {
                resultSection(result)
            }

            Section("Test ideas") {
                ForEach(model.suggestions, id: \.title) { suggestion in
                    Button {
                        model.openPropose()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).font(.callout.weight(.medium))
                            Text(suggestion.rationale).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func variantSection(
        title: String, name: Binding<String>, impressions: Binding<Int>, conversions: Binding<Int>
    ) -> some View {
        Section(title) {
            TextField("Name", text: name)
            TextField("Visitors", value: impressions, format: .number)
            TextField("Conversions", value: conversions, format: .number)
        }
    }

    private func resultSection(_ result: ExperimentStats.Result) -> some View {
        Section("Result") {
            if let summary = model.summary {
                Text(summary).font(.callout).textSelection(.enabled)
            }
            LabeledContent("Control rate", value: percent(result.controlRate))
            LabeledContent("Variant rate", value: percent(result.treatmentRate))
            LabeledContent("Probability variant wins", value: percent(result.probabilityTreatmentBeatsControl))
            if !model.hasSufficientData {
                Label(
                    "Not enough traffic yet — the retired skill's rule of thumb is 30+ days or 500+ visitors per variant before trusting an inconclusive result.",
                    systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.sampleRatioMismatch {
                Label(
                    "The traffic split looks off from what you'd expect — check your test setup before trusting these numbers.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button("Edit and re-analyze") { model.editAgain() }
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

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
    /// `SiteWindowModel.deploySite()` — see `ExperimentConfigureView.deploySite`.
    var deploySite: () -> Void
    /// See `ExperimentConfigureView.deployUnavailableReason`.
    var deployUnavailableReason: () -> String?
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
                    ExperimentConfigureView(
                        model: model, deploySite: deploySite,
                        deployUnavailableReason: deployUnavailableReason,
                        enterGoalPickMode: enterGoalPickMode, exitGoalPickMode: exitGoalPickMode)
                case .starting:
                    ProgressView("Starting your test…")
                case .running(let experiment):
                    ExperimentRunningStatusView(experiment: experiment)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Experiment Results")
            .toolbar {
                // One shared affordance rather than a button per non-manual view: the manual-entry
                // form (#769) is still the only working analysis surface until live counts land
                // (#1270), so every lifecycle step needs a way back to it (#1518 review, I6).
                if model.canReturnToManual {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Analyze Manually") { model.returnToManual() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                        // A failed start is rolled back to `"draft"` by this view's own
                        // `.onChange(of: deployModel.phase)` observer — which dies with the view.
                        // Dismissing mid-deploy would leave `anglesite.json` permanently claiming a
                        // test is live that never published (#1518 review, I4). `.starting` always
                        // ends: `start(unavailableReason:deploy:)` refuses to enter it unless the
                        // deploy will really run, and `observeDeployPhase(_:)` now handles every
                        // non-`.running` phase.
                        .disabled(model.step == .starting)
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 620)
        .onExitCommand { model.goalPickController.cancel() }
        // Dismissing the sheet mid-pick would otherwise leave the preview overlay armed with no
        // controller left to answer it. A no-op unless actually picking.
        .onDisappear { model.goalPickController.cancel() }
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
                if model.isLive {
                    Label("Live counts from your site", systemImage: "bolt.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                if let running = model.runningExperiment {
                    // `openPropose()` refuses while a running experiment is declared (it would
                    // otherwise be reachable here via `returnToManual()`), so this row explains
                    // why in terms of the owner's live test rather than leaving the buttons a
                    // silent no-op.
                    Text("“\(running.name)” is your live test right now. Wait for it to finish before starting a new one.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
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

import SwiftUI
import AnglesiteCore

/// The running step of the experiment lifecycle (#1518): a status readout, plus — as of #1270
/// slice 6 — the conclude actions that end it. Reached from `.configure` once
/// `ExperimentStatsModel.observeDeployPhase(_:)` sees the starting deploy succeed.
struct ExperimentRunningStatusView: View {
    @Bindable var model: ExperimentStatsModel
    let experiment: DomainConfig.Experiments.Experiment
    /// Runs the site's one real deploy path, threaded down the same way `ExperimentConfigureView`
    /// receives it — conclude publishes unconditionally once its file/config/history changes land
    /// (see `ExperimentStatsModel.confirmConclude(deploy:)`).
    var deploySite: () -> Void

    var body: some View {
        Form {
            Section(experiment.name) {
                LabeledContent("Status") {
                    Text("Live")
                }
                .accessibilityLabel("Status")
                .accessibilityValue("Live")
                if let startedAt = experiment.startedAt {
                    LabeledContent("Started", value: startedAt)
                }
                Text("Your test is live. Visitors will see one version or the other; I'll tell you when there's a clear answer.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.hasSufficientData, let result = model.result {
                Section("What we've learned") {
                    if let summary = model.summary {
                        Text(summary).font(.callout).textSelection(.enabled)
                    }
                    Text(consequenceSuggestion(for: result))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Conclude this test") {
                Button("Promote the variant") { model.requestConclude(.promote) }
                Button("Keep the original") { model.requestConclude(.keep) }
                Button("End test early", role: .destructive) { model.requestConclude(.discard) }
                if let reason = model.concludeFailureReason {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .task {
            guard model.canAnalyze, model.result == nil else { return }
            model.analyze()
        }
        .confirmationDialog(
            concludeDialogTitle, isPresented: Binding(
                get: { model.pendingConclude != nil }, set: { _ in }),
            titleVisibility: .visible
        ) {
            if let decision = model.pendingConclude {
                // Return-key default (#1736) — see the revert alert in `SiteWindow` for why the
                // default sits on the action rather than on Cancel. Explicit for every decision so
                // Return behaves the same whether the confirm button is `.destructive` (promote,
                // discard) or role-less (keep) — SwiftUI only defaults the latter on its own.
                Button(concludeConfirmLabel(for: decision), role: concludeConfirmRole(for: decision)) {
                    Task { await model.confirmConclude(deploy: deploySite) }
                }
                .keyboardShortcut(.defaultAction)
            }
            Button("Cancel", role: .cancel) { model.cancelConclude() }
        } message: {
            Text(concludeDialogMessage)
        }
    }

    private func consequenceSuggestion(for result: ExperimentStats.Result) -> String {
        switch result.winner {
        case .treatment:
            return "Your variant looks like the winner. Make it the site's version?"
        case .control:
            return "The original is holding up. Keep it as is?"
        case .inconclusive:
            return "It's still too close to call — you can keep collecting data, or end the test early."
        }
    }

    private var concludeDialogTitle: String {
        switch model.pendingConclude {
        case .promote: return "Promote the variant?"
        case .keep: return "Keep the original?"
        case .discard: return "End this test early?"
        case nil: return ""
        }
    }

    private var concludeDialogMessage: String {
        switch model.pendingConclude {
        case .promote:
            return "This applies the variant's content to \(experiment.page) and removes the variant page. Your site will publish the change."
        case .keep:
            return "This removes the variant page and keeps \(experiment.page) as it is. Your site will publish the change."
        case .discard:
            return "This ends the test before a clear answer, removes the variant page, and keeps \(experiment.page) as it is. Your site will publish the change."
        case nil:
            return ""
        }
    }

    private func concludeConfirmLabel(for decision: ExperimentHistoryStore.Outcome.Decision) -> String {
        switch decision {
        case .promote: return "Promote"
        case .keep: return "Keep the Original"
        case .discard: return "End Test"
        }
    }

    private func concludeConfirmRole(for decision: ExperimentHistoryStore.Outcome.Decision) -> ButtonRole? {
        switch decision {
        case .promote, .discard: return .destructive
        case .keep: return nil
        }
    }
}

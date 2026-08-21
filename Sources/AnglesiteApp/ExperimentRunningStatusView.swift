import SwiftUI
import AnglesiteCore

/// The running step of the experiment lifecycle (#1518): a live test with nothing left for the
/// owner to configure — just a status readout until it concludes. Reached from `.configure` once
/// `ExperimentStatsModel.observeDeployPhase(_:)` sees the starting deploy succeed.
struct ExperimentRunningStatusView: View {
    let experiment: DomainConfig.Experiments.Experiment

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
        }
    }
}

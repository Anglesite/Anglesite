import SwiftUI
import AnglesiteCore

/// The suggestion-browsing step of the experiment lifecycle (#1518): pick one of the playbook's
/// test ideas, or type a custom one, to seed a `ExperimentStatsModel.Draft` and move to
/// `.configure`. Reached from `.manual` by tapping a "Test ideas" row.
struct ExperimentProposeView: View {
    @Bindable var model: ExperimentStatsModel
    @State private var customName = ""

    var body: some View {
        Form {
            Section("What should we test?") {
                ForEach(model.suggestions, id: \.title) { suggestion in
                    Button {
                        model.propose(from: suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).font(.callout.weight(.medium))
                            Text(suggestion.rationale).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(suggestion.title)
                    .accessibilityHint(suggestion.rationale)
                }
            }
            Section("Or describe your own idea") {
                TextField("What are you testing?", text: $customName)
                Button("Start with this idea") { model.proposeCustom(name: customName) }
                    .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

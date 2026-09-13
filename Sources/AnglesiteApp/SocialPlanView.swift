import SwiftUI
import AnglesiteCore

struct SocialPlanView: View {
    @Bindable var model: SocialPlanModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Social Media Plan").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if model.unavailable {
                ContentUnavailableView(
                    "Apple Intelligence Required", systemImage: "sparkles",
                    description: Text(ContentHelpDialogs.assistantUnavailable(feature: "Social planning")))
            } else {
                HStack {
                    Stepper("Weeks: \(model.weeks)", value: $model.weeks, in: 1...8)
                    Spacer()
                    Button(model.markdown == nil ? "Generate Plan" : "Regenerate") {
                        Task { await model.generate() }
                    }
                    .disabled(model.running)
                    if model.running { ProgressView().controlSize(.small) }
                }
                if let markdown = model.markdown {
                    ScrollView {
                        Text(markdown)
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Spacer()
                        if model.saved { Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        Button("Save to docs/social-calendar.md") { model.save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.saved)
                    }
                } else if !model.running {
                    Text("Generates recommended platforms, bios, content pillars, and a weekly calendar — saved with your site, never posted for you.")
                        .foregroundStyle(.secondary)
                }
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
    }
}

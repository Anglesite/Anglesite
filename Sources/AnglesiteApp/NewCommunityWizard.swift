import SwiftUI
import AnglesiteCore

/// The New Community wizard (V-5.1b, #907, design doc §3) — one question (the community's
/// name), then it scaffolds into the default location and opens in the preview. A distinct
/// flow from ``NewSiteWizard``: a hosted community is a different site kind, not a theme
/// pick, so there is no template grid here.
struct NewCommunityWizard: View {
    @Bindable var model: NewCommunityWizardModel
    let scaffolder: SiteScaffolder
    let onComplete: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(width: 420, height: 220)
        .interactiveDismissDisabled(model.step == .building)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .chooser:  chooserStep
        case .building: buildingStep
        }
    }

    private var chooserStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name Your Community").font(.title2.bold())
            Text("Others will be able to join and post to it from any fediverse account.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Community Name", text: $model.communityName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit(create)
                .task { nameFieldFocused = true }
        }.padding(24)
    }

    private var buildingStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Building your community\u{2026}").font(.title2.bold())
            ForEach(Array(model.progress.enumerated()), id: \.offset) { _, s in
                Text(label(for: s)).font(.callout)
                    .accessibilityLabel(accessibilityLabel(for: s))
            }
            if case .failed(_, let msg) = model.fatal {
                Text(msg).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityLabel("Build failed")
                    .accessibilityValue(msg)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func label(for step: SiteScaffolder.ScaffoldStep) -> String {
        switch step {
        case .creatingFolder: return "\u{2705} Created the community file"
        case .copyingTemplate: return "\u{2705} Copied the template"
        case .applyingTheme: return "\u{2705} Applied the community theme"
        case .writingContent: return "\u{2705} Prepared the starter content"
        case .installing: return "\u{23F3} Installing\u{2026}"
        case .registering: return "\u{2705} Registering"
        case .warning(_, let m): return "\u{26A0}\u{FE0F} \(m)"
        case .failed(_, let m): return "\u{274C} \(m)"
        case .done: return "\u{2705} Done"
        }
    }

    private func accessibilityLabel(for step: SiteScaffolder.ScaffoldStep) -> String {
        switch step {
        case .creatingFolder:    return "Created the community file"
        case .copyingTemplate:   return "Copied the template"
        case .applyingTheme:     return "Applied the community theme"
        case .writingContent:    return "Prepared the starter content"
        case .installing:        return "Installing…"
        case .registering:       return "Registering"
        case .warning(_, let m): return "Warning: \(m)"
        case .failed(_, let m):  return "Failed: \(m)"
        case .done:              return "Done"
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            Spacer()
            if model.step == .chooser {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction).disabled(!model.canCreate)
            } else if model.completedSiteID == nil && model.fatal != nil {
                Button("Close") { onCancel() }
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func create() {
        guard model.canCreate else { return }
        Task {
            _ = await model.build(using: scaffolder)
            if model.didCompleteCleanly, let id = model.completedSiteID { onComplete(id) }
        }
    }
}

import SwiftUI
import AnglesiteCore

/// "Manage UTM Codes…" popup (#1092), opened from the Analytics tab of Website Settings. A live
/// list bound directly to `model.utmCampaigns` — the same array `PlistEditorModel`'s existing
/// dirty-facet machinery already tracks, so leaving the Analytics tab or closing the site window
/// persists edits exactly like Redirects. "Done" additionally attempts an explicit save so a
/// validation failure (e.g. two campaigns claiming the same target) is caught with the sheet
/// still open, rather than silently deferred until the owner leaves the whole Analytics tab.
struct UTMCodesSheet: View {
    @Bindable var model: PlistEditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("UTM Codes").font(.headline)
                Spacer()
                if model.isSavingUTMCodes {
                    ProgressView().controlSize(.small)
                }
                Button("Done") {
                    Task {
                        if await model.saveUTMCodes() {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }

            if model.utmCampaigns.isEmpty {
                Text("No UTM codes yet. Add one below.")
                    .foregroundStyle(.secondary)
            }

            List {
                ForEach($model.utmCampaigns) { $campaign in
                    UTMCampaignRow(campaign: $campaign, onDelete: {
                        model.utmCampaigns.removeAll { $0.id == campaign.id }
                    })
                }
            }
            .frame(minHeight: 240)

            Button {
                model.utmCampaigns.append(UTMCodesStore.Campaign())
            } label: {
                Label("Add UTM Code", systemImage: "plus")
            }

            if let utmCodesError = model.utmCodesError {
                Label(utmCodesError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 460)
    }
}

private struct UTMCampaignRow: View {
    @Binding var campaign: UTMCodesStore.Campaign
    let onDelete: () -> Void

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Source (e.g. rss)", text: $campaign.source)
                TextField("Medium (e.g. feed)", text: $campaign.medium)
                TextField("Campaign", text: $campaign.campaign)
                TextField("Term (optional)", text: optionalTextBinding($campaign.term))
                TextField("Content (optional)", text: optionalTextBinding($campaign.content))
                Text("Applies to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(UTMCodesStore.Target.allCases, id: \.self) { target in
                        Toggle(target.displayName, isOn: targetBinding(target))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 4)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary)
                    if !campaign.appliesTo.isEmpty {
                        Text(campaign.appliesTo.map(\.displayName).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var summary: String {
        let parts = [campaign.source, campaign.medium, campaign.campaign].filter { !$0.isEmpty }
        return parts.isEmpty ? "New UTM Code" : parts.joined(separator: " / ")
    }

    private func targetBinding(_ target: UTMCodesStore.Target) -> Binding<Bool> {
        Binding(
            get: { campaign.appliesTo.contains(target) },
            set: { isOn in
                if isOn {
                    if !campaign.appliesTo.contains(target) { campaign.appliesTo.append(target) }
                } else {
                    campaign.appliesTo.removeAll { $0 == target }
                }
            })
    }

    private func optionalTextBinding(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

import SwiftUI
import AnglesiteCore

struct RepurposeView: View {
    @Bindable var model: RepurposeModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Repurpose “\(model.post?.title ?? model.slug)”").font(.title2.bold())
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            // `PostRepurposer` requests the PCC tier (#1965): badge the sheet while it's served on-device.
            // Not when Apple Intelligence is unavailable — that state has its own explanation.
            if !model.unavailable { ModelTierNoticeView(tier: .privateCloudCompute) }
            if model.unavailable {
                ContentUnavailableView(
                    "Apple Intelligence Required", systemImage: "sparkles",
                    description: Text(ContentHelpDialogs.assistantUnavailable(feature: "Repurposing")))
            } else {
                if let domainWarning = model.domainWarning {
                    Label(domainWarning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                if model.variants.isEmpty && !model.running {
                    Text("Drafts platform-sized posts for this article. Anglesite never posts for you — copy each one out, then record the published URLs below.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(model.variants, id: \.platform) { variant in
                                variantCard(variant)
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        if model.syndicationSaved {
                            Label("Syndication recorded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        Button("Record Published URLs") { model.saveSyndication() }
                            .disabled(model.publishedURLs.values.allSatisfy(\.isEmpty) || model.syndicationSaved)
                    }
                }
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
        .task { if model.variants.isEmpty { await model.generate() } }
    }

    private func variantCard(_ variant: PlatformPostVariant) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(variant.platform).font(.headline)
                Spacer()
                if let text = variant.text {
                    Text("\(text.count) chars").font(.caption).foregroundStyle(.secondary)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                }
            }
            if let text = variant.text {
                Text(text)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                TextField("Published URL (paste after posting)", text: Binding(
                    get: { model.publishedURLs[variant.platform] ?? "" },
                    set: { model.publishedURLs[variant.platform] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            } else {
                Text(variant.failure ?? "Unavailable").foregroundStyle(.secondary).italic()
            }
        }
    }
}

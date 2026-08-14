import SwiftUI
import AnglesiteCore

/// The first-publish license gate (#999) — a hard-blocking comparison table shown before a
/// site's first deploy, so "All rights reserved" is a choice the owner made rather than a
/// default they never saw. Confirming resumes the deploy `DeployModel` parked in its
/// `pendingDeploy`. No per-collection overrides or the "Refuse AI crawlers" toggle here — those
/// stay in Settings ▸ Content Licensing; this sheet only needs one decision made.
struct LicenseGateSheetView: View {
    @Bindable var model: DeployModel

    /// One row's pure state: which license is selected, and (for `.custom`) the URL/name typed
    /// so far. A fresh instance per presentation — the gate never shows a prior choice, since it
    /// only appears when none has been recorded yet. Extracted as a plain struct (not held
    /// directly as separate `@State` fields) so `isContinueEnabled`/`resolvedLicense()` are
    /// unit-testable without a hosted SwiftUI render pass, mirroring
    /// `ContentLicensingTab.PendingCustomLicense`. Internal (not `private`) so tests can
    /// construct and mutate it directly.
    struct Selection: Equatable {
        enum Choice: Hashable {
            case allRightsReserved
            case catalog(String)
            case custom
        }

        var choice: Choice = .allRightsReserved
        var customURL: String = ""
        var customName: String = ""

        /// False only for an empty-URL custom selection — every other choice is already
        /// complete the moment it's picked.
        var isContinueEnabled: Bool {
            if case .custom = choice { return !customURL.isEmpty }
            return true
        }

        /// The `LicenseRef?` `DeployModel.confirmLicenseChoice(_:)` should persist for the
        /// current choice, or nil for "All rights reserved."
        func resolvedLicense() -> LicenseRef? {
            switch choice {
            case .allRightsReserved:
                return nil
            case .catalog(let id):
                return LicenseCatalog.entries.first { $0.id == id }?.ref
            case .custom:
                return LicenseRef(url: customURL, name: customName.isEmpty ? customURL : customName)
            }
        }
    }

    @State private var selection = Selection()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a License")
                .font(.title2.bold())
            Text("Before your first publish, pick what license covers your content. \"All rights reserved\" is a valid choice — Anglesite just never picks it for you silently.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("License")
                    Text("Permits")
                    Text("AI systems")
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)

                row(title: "All rights reserved", permits: "Nothing without asking", aiNote: nil,
                    choice: .allRightsReserved)

                ForEach(LicenseCatalog.entries) { entry in
                    row(
                        title: entry.name,
                        permits: permitsSummary(for: entry),
                        aiNote: entry.permitsAIUse ? "✅ Permits" : "❔ Unclear",
                        choice: .catalog(entry.id))
                }

                row(title: "Custom…", permits: "Your own terms", aiNote: nil, choice: .custom)
            }

            if selection.choice == .custom {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Address").frame(minWidth: 100, alignment: .leading)
                        TextField("https://example.com/license", text: $selection.customURL)
                            .frame(minWidth: 280)
                    }
                    GridRow {
                        Text("Name").frame(minWidth: 100, alignment: .leading)
                        TextField("My license", text: $selection.customName)
                            .frame(minWidth: 280)
                    }
                }
            }

            if let error = model.licenseGateError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Continue") {
                    model.confirmLicenseChoice(selection.resolvedLicense())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!selection.isContinueEnabled)
            }
        }
        .padding(24)
        .frame(minWidth: 520)
    }

    private func row(
        title: String, permits: String, aiNote: String?, choice: Selection.Choice
    ) -> some View {
        GridRow {
            Text(title)
            Text(permits).font(.caption).foregroundStyle(.secondary)
            Text(aiNote ?? "—").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(selection.choice == choice ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { selection.choice = choice }
    }

    /// Plain-language summary of what each catalog license permits — the middle comparison-table
    /// column. Keyed by catalog id rather than re-deriving from `permitsAIUse` so it stays
    /// independent of the AI classification the last column already renders.
    private func permitsSummary(for entry: LicenseCatalog.Entry) -> String {
        switch entry.id {
        case "cc0-1.0": return "Any use, no credit required"
        case "cc-by-4.0": return "Any use, with credit"
        case "cc-by-sa-4.0": return "Any use, with credit, same license"
        case "cc-by-nc-4.0": return "Non-commercial use, with credit"
        case "cc-by-nd-4.0": return "Redistribute unmodified, with credit"
        case "cc-by-nc-sa-4.0": return "Non-commercial use, with credit, same license"
        case "cc-by-nc-nd-4.0": return "Redistribute unmodified, non-commercial, with credit"
        default: return entry.name
        }
    }
}

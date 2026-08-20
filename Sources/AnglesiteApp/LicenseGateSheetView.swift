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
    /// so far. Re-seeded on every presentation from whatever license the site already records
    /// (see `init(existing:)`). Extracted as a plain struct (not held
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

        /// Seeds the selection from a license the site's `licensing.json` already records.
        ///
        /// The gate normally only appears when nothing has been chosen, so `nil` — an untouched
        /// scaffold — is the usual input and lands on "All rights reserved". But
        /// `defaultLicense` and `licenseChosen` are separate fields, and a hand-edited
        /// `licensing.json` (or any future writer that forgets the flag) can carry a real
        /// license with `licenseChosen == false`. Starting from that license means pressing
        /// Continue re-affirms it rather than silently replacing it with this sheet's default.
        init(existing license: LicenseRef? = nil) {
            guard let license else { return }
            if let entry = LicenseCatalog.entry(for: license) {
                choice = .catalog(entry.id)
            } else {
                choice = .custom
                customURL = license.url
                // `LicenseRef` decoding falls the name back to the URL, so a name equal to the
                // URL carries no information the Name field should show as if it were typed.
                customName = license.name == license.url ? "" : license.name
            }
        }

        /// False only for an empty-URL custom selection — every other choice is already
        /// complete the moment it's picked. Whitespace is trimmed before the emptiness check so
        /// a blank-looking URL is caught here rather than at `LicensingStore.save`'s validation
        /// boundary, which surfaces as an error banner instead of a disabled button.
        var isContinueEnabled: Bool {
            if case .custom = choice {
                return !customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
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

            VStack(alignment: .leading, spacing: 4) {
                // Header row. Deliberately an `HStack` with the same three column widths the
                // body rows use, not a `GridRow` — see `row(...)` for why this table isn't a
                // `Grid` at all; the columns line up because every row states the same widths.
                HStack(alignment: .firstTextBaseline, spacing: Self.columnSpacing) {
                    Text("License").frame(width: Self.licenseColumnWidth, alignment: .leading)
                    Text("Permits").frame(width: Self.permitsColumnWidth, alignment: .leading)
                    Text("AI systems").frame(width: Self.aiColumnWidth, alignment: .leading)
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)

                row(title: "All rights reserved", permits: "Nothing without asking",
                    aiNote: aiInterpretationLabel(LicenseCatalog.allRightsReservedInterpretation),
                    choice: .allRightsReserved)

                ForEach(LicenseCatalog.entries) { entry in
                    row(
                        // A license's own name ("CC BY 4.0") is catalog data, not UI copy, so
                        // it is deliberately not a literal key for extraction — the runtime
                        // lookup just falls back to the name itself.
                        title: LocalizedStringKey(entry.name),
                        permits: permitsSummary(for: entry),
                        aiNote: aiInterpretationLabel(entry.aiInterpretation),
                        choice: .catalog(entry.id))
                }

                row(title: "Custom…", permits: "Your own terms",
                    aiNote: aiInterpretationLabel(LicenseCatalog.customLicenseInterpretation), choice: .custom)
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
                // Backing out of a mis-clicked Deploy. Saves nothing, so the gate fires again on
                // the next Deploy — this abandons the attempt, it doesn't bypass the block.
                Button("Cancel") { model.cancelLicenseGate() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    Task { await model.confirmLicenseChoice(selection.resolvedLicense()) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!selection.isContinueEnabled)
            }
        }
        .padding(24)
        .frame(minWidth: 520)
        .onAppear {
            selection = Selection(existing: model.pendingLicensingPolicy?.defaultLicense)
        }
    }

    /// One selectable license row.
    ///
    /// Deliberately **not** a `GridRow` inside a `Grid`. Modifiers chained onto a `GridRow` are
    /// applied to each of its cells individually rather than to the row as a whole, so the
    /// earlier `Grid`-based version produced three disconnected backgrounds, three hit targets
    /// with dead gutters between the columns, three Tab stops, and three accessibility elements
    /// all announcing the same label — verified by rendering the rows with `ImageRenderer` and
    /// measuring the painted pixels. A single `Button` per row makes the row one view: one
    /// contiguous highlight, one content shape spanning the full width, one focus stop, and one
    /// accessibility element with the native button activation (Return/Space) that comes with it.
    /// The columns line up because every row — including the header — states the same three
    /// explicit frame widths, which is the alignment job `Grid` used to do.
    private func row(
        title: LocalizedStringKey, permits: LocalizedStringKey, aiNote: LocalizedStringKey,
        choice: Selection.Choice
    ) -> some View {
        Button {
            selection.choice = choice
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Self.columnSpacing) {
                Text(title)
                    .frame(width: Self.licenseColumnWidth, alignment: .leading)
                Text(permits)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: Self.permitsColumnWidth, alignment: .leading)
                Text(aiNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: Self.aiColumnWidth, alignment: .leading)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selection.choice == choice ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection.choice == choice ? .isSelected : [])
    }

    /// Column geometry for the comparison table. Shared by the header and every body row so the
    /// three columns line up without a `Grid` (see `row(...)`).
    private static let columnSpacing: CGFloat = 16
    private static let licenseColumnWidth: CGFloat = 150
    private static let permitsColumnWidth: CGFloat = 260
    private static let aiColumnWidth: CGFloat = 100

    /// Plain-language summary of what each catalog license permits — the middle comparison-table
    /// column. Keyed by catalog id rather than re-deriving from `aiInterpretation` so it stays
    /// independent of the AI classification the last column already renders.
    func permitsSummary(for entry: LicenseCatalog.Entry) -> LocalizedStringKey {
        switch entry.id {
        case "cc0-1.0": return "Any use, no credit required"
        case "cc-by-4.0": return "Any use, with credit"
        case "cc-by-sa-4.0": return "Any use, with credit, same license"
        case "cc-by-nc-4.0": return "Non-commercial use, with credit"
        case "cc-by-nd-4.0": return "Redistribute unmodified, with credit"
        case "cc-by-nc-sa-4.0": return "Non-commercial use, with credit, same license"
        case "cc-by-nc-nd-4.0": return "Redistribute unmodified, non-commercial, with credit"
        // Adding a `LicenseCatalog` entry should add a case above too — otherwise its Permits
        // column just repeats the license name (and, being catalog data rather than UI copy,
        // isn't a literal key the way every case above is).
        default: return LocalizedStringKey(entry.name)
        }
    }

    /// Row copy for the "AI systems" column, keyed by the 3-state classification (#999) rather
    /// than a bare bool — see `LicenseCatalog.AIInterpretation`.
    func aiInterpretationLabel(_ interpretation: LicenseCatalog.AIInterpretation) -> LocalizedStringKey {
        switch interpretation {
        case .permits: return "✅ Permits"
        case .unclear: return "❔ Unclear"
        case .prohibits: return "🚫 Prohibits"
        }
    }
}

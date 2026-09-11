import SwiftUI
import AnglesiteCore

/// Sync conflict resolution sheet (#881, design doc §3), re-phrased around the owner's content
/// (#1964, decision D1): "this was edited on two Macs — Anglesite will keep the newer version;
/// change any you'd rather keep the other way." Every conflicted file arrives with a default
/// already picked (`SyncConflictResolver.defaultChoice`: newer edit wins, this Mac on a tie), so
/// Apply is enabled the moment the list loads and the owner is never handed a per-file question
/// they have to answer from scratch. Quarantined `Config/conflicts/` copies list in the same sheet.
///
/// Mac-assed-app-spec compliance: standard sheet chrome (Cancel/Apply in the standard toolbar
/// placements — Esc and ⌘. both dismiss via Cancel, ⌘Return activates Apply), VoiceOver labels on
/// every control, and no state is silently discarded — Cancel leaves the conflict exactly as it
/// was; nothing here writes to the repo until Apply succeeds. The path and the git mechanics stay
/// out of the copy: the path is a tooltip, and "Compare Both…" opens plain files in Finder.
struct SyncConflictResolutionSheetView: View {
    @Bindable var model: SyncModel
    let siteName: String

    @State private var choices: [String: SyncConflictResolver.Choice] = [:]

    var body: some View {
        NavigationStack {
            List {
                if !model.conflictedFiles.isEmpty {
                    Section {
                        ForEach(model.conflictedFiles) { file in
                            conflictedFileRow(file)
                        }
                    } header: {
                        Text("Changed on both Macs")
                    } footer: {
                        Text("Anglesite keeps the newer version of each. Choose the other version for anything you'd rather keep from this Mac or the other one, then click Apply.")
                    }
                }
                if !model.quarantinedFiles.isEmpty {
                    Section {
                        ForEach(model.quarantinedFiles, id: \.self) { url in
                            quarantinedFileRow(url)
                        }
                    } header: {
                        Text("Extra copies iCloud saved")
                    } footer: {
                        Text("iCloud set these aside while the two Macs were syncing. Anglesite already has their content, so discarding them doesn't lose anything.")
                    }
                }
                if let error = model.resolutionError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error: \(error)")
                    }
                }
            }
            .navigationTitle("Edited on Two Macs")
            .navigationSubtitle(siteName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.dismissResolutionSheet() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        model.resolve(choices: choices)
                    } label: {
                        if model.isResolving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Apply")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isEveryConflictedFileResolved || model.isResolving)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        // Seed the default for every file as the list arrives (it loads asynchronously after the
        // sheet opens), without clobbering a choice the owner already changed by hand.
        .onChange(of: model.conflictedFiles, initial: true) { _, files in
            for file in files where choices[file.path] == nil {
                choices[file.path] = file.defaultChoice
            }
        }
        // Esc's default sheet-dismiss behavior is exactly Cancel here — resolving nothing is
        // always safe (the site stays editable, per the design doc; only pushing this branch
        // stays paused), so no `.interactiveDismissDisabled()` is needed.
    }

    private var isEveryConflictedFileResolved: Bool {
        !model.conflictedFiles.isEmpty && model.conflictedFiles.allSatisfy { choices[$0.path] != nil }
    }

    @ViewBuilder
    private func conflictedFileRow(_ file: SyncConflictResolver.ConflictedFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(file.displayName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.path)

            Picker("Keep which version", selection: Binding<SyncConflictResolver.Choice?>(
                get: { choices[file.path] },
                set: { choices[file.path] = $0 }
            )) {
                Text(sideLabel(String(localized: "This Mac"), date: file.oursDate, isNewer: file.defaultChoice == .keepMine))
                    .tag(Optional(SyncConflictResolver.Choice.keepMine))
                Text(sideLabel(String(localized: "Other Mac"), date: file.theirsDate, isNewer: file.defaultChoice == .keepTheirs))
                    .tag(Optional(SyncConflictResolver.Choice.keepTheirs))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Keep which version of \(file.displayName)")

            Button("Compare Both…") {
                model.openBothVersions(for: file)
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(file.oursText == nil && file.theirsText == nil)
            .accessibilityHint("Opens both versions of \(file.displayName) in Finder so you can compare them before choosing")
        }
        .padding(.vertical, 4)
    }

    /// Segment title for one side: the Mac, when it was edited, and which one Anglesite picked.
    /// Built as one string so VoiceOver reads the whole comparison off the segment itself.
    private func sideLabel(_ mac: String, date: Date?, isNewer: Bool) -> String {
        var label = mac
        if let date {
            label += " · \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        if isNewer {
            label += " " + String(localized: "(newer)")
        }
        return label
    }

    @ViewBuilder
    private func quarantinedFileRow(_ url: URL) -> some View {
        HStack {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(url.lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Reveal") { model.revealQuarantinedFile(url) }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityLabel("Reveal \(url.lastPathComponent) in Finder")
            Button("Discard", role: .destructive) { model.deleteQuarantinedFile(url) }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityLabel("Discard \(url.lastPathComponent)")
                .accessibilityHint("Anglesite already has this content saved, so discarding the copy doesn't lose anything")
        }
    }
}

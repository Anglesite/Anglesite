import SwiftUI
import AppKit
import AnglesiteCore

/// Slide-up drawer for a backup in progress and its terminal result. Mirrors
/// `DeployDrawerView`: spinner + streaming log during `.running`, structured result on
/// `.succeeded` / `.failed`. The `.noChanges` outcome is rendered by a separate banner —
/// the drawer never opens for it.
struct BackupDrawerView: View {
    @Bindable var model: BackupModel
    let siteName: String

    var body: some View {
        VStack(spacing: 0) {
            header
            if case .failed(let reason, let exit) = model.phase,
               let detail = OwnerFacingCopy.backup(reason: reason, exitCode: exit).detail {
                FailureDetailsView(detail: detail)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            Divider()
            logScroller
            Divider()
            footer
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .background(.regularMaterial)
    }

    // MARK: Sections

    private var header: some View {
        SheetHeader(title: headerTitle, subtitle: headerSubtitle, verticalPadding: 10) {
            statusIcon
        } trailing: {
            if case .succeeded(let sha, let branch, let remote, _) = model.phase {
                // The git identifiers stay one click away for a support conversation, but
                // never on the drawer face (#1963, D1).
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(sha) · \(branch) · \(remote)", forType: .string)
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.phase {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.title3)
        case .noChanges:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.secondary).font(.title3)
        case .failed:
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red).font(.title3)
        case .idle:
            Image(systemName: "externaldrive").font(.title3)
        }
    }

    private var headerTitle: String {
        switch model.phase {
        case .running: return "Backing up \(siteName)…"
        case .succeeded(_, _, let remote, _):
            return "Backed up to \(OwnerFacingCopy.backupDestination(remote: remote))"
        case .noChanges: return "Already backed up"
        case .failed: return "Backup failed"
        case .idle: return siteName
        }
    }

    private var headerSubtitle: String? {
        switch model.phase {
        case .succeeded(_, _, _, let duration):
            return String(localized: "Saved in \(String(format: "%.1f s", duration))")
        case .noChanges:
            return "No new changes to save."
        case .failed(let reason, let exit):
            return OwnerFacingCopy.backup(reason: reason, exitCode: exit).summary
        default:
            return nil
        }
    }

    private var logScroller: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.logLines) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.stream == .stderr ? Color.red : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                    if model.logLines.isEmpty {
                        Text("Waiting for output…")
                            .font(.caption).foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: model.logLines.count) { _, _ in
                if let last = model.logLines.last {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if case .failed = model.phase {
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText, forType: .string)
                }
            }
            Spacer()
            Button(model.isRunning ? "Hide" : "Dismiss") {
                model.dismissDrawer()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

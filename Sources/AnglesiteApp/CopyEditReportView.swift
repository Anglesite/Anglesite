import SwiftUI
import AppKit
import AnglesiteCore

/// The Review Copy sheet (#465): findings grouped by page, severity-badged, each with
/// diff-confirmed Apply / Save as Annotation / Copy Rewrite. Never batch-applies.
struct CopyEditReportView: View {
    @Bindable var model: CopyEditReportModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirming: CopyFinding?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Review Copy").font(.title2.bold())
                    Spacer()
                    if model.running { ProgressView().controlSize(.small) }
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                // `CopyEditAuditor` requests the PCC tier (#1965): badge the sheet while it's served on-device.
                // Not when Apple Intelligence is unavailable — that state has its own explanation.
                if !model.unavailable { ModelTierNoticeView(tier: .privateCloudCompute) }
            }
            .padding()
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 480)
        .task { if model.report == nil { await model.run() } }
        .alert("Copy Review", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog(
            "Apply this rewrite?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { finding in
            Button("Replace") { model.apply(finding); confirming = nil }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { finding in
            Text("“\(finding.excerpt)”\n\nbecomes\n\n“\(finding.suggestedRewrite)”")
        }
    }

    @ViewBuilder private var content: some View {
        if model.unavailable {
            ContentUnavailableView(
                "Apple Intelligence Required",
                systemImage: "sparkles",
                description: Text(ContentHelpDialogs.assistantUnavailable(feature: "Copy review")))
        } else if let message = model.report?.unavailableMessage {
            // Runtime unavailability (Apple Intelligence toggled off, on a 6.4+ toolchain) — same
            // explanation surface as the pre-6.4 `model.unavailable` case above.
            ContentUnavailableView(
                "Apple Intelligence Required",
                systemImage: "sparkles",
                description: Text(message))
        } else if model.running && model.report == nil {
            VStack(spacing: 8) {
                ProgressView()
                Text("Reviewing your site's copy, page by page…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report = model.report {
            reportList(report)
        }
    }

    private func reportList(_ report: CopyEditReport) -> some View {
        List {
            if report.findings.isEmpty {
                Text("No copy issues found across \(report.auditedCount) pages — nice work.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groupedRoutes(report), id: \.self) { route in
                Section(route) {
                    ForEach(report.findings.filter { $0.route == route }) { finding in
                        findingRow(finding)
                    }
                }
            }
            if !report.skippedRoutes.isEmpty {
                Section("Not reviewed") {
                    Text(report.skippedRoutes.joined(separator: ", ")).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func findingRow(_ finding: CopyFinding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                severityBadge(finding.severity)
                Text(finding.category).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.appliedFindingIDs.contains(finding.id) {
                    Label("Applied", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
            }
            Text(finding.issue)
            Text("“\(finding.excerpt)” → “\(finding.suggestedRewrite)”")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Apply…") { confirming = finding }
                    .disabled(!model.canApply(finding))
                Button("Save as Annotation") { model.saveAsAnnotation(finding) }
                    .disabled(model.annotatedFindingIDs.contains(finding.id))
                Button("Copy Rewrite") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(finding.suggestedRewrite, forType: .string)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func severityBadge(_ severity: CopyFindingSeverity) -> some View {
        let (label, color): (String, Color) = switch severity {
        case .high: ("High", .red)
        case .medium: ("Medium", .orange)
        case .low: ("Low", .gray)
        }
        return Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func groupedRoutes(_ report: CopyEditReport) -> [String] {
        var seen = Set<String>()
        return report.findings.map(\.route).filter { seen.insert($0).inserted }
    }
}

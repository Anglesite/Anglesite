import SwiftUI
import AnglesiteCore

struct HardenSheetView: View {
    @Bindable var model: HardenModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 620, minHeight: 380, idealHeight: 520)
    }

    // MARK: - Header

    private var header: some View {
        SheetHeader(title: headerTitle, subtitle: headerSubtitle) {
            statusIcon
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.phase {
        case .idle:
            Image(systemName: "shield.lefthalf.filled").font(.title3)
        case .resolvingZone, .applying:
            ProgressView().controlSize(.small)
        case .preview(let plan, _, _):
            Image(systemName: plan.isEmpty ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                .foregroundStyle(plan.isEmpty ? .green : .blue)
                .font(.title3)
        case .succeeded(let result):
            Image(systemName: result.failedItems.isEmpty ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.failedItems.isEmpty ? .green : .yellow)
                .font(.title3)
        case .failed:
            Image(systemName: "xmark.shield.fill")
                .foregroundStyle(.red).font(.title3)
        }
    }

    private var headerTitle: String {
        switch model.phase {
        case .idle:
            return "Harden Cloudflare"
        case .resolvingZone(let domain):
            return "Reading zone state for \(domain)…"
        case .preview(let plan, let domain, _):
            if plan.isEmpty { return "\(domain) is fully hardened" }
            return "\(plan.items.count) change\(plan.items.count == 1 ? "" : "s") for \(domain)"
        case .applying(_, let domain):
            return "Applying changes to \(domain)…"
        case .succeeded(let result):
            if result.failedItems.isEmpty {
                return "\(result.appliedCount) change\(result.appliedCount == 1 ? "" : "s") applied"
            }
            return "\(result.appliedCount) applied, \(result.failedItems.count) failed"
        case .failed:
            return "Hardening failed"
        }
    }

    private var headerSubtitle: String? {
        switch model.phase {
        case .preview(_, _, _):
            return "Review the changes below, then click Apply to proceed."
        case .succeeded(let result):
            if let err = result.auditError {
                return "Post-apply audit failed: \(err)"
            }
            let findings = result.postAuditFindings.count
            if findings == 0 { return "Post-apply audit: no remaining issues." }
            return "Post-apply audit: \(findings) remaining finding\(findings == 1 ? "" : "s")."
        case .failed:
            return nil
        default:
            return nil
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            domainInputForm
        case .resolvingZone:
            VStack(spacing: 8) {
                ProgressView()
                Text("Resolving zone and reading current state…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .preview(let plan, _, _):
            planPreview(plan)
        case .applying:
            VStack(spacing: 8) {
                ProgressView()
                Text("Applying hardening changes…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .succeeded(let result):
            resultView(result)
        case .failed(let reason):
            VStack(spacing: 12) {
                Image(systemName: "xmark.shield.fill")
                    .foregroundStyle(.red).font(.largeTitle)
                Text(reason)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var domainInputForm: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Enter the domain to harden")
                .font(.headline)
            Text("The domain must be managed in Cloudflare. Your API token needs Zone DNS Edit, Zone Settings Edit, and WAF Edit permissions.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            TextField("example.com", text: $model.domainInput)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .onSubmit { model.resolveAndPlan() }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private func planPreview(_ plan: HardenPlan) -> some View {
        if plan.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green).font(.largeTitle)
                Text("No changes needed.").font(.headline)
                Text("This zone already has all recommended hardening settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.items, id: \.self) { item in
                        planItemRow(item)
                    }

                    notIncludedSection
                }
                .padding(16)
            }
        }
    }

    private func planItemRow(_ item: HardenPlanItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
            Text(item.description)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.green.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var notIncludedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Explicitly not included")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 8)
            ForEach(Self.exclusions, id: \.self) { text in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Text(text)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private static let exclusions: [String] = [
            "Rate limiting (broken on free plan)",
            "Blanket user-agent blocking (breaks monitors, webhooks, RSS)",
        "Outdated-browser sniffing / referrer-based challenges",
    ]

    @ViewBuilder
    private func resultView(_ result: HardenModel.HardenResult) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if result.appliedCount > 0 {
                    Section {
                        Label("\(result.appliedCount) change\(result.appliedCount == 1 ? "" : "s") applied successfully.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    }
                }

                if !result.failedItems.isEmpty {
                    Section {
                        Text("Failed").font(.subheadline.weight(.semibold))
                        ForEach(Array(result.failedItems.enumerated()), id: \.element.description) { _, item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.description).font(.callout.weight(.medium))
                                Text(item.error).font(.caption).foregroundStyle(.red)
                            }
                            .padding(10)
                            .background(Color.red.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }

                if !result.postAuditFindings.isEmpty {
                    Section {
                        Text("Remaining audit findings").font(.subheadline.weight(.semibold))
                        ForEach(result.postAuditFindings) { finding in
                            auditFindingRow(finding)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func auditFindingRow(_ finding: AuditReport.Finding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            severityIcon(finding.severity)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(.callout.weight(.medium))
                Text(finding.detail).font(.callout).foregroundStyle(.primary)
                if let remediation = finding.remediation {
                    Text(remediation).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func severityIcon(_ severity: AuditReport.Finding.Severity) -> some View {
        switch severity {
        case .critical:
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .info:
            Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            switch model.phase {
            case .idle:
                Button("Scan") { model.resolveAndPlan() }
                    .disabled(model.domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
            case .preview(let plan, _, _) where !plan.isEmpty:
                Button("Apply \(plan.items.count) change\(plan.items.count == 1 ? "" : "s")") {
                    model.apply()
                }
                .buttonStyle(.borderedProminent)
            case .failed:
                Button("Try Again") {
                    model.retryFromFailed()
                }
            default:
                EmptyView()
            }
            Spacer()
            Button("Close") {
                model.dismissSheet()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

import SwiftUI
import AnglesiteCore

/// Circular deploy-readiness indicator + popover, rendered as a `ToolbarItem`
/// in `SiteWindow`'s window toolbar (high `visibilityPriority`, so it stays
/// visible as the window narrows).
///
/// The view is intentionally dumb: it reads `HealthModel`'s settled state and
/// surfaces the same data structures `BlockedDeploySheetView` already renders
/// (`PreDeployCheck.ScanFailure` / `ScanWarning`). The two actions — Recheck
/// and Ask Assistant — call back into the owner via closures so this view doesn't
/// need to know about `SiteStore`, `ChatModel`, or any wiring.
struct HealthBadgeView: View {
    @Bindable var model: HealthModel
    let onRecheck: () -> Void
    let onAskAssistant: () -> Void

    @State private var popoverPresented: Bool = false

    /// When set, the badge can't rely on color alone to convey state, so it draws a
    /// state-specific glyph instead of a plain dot (HIG: differentiate without color).
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// Badge geometry scales with Dynamic Type so the differentiate-without-color glyph stays
    /// legible at larger text sizes — the very users who turn that setting on. Anchored to
    /// `.body` so it tracks the system text size rather than a fixed point size.
    @ScaledMetric(relativeTo: .body) private var badgeDimension = 18
    @ScaledMetric(relativeTo: .body) private var glyphSize = 11

    var body: some View {
        Button {
            popoverPresented.toggle()
        } label: {
            indicator
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .help(helpText)
        .accessibilityLabel("Publish readiness")
        .accessibilityValue(headerTitle)
        .accessibilityHint("Shows the most recent pre-deploy scan results")
        .popover(isPresented: $popoverPresented, arrowEdge: .top) {
            popoverContent
                .padding(14)
                .frame(width: 360)
        }
    }

    @ViewBuilder
    private var indicator: some View {
        ZStack {
            if differentiateWithoutColor {
                Image(systemName: stateSymbol)
                    .font(.system(size: glyphSize, weight: .bold))
                    .foregroundStyle(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
            }
            if model.isRunning {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: 14, height: 14)
            }
        }
        .frame(width: badgeDimension, height: badgeDimension, alignment: .center)
        .contentShape(Rectangle())
    }

    /// Shape that distinguishes badge state without relying on color.
    private var stateSymbol: String {
        switch model.badgeState {
        case .unknown:  return "questionmark"
        case .clean:    return "checkmark"
        case .warnings: return "exclamationmark"
        case .failures: return "xmark"
        }
    }

    private var color: Color {
        switch model.badgeState {
        case .unknown:  return .secondary.opacity(0.6)
        case .clean:    return .green
        case .warnings: return .yellow
        case .failures: return .red
        }
    }

    private var helpText: String {
        switch model.badgeState {
        case .unknown:  return "Publish-readiness check has not run yet"
        case .clean:    return "Most recent scan: no issues"
        case .warnings: return "Most recent scan: warnings only"
        case .failures: return "Most recent scan: failures — publishing is blocked"
        }
    }

    // MARK: - Popover

    @ViewBuilder
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            findings
            Divider()
            footerButtons
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(headerTitle).font(.headline)
            Spacer()
            Text(timestampText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var headerTitle: String {
        switch model.badgeState {
        case .unknown:  return "Health unknown"
        case .clean:    return "Ready to publish"
        case .warnings: return "Warnings"
        case .failures: return "Issues found"
        }
    }

    private var timestampText: String {
        guard let date = model.lastCheckedAt else { return "Never checked" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Checked \(f.localizedString(for: date, relativeTo: Date()))"
    }

    @ViewBuilder
    private var findings: some View {
        if let failure = model.lastFailure {
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't run the check").font(.subheadline.weight(.semibold))
                Text(failureMessage(failure))
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if let outcome = model.lastOutcome {
            outcomeFindings(outcome)
        } else {
            Text("Click Recheck to run the pre-deploy scan against this site.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func outcomeFindings(_ outcome: PreDeployCheck.Outcome) -> some View {
        switch outcome {
        case .passed(let warnings) where warnings.isEmpty:
            Text("No issues found in the most recent scan.")
                .font(.callout).foregroundStyle(.secondary)
        case .passed(let warnings):
            findingsList(failures: [], warnings: warnings)
        case .blocked(let failures, let warnings):
            findingsList(failures: failures, warnings: warnings)
        case .error(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Text("Scan couldn't run").font(.subheadline.weight(.semibold))
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func findingsList(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !failures.isEmpty {
                Text("Blocking (\(failures.count))").font(.subheadline.weight(.semibold))
                ForEach(failures.indices, id: \.self) { i in
                    let f = failures[i]
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.detail ?? f.message).font(.callout)
                            if let file = f.file {
                                Text(file).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if let remediation = f.remediation {
                                Text(remediation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !warnings.isEmpty {
                Text("Warnings (\(warnings.count))").font(.subheadline.weight(.semibold))
                ForEach(warnings.indices, id: \.self) { i in
                    let w = warnings[i]
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.detail ?? w.message).font(.callout)
                            if let remediation = w.remediation {
                                Text(remediation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func failureMessage(_ reason: HealthModel.FailureReason) -> String {
        switch reason {
        case .buildFailed(let m): return "Build failed before the scan could run: \(m)"
        case .scanFailed(let m): return "Scan failed: \(m)"
        }
    }

    private var footerButtons: some View {
        HStack {
            Button("Ask Assistant") {
                popoverPresented = false
                onAskAssistant()
            }
            .controlSize(.small)
            .help("Open the chat panel for a deeper AI audit of this site")

            Spacer()

            Button {
                onRecheck()
            } label: {
                if model.isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                    }
                } else {
                    Text("Recheck")
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(model.isRunning)
        }
    }
}

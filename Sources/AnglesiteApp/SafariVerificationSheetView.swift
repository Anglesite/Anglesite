import SwiftUI
import AppKit
import AnglesiteCore

/// Renders one `SafariVerificationPass` run (#1911): console errors, failed network requests, a
/// page-content summary, and a screenshot — each section independently `.available` or
/// `.unavailable(reason:)` per `SafariVerificationReport`. Modeled on `AgentReadinessSheetView`'s
/// idle-prompt → running → succeeded/failed shape.
struct SafariVerificationSheetView: View {
    @Bindable var model: SafariVerificationModel
    /// Resolves the current live preview URL and starts a pass — wired in `SiteWindow` to
    /// `SiteWindowModel.runSafariVerification()`, since only that model knows the current
    /// `PreviewModel` state at the moment the owner clicks Run/Rescan/Try Again.
    let onRun: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
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
            Image(systemName: "safari").font(.title3)
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.title3)
        case .failed:
            Image(systemName: "xmark.seal.fill").foregroundStyle(.red).font(.title3)
        }
    }

    private var headerTitle: String {
        switch model.phase {
        case .idle: return "Safari Verification"
        case .running(let url): return "Checking \(url.host ?? url.absoluteString)…"
        case .succeeded(_, let url): return "Verified \(url.host ?? url.absoluteString)"
        case .failed: return "Couldn't complete the verification pass"
        }
    }

    private var headerSubtitle: String? {
        switch model.phase {
        case .idle:
            return "Uses the connected Safari MCP session to inspect the live preview."
        case .running:
            return "Loading the preview in Safari and collecting console, network, and page data…"
        case .succeeded(let report, _):
            return "console: \(sectionSummary(report.console)) · network: \(sectionSummary(report.network))"
        case .failed:
            return nil
        }
    }

    private func sectionSummary<Value: Sendable & Equatable>(
        _ section: SafariVerificationReport.Section<SafariVerificationReport.CappedList<Value>>
    ) -> String {
        switch section {
        case .available(let list): return "\(list.entries.count)\(list.truncated ? "+" : "")"
        case .unavailable: return "unavailable"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            idlePrompt
        case .running:
            VStack(spacing: 8) {
                ProgressView()
                Text("Running a Safari-backed verification pass…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .succeeded(let report, _):
            reportView(report)
        case .failed(let reason):
            VStack(spacing: 12) {
                Image(systemName: "xmark.seal.fill")
                    .foregroundStyle(.red).font(.largeTitle)
                Text(reason)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var idlePrompt: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "safari")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Verify with Safari?")
                .font(.headline)
            Text("Runs one read-only inspection pass of the live preview over the connected Safari MCP session — console errors, failed network requests, a page-content summary, and a screenshot. It never edits site files.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .padding(16)
    }

    private func reportView(_ report: SafariVerificationReport) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                consoleSection(report.console)
                networkSection(report.network)
                pageContentSection(report.pageContent)
                screenshotSection(report.screenshot)
            }
            .padding(16)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func consoleSection(
        _ section: SafariVerificationReport.Section<SafariVerificationReport.CappedList<SafariVerificationReport.ConsoleEntry>>
    ) -> some View {
        sectionContainer(title: "Console") {
            switch section {
            case .unavailable(let reason):
                unavailableRow(reason)
            case .available(let list) where list.entries.isEmpty:
                Text("No console messages.").font(.callout).foregroundStyle(.secondary)
            case .available(let list):
                ForEach(Array(list.entries.enumerated()), id: \.offset) { _, entry in
                    Text("[\(entry.level)] \(entry.text)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(entry.level.lowercased() == "error" ? Color.red : Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if list.truncated {
                    truncatedNote()
                }
            }
        }
    }

    @ViewBuilder
    private func networkSection(
        _ section: SafariVerificationReport.Section<SafariVerificationReport.CappedList<SafariVerificationReport.NetworkEntry>>
    ) -> some View {
        sectionContainer(title: "Network") {
            switch section {
            case .unavailable(let reason):
                unavailableRow(reason)
            case .available(let list) where list.entries.isEmpty:
                Text("No network requests observed.").font(.callout).foregroundStyle(.secondary)
            case .available(let list):
                ForEach(Array(list.entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.method ?? "?").font(.caption.monospaced().weight(.medium))
                        Text(entry.url).font(.caption.monospaced())
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        if let status = entry.status {
                            Text("\(status)").font(.caption.monospaced())
                                .foregroundStyle(entry.failed ? Color.red : Color.secondary)
                        }
                    }
                    .textSelection(.enabled)
                }
                if list.truncated {
                    truncatedNote()
                }
            }
        }
    }

    @ViewBuilder
    private func pageContentSection(_ section: SafariVerificationReport.Section<String>) -> some View {
        sectionContainer(title: "Page content") {
            switch section {
            case .unavailable(let reason):
                unavailableRow(reason)
            case .available(let text):
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(20)
            }
        }
    }

    @ViewBuilder
    private func screenshotSection(_ section: SafariVerificationReport.Section<Data>) -> some View {
        sectionContainer(title: "Screenshot") {
            switch section {
            case .unavailable(let reason):
                unavailableRow(reason)
            case .available(let data):
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    unavailableRow("captured image data couldn't be decoded")
                }
            }
        }
    }

    // MARK: - Section chrome

    @ViewBuilder
    private func sectionContainer(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func unavailableRow(_ reason: String) -> some View {
        Text("Unavailable — \(reason)")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func truncatedNote() -> some View {
        Text("Showing the first 200 entries.")
            .font(.caption2).foregroundStyle(.tertiary)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            switch model.phase {
            case .idle:
                Button("Run Verification") { onRun() }
                    .buttonStyle(.borderedProminent)
            case .succeeded:
                Button("Run Again") { onRun() }
            case .failed:
                Button("Try Again") { onRun() }
            case .running:
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

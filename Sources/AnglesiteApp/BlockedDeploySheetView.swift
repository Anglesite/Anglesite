import SwiftUI
import AnglesiteCore

/// Modal sheet shown when the pre-deploy scan refuses a deploy, a "Publish to GitHub", or a
/// backup (#1959 — the same no-override gate fronts all three off-device pushes of `Source/`).
///
/// Per the CLAUDE.md durable rule "the app cannot bypass plugin security hooks", this sheet has
/// no override button — the only action dismisses. Because the owner can't override it, the sheet
/// has to say more than a bypassable warning would (#2211): what was found and what publishing it
/// would do, in the owner's terms; where it is, as a page address; and — always — that nothing
/// left the Mac. The scan's own wording and file paths are technical (`dist/`, `_headers`), so
/// they stay under each finding's Details disclosure (decision D1). Copy lives in
/// `OwnerFacingCopy.gate(_:)`.
struct BlockedDeploySheetView: View {
    /// Which action the gate refused — the findings list below reads identically for every
    /// context; only the header's consequence copy differs, so a blocked **Backup** doesn't tell
    /// the owner their site won't "publish" when they only asked to back it up (PR #1981
    /// review). Deploy and "Publish to GitHub" share `.shipping`'s wording.
    enum Context: Equatable {
        case shipping
        case backup

        var title: String {
            switch self {
            case .shipping: return String(localized: "Your changes weren't published")
            case .backup: return String(localized: "Your site wasn't backed up")
            }
        }

        /// What is safe. Required content, not decoration: with no override, this is the line
        /// that tells the owner nothing went wrong in public.
        var reassurance: String {
            switch self {
            case .shipping:
                return String(localized: "Anglesite's safety check found something that shouldn't go public. Nothing was published — your live site hasn't changed, and your edits are saved.")
            case .backup:
                return String(localized: "Anglesite's safety check found something that shouldn't leave this Mac. Nothing was sent, and your edits are saved.")
            }
        }

        var nextStep: String {
            switch self {
            case .shipping: return String(localized: "Fix each item below, then publish again.")
            case .backup: return String(localized: "Fix each item below, then back up again.")
            }
        }
    }

    /// Defaults to `.shipping` so Deploy's own call site (predating this parameter) keeps
    /// compiling unchanged.
    var context: Context = .shipping
    let failures: [PreDeployCheck.ScanFailure]
    let warnings: [PreDeployCheck.ScanWarning]
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(context.nextStep)
                        .font(.subheadline).fontWeight(.semibold)
                    ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                        FindingCard(finding: OwnerFacingCopy.gate(failure), severity: .blocker)
                    }
                    if !warnings.isEmpty {
                        Divider().padding(.vertical, 4)
                        Text("Also worth a look")
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text("These don't stop publishing.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                            FindingCard(finding: OwnerFacingCopy.gate(warning), severity: .advisory)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("OK", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(context.title).font(.title3).fontWeight(.semibold)
                Text(context.reassurance)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct FindingCard: View {
    enum Severity { case blocker, advisory }

    let finding: OwnerFacingCopy.GateFinding
    let severity: Severity

    private var tint: Color { severity == .blocker ? .red : .orange }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: severity == .blocker ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(finding.title)
                    .font(.subheadline).fontWeight(.semibold)
                if let page = finding.page {
                    Text("On \(page)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Text(finding.consequence)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = finding.detail {
                DisclosureGroup("Show Details") {
                    Text(verbatim: detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

#Preview {
    BlockedDeploySheetView(
        failures: [
            .init(
                category: .exposedToken,
                message: "Pattern matching a Stripe secret key in built output.",
                file: "dist/contact/index.html",
                remediation: "Remove the key from the page and move it to Cloudflare secrets."
            ),
            .init(category: .piiEmail, message: "Email address found: jo@example.com", file: "dist/about/index.html"),
        ],
        warnings: [
            .init(category: .missingOgImage, message: "dist/blog/index.html lacks og:image", file: "dist/blog/index.html"),
        ],
        onDismiss: {}
    )
}

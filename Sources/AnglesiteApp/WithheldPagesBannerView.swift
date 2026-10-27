import SwiftUI
import AnglesiteCore

/// Non-blocking banner on an EmDash site when the render backstop is holding pages back from
/// readers (#2097, #2055 slice 4). Docked above the content like `SiteUpdateNoticeBannerView`. The
/// line says what it means for the site; Details lists each page and why, in owner terms (decision
/// D1). The fix happens in EmDash, so Open EmDash is offered when the admin is known.
struct WithheldPagesBannerView: View {
    let pages: [WithheldPage]
    let canOpenEmDash: Bool
    let onOpenEmDash: () -> Void
    let onDismiss: () -> Void

    @State private var detailsPresented = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(verbatim: Self.message(count: pages.count))
                .font(.callout)
            Spacer(minLength: 12)
            Button("Details") { detailsPresented.toggle() }
                .controlSize(.small)
                .popover(isPresented: $detailsPresented, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(pages) { page in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: page.path)
                                    .font(.callout.monospaced())
                                ForEach(page.reasons, id: \.self) { reason in
                                    Text(verbatim: Self.explanation(for: reason))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(width: 380, alignment: .leading)
                }
            if canOpenEmDash {
                Button("Open EmDash", action: onOpenEmDash)
                    .controlSize(.small)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .accessibilityLabel("Dismiss")
            .help("Hide this notice")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12), in: Rectangle())
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.withheldPagesBanner)
    }

    static func message(count: Int) -> String {
        count == 1
            ? String(localized: "An article isn't showing to readers because it needs a fix.")
            : String(localized: "\(count) articles aren't showing to readers because they need a fix.")
    }

    static func explanation(for reason: WithheldPage.Reason) -> String {
        switch reason {
        case .secret:
            String(localized: "It contains something that looks like a password or access key.")
        case .restrictedContent:
            String(localized: "It shows something meant only for your contacts.")
        case .adminLink:
            String(localized: "It links to a page for editing the site.")
        case .uncheckable:
            String(localized: "It couldn't be checked, so it's being held back to be safe.")
        }
    }
}

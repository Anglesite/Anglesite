import SwiftUI
import AnglesiteCore

/// Non-blocking banner shown after a site opens and Anglesite applied the updates it maintains
/// (#1962) — docked above the content like `SyncConflictBannerView` (#881), never a sheet, so
/// the site stays fully usable while it's up. The primary line is phrased about the site; the
/// technical detail (which files, which packages) sits behind a Details popover for the curious.
struct SiteUpdateNoticeBannerView: View {
    let notice: SiteOpenUpdateNotice
    let onDismiss: () -> Void

    @State private var detailsPresented = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(verbatim: notice.message)
                .font(.callout)
            Spacer(minLength: 12)
            if !notice.details.isEmpty {
                Button("Details") { detailsPresented.toggle() }
                    .controlSize(.small)
                    .popover(isPresented: $detailsPresented, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(notice.details.enumerated()), id: \.offset) { _, line in
                                Text(verbatim: line)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(16)
                        .frame(width: 380, alignment: .leading)
                    }
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
        .background(.tint.opacity(0.10), in: Rectangle())
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.siteUpdateNoticeBanner)
    }
}

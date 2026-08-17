import SwiftUI

/// Shared status/category header for sheets and drawers: an icon beside a title/subtitle
/// stack, with an optional trailing slot for header-level actions (e.g. `BackupDrawerView`'s
/// "Copy SHA" button). By construction it groups the title/subtitle into a single VoiceOver
/// stop and hides the status icon, which is redundant with the adjacent title text (2026-08-16
/// semantic accessibility audit, checklist §4 "Grouping Elements" and §5 "Hiding Decorative
/// Elements").
struct SheetHeader<Icon: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    var verticalPadding: CGFloat = 12
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        verticalPadding: CGFloat = 12,
        @ViewBuilder icon: @escaping () -> Icon,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.verticalPadding = verticalPadding
        self.icon = icon
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            icon()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, verticalPadding)
    }
}

#Preview {
    VStack(spacing: 0) {
        SheetHeader(title: "Manage Domain", subtitle: "3 DNS records for example.com") {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
        }
        Divider()
        SheetHeader(title: "Backing up my-site…", subtitle: "Committing 4 files", verticalPadding: 10) {
            ProgressView().controlSize(.small)
        } trailing: {
            Button("Copy SHA") {}
        }
    }
}

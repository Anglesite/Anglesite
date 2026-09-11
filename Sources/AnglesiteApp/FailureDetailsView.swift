import SwiftUI

/// The "Details" disclosure that keeps a failure's technical reason (the raw git/npm/wrangler
/// line, exit code included) one click away from the owner-phrased summary above it (#1963,
/// D1). Collapsed by default so the primary surface never leads with tool vocabulary; the
/// text is selectable so it can be pasted into a support conversation.
struct FailureDetailsView: View {
    let detail: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Details", isExpanded: $expanded) {
            Text(detail)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
        .font(.caption)
        .accessibilityIdentifier("failure-details")
    }
}

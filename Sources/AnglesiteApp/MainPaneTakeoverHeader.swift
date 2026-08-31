import SwiftUI

/// Shared header for a main-pane "takeover" — Editor, Graph, or Cleanup (#714 v2 slice 2): a
/// leading icon/title, an optional trailing accessory (e.g. the editor's dirty dot and Save
/// button), and a Done control that always returns to the canvas. Selecting a page in the
/// navigator already does this via `SiteWindowModel.applyNavigatorSelection`'s `.route` branch;
/// this is the explicit, discoverable equivalent for a takeover reached with no page selection in
/// play — opening a file directly, Website ▸ Graph…, or Website ▸ Cleanup….
struct MainPaneTakeoverHeader<Title: View, Accessory: View>: View {
    let systemImage: String
    let onDone: () -> Void
    /// `Text`-producing so callers choose localization explicitly: `Text("Settings")` for a
    /// fixed, translatable title, `Text(verbatim: model.file.name)` for one built from runtime
    /// content that must never be parsed as Markdown or looked up as a catalog key (#1686
    /// review — a `LocalizedStringKey`-typed title did both to a dynamic file name: underscores
    /// were consumed as emphasis delimiters, and a filename matching an existing catalog key
    /// rendered that key's translation instead of the filename).
    @ViewBuilder var title: () -> Title
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack {
            Label {
                title()
            } icon: {
                Image(systemName: systemImage)
            }
            .font(.headline)
            // One shared identifier across every takeover, mirroring `SheetHeader`'s
            // `AXID.sheetHeader` precedent (#1686 review): automation reads the label to learn
            // which takeover is showing rather than needing a per-takeover identifier.
            .accessibilityIdentifier(AXID.mainPaneTakeoverHeader)
            Spacer()
            accessory()
            Button("Done", action: onDone)
                .accessibilityIdentifier(AXID.mainPaneTakeoverDone)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

extension MainPaneTakeoverHeader where Accessory == EmptyView {
    init(systemImage: String, onDone: @escaping () -> Void, @ViewBuilder title: @escaping () -> Title) {
        self.init(systemImage: systemImage, onDone: onDone, title: title) { EmptyView() }
    }
}

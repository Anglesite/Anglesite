import SwiftUI

/// Shared header for a main-pane "takeover" — Editor, Graph, or Cleanup (#714 v2 slice 2): a
/// leading icon/title, an optional trailing accessory (e.g. the editor's dirty dot and Save
/// button), and a Done control that always returns to the canvas. Selecting a page in the
/// navigator already does this via `SiteWindowModel.applyNavigatorSelection`'s `.route` branch;
/// this is the explicit, discoverable equivalent for a takeover reached with no page selection in
/// play — opening a file directly, Website ▸ Graph…, or Website ▸ Cleanup….
struct MainPaneTakeoverHeader<Accessory: View>: View {
    let title: String
    let systemImage: String
    let onDone: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Spacer()
            accessory()
            Button("Done", action: onDone)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

extension MainPaneTakeoverHeader where Accessory == EmptyView {
    init(title: String, systemImage: String, onDone: @escaping () -> Void) {
        self.init(title: title, systemImage: systemImage, onDone: onDone) { EmptyView() }
    }
}

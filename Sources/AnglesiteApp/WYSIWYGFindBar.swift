import SwiftUI

/// The WYSIWYG canvas's native find bar (#1588 Task 19, design doc §4: "native ⌘F find bar").
/// Thin chrome over `WYSIWYGCanvasController.find(_:backwards:)` — WebKit owns match
/// highlighting/scrolling via `WKWebView.find` itself. `EditMenuSkeletonCommands.performFind()`
/// flips `controller.isFindBarPresented` on; the "Done" button (or Escape) flips it back off.
struct WYSIWYGFindBar: View {
    @Bindable var controller: WYSIWYGCanvasController
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        if controller.isFindBarPresented {
            HStack {
                TextField("Find", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { controller.find(query) }
                    .frame(maxWidth: 240)
                Button {
                    controller.find(query, backwards: true)
                } label: {
                    Image(systemName: "chevron.up")
                }
                Button {
                    controller.find(query)
                } label: {
                    Image(systemName: "chevron.down")
                }
                Button("Done") {
                    controller.isFindBarPresented = false
                }
                .keyboardShortcut(.escape)
            }
            .padding(8)
            .background(.bar)
            .onAppear { focused = true }
        }
    }
}

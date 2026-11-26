import AppKit
import SwiftUI
import WebKit
import AnglesiteBridgeCore

/// Format ▸ Add Link… on the block editor canvas (#2216): a native popover with an address field,
/// anchored to the selected text. The JS calls, reply decoding and anchor math live in
/// `WYSIWYGLinkEdit` (AnglesiteBridgeCore). This type owns only the AppKit presentation.
///
/// Moving focus into the popover blurs the page's `contentEditable` block. `beginLinkEdit()` holds
/// the editing session open across that, so the selection is still there to link on Return.
/// Every way the popover closes releases the hold exactly once: Return commits, and anything else
/// (Escape, Cancel, a click outside) cancels in `popoverDidClose(_:)`.
@MainActor
final class WYSIWYGLinkPopoverPresenter: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var model: WYSIWYGLinkPopoverModel?
    private weak var webView: WKWebView?
    /// Set once a commit closed the popover, so `popoverDidClose(_:)` doesn't also cancel.
    private var committed = false
    /// Guards against Return reaching both the field's submit and the default button.
    private var isCommitting = false

    /// Starts a link edit on `webView`'s active text block. Beeps instead when there's nothing to
    /// link: no text block being edited, or no text selected and no link under the caret.
    func present(in webView: WKWebView) async {
        guard popover == nil else { return }
        let reply = try? await webView.callAsyncJavaScript(
            WYSIWYGLinkEdit.beginScript, arguments: [:], in: nil, contentWorld: .page)
        guard let context = WYSIWYGLinkEdit.Context(jsReply: reply) else {
            NSSound.beep()
            return
        }

        let model = WYSIWYGLinkPopoverModel(address: context.href ?? "", isEditingExistingLink: context.href != nil)
        let view = WYSIWYGLinkPopoverView(
            model: model,
            selectedText: context.text,
            onCommit: { [weak self] in Task { await self?.commit() } },
            onCancel: { [weak self] in self?.popover?.performClose(nil) })

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = NSHostingController(rootView: view)
        popover.delegate = self

        self.popover = popover
        self.model = model
        self.webView = webView
        committed = false

        let anchor = WYSIWYGLinkEdit.anchorRect(
            for: context.rect,
            zoom: Double(webView.pageZoom * webView.magnification),
            viewHeight: Double(webView.bounds.height),
            isFlipped: webView.isFlipped)
        // A selection scrolled out of view still gets a popover, anchored mid-canvas.
        let visibleAnchor = webView.bounds.intersects(anchor)
            ? anchor
            : CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 1, height: 1)
        // Below the selection, so the linked text stays visible while the owner types.
        popover.show(relativeTo: visibleAnchor, of: webView, preferredEdge: webView.isFlipped ? .maxY : .minY)
    }

    private func commit() async {
        guard let webView, let model, !isCommitting else { return }
        isCommitting = true
        defer { isCommitting = false }
        let reply = try? await webView.callAsyncJavaScript(
            WYSIWYGLinkEdit.commitScript, arguments: ["href": model.address], in: nil, contentWorld: .page)
        let result = (reply as? String).flatMap(WYSIWYGLinkEdit.CommitResult.init(rawValue:)) ?? .stale
        if result.closesPopover {
            committed = true
            popover?.performClose(nil)
        } else {
            model.isInvalid = true
            NSSound.beep()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if !committed { webView?.evaluateJavaScript(WYSIWYGLinkEdit.cancelScript) }
        // Back to the canvas, where `commitLinkEdit`/`cancelLinkEdit` already restored the
        // selection inside the page.
        webView?.window?.makeFirstResponder(webView)
        popover = nil
        model = nil
        committed = false
    }
}

@MainActor @Observable
final class WYSIWYGLinkPopoverModel {
    var address: String {
        didSet { isInvalid = false }
    }
    var isInvalid = false
    let isEditingExistingLink: Bool

    init(address: String, isEditingExistingLink: Bool) {
        self.address = address
        self.isEditingExistingLink = isEditingExistingLink
    }
}

/// The popover's content: one address field, Return to apply and Escape to cancel. Leaving the
/// field empty and pressing Return removes an existing link.
struct WYSIWYGLinkPopoverView: View {
    @Bindable var model: WYSIWYGLinkPopoverModel
    let selectedText: String
    let onCommit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Link to", text: $model.address, prompt: Text(verbatim: "example.com"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused($isFieldFocused)
                .onSubmit(onCommit)
                .accessibilityLabel(Text("Link address for “\(selectedText)”"))
            if model.isInvalid {
                Text("That address can’t be used as a link.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(
                    model.isEditingExistingLink ? LocalizedStringKey("Update Link") : LocalizedStringKey("Add Link"),
                    action: onCommit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear { isFieldFocused = true }
        .onChange(of: model.isInvalid) { _, isInvalid in
            if isInvalid {
                AccessibilityNotification.Announcement(String(localized: "That address can’t be used as a link.")).post()
            }
        }
    }
}

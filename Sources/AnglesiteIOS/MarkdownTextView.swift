// Sources/AnglesiteIOS/MarkdownTextView.swift
#if os(iOS)
import SwiftUI
import UIKit

/// The iOS counterpart of the Mac's `MarkdownTextView` (#869) — the Micropub composer's body
/// surface, mirroring the AppKit seam's shape (`$text` binding, `documentId`, `fitsContent`).
///
/// **Substrate spike result (#869, 2026-08-08):** the design (2026-07-21, §6) called for
/// `UIViewRepresentable` over the same `swift-markdown-engine` substrate the Mac editor uses,
/// on the parent spec's assertion that the engine "already supports both AppKit and UIKit".
/// The spike falsified that: both the pinned Anglesite fork and upstream
/// `nodes-app/swift-markdown-engine` declare `platforms: [.macOS(.v14)]` only, and every view
/// file imports AppKit (`NativeTextViewWrapper` is `NSViewRepresentable`) — there is no UIKit
/// support to wrap. Rather than block the posting client on a cross-repo engine port, v1 wraps a
/// plain `UITextView` configured to preserve Markdown byte-for-byte; live styled editing arrives
/// when the engine fork grows UIKit support.
///
/// What "configured for Markdown" means here (the same corruption vectors the Mac seam disables
/// on the engine): smart quotes/dashes are OFF (they'd corrupt frontmatter, code spans, and
/// `--`-style constructs), as is smart insert/delete (invisible whitespace edits). Autocorrection
/// and sentence capitalization stay ON — this is prose-first compose, and neither rewrites text
/// the user didn't touch. The view never transforms the bound string: what the user typed is
/// what the binding holds, so an open→close with no edits is byte-identical by construction.
public struct MarkdownTextView: UIViewRepresentable {
    @Binding public var text: String
    /// Names the logical document, mirroring the Mac seam's parameter. `UITextView` keys its
    /// undo manager to the view instance, so embedders apply this via `.id(documentId)` to force
    /// a fresh editor per document — two documents never share one editor's undo stack.
    public var documentId: String
    /// `true` for form embedding (typed-entry body): the editor sizes to its content and the
    /// enclosing `Form`/`ScrollView` scrolls. `false` (default) scrolls internally.
    public var fitsContent = false

    public init(text: Binding<String>, documentId: String, fitsContent: Bool = false) {
        self._text = text
        self.documentId = documentId
        self.fitsContent = fitsContent
    }

    public func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        // Markdown-preserving input: see the type doc for why each of these is off.
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.isScrollEnabled = !fitsContent
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // Growing views collapse to nothing inside a Form row without a floor; scrolling views
        // let the enclosing layout size them.
        if fitsContent {
            view.setContentHuggingPriority(.defaultLow, for: .vertical)
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        view.text = text
        return view
    }

    public func updateUIView(_ view: UITextView, context: Context) {
        // Only push external changes; echoing the view's own text back mid-edit resets the
        // caret and the marked-text (multistage input) state.
        if view.text != text {
            view.text = text
        }
        view.isScrollEnabled = !fitsContent
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    /// Forwards edits into the binding verbatim — no normalization, no trimming.
    public final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        public func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}
#endif

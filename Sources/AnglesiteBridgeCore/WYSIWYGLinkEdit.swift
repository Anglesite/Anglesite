import Foundation

/// The webview-agnostic half of Format ▸ Add Link… on the block editor canvas (#2216): the JS
/// calls a host makes, decoding of their replies, and placing the popover. Each platform shell
/// (the macOS `NSPopover` today) owns only the native UI around it.
///
/// The flow is a session hold in `RichTextEditor` (`JS/wysiwyg-engine/src/rich-text.ts`):
/// `beginLinkEdit()` saves the selection and keeps the edit alive while focus is in the native URL
/// field. Then exactly one of `commitLinkEdit(_:)` (Return) or `cancelLinkEdit()` (Escape or
/// dismissal) releases it.
public enum WYSIWYGLinkEdit {
    /// Where the selection is, in the top-level page's viewport (CSS px).
    public struct ViewportRect: Equatable, Sendable {
        public var x, y, width, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// `beginLinkEdit()`'s reply: what the popover pre-fills, labels and anchors to.
    public struct Context: Equatable, Sendable {
        /// The existing link's address when the selection is inside one, else `nil`.
        public var href: String?
        /// The selected text.
        public var text: String
        public var rect: ViewportRect

        public init(href: String?, text: String, rect: ViewportRect) {
            self.href = href
            self.text = text
            self.rect = rect
        }

        /// Decodes the plain object a JS bridge (`callAsyncJavaScript` on WKWebView) hands back.
        /// `nil` for JS `null` — no active text edit, or nothing selected and no link under the
        /// caret — or for any shape this doesn't recognize.
        public init?(jsReply: Any?) {
            guard let object = jsReply as? [String: Any],
                  let text = object["text"] as? String,
                  let rect = object["rect"] as? [String: Any],
                  let x = Self.number(rect["x"]), let y = Self.number(rect["y"]),
                  let width = Self.number(rect["width"]), let height = Self.number(rect["height"])
            else { return nil }
            self.init(href: object["href"] as? String, text: text, rect: ViewportRect(x: x, y: y, width: width, height: height))
        }

        /// JS numbers arrive as `NSNumber` through WebKit, as `Double`/`Int` from a test.
        private static func number(_ value: Any?) -> Double? {
            switch value {
            case let value as Double: value
            case let value as Int: Double(value)
            case let value as NSNumber: value.doubleValue
            default: nil
            }
        }
    }

    /// `commitLinkEdit(_:)`'s reply.
    public enum CommitResult: String, Sendable {
        /// The selection is now a link.
        case applied
        /// The address was empty, so the link was removed.
        case removed
        /// The address can't be a link (`javascript:`, spaces). The hold is kept, so the popover
        /// stays open for a fix.
        case invalid
        /// Nothing was held, or the held text changed while the popover was open. The page is unchanged.
        case stale

        /// Whether the popover should close.
        public var closesPopover: Bool { self != .invalid }
    }

    /// The page-world call that starts the hold. Its reply decodes with `Context(jsReply:)`.
    public static let beginScript = "return window.__anglesiteWysiwygRichTextEditor?.beginLinkEdit() ?? null"

    /// The page-world call that releases the hold without changing anything.
    public static let cancelScript = "window.__anglesiteWysiwygRichTextEditor?.cancelLinkEdit()"

    /// The page-world call that applies `address`. Pass `address` as the `href` argument rather than
    /// interpolating it, so no escaping is needed. A missing engine replies `stale`.
    public static let commitScript = "return window.__anglesiteWysiwygRichTextEditor?.commitLinkEdit(href) ?? \"stale\""

    /// Maps `rect` into the web view's own coordinate space, for anchoring a popover.
    ///
    /// - Parameters:
    ///   - rect: The selection, as `beginLinkEdit()` reported it.
    ///   - zoom: CSS px → view points (`pageZoom × magnification` on WKWebView).
    ///   - viewHeight: the web view's height in points. Only used when `isFlipped` is false.
    ///   - isFlipped: whether the view's y axis points down, as the page's does.
    /// - Returns: A rect at least 1×1 point, so a popover can always anchor to it.
    public static func anchorRect(for rect: ViewportRect, zoom: Double, viewHeight: Double, isFlipped: Bool) -> CGRect {
        let width = max(rect.width * zoom, 1)
        let height = max(rect.height * zoom, 1)
        let x = rect.x * zoom
        let top = rect.y * zoom
        let y = isFlipped ? top : viewHeight - top - height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

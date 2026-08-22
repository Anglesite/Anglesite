import Foundation

/// Renders a `BlockNode` to minimal semantic HTML plus its plain-text equivalent — design doc
/// §8.4: "copying a block puts real HTML + plain text on the pasteboard." A block with no rich
/// text (e.g. a bare `Callout`) falls back to its `componentName` for both, so copying never
/// produces empty pasteboard content.
public enum WYSIWYGBlockClipboardWriter {
    public static func render(_ node: BlockNode) -> (html: String, plainText: String) {
        guard let runs = node.richText, !runs.isEmpty else {
            return ("<div>\(escapeHTML(node.componentName))</div>", node.componentName)
        }
        return ("<p>\(runs.map(runHTML).joined())</p>", runs.map(\.text).joined())
    }

    private static func runHTML(_ run: RichTextRun) -> String {
        let text = escapeHTML(run.text)
        switch run.kind {
        case .text: return text
        case .strong: return "<strong>\(text)</strong>"
        case .em: return "<em>\(text)</em>"
        case .code: return "<code>\(text)</code>"
        case .link: return "<a href=\"\(escapeHTML(run.href ?? ""))\">\(text)</a>"
        }
    }

    /// Escapes for **both** element text and double-quoted attribute values — `runHTML`
    /// interpolates the result of this into `href="…"`, and the rendered HTML is written to
    /// `NSPasteboard.general`, so an href carrying a `"` must not be able to break out of the
    /// attribute and inject a new one (e.g. `a" onmouseover="…`) into whatever app the owner
    /// pastes into next. `&` stays first so an already-escaped entity in the source text isn't
    /// double-escaped by a later replacement.
    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

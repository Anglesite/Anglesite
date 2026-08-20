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

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

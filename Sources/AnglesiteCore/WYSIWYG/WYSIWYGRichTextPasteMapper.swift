// SwiftUI/AppKit-only: NSAttributedString/NSFont aren't available on the portable core's Linux
// build (cross-platform port design §5) — same posture as CSSColor.swift.
#if canImport(AppKit)
import AppKit
import Foundation

/// Maps a pasted `NSAttributedString` (RTF/HTML from Pages/Word/Safari) into paragraph-level
/// `RichTextRun` lists — the shape `insertBlock` ops build text blocks from (design doc §8.4:
/// "rich text... maps to blocks and honest inline runs"). `plainTextOnly` collapses every run to
/// `.text`, for ⇧⌥⌘V "Paste and Match Style" — only the text content survives, no formatting.
public enum WYSIWYGRichTextPasteMapper {
    public static func map(_ attributed: NSAttributedString, plainTextOnly: Bool = false) -> [[RichTextRun]] {
        let paragraphs = attributed.string.components(separatedBy: "\n")
        var result: [[RichTextRun]] = []
        var location = 0
        for paragraph in paragraphs {
            let length = (paragraph as NSString).length
            defer { location += length + 1 } // +1 accounts for the removed "\n"
            guard length > 0 else {
                result.append([])
                continue
            }
            let range = NSRange(location: location, length: length)
            guard range.location + range.length <= attributed.length else {
                result.append([RichTextRun(kind: .text, text: paragraph)])
                continue
            }
            let slice = attributed.attributedSubstring(from: range)
            result.append(plainTextOnly ? [RichTextRun(kind: .text, text: slice.string)] : runs(for: slice))
        }
        return result
    }

    private static func runs(for attributed: NSAttributedString) -> [RichTextRun] {
        var result: [RichTextRun] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            let text = (attributed.string as NSString).substring(with: range)
            guard !text.isEmpty else { return }
            // Handle both URL and NSString-valued link attributes (HTML paste from Safari/Pages)
            if let link = (attributes[.link] as? URL) ?? (attributes[.link] as? NSString).flatMap({ URL(string: $0 as String) }) {
                result.append(RichTextRun(kind: .link, text: text, href: link.absoluteString))
                return
            }
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) {
                    result.append(RichTextRun(kind: .strong, text: text))
                    return
                }
                if traits.contains(.italic) {
                    result.append(RichTextRun(kind: .em, text: text))
                    return
                }
            }
            result.append(RichTextRun(kind: .text, text: text))
        }
        return result
    }
}
#endif

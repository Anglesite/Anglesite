import Foundation

/// The outcome of converting one Portable Text document to Markdown.
public struct PortableTextMarkdown: Sendable, Equatable {
    /// The rendered Markdown body. Blocks are separated by one blank line; list items that follow
    /// each other stay contiguous so they render as one list.
    public var markdown: String

    /// Every image URL the body references (`image` and `gallery` blocks), in document order,
    /// deduplicated — the inventory ``AssetLocalizer`` needs to install and rewrite them.
    public var images: [String]

    /// The `_type` of every block the converter had no rendering for, in first-seen order,
    /// deduplicated. Such a block is kept verbatim as a fenced JSON code block (see
    /// ``PortableTextMarkdownConverter``) rather than dropped, and the caller reports the type
    /// names so the owner knows which content needs a look.
    public var unsupportedBlockTypes: [String]

    /// Creates a conversion result.
    /// - Parameters:
    ///   - markdown: The rendered Markdown body.
    ///   - images: Image URLs referenced by the body, in document order, deduplicated.
    ///   - unsupportedBlockTypes: Block `_type`s kept as fenced JSON, in first-seen order.
    public init(markdown: String, images: [String], unsupportedBlockTypes: [String]) {
        self.markdown = markdown
        self.images = images
        self.unsupportedBlockTypes = unsupportedBlockTypes
    }
}

/// Converts EmDash's Portable Text dialect to Markdown (#2051), in pure Swift.
///
/// Standalone on purpose: the EmDash import rung (``EmDashRung``) is one consumer, and the
/// git-mirror option discussed for #2050 would be another, so nothing here knows about import
/// items, snapshots, or networking — the input is the decoded JSON block array and the output is
/// text plus an inventory. The dialect is the one EmDash's editor writes (its
/// `prosemirror-to-portable-text` converter and `src/content/converters/types.ts`), which is
/// standard Portable Text plus EmDash's own block types:
///
/// - `block` — a text block. `style` of `normal`/`h1`–`h6`/`blockquote`; `listItem` of
///   `bullet`/`number` with a 1-based `level` (four spaces of indent per level) and an optional
///   `listStart`; `children` spans whose `marks` are either decorators (`strong`, `em`, `code`,
///   `underline`, `strike-through`/`strikethrough`, `subscript`, `superscript`) or the `_key` of
///   a `markDefs` entry (`link` with `href`). Markdown has no underline/sub/sup syntax, so those
///   render as the inline HTML every Markdown pipeline (including Astro's) passes through.
/// - `image` — `![alt](url "title")`, optionally wrapped in its `link`, with `caption` as an
///   italic line below. The URL is `asset.url`; when that's empty the caller-supplied
///   `resolveImageURL` can derive one from `asset._ref` (an EmDash media id).
/// - `gallery` — one image line per entry.
/// - `code` — a fenced block with `language` as the info string; the fence grows past any
///   backtick run inside `code` so the content can't close it early.
/// - `break` — a horizontal rule.
/// - `htmlBlock` — raw HTML. Passed through as-is (Markdown admits HTML blocks) unless the
///   caller supplies a Markdown conversion for that exact HTML string in `htmlConversions`,
///   which is how an injected ``ImportHTMLConverter`` (platform-specific, async) plugs into a
///   converter that stays synchronous and portable — the same hash-keyed lookup shape
///   ``ImportSnapshot/conversions`` uses.
/// - `table` — a GFM table when it's a plain grid; `colspan`/`rowspan` are flattened (the cell
///   is written once, in its first slot).
///
/// Any other `_type` — a custom block from an EmDash plugin or the schema builder — is kept in
/// full as a fenced JSON code block whose info string names the type
/// (`json emdash-block=<type>`), and the type is reported in
/// ``PortableTextMarkdown/unsupportedBlockTypes``. Keeping the JSON (sorted keys, so output is
/// deterministic) rather than dropping the block means nothing the owner wrote is lost: it's
/// visible on the page, and the summary tells them which posts to look at.
///
/// Span text is escaped so that characters Markdown would otherwise interpret (`*`, `_`,
/// backticks, brackets, a leading `#`/`>`/`-`/`1.`) come through literally — EmDash's own
/// `portableTextToMarkdown` doesn't escape, but it only ever round-trips its own output, whereas
/// an import has to survive arbitrary prose.
public enum PortableTextMarkdownConverter {
    /// What an `image` block (or a gallery entry) says about where its picture is: EmDash's
    /// `asset.url` (absolute, or site-relative under `/_emdash/api/media/file/`) and/or
    /// `asset._ref` (a media id). Handed to the caller's `resolveImageURL` so a consumer that
    /// knows the site origin and media table can turn either into a fetchable URL.
    public struct ImageAsset: Sendable, Equatable {
        /// `asset.url`, when non-empty.
        public var url: String?
        /// `asset._ref`, when non-empty.
        public var ref: String?

        /// Creates an asset reference.
        /// - Parameters:
        ///   - url: `asset.url`, when non-empty.
        ///   - ref: `asset._ref`, when non-empty.
        public init(url: String?, ref: String?) {
            self.url = url
            self.ref = ref
        }
    }

    /// Converts a Portable Text block array to Markdown.
    ///
    /// - Parameters:
    ///   - blocks: The decoded block array (`JSONValue.array` elements; anything that isn't an
    ///     object with a string `_type` is skipped).
    ///   - htmlConversions: Markdown for `htmlBlock` contents, keyed by the exact `html` string.
    ///     An `htmlBlock` with no entry is passed through as raw HTML.
    ///   - resolveImageURL: The URL to write for an image, given its ``ImageAsset``. The default
    ///     uses `asset.url` verbatim. Returning `nil` drops the image, and nothing is reported
    ///     for it — the block carried no usable reference.
    /// - Returns: The Markdown, the image inventory, and the unsupported block types.
    public static func convert(
        blocks: [JSONValue], htmlConversions: [String: String] = [:],
        resolveImageURL: (ImageAsset) -> String? = { $0.url }
    ) -> PortableTextMarkdown {
        // The renderer holds the resolver for the duration of one walk and nothing outlives the
        // call, so the public parameter can stay non-escaping.
        withoutActuallyEscaping(resolveImageURL) { resolveImageURL in
            var renderer = Renderer(htmlConversions: htmlConversions, resolveImageURL: resolveImageURL)
            for block in blocks {
                guard case .object(let object) = block, case .string(let type)? = object["_type"] else { continue }
                renderer.render(type: type, block: object)
            }
            return PortableTextMarkdown(markdown: renderer.output(), images: renderer.images,
                                        unsupportedBlockTypes: renderer.unsupportedBlockTypes)
        }
    }

    /// Converts a Portable Text document given as JSON text.
    ///
    /// Accepts either a bare block array or an object with a `blocks`/`content` array (both
    /// shapes appear in EmDash exports: a `portableText` field's column value is the array; the
    /// editor's clipboard format wraps it).
    /// - Parameters:
    ///   - json: UTF-8 JSON text.
    ///   - htmlConversions: See ``convert(blocks:htmlConversions:resolveImageURL:)``.
    ///   - resolveImageURL: See ``convert(blocks:htmlConversions:resolveImageURL:)``.
    /// - Returns: The conversion, or `nil` when `json` isn't valid JSON holding a block array.
    public static func convert(
        json: Data, htmlConversions: [String: String] = [:],
        resolveImageURL: (ImageAsset) -> String? = { $0.url }
    ) -> PortableTextMarkdown? {
        guard let raw = try? JSONSerialization.jsonObject(with: json), let value = JSONValue.from(raw) else {
            return nil
        }
        guard let blocks = blockArray(value) else { return nil }
        return convert(blocks: blocks, htmlConversions: htmlConversions, resolveImageURL: resolveImageURL)
    }

    /// The block array inside `value`: the value itself, or its `blocks`/`content` member.
    static func blockArray(_ value: JSONValue) -> [JSONValue]? {
        switch value {
        case .array(let blocks):
            return blocks
        case .object(let object):
            if case .array(let blocks)? = object["blocks"] { return blocks }
            if case .array(let blocks)? = object["content"] { return blocks }
            return nil
        default:
            return nil
        }
    }

    /// The `html` strings of every `htmlBlock` in `blocks`, in order, deduplicated — so a caller
    /// with an async HTML→Markdown converter can prepare `htmlConversions` ahead of
    /// ``convert(blocks:htmlConversions:resolveImageURL:)``.
    /// - Parameter blocks: The decoded block array.
    /// - Returns: Each distinct `htmlBlock` body, in first-seen order.
    public static func htmlBlocks(in blocks: [JSONValue]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for block in blocks {
            guard case .object(let object) = block, case .string("htmlBlock")? = object["_type"],
                  case .string(let html)? = object["html"], !html.isEmpty, seen.insert(html).inserted else { continue }
            result.append(html)
        }
        return result
    }

    // MARK: Rendering

    /// Accumulates rendered lines plus the image/unsupported inventories while walking a document.
    private struct Renderer {
        let htmlConversions: [String: String]
        let resolveImageURL: (ImageAsset) -> String?

        private var lines: [String] = []
        private(set) var images: [String] = []
        private(set) var unsupportedBlockTypes: [String] = []
        private var seenImages: Set<String> = []
        private var seenUnsupported: Set<String> = []

        /// Whether the previous rendered block was a list item — list items stay contiguous,
        /// everything else is separated by a blank line.
        private var previousWasListItem = false
        /// Running counters for numbered lists, indexed by nesting level, so `1. 2. 3.` comes out
        /// in order; reset whenever a run ends or a shallower level starts over.
        private var numberedCounters: [Int: Int] = [:]

        init(htmlConversions: [String: String], resolveImageURL: @escaping (ImageAsset) -> String?) {
            self.htmlConversions = htmlConversions
            self.resolveImageURL = resolveImageURL
        }

        func output() -> String {
            lines.joined(separator: "\n")
        }

        mutating func render(type: String, block: [String: JSONValue]) {
            switch type {
            case "block":
                renderTextBlock(block)
            case "image":
                append(imageLines(block))
            case "gallery":
                var rendered: [String] = []
                for case .object(let image) in block["images"]?.arrayValue ?? [] {
                    rendered.append(contentsOf: imageLines(image))
                }
                append(rendered)
            case "code":
                append(codeLines(code: block["code"]?.stringValue ?? "",
                                 info: block["language"]?.stringValue ?? "",
                                 filename: block["filename"]?.stringValue))
            case "break":
                append(["---"])
            case "htmlBlock":
                let html = block["html"]?.stringValue ?? ""
                guard !html.isEmpty else { return }
                append((htmlConversions[html] ?? html).split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            case "table":
                append(tableLines(block))
            default:
                if seenUnsupported.insert(type).inserted { unsupportedBlockTypes.append(type) }
                append(codeLines(code: canonicalJSON(.object(block)), info: "json emdash-block=\(type)", filename: nil))
            }
        }

        /// Appends a non-list block: a blank separator line first unless it's the document's
        /// first block.
        private mutating func append(_ rendered: [String]) {
            guard !rendered.isEmpty else { return }
            if !lines.isEmpty { lines.append("") }
            lines.append(contentsOf: rendered)
            previousWasListItem = false
            numberedCounters = [:]
        }

        private mutating func renderTextBlock(_ block: [String: JSONValue]) {
            let markDefs = block["markDefs"]?.arrayValue ?? []
            let text = renderSpans(block["children"]?.arrayValue ?? [], markDefs: markDefs)
            let style = block["style"]?.stringValue ?? "normal"

            if let listItem = block["listItem"]?.stringValue {
                let level = max(1, block["level"]?.intValue ?? 1)
                // Four spaces per level: CommonMark nests an item only when it's indented past
                // the parent's content column, which is 3 for `1. ` and 4 for `10. ` — two
                // spaces (EmDash's own serializer) would make every nested ordered item a new
                // top-level list.
                let indent = String(repeating: "    ", count: level - 1)
                let marker: String
                if listItem == "number" {
                    // Deeper levels start over when a shallower item appears, matching how a
                    // nested list restarts under each parent item.
                    numberedCounters = numberedCounters.filter { $0.key <= level }
                    let next = numberedCounters[level].map { $0 + 1 } ?? (block["listStart"]?.intValue ?? 1)
                    numberedCounters[level] = next
                    marker = "\(next)."
                } else {
                    numberedCounters = numberedCounters.filter { $0.key < level }
                    marker = "-"
                }
                let continuation = "\n" + indent + String(repeating: " ", count: marker.count + 1)
                let body = text.replacingOccurrences(of: "\n", with: "  " + continuation)
                if !lines.isEmpty, !previousWasListItem { lines.append("") }
                lines.append("\(indent)\(marker) \(body)")
                previousWasListItem = true
                return
            }

            let rendered: [String]
            switch style {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(style.dropFirst()) ?? 1
                rendered = [String(repeating: "#", count: level) + " " + text.replacingOccurrences(of: "\n", with: " ")]
            case "blockquote":
                rendered = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }
            default:
                // An empty paragraph (EmDash's editor stores one for every blank line the author
                // typed) adds nothing to Markdown, where block spacing is structural.
                guard !text.isEmpty else { return }
                // A newline inside a paragraph is a hard break the author inserted (Shift-Return),
                // so each line but the last gets Markdown's two-space hard-break suffix.
                let paragraphLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                rendered = paragraphLines.enumerated().map { index, line in
                    (index == 0 ? escapeLineStart(line) : line) + (index < paragraphLines.count - 1 ? "  " : "")
                }
            }
            append(rendered)
        }

        private mutating func imageLines(_ block: [String: JSONValue]) -> [String] {
            let asset = block["asset"]?.objectValue ?? [:]
            func nonEmpty(_ key: String) -> String? {
                guard let value = asset[key]?.stringValue, !value.isEmpty else { return nil }
                return value
            }
            guard let resolved = resolveImageURL(ImageAsset(url: nonEmpty("url"), ref: nonEmpty("_ref"))),
                  !resolved.isEmpty else { return [] }
            // The inventory carries the same spelling the Markdown does, so ``AssetLocalizer``'s
            // body rewrite finds the reference it's told to replace.
            let url = escapeURL(resolved)
            if seenImages.insert(url).inserted { images.append(url) }

            let alt = escapeInline(block["alt"]?.stringValue ?? "")
            var image = "![\(alt)](\(url)"
            if let title = block["title"]?.stringValue, !title.isEmpty {
                image += " \"\(title.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            image += ")"
            if let href = imageLinkHref(block["link"]) {
                image = "[\(image)](\(escapeURL(href)))"
            }
            var result = [image]
            if let caption = block["caption"]?.stringValue, !caption.isEmpty {
                result.append("*\(escapeInline(caption))*")
            }
            return result
        }

        /// An image block's link target: either the canonical `{href}` object or the legacy bare
        /// string EmDash's WordPress importer writes.
        private func imageLinkHref(_ link: JSONValue?) -> String? {
            switch link {
            case .string(let href)?:
                return href.isEmpty ? nil : href
            case .object(let object)?:
                guard let href = object["href"]?.stringValue, !href.isEmpty else { return nil }
                return href
            default:
                return nil
            }
        }

        private func codeLines(code: String, info: String, filename: String?) -> [String] {
            // A fence must be longer than any backtick run inside the code, or the code would
            // close it early (CommonMark §4.5).
            var longestRun = 0
            var run = 0
            for character in code {
                run = character == "`" ? run + 1 : 0
                longestRun = max(longestRun, run)
            }
            let fence = String(repeating: "`", count: max(3, longestRun + 1))
            var result: [String] = []
            if let filename, !filename.isEmpty {
                result.append("<!-- file: \(filename.replacingOccurrences(of: "--", with: "- -")) -->")
            }
            result.append(fence + info)
            result.append(contentsOf: code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            result.append(fence)
            return result
        }

        private mutating func tableLines(_ block: [String: JSONValue]) -> [String] {
            let tableMarkDefs = block["markDefs"]?.arrayValue ?? []
            var rows: [[String]] = []
            var headerRowIndex: Int?
            for case .object(let row) in block["rows"]?.arrayValue ?? [] {
                var cells: [String] = []
                var allHeader = true
                for case .object(let cell) in row["cells"]?.arrayValue ?? [] {
                    let markDefs = (cell["markDefs"]?.arrayValue ?? []) + tableMarkDefs
                    var parts: [String] = []
                    for case .object(let inner) in cell["content"]?.arrayValue ?? [] {
                        let text = renderSpans(inner["children"]?.arrayValue ?? [], markDefs: markDefs)
                        if !text.isEmpty { parts.append(text) }
                    }
                    cells.append(parts.joined(separator: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "|", with: "\\|"))
                    if cell["isHeader"]?.boolValue != true { allHeader = false }
                }
                if headerRowIndex == nil, !cells.isEmpty, allHeader { headerRowIndex = rows.count }
                rows.append(cells)
            }
            guard !rows.isEmpty else { return [] }
            if headerRowIndex == nil, block["hasHeaderRow"]?.boolValue == true { headerRowIndex = 0 }

            let width = rows.map(\.count).max() ?? 0
            func line(_ cells: [String]) -> String {
                "| " + (cells + Array(repeating: "", count: width - cells.count)).joined(separator: " | ") + " |"
            }
            let separator = "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"

            var result: [String] = []
            if let headerRowIndex, headerRowIndex == 0 {
                result.append(line(rows[0]))
                result.append(separator)
                result.append(contentsOf: rows.dropFirst().map(line))
            } else {
                // GFM requires a header row; a table without one gets an empty header so the
                // body rows stay a table instead of collapsing into a paragraph of pipes.
                result.append(line(Array(repeating: "", count: width)))
                result.append(separator)
                result.append(contentsOf: rows.map(line))
            }
            return result
        }

        // MARK: Spans

        private func renderSpans(_ spans: [JSONValue], markDefs: [JSONValue]) -> String {
            var result = ""
            for case .object(let span) in spans {
                guard span["_type"]?.stringValue == "span" else { continue }
                let text = span["text"]?.stringValue ?? ""
                guard !text.isEmpty else { continue }
                let marks = (span["marks"]?.arrayValue ?? []).compactMap(\.stringValue)
                result += decorate(text, marks: marks, markDefs: markDefs)
            }
            return result
        }

        /// Wraps `text` in its marks: `code` innermost (its content is verbatim, never escaped),
        /// then the other decorators, then any `link` outermost so the whole styled run is the
        /// link text. Unknown decorator names and mark definitions of unknown types leave the
        /// text as-is — a custom mark has no Markdown equivalent, and silently keeping the words
        /// beats dropping them.
        private func decorate(_ text: String, marks: [String], markDefs: [JSONValue]) -> String {
            var result = marks.contains("code") ? codeSpan(text) : escapeInline(text)

            var links: [String] = []
            for mark in marks where mark != "code" {
                switch mark {
                case "strong", "bold":
                    result = "**\(result)**"
                case "em", "italic":
                    result = "_\(result)_"
                case "underline":
                    result = "<u>\(result)</u>"
                case "strike-through", "strikethrough", "strike":
                    result = "~~\(result)~~"
                case "subscript":
                    result = "<sub>\(result)</sub>"
                case "superscript":
                    result = "<sup>\(result)</sup>"
                default:
                    guard case .object(let def)? = markDefs.first(where: { $0.objectValue?["_key"]?.stringValue == mark }),
                          def["_type"]?.stringValue == "link",
                          let href = def["href"]?.stringValue, !href.isEmpty else { continue }
                    links.append(href)
                }
            }
            for href in links {
                result = "[\(result)](\(escapeURL(href)))"
            }
            return result
        }

        /// A code span whose fence is longer than any backtick run in `text`, space-padded when
        /// the text itself starts or ends with a backtick (CommonMark §6.1), so the content
        /// comes through verbatim.
        private func codeSpan(_ text: String) -> String {
            var longestRun = 0
            var run = 0
            for character in text {
                run = character == "`" ? run + 1 : 0
                longestRun = max(longestRun, run)
            }
            let fence = String(repeating: "`", count: longestRun + 1)
            let padded = text.hasPrefix("`") || text.hasSuffix("`") ? " \(text) " : text
            return fence + padded + fence
        }

        private func canonicalJSON(_ value: JSONValue) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(value) else { return "{}" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: Escaping

    /// Backslash-escapes the characters that would otherwise start inline Markdown syntax
    /// mid-text. Scoped to those seven on purpose: escaping every ASCII punctuation character
    /// CommonMark allows would make ordinary prose unreadable in the file the owner edits.
    static func escapeInline(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\\", "*", "_", "`", "[", "]", "<":
                result.append("\\")
                result.append(character)
            default:
                result.append(character)
            }
        }
        return result
    }

    /// Escapes a paragraph's first line where a leading `#`, `>`, `-`/`+`, `=`, or `1.` would
    /// turn the paragraph into a heading, quote, list item, setext underline, or ordered list.
    static func escapeLineStart(_ line: String) -> String {
        let trimmed = line.drop { $0 == " " }
        guard let first = trimmed.first else { return line }
        let prefix = String(line.prefix(line.count - trimmed.count))
        switch first {
        case "#", ">", "+", "-", "=", "|", "~":
            return prefix + "\\" + trimmed
        default:
            break
        }
        if first.isNumber {
            let digits = trimmed.prefix { $0.isNumber }
            let rest = trimmed.dropFirst(digits.count)
            if let punctuation = rest.first, punctuation == "." || punctuation == ")",
               rest.dropFirst().first.map({ $0 == " " }) ?? true {
                return prefix + digits + "\\" + rest
            }
        }
        return line
    }

    /// Percent-encodes the characters that would end a Markdown link destination early.
    static func escapeURL(_ url: String) -> String {
        url.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }
}

extension JSONValue {
    /// The wrapped string, or `nil` for any other case.
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The wrapped integer (a whole-number double counts too), or `nil` for any other case.
    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value && abs(value) < Double(Int.max): return Int(value)
        default: return nil
        }
    }

    /// The wrapped boolean, or `nil` for any other case.
    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The wrapped array, or `nil` for any other case.
    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// The wrapped object, or `nil` for any other case.
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

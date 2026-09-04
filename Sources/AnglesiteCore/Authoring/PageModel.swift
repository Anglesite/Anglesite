import Foundation

/// Decoded response from the sidecar's `get_page_model` MCP tool: a block-annotated template
/// tree for one page (`server/page-model.mjs`'s `buildPageModel`). Node shape mirrors
/// ``ComponentModel/Node`` (same `toPublicNode` serializer on the sidecar side) plus a `block`
/// annotation on component instances that resolve to a `blocks.manifest.json` entry.
public struct PageModel: Sendable, Equatable, Codable {
    /// Content-hash version of the source this model was parsed from — passed back as
    /// `baseVersion` on the next edit so the sidecar can refuse a stale write.
    public let version: String
    /// Project-relative page path this model describes, e.g. `src/pages/index.astro`.
    public let path: String
    /// The page's template tree, rooted at a synthetic `.fragment` node.
    public let tree: Node

    public init(version: String, path: String, tree: Node) {
        self.version = version
        self.path = path
        self.tree = tree
    }

    public struct Node: Sendable, Equatable, Codable, Identifiable {
        public let id: String
        public let kind: Kind
        public let tag: String?
        public let attrs: [Attr]
        public let span: Span
        public let loc: Loc?
        public let text: String?
        public let children: [Node]
        /// Present only when this node is a `.component` instance resolving to a
        /// `blocks.manifest.json` entry by its local import path.
        public let block: BlockInfo?

        public init(id: String, kind: Kind, tag: String?, attrs: [Attr], span: Span, loc: Loc?, text: String?, children: [Node], block: BlockInfo?) {
            self.id = id
            self.kind = kind
            self.tag = tag
            self.attrs = attrs
            self.span = span
            self.loc = loc
            self.text = text
            self.children = children
            self.block = block
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(Kind.self, forKey: .kind)
            tag = try c.decodeIfPresent(String.self, forKey: .tag)
            attrs = try c.decodeIfPresent([Attr].self, forKey: .attrs) ?? []
            span = try c.decodeIfPresent(Span.self, forKey: .span) ?? Span(start: nil, end: nil)
            loc = try c.decodeIfPresent(Loc.self, forKey: .loc)
            text = try c.decodeIfPresent(String.self, forKey: .text)
            children = try c.decodeIfPresent([Node].self, forKey: .children) ?? []
            block = try c.decodeIfPresent(BlockInfo.self, forKey: .block)
        }

        enum CodingKeys: String, CodingKey {
            case id, kind, tag, attrs, span, loc, text, children, block
        }

        public enum Kind: String, Sendable, Codable {
            case fragment, element, component, expression, slot, text
        }
    }

    public struct Attr: Sendable, Equatable, Codable {
        public let name: String
        public let value: String?
        public init(name: String, value: String?) {
            self.name = name
            self.value = value
        }
    }

    /// Wire format is a two-element array `[start, end]`, either may be null.
    public struct Span: Sendable, Equatable, Codable {
        public let start: Int?
        public let end: Int?

        public init(start: Int?, end: Int?) {
            self.start = start
            self.end = end
        }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            start = try c.decodeIfPresent(Int.self) ?? nil
            end = try c.decodeIfPresent(Int.self) ?? nil
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(start)
            try c.encode(end)
        }
    }

    public struct Loc: Sendable, Equatable, Codable {
        public let line: Int
        public let column: Int
        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }
    }

    /// Owner-facing metadata from `blocks.manifest.json`, annotated onto a resolved component
    /// instance by the sidecar's `annotateBlocks`.
    public struct BlockInfo: Sendable, Equatable, Codable {
        public let manifestPath: String
        public let name: String
        public let description: String
        public let icon: String?
        public let slots: [String]

        public init(manifestPath: String, name: String, description: String, icon: String?, slots: [String]) {
            self.manifestPath = manifestPath
            self.name = name
            self.description = description
            self.icon = icon
            self.slots = slots
        }

        enum CodingKeys: String, CodingKey {
            case manifestPath, name, description, icon, slots
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            manifestPath = try c.decode(String.self, forKey: .manifestPath)
            name = try c.decode(String.self, forKey: .name)
            description = try c.decode(String.self, forKey: .description)
            icon = try c.decodeIfPresent(String.self, forKey: .icon)
            slots = try c.decodeIfPresent([String].self, forKey: .slots) ?? []
        }
    }
}

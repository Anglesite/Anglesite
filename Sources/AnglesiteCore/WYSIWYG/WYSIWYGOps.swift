import Foundation

// The ops protocol (spec: docs/superpowers/specs/2026-08-03-modern-wysiwyg-editor-design.md §3.2).
// Wire-compatible with JS/wysiwyg-engine/src/types.ts — every Codable shape here mirrors that
// file's JSON exactly (flat "kind"/"status" discriminator, matching field names) because the JS
// engine on the other side of the bridge is the source of truth for the wire format.

public typealias BlockId = String

public indirect enum PropValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case object([String: PropValue])
    case array([PropValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Double.self) { self = .number(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([String: PropValue].self) { self = .object(v); return }
        if let v = try? container.decode([PropValue].self) { self = .array(v); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized PropValue")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        }
    }
}

public struct RichTextRun: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text, strong, em, link, code
    }
    public var kind: Kind
    public var text: String
    public var href: String?
    public var children: [RichTextRun]?

    public init(kind: Kind, text: String, href: String? = nil, children: [RichTextRun]? = nil) {
        self.kind = kind
        self.text = text
        self.href = href
        self.children = children
    }
}

public enum BlockKind: String, Codable, Sendable {
    case astro
    case customElement = "custom-element"
    case text
    /// A plain HTML element with no block-manifest registration — a wrapper/container node
    /// that's still a valid `insertBlock`/`moveBlock` target even though it's not itself a
    /// theme-authored block. Added for the sidecar-backed transport (#1222); the JS engine side
    /// (`JS/wysiwyg-engine/src/types.ts`) needs the matching case added in lockstep — check it
    /// compiles against the wire string `"element"` before assuming parity.
    case element
    /// The page's synthetic fragment root, or any nested fragment. Never itself editable, but
    /// still addressable as a `parentId`.
    case fragment
}

/// Full block node, including its `id` — matches TS `BlockNode`.
public struct BlockNode: Codable, Equatable, Sendable {
    public var id: BlockId
    public var kind: BlockKind
    public var componentName: String
    public var props: [String: PropValue]
    public var slots: [String: [BlockId]]
    /// `[start, end)` byte offsets into the source file — a 2-element array, matching TS's tuple.
    public var sourceSpan: [Int]
    public var richText: [RichTextRun]?

    public init(id: BlockId, kind: BlockKind, componentName: String, props: [String: PropValue], slots: [String: [BlockId]], sourceSpan: [Int], richText: [RichTextRun]? = nil) {
        self.id = id
        self.kind = kind
        self.componentName = componentName
        self.props = props
        self.slots = slots
        self.sourceSpan = sourceSpan
        self.richText = richText
    }
}

/// `BlockNode` without `id` — matches TS's `Omit<BlockNode, "id">`, used by `insertBlock`'s payload
/// (the id travels separately as `newId`).
public struct BlockNodeContent: Codable, Equatable, Sendable {
    public var kind: BlockKind
    public var componentName: String
    public var props: [String: PropValue]
    public var slots: [String: [BlockId]]
    public var sourceSpan: [Int]
    public var richText: [RichTextRun]?

    public init(kind: BlockKind, componentName: String, props: [String: PropValue], slots: [String: [BlockId]], sourceSpan: [Int], richText: [RichTextRun]? = nil) {
        self.kind = kind
        self.componentName = componentName
        self.props = props
        self.slots = slots
        self.sourceSpan = sourceSpan
        self.richText = richText
    }
}

/// Sentinel parent for blocks that live at the page root — matches TS `ROOT_PARENT_ID`.
public let rootParentID: BlockId = "__root__"
public typealias ParentRef = BlockId

public struct BlockModel: Codable, Equatable, Sendable {
    public var path: String
    public var version: String
    public var rootIds: [BlockId]
    public var blocks: [BlockId: BlockNode]

    public init(path: String, version: String, rootIds: [BlockId], blocks: [BlockId: BlockNode]) {
        self.path = path
        self.version = version
        self.rootIds = rootIds
        self.blocks = blocks
    }
}

/// Engine -> host semantic ops (spec §3.2). Every case here MUST have a matching case in
/// `WYSIWYGOpInverter.invert` — see that file's header comment.
public enum Op: Equatable, Sendable {
    case insertBlock(parentId: ParentRef, slot: String, index: Int, newId: BlockId, block: BlockNodeContent)
    case deleteBlock(parentId: ParentRef, slot: String, index: Int, blockId: BlockId, block: BlockNode)
    case moveBlock(blockId: BlockId, fromParentId: ParentRef, fromSlot: String, fromIndex: Int, toParentId: ParentRef, toSlot: String, toIndex: Int)
    case setProp(blockId: BlockId, propName: String, value: PropValue, previousValue: PropValue)
    case editText(blockId: BlockId, runs: [RichTextRun], previousRuns: [RichTextRun])
    case setDesignToken(tokenName: String, value: String, previousValue: String)
}

extension Op: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, parentId, slot, index, newId, block
        case blockId, fromParentId, fromSlot, fromIndex, toParentId, toSlot, toIndex
        case propName, value, previousValue
        case runs, previousRuns
        case tokenName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "insertBlock":
            self = .insertBlock(
                parentId: try container.decode(ParentRef.self, forKey: .parentId),
                slot: try container.decode(String.self, forKey: .slot),
                index: try container.decode(Int.self, forKey: .index),
                newId: try container.decode(BlockId.self, forKey: .newId),
                block: try container.decode(BlockNodeContent.self, forKey: .block))
        case "deleteBlock":
            self = .deleteBlock(
                parentId: try container.decode(ParentRef.self, forKey: .parentId),
                slot: try container.decode(String.self, forKey: .slot),
                index: try container.decode(Int.self, forKey: .index),
                blockId: try container.decode(BlockId.self, forKey: .blockId),
                block: try container.decode(BlockNode.self, forKey: .block))
        case "moveBlock":
            self = .moveBlock(
                blockId: try container.decode(BlockId.self, forKey: .blockId),
                fromParentId: try container.decode(ParentRef.self, forKey: .fromParentId),
                fromSlot: try container.decode(String.self, forKey: .fromSlot),
                fromIndex: try container.decode(Int.self, forKey: .fromIndex),
                toParentId: try container.decode(ParentRef.self, forKey: .toParentId),
                toSlot: try container.decode(String.self, forKey: .toSlot),
                toIndex: try container.decode(Int.self, forKey: .toIndex))
        case "setProp":
            self = .setProp(
                blockId: try container.decode(BlockId.self, forKey: .blockId),
                propName: try container.decode(String.self, forKey: .propName),
                value: try container.decode(PropValue.self, forKey: .value),
                previousValue: try container.decode(PropValue.self, forKey: .previousValue))
        case "editText":
            self = .editText(
                blockId: try container.decode(BlockId.self, forKey: .blockId),
                runs: try container.decode([RichTextRun].self, forKey: .runs),
                previousRuns: try container.decode([RichTextRun].self, forKey: .previousRuns))
        case "setDesignToken":
            self = .setDesignToken(
                tokenName: try container.decode(String.self, forKey: .tokenName),
                value: try container.decode(String.self, forKey: .value),
                previousValue: try container.decode(String.self, forKey: .previousValue))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unrecognized op kind: \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .insertBlock(let parentId, let slot, let index, let newId, let block):
            try container.encode("insertBlock", forKey: .kind)
            try container.encode(parentId, forKey: .parentId)
            try container.encode(slot, forKey: .slot)
            try container.encode(index, forKey: .index)
            try container.encode(newId, forKey: .newId)
            try container.encode(block, forKey: .block)
        case .deleteBlock(let parentId, let slot, let index, let blockId, let block):
            try container.encode("deleteBlock", forKey: .kind)
            try container.encode(parentId, forKey: .parentId)
            try container.encode(slot, forKey: .slot)
            try container.encode(index, forKey: .index)
            try container.encode(blockId, forKey: .blockId)
            try container.encode(block, forKey: .block)
        case .moveBlock(let blockId, let fromParentId, let fromSlot, let fromIndex, let toParentId, let toSlot, let toIndex):
            try container.encode("moveBlock", forKey: .kind)
            try container.encode(blockId, forKey: .blockId)
            try container.encode(fromParentId, forKey: .fromParentId)
            try container.encode(fromSlot, forKey: .fromSlot)
            try container.encode(fromIndex, forKey: .fromIndex)
            try container.encode(toParentId, forKey: .toParentId)
            try container.encode(toSlot, forKey: .toSlot)
            try container.encode(toIndex, forKey: .toIndex)
        case .setProp(let blockId, let propName, let value, let previousValue):
            try container.encode("setProp", forKey: .kind)
            try container.encode(blockId, forKey: .blockId)
            try container.encode(propName, forKey: .propName)
            try container.encode(value, forKey: .value)
            try container.encode(previousValue, forKey: .previousValue)
        case .editText(let blockId, let runs, let previousRuns):
            try container.encode("editText", forKey: .kind)
            try container.encode(blockId, forKey: .blockId)
            try container.encode(runs, forKey: .runs)
            try container.encode(previousRuns, forKey: .previousRuns)
        case .setDesignToken(let tokenName, let value, let previousValue):
            try container.encode("setDesignToken", forKey: .kind)
            try container.encode(tokenName, forKey: .tokenName)
            try container.encode(value, forKey: .value)
            try container.encode(previousValue, forKey: .previousValue)
        }
    }
}

public struct OpEnvelope: Codable, Equatable, Sendable {
    public var id: String
    /// The model version (content hash) this op was computed against — spec §9.
    public var targetVersion: String
    public var op: Op

    public init(id: String, targetVersion: String, op: Op) {
        self.id = id
        self.targetVersion = targetVersion
        self.op = op
    }
}

public enum OpRejectionReason: String, Codable, Sendable {
    case versionMismatch = "version-mismatch"
    case invalidTarget = "invalid-target"
    case hostError = "host-error"
}

public enum OpResult: Equatable, Sendable {
    case applied(model: BlockModel)
    case rejected(reason: OpRejectionReason, message: String?, freshModel: BlockModel?)
}

extension OpResult: Codable {
    private enum CodingKeys: String, CodingKey { case status, model, reason, message, freshModel }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "applied":
            self = .applied(model: try container.decode(BlockModel.self, forKey: .model))
        case "rejected":
            self = .rejected(
                reason: try container.decode(OpRejectionReason.self, forKey: .reason),
                message: try container.decodeIfPresent(String.self, forKey: .message),
                freshModel: try container.decodeIfPresent(BlockModel.self, forKey: .freshModel))
        default:
            throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Unrecognized status: \(status)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .applied(let model):
            try container.encode("applied", forKey: .status)
            try container.encode(model, forKey: .model)
        case .rejected(let reason, let message, let freshModel):
            try container.encode("rejected", forKey: .status)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(message, forKey: .message)
            try container.encodeIfPresent(freshModel, forKey: .freshModel)
        }
    }
}

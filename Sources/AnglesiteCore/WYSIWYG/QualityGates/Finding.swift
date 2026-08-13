import Foundation

public enum FindingCategory: String, Codable, Sendable {
    case contrast
    case altText
    case headingOrder
    case linkIntegrity
    case imageWeight
}

public enum FindingSeverity: String, Codable, Sendable {
    case advisory
    case warning
}

/// A live quality-gate finding (spec §6) — advisory, anchored to a block, phrased in owner
/// consequences. Wire-compatible with `JS/wysiwyg-engine/src/quality-gates.ts`'s `Finding`.
public struct Finding: Codable, Equatable, Sendable {
    public let id: String
    public let blockId: BlockId
    public let category: FindingCategory
    public let severity: FindingSeverity
    public let message: String
    public let fix: Op?

    /// `id` is derived, never passed in — "<blockId>::<category>", or with `discriminator` appended
    /// as "<blockId>::<category>::<discriminator>" when one block can carry more than one finding in
    /// the same category (e.g. two broken links in one rich-text block). Deriving it here rather
    /// than trusting each gate to build a matching string by hand is what keeps ids stable across
    /// re-analysis — the property the engine's keyed diff (design doc §3) depends on.
    public init(blockId: BlockId, category: FindingCategory, discriminator: String? = nil, severity: FindingSeverity, message: String, fix: Op? = nil) {
        self.id = discriminator.map { "\(blockId)::\(category.rawValue)::\($0)" } ?? "\(blockId)::\(category.rawValue)"
        self.blockId = blockId
        self.category = category
        self.severity = severity
        self.message = message
        self.fix = fix
    }
}

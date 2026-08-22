import Foundation

/// Which native system control a block prop's inspector row uses (design doc §4: "typed block
/// props using system controls: steppers, color wells with the system color panel, pop-up
/// buttons"). Real prop schemas will come from #1222's CEM-aligned theme manifest once it exists;
/// until then, `WYSIWYGBlockPaletteEntry.props` (Task 5) carries a small static stand-in built
/// from this vocabulary, same "interim, not a fake final answer" posture PR1 took for the block
/// palette itself.
public enum WYSIWYGPropEditorKind: String, Codable, Equatable, Sendable {
    case text
    case number
    case boolean
    case color
    case enumeration = "enum"
}

/// One editable prop on a block kind, and how to render/commit it. `enumOptions` is only
/// meaningful for `.enumeration` — the fixed set of allowed string values a pop-up button offers.
public struct WYSIWYGPropDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let label: String
    public let kind: WYSIWYGPropEditorKind
    public let enumOptions: [String]

    public init(name: String, label: String, kind: WYSIWYGPropEditorKind, enumOptions: [String] = []) {
        self.name = name
        self.label = label
        self.kind = kind
        self.enumOptions = enumOptions
    }
}

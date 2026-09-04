import Foundation

/// Which editor surface a navigator file opens in.
public enum EditorKind: Sendable, Equatable {
    case text
    case plist
    case component
    case markdown

    /// Resolves the editor for a file. A single decision point so the routing rule lives in one
    /// tested place; kept on the enum to keep the public API surface tidy.
    public static func resolve(for file: FileRef) -> EditorKind {
        if file.group == .metadata, file.url.pathExtension.lowercased() == "plist" {
            return .plist
        }
        if file.group == .components, file.url.pathExtension.lowercased() == "astro" {
            return .component
        }
        if ["md", "mdx", "markdown"].contains(file.url.pathExtension.lowercased()) {
            return .markdown
        }
        return .text
    }
}

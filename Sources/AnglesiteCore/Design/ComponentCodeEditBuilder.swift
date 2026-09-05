import Foundation

/// Builds the wire-format `EditMessage` payloads for the two Component Editor "Props & code"
/// write ops (`set-props-interface`, `set-script-zone`). Pure and testable — no MCP/router
/// dependency, mirrors `ComponentStyleEditBuilder`'s shape exactly.
public enum ComponentCodeEditBuilder {
    /// `props` mirrors the plugin's `component.props` schema — the same shape
    /// `ComponentModel.Prop` decodes, so callers can pass `model.frontmatter?.props`
    /// (edited in place) straight through. An empty array removes the Props interface
    /// and its `Astro.props` destructure entirely.
    public static func setPropsInterface(
        id: String,
        path: String,
        baseVersion: String,
        props: [ComponentModel.Prop]
    ) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            selector: nil,
            op: EditMessage.Op.setPropsInterface,
            component: .object([
                "path": .string(path),
                "baseVersion": .string(baseVersion),
                "props": .array(props.map(propValue)),
            ]),
            value: nil
        )
    }

    /// `zone` is `"frontmatter"` or `"client"`; `source` replaces that zone's text wholesale
    /// (a code-pane save), synthesizing the zone server-side if it doesn't exist yet.
    public static func setScriptZone(
        id: String,
        path: String,
        baseVersion: String,
        zone: String,
        source: String
    ) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            selector: nil,
            op: EditMessage.Op.setScriptZone,
            component: .object([
                "path": .string(path),
                "baseVersion": .string(baseVersion),
                "zone": .string(zone),
                "source": .string(source),
            ]),
            value: nil
        )
    }

    private static func propValue(_ prop: ComponentModel.Prop) -> JSONValue {
        .object([
            "name": .string(prop.name),
            "type": .string(prop.type),
            "optional": .bool(prop.optional),
            "default": prop.defaultValue.map(JSONValue.string) ?? .null,
        ])
    }
}

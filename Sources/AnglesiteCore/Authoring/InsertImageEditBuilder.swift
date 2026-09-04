import Foundation

/// Builds the `insert-image` `EditMessage` for a picked-file (not dropped-file) image insert —
/// `Insert ▸ Image`'s native counterpart to the overlay's own `FileReader.readAsDataURL` +
/// `postEdit` call. Pure and testable, mirroring `ComponentStructureEditBuilder`'s shape: the
/// menu command (`InsertCommands.swift`, AnglesiteApp) stays thin glue around this.
public enum InsertImageEditBuilder {
    /// Base64 data-URL for `bytes`, matching the wire format the sidecar's `processImageDrop`
    /// decodes (`data:<mimeType>;base64,<...>`).
    public static func dataURL(bytes: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(bytes.base64EncodedString())"
    }

    /// Builds the `insert-image` message. No `selector` — the op always targets the page's
    /// content root, resolved server-side (see `EditMessage.Op.insertImage`'s doc comment).
    public static func message(
        id: String = UUID().uuidString,
        path: String,
        filename: String,
        mimeType: String,
        dataURL: String
    ) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            op: EditMessage.Op.insertImage,
            value: .object([
                "filename": .string(filename),
                "mimeType": .string(mimeType),
                "dataURL": .string(dataURL),
            ])
        )
    }
}

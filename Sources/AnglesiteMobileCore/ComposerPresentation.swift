import Foundation
import UniformTypeIdentifiers
import AnglesiteCore
import AnglesiteIOS

extension PostComposerModel.Phase {
    /// A foreground send is in flight — the Save Draft / Publish actions disable.
    public var isSending: Bool {
        if case .sending = self { return true }
        return false
    }

    /// The last send is queued for the network — the composer arms its automatic retry.
    public var isWaitingForNetwork: Bool {
        if case .waitingForNetwork = self { return true }
        return false
    }

    /// The server copy changed underneath this composition — the conflict dialog presents.
    public var isConflict: Bool {
        if case .conflict = self { return true }
        return false
    }

    /// The composition reached the server (draft saved or publish accepted) — the enclosing
    /// list should refresh.
    public var didSend: Bool {
        switch self {
        case .savedDraft, .publishedRebuilding: return true
        default: return false
        }
    }
}

/// Which of a content type's fields the iOS form renders where: scalar controls in descriptor
/// order, then the Markdown body in its own section. Mirrors the Mac's `TypedEntryForm`.
public enum ComposerFieldLayout {
    /// The fields rendered as inline controls — everything but the Markdown body and `draft`.
    /// `draft` is omitted because its wire form is `post-status`, which the Save Draft /
    /// Publish actions stamp — a checkbox alongside those buttons would fight them.
    ///
    /// - Parameter descriptor: The content type being composed.
    /// - Returns: The scalar fields, in descriptor order.
    public static func scalarFields(of descriptor: ContentTypeDescriptor) -> [ContentTypeField] {
        descriptor.fields.filter { $0.kind != .markdown && $0.name != "draft" }
    }

    /// The Markdown body field, if the type has one.
    ///
    /// - Parameter descriptor: The content type being composed.
    /// - Returns: The first `.markdown` field, or `nil`.
    public static func bodyField(of descriptor: ContentTypeDescriptor) -> ContentTypeField? {
        descriptor.fields.first { $0.kind == .markdown }
    }
}

/// The owner-facing classification of an image-upload failure. The view maps each case to
/// localized copy; keeping the classification here (and the strings in the app target) means
/// the branching is unit-tested while the String Catalog extraction still sees every literal.
public enum MediaUploadFailure: Equatable, Sendable {
    /// Over the upload limit; carries the actual size, already formatted for display.
    case tooLarge(formattedSize: String)
    /// Not a web-servable image format; carries the offending MIME type.
    case unsupportedFormat(mimeType: String)
    /// A zero-byte payload.
    case empty
    /// The site rejected the token — route to sign-in.
    case reauthorizationRequired
    /// Any other transport failure — retryable.
    case transportFailed
}

/// Presentation helpers for the composer's image controls.
public enum MediaUploadPresentation {
    /// Classifies an upload error for display.
    ///
    /// - Parameter error: The composer's upload failure.
    /// - Returns: The owner-facing classification.
    public static func classify(_ error: PostComposerModel.MediaUploadError) -> MediaUploadFailure {
        switch error {
        case .rejected(.tooLarge(let bytes)):
            return .tooLarge(formattedSize: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        case .rejected(.unsupportedFormat(let mimeType)):
            return .unsupportedFormat(mimeType: mimeType)
        case .rejected(.empty):
            return .empty
        case .transport(let micropubError) where micropubError.requiresReauthorization:
            return .reauthorizationRequired
        case .transport:
            return .transportFailed
        }
    }

    /// The MIME type to upload a Files-picked file as, from its extension.
    ///
    /// - Parameter fileExtension: The file's path extension (e.g. `png`).
    /// - Returns: The preferred MIME type, or `application/octet-stream` when unknown.
    public static func mimeType(forFileExtension fileExtension: String) -> String {
        UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

import Foundation

// Gated to the Xcode-27 toolchain — `GeneratedAltText` is `@Generable` (FoundationModels), absent
// at runtime on CI (#128) — and to canImport for genuine off-Darwin portability (cross-platform
// port design §5). Same pattern as `AltTextGenerator.swift` / `FoundationModelAssistant.swift`.
#if compiler(>=6.4) && canImport(FoundationModels)

/// Proposes alt text for a just-ingested WYSIWYG image-drop (design doc §3, #1227): the on-device
/// vision model looks at the dropped image and returns a ``GeneratedAltText`` to seed the new
/// `insertBlock` op's `alt` prop *before* it is submitted — one op, one undo entry, reviewable
/// live in the inspector like any other prop. Unlike the legacy overlay's `AltTextGenerator`,
/// there is no follow-up edit to apply: the caller writes the result straight into the op it's
/// about to submit.
///
/// Best-effort by design: any failure (model unavailable, vision call error, timeout) yields
/// `nil` rather than throwing, so a drop never blocks or errors on a failed proposal — the image
/// still inserts with empty alt text exactly as it did before this feature existed.
public struct WYSIWYGAltTextProposer: Sendable {
    /// Production wraps `FoundationModelAssistant.generateStructured(prompt:imageURL:context:resultType:)`.
    public typealias Producer = @Sendable (_ imageURL: URL, _ context: AssistantContext) async throws -> GeneratedAltText

    private let produce: Producer
    private let log: @Sendable (String) async -> Void

    /// `log` defaults to a no-op because failures here are best-effort by design; production
    /// passes the debug-pane logger so a swallowed failure still leaves a trace ("logs are
    /// sacred").
    public init(produce: @escaping Producer, log: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.produce = produce
        self.log = log
    }

    /// Proposes alt text for the image at `imageURL`, or `nil` on any failure.
    public func propose(imageURL: URL, context: AssistantContext) async -> GeneratedAltText? {
        do {
            return try await produce(imageURL, context)
        } catch {
            await log("alt-text proposal failed for \(imageURL.path): \(error)")
            return nil
        }
    }
}
#endif

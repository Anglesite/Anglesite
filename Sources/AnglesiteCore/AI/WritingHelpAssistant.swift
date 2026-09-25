import Foundation

/// Result of a writing-help request (#1227 PR 2) — never throws to its caller. `.unavailable`
/// covers every failure mode (no FM on this Mac, a generation error) with one owner-facing
/// message, matching PR 1's alt-text "silent degrade, never surface a raw error" convention.
public enum WritingHelpOutcome: Equatable, Sendable {
    /// `notice` is the model-tier badge for the surface that renders the rewrite (the canvas
    /// selection toolbar) — `FoundationModelTier.degradationNotice` when the feature ran on a
    /// smaller model than it was designed for (#1965), `nil` when served as designed or when
    /// the producer has no tier to report (test fakes, the chat tool's own reply).
    case rewritten(String, notice: String? = nil)
    case unavailable(String)
}

/// Custom `Codable` via a `status` string discriminator — mirrors `OpResult`'s extension
/// (`Sources/AnglesiteCore/WYSIWYG/WYSIWYGOps.swift`) exactly. The auto-synthesized Codable for an
/// enum with associated values does not produce the `{"status": "rewritten", "text": "..."}` /
/// `{"status": "unavailable", "message": "..."}` shape the JS side (`WritingHelpReply`,
/// #1227 PR 2) needs.
extension WritingHelpOutcome: Codable {
    private enum CodingKeys: String, CodingKey { case status, text, message, notice }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "rewritten":
            self = .rewritten(
                try container.decode(String.self, forKey: .text),
                notice: try container.decodeIfPresent(String.self, forKey: .notice))
        case "unavailable":
            self = .unavailable(try container.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Unrecognized status: \(status)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .rewritten(let text, let notice):
            try container.encode("rewritten", forKey: .status)
            try container.encode(text, forKey: .text)
            // Omitted rather than `null` so the JS side's `notice?: string` reads it as absent.
            try container.encodeIfPresent(notice, forKey: .notice)
        case .unavailable(let message):
            try container.encode("unavailable", forKey: .status)
            try container.encode(message, forKey: .message)
        }
    }
}

/// Rewrites `text` per a natural-language `instruction` — the shared core behind both the canvas
/// selection toolbar (canned instructions per button) and the `rewriteBlock` chat tool (free-form
/// instruction). One method, no action enum (see plan Global Constraints).
public protocol WritingHelpAssisting: Sendable {
    /// `preamble` is a `BrandVoiceGuidance`-built voice preamble, prepended verbatim when present.
    func rewrite(
        text: String, instruction: String, preamble: String?, siteID: String, siteDirectory: URL
    ) async -> WritingHelpOutcome
}

/// `nil` below the Xcode-27 toolchain — callers hide/disable the feature (pattern:
/// `CopyEditAuditorFactory`).
public enum WritingHelpAssistantFactory {
    public static func makeDefault() -> (any WritingHelpAssisting)? {
        #if compiler(>=6.4) && canImport(FoundationModels)
        return FoundationModelWritingHelpAssistant()
        #else
        return nil
        #endif
    }
}

/// Pure prompt builder — no FM dependency, unit-tested directly regardless of toolchain.
public enum WritingHelpPrompt {
    public static func build(instruction: String, text: String, preamble: String?) -> String {
        let base = """
        \(instruction)

        Text:
        \"\"\"
        \(text)
        \"\"\"

        Reply with only the rewritten text — no preamble, no quotes, no explanation of what changed.
        """
        guard let preamble else { return base }
        return "\(preamble)\n\n\(base)"
    }
}

// Gated to the Xcode-27 toolchain (FoundationModels absent at runtime on CI, #128) and to
// canImport for genuine off-Darwin portability (cross-platform port design §5).
#if compiler(>=6.4) && canImport(FoundationModels)

/// The production `WritingHelpAssisting`. Goes through `ContentAssistantFactory`/`ContentAssistant`
/// (not a concrete `FoundationModelAssistant` directly) — writing help needs no vision input,
/// so unlike PR 1's alt-text proposer it can and should use the same protocol seam every other
/// one-shot FM feature (`CopyEditAuditor`, `SiteGraphNodeExplainer`) already goes through.
public struct FoundationModelWritingHelpAssistant: WritingHelpAssisting {
    /// Injected so tests can fake the backend without a live model. Production default resolves
    /// through the shared tier seam for `designedTier`, matching `CopyEditAuditor`'s own
    /// `.privateCloudCompute` request (today backed on-device; the seam is what changes when
    /// real PCC lands).
    private let assistantFactory: @Sendable () -> (any ContentAssistant)?

    /// The tier this feature was designed for. Drives the `notice` attached to every
    /// `.rewritten` outcome (`FoundationModelTier.degradationNotice`, #1965) — so the badge
    /// tells the truth even when a test injects a fake backend.
    private let designedTier: FoundationModelTier

    /// Logs errors from generation failures ("logs are sacred" convention). Defaults to no-op for
    /// best-effort behavior; production passes the debug-pane logger so failures leave a trace.
    private let log: @Sendable (String) async -> Void

    public init(
        designedTier: FoundationModelTier = .privateCloudCompute,
        assistantFactory: (@Sendable () -> (any ContentAssistant)?)? = nil,
        log: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.designedTier = designedTier
        self.assistantFactory = assistantFactory ?? { ContentAssistantFactory.make(tier: designedTier) }
        self.log = log
    }

    public func rewrite(
        text: String, instruction: String, preamble: String?, siteID: String, siteDirectory: URL
    ) async -> WritingHelpOutcome {
        guard let assistant = assistantFactory() else {
            return .unavailable(ContentHelpDialogs.assistantUnavailable(feature: "Writing help"))
        }
        do {
            let generated = try await assistant.generateStructured(
                prompt: WritingHelpPrompt.build(instruction: instruction, text: text, preamble: preamble),
                context: AssistantContext(siteID: siteID, siteDirectory: siteDirectory),
                resultType: GeneratedRewrite.self
            )
            return .rewritten(generated.rewrittenText, notice: designedTier.degradationNotice)
        } catch {
            await log("writing-help generation failed: \(error)")
            return .unavailable(ContentHelpDialogs.assistantUnavailable(feature: "Writing help"))
        }
    }
}
#endif

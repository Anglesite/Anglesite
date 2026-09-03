import Foundation

/// Result of a writing-help request (#1227 PR 2) — never throws to its caller. `.unavailable`
/// covers every failure mode (no FM on this Mac, a generation error) with one owner-facing
/// message, matching PR 1's alt-text "silent degrade, never surface a raw error" convention.
public enum WritingHelpOutcome: Equatable, Sendable, Codable {
    case rewritten(String)
    case unavailable(String)
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
    /// through the shared tier seam, matching `CopyEditAuditor`'s own `.privateCloudCompute`
    /// request (today backed on-device; the seam is what changes when real PCC lands).
    private let assistantFactory: @Sendable () -> (any ContentAssistant)?

    /// Logs errors from generation failures ("logs are sacred" convention). Defaults to no-op for
    /// best-effort behavior; production passes the debug-pane logger so failures leave a trace.
    private let log: @Sendable (String) async -> Void

    public init(
        assistantFactory: @escaping @Sendable () -> (any ContentAssistant)? = { ContentAssistantFactory.make(tier: .privateCloudCompute) },
        log: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.assistantFactory = assistantFactory
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
            return .rewritten(generated.rewrittenText)
        } catch {
            await log("writing-help generation failed: \(error)")
            return .unavailable(ContentHelpDialogs.assistantUnavailable(feature: "Writing help"))
        }
    }
}
#endif

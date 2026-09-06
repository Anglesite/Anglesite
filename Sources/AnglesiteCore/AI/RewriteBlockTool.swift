import Foundation

/// Pure reply strings for `RewriteBlockTool`, non-gated for CI tests.
public enum RewriteBlockReply {
    public enum Outcome: Equatable {
        case success
        case blockNotFound
        case unavailable(String)
        case submitFailed
        case canvasNotOpen
    }

    public static func confirmation(for outcome: Outcome) -> String {
        switch outcome {
        case .success:
            return "I rewrote that block. Undo (⌘Z) if you don't like it."
        case .blockNotFound:
            return "I couldn't find that block on the page — it may have been deleted or the page may have changed since you last saw it."
        case .unavailable(let message):
            return message
        case .submitFailed:
            return "I generated a rewrite, but couldn't apply it to the page — the document may have changed underneath it. Try again."
        case .canvasNotOpen:
            return "Turn on Site ▸ Edit Page first, then ask me to rewrite a block."
        }
    }
}

// Gated to the Xcode-27 toolchain (FoundationModels absent at runtime on CI, #128) and to
// canImport for genuine off-Darwin portability (cross-platform port design §5).
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels

/// Chat front door for writing help on a whole block (#1227 PR 2, design doc §4) — the
/// `rewriteBlock` counterpart to the canvas selection toolbar (Task 6), operating on a block's
/// full current text rather than a live selection. Applies immediately (with Undo as the safety
/// net) rather than requiring a separate in-chat accept step — chat has no existing
/// "inline-action-in-transcript" affordance to build a preview-then-apply UI on top of (confirmed
/// by inspection of the existing `Tool` call sites), and immediate-apply-with-Undo is the same
/// resolution PR 1's alt-text proposal already uses for a comparable "reviewable, not gated on an
/// extra click" tradeoff.
public struct RewriteBlockTool: Tool, Sendable {
    public static let toolName = "rewriteBlock"
    public let name = RewriteBlockTool.toolName
    public let description = "Rewrite an existing block's text per the owner's instruction (e.g. 'make the hero heading punchier'). If the owner has a block selected in the canvas, you can omit blockId to target it; otherwise you need the block's id."

    @Generable
    public struct Arguments {
        @Guide(description: "The id of the block to rewrite. May be omitted to target whatever block is currently selected in the canvas.")
        public var blockId: String?
        @Guide(description: "The owner's rewrite instruction, in their own words.")
        public var instruction: String

        public init(blockId: String? = nil, instruction: String) {
            self.blockId = blockId
            self.instruction = instruction
        }
    }

    /// Resolved fresh on every call, at the moment the model actually invokes this tool — not once
    /// per session or per session-rebuild (#1227 PR 2 final review, Finding 2). The live canvas
    /// mounts/unmounts as the owner toggles Site ▸ Edit Page well after the chat session (and its
    /// cached `LanguageModelSession`, reused across turns) was built, so resolving here is the only
    /// point that's correct even mid-cached-session. `nil` means no canvas is currently mounted.
    private let accessProvider: @Sendable () async -> (any WYSIWYGBlockTextAccess)?
    /// Optional so a caller can attach this tool even when `WritingHelpAssistantFactory.makeDefault()`
    /// returned `nil` — `call` degrades to `.unavailable` immediately rather than needing a
    /// non-functional fallback conformer (there is no meaningful non-optional default: any stand-in
    /// would just re-implement the same "always unavailable" behavior `nil` already expresses).
    private let writingHelp: (any WritingHelpAssisting)?
    private let siteID: String
    private let siteDirectory: URL

    public init(
        accessProvider: @escaping @Sendable () async -> (any WYSIWYGBlockTextAccess)?,
        writingHelp: (any WritingHelpAssisting)?, siteID: String, siteDirectory: URL
    ) {
        self.accessProvider = accessProvider
        self.writingHelp = writingHelp
        self.siteID = siteID
        self.siteDirectory = siteDirectory
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let access = await accessProvider() else {
            return RewriteBlockReply.confirmation(for: .canvasNotOpen)
        }
        guard let writingHelp else {
            return RewriteBlockReply.confirmation(for: .unavailable(ContentHelpDialogs.assistantUnavailable(feature: "Writing help")))
        }
        let resolvedBlockId: String?
        if let blockId = arguments.blockId {
            resolvedBlockId = blockId
        } else {
            resolvedBlockId = await access.selectedBlockId()
        }
        guard let blockId = resolvedBlockId else {
            return RewriteBlockReply.confirmation(for: .blockNotFound)
        }
        guard let text = await access.blockText(blockId) else {
            return RewriteBlockReply.confirmation(for: .blockNotFound)
        }
        let outcome = await writingHelp.rewrite(
            text: text, instruction: arguments.instruction, preamble: nil,
            siteID: siteID, siteDirectory: siteDirectory)
        switch outcome {
        case .unavailable(let message):
            return RewriteBlockReply.confirmation(for: .unavailable(message))
        case .rewritten(let newText):
            let applied = await access.submitRewrite(blockId: blockId, newText: newText)
            return RewriteBlockReply.confirmation(for: applied ? .success : .submitFailed)
        }
    }
}
#endif

import Testing
import Foundation
@testable import AnglesiteCore

@Suite("RewriteBlockReply")
struct RewriteBlockReplyTests {
    @Test("confirmation names the block was rewritten")
    func confirmationNamesSuccess() {
        #expect(RewriteBlockReply.confirmation(for: .success).contains("rewrote"))
    }

    @Test("blockNotFound explains the block couldn't be located")
    func blockNotFoundExplains() {
        #expect(RewriteBlockReply.confirmation(for: .blockNotFound).lowercased().contains("couldn't find"))
    }

    @Test("unavailable passes through the assistant's own message")
    func unavailablePassesThroughMessage() {
        #expect(RewriteBlockReply.confirmation(for: .unavailable("Apple Intelligence isn't available.")).contains("Apple Intelligence isn't available."))
    }

    @Test("submitFailed explains the rewrite generated but couldn't be applied")
    func submitFailedExplains() {
        #expect(RewriteBlockReply.confirmation(for: .submitFailed).lowercased().contains("couldn't apply"))
    }

    @Test("canvasNotOpen tells the owner to turn on Edit Page")
    func canvasNotOpenExplains() {
        #expect(RewriteBlockReply.confirmation(for: .canvasNotOpen).contains("Edit Page"))
    }
}

// Gated like the type under test — `RewriteBlockTool` is a FoundationModels `Tool`. The reply
// logic above is model-free and always tested; the tool itself is exercised through a fake
// `WYSIWYGBlockTextAccess` + `WritingHelpAssisting`.
#if compiler(>=6.4) && canImport(FoundationModels)

@Suite("RewriteBlockTool")
struct RewriteBlockToolTests {
    private struct FakeAccess: WYSIWYGBlockTextAccess {
        var text: String?
        var submitResult = true
        var selected: String?
        func blockText(_ id: String) async -> String? { text }
        func submitRewrite(blockId: String, newText: String) async -> Bool { submitResult }
        func selectedBlockId() async -> String? { selected }
    }

    private struct FakeWritingHelp: WritingHelpAssisting {
        let outcome: WritingHelpOutcome
        func rewrite(text: String, instruction: String, preamble: String?, siteID: String, siteDirectory: URL) async -> WritingHelpOutcome { outcome }
    }

    @Test("rewrites and submits when the block exists and generation succeeds")
    func rewritesAndSubmits() async throws {
        let tool = RewriteBlockTool(
            accessProvider: { FakeAccess(text: "Original paragraph.") },
            writingHelp: FakeWritingHelp(outcome: .rewritten("Punchier paragraph.")),
            siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        let reply = try await tool.call(arguments: .init(blockId: "b1", instruction: "make this punchier"))
        #expect(reply.contains("rewrote"))
    }

    @Test("replies blockNotFound when the block id doesn't resolve")
    func repliesBlockNotFound() async throws {
        let tool = RewriteBlockTool(
            accessProvider: { FakeAccess(text: nil) },
            writingHelp: FakeWritingHelp(outcome: .rewritten("x")),
            siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        let reply = try await tool.call(arguments: .init(blockId: "missing", instruction: "y"))
        #expect(reply.lowercased().contains("couldn't find"))
    }

    @Test("passes through the assistant's unavailable message without submitting")
    func repliesUnavailable() async throws {
        let tool = RewriteBlockTool(
            accessProvider: { FakeAccess(text: "Original.") },
            writingHelp: FakeWritingHelp(outcome: .unavailable("Apple Intelligence isn't available.")),
            siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        let reply = try await tool.call(arguments: .init(blockId: "b1", instruction: "y"))
        #expect(reply.contains("Apple Intelligence isn't available."))
    }

    @Test("replies unavailable immediately, without reading the block, when no assistant is wired")
    func repliesUnavailableWithNilAssistant() async throws {
        let tool = RewriteBlockTool(
            accessProvider: { FakeAccess(text: "Original.") }, writingHelp: nil,
            siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        let reply = try await tool.call(arguments: .init(blockId: "b1", instruction: "y"))
        #expect(reply.contains("Apple Intelligence") || reply.contains("available"))
    }

    // MARK: Fix round 2 — accessProvider resolved at call time, optional blockId (#1227 PR 2)

    @Test("replies canvasNotOpen, not blockNotFound, when the provider resolves no canvas")
    func repliesCanvasNotOpenWhenProviderResolvesNil() async throws {
        let tool = RewriteBlockTool(
            accessProvider: { nil },
            writingHelp: FakeWritingHelp(outcome: .rewritten("x")),
            siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        let reply = try await tool.call(arguments: .init(blockId: "b1", instruction: "y"))
        #expect(reply.contains("Edit Page"))
    }

    @Test("omitted blockId resolves to the canvas's currently selected block")
    func omittedBlockIdUsesSelection() async throws {
        let tool = RewriteBlockTool(
            accessProvider: { FakeAccess(text: "Original.", selected: "b1") },
            writingHelp: FakeWritingHelp(outcome: .rewritten("Punchier.")),
            siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        let reply = try await tool.call(arguments: .init(instruction: "make this punchier"))
        #expect(reply.contains("rewrote"))
    }

    @Test("omitted blockId with nothing selected replies blockNotFound")
    func omittedBlockIdWithNoSelectionRepliesBlockNotFound() async throws {
        let tool = RewriteBlockTool(
            accessProvider: { FakeAccess(text: "Original.", selected: nil) },
            writingHelp: FakeWritingHelp(outcome: .rewritten("x")),
            siteID: "site-1", siteDirectory: URL(fileURLWithPath: "/tmp/site"))
        let reply = try await tool.call(arguments: .init(instruction: "y"))
        #expect(reply.lowercased().contains("couldn't find"))
    }
}
#endif

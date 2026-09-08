import Testing
import Foundation
@testable import AnglesiteCore
@testable import AnglesiteSiteModel

#if compiler(>=6.4)
import FoundationModels
#endif

// The shared `FakeConversationalAssistant` (FakeConversationalAssistant.swift) provides the
// canned "Got it." reply plus the failure/empty-reply variants these tests exercise.

@Suite struct DesignInterviewModelTests {
    /// Builds a real `.anglesite` package layout: a package root containing a `Source/`
    /// subdirectory with the `src/styles/global.css` fixture nested underneath, matching
    /// `AnglesitePackage.sourceURL`'s real `url/Source` invariant (not a synthetic wrapper).
    private func makeSite() throws -> AnglesitePackage {
        let packageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = packageRoot.appendingPathComponent("Source/src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        try ":root {\n  --color-primary: #000000;\n}\n".write(
            to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
        return AnglesitePackage(url: packageRoot)
    }

    /// A package whose `Source/` exists but has no `src/styles/global.css` at all, so
    /// `DesignApplyService.apply` fails with `.missingGlobalCSS` rather than writing anything.
    private func makeSiteWithoutGlobalCSS() throws -> AnglesitePackage {
        let packageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: packageRoot.appendingPathComponent("Source"), withIntermediateDirectories: true)
        return AnglesitePackage(url: packageRoot)
    }

    @Test @MainActor func sendAppendsToTranscriptAndAdvancesStage() async throws {
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSite())
        #expect(model.draft.stage == .intent)
        await model.send("It's a cozy neighborhood bakery.")
        #expect(model.draft.stage == .mood)
        #expect(model.transcript.contains { $0.role == "user" && $0.text == "It's a cozy neighborhood bakery." })
        #expect(model.transcript.contains { $0.role == "assistant" && $0.text == "Got it." })
    }

    @Test @MainActor func nudgeAdjustsAxesWithoutAdvancingStage() async throws {
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSite())
        let before = model.draft.axes.temperature
        model.nudge(.warmer)
        #expect(model.draft.axes.temperature > before)
        #expect(model.draft.stage == .intent)
    }

    @Test @MainActor func skipToAxisConfirmationJumpsStage() async throws {
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSite())
        model.skipToAxisConfirmation()
        #expect(model.draft.stage == .axisConfirmation)
    }

    @Test @MainActor func confirmAndApplyWritesThroughDesignApplyService() async throws {
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSite())
        model.skipToAxisConfirmation()
        await model.confirmAndApply()
        guard case .success(let applied) = model.applyResult else { Issue.record("expected success"); return }
        #expect(applied.writtenFiles.contains("src/styles/global.css"))
        #expect(model.draft.stage == .done)
    }

    @Test @MainActor func sendOnIntentStageCapturesUserMessageAsFreeTextNote() async throws {
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSite())
        #expect(model.draft.stage == .intent)
        await model.send("It's a cozy neighborhood bakery for regulars who work nearby.")
        #expect(model.draft.freeTextNotes == ["It's a cozy neighborhood bakery for regulars who work nearby."])
    }

    @Test @MainActor func sendOnIntentStageFailureDoesNotCaptureAFreeTextNote() async throws {
        // Regression for a PR #1950 review comment: appending before the failure-path early
        // returns would leave a stray note for a turn whose reply never actually landed — and
        // duplicate it again on every retry, since the stage (and thus this guard) never
        // advances past `.intent` on failure.
        let model = DesignInterviewModel(
            businessType: "bakery",
            assistant: FakeConversationalAssistant(failureMessage: "model unavailable"),
            package: try makeSite())
        await model.send("It's a cozy neighborhood bakery.")
        #expect(model.draft.stage == .intent)
        #expect(model.draft.freeTextNotes.isEmpty)
    }

    @Test @MainActor func sendOnIntentStageEmptyReplyDoesNotCaptureAFreeTextNote() async throws {
        let model = DesignInterviewModel(
            businessType: "bakery",
            assistant: FakeConversationalAssistant(emitsEmptyReply: true),
            package: try makeSite())
        await model.send("It's a cozy neighborhood bakery.")
        #expect(model.draft.stage == .intent)
        #expect(model.draft.freeTextNotes.isEmpty)
    }

    @Test @MainActor func sendOnLaterStagesDoesNotDuplicateIntoFreeTextNotes() async throws {
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSite())
        await model.send("It's a cozy neighborhood bakery.") // .intent -> .mood
        await model.send("Warm and inviting.") // .mood -> .brandAnchor
        #expect(model.draft.freeTextNotes == ["It's a cozy neighborhood bakery."])
    }

    @Test @MainActor func confirmAndApplyWritesDesignAndProductContextDocuments() async throws {
        let package = try makeSite()
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: package)
        await model.send("It's a cozy neighborhood bakery for regulars.") // captures the intent note
        model.skipToAxisConfirmation()
        await model.confirmAndApply()
        guard case .success(let applied) = model.applyResult else { Issue.record("expected success"); return }
        #expect(applied.writtenFiles.contains("DESIGN.md"))
        #expect(applied.writtenFiles.contains("PRODUCT.md"))

        let designMD = try String(contentsOf: package.sourceURL.appendingPathComponent("DESIGN.md"), encoding: .utf8)
        #expect(designMD.hasPrefix(GeneratedDesignDocument.marker))
        #expect(designMD.contains("## Mood"))

        let productMD = try String(contentsOf: package.sourceURL.appendingPathComponent("PRODUCT.md"), encoding: .utf8)
        #expect(productMD.contains("website of a bakery"))
        #expect(productMD.contains("It's a cozy neighborhood bakery for regulars."))
    }

    @Test @MainActor func sendOnInBandFailureAppendsErrorAndDoesNotAdvanceStage() async throws {
        let model = DesignInterviewModel(
            businessType: "bakery",
            assistant: FakeConversationalAssistant(failureMessage: "model unavailable"),
            package: try makeSite())
        #expect(model.draft.stage == .intent)
        await model.send("It's a cozy neighborhood bakery.")
        #expect(model.draft.stage == .intent, "stage must not advance when the assistant reports .failed")
        guard let lastAssistantTurn = model.transcript.last(where: { $0.role == "assistant" }) else {
            Issue.record("expected an assistant transcript entry")
            return
        }
        #expect(!lastAssistantTurn.text.isEmpty)
        #expect(lastAssistantTurn.text.contains("model unavailable"))
    }

    @Test @MainActor func sendOnEmptyReplyAppendsErrorAndDoesNotAdvanceStage() async throws {
        let model = DesignInterviewModel(
            businessType: "bakery",
            assistant: FakeConversationalAssistant(emitsEmptyReply: true),
            package: try makeSite())
        #expect(model.draft.stage == .intent)
        await model.send("It's a cozy neighborhood bakery.")
        #expect(model.draft.stage == .intent, "stage must not advance when the assistant sends no text")
        guard let lastAssistantTurn = model.transcript.last(where: { $0.role == "assistant" }) else {
            Issue.record("expected an assistant transcript entry")
            return
        }
        #expect(!lastAssistantTurn.text.isEmpty)
    }

    @Test @MainActor func sendAdvancesThroughAllStagesAcrossMultipleTurns() async throws {
        let model = DesignInterviewModel(businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSite())
        #expect(model.draft.stage == .intent)

        await model.send("It's a cozy neighborhood bakery.")
        #expect(model.draft.stage == .mood)

        await model.send("Warm and inviting, but still modern.")
        #expect(model.draft.stage == .brandAnchor)

        await model.send("Think a warm oat-milk latte color.")
        #expect(model.draft.stage == .axisConfirmation)

        await model.send("That all sounds right.")
        #expect(model.draft.stage == .done)
    }

    @Test @MainActor func confirmAndApplyOnFailureLeavesStageAtAxisConfirmation() async throws {
        let model = DesignInterviewModel(
            businessType: "bakery", assistant: FakeConversationalAssistant(), package: try makeSiteWithoutGlobalCSS())
        model.skipToAxisConfirmation()
        await model.confirmAndApply()
        guard case .failure(let error) = model.applyResult else { Issue.record("expected failure"); return }
        #expect(error == .missingGlobalCSS)
        #expect(model.draft.stage == .axisConfirmation, "stage must not become .done when apply fails")
    }
}

extension DesignInterviewModelTests {
    @Test func applyingTurnReplyDeltasNudgesAxesAndCapturesBrandColor() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let before = draft.axes.temperature
        DesignInterviewModel.applyTurnReplyDeltas(
            temperature: 0.1, weight: nil, register: nil, time: nil, voice: nil,
            brandColorHex: "#ff6600", to: &draft
        )
        #expect(draft.axes.temperature == before + 0.1)
        #expect(draft.brandColorHex == "#ff6600")
    }

    @Test func applyingNilDeltasLeavesAxesUnchanged() {
        var draft = DesignInterviewDraft(businessType: "bakery")
        let before = draft.axes
        DesignInterviewModel.applyTurnReplyDeltas(
            temperature: nil, weight: nil, register: nil, time: nil, voice: nil,
            brandColorHex: nil, to: &draft
        )
        #expect(draft.axes == before)
    }
}

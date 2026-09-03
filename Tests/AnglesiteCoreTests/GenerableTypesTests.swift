import Testing
import Foundation
@testable import AnglesiteCore

// Gated for the same reason as the types under test — FoundationModels is unavailable at
// runtime on CI (#128). These are live-model round-trip tests by design (Apple's
// FoundationModels exposes no fake/mock session to substitute); they skip when the
// on-device model isn't present so they never produce spurious CI failures. Registered in
// scripts/lib/live-model-tests.sh so local full runs serialize on the on-device model (#1594).
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels

@Suite("GenerableTypes round-trips")
struct GenerableTypesTests {

    /// Early-return guard: live tests only run on a host with the on-device model available.
    /// Returns nil (caller should `return`) when the model can't be used.
    private func availableSession(instructions: String) -> LanguageModelSession? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        return LanguageModelSession(instructions: instructions)
    }

    @Test("GeneratedEditCommand parses with a known operation")
    func editCommandRoundTrips() async throws {
        guard let session = availableSession(instructions: "You produce a single structured edit command.") else { return }
        let result = try await session.respond(
            to: "Change the <h1> in src/pages/index.md to say 'Welcome'.",
            generating: GeneratedEditCommand.self
        ).content
        #expect(!result.filePath.isEmpty)
        #expect(!result.selector.isEmpty)
        #expect(!result.explanation.isEmpty)
        #expect(!result.value.isEmpty)
    }

    @Test("GeneratedPageMeta parses with non-empty fields")
    func pageMetaRoundTrips() async throws {
        guard let session = availableSession(instructions: "You produce SEO metadata for a web page.") else { return }
        let result = try await session.respond(
            to: "Generate page metadata for an 'About our bakery' page.",
            generating: GeneratedPageMeta.self
        ).content
        #expect(!result.title.isEmpty)
        #expect(!result.slug.isEmpty)
        #expect(!result.description.isEmpty)
        #expect(!result.tags.isEmpty)
    }

    @Test("GeneratedAltText parses a boolean and string")
    func altTextRoundTrips() async throws {
        guard let session = availableSession(instructions: "You produce image alt text.") else { return }
        let result = try await session.respond(
            to: "Generate alt text for a photo of a golden retriever running on a beach.",
            generating: GeneratedAltText.self
        ).content
        #expect(result.isDecorative || !result.altText.isEmpty)
    }

    @Test("ContentSummary parses numeric reading metadata")
    func summaryRoundTrips() async throws {
        guard let session = availableSession(instructions: "You summarize content.") else { return }
        let result = try await session.respond(
            to: "Summarize: 'Our bakery opened in 1998 and specializes in sourdough. We bake fresh daily.'",
            generating: ContentSummary.self
        ).content
        #expect(!result.summary.isEmpty)
        #expect(result.wordCount > 0)
        #expect(result.readingTimeMinutes >= 0)
        #expect(!result.topics.isEmpty)
    }

    @Test("ContentClassification parses to a known case")
    func classificationRoundTrips() async throws {
        guard let session = availableSession(instructions: "You classify web page content into a category.") else { return }
        let result = try await session.respond(
            to: "Classify this content: 'Posted March 3rd — my thoughts on the new framework release...'",
            generating: ContentClassification.self
        ).content
        // Any of the five cases is acceptable; assert the `other` case carries a non-empty label
        // (the known cases are guaranteed valid by the type, so there's nothing more to check).
        if case .other(let label) = result {
            #expect(!label.isEmpty)
        }
    }
}
#endif

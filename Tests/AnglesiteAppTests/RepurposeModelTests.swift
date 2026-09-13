import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteAppCore

/// Regression coverage for a PR #1980 review finding: `ModelTierNoticeView` was gated only on
/// `RepurposeModel.unavailable` (the pre-6.4-toolchain case), not on Apple Intelligence being
/// unavailable at runtime — which `PostRepurposer.variants()` surfaces by returning every
/// platform with the same "needs Apple Intelligence" `failure`, leaving `unavailable` `false`.
/// `showsModelTierBadge` is the fix.
@Suite struct RepurposeModelTests {
    private struct StubRepurposer: PostRepurposing {
        let variants: [PlatformPostVariant]
        func variants(post: PostSource, postURL: String, specs: [PlatformPostSpec], preamble: String?,
                     siteID: String, siteDirectory: URL) async -> [PlatformPostVariant] {
            variants
        }
    }

    private func makeConventionsStore() -> ProjectConventionsStore {
        ProjectConventionsStore(configDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString))
    }

    /// A throwaway site directory with one post at `src/content/blog/<slug>.md`, so
    /// `PostSource.load(slug:sourceDirectory:)` (called from `RepurposeModel.generate()`)
    /// succeeds before the stub repurposer is ever reached.
    private func makeSiteWithPost(slug: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let blogDir = root.appendingPathComponent("src/content/blog")
        try FileManager.default.createDirectory(at: blogDir, withIntermediateDirectories: true)
        let contents = """
        ---
        title: Test Post
        ---
        Body text.
        """
        try contents.write(to: blogDir.appendingPathComponent("\(slug).md"), atomically: true, encoding: .utf8)
        return root
    }

    @MainActor
    @Test("badge is hidden when the toolchain has no repurposer at all")
    func hiddenWhenCompileTimeUnavailable() {
        let model = RepurposeModel(
            siteID: "s", sourceDirectory: URL(fileURLWithPath: "/tmp"), slug: "post",
            conventionsStore: makeConventionsStore(), repurposer: nil)
        #expect(model.unavailable)
        #expect(!model.showsModelTierBadge)
    }

    @MainActor
    @Test("badge shows once at least one variant generates")
    func showsWhenAVariantSucceeds() async throws {
        let siteDirectory = try makeSiteWithPost(slug: "post")
        let variants = [
            PlatformPostVariant(platform: "Instagram", text: "A great caption", failure: nil),
            PlatformPostVariant(platform: "Facebook", text: nil, failure: "Couldn't fit Facebook's limit."),
        ]
        let model = RepurposeModel(
            siteID: "s", sourceDirectory: siteDirectory, slug: "post",
            conventionsStore: makeConventionsStore(), repurposer: StubRepurposer(variants: variants))
        await model.generate()
        #expect(!model.variants.isEmpty)
        #expect(model.showsModelTierBadge)
    }

    @MainActor
    @Test("badge is hidden when every variant fails as Apple Intelligence unavailable")
    func hiddenWhenRuntimeUnavailable() async throws {
        let siteDirectory = try makeSiteWithPost(slug: "post")
        let unavailableMessage = ContentHelpDialogs.assistantUnavailable(feature: "Repurposing")
        let variants = RepurposePlatformSpecs.all.map {
            PlatformPostVariant(platform: $0.platform, text: nil, failure: unavailableMessage)
        }
        let model = RepurposeModel(
            siteID: "s", sourceDirectory: siteDirectory, slug: "post",
            conventionsStore: makeConventionsStore(), repurposer: StubRepurposer(variants: variants))
        #expect(!model.unavailable)
        await model.generate()
        #expect(!model.variants.isEmpty)
        #expect(model.variants.allSatisfy { $0.text == nil })
        #expect(!model.showsModelTierBadge)
    }

    @MainActor
    @Test("badge shows before generation has produced any variants")
    func showsBeforeVariantsArrive() {
        let model = RepurposeModel(
            siteID: "s", sourceDirectory: URL(fileURLWithPath: "/tmp"), slug: "post",
            conventionsStore: makeConventionsStore(), repurposer: StubRepurposer(variants: []))
        #expect(model.variants.isEmpty)
        #expect(model.showsModelTierBadge)
    }
}

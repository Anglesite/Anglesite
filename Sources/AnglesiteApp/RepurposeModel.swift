import Foundation
import Observation
import AnglesiteCore

/// Drives the Repurpose sheet (#465): generate per-platform variants for one post, offer
/// copy/share, then deterministically record published URLs as the post's syndication trail.
@Observable @MainActor
final class RepurposeModel: Identifiable {
    let id = UUID()
    let siteID: String
    let sourceDirectory: URL
    let slug: String
    private let conventionsStore: ProjectConventionsStore
    private let repurposer: (any PostRepurposing)?

    var post: PostSource?
    var variants: [PlatformPostVariant] = []
    var publishedURLs: [String: String] = [:]  // platform → pasted URL
    var running = false
    var syndicationSaved = false
    var errorMessage: String?
    /// Set when the site has no configured domain — `RepurposeReply.missingDomainWarning`,
    /// shown so the owner knows the links in each variant point at `example.com` (#465, Task 16
    /// domain-resolution correction: the app writes `DOMAIN`, not `SITE_DOMAIN`, into
    /// `.site-config`, so this reuses `WebsiteAnalyticsAsset.bestHost` rather than a raw key read).
    var domainWarning: String?
    var unavailable: Bool { repurposer == nil }

    /// Whether `ModelTierNoticeView` should show (#1965 review fix). `unavailable` alone only
    /// covers the pre-6.4-toolchain case — when Apple Intelligence is off at runtime,
    /// `PostRepurposer.variants()` returns every platform with the same "needs Apple
    /// Intelligence" `failure` rather than flipping `unavailable`. Hidden whenever `variants` is
    /// non-empty and none of them actually generated text — nothing ran on-device, so there's
    /// nothing to badge. Shown while `variants` is still empty (nothing has run yet, or
    /// generation is in flight) so the badge doesn't flicker off and back on around a normal run.
    var showsModelTierBadge: Bool {
        !unavailable && (variants.isEmpty || variants.contains { $0.text != nil })
    }

    init(siteID: String, sourceDirectory: URL, slug: String, conventionsStore: ProjectConventionsStore,
         repurposer: (any PostRepurposing)? = PostRepurposerFactory.makeDefault()) {
        self.siteID = siteID
        self.sourceDirectory = sourceDirectory
        self.slug = slug
        self.conventionsStore = conventionsStore
        self.repurposer = repurposer
    }

    func generate() async {
        errorMessage = nil
        guard let repurposer, !running else { return }
        running = true
        defer { running = false }
        guard let post = PostSource.load(slug: slug, sourceDirectory: sourceDirectory) else {
            errorMessage = String(localized: "Couldn't load the post \"\(slug)\".")
            return
        }
        self.post = post
        let config = (try? String(contentsOf: sourceDirectory.appendingPathComponent(".site-config"), encoding: .utf8)) ?? ""
        let domain = WebsiteAnalyticsAsset.bestHost(from: config, fallback: "")
        domainWarning = domain.isEmpty ? RepurposeReply.missingDomainWarning : nil
        let conventions = await conventionsStore.load()
        let preamble = BrandVoiceGuidance.preamble(
            conventions: conventions, businessType: SiteBusinessType.read(sourceDirectory: sourceDirectory))
        variants = await repurposer.variants(
            post: post,
            postURL: PostSource.postURL(
                domain: domain.isEmpty ? "example.com" : domain, collection: post.collection, slug: post.slug),
            specs: RepurposePlatformSpecs.all,
            preamble: preamble, siteID: siteID, siteDirectory: sourceDirectory)
    }

    func saveSyndication() {
        errorMessage = nil
        guard let post else { return }
        let urls = publishedURLs.values
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else { return }
        let fileURL = sourceDirectory.appendingPathComponent(post.filePath)
        do {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            try SyndicationFrontmatter.adding(urls: urls.sorted(), to: contents)
                .write(to: fileURL, atomically: true, encoding: .utf8)
            syndicationSaved = true
        } catch {
            errorMessage = String(localized: "Couldn't record the syndication URLs: \(error.localizedDescription)")
        }
    }
}

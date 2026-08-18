import Foundation

/// Reads/writes `Source/utm-codes.json` — a git-tracked, ordered list of named UTM campaigns a
/// site owner assigns to RSS collections and/or the Fediverse outbox (#1092). Mirrors
/// `RedirectsStore`'s shape and rationale exactly: rooted at `sourceDirectory` (the `Source/` git
/// repo), not `Config/`, because both the Astro build (RSS/Atom/JSON Feed generation) and the
/// Cloudflare Worker (Fediverse fan-out) need to read it — app-owned `Config/` state is invisible
/// to both.
///
/// A template-side lib (`src/lib/utm-codes.ts`) is the RSS/feed consumer at build time; a
/// worker-local `worker/utm-codes.ts` (paired with a static `../utm-codes.json` import) is the
/// Fediverse consumer at runtime. This type only owns the read/write/validate contract the app's
/// UTM Codes UI uses to produce that file.
public struct UTMCodesStore: Sendable {
    /// One named UTM campaign, as serialized in `utm-codes.json`.
    public struct Campaign: Sendable, Equatable, Codable, Identifiable {
        public var id: UUID
        /// `utm_source` — e.g. "rss", "fediverse".
        public var source: String
        /// `utm_medium` — e.g. "feed", "social".
        public var medium: String
        /// `utm_campaign`.
        public var campaign: String
        /// `utm_term`, omitted from the tagged URL and from JSON when unset.
        public var term: String?
        /// `utm_content`, omitted from the tagged URL and from JSON when unset.
        public var content: String?
        /// Which RSS collections and/or the Fediverse outbox this campaign is currently applied
        /// to. A campaign with no targets is a draft — defined but not yet wired into any output.
        public var appliesTo: [Target]

        public init(
            id: UUID = UUID(),
            source: String = "",
            medium: String = "",
            campaign: String = "",
            term: String? = nil,
            content: String? = nil,
            appliesTo: [Target] = []
        ) {
            self.id = id
            self.source = source
            self.medium = medium
            self.campaign = campaign
            self.term = term
            self.content = content
            self.appliesTo = appliesTo
        }
    }

    /// One tagging target: an RSS collection (matching `FEED_COLLECTIONS`' keys in the template's
    /// `src/lib/feeds.ts`) or the Fediverse outbox. Raw values round-trip through
    /// `utm-codes.json` verbatim, so the Swift and TypeScript sides must agree on these strings.
    public enum Target: String, Sendable, Codable, CaseIterable, Hashable {
        case blog, notes, articles, photos, albums, bookmarks, replies, likes
        case fediverse

        /// User-facing label for the UTM Codes UI, matching `FEED_COLLECTIONS`'s `.title` strings
        /// in `feeds.ts` for the RSS cases.
        public var displayName: String {
            switch self {
            case .blog: return "Blog"
            case .notes: return "Notes"
            case .articles: return "Articles"
            case .photos: return "Photos"
            case .albums: return "Albums"
            case .bookmarks: return "Bookmarks"
            case .replies: return "Replies"
            case .likes: return "Likes"
            case .fediverse: return "Fediverse"
            }
        }
    }

    /// Invariants ``UTMCodesStore/validate(_:)`` enforces before anything reaches disk.
    public enum ValidationError: Error, Equatable {
        /// Two campaigns both claim the same target — at most one campaign can apply to a given
        /// RSS collection or Fediverse at a time.
        case duplicateTarget(Target)
        /// A campaign has at least one target but is missing the named required field.
        case missingRequiredField(UUID, field: String)
    }

    private let fileURL: URL
    private let fileManager: FileManager

    /// Roots the store at `<sourceDirectory>/utm-codes.json` — inside the `Source/` git repo, for
    /// the same reason `RedirectsStore` does: this is site content the build/deploy pipeline
    /// reads, not app-owned state. `fileManager` is injectable for tests.
    public init(sourceDirectory: URL, fileManager: FileManager = .default) {
        self.fileURL = sourceDirectory.appendingPathComponent("utm-codes.json")
        self.fileManager = fileManager
    }

    /// `[]` (not a throw) when the file is absent — the normal "no UTM codes yet" case for a
    /// freshly scaffolded site.
    public func load() throws -> [Campaign] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([Campaign].self, from: data)
    }

    /// Validates, normalizes each campaign's `appliesTo` to a deterministic order, then writes the
    /// full list (pretty-printed, sorted keys, atomic — the file is git-tracked and hand-readable,
    /// so diffs should stay minimal). Validation runs here rather than only in the UI, so no code
    /// path can persist a file the template-side build/worker code would silently mis-tag from.
    ///
    /// - Returns: The normalized array actually written to disk, so callers can keep in-memory
    ///   "saved" state (and any live-edited copy) in agreement with what's on disk.
    /// - Throws: A ``ValidationError`` before touching disk, or the underlying encode/write error.
    @discardableResult
    public func save(_ campaigns: [Campaign]) throws -> [Campaign] {
        try Self.validate(campaigns)
        let normalized = campaigns.map { campaign -> Campaign in
            var campaign = campaign
            campaign.appliesTo = Target.allCases.filter { campaign.appliesTo.contains($0) }
            campaign.source = campaign.source.trimmingCharacters(in: .whitespacesAndNewlines)
            campaign.medium = campaign.medium.trimmingCharacters(in: .whitespacesAndNewlines)
            campaign.campaign = campaign.campaign.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedTerm = campaign.term?.trimmingCharacters(in: .whitespacesAndNewlines)
            campaign.term = (trimmedTerm?.isEmpty ?? true) ? nil : trimmedTerm
            let trimmedContent = campaign.content?.trimmingCharacters(in: .whitespacesAndNewlines)
            campaign.content = (trimmedContent?.isEmpty ?? true) ? nil : trimmedContent
            return campaign
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized)
        try data.write(to: fileURL, options: .atomic)
        return normalized
    }

    /// Checks every campaign's invariants: no two campaigns share a target, and any campaign with
    /// at least one target has non-empty source/medium/campaign (a draft with no targets can be
    /// left incomplete).
    ///
    /// - Throws: A ``ValidationError`` for the first violation found.
    public static func validate(_ campaigns: [Campaign]) throws {
        var seenTargets = Set<Target>()
        for campaign in campaigns {
            for target in campaign.appliesTo {
                guard !seenTargets.contains(target) else {
                    throw ValidationError.duplicateTarget(target)
                }
                seenTargets.insert(target)
            }
        }
        for campaign in campaigns where !campaign.appliesTo.isEmpty {
            if campaign.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError.missingRequiredField(campaign.id, field: "source")
            }
            if campaign.medium.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError.missingRequiredField(campaign.id, field: "medium")
            }
            if campaign.campaign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError.missingRequiredField(campaign.id, field: "campaign")
            }
        }
    }
}

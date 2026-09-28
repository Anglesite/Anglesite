import Foundation

/// What a link to a page would look like if pasted into Mastodon, Bluesky, Slack, iMessage, or
/// LinkedIn — the fields every network's card shares (title, description, domain, optional
/// image), not a per-network mock (multi-network rendering is parent #1995's scope, not this
/// pane's — #2005 §7). A pure, `Sendable` value so `PageInspectorView`'s "Shared as" section
/// stays a thin renderer over it: `CLAUDE.md` ▸ Build records that hosted app-target logic
/// needing CI coverage belongs in a testable `AnglesiteCore` type (the `DeployModel`/
/// `TokenOnboarding` precedent).
public struct SharePreviewCard: Sendable, Equatable {
    /// `LinkMetadata.title`, unaltered — nil means the page truly has none, which the "Shared
    /// as" section renders as an explicit placeholder rather than inventing text.
    public var title: String?
    public var description: String?
    /// Absolute http(s) only — a page with no usable `og:image` gets no card image, never
    /// substitute artwork (matches `LinkMetadataParser`'s documented "no `<img>` guessing" rule).
    public var imageURL: URL?
    /// The page URL's host, with its port when it has one (the dev-server preview URL always
    /// does) — the domain an owner would actually recognize this card by.
    public var domain: String

    public init(title: String?, description: String?, imageURL: URL?, domain: String) {
        self.title = title
        self.description = description
        self.imageURL = imageURL
        self.domain = domain
    }

    /// Builds the card a viewer would see if `pageURL` were shared, from metadata scraped off
    /// that page. `imageURL` reuses `LinkMetadataFetcher.resolvedImageURL` — the same
    /// relative-resolution and http(s)-only gate a live fetch already applies — rather than
    /// re-implementing it: a value already resolved by the fetcher round-trips unchanged, and a
    /// relative value handed in directly (as in tests, which construct `LinkMetadata` without
    /// fetching) resolves against `pageURL` the same way.
    ///
    /// - Parameters:
    ///   - metadata: Scraped page metadata, typically from ``LinkMetadataFetcher/fetch(url:)``.
    ///   - pageURL: The page's own URL — resolves a relative `imageURL` and derives ``domain``.
    /// - Returns: The card, with every field left `nil` (or, for ``domain``, derived from
    ///   `pageURL` alone) rather than substituted when `metadata` doesn't carry it.
    public static func make(from metadata: LinkMetadata, pageURL: URL) -> SharePreviewCard {
        let resolvedImage = LinkMetadataFetcher.resolvedImageURL(metadata.imageURL, relativeTo: pageURL)
        return SharePreviewCard(
            title: metadata.title,
            description: metadata.description,
            imageURL: resolvedImage.flatMap { URL(string: $0) },
            domain: displayDomain(for: pageURL)
        )
    }

    static func displayDomain(for pageURL: URL) -> String {
        guard let host = pageURL.host else { return pageURL.absoluteString }
        guard let port = pageURL.port else { return host }
        return "\(host):\(port)"
    }
}

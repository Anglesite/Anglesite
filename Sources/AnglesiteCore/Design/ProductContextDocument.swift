import Foundation

/// Renders `Source/PRODUCT.md` — the product-context companion to ``DesignContextDocument``'s
/// `DESIGN.md`, so an external agent editing `Source/` knows what the site is *for*, not just how
/// it looks (#72, #1947).
///
/// Section headings (`Platform`, `Purpose`, `Audience`) match the current
/// [Impeccable](https://impeccable.style/docs) `PRODUCT.md` convention's names for the facts this
/// module actually has. Impeccable's own template also carries `Positioning`, `Evidence on hand`,
/// `Accessibility needs` and similar strategy sections — this builder omits every one of those
/// rather than fabricate a competitive claim or accessibility audit finding Anglesite never
/// gathered; an owner or agent that has that context can add it by hand; the ownership marker
/// gate (``GeneratedDesignDocument``) means hand-added sections survive future regenerations by
/// this generator being routed to notice-only, not silently dropped. Pure string rendering — no
/// I/O — same division of labor as ``DesignContextDocument``.
public enum ProductContextDocument {
    /// - Parameters:
    ///   - displayName: The site's display name (``SiteConfigValues/siteName(sourceDirectory:)``),
    ///     when known.
    ///   - businessType: The owner-declared business type/category that seeded the design (e.g.
    ///     `"bakery"`) — `DesignInterviewDraft.businessType` or `SiteBusinessType.read(...)`.
    ///   - siteType: The site's broad kind (`NewSiteDraft.siteType`'s `rawValue`, read back via
    ///     `.site-config`'s `SITE_TYPE` key) when one was recorded — `.blank` writes no key, so
    ///     this is commonly `nil`.
    ///   - audienceAndIntentNotes: Free-text owner remarks captured during the interview's
    ///     `.intent` stage (``DesignInterviewDraft/freeTextNotes``) — never invented when empty.
    public static func render(
        displayName: String?,
        businessType: String?,
        siteType: String?,
        audienceAndIntentNotes: [String]
    ) -> String {
        var sections: [String] = [
            "## Platform\n\nWeb — a static site built with Anglesite.",
        ]

        var purposeLines: [String] = []
        if let businessType, !businessType.isEmpty {
            purposeLines.append("This is the website of a \(businessType).")
        }
        if let siteType, !siteType.isEmpty {
            purposeLines.append("Site type: \(siteType).")
        }
        if !purposeLines.isEmpty {
            sections.append("## Purpose\n\n\(purposeLines.joined(separator: " "))")
        }

        if !audienceAndIntentNotes.isEmpty {
            let notes = audienceAndIntentNotes.map { "- \($0)" }.joined(separator: "\n")
            sections.append("## Audience\n\nIn the owner's own words, from the design interview:\n\n\(notes)")
        }

        let name = (displayName?.isEmpty == false) ? displayName! : "This site"
        let intro = """
        \(name)'s product context for any agent editing `Source/` — set once in Anglesite's \
        design interview. See `DESIGN.md` alongside this file for the visual system.
        """

        return ([GeneratedDesignDocument.marker, "", "# Product", "", intro] + sections.flatMap { ["", $0] })
            .joined(separator: "\n") + "\n"
    }

    /// `true` when `content` is this document's own prior generated output (see
    /// ``GeneratedDesignDocument``) and therefore safe for ``DesignApplyService`` to overwrite.
    public static func isOwned(_ content: String?) -> Bool { GeneratedDesignDocument.isOwned(content) }
}

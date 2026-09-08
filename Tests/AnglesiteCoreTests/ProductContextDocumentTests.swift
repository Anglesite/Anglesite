import Testing
@testable import AnglesiteCore

@Suite struct ProductContextDocumentTests {
    @Test func startsWithTheOwnershipMarker() {
        let md = ProductContextDocument.render(
            displayName: nil, businessType: nil, siteType: nil, audienceAndIntentNotes: []
        )
        #expect(md.hasPrefix(GeneratedDesignDocument.marker))
    }

    @Test func alwaysIncludesPlatform() {
        let md = ProductContextDocument.render(
            displayName: nil, businessType: nil, siteType: nil, audienceAndIntentNotes: []
        )
        #expect(md.contains("## Platform"))
        #expect(md.contains("Web"))
    }

    @Test func includesPurposeFromBusinessTypeAndSiteType() {
        let md = ProductContextDocument.render(
            displayName: "Oat & Ember", businessType: "bakery", siteType: "business", audienceAndIntentNotes: []
        )
        #expect(md.contains("## Purpose"))
        #expect(md.contains("website of a bakery"))
        #expect(md.contains("Site type: business"))
        #expect(md.contains("Oat & Ember"))
    }

    @Test func omitsPurposeSectionWhenNothingKnown() {
        let md = ProductContextDocument.render(
            displayName: nil, businessType: nil, siteType: nil, audienceAndIntentNotes: []
        )
        #expect(!md.contains("## Purpose"))
    }

    @Test func includesAudienceNotesVerbatimWhenPresent() {
        let md = ProductContextDocument.render(
            displayName: nil, businessType: "bakery", siteType: nil,
            audienceAndIntentNotes: ["It's a cozy neighborhood bakery for regulars who work nearby."]
        )
        #expect(md.contains("## Audience"))
        #expect(md.contains("It's a cozy neighborhood bakery for regulars who work nearby."))
    }

    @Test func omitsAudienceSectionWhenNoNotesCaptured() {
        let md = ProductContextDocument.render(
            displayName: nil, businessType: "bakery", siteType: nil, audienceAndIntentNotes: []
        )
        #expect(!md.contains("## Audience"))
    }

    @Test func neverFabricatesPositioningOrEvidence() {
        // Impeccable's own PRODUCT.md convention includes strategic sections (Positioning,
        // Evidence on hand) this module has no real data for — they must never appear.
        let md = ProductContextDocument.render(
            displayName: "Oat & Ember", businessType: "bakery", siteType: "business",
            audienceAndIntentNotes: ["Neighborhood regulars."]
        )
        #expect(!md.contains("## Positioning"))
        #expect(!md.contains("## Evidence"))
    }

    @Test func isOwnedTrueForOwnGeneratedOutputFalseForHandEdited() {
        let generated = ProductContextDocument.render(
            displayName: nil, businessType: nil, siteType: nil, audienceAndIntentNotes: []
        )
        #expect(ProductContextDocument.isOwned(generated))
        #expect(!ProductContextDocument.isOwned("# My hand-written product notes"))
        #expect(!ProductContextDocument.isOwned(nil))
    }
}

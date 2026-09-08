import Testing
@testable import AnglesiteCore

@Suite struct DesignContextDocumentTests {
    private let axes = DesignAxes(temperature: 0.75, weight: 0.35, register: 0.25, time: 0.3, voice: 0.45)
    private let cssVars = [
        "color-primary": "#2563eb", "color-accent": "#f59e0b",
        "font-heading": "Georgia, serif", "font-body": "system-ui, sans-serif",
        "radius-sm": "0.25rem", "spacing-unit": "1rem",
    ]

    @Test func startsWithTheOwnershipMarker() {
        let md = DesignContextDocument.render(
            axes: nil, cssVars: [:], brandVoicePreamble: nil, freedesignmdSystem: nil, appliedThemeOrPackID: nil
        )
        #expect(md.hasPrefix(GeneratedDesignDocument.marker))
    }

    @Test func includesMoodProseAndAxisTableWhenAxesGiven() {
        let md = DesignContextDocument.render(
            axes: axes, cssVars: [:], brandVoicePreamble: nil, freedesignmdSystem: nil, appliedThemeOrPackID: nil
        )
        #expect(md.contains("## Mood"))
        #expect(md.contains("warm"))
        #expect(md.contains("airy"))
        #expect(md.contains("playful"))
        #expect(md.contains("contemporary"))
        #expect(md.contains("subtle"))
        #expect(md.contains("Temperature (cool ↔ warm)"))
    }

    @Test func omitsMoodSectionWhenAxesNil() {
        let md = DesignContextDocument.render(
            axes: nil, cssVars: cssVars, brandVoicePreamble: nil, freedesignmdSystem: nil, appliedThemeOrPackID: nil
        )
        #expect(!md.contains("## Mood"))
    }

    @Test func includesTokenTablesGroupedByKind() {
        let md = DesignContextDocument.render(
            axes: nil, cssVars: cssVars, brandVoicePreamble: nil, freedesignmdSystem: nil, appliedThemeOrPackID: nil
        )
        #expect(md.contains("## Colors"))
        #expect(md.contains("`--color-primary`"))
        #expect(md.contains("`#2563eb`"))
        #expect(md.contains("## Typography"))
        #expect(md.contains("`--font-heading`"))
        #expect(md.contains("## Radius scale"))
        #expect(md.contains("`--radius-sm`"))
        #expect(md.contains("`--spacing-unit`"))
        #expect(md.contains("only source of palette"))
    }

    @Test func omitsTokenSectionsWhenCSSVarsEmpty() {
        let md = DesignContextDocument.render(
            axes: nil, cssVars: [:], brandVoicePreamble: nil, freedesignmdSystem: nil, appliedThemeOrPackID: nil
        )
        #expect(!md.contains("## Colors"))
        #expect(!md.contains("## Typography"))
        #expect(!md.contains("## Radius scale"))
    }

    @Test func includesBrandVoiceSectionWhenPresent() {
        let md = DesignContextDocument.render(
            axes: nil, cssVars: [:], brandVoicePreamble: "Match this site's voice:\nWrite in a warm tone.",
            freedesignmdSystem: nil, appliedThemeOrPackID: nil
        )
        #expect(md.contains("## Brand voice"))
        #expect(md.contains("Write in a warm tone."))
    }

    @Test func omitsBrandVoiceSectionWhenNil() {
        let md = DesignContextDocument.render(
            axes: nil, cssVars: [:], brandVoicePreamble: nil, freedesignmdSystem: nil, appliedThemeOrPackID: nil
        )
        #expect(!md.contains("## Brand voice"))
    }

    @Test func includesFreedesignmdAttributionWhenPicked() {
        let system = FreedesignmdSystem(slug: "linear-orbit", name: "Linear Orbit")
        let md = DesignContextDocument.render(
            axes: nil, cssVars: [:], brandVoicePreamble: nil, freedesignmdSystem: system, appliedThemeOrPackID: nil
        )
        #expect(md.contains("## Design system"))
        #expect(md.contains("Linear Orbit"))
        #expect(md.contains("/system/linear-orbit"))
    }

    @Test func includesAppliedThemeIDWhenPresent() {
        let md = DesignContextDocument.render(
            axes: nil, cssVars: [:], brandVoicePreamble: nil, freedesignmdSystem: nil, appliedThemeOrPackID: "warm"
        )
        #expect(md.contains("## Applied theme"))
        #expect(md.contains("`warm`"))
    }

    @Test func isOwnedTrueForOwnGeneratedOutputFalseForHandEdited() {
        let generated = DesignContextDocument.render(
            axes: nil, cssVars: [:], brandVoicePreamble: nil, freedesignmdSystem: nil, appliedThemeOrPackID: nil
        )
        #expect(DesignContextDocument.isOwned(generated))
        #expect(!DesignContextDocument.isOwned("# My hand-written design notes"))
        #expect(!DesignContextDocument.isOwned(nil))
    }
}

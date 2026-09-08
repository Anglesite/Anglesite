// Tests/AnglesiteCoreTests/DesignAxesTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct DesignAxesTests {
    @Test func defaultsForKnownBusinessType() {
        let axes = DesignAxesCatalog.defaults(forBusinessType: "restaurant")
        #expect(axes.temperature == 0.75)
        #expect(axes.weight == 0.45)
        #expect(axes.register == 0.3)
        #expect(axes.time == 0.4)
        #expect(axes.voice == 0.5)
    }

    @Test func defaultsForUnknownBusinessTypeFallsBackToBalanced() {
        let axes = DesignAxesCatalog.defaults(forBusinessType: "spaceship-repair")
        #expect(axes == DesignAxes(temperature: 0.5, weight: 0.4, register: 0.5, time: 0.5, voice: 0.4))
    }

    @Test func defaultsAreCaseAndCommaInsensitive() {
        let axes = DesignAxesCatalog.defaults(forBusinessType: "Restaurant, fine-dining")
        #expect(axes.temperature == 0.75)
    }

    @Test func adjustedClampsToUnitRange() {
        let axes = DesignAxes(temperature: 0.9, weight: 0.1, register: 0.5, time: 0.5, voice: 0.5)
        let result = DesignAxesCatalog.adjusted(axes, by: [\.temperature: 0.5, \.weight: -0.5])
        #expect(result.temperature == 1.0)
        #expect(result.weight == 0.0)
    }

    @Test func adjustedLeavesUntouchedAxesAlone() {
        let axes = DesignAxes(temperature: 0.5, weight: 0.4, register: 0.5, time: 0.5, voice: 0.4)
        let result = DesignAxesCatalog.adjusted(axes, by: [\.register: 0.1])
        #expect(result.temperature == 0.5)
        #expect(result.register == 0.6)
    }

    @Test func isValidRejectsOutOfRange() {
        #expect(DesignAxesCatalog.isValid(DesignAxes(temperature: 1.5, weight: 0.4, register: 0.5, time: 0.5, voice: 0.4)) == false)
        #expect(DesignAxesCatalog.isValid(DesignAxes(temperature: 0.5, weight: 0.4, register: 0.5, time: 0.5, voice: 0.4)) == true)
    }

    @Test func proseDescriptionReturnsLowAtOrBelowFourTenths() {
        #expect(DesignAxesCatalog.proseDescription(0.4, low: "cool", high: "warm") == "cool")
        #expect(DesignAxesCatalog.proseDescription(0.0, low: "cool", high: "warm") == "cool")
    }

    @Test func proseDescriptionReturnsHighAtOrAboveSixTenths() {
        #expect(DesignAxesCatalog.proseDescription(0.6, low: "cool", high: "warm") == "warm")
        #expect(DesignAxesCatalog.proseDescription(1.0, low: "cool", high: "warm") == "warm")
    }

    @Test func proseDescriptionStraddlesInBetween() {
        #expect(DesignAxesCatalog.proseDescription(0.5, low: "cool", high: "warm") == "between cool and warm")
    }

    @Test func moodWordsReturnsOnePerAxisInDeclarationOrder() {
        let axes = DesignAxes(temperature: 0.75, weight: 0.35, register: 0.25, time: 0.3, voice: 0.45)
        #expect(DesignAxesCatalog.moodWords(for: axes) == ["warm", "airy", "playful", "classic", "between subtle and bold"])
    }
}

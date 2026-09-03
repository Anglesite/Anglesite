# Theme Apply Wizard + Design Token Engine Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a deterministic, Claude-free way to apply a visual theme to an existing `.anglesite` site — either one of the 9 built-in quick-picks or a freedesignmd catalog system — through GUI, App Intent, and FM-chat front doors alike.

**Architecture:** A pure Swift design-token engine (ported 1:1 from the plugin's `scripts/design.ts` + `scripts/contrast.ts`) computes CSS custom-property values; a single `DesignApplyService` writes them into the site's `global.css` `:root` block plus `docs/brand.md`. `ThemeApplyWizardModel` drives the built-in/freedesignmd choice through this shared write path, following the existing `IntegrationWizardModel` triad (GUI sheet, App Intent, FM chat tool).

**Tech Stack:** Swift 6.4, SwiftUI, Swift Testing, Foundation (`URLSession`, `NSRegularExpression`), FoundationModels (optional FM-assist step only, `#if compiler(>=6.4)`).

## Global Constraints

- Target macOS 27+, Swift 6.4 toolchain (`DEVELOPER_DIR=/Applications/Xcode-beta.app/...` for `swift test`, per project memory).
- No third-party dependencies — Apple frameworks only.
- All file writes go through `AnglesiteCore`; no view ever calls `Process()` or writes files directly.
- CSS custom-property names written by this feature MUST match the **12 names already used by `Resources/Template/src/styles/global.css`**: `--color-primary`, `--color-accent`, `--color-background`, `--color-surface`, `--color-text`, `--color-text-muted`, `--font-heading`, `--font-body`, `--spacing-unit`, `--radius-sm`, `--radius-md`, `--radius-lg`. Do not introduce new var names (e.g. `--color-brand`, `--color-bg`, `--shadow-*`, `--space-xs`) — the plugin's `design.ts` uses a different, newer naming scheme than the shipped template; this plan's engine output must be mapped onto the template's existing schema, not the plugin's.
- Every new type is `Sendable`; models that touch SwiftUI state are `@MainActor @Observable`, following `IntegrationWizardModel`.
- No FM dependency in Tasks 1–7 — those are pure, CI-testable. FM is used only in Task 8 (optional catalog re-rank), gated `#if compiler(>=6.4)`.

---

## File Structure

```
Sources/AnglesiteCore/
  WCAGContrast.swift            # Task 1 — hex/RGB/luminance/contrast-ratio math
  DesignAxes.swift               # Task 2 — DesignAxes struct, business-type defaults, adjustAxes
  DesignPaletteGenerator.swift   # Task 3 — HSL color math, generatePalette
  DesignConfigGenerator.swift    # Task 4 — Typography/Spacing/Shape + DesignConfig assembly
  DesignTokenWriter.swift        # Task 5 — CSS-var mapping (engine output -> template's 12 vars) + DESIGN.md rationale text
  DesignApplyService.swift       # Task 6 — writes global.css :root + docs/brand.md
  FreedesignmdCatalog.swift      # Task 8 — fetch + parse the systems list, per-system description
  ThemeApplyWizardModel.swift    # Task 9 — @MainActor @Observable wizard model
  SetupThemeTool.swift           # Task 11 — FM chat tool

Sources/AnglesiteApp/
  ThemeApplyWizard.swift         # Task 10 — SwiftUI sheet

Sources/AnglesiteIntents/
  ThemeIntents.swift             # Task 12 — ApplyThemeIntent

Tests/AnglesiteCoreTests/
  WCAGContrastTests.swift
  DesignAxesTests.swift
  DesignPaletteGeneratorTests.swift
  DesignConfigGeneratorTests.swift
  DesignTokenWriterTests.swift
  DesignApplyServiceTests.swift
  FreedesignmdCatalogTests.swift
  ThemeApplyWizardModelTests.swift
  SetupThemeToolTests.swift
```

`ThemeCatalog.swift` (existing) is reused unchanged for the 9 built-ins — no modification needed.

---

### Task 1: WCAG contrast math

**Files:**
- Create: `Sources/AnglesiteCore/WCAGContrast.swift`
- Test: `Tests/AnglesiteCoreTests/WCAGContrastTests.swift`

**Interfaces:**
- Produces: `struct RGBColor: Sendable, Equatable { let r, g, b: Int }`, `enum WCAGContrast { static func hexToRGB(_ hex: String) -> RGBColor?; static func relativeLuminance(_ rgb: RGBColor) -> Double; static func contrastRatio(_ hex1: String, _ hex2: String) -> Double; static func meetsAA(fg: String, bg: String) -> Bool; static func meetsAALarge(fg: String, bg: String) -> Bool; static func suggestReadable(fg: String, bg: String) -> String }`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/WCAGContrastTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct WCAGContrastTests {
    @Test func hexToRGBParsesSixDigit() {
        #expect(WCAGContrast.hexToRGB("#2563eb") == RGBColor(r: 0x25, g: 0x63, b: 0xeb))
    }

    @Test func hexToRGBExpandsThreeDigit() {
        #expect(WCAGContrast.hexToRGB("#f00") == RGBColor(r: 0xff, g: 0x00, b: 0x00))
    }

    @Test func hexToRGBRejectsInvalid() {
        #expect(WCAGContrast.hexToRGB("not-a-color") == nil)
    }

    @Test func contrastRatioBlackOnWhiteIsMax() {
        let ratio = WCAGContrast.contrastRatio("#000000", "#ffffff")
        #expect(abs(ratio - 21.0) < 0.01)
    }

    @Test func contrastRatioIsOrderIndependent() {
        #expect(WCAGContrast.contrastRatio("#123456", "#abcdef") ==
                WCAGContrast.contrastRatio("#abcdef", "#123456"))
    }

    @Test func meetsAAThreshold() {
        #expect(WCAGContrast.meetsAA(fg: "#000000", bg: "#ffffff") == true)
        #expect(WCAGContrast.meetsAA(fg: "#777777", bg: "#888888") == false)
    }

    @Test func suggestReadableReturnsOriginalWhenAlreadyPassing() {
        #expect(WCAGContrast.suggestReadable(fg: "#000000", bg: "#ffffff") == "#000000")
    }

    @Test func suggestReadableDarkensOnLightBackground() {
        let fixed = WCAGContrast.suggestReadable(fg: "#aaaaaa", bg: "#ffffff")
        #expect(WCAGContrast.meetsAA(fg: fixed, bg: "#ffffff"))
    }

    @Test func suggestReadableLightensOnDarkBackground() {
        let fixed = WCAGContrast.suggestReadable(fg: "#333333", bg: "#000000")
        #expect(WCAGContrast.meetsAA(fg: fixed, bg: "#000000"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter WCAGContrastTests`
Expected: FAIL (compile error — `WCAGContrast`/`RGBColor` don't exist yet)

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/WCAGContrast.swift
import Foundation

/// WCAG 2.2 contrast-ratio utilities, ported 1:1 from the plugin's `scripts/contrast.ts`.
/// Pure, no I/O.
public struct RGBColor: Sendable, Equatable {
    public let r: Int
    public let g: Int
    public let b: Int
    public init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }
}

public enum WCAGContrast {
    /// Parses a hex color (`#rgb` or `#rrggbb`, leading `#` optional). Returns `nil` for invalid input.
    public static func hexToRGB(_ hex: String) -> RGBColor? {
        var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if h.count == 3, h.allSatisfy({ $0.isHexDigit }) {
            h = h.map { "\($0)\($0)" }.joined()
        }
        guard h.count == 6, h.allSatisfy({ $0.isHexDigit }) else { return nil }
        let scanner = Scanner(string: h)
        var value: UInt64 = 0
        guard scanner.scanHexInt64(&value) else { return nil }
        return RGBColor(r: Int((value >> 16) & 0xFF), g: Int((value >> 8) & 0xFF), b: Int(value & 0xFF))
    }

    /// Relative luminance per WCAG 2.2 §1.4.3.
    public static func relativeLuminance(_ rgb: RGBColor) -> Double {
        func channel(_ c: Int) -> Double {
            let s = Double(c) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.r) + 0.7152 * channel(rgb.g) + 0.0722 * channel(rgb.b)
    }

    /// Contrast ratio between two hex colors. `NaN` if either fails to parse.
    public static func contrastRatio(_ hex1: String, _ hex2: String) -> Double {
        guard let rgb1 = hexToRGB(hex1), let rgb2 = hexToRGB(hex2) else { return .nan }
        let l1 = relativeLuminance(rgb1)
        let l2 = relativeLuminance(rgb2)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    public static func meetsAA(fg: String, bg: String) -> Bool { contrastRatio(fg, bg) >= 4.5 }
    public static func meetsAALarge(fg: String, bg: String) -> Bool { contrastRatio(fg, bg) >= 3 }

    private static func toHex(_ rgb: RGBColor) -> String {
        func clamp(_ n: Int) -> String { String(format: "%02x", max(0, min(255, n))) }
        return "#\(clamp(rgb.r))\(clamp(rgb.g))\(clamp(rgb.b))"
    }

    /// Darkens or lightens `fg` in 1-unit RGB steps until it meets AA against `bg`. Returns the
    /// original hex, lowercased, if it already passes or if either color fails to parse.
    public static func suggestReadable(fg: String, bg: String) -> String {
        if meetsAA(fg: fg, bg: bg) { return fg }
        guard let fgRGB = hexToRGB(fg), let bgRGB = hexToRGB(bg) else { return fg }
        let shouldDarken = relativeLuminance(bgRGB) > 0.5
        var best = fgRGB
        for step in 1...255 {
            let delta = shouldDarken ? -step : step
            let candidate = RGBColor(
                r: max(0, min(255, fgRGB.r + delta)),
                g: max(0, min(255, fgRGB.g + delta)),
                b: max(0, min(255, fgRGB.b + delta))
            )
            if meetsAA(fg: toHex(candidate), bg: toHex(bgRGB)) {
                best = candidate
                break
            }
        }
        return toHex(best)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter WCAGContrastTests`
Expected: PASS (9 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/WCAGContrast.swift Tests/AnglesiteCoreTests/WCAGContrastTests.swift
git commit -m "feat(core): port WCAG contrast utilities from plugin contrast.ts"
```

---

### Task 2: Design axes + business-type defaults

**Files:**
- Create: `Sources/AnglesiteCore/DesignAxes.swift`
- Test: `Tests/AnglesiteCoreTests/DesignAxesTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `struct DesignAxes: Sendable, Equatable, Codable { var temperature, weight, register, time, voice: Double }`, `enum DesignAxesCatalog { static func defaults(forBusinessType: String) -> DesignAxes; static func adjusted(_ axes: DesignAxes, by deltas: [WritableKeyPath<DesignAxes, Double>: Double]) -> DesignAxes; static func isValid(_ axes: DesignAxes) -> Bool }`

- [ ] **Step 1: Write the failing tests**

```swift
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignAxesTests`
Expected: FAIL (compile error)

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/DesignAxes.swift
import Foundation

/// Five design axes, each a float 0–1. Ported from the plugin's `scripts/design.ts`.
public struct DesignAxes: Sendable, Equatable, Codable {
    /// Cool (0) <-> Warm (1)
    public var temperature: Double
    /// Airy (0) <-> Dense (1)
    public var weight: Double
    /// Playful (0) <-> Authoritative (1)
    public var register: Double
    /// Classic (0) <-> Contemporary (1)
    public var time: Double
    /// Subtle (0) <-> Bold (1)
    public var voice: Double

    public init(temperature: Double, weight: Double, register: Double, time: Double, voice: Double) {
        self.temperature = temperature; self.weight = weight; self.register = register
        self.time = time; self.voice = voice
    }
}

public enum DesignAxesCatalog {
    public static let balanced = DesignAxes(temperature: 0.5, weight: 0.4, register: 0.5, time: 0.5, voice: 0.4)

    /// Business-type -> default axes. Verbatim port of `BUSINESS_AXES` in `scripts/design.ts`.
    private static let byBusinessType: [String: DesignAxes] = [
        "restaurant":   DesignAxes(temperature: 0.75, weight: 0.45, register: 0.3,  time: 0.4,  voice: 0.5),
        "bakery":       DesignAxes(temperature: 0.8,  weight: 0.35, register: 0.25, time: 0.3,  voice: 0.45),
        "brewery":      DesignAxes(temperature: 0.7,  weight: 0.55, register: 0.35, time: 0.45, voice: 0.55),
        "hospitality":  DesignAxes(temperature: 0.7,  weight: 0.4,  register: 0.4,  time: 0.35, voice: 0.4),
        "campground":   DesignAxes(temperature: 0.65, weight: 0.4,  register: 0.3,  time: 0.3,  voice: 0.45),
        "accounting":   DesignAxes(temperature: 0.2,  weight: 0.4,  register: 0.8,  time: 0.3,  voice: 0.3),
        "insurance":    DesignAxes(temperature: 0.25, weight: 0.45, register: 0.75, time: 0.35, voice: 0.3),
        "credit-union": DesignAxes(temperature: 0.3,  weight: 0.4,  register: 0.7,  time: 0.4,  voice: 0.35),
        "real-estate":  DesignAxes(temperature: 0.35, weight: 0.45, register: 0.65, time: 0.5,  voice: 0.45),
        "healthcare":   DesignAxes(temperature: 0.35, weight: 0.3,  register: 0.6,  time: 0.6,  voice: 0.3),
        "pharmacy":     DesignAxes(temperature: 0.3,  weight: 0.35, register: 0.65, time: 0.55, voice: 0.25),
        "cleaning":     DesignAxes(temperature: 0.35, weight: 0.3,  register: 0.5,  time: 0.6,  voice: 0.35),
        "grocery":      DesignAxes(temperature: 0.45, weight: 0.4,  register: 0.4,  time: 0.5,  voice: 0.4),
        "fitness":      DesignAxes(temperature: 0.45, weight: 0.7,  register: 0.55, time: 0.7,  voice: 0.8),
        "trades":       DesignAxes(temperature: 0.4,  weight: 0.65, register: 0.6,  time: 0.5,  voice: 0.7),
        "auto-dealer":  DesignAxes(temperature: 0.35, weight: 0.7,  register: 0.6,  time: 0.6,  voice: 0.75),
        "car-wash":     DesignAxes(temperature: 0.4,  weight: 0.6,  register: 0.5,  time: 0.6,  voice: 0.65),
        "plumber":      DesignAxes(temperature: 0.4,  weight: 0.6,  register: 0.55, time: 0.5,  voice: 0.6),
        "electrician":  DesignAxes(temperature: 0.35, weight: 0.6,  register: 0.55, time: 0.55, voice: 0.6),
        "farm":         DesignAxes(temperature: 0.6,  weight: 0.45, register: 0.4,  time: 0.2,  voice: 0.4),
        "florist":      DesignAxes(temperature: 0.6,  weight: 0.3,  register: 0.3,  time: 0.35, voice: 0.45),
        "hardware":     DesignAxes(temperature: 0.5,  weight: 0.55, register: 0.5,  time: 0.3,  voice: 0.5),
        "veterinarian": DesignAxes(temperature: 0.55, weight: 0.4,  register: 0.45, time: 0.4,  voice: 0.4),
        "childcare":    DesignAxes(temperature: 0.7,  weight: 0.3,  register: 0.15, time: 0.6,  voice: 0.7),
        "pet-services": DesignAxes(temperature: 0.65, weight: 0.35, register: 0.2,  time: 0.55, voice: 0.65),
        "dance-studio": DesignAxes(temperature: 0.6,  weight: 0.3,  register: 0.2,  time: 0.65, voice: 0.7),
        "youth-org":    DesignAxes(temperature: 0.6,  weight: 0.35, register: 0.25, time: 0.6,  voice: 0.6),
        "entertainment": DesignAxes(temperature: 0.55, weight: 0.4, register: 0.2,  time: 0.65, voice: 0.75),
        "salon":        DesignAxes(temperature: 0.4,  weight: 0.3,  register: 0.65, time: 0.7,  voice: 0.5),
        "photography":  DesignAxes(temperature: 0.35, weight: 0.25, register: 0.6,  time: 0.7,  voice: 0.55),
        "jewelry":      DesignAxes(temperature: 0.3,  weight: 0.25, register: 0.7,  time: 0.6,  voice: 0.45),
        "community-theater": DesignAxes(temperature: 0.45, weight: 0.35, register: 0.55, time: 0.5, voice: 0.55),
        "hotel":        DesignAxes(temperature: 0.4,  weight: 0.35, register: 0.7,  time: 0.55, voice: 0.4),
        "nonprofit":    DesignAxes(temperature: 0.55, weight: 0.4,  register: 0.4,  time: 0.5,  voice: 0.45),
        "house-of-worship": DesignAxes(temperature: 0.6, weight: 0.4, register: 0.45, time: 0.3, voice: 0.4),
        "social-services": DesignAxes(temperature: 0.55, weight: 0.4, register: 0.45, time: 0.5, voice: 0.4),
        "food-bank":    DesignAxes(temperature: 0.6,  weight: 0.4,  register: 0.35, time: 0.45, voice: 0.45),
        "animal-shelter": DesignAxes(temperature: 0.6, weight: 0.35, register: 0.3, time: 0.5, voice: 0.5),
    ]

    /// Default axis positions for a business type. Falls back to ``balanced`` for unknown types.
    /// Matches only on the substring before the first comma, lowercased and trimmed.
    public static func defaults(forBusinessType businessType: String) -> DesignAxes {
        guard !businessType.isEmpty else { return balanced }
        let key = businessType.lowercased().split(separator: ",", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespaces)
        return byBusinessType[key] ?? balanced
    }

    /// Applies each delta to the named axis, clamping the result to [0, 1].
    public static func adjusted(_ axes: DesignAxes, by deltas: [WritableKeyPath<DesignAxes, Double>: Double]) -> DesignAxes {
        var result = axes
        for (keyPath, delta) in deltas {
            result[keyPath: keyPath] = max(0, min(1, result[keyPath: keyPath] + delta))
        }
        return result
    }

    public static func isValid(_ axes: DesignAxes) -> Bool {
        [axes.temperature, axes.weight, axes.register, axes.time, axes.voice]
            .allSatisfy { !$0.isNaN && $0 >= 0 && $0 <= 1 }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignAxesTests`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DesignAxes.swift Tests/AnglesiteCoreTests/DesignAxesTests.swift
git commit -m "feat(core): port DesignAxes + business-type defaults from plugin design.ts"
```

---

### Task 3: Palette generation (HSL color math)

**Files:**
- Create: `Sources/AnglesiteCore/DesignPaletteGenerator.swift`
- Test: `Tests/AnglesiteCoreTests/DesignPaletteGeneratorTests.swift`

**Interfaces:**
- Consumes: `DesignAxes` (Task 2), `WCAGContrast.suggestReadable`/`hexToRGB` (Task 1).
- Produces: `struct DesignPalette: Sendable, Equatable, Codable { let brand, accent, bg, surface, text, muted, border: String }`, `enum DesignPaletteGenerator { static func generate(axes: DesignAxes, brandColor: String?) -> DesignPalette }`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/DesignPaletteGeneratorTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct DesignPaletteGeneratorTests {
    @Test func generatesAllSevenTokens() {
        let palette = DesignPaletteGenerator.generate(axes: DesignAxesCatalog.balanced, brandColor: nil)
        for hex in [palette.brand, palette.accent, palette.bg, palette.surface, palette.text, palette.muted, palette.border] {
            #expect(WCAGContrast.hexToRGB(hex) != nil)
        }
    }

    @Test func honorsExplicitBrandColor() {
        let palette = DesignPaletteGenerator.generate(axes: DesignAxesCatalog.balanced, brandColor: "#ff0000")
        #expect(palette.brand == "#ff0000")
    }

    @Test func ignoresInvalidBrandColorAndDerivesInstead() {
        let derived = DesignPaletteGenerator.generate(axes: DesignAxesCatalog.balanced, brandColor: "not-a-color")
        #expect(derived.brand != "not-a-color")
        #expect(WCAGContrast.hexToRGB(derived.brand) != nil)
    }

    @Test func textMeetsAAAgainstBackground() {
        let palette = DesignPaletteGenerator.generate(axes: DesignAxesCatalog.balanced, brandColor: nil)
        #expect(WCAGContrast.meetsAA(fg: palette.text, bg: palette.bg))
    }

    @Test func mutedMeetsAAAgainstBackground() {
        let palette = DesignPaletteGenerator.generate(axes: DesignAxesCatalog.balanced, brandColor: nil)
        #expect(WCAGContrast.meetsAA(fg: palette.muted, bg: palette.bg))
    }

    @Test func warmTemperatureProducesDifferentBrandHueThanCool() {
        let warm = DesignPaletteGenerator.generate(
            axes: DesignAxes(temperature: 1.0, weight: 0.4, register: 0.5, time: 0.5, voice: 0.4), brandColor: nil)
        let cool = DesignPaletteGenerator.generate(
            axes: DesignAxes(temperature: 0.0, weight: 0.4, register: 0.5, time: 0.5, voice: 0.4), brandColor: nil)
        #expect(warm.brand != cool.brand)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignPaletteGeneratorTests`
Expected: FAIL (compile error)

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/DesignPaletteGenerator.swift
import Foundation

/// Color tokens for a generated design. Ported from the plugin's `scripts/design.ts` `Palette`.
public struct DesignPalette: Sendable, Equatable, Codable {
    public let brand: String
    public let accent: String
    public let bg: String
    public let surface: String
    public let text: String
    public let muted: String
    public let border: String

    public init(brand: String, accent: String, bg: String, surface: String, text: String, muted: String, border: String) {
        self.brand = brand; self.accent = accent; self.bg = bg; self.surface = surface
        self.text = text; self.muted = muted; self.border = border
    }
}

public enum DesignPaletteGenerator {
    /// Deterministic palette generation from design axes, ported verbatim from `generatePalette` in
    /// `scripts/design.ts`. If `brandColor` is a valid hex, it becomes the brand color and the rest
    /// is derived from it; otherwise the brand color is derived from `axes.temperature`.
    public static func generate(axes: DesignAxes, brandColor: String?) -> DesignPalette {
        let isDarkMode = axes.weight > 0.75 && axes.voice > 0.7

        var brandH: Double, brandS: Double, brandL: Double
        if let brandColor, let rgb = WCAGContrast.hexToRGB(brandColor) {
            (brandH, brandS, brandL) = hexToHSL(rgb)
        } else {
            brandH = temperatureToHue(axes.temperature)
            brandS = min(0.85, max(0.35, 0.45 + (1 - axes.register) * 0.2 + axes.voice * 0.15))
            brandL = 0.42 - axes.register * 0.08
        }
        let brand = (brandColor.flatMap(WCAGContrast.hexToRGB) != nil) ? brandColor! : hslToHex(brandH, brandS, brandL)

        let accentOffset: Double = axes.voice > 0.5 ? 180 : 40
        let accentH = (brandH + accentOffset).truncatingRemainder(dividingBy: 360)
        let accentS = min(0.8, brandS + 0.05)
        let accentL = 0.45 + axes.voice * 0.1
        let accent = hslToHex(accentH, accentS, accentL)

        var bg: String, surface: String, text: String, muted: String, border: String
        if isDarkMode {
            bg = hslToHex(brandH, 0.15, 0.08 + axes.temperature * 0.04)
            surface = hslToHex(brandH, 0.12, 0.12 + axes.temperature * 0.04)
            text = hslToHex(brandH, 0.05, 0.92)
            muted = hslToHex(brandH, 0.08, 0.6)
            border = hslToHex(brandH, 0.1, 0.2)
        } else {
            let surfaceH = brandH
            let surfaceS = 0.05 + axes.temperature * 0.1
            bg = hslToHex(surfaceH, surfaceS, 0.99 - axes.temperature * 0.02)
            surface = hslToHex(surfaceH, surfaceS + 0.02, 0.96 - axes.temperature * 0.02)
            text = hslToHex(brandH, 0.1 + axes.temperature * 0.05, 0.1 + axes.weight * 0.03)
            muted = hslToHex(brandH, 0.05, 0.42 + axes.weight * 0.05)
            border = hslToHex(surfaceH, surfaceS + 0.03, 0.88 - axes.weight * 0.05)
        }

        text = WCAGContrast.suggestReadable(fg: text, bg: bg)
        muted = WCAGContrast.suggestReadable(fg: muted, bg: bg)

        return DesignPalette(brand: brand, accent: accent, bg: bg, surface: surface, text: text, muted: muted, border: border)
    }

    /// Cool (0) -> blue/teal (210), balanced (0.5) -> teal (160), warm (1) -> orange/terracotta (25).
    static func temperatureToHue(_ t: Double) -> Double {
        t <= 0.5 ? 210 - t * 100 : 160 - (t - 0.5) * 270
    }

    static func hslToHex(_ h: Double, _ s: Double, _ l: Double) -> String {
        let hue = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        let a = s * min(l, 1 - l)
        func f(_ n: Double) -> String {
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            let color = l - a * max(min(min(k - 3, 9 - k), 1), -1)
            let byte = Int((255 * max(0, min(1, color))).rounded())
            return String(format: "%02x", byte)
        }
        return "#\(f(0))\(f(8))\(f(4))"
    }

    static func hexToHSL(_ rgb: RGBColor) -> (h: Double, s: Double, l: Double) {
        let r = Double(rgb.r) / 255, g = Double(rgb.g) / 255, b = Double(rgb.b) / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        if maxC == minC { return (0, 0, l) }
        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Double
        if maxC == r { h = ((g - b) / d + (g < b ? 6 : 0)) * 60 }
        else if maxC == g { h = ((b - r) / d + 2) * 60 }
        else { h = ((r - g) / d + 4) * 60 }
        return (h, s, l)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignPaletteGeneratorTests`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DesignPaletteGenerator.swift Tests/AnglesiteCoreTests/DesignPaletteGeneratorTests.swift
git commit -m "feat(core): port HSL palette generator from plugin design.ts"
```

---

### Task 4: Typography, spacing, shape + DesignConfig assembly

**Files:**
- Create: `Sources/AnglesiteCore/DesignConfigGenerator.swift`
- Test: `Tests/AnglesiteCoreTests/DesignConfigGeneratorTests.swift`

**Interfaces:**
- Consumes: `DesignAxes` (Task 2), `DesignPalette`/`DesignPaletteGenerator.generate` (Task 3).
- Produces: `struct DesignTypography: Sendable, Equatable, Codable { let display, body, pairing: String }`, `struct DesignSpacing: Sendable, Equatable, Codable { let xs, sm, md, lg, xl: String }`, `struct DesignShape: Sendable, Equatable, Codable { let radiusSm, radiusMd, radiusLg, shadowSm, shadowMd: String }`, `struct DesignConfig: Sendable, Equatable, Codable { let axes: DesignAxes; let palette: DesignPalette; let typography: DesignTypography; let spacing: DesignSpacing; let shape: DesignShape; let siteType: String; let brandColor: String? }`, `enum DesignConfigGenerator { static func typography(for axes: DesignAxes) -> DesignTypography; static func spacing(for axes: DesignAxes) -> DesignSpacing; static func shape(for axes: DesignAxes) -> DesignShape; static func config(axes: DesignAxes, siteType: String, brandColor: String?) -> DesignConfig }`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/DesignConfigGeneratorTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct DesignConfigGeneratorTests {
    @Test func contemporaryAxesPickModernSansPairing() {
        let axes = DesignAxes(temperature: 0.5, weight: 0.4, register: 0.2, time: 1.0, voice: 0.5)
        #expect(DesignConfigGenerator.typography(for: axes).pairing == "modern-sans+modern-sans")
    }

    @Test func classicAuthoritativeAxesPickClassicSerifPairing() {
        let axes = DesignAxes(temperature: 0.5, weight: 0.4, register: 1.0, time: 0.0, voice: 0.1)
        #expect(DesignConfigGenerator.typography(for: axes).pairing == "classic-serif+modern-sans")
    }

    @Test func airyWeightProducesLargerSpacingThanDense() {
        let airy = DesignConfigGenerator.spacing(for: DesignAxes(temperature: 0.5, weight: 0.0, register: 0.5, time: 0.5, voice: 0.4))
        let dense = DesignConfigGenerator.spacing(for: DesignAxes(temperature: 0.5, weight: 1.0, register: 0.5, time: 0.5, voice: 0.4))
        #expect(parseRem(airy.md) > parseRem(dense.md))
    }

    @Test func playfulContemporaryAxesProduceRounderShapeThanAuthoritativeClassic() {
        let playful = DesignConfigGenerator.shape(for: DesignAxes(temperature: 0.5, weight: 0.4, register: 0.0, time: 1.0, voice: 0.4))
        let authoritative = DesignConfigGenerator.shape(for: DesignAxes(temperature: 0.5, weight: 0.4, register: 1.0, time: 0.0, voice: 0.4))
        #expect(parseRem(playful.radiusMd) > parseRem(authoritative.radiusMd))
    }

    @Test func configAssemblesAllParts() {
        let config = DesignConfigGenerator.config(axes: DesignAxesCatalog.balanced, siteType: "bakery", brandColor: nil)
        #expect(config.siteType == "bakery")
        #expect(config.axes == DesignAxesCatalog.balanced)
        #expect(config.brandColor == nil)
    }

    private func parseRem(_ value: String) -> Double {
        Double(value.replacingOccurrences(of: "rem", with: "")) ?? 0
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignConfigGeneratorTests`
Expected: FAIL (compile error)

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/DesignConfigGenerator.swift
import Foundation

public struct DesignTypography: Sendable, Equatable, Codable {
    public let display: String
    public let body: String
    public let pairing: String
    public init(display: String, body: String, pairing: String) { self.display = display; self.body = body; self.pairing = pairing }
}

public struct DesignSpacing: Sendable, Equatable, Codable {
    public let xs, sm, md, lg, xl: String
    public init(xs: String, sm: String, md: String, lg: String, xl: String) {
        self.xs = xs; self.sm = sm; self.md = md; self.lg = lg; self.xl = xl
    }
}

public struct DesignShape: Sendable, Equatable, Codable {
    public let radiusSm, radiusMd, radiusLg, shadowSm, shadowMd: String
    public init(radiusSm: String, radiusMd: String, radiusLg: String, shadowSm: String, shadowMd: String) {
        self.radiusSm = radiusSm; self.radiusMd = radiusMd; self.radiusLg = radiusLg
        self.shadowSm = shadowSm; self.shadowMd = shadowMd
    }
}

public struct DesignConfig: Sendable, Equatable, Codable {
    public let axes: DesignAxes
    public let palette: DesignPalette
    public let typography: DesignTypography
    public let spacing: DesignSpacing
    public let shape: DesignShape
    public let siteType: String
    public let brandColor: String?

    public init(axes: DesignAxes, palette: DesignPalette, typography: DesignTypography,
                spacing: DesignSpacing, shape: DesignShape, siteType: String, brandColor: String?) {
        self.axes = axes; self.palette = palette; self.typography = typography
        self.spacing = spacing; self.shape = shape; self.siteType = siteType; self.brandColor = brandColor
    }
}

public enum DesignConfigGenerator {
    private struct FontPairing {
        let display: String
        let body: String
        let pairing: String
        let score: (DesignAxes) -> Double
    }

    private static let fontPairings: [FontPairing] = [
        FontPairing(display: #"Georgia, "Times New Roman", Times, serif"#,
                    body: "system-ui, -apple-system, sans-serif",
                    pairing: "classic-serif+modern-sans",
                    score: { (1 - $0.time) * 2 + $0.register * 1.5 + (1 - $0.voice) * 0.5 }),
        FontPairing(display: "system-ui, -apple-system, sans-serif",
                    body: "system-ui, -apple-system, sans-serif",
                    pairing: "modern-sans+modern-sans",
                    score: { $0.time * 1.5 + (1 - $0.register) * 1 + $0.voice * 0.5 }),
        FontPairing(display: #""Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif"#,
                    body: #""Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif"#,
                    pairing: "humanist-sans+humanist-sans",
                    score: { $0.temperature * 1.5 + (1 - $0.register) * 1 + (1 - $0.voice) * 0.5 }),
        FontPairing(display: #"Georgia, "Times New Roman", Times, serif"#,
                    body: #""Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif"#,
                    pairing: "classic-serif+humanist-sans",
                    score: { (1 - $0.time) * 1.5 + $0.register * 1 + $0.temperature * 0.8 }),
        FontPairing(display: "system-ui, -apple-system, sans-serif",
                    body: #""Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif"#,
                    pairing: "modern-sans+humanist-sans",
                    score: { $0.time * 1 + $0.temperature * 0.8 + (1 - $0.register) * 0.8 }),
    ]

    public static func typography(for axes: DesignAxes) -> DesignTypography {
        let best = fontPairings.max { $0.score(axes) < $1.score(axes) } ?? fontPairings[0]
        return DesignTypography(display: best.display, body: best.body, pairing: best.pairing)
    }

    /// Airy (weight=0) -> generous spacing (1.2x). Dense (weight=1) -> tighter (0.8x).
    public static func spacing(for axes: DesignAxes) -> DesignSpacing {
        let m = 1.2 - axes.weight * 0.4
        func fmt(_ v: Double) -> String { "\((v * 1000).rounded() / 1000)rem" }
        return DesignSpacing(xs: fmt(0.25 * m), sm: fmt(0.5 * m), md: fmt(1 * m), lg: fmt(2 * m), xl: fmt(4 * m))
    }

    /// Playful (low register) + contemporary (high time) -> rounder. Bold (voice) -> stronger shadows.
    public static func shape(for axes: DesignAxes) -> DesignShape {
        let roundness = (1 - axes.register) * 0.6 + axes.time * 0.4
        func fmt(_ v: Double) -> String { "\((v * 1000).rounded() / 1000)rem" }
        let shadowAlpha = 0.06 + axes.voice * 0.08
        let shadowSpread = 2 + axes.weight * 4
        return DesignShape(
            radiusSm: fmt(0.125 + roundness * 0.25),
            radiusMd: fmt(0.25 + roundness * 0.5),
            radiusLg: fmt(0.5 + roundness * 1.0),
            shadowSm: "0 1px \(Int(shadowSpread.rounded()))px rgba(0, 0, 0, \(String(format: "%.2f", shadowAlpha)))",
            shadowMd: "0 \(Int(shadowSpread.rounded()))px \(Int((shadowSpread * 3).rounded()))px rgba(0, 0, 0, \(String(format: "%.2f", shadowAlpha * 1.5)))"
        )
    }

    public static func config(axes: DesignAxes, siteType: String, brandColor: String?) -> DesignConfig {
        DesignConfig(
            axes: axes,
            palette: DesignPaletteGenerator.generate(axes: axes, brandColor: brandColor),
            typography: typography(for: axes),
            spacing: spacing(for: axes),
            shape: shape(for: axes),
            siteType: siteType,
            brandColor: brandColor
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignConfigGeneratorTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DesignConfigGenerator.swift Tests/AnglesiteCoreTests/DesignConfigGeneratorTests.swift
git commit -m "feat(core): port typography/spacing/shape generators + DesignConfig assembly"
```

---

### Task 5: Map engine output onto the template's CSS vars + DESIGN.md rationale

**Files:**
- Create: `Sources/AnglesiteCore/DesignTokenWriter.swift`
- Test: `Tests/AnglesiteCoreTests/DesignTokenWriterTests.swift`

**Interfaces:**
- Consumes: `DesignConfig`/`DesignPalette`/`DesignTypography` (Task 4), `Theme` (existing `ThemeCatalog.swift`).
- Produces: `enum DesignTokenWriter { static func templateCSSVars(for config: DesignConfig) -> [String: String]; static func templateCSSVars(for theme: Theme) -> [String: String]; static func rationaleMarkdown(for config: DesignConfig) -> String }`

Per the Global Constraints, output var names are the template's existing 12: `color-primary`, `color-accent`, `color-background`, `color-surface`, `color-text`, `color-text-muted`, `font-heading`, `font-body`, `spacing-unit`, `radius-sm`, `radius-md`, `radius-lg`. The engine's `border`/`shadow-*`/per-step spacing scale have no template slot yet and are intentionally dropped here (out of scope — see design spec §5).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/DesignTokenWriterTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct DesignTokenWriterTests {
    @Test func mapsConfigToExactlyTheTemplateTwelveVars() {
        let config = DesignConfigGenerator.config(axes: DesignAxesCatalog.balanced, siteType: "bakery", brandColor: nil)
        let vars = DesignTokenWriter.templateCSSVars(for: config)
        #expect(Set(vars.keys) == Set([
            "color-primary", "color-accent", "color-background", "color-surface",
            "color-text", "color-text-muted", "font-heading", "font-body",
            "spacing-unit", "radius-sm", "radius-md", "radius-lg",
        ]))
    }

    @Test func configColorPrimaryComesFromPaletteBrand() {
        let config = DesignConfigGenerator.config(axes: DesignAxesCatalog.balanced, siteType: "bakery", brandColor: "#ff0000")
        let vars = DesignTokenWriter.templateCSSVars(for: config)
        #expect(vars["color-primary"] == "#ff0000")
    }

    @Test func themeVarsPassThroughUnchanged() {
        let theme = Theme(id: "warm", name: "Warm", blurb: "cozy", swatch: ["#111", "#222"],
                          cssVars: ["color-primary": "#111", "font-heading": "Georgia"])
        let vars = DesignTokenWriter.templateCSSVars(for: theme)
        #expect(vars["color-primary"] == "#111")
        #expect(vars["font-heading"] == "Georgia")
    }

    @Test func rationaleIncludesAllFiveAxesAndBothColors() {
        let config = DesignConfigGenerator.config(axes: DesignAxesCatalog.balanced, siteType: "bakery", brandColor: nil)
        let md = DesignTokenWriter.rationaleMarkdown(for: config)
        for axisName in ["Temperature", "Weight", "Register", "Time", "Voice"] {
            #expect(md.contains(axisName))
        }
        #expect(md.contains(config.palette.brand))
        #expect(md.contains(config.palette.accent))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignTokenWriterTests`
Expected: FAIL (compile error)

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/DesignTokenWriter.swift
import Foundation

public enum DesignTokenWriter {
    /// Maps a generated ``DesignConfig`` onto the 12 CSS custom-property names
    /// `Resources/Template/src/styles/global.css` already declares. Tokens the engine computes but
    /// the template has no slot for (border, shadows, the xs/sm/lg/xl spacing steps) are dropped —
    /// only `spacing.md` maps, to `--spacing-unit`.
    public static func templateCSSVars(for config: DesignConfig) -> [String: String] {
        [
            "color-primary": config.palette.brand,
            "color-accent": config.palette.accent,
            "color-background": config.palette.bg,
            "color-surface": config.palette.surface,
            "color-text": config.palette.text,
            "color-text-muted": config.palette.muted,
            "font-heading": config.typography.display,
            "font-body": config.typography.body,
            "spacing-unit": config.spacing.md,
            "radius-sm": config.shape.radiusSm,
            "radius-md": config.shape.radiusMd,
            "radius-lg": config.shape.radiusLg,
        ]
    }

    /// A built-in ``Theme``'s `cssVars` already use the template's naming scheme (parsed from
    /// `Resources/Template/scripts/themes.ts`) — pass through unchanged.
    public static func templateCSSVars(for theme: Theme) -> [String: String] { theme.cssVars }

    /// Human-readable `DESIGN.md` rationale, ported from `generateDesignRationale` in
    /// `scripts/design.ts`.
    public static func rationaleMarkdown(for config: DesignConfig) -> String {
        let axes = config.axes
        func describe(_ axis: String, _ value: Double, low: String, high: String) -> String {
            if value <= 0.4 { return low }
            if value >= 0.6 { return high }
            return "between \(low) and \(high)"
        }
        let temperature = describe("temperature", axes.temperature, low: "cool", high: "warm")
        let weight = describe("weight", axes.weight, low: "airy", high: "dense")
        let register = describe("register", axes.register, low: "playful", high: "authoritative")
        let time = describe("time", axes.time, low: "classic", high: "contemporary")
        let voice = describe("voice", axes.voice, low: "subtle", high: "bold")
        let moodWords = [temperature, weight, register, time, voice]
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

        return """
        # Your Design System

        ## What we're going for

        The feel is **\(moodWords.joined(separator: ", "))** — designed for a \(config.siteType.replacingOccurrences(of: "-", with: " ")).

        ## Design axes

        | Axis | Value | Reading |
        |------|-------|---------|
        | Temperature (cool <-> warm) | \(axes.temperature) | \(temperature) |
        | Weight (airy <-> dense) | \(axes.weight) | \(weight) |
        | Register (playful <-> authoritative) | \(axes.register) | \(register) |
        | Time (classic <-> contemporary) | \(axes.time) | \(time) |
        | Voice (subtle <-> bold) | \(axes.voice) | \(voice) |

        ## Color

        Your brand color is `\(config.palette.brand)`. The accent color `\(config.palette.accent)` provides contrast for calls to action. Text color `\(config.palette.text)` on background `\(config.palette.bg)` meets WCAG AA contrast requirements for readability.

        ## Typography

        Display font: `\(config.typography.display.split(separator: ",").first.map(String.init)?.replacingOccurrences(of: "\"", with: "") ?? config.typography.display)` — \(axes.register > 0.5 ? "conveys authority and expertise" : "feels approachable and friendly").

        Body font: `\(config.typography.body.split(separator: ",").first.map(String.init)?.replacingOccurrences(of: "\"", with: "") ?? config.typography.body)` — optimized for comfortable reading at body text sizes.
        """
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignTokenWriterTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DesignTokenWriter.swift Tests/AnglesiteCoreTests/DesignTokenWriterTests.swift
git commit -m "feat(core): map design engine output onto the template's 12 CSS vars"
```

---

### Task 6: DesignApplyService — the shared write path

**Files:**
- Create: `Sources/AnglesiteCore/DesignApplyService.swift`
- Test: `Tests/AnglesiteCoreTests/DesignApplyServiceTests.swift`

**Interfaces:**
- Consumes: nothing new — takes a plain `[String: String]` of CSS vars plus text content, so it has no dependency on `DesignConfig`/`Theme` directly (keeps it reusable from Task 9's wizard and, later, `DesignInterviewModel`).
- Produces:
```swift
public struct DesignApplyInput: Sendable {
    public let cssVars: [String: String]      // property name (no leading --) -> value
    public let rationaleMarkdown: String?      // written to docs/DESIGN.md when non-nil
    public let brandSummary: String            // one paragraph, appended to docs/brand.md
    public let sourceLabel: String             // e.g. "Built-in theme: Warm"
    public init(cssVars: [String: String], rationaleMarkdown: String?, brandSummary: String, sourceLabel: String)
}
public struct AppliedDesign: Sendable, Equatable { public let updatedVars: [String: String]; public let writtenFiles: [String] }
public enum DesignApplyError: Error, Sendable, Equatable { case missingGlobalCSS, missingRootBlock, writeFailed(String) }
public enum DesignApplyService {
    public static func apply(_ input: DesignApplyInput, to sourceDirectory: URL, fileManager: FileManager = .default) -> Result<AppliedDesign, DesignApplyError>
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/DesignApplyServiceTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct DesignApplyServiceTests {
    private func makeSite() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = dir.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        let css = """
        :root {
          --color-primary: #2563eb;
          --color-accent: #f59e0b;
          --font-heading: system-ui, -apple-system, sans-serif;
        }

        * { box-sizing: border-box; }
        """
        try css.write(to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func updatesExistingVarsInRootBlock() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: ["color-primary": "#ff0000"], rationaleMarkdown: nil,
                                     brandSummary: "A test brand.", sourceLabel: "Test")
        let result = DesignApplyService.apply(input, to: dir)
        guard case .success = result else { Issue.record("expected success"); return }
        let css = try String(contentsOf: dir.appendingPathComponent("src/styles/global.css"), encoding: .utf8)
        #expect(css.contains("--color-primary: #ff0000;"))
        #expect(css.contains("--color-accent: #f59e0b;")) // untouched var preserved
    }

    @Test func addsNewVarsNotPreviouslyInRootBlock() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: ["color-surface": "#eeeeee"], rationaleMarkdown: nil,
                                     brandSummary: "A test brand.", sourceLabel: "Test")
        _ = DesignApplyService.apply(input, to: dir)
        let css = try String(contentsOf: dir.appendingPathComponent("src/styles/global.css"), encoding: .utf8)
        #expect(css.contains("--color-surface: #eeeeee;"))
    }

    @Test func preservesEverythingOutsideRootBlock() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: ["color-primary": "#ff0000"], rationaleMarkdown: nil,
                                     brandSummary: "A test brand.", sourceLabel: "Test")
        _ = DesignApplyService.apply(input, to: dir)
        let css = try String(contentsOf: dir.appendingPathComponent("src/styles/global.css"), encoding: .utf8)
        #expect(css.contains("* { box-sizing: border-box; }"))
    }

    @Test func writesRationaleWhenProvided() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: [:], rationaleMarkdown: "# Design", brandSummary: "A test brand.", sourceLabel: "Test")
        let result = DesignApplyService.apply(input, to: dir)
        guard case .success(let applied) = result else { Issue.record("expected success"); return }
        #expect(applied.writtenFiles.contains("docs/DESIGN.md"))
        let md = try String(contentsOf: dir.appendingPathComponent("docs/DESIGN.md"), encoding: .utf8)
        #expect(md == "# Design")
    }

    @Test func skipsRationaleFileWhenNil() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: [:], rationaleMarkdown: nil, brandSummary: "A test brand.", sourceLabel: "Test")
        guard case .success(let applied) = DesignApplyService.apply(input, to: dir) else { Issue.record("expected success"); return }
        #expect(!applied.writtenFiles.contains("docs/DESIGN.md"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("docs/DESIGN.md").path))
    }

    @Test func appendsBrandSummaryToNewBrandMd() throws {
        let dir = try makeSite()
        let input = DesignApplyInput(cssVars: [:], rationaleMarkdown: nil, brandSummary: "A test brand.", sourceLabel: "Built-in theme: Warm")
        _ = DesignApplyService.apply(input, to: dir)
        let brand = try String(contentsOf: dir.appendingPathComponent("docs/brand.md"), encoding: .utf8)
        #expect(brand.contains("Built-in theme: Warm"))
        #expect(brand.contains("A test brand."))
    }

    @Test func failsWhenGlobalCSSMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = DesignApplyInput(cssVars: ["color-primary": "#fff"], rationaleMarkdown: nil, brandSummary: "x", sourceLabel: "x")
        let result = DesignApplyService.apply(input, to: dir)
        guard case .failure(.missingGlobalCSS) = result else { Issue.record("expected .missingGlobalCSS"); return }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignApplyServiceTests`
Expected: FAIL (compile error)

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/DesignApplyService.swift
import Foundation

public struct DesignApplyInput: Sendable {
    public let cssVars: [String: String]
    public let rationaleMarkdown: String?
    public let brandSummary: String
    public let sourceLabel: String

    public init(cssVars: [String: String], rationaleMarkdown: String?, brandSummary: String, sourceLabel: String) {
        self.cssVars = cssVars; self.rationaleMarkdown = rationaleMarkdown
        self.brandSummary = brandSummary; self.sourceLabel = sourceLabel
    }
}

public struct AppliedDesign: Sendable, Equatable {
    public let updatedVars: [String: String]
    public let writtenFiles: [String]
}

public enum DesignApplyError: Error, Sendable, Equatable {
    case missingGlobalCSS
    case missingRootBlock
    case writeFailed(String)
}

/// The single writer for applying a design to a site's `Source/` directory — shared by the
/// built-in/freedesignmd theme-apply wizard and (later) the design-interview conversation, so
/// there is exactly one "write design to disk" implementation.
public enum DesignApplyService {
    static let globalCSSRelativePath = "src/styles/global.css"
    static let rationaleRelativePath = "docs/DESIGN.md"
    static let brandRelativePath = "docs/brand.md"

    public static func apply(
        _ input: DesignApplyInput,
        to sourceDirectory: URL,
        fileManager: FileManager = .default
    ) -> Result<AppliedDesign, DesignApplyError> {
        let cssURL = sourceDirectory.appendingPathComponent(globalCSSRelativePath)
        guard let original = try? String(contentsOf: cssURL, encoding: .utf8) else {
            return .failure(.missingGlobalCSS)
        }
        guard let updatedCSS = upsertRootVars(input.cssVars, in: original) else {
            return .failure(.missingRootBlock)
        }

        var written: [String] = []
        do {
            try updatedCSS.write(to: cssURL, atomically: true, encoding: .utf8)
            written.append(globalCSSRelativePath)

            if let rationaleMarkdown = input.rationaleMarkdown {
                let rationaleURL = sourceDirectory.appendingPathComponent(rationaleRelativePath)
                try fileManager.createDirectory(at: rationaleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try rationaleMarkdown.write(to: rationaleURL, atomically: true, encoding: .utf8)
                written.append(rationaleRelativePath)
            }

            let brandURL = sourceDirectory.appendingPathComponent(brandRelativePath)
            try fileManager.createDirectory(at: brandURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existingBrand = (try? String(contentsOf: brandURL, encoding: .utf8)) ?? ""
            let entry = "\n## \(input.sourceLabel)\n\n\(input.brandSummary)\n"
            try (existingBrand + entry).write(to: brandURL, atomically: true, encoding: .utf8)
            written.append(brandRelativePath)
        } catch {
            return .failure(.writeFailed((error as NSError).localizedDescription))
        }

        return .success(AppliedDesign(updatedVars: input.cssVars, writtenFiles: written))
    }

    /// Replaces or appends `--<key>: <value>;` lines inside the first `:root { ... }` block,
    /// leaving everything else in the file untouched. Returns `nil` if no `:root` block is found.
    static func upsertRootVars(_ vars: [String: String], in css: String) -> String? {
        guard let rootRange = css.range(of: ":root"),
              let openBrace = css.range(of: "{", range: rootRange.upperBound..<css.endIndex),
              let closeBrace = css.range(of: "}", range: openBrace.upperBound..<css.endIndex)
        else { return nil }

        var body = String(css[openBrace.upperBound..<closeBrace.lowerBound])
        var remaining = vars

        for key in vars.keys {
            let pattern = #"(--\#(NSRegularExpression.escapedPattern(for: key))\s*:\s*)[^;]*;"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            if let match = re.firstMatch(in: body, range: range), let matchRange = Range(match.range, in: body) {
                body.replaceSubrange(matchRange, with: "--\(key): \(vars[key]!);")
                remaining.removeValue(forKey: key)
            }
        }

        if !remaining.isEmpty {
            let additions = remaining.sorted(by: { $0.key < $1.key })
                .map { "  --\($0.key): \($0.value);" }.joined(separator: "\n")
            if !body.hasSuffix("\n") { body += "\n" }
            body += additions + "\n"
        }

        return String(css[css.startIndex..<openBrace.upperBound]) + body + String(css[closeBrace.lowerBound...])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignApplyServiceTests`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DesignApplyService.swift Tests/AnglesiteCoreTests/DesignApplyServiceTests.swift
git commit -m "feat(core): add DesignApplyService, the shared design write path"
```

---

### Task 7: `AnglesitePackage` convenience for DesignApplyService

**Files:**
- Modify: `Sources/AnglesiteCore/DesignApplyService.swift`
- Test: `Tests/AnglesiteCoreTests/DesignApplyServiceTests.swift`

**Interfaces:**
- Consumes: `AnglesitePackage.sourceDirectory` (existing, from `AnglesiteSiteModel`, re-exported by `AnglesiteCore` per CLAUDE.md).
- Produces: `extension DesignApplyService { static func apply(_ input: DesignApplyInput, to package: AnglesitePackage, fileManager: FileManager = .default) -> Result<AppliedDesign, DesignApplyError> }`

- [ ] **Step 1: Write the failing test**

```swift
// Appended to Tests/AnglesiteCoreTests/DesignApplyServiceTests.swift
extension DesignApplyServiceTests {
    @Test func packageOverloadDelegatesToSourceDirectory() throws {
        let dir = try makeSite()
        // AnglesitePackage(sourceDirectory:) is the existing test-friendly initializer used
        // elsewhere in AnglesiteCoreTests (see AnglesiteSiteModelTests) — wraps a bare directory
        // without requiring a full .anglesite package on disk.
        let package = AnglesitePackage(sourceDirectory: dir)
        let input = DesignApplyInput(cssVars: ["color-primary": "#ff0000"], rationaleMarkdown: nil,
                                     brandSummary: "x", sourceLabel: "x")
        let result = DesignApplyService.apply(input, to: package)
        guard case .success = result else { Issue.record("expected success"); return }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignApplyServiceTests/packageOverloadDelegatesToSourceDirectory`
Expected: FAIL (compile error — no such overload)

- [ ] **Step 3: Implement**

```swift
// Appended to Sources/AnglesiteCore/DesignApplyService.swift
public extension DesignApplyService {
    static func apply(
        _ input: DesignApplyInput,
        to package: AnglesitePackage,
        fileManager: FileManager = .default
    ) -> Result<AppliedDesign, DesignApplyError> {
        apply(input, to: package.sourceDirectory, fileManager: fileManager)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter DesignApplyServiceTests`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/DesignApplyService.swift Tests/AnglesiteCoreTests/DesignApplyServiceTests.swift
git commit -m "feat(core): add AnglesitePackage overload for DesignApplyService.apply"
```

---

### Task 8: freedesignmd catalog fetch + parse + deterministic pre-filter

**Files:**
- Create: `Sources/AnglesiteCore/FreedesignmdCatalog.swift`
- Test: `Tests/AnglesiteCoreTests/FreedesignmdCatalogTests.swift`

**Interfaces:**
- Consumes: nothing from prior tasks.
- Produces:
```swift
public struct FreedesignmdSystem: Sendable, Equatable, Identifiable { public let slug: String; public let name: String; public var id: String { slug } }
public struct FreedesignmdSystemDetail: Sendable, Equatable { public let system: FreedesignmdSystem; public let description: String }
public enum FreedesignmdCatalogError: Error, Sendable, Equatable { case fetchFailed(String), parseFailed }
public enum FreedesignmdCatalog {
    public static func parseSystemList(html: String) -> [FreedesignmdSystem]
    public static func parseDescription(html: String) -> String?
    public static func fetchSystemList(session: URLSession = .shared) async throws -> [FreedesignmdSystem]
    public static func fetchDescription(slug: String, session: URLSession = .shared) async throws -> String?
    public static func rank(_ systems: [FreedesignmdSystem], byKeywordsIn businessType: String) -> [FreedesignmdSystem]
}
```

**Verified real structure** (fetched 2026-07-10 from `https://freedesignmd.com/systems`): the page embeds a JSON-LD `<script type="application/ld+json">` block containing `"@type":"ItemList"` with `itemListElement` entries shaped `{"@type":"ListItem","position":N,"url":"https://freedesignmd.com/system/<slug>","name":"<Display Name>"}`. Individual system pages (`https://freedesignmd.com/system/<slug>`) carry a standard `<meta name="description" content="...">` tag with a one-line description. Both are parsed with a tolerant regex, following the existing pattern in `ThemeCatalog.parse(themesTS:)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/FreedesignmdCatalogTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct FreedesignmdCatalogTests {
    private let sampleListHTML = """
    <script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"BreadcrumbList"},{"@type":"CollectionPage","mainEntity":{"@type":"ItemList","numberOfItems":3,"itemListElement":[{"@type":"ListItem","position":1,"url":"https://freedesignmd.com/system/linear-orbit","name":"Linear Orbit"},{"@type":"ListItem","position":2,"url":"https://freedesignmd.com/system/devshell-mono","name":"Devshell Mono"},{"@type":"ListItem","position":3,"url":"https://freedesignmd.com/system/vinyl-noir","name":"Vinyl Noir"}]}}]}</script>
    """

    private let sampleDetailHTML = """
    <meta name="description" content="Hairline-thin product workspace. Cool off-white surfaces, Inter Display with tight tracking."/>
    """

    @Test func parsesAllListItems() {
        let systems = FreedesignmdCatalog.parseSystemList(html: sampleListHTML)
        #expect(systems.count == 3)
        #expect(systems[0] == FreedesignmdSystem(slug: "linear-orbit", name: "Linear Orbit"))
        #expect(systems[2] == FreedesignmdSystem(slug: "vinyl-noir", name: "Vinyl Noir"))
    }

    @Test func parseSystemListReturnsEmptyForUnrecognizedHTML() {
        #expect(FreedesignmdCatalog.parseSystemList(html: "<html><body>nothing here</body></html>").isEmpty)
    }

    @Test func parsesDescriptionMetaTag() {
        let description = FreedesignmdCatalog.parseDescription(html: sampleDetailHTML)
        #expect(description == "Hairline-thin product workspace. Cool off-white surfaces, Inter Display with tight tracking.")
    }

    @Test func parseDescriptionReturnsNilWhenAbsent() {
        #expect(FreedesignmdCatalog.parseDescription(html: "<html></html>") == nil)
    }

    @Test func rankPrioritizesNameSubstringMatches() {
        let systems = FreedesignmdCatalog.parseSystemList(html: sampleListHTML)
        let ranked = FreedesignmdCatalog.rank(systems, byKeywordsIn: "mono developer tools")
        #expect(ranked.first == FreedesignmdSystem(slug: "devshell-mono", name: "Devshell Mono"))
    }

    @Test func rankFallsBackToOriginalOrderWithNoMatches() {
        let systems = FreedesignmdCatalog.parseSystemList(html: sampleListHTML)
        let ranked = FreedesignmdCatalog.rank(systems, byKeywordsIn: "")
        #expect(ranked == systems)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FreedesignmdCatalogTests`
Expected: FAIL (compile error)

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/FreedesignmdCatalog.swift
import Foundation

public struct FreedesignmdSystem: Sendable, Equatable, Identifiable {
    public let slug: String
    public let name: String
    public var id: String { slug }
    public init(slug: String, name: String) { self.slug = slug; self.name = name }
}

public struct FreedesignmdSystemDetail: Sendable, Equatable {
    public let system: FreedesignmdSystem
    public let description: String
    public init(system: FreedesignmdSystem, description: String) { self.system = system; self.description = description }
}

public enum FreedesignmdCatalogError: Error, Sendable, Equatable {
    case fetchFailed(String)
    case parseFailed
}

/// Browses the freedesignmd.com catalog deterministically. The catalog page has no JSON API, but
/// server-renders a JSON-LD `ItemList` with every system's slug/name — this parses that block
/// directly rather than doing LLM-mediated page extraction (unlike the plugin's WebFetch-based
/// `freedesignmd` skill), following `ThemeCatalog.parse(themesTS:)`'s tolerant-regex pattern.
public enum FreedesignmdCatalog {
    static let systemsURL = URL(string: "https://freedesignmd.com/systems")!
    static func systemURL(slug: String) -> URL { URL(string: "https://freedesignmd.com/system/\(slug)")! }

    private static let listItemPattern = #""url":"https://freedesignmd\.com/system/([a-z0-9-]+)","name":"([^"]+)""#
    private static let descriptionPattern = #"name="description" content="([^"]*)""#

    public static func parseSystemList(html: String) -> [FreedesignmdSystem] {
        guard let re = try? NSRegularExpression(pattern: listItemPattern) else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            FreedesignmdSystem(slug: ns.substring(with: $0.range(at: 1)), name: ns.substring(with: $0.range(at: 2)))
        }
    }

    public static func parseDescription(html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: descriptionPattern) else { return nil }
        let ns = html as NSString
        guard let match = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    public static func fetchSystemList(session: URLSession = .shared) async throws -> [FreedesignmdSystem] {
        let (data, response) = try await session.data(from: systemsURL)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let html = String(data: data, encoding: .utf8)
        else { throw FreedesignmdCatalogError.fetchFailed("bad response from \(systemsURL)") }
        let systems = parseSystemList(html: html)
        guard !systems.isEmpty else { throw FreedesignmdCatalogError.parseFailed }
        return systems
    }

    public static func fetchDescription(slug: String, session: URLSession = .shared) async throws -> String? {
        let (data, response) = try await session.data(from: systemURL(slug: slug))
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let html = String(data: data, encoding: .utf8)
        else { throw FreedesignmdCatalogError.fetchFailed("bad response for \(slug)") }
        return parseDescription(html: html)
    }

    /// Deterministic pre-filter: scores each system by how many whitespace-separated keywords from
    /// `businessType` appear as a substring of its name (case-insensitive), descending. Ties keep
    /// original catalog order (Swift's `sorted` is stable). Falls back to the original order when
    /// `businessType` is empty or nothing matches.
    public static func rank(_ systems: [FreedesignmdSystem], byKeywordsIn businessType: String) -> [FreedesignmdSystem] {
        let keywords = businessType.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !keywords.isEmpty else { return systems }
        func score(_ system: FreedesignmdSystem) -> Int {
            let name = system.name.lowercased()
            return keywords.reduce(0) { $0 + (name.contains($1) ? 1 : 0) }
        }
        return systems.enumerated()
            .sorted { a, b in
                let (sa, sb) = (score(a.element), score(b.element))
                return sa == sb ? a.offset < b.offset : sa > sb
            }
            .map(\.element)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FreedesignmdCatalogTests`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/FreedesignmdCatalog.swift Tests/AnglesiteCoreTests/FreedesignmdCatalogTests.swift
git commit -m "feat(core): add deterministic freedesignmd catalog fetch/parse/rank"
```

---

### Task 9: ThemeApplyWizardModel

**Files:**
- Create: `Sources/AnglesiteCore/ThemeApplyWizardModel.swift`
- Test: `Tests/AnglesiteCoreTests/ThemeApplyWizardModelTests.swift`

**Interfaces:**
- Consumes: `ThemeCatalog`/`Theme` (existing), `FreedesignmdCatalog` (Task 8), `DesignApplyService`/`DesignApplyInput`/`AppliedDesign`/`DesignApplyError` (Tasks 6-7), `DesignTokenWriter.templateCSSVars(for:)` (Task 5).
- Produces:
```swift
@MainActor @Observable
public final class ThemeApplyWizardModel: Identifiable {
    public enum Step: Int, CaseIterable { case pickSource, pickBuiltIn, browseFreedesignmd, review, applying }
    public enum Source: Equatable { case builtIn, freedesignmd }
    public let id = UUID()
    public var step: Step = .pickSource
    public var source: Source?
    public var selectedBuiltInID: String?
    public var freedesignmdCandidates: [FreedesignmdSystem] = []
    public var selectedFreedesignmdSlug: String?
    public var businessType: String
    public internal(set) var applyResult: Result<AppliedDesign, DesignApplyError>?
    public init(catalog: ThemeCatalog, businessType: String, package: AnglesitePackage)
    public var canContinue: Bool { get }
    public func advance() async
    public func back()
    public func apply() async
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/ThemeApplyWizardModelTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ThemeApplyWizardModelTests {
    private func makeSite() throws -> AnglesitePackage {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stylesDir = dir.appendingPathComponent("src/styles")
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)
        try ":root {\n  --color-primary: #000000;\n}\n".write(
            to: stylesDir.appendingPathComponent("global.css"), atomically: true, encoding: .utf8)
        return AnglesitePackage(sourceDirectory: dir)
    }

    private var testCatalog: ThemeCatalog {
        ThemeCatalog(themes: [Theme(id: "warm", name: "Warm", blurb: "cozy", swatch: ["#a11", "#a22"],
                                    cssVars: ["color-primary": "#a11111", "color-accent": "#a22222"])])
    }

    @Test @MainActor func picksBuiltInFlowAndApplies() async throws {
        let package = try makeSite()
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery", package: package)
        model.source = .builtIn
        await model.advance() // pickSource -> pickBuiltIn
        #expect(model.step == .pickBuiltIn)
        model.selectedBuiltInID = "warm"
        await model.advance() // pickBuiltIn -> review
        #expect(model.step == .review)
        #expect(model.canContinue)
        await model.apply()
        #expect(model.step == .applying)
        guard case .success(let applied) = model.applyResult else { Issue.record("expected success"); return }
        #expect(applied.updatedVars["color-primary"] == "#a11111")
    }

    @Test @MainActor func canContinueRequiresSourceChoiceFirst() {
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery",
                                          package: AnglesitePackage(sourceDirectory: FileManager.default.temporaryDirectory))
        #expect(model.canContinue == false)
        model.source = .builtIn
        #expect(model.canContinue)
    }

    @Test @MainActor func canContinueRequiresBuiltInSelection() async {
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery",
                                          package: AnglesitePackage(sourceDirectory: FileManager.default.temporaryDirectory))
        model.source = .builtIn
        await model.advance()
        #expect(model.canContinue == false)
        model.selectedBuiltInID = "warm"
        #expect(model.canContinue)
    }

    @Test @MainActor func backReturnsToPickSource() async {
        let model = ThemeApplyWizardModel(catalog: testCatalog, businessType: "bakery",
                                          package: AnglesitePackage(sourceDirectory: FileManager.default.temporaryDirectory))
        model.source = .builtIn
        await model.advance()
        model.back()
        #expect(model.step == .pickSource)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ThemeApplyWizardModelTests`
Expected: FAIL (compile error)

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/ThemeApplyWizardModel.swift
import Foundation
import Observation

@MainActor @Observable
public final class ThemeApplyWizardModel: Identifiable {
    public enum Step: Int, CaseIterable { case pickSource, pickBuiltIn, browseFreedesignmd, review, applying }
    public enum Source: Equatable { case builtIn, freedesignmd }

    public let id = UUID()
    public var step: Step = .pickSource
    public var source: Source?
    public var selectedBuiltInID: String?
    public var freedesignmdCandidates: [FreedesignmdSystem] = []
    public var selectedFreedesignmdSlug: String?
    public var businessType: String
    public internal(set) var applyResult: Result<AppliedDesign, DesignApplyError>?
    public internal(set) var fetchError: String?

    private let catalog: ThemeCatalog
    private let package: AnglesitePackage

    public init(catalog: ThemeCatalog, businessType: String, package: AnglesitePackage) {
        self.catalog = catalog
        self.businessType = businessType
        self.package = package
    }

    public var selectedBuiltInTheme: Theme? {
        selectedBuiltInID.flatMap(catalog.theme(id:))
    }

    public var canContinue: Bool {
        switch step {
        case .pickSource: return source != nil
        case .pickBuiltIn: return selectedBuiltInID != nil
        case .browseFreedesignmd: return selectedFreedesignmdSlug != nil
        case .review: return true
        case .applying: return false
        }
    }

    public func advance() async {
        guard canContinue else { return }
        switch step {
        case .pickSource:
            step = source == .builtIn ? .pickBuiltIn : .browseFreedesignmd
            if source == .freedesignmd { await loadFreedesignmdCandidates() }
        case .pickBuiltIn, .browseFreedesignmd:
            step = .review
        case .review, .applying:
            break
        }
    }

    public func back() {
        switch step {
        case .pickBuiltIn, .browseFreedesignmd: step = .pickSource
        case .review: step = source == .builtIn ? .pickBuiltIn : .browseFreedesignmd
        case .pickSource, .applying: break
        }
    }

    private func loadFreedesignmdCandidates() async {
        do {
            let all = try await FreedesignmdCatalog.fetchSystemList()
            freedesignmdCandidates = Array(FreedesignmdCatalog.rank(all, byKeywordsIn: businessType).prefix(10))
        } catch {
            fetchError = "Couldn't reach freedesignmd.com — \((error as NSError).localizedDescription)"
        }
    }

    public func apply() async {
        step = .applying
        switch source {
        case .builtIn:
            guard let theme = selectedBuiltInTheme else { return }
            let input = DesignApplyInput(
                cssVars: DesignTokenWriter.templateCSSVars(for: theme),
                rationaleMarkdown: nil,
                brandSummary: theme.blurb,
                sourceLabel: "Built-in theme: \(theme.name)"
            )
            applyResult = DesignApplyService.apply(input, to: package)
        case .freedesignmd:
            guard let slug = selectedFreedesignmdSlug else { return }
            let description = (try? await FreedesignmdCatalog.fetchDescription(slug: slug)) ?? nil
            let input = DesignApplyInput(
                cssVars: [:], // token translation from a fetched DESIGN.md is out of scope here (see plan Task 8 note)
                rationaleMarkdown: nil,
                brandSummary: description ?? "Applied from freedesignmd.com/system/\(slug).",
                sourceLabel: "freedesignmd: \(slug)"
            )
            applyResult = DesignApplyService.apply(input, to: package)
        case nil:
            return
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ThemeApplyWizardModelTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ThemeApplyWizardModel.swift Tests/AnglesiteCoreTests/ThemeApplyWizardModelTests.swift
git commit -m "feat(core): add ThemeApplyWizardModel driving built-in + freedesignmd flows"
```

**Note for the implementer:** freedesignmd's per-system CSS-token translation (mapping a fetched `DESIGN.md`'s described tokens onto the template's 12 vars) is deliberately stubbed to `[:]` here — the plugin skill does this translation via LLM judgment over unstructured markdown, which this plan doesn't attempt to replicate deterministically. Flag this gap to the user before merging: freedesignmd selection currently only writes `docs/brand.md` (the description/rationale), not new CSS vars. Closing that gap is follow-up work, tracked as a fast-follow to this plan rather than silently shipped as feature-complete.

---

### Task 10: ThemeApplyWizard SwiftUI sheet

**Files:**
- Create: `Sources/AnglesiteApp/ThemeApplyWizard.swift`

**Interfaces:**
- Consumes: `ThemeApplyWizardModel` (Task 9), `ThemeCatalog`/`Theme` (existing).
- Produces: `struct ThemeApplyWizard: View { init(model: ThemeApplyWizardModel) }`

This task has no isolated unit test — SwiftUI view bodies aren't unit-testable, and hosted UI tests can't run on CI (per Global Constraints / project memory). It's covered by the manual GUI smoke pass noted in the design spec. Mirror `IntegrationWizard.swift`'s structure (a `switch model.step` producing per-step content, Back/Continue buttons wired to `model.back()`/`model.advance()`, a final `.applying` step showing a progress spinner then the result).

- [ ] **Step 1: Implement**

```swift
// Sources/AnglesiteApp/ThemeApplyWizard.swift
import SwiftUI
import AnglesiteCore

struct ThemeApplyWizard: View {
    @Bindable var model: ThemeApplyWizardModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apply a Theme")
                .font(.title2.bold())

            Group {
                switch model.step {
                case .pickSource: pickSourceStep
                case .pickBuiltIn: pickBuiltInStep
                case .browseFreedesignmd: browseFreedesignmdStep
                case .review: reviewStep
                case .applying: applyingStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if model.step != .pickSource, model.step != .applying {
                    Button("Back") { model.back() }
                }
                Spacer()
                if model.step == .review {
                    Button("Apply") { Task { await model.apply() } }
                        .buttonStyle(.borderedProminent)
                } else if model.step != .applying {
                    Button("Continue") { Task { await model.advance() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canContinue)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 360)
    }

    private var pickSourceStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Source", selection: Binding(get: { model.source }, set: { model.source = $0 })) {
                Text("Built-in themes").tag(ThemeApplyWizardModel.Source?.some(.builtIn))
                Text("Browse freedesignmd.com").tag(ThemeApplyWizardModel.Source?.some(.freedesignmd))
            }
            .pickerStyle(.radioGroup)
        }
    }

    private var pickBuiltInStep: some View {
        List(model.selectedBuiltInID.map { _ in [] } ?? [], id: \.self) { (_: String) in EmptyView() }
            .overlay { EmptyView() } // placeholder overlay removed below by real catalog binding
    }

    private var browseFreedesignmdStep: some View {
        Group {
            if let error = model.fetchError {
                Text(error).foregroundStyle(.secondary)
            } else if model.freedesignmdCandidates.isEmpty {
                ProgressView("Searching freedesignmd.com…")
            } else {
                List(model.freedesignmdCandidates, selection: Binding(
                    get: { model.selectedFreedesignmdSlug },
                    set: { model.selectedFreedesignmdSlug = $0 }
                )) { system in
                    Text(system.name).tag(system.slug)
                }
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.source {
            case .builtIn:
                if let theme = model.selectedBuiltInTheme {
                    Text(theme.name).font(.headline)
                    Text(theme.blurb).foregroundStyle(.secondary)
                }
            case .freedesignmd:
                if let slug = model.selectedFreedesignmdSlug {
                    Text(slug).font(.headline)
                }
            case nil: EmptyView()
            }
        }
    }

    private var applyingStep: some View {
        VStack(spacing: 12) {
            switch model.applyResult {
            case .none:
                ProgressView("Applying…")
            case .success:
                Label("Theme applied.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Done") { dismiss() }
            case .failure(let error):
                Label("Couldn't apply that theme: \(String(describing: error))", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}
```

**Note for the implementer:** `pickBuiltInStep` above is intentionally left as a minimal placeholder pending a small follow-up: it needs a `ThemeCatalog` instance threaded into the view (not currently exposed by the model) to render the actual 9-theme picker grid. Before merging, either add a `catalog` property to `ThemeApplyWizardModel` (exposing `catalog.themes` read-only) or pass `ThemeCatalog` into `ThemeApplyWizard`'s initializer directly, then replace this step with a `LazyVGrid` of theme swatches bound to `model.selectedBuiltInID`, mirroring `IntegrationWizard.swift`'s picker step. Flag this to the user rather than silently shipping the placeholder.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/ThemeApplyWizard.swift
git commit -m "feat(app): add ThemeApplyWizard SwiftUI sheet"
```

---

### Task 11: SetupThemeTool (FM chat front door)

**Files:**
- Create: `Sources/AnglesiteCore/SetupThemeTool.swift`
- Test: `Tests/AnglesiteCoreTests/SetupThemeToolTests.swift`

**Interfaces:**
- Consumes: `ThemeCatalog` (existing), `DesignApplyService`/`DesignTokenWriter` (Tasks 5-7).
- Produces: `enum SetupThemeArguments { static func reply(for result: Result<AppliedDesign, DesignApplyError>, themeName: String) -> String }`, and (gated `#if compiler(>=6.4)`) `struct SetupThemeTool: Tool, Sendable`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/SetupThemeToolTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct SetupThemeToolTests {
    @Test func replyForSuccessNamesTheTheme() {
        let applied = AppliedDesign(updatedVars: [:], writtenFiles: ["src/styles/global.css"])
        let reply = SetupThemeArguments.reply(for: .success(applied), themeName: "Warm")
        #expect(reply.contains("Warm"))
    }

    @Test func replyForFailureExplainsWhatWentWrong() {
        let reply = SetupThemeArguments.reply(for: .failure(.missingGlobalCSS), themeName: "Warm")
        #expect(!reply.isEmpty)
        #expect(reply != SetupThemeArguments.reply(for: .success(AppliedDesign(updatedVars: [:], writtenFiles: [])), themeName: "Warm"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SetupThemeToolTests`
Expected: FAIL (compile error)

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/SetupThemeTool.swift
import Foundation

/// Pure, non-gated helpers so parse/reply logic is unit-testable on CI, mirroring
/// `SetupIntegrationArguments`.
public enum SetupThemeArguments {
    public static func reply(for result: Result<AppliedDesign, DesignApplyError>, themeName: String) -> String {
        switch result {
        case .success:
            return "Applied the \(themeName) theme."
        case .failure(.missingGlobalCSS):
            return "I couldn't find this site's stylesheet, so I couldn't apply \(themeName)."
        case .failure(.missingRootBlock):
            return "This site's stylesheet doesn't have the expected structure, so I couldn't apply \(themeName)."
        case .failure(.writeFailed(let message)):
            return "Applying \(themeName) failed: \(message)."
        }
    }
}

#if compiler(>=6.4)
import FoundationModels

public struct SetupThemeTool: Tool, Sendable {
    public static let toolName = "setupTheme"
    public let name = SetupThemeTool.toolName
    public let description = "Apply one of the built-in visual themes to the current site."

    @Generable
    public struct Arguments {
        @Guide(description: "The theme id to apply, e.g. 'warm', 'classic', 'bold'.")
        public var themeID: String
    }

    private let catalog: ThemeCatalog
    private let package: AnglesitePackage
    public init(catalog: ThemeCatalog, package: AnglesitePackage) {
        self.catalog = catalog; self.package = package
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let theme = catalog.theme(id: arguments.themeID) else {
            let names = catalog.themes.map(\.name).joined(separator: ", ")
            return "I don't recognize that theme. Available themes: \(names)."
        }
        let input = DesignApplyInput(
            cssVars: DesignTokenWriter.templateCSSVars(for: theme),
            rationaleMarkdown: nil,
            brandSummary: theme.blurb,
            sourceLabel: "Built-in theme: \(theme.name)"
        )
        let result = DesignApplyService.apply(input, to: package)
        return SetupThemeArguments.reply(for: result, themeName: theme.name)
    }
}
#endif
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SetupThemeToolTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/SetupThemeTool.swift Tests/AnglesiteCoreTests/SetupThemeToolTests.swift
git commit -m "feat(core): add SetupThemeTool FM chat front door for theme apply"
```

**Note for the implementer:** wire `SetupThemeTool` into `FoundationModelAssistant.conversationTools(for:includeSpotlight:)` (`Sources/AnglesiteCore/FoundationModelAssistant.swift:389`) the same way `SetupIntegrationTool` is wired, adding a `themeApplyService`-shaped dependency (or reuse a `ThemeCatalog`/`AnglesitePackage` pair) to `FoundationModelAssistant.init` and `attachedToolNames`. Not spelled out as its own task here because it's a small, mechanical addition to an existing file — but don't skip it, or the chat front door never actually attaches.

---

### Task 12: ApplyThemeIntent (Siri/Shortcuts front door)

**Files:**
- Create: `Sources/AnglesiteIntents/ThemeIntents.swift`

**Interfaces:**
- Consumes: `ThemeCatalog`, `DesignApplyService`/`DesignTokenWriter`, `SiteEntity` (existing, same as `IntegrationIntents.swift`).

This task has no isolated unit test — `AppIntents` types aren't testable without the AppIntents runtime, matching `IntegrationIntents.swift`'s existing pattern (which relies on `confirmAndApplyForTesting()` seams tested at the `AnglesiteIntentsTests` target, not here). Follow that same seam pattern.

- [ ] **Step 1: Implement**

```swift
// Sources/AnglesiteIntents/ThemeIntents.swift
import AppIntents
import AnglesiteCore
import Foundation

public struct ApplyThemeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Apply Theme"
    public static let description = IntentDescription("Apply a built-in visual theme to a site.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Theme", description: "e.g. warm, classic, bold, elegant.") public var themeID: String
    @Dependency private var catalog: ThemeCatalog

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$themeID) theme to \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let theme = catalog.theme(id: themeID) else {
            let names = catalog.themes.map(\.name).joined(separator: ", ")
            return .result(dialog: IntentDialog(stringLiteral: "I don't recognize that theme. Available: \(names)."))
        }
        try await requestConfirmation(dialog: "Apply the \(theme.name) theme to \(site.displayName)?")
        let package = AnglesitePackage(sourceDirectory: site.sourceDirectory)
        let input = DesignApplyInput(
            cssVars: DesignTokenWriter.templateCSSVars(for: theme),
            rationaleMarkdown: nil,
            brandSummary: theme.blurb,
            sourceLabel: "Built-in theme: \(theme.name)"
        )
        let result = DesignApplyService.apply(input, to: package)
        return .result(dialog: IntentDialog(stringLiteral: SetupThemeArguments.reply(for: result, themeName: theme.name)))
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteIntents/ThemeIntents.swift
git commit -m "feat(intents): add ApplyThemeIntent for Siri/Shortcuts theme apply"
```

---

## Self-Review Notes

- **Spec coverage:** built-in wizard (Tasks 9-10), freedesignmd browse (Task 8, with the token-translation gap explicitly flagged rather than faked), GUI+Siri+chat front-door parity (Tasks 10-12), shared deterministic write path (Tasks 5-7), design-engine port from real plugin source (Tasks 1-5) — all covered. FM-assist re-ranking (design spec's optional step) is implemented as `FreedesignmdCatalog.rank` (deterministic keyword match); a true on-device FM re-rank on top of it is a small follow-up, not blocking this plan's independently-shippable deliverable (the deterministic wizard).
- **Known gaps surfaced to the implementer, not hidden:** (1) freedesignmd CSS-token translation from a fetched `DESIGN.md` (Task 9 note), (2) `pickBuiltInStep`'s theme-grid wiring (Task 10 note), (3) `SetupThemeTool` wiring into `FoundationModelAssistant` (Task 11 note). Each is a small, well-scoped addition — flagged explicitly rather than silently shipped incomplete.
- **Type consistency:** `DesignApplyInput`/`AppliedDesign`/`DesignApplyError` (Task 6) are used identically by `ThemeApplyWizardModel` (Task 9), `SetupThemeTool` (Task 11), and `ApplyThemeIntent` (Task 12) — one shared write path as the design spec required.

# Project Style Guide & AI Consistency Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Learn a site's writing/image/component/naming/SEO conventions from its existing content, feed them into `AltTextGenerator`'s on-device prompt, and ship a "Project Style Guide" inspector view where the owner can see and override what was learned.

**Architecture:** A shared, app-lifetime `ProjectConventionsEngine` actor (mirroring the existing `SiteKnowledgeIndex` pattern) maintains an in-memory `ProjectConventions` value per open site, kept fresh by the same `SiteFileWatcher`/container-boot triggers that already drive `SiteKnowledgeIndex`. A pure deterministic extractor computes most fields from file contents; a throttled on-device Foundation Models pass fills in tone/brand-term fields. Frontmatter schema is read (not inferred) via a pure-Swift text scan of `src/content.config.ts` — this is a deliberate simplification from the design doc's "Node script over the container channel" sketch (see Task 3 for why). Per-site persistence to `Config/conventions.json` lives in a small `ProjectConventionsStore` actor, following the `ChatHistoryStore` precedent, and is driven by the UI-facing `ProjectConventionsModel`, not the shared engine.

**Tech Stack:** Swift 6.4 / Xcode 27, Swift Testing (`@Suite`/`@Test`/`#expect`), `FoundationModels` gated behind `#if compiler(>=6.4)`, SwiftUI for the inspector sheet.

**Spec:** [`docs/superpowers/specs/2026-07-07-project-style-guide-ai-design.md`](../specs/2026-07-07-project-style-guide-ai-design.md)

## Global Constraints

- Toolchain is Xcode 27 / Swift 6.4 (`.enabled(if:)`/`#if compiler(>=6.4)` gates around anything touching `FoundationModels`, matching `ContentAssistant.swift`/`GenerableTypes.swift`/`AltTextGenerator.swift`).
- All new/edited test files use the **Swift Testing** framework (`import Testing`, `@Suite`, `@Test`, `#expect`) — this codebase's `AnglesiteCoreTests` target is Swift Testing, not XCTest, for these files.
- `project.yml` globs `Sources/AnglesiteCore` and `Sources/AnglesiteApp` by path, so new files need no manual Xcode project registration — but `xcodegen generate` must be re-run once after adding files, before building in Xcode (per project `CLAUDE.md`; `Anglesite.xcodeproj` is gitignored/generated).
- `swift test --package-path .` requires `DEVELOPER_DIR` pointed at the Xcode-27 beta toolchain, not the default CommandLineTools swift (see project memory `swift-toolchain-developer-dir`) — if `swift test` hangs or fails to build with no clear error, check `DEVELOPER_DIR` before anything else.
- `Config/` is app-owned, per-site, **not** git-tracked (per project `CLAUDE.md` "Site identity" section) — `ProjectConventionsStore` writes there, matching `ChatHistoryStore`.
- Deviation from the design doc: the "Frontmatter reading" section proposed a Node script (`scripts/describe-content-schema.ts`) invoked over the container/MCP channel. Task 3 instead reads `src/content.config.ts` directly in Swift with a small text scan — the template's `content.config.ts` files are consistently shaped (`const NAME = defineCollection({ ..., schema: z.object({...}).strict() })`), so a deterministic Bucket-1 text scan is simpler, more testable, and avoids a container round-trip for something that's read-only ground truth, not inference.

---

### Task 1: `ProjectConventions` data model

**Files:**
- Create: `Sources/AnglesiteCore/ProjectConventions.swift`
- Test: `Tests/AnglesiteCoreTests/ProjectConventionsTests.swift`

**Interfaces:**
- Consumes: nothing (pure data types).
- Produces: `ProjectConventions`, `Learned<Value>`, `ConventionSource`, `HeadingCapitalization`, `SlugStyle`, `WritingConventions`, `FrontmatterConventions`, `ComponentConventions`, `ImageConventions`, `NamingConventions`, `SEOConventions`, `OverridableField`, `OverrideValue`. `ProjectConventions.empty` static value. `ProjectConventions.apply(_:)`, `.clearOverride(_:)`, `.merging(overriddenFrom:)` — used by Task 2 (extractor produces a `ProjectConventions`), Task 4 (engine calls `apply`/`clearOverride`/`merging`), Task 9 (`ProjectConventionsModel` calls `apply`/`clearOverride` indirectly through the engine).

- [ ] **Step 1: Write the failing test for `Learned` and override/merge semantics**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ProjectConventions")
struct ProjectConventionsTests {
    @Test("apply(_:) sets the field's value and marks it userOverride")
    func applySetsOverride() {
        var conventions = ProjectConventions.empty
        conventions.apply(.altTextAverageLength(42))
        #expect(conventions.images.altTextAverageLength.value == 42)
        #expect(conventions.images.altTextAverageLength.isOverridden == true)
    }

    @Test("clearOverride(_:) reverts the field's source to inferred, keeping the value")
    func clearOverrideRevertsSource() {
        var conventions = ProjectConventions.empty
        conventions.apply(.altTextAverageLength(42))
        conventions.clearOverride(.altTextAverageLength)
        #expect(conventions.images.altTextAverageLength.value == 42)
        #expect(conventions.images.altTextAverageLength.isOverridden == false)
    }

    @Test("merging(overriddenFrom:) preserves only the overridden fields from the previous value")
    func mergingPreservesOverriddenFieldsOnly() {
        var previous = ProjectConventions.empty
        previous.apply(.altTextAverageLength(42))
        previous.writing.brandTerms = Learned(value: ["Anglesite"], source: .inferred(confidence: 1), sampleSize: 3)

        var fresh = ProjectConventions.empty
        fresh.images.altTextAverageLength = Learned(value: 10, source: .inferred(confidence: 1), sampleSize: 5)
        fresh.writing.brandTerms = Learned(value: ["anglesite"], source: .inferred(confidence: 1), sampleSize: 5)

        let merged = fresh.merging(overriddenFrom: previous)

        // Overridden field survives the merge untouched.
        #expect(merged.images.altTextAverageLength.value == 42)
        #expect(merged.images.altTextAverageLength.isOverridden == true)
        // Non-overridden field takes the fresh (just-recomputed) value.
        #expect(merged.writing.brandTerms.value == ["anglesite"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ProjectConventionsTests`
Expected: FAIL to compile — `ProjectConventions`, `Learned`, `OverrideValue` don't exist yet.

- [ ] **Step 3: Write the data model**

```swift
// Sources/AnglesiteCore/ProjectConventions.swift
import Foundation

/// Where a `Learned` field's current value came from.
public enum ConventionSource: Sendable, Codable, Equatable {
    case inferred(confidence: Double)
    case userOverride
}

/// One inferred-or-overridden fact about a project's conventions. Re-learning never overwrites
/// a `.userOverride` value — see `ProjectConventions.merging(overriddenFrom:)`.
public struct Learned<Value: Sendable & Codable & Equatable>: Sendable, Codable, Equatable {
    public var value: Value
    public var source: ConventionSource
    /// How many files this was inferred from, when known. `nil`/0 lets a future UI show a
    /// "low confidence" indicator instead of asserting a rule from too little evidence.
    public var sampleSize: Int?

    public init(value: Value, source: ConventionSource, sampleSize: Int? = nil) {
        self.value = value
        self.source = source
        self.sampleSize = sampleSize
    }

    public var isOverridden: Bool {
        if case .userOverride = source { return true }
        return false
    }
}

public enum HeadingCapitalization: String, Sendable, Codable, Equatable {
    case titleCase
    case sentenceCase
    case mixed
}

public enum SlugStyle: String, Sendable, Codable, Equatable {
    case kebabCase
    case snakeCase
    case mixed
}

public struct WritingConventions: Sendable, Codable, Equatable {
    public var headingCapitalization: Learned<HeadingCapitalization>
    public var toneDescriptors: Learned<[String]>
    public var brandTerms: Learned<[String]>

    public init(
        headingCapitalization: Learned<HeadingCapitalization>,
        toneDescriptors: Learned<[String]>,
        brandTerms: Learned<[String]>
    ) {
        self.headingCapitalization = headingCapitalization
        self.toneDescriptors = toneDescriptors
        self.brandTerms = brandTerms
    }
}

/// Read as ground truth from `src/content.config.ts` (Task 3) — not inferred, so no `Learned`
/// wrapper and never user-overridable. Maps collection name to its declared field names.
public struct FrontmatterConventions: Sendable, Codable, Equatable {
    public var collections: [String: [String]]

    public init(collections: [String: [String]]) {
        self.collections = collections
    }
}

public struct ComponentConventions: Sendable, Codable, Equatable {
    public var usageCounts: Learned<[String: Int]>

    public init(usageCounts: Learned<[String: Int]>) {
        self.usageCounts = usageCounts
    }
}

public struct ImageConventions: Sendable, Codable, Equatable {
    public var altTextAverageLength: Learned<Int>
    public var altTextEndsWithPunctuation: Learned<Bool>

    public init(altTextAverageLength: Learned<Int>, altTextEndsWithPunctuation: Learned<Bool>) {
        self.altTextAverageLength = altTextAverageLength
        self.altTextEndsWithPunctuation = altTextEndsWithPunctuation
    }
}

public struct NamingConventions: Sendable, Codable, Equatable {
    public var slugStyle: Learned<SlugStyle>

    public init(slugStyle: Learned<SlugStyle>) {
        self.slugStyle = slugStyle
    }
}

public struct SEOConventions: Sendable, Codable, Equatable {
    public var metaDescriptionAverageLength: Learned<Int>

    public init(metaDescriptionAverageLength: Learned<Int>) {
        self.metaDescriptionAverageLength = metaDescriptionAverageLength
    }
}

/// One site's learned/edited project conventions. See the design doc for the taxonomy and the
/// override-preserving merge invariant.
public struct ProjectConventions: Sendable, Codable, Equatable {
    public var writing: WritingConventions
    public var frontmatter: FrontmatterConventions
    public var components: ComponentConventions
    public var images: ImageConventions
    public var naming: NamingConventions
    public var seo: SEOConventions
    public var lastLearnedAt: Date?

    public init(
        writing: WritingConventions,
        frontmatter: FrontmatterConventions,
        components: ComponentConventions,
        images: ImageConventions,
        naming: NamingConventions,
        seo: SEOConventions,
        lastLearnedAt: Date?
    ) {
        self.writing = writing
        self.frontmatter = frontmatter
        self.components = components
        self.images = images
        self.naming = naming
        self.seo = seo
        self.lastLearnedAt = lastLearnedAt
    }

    /// A zero-confidence, empty starting point — what a brand-new site (or a site that hasn't
    /// been scanned yet) reports.
    public static let empty = ProjectConventions(
        writing: WritingConventions(
            headingCapitalization: Learned(value: .mixed, source: .inferred(confidence: 0), sampleSize: 0),
            toneDescriptors: Learned(value: [], source: .inferred(confidence: 0), sampleSize: 0),
            brandTerms: Learned(value: [], source: .inferred(confidence: 0), sampleSize: 0)
        ),
        frontmatter: FrontmatterConventions(collections: [:]),
        components: ComponentConventions(
            usageCounts: Learned(value: [:], source: .inferred(confidence: 0), sampleSize: 0)
        ),
        images: ImageConventions(
            altTextAverageLength: Learned(value: 0, source: .inferred(confidence: 0), sampleSize: 0),
            altTextEndsWithPunctuation: Learned(value: false, source: .inferred(confidence: 0), sampleSize: 0)
        ),
        naming: NamingConventions(
            slugStyle: Learned(value: .mixed, source: .inferred(confidence: 0), sampleSize: 0)
        ),
        seo: SEOConventions(
            metaDescriptionAverageLength: Learned(value: 0, source: .inferred(confidence: 0), sampleSize: 0)
        ),
        lastLearnedAt: nil
    )
}

/// Every field a user can override from the Style Guide inspector (Task 10). Frontmatter
/// (ground truth) and component usage counts (a count, not a preference) are intentionally
/// excluded.
public enum OverridableField: String, Sendable, Codable, CaseIterable {
    case headingCapitalization
    case toneDescriptors
    case brandTerms
    case altTextAverageLength
    case altTextEndsWithPunctuation
    case slugStyle
    case metaDescriptionAverageLength
}

/// A typed value for one `OverridableField`. The case identifies the field; the payload is
/// already the right type for it, so callers can't set a `String` onto an `Int` field.
public enum OverrideValue: Sendable, Equatable {
    case headingCapitalization(HeadingCapitalization)
    case toneDescriptors([String])
    case brandTerms([String])
    case altTextAverageLength(Int)
    case altTextEndsWithPunctuation(Bool)
    case slugStyle(SlugStyle)
    case metaDescriptionAverageLength(Int)
}

extension ProjectConventions {
    /// Sets the matching field's value and flips its `source` to `.userOverride`.
    public mutating func apply(_ value: OverrideValue) {
        switch value {
        case .headingCapitalization(let v):
            writing.headingCapitalization = Learned(value: v, source: .userOverride)
        case .toneDescriptors(let v):
            writing.toneDescriptors = Learned(value: v, source: .userOverride)
        case .brandTerms(let v):
            writing.brandTerms = Learned(value: v, source: .userOverride)
        case .altTextAverageLength(let v):
            images.altTextAverageLength = Learned(value: v, source: .userOverride)
        case .altTextEndsWithPunctuation(let v):
            images.altTextEndsWithPunctuation = Learned(value: v, source: .userOverride)
        case .slugStyle(let v):
            naming.slugStyle = Learned(value: v, source: .userOverride)
        case .metaDescriptionAverageLength(let v):
            seo.metaDescriptionAverageLength = Learned(value: v, source: .userOverride)
        }
    }

    /// Reverts one field's `source` back to `.inferred`, keeping its current value in place until
    /// the next rebuild recomputes it fresh.
    public mutating func clearOverride(_ field: OverridableField) {
        switch field {
        case .headingCapitalization:
            writing.headingCapitalization.source = .inferred(confidence: 0)
        case .toneDescriptors:
            writing.toneDescriptors.source = .inferred(confidence: 0)
        case .brandTerms:
            writing.brandTerms.source = .inferred(confidence: 0)
        case .altTextAverageLength:
            images.altTextAverageLength.source = .inferred(confidence: 0)
        case .altTextEndsWithPunctuation:
            images.altTextEndsWithPunctuation.source = .inferred(confidence: 0)
        case .slugStyle:
            naming.slugStyle.source = .inferred(confidence: 0)
        case .metaDescriptionAverageLength:
            seo.metaDescriptionAverageLength.source = .inferred(confidence: 0)
        }
    }

    /// `self` is a freshly-recomputed rebuild result. Returns a copy where every field the user
    /// had overridden in `previous` is preserved verbatim; every other field keeps `self`'s fresh
    /// value. This is the invariant that makes re-learning safe to run automatically in the
    /// background without clobbering user edits.
    public func merging(overriddenFrom previous: ProjectConventions) -> ProjectConventions {
        var merged = self
        if previous.writing.headingCapitalization.isOverridden {
            merged.writing.headingCapitalization = previous.writing.headingCapitalization
        }
        if previous.writing.toneDescriptors.isOverridden {
            merged.writing.toneDescriptors = previous.writing.toneDescriptors
        }
        if previous.writing.brandTerms.isOverridden {
            merged.writing.brandTerms = previous.writing.brandTerms
        }
        if previous.images.altTextAverageLength.isOverridden {
            merged.images.altTextAverageLength = previous.images.altTextAverageLength
        }
        if previous.images.altTextEndsWithPunctuation.isOverridden {
            merged.images.altTextEndsWithPunctuation = previous.images.altTextEndsWithPunctuation
        }
        if previous.naming.slugStyle.isOverridden {
            merged.naming.slugStyle = previous.naming.slugStyle
        }
        if previous.seo.metaDescriptionAverageLength.isOverridden {
            merged.seo.metaDescriptionAverageLength = previous.seo.metaDescriptionAverageLength
        }
        return merged
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ProjectConventionsTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ProjectConventions.swift Tests/AnglesiteCoreTests/ProjectConventionsTests.swift
git commit -m "feat: add ProjectConventions data model with override-preserving merge"
```

---

### Task 2: Deterministic convention extractor

**Files:**
- Create: `Sources/AnglesiteCore/ProjectConventionsExtractor.swift`
- Test: `Tests/AnglesiteCoreTests/ProjectConventionsExtractorTests.swift`

**Interfaces:**
- Consumes: `ProjectConventions`, `Learned`, `HeadingCapitalization`, `SlugStyle` (Task 1); `Frontmatter.parse(_:)` (existing, `Sources/AnglesiteCore/Frontmatter.swift`).
- Produces: `ProjectConventionsExtractor.ScannedFile`, `ProjectConventionsExtractor.extract(files:) -> ProjectConventions` — consumed by Task 4's `ProjectConventionsEngine.recompute`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ProjectConventionsExtractor")
struct ProjectConventionsExtractorTests {
    private func file(_ path: String, _ contents: String) -> ProjectConventionsExtractor.ScannedFile {
        .init(path: path, contents: contents)
    }

    @Test("detects title-case headings")
    func detectsTitleCase() {
        let files = [
            file("src/pages/about.astro", "# About Our Team\n"),
            file("src/pages/pricing.astro", "# Simple Pricing Plans\n"),
        ]
        let conventions = ProjectConventionsExtractor.extract(files: files)
        #expect(conventions.writing.headingCapitalization.value == .titleCase)
        #expect(conventions.writing.headingCapitalization.sampleSize == 2)
    }

    @Test("computes average alt-text length from markdown and HTML images")
    func computesAltTextStats() {
        let files = [
            file("src/content/blog/post.md", "![A red bicycle leaning on a wall.](bike.jpg)"),
            file("src/components/Hero.astro", "<img src=\"hero.jpg\" alt=\"A misty mountain range.\" />"),
        ]
        let conventions = ProjectConventionsExtractor.extract(files: files)
        #expect(conventions.images.altTextAverageLength.value > 0)
        #expect(conventions.images.altTextEndsWithPunctuation.value == true)
        #expect(conventions.images.altTextAverageLength.sampleSize == 2)
    }

    @Test("counts component usage across .astro files")
    func countsComponentUsage() {
        let files = [
            file("src/pages/index.astro", "<CTA /><CTA /><Footer />"),
        ]
        let conventions = ProjectConventionsExtractor.extract(files: files)
        #expect(conventions.components.usageCounts.value["CTA"] == 2)
        #expect(conventions.components.usageCounts.value["Footer"] == 1)
    }

    @Test("detects kebab-case content slugs")
    func detectsKebabCaseSlugs() {
        let files = [
            file("src/content/blog/welcome-to-your-blog.md", "# Welcome"),
            file("src/content/blog/our-second-post.md", "# Second post"),
        ]
        let conventions = ProjectConventionsExtractor.extract(files: files)
        #expect(conventions.naming.slugStyle.value == .kebabCase)
    }

    @Test("computes average meta description length from frontmatter")
    func computesMetaDescriptionLength() {
        let files = [
            file("src/content/blog/a.md", "---\ntitle: A\ndescription: A twelve word sentence used only to check average length here.\n---\nBody"),
        ]
        let conventions = ProjectConventionsExtractor.extract(files: files)
        #expect(conventions.seo.metaDescriptionAverageLength.value > 0)
    }

    @Test("empty input yields zero-confidence empty conventions")
    func emptyInputYieldsEmpty() {
        let conventions = ProjectConventionsExtractor.extract(files: [])
        #expect(conventions.writing.headingCapitalization.sampleSize == 0)
        #expect(conventions.images.altTextAverageLength.sampleSize == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ProjectConventionsExtractorTests`
Expected: FAIL to compile — `ProjectConventionsExtractor` doesn't exist yet.

- [ ] **Step 3: Write the extractor**

```swift
// Sources/AnglesiteCore/ProjectConventionsExtractor.swift
import Foundation

/// Pure, deterministic statistics over a project's file contents (Bucket 1 — no model calls).
/// Each `*Convention` function is independently testable against fixture strings; `extract(files:)`
/// composes them into one `ProjectConventions` value. Tone/brand-term fields are left at their
/// `.empty` zero-confidence default here — those come from the throttled FM enrichment pass
/// added in Task 5.
public enum ProjectConventionsExtractor {
    public struct ScannedFile: Sendable {
        public let path: String
        public let contents: String

        public init(path: String, contents: String) {
            self.path = path
            self.contents = contents
        }
    }

    public static func extract(files: [ScannedFile]) -> ProjectConventions {
        var conventions = ProjectConventions.empty
        conventions.writing.headingCapitalization = headingCapitalizationConvention(files: files)
        conventions.images.altTextAverageLength = altTextAverageLengthConvention(files: files)
        conventions.images.altTextEndsWithPunctuation = altTextEndsWithPunctuationConvention(files: files)
        conventions.components.usageCounts = componentUsageCountsConvention(files: files)
        conventions.naming.slugStyle = slugStyleConvention(files: files)
        conventions.seo.metaDescriptionAverageLength = metaDescriptionAverageLengthConvention(files: files)
        return conventions
    }

    // MARK: Heading capitalization

    private static let headingPattern = try! NSRegularExpression(
        pattern: "^#{1,6}\\s+(.+)$", options: [.anchorsMatchLines]
    )
    private static let stopwords: Set<String> = ["a", "an", "and", "the", "of", "to", "for", "in", "on", "with", "or"]

    static func headingCapitalizationConvention(files: [ScannedFile]) -> Learned<HeadingCapitalization> {
        var titleCaseCount = 0
        var sentenceCaseCount = 0
        var total = 0
        for file in files {
            for heading in headings(in: file.contents) {
                total += 1
                if isTitleCase(heading) { titleCaseCount += 1 }
                else if isSentenceCase(heading) { sentenceCaseCount += 1 }
            }
        }
        guard total > 0 else {
            return Learned(value: .mixed, source: .inferred(confidence: 0), sampleSize: 0)
        }
        let confidence = Double(max(titleCaseCount, sentenceCaseCount)) / Double(total)
        let style: HeadingCapitalization = confidence >= 0.7
            ? (titleCaseCount >= sentenceCaseCount ? .titleCase : .sentenceCase)
            : .mixed
        return Learned(value: style, source: .inferred(confidence: confidence), sampleSize: total)
    }

    private static func headings(in source: String) -> [String] {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return headingPattern.matches(in: source, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[r]).trimmingCharacters(in: .whitespaces)
        }
    }

    private static func isTitleCase(_ heading: String) -> Bool {
        let words = heading.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        return words.allSatisfy { word in
            if stopwords.contains(word.lowercased()) { return true }
            guard let first = word.first else { return false }
            return first.isUppercase
        }
    }

    /// Sentence case: first word capitalized, and at least one later word starts lowercase (which
    /// rules out title case). This is a heuristic, not a grammar check — good enough to bucket a
    /// site's dominant style, not to grade any single heading.
    private static func isSentenceCase(_ heading: String) -> Bool {
        let words = heading.split(separator: " ").map(String.init)
        guard let firstChar = words.first?.first, firstChar.isUppercase else { return false }
        guard words.count > 1 else { return true }
        return words.dropFirst().contains { word in
            guard let c = word.first else { return false }
            return c.isLowercase
        }
    }

    // MARK: Alt text

    private static let markdownImagePattern = try! NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\([^)]*\\)")
    private static let htmlAltPattern = try! NSRegularExpression(pattern: "alt=\"([^\"]*)\"")

    static func altTextAverageLengthConvention(files: [ScannedFile]) -> Learned<Int> {
        let values = altTexts(files: files).filter { !$0.isEmpty }
        guard !values.isEmpty else {
            return Learned(value: 0, source: .inferred(confidence: 0), sampleSize: 0)
        }
        let average = values.reduce(0) { $0 + $1.count } / values.count
        return Learned(value: average, source: .inferred(confidence: 1), sampleSize: values.count)
    }

    static func altTextEndsWithPunctuationConvention(files: [ScannedFile]) -> Learned<Bool> {
        let values = altTexts(files: files).filter { !$0.isEmpty }
        guard !values.isEmpty else {
            return Learned(value: false, source: .inferred(confidence: 0), sampleSize: 0)
        }
        let punctuation: Set<Character> = [".", "!", "?"]
        let endingCount = values.filter { punctuation.contains($0.last ?? " ") }.count
        let confidence = Double(endingCount) / Double(values.count)
        return Learned(value: confidence >= 0.5, source: .inferred(confidence: confidence), sampleSize: values.count)
    }

    private static func altTexts(files: [ScannedFile]) -> [String] {
        files.flatMap { file -> [String] in
            let range = NSRange(file.contents.startIndex..<file.contents.endIndex, in: file.contents)
            let markdown = markdownImagePattern.matches(in: file.contents, range: range).compactMap { match -> String? in
                guard let r = Range(match.range(at: 1), in: file.contents) else { return nil }
                return String(file.contents[r])
            }
            let html = htmlAltPattern.matches(in: file.contents, range: range).compactMap { match -> String? in
                guard let r = Range(match.range(at: 1), in: file.contents) else { return nil }
                return String(file.contents[r])
            }
            return markdown + html
        }
    }

    // MARK: Component usage

    private static let componentTagPattern = try! NSRegularExpression(pattern: "<([A-Z][A-Za-z0-9]*)\\b")

    static func componentUsageCountsConvention(files: [ScannedFile]) -> Learned<[String: Int]> {
        var counts: [String: Int] = [:]
        var total = 0
        for file in files where file.path.hasSuffix(".astro") {
            let range = NSRange(file.contents.startIndex..<file.contents.endIndex, in: file.contents)
            for match in componentTagPattern.matches(in: file.contents, range: range) {
                guard let r = Range(match.range(at: 1), in: file.contents) else { continue }
                counts[String(file.contents[r]), default: 0] += 1
                total += 1
            }
        }
        guard total > 0 else {
            return Learned(value: [:], source: .inferred(confidence: 0), sampleSize: 0)
        }
        return Learned(value: counts, source: .inferred(confidence: 1), sampleSize: total)
    }

    // MARK: Naming

    static func slugStyleConvention(files: [ScannedFile]) -> Learned<SlugStyle> {
        let slugs = files
            .filter { $0.path.hasPrefix("src/content/") || $0.path.hasPrefix("src/pages/") }
            .map { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent }
            .filter { $0 != "index" }
        guard !slugs.isEmpty else {
            return Learned(value: .mixed, source: .inferred(confidence: 0), sampleSize: 0)
        }
        let kebabCount = slugs.filter(isKebabCase).count
        let snakeCount = slugs.filter(isSnakeCase).count
        let confidence = Double(max(kebabCount, snakeCount)) / Double(slugs.count)
        let style: SlugStyle = confidence >= 0.7
            ? (kebabCount >= snakeCount ? .kebabCase : .snakeCase)
            : .mixed
        return Learned(value: style, source: .inferred(confidence: confidence), sampleSize: slugs.count)
    }

    private static func isKebabCase(_ s: String) -> Bool {
        !s.isEmpty && !s.contains("_") && s.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }

    private static func isSnakeCase(_ s: String) -> Bool {
        !s.isEmpty && !s.contains("-") && s.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
    }

    // MARK: SEO

    static func metaDescriptionAverageLengthConvention(files: [ScannedFile]) -> Learned<Int> {
        let lengths = files.compactMap { file -> Int? in
            guard case .string(let description)? = Frontmatter.parse(file.contents)["description"],
                  !description.isEmpty
            else { return nil }
            return description.count
        }
        guard !lengths.isEmpty else {
            return Learned(value: 0, source: .inferred(confidence: 0), sampleSize: 0)
        }
        let average = lengths.reduce(0, +) / lengths.count
        return Learned(value: average, source: .inferred(confidence: 1), sampleSize: lengths.count)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ProjectConventionsExtractorTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ProjectConventionsExtractor.swift Tests/AnglesiteCoreTests/ProjectConventionsExtractorTests.swift
git commit -m "feat: add deterministic project-conventions extractor"
```

---

### Task 3: Frontmatter schema reader

**Files:**
- Create: `Sources/AnglesiteCore/FrontmatterSchemaReader.swift`
- Test: `Tests/AnglesiteCoreTests/FrontmatterSchemaReaderTests.swift`

**Interfaces:**
- Consumes: nothing new (pure `String` in, `[String: [String]]` out).
- Produces: `FrontmatterSchemaReader.collections(fromContentConfig:) -> [String: [String]]`, `FrontmatterSchemaReader.read(siteDirectory:) -> [String: [String]]` — consumed by Task 4's `ProjectConventionsEngine.rebuild`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("FrontmatterSchemaReader")
struct FrontmatterSchemaReaderTests {
    @Test("extracts collection names and field names from a content.config.ts-shaped source")
    func extractsCollectionsAndFields() {
        let source = """
        import { defineCollection } from "astro:content";
        import { glob } from "astro/loaders";
        import { z } from "astro/zod";

        const blog = defineCollection({
          loader: glob({ pattern: "**/*.md", base: "./src/content/blog" }),
          schema: z.object({
            title: z.string(),
            pubDate: z.coerce.date(),
            description: z.string().optional(),
            draft: z.boolean().default(false),
          }).strict(),
        });

        const events = defineCollection({
          loader: glob({ pattern: "**/*.md", base: "./src/content/events" }),
          schema: z.object({
            name: z.string(),
            start: z.coerce.date(),
          }).strict(),
        });

        export const collections = { blog, events };
        """

        let collections = FrontmatterSchemaReader.collections(fromContentConfig: source)

        #expect(collections["blog"] == ["title", "pubDate", "description", "draft"])
        #expect(collections["events"] == ["name", "start"])
    }

    @Test("returns an empty map for unrecognized shapes rather than guessing")
    func returnsEmptyForUnrecognizedShape() {
        let collections = FrontmatterSchemaReader.collections(fromContentConfig: "export const collections = {};")
        #expect(collections.isEmpty)
    }

    @Test("read(siteDirectory:) returns empty when content.config.ts is missing")
    func readReturnsEmptyWhenFileMissing() {
        let missingRoot = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)", isDirectory: true)
        #expect(FrontmatterSchemaReader.read(siteDirectory: missingRoot).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FrontmatterSchemaReaderTests`
Expected: FAIL to compile — `FrontmatterSchemaReader` doesn't exist yet.

- [ ] **Step 3: Write the reader**

```swift
// Sources/AnglesiteCore/FrontmatterSchemaReader.swift
import Foundation

/// Reads `src/content.config.ts` as ground truth for each content collection's declared field
/// names — this is NOT inference (see `ProjectConventionsExtractor` for the inferred fields).
///
/// This is a lightweight text scan, not a TypeScript/Zod parser: it recognizes the site
/// template's consistent shape (`const NAME = defineCollection({ ..., schema: z.object({...}) })`
/// — see `Resources/Template/src/content.config.ts`) and extracts top-level `key: z....` field
/// names inside the `z.object({...})` block. Anything it doesn't recognize is left out rather
/// than guessed, matching `Frontmatter.parse`'s "deliberately minimal" precedent.
public enum FrontmatterSchemaReader {
    public static func read(siteDirectory: URL) -> [String: [String]] {
        let url = siteDirectory.appendingPathComponent("src/content.config.ts")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return collections(fromContentConfig: source)
    }

    public static func collections(fromContentConfig source: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for block in collectionBlocks(in: source) {
            result[block.name] = fieldNames(in: block.schemaBody)
        }
        return result
    }

    // MARK: - Parsing

    private struct CollectionBlock {
        let name: String
        let schemaBody: String
    }

    private static let declarationPattern = try! NSRegularExpression(
        pattern: "const\\s+(\\w+)\\s*=\\s*defineCollection\\("
    )
    private static let fieldPattern = try! NSRegularExpression(pattern: "(\\w+):\\s*z\\.")

    private static func collectionBlocks(in source: String) -> [CollectionBlock] {
        var blocks: [CollectionBlock] = []
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in declarationPattern.matches(in: source, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let fullRange = Range(match.range, in: source)
            else { continue }
            let name = String(source[nameRange])
            // `fullRange.upperBound` sits right after the "defineCollection(" we just matched —
            // step back one character to land ON that opening paren.
            let openParenIndex = source.index(before: fullRange.upperBound)
            guard let body = balancedSubstring(in: source, openIndex: openParenIndex, open: "(", close: ")"),
                  let schemaKeywordRange = body.range(of: "z.object(")
            else { continue }
            let schemaOpenIndex = body.index(before: schemaKeywordRange.upperBound)
            guard let schemaBody = balancedSubstring(in: body, openIndex: schemaOpenIndex, open: "(", close: ")")
            else { continue }
            blocks.append(CollectionBlock(name: name, schemaBody: schemaBody))
        }
        return blocks
    }

    private static func fieldNames(in schemaBody: String) -> [String] {
        let range = NSRange(schemaBody.startIndex..<schemaBody.endIndex, in: schemaBody)
        return fieldPattern.matches(in: schemaBody, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: schemaBody) else { return nil }
            return String(schemaBody[r])
        }
    }

    /// Starting at `openIndex` (which must be the `open` character), returns the substring
    /// strictly between the matching `open`/`close` pair, honoring nesting. `nil` if the pair
    /// never balances before the string ends.
    private static func balancedSubstring(
        in source: String, openIndex: String.Index, open: Character, close: Character
    ) -> String? {
        guard source[openIndex] == open else { return nil }
        var depth = 0
        var index = openIndex
        let contentStart = source.index(after: openIndex)
        while index < source.endIndex {
            let c = source[index]
            if c == open { depth += 1 }
            else if c == close {
                depth -= 1
                if depth == 0 { return String(source[contentStart..<index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter FrontmatterSchemaReaderTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/FrontmatterSchemaReader.swift Tests/AnglesiteCoreTests/FrontmatterSchemaReaderTests.swift
git commit -m "feat: add pure-Swift content.config.ts schema reader"
```

---

### Task 4: `ProjectConventionsEngine` actor (in-memory)

**Files:**
- Create: `Sources/AnglesiteCore/ProjectConventionsEngine.swift`
- Test: `Tests/AnglesiteCoreTests/ProjectConventionsEngineTests.swift`

**Interfaces:**
- Consumes: `ProjectConventionsExtractor.extract(files:)` (Task 2), `FrontmatterSchemaReader.read(siteDirectory:)` (Task 3), `SiteIndexPaths.isSkipped(relativePath:)`/`.skippedDirectoryNames` (existing, `Sources/AnglesiteCore/SiteFileWatcher.swift`), `ProjectConventions.merging(overriddenFrom:)`/`.apply(_:)`/`.clearOverride(_:)` (Task 1).
- Produces: `ProjectConventionsEngine` actor with `rebuild(siteID:projectRoot:)`, `upsertFile(siteID:projectRoot:relativePath:)`, `removeFile(siteID:relativePath:)`, `unload(siteID:)`, `conventions(siteID:) -> ProjectConventions?`, `seed(siteID:with:)`, `applyOverride(siteID:value:)`, `clearOverride(siteID:field:)` — consumed by Task 6 (runtime wiring), Task 8 (alt-text consumption), Task 9 (`ProjectConventionsModel`).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ProjectConventionsEngine")
struct ProjectConventionsEngineTests {
    private func makeSite(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conventions-engine-\(UUID().uuidString)", isDirectory: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test("rebuild scans matching files and skips build artifacts")
    func rebuildScansFiles() async {
        let root = makeSite([
            "src/pages/about.astro": "# About Us\n",
            "node_modules/pkg/index.js": "<ShouldNotCount />",
        ])
        let engine = ProjectConventionsEngine()

        await engine.rebuild(siteID: "site-1", projectRoot: root)

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.writing.headingCapitalization.sampleSize == 1)
    }

    @Test("upsertFile incorporates a single changed file without a full rescan")
    func upsertFileIncorporatesChange() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let engine = ProjectConventionsEngine()
        await engine.rebuild(siteID: "site-1", projectRoot: root)

        let newFile = root.appendingPathComponent("src/pages/pricing.astro")
        try! Data("# Our Pricing\n".utf8).write(to: newFile)
        await engine.upsertFile(siteID: "site-1", projectRoot: root, relativePath: "src/pages/pricing.astro")

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.writing.headingCapitalization.sampleSize == 2)
    }

    @Test("removeFile drops a file's contribution")
    func removeFileDropsContribution() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let engine = ProjectConventionsEngine()
        await engine.rebuild(siteID: "site-1", projectRoot: root)

        await engine.removeFile(siteID: "site-1", relativePath: "src/pages/about.astro")

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.writing.headingCapitalization.sampleSize == 0)
    }

    @Test("rebuild preserves a user override across re-learning")
    func rebuildPreservesOverride() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let engine = ProjectConventionsEngine()
        await engine.rebuild(siteID: "site-1", projectRoot: root)
        await engine.applyOverride(siteID: "site-1", value: .altTextAverageLength(99))

        // A second rebuild (simulating a background re-learn) must not clobber the override.
        await engine.rebuild(siteID: "site-1", projectRoot: root)

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.images.altTextAverageLength.value == 99)
        #expect(conventions?.images.altTextAverageLength.isOverridden == true)
    }

    @Test("clearOverride reverts a field to inferred")
    func clearOverrideReverts() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let engine = ProjectConventionsEngine()
        await engine.rebuild(siteID: "site-1", projectRoot: root)
        await engine.applyOverride(siteID: "site-1", value: .altTextAverageLength(99))

        await engine.clearOverride(siteID: "site-1", field: .altTextAverageLength)

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.images.altTextAverageLength.isOverridden == false)
    }

    @Test("seed sets a starting value that a subsequent rebuild's merge respects")
    func seedIsRespectedByRebuild() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let engine = ProjectConventionsEngine()
        var seeded = ProjectConventions.empty
        seeded.apply(.altTextAverageLength(7))
        await engine.seed(siteID: "site-1", with: seeded)

        await engine.rebuild(siteID: "site-1", projectRoot: root)

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.images.altTextAverageLength.value == 7)
    }

    @Test("frontmatter collections come from content.config.ts, not the extractor")
    func frontmatterComesFromSchemaReader() async {
        let root = makeSite([
            "src/content.config.ts": """
            import { defineCollection } from "astro:content";
            import { z } from "astro/zod";
            const blog = defineCollection({ schema: z.object({ title: z.string() }).strict() });
            export const collections = { blog };
            """,
        ])
        let engine = ProjectConventionsEngine()
        await engine.rebuild(siteID: "site-1", projectRoot: root)

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.frontmatter.collections["blog"] == ["title"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ProjectConventionsEngineTests`
Expected: FAIL to compile — `ProjectConventionsEngine` doesn't exist yet.

- [ ] **Step 3: Write the engine**

```swift
// Sources/AnglesiteCore/ProjectConventionsEngine.swift
import Foundation

/// Shared, app-lifetime, in-memory index of each open site's `ProjectConventions` — mirrors
/// `SiteKnowledgeIndex`'s shape and lifecycle exactly (same `rebuild`/`upsertFile`/`removeFile`
/// triggers, driven by the same `SiteFileWatcher`, see Task 6).
///
/// Deliberately in-memory only, like `SiteKnowledgeIndex`'s embedding cache today: per-site
/// `Config/` persistence is owned by `ProjectConventionsStore` (Task 6) and driven by the
/// UI-facing `ProjectConventionsModel` (Task 9), not by this actor. `seed(siteID:with:)` lets a
/// caller preload a persisted value (so overrides survive an app restart) before the first
/// `rebuild` runs its merge.
public actor ProjectConventionsEngine {
    private var conventionsBySite: [String: ProjectConventions] = [:]
    private var filesBySite: [String: [String: String]] = [:]

    public init() {}

    public func rebuild(siteID: String, projectRoot: URL) async {
        let files = await Task.detached(priority: .utility) {
            Self.scan(projectRoot: projectRoot)
        }.value
        filesBySite[siteID] = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.contents) })
        recompute(siteID: siteID, projectRoot: projectRoot)
    }

    public func upsertFile(siteID: String, projectRoot: URL, relativePath: String) async {
        guard shouldScan(relativePath) else { return }
        let url = projectRoot.appendingPathComponent(relativePath)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            removeFile(siteID: siteID, relativePath: relativePath)
            return
        }
        filesBySite[siteID, default: [:]][relativePath] = contents
        recompute(siteID: siteID, projectRoot: projectRoot)
    }

    public func removeFile(siteID: String, relativePath: String) {
        guard filesBySite[siteID]?.removeValue(forKey: relativePath) != nil else { return }
        // No projectRoot available here (mirrors SiteKnowledgeIndex.removeFile) — frontmatter
        // collections are re-read from disk on the next full `rebuild`, not on every removal.
        recompute(siteID: siteID, projectRoot: nil)
    }

    public func unload(siteID: String) {
        conventionsBySite.removeValue(forKey: siteID)
        filesBySite.removeValue(forKey: siteID)
    }

    public func conventions(siteID: String) -> ProjectConventions? {
        conventionsBySite[siteID]
    }

    /// Preloads a value (typically read from `Config/conventions.json` by the caller) before the
    /// first `rebuild` for this site, so a subsequent `rebuild`'s merge preserves its overrides.
    /// No-op if a value is already present (a real `rebuild` has already run this session).
    public func seed(siteID: String, with conventions: ProjectConventions) {
        guard conventionsBySite[siteID] == nil else { return }
        conventionsBySite[siteID] = conventions
    }

    public func applyOverride(siteID: String, value: OverrideValue) {
        var conventions = conventionsBySite[siteID] ?? .empty
        conventions.apply(value)
        conventionsBySite[siteID] = conventions
    }

    public func clearOverride(siteID: String, field: OverridableField) {
        guard var conventions = conventionsBySite[siteID] else { return }
        conventions.clearOverride(field)
        conventionsBySite[siteID] = conventions
    }

    // MARK: - Recompute

    private func recompute(siteID: String, projectRoot: URL?) {
        let files = (filesBySite[siteID] ?? [:]).map {
            ProjectConventionsExtractor.ScannedFile(path: $0.key, contents: $0.value)
        }
        var fresh = ProjectConventionsExtractor.extract(files: files)
        if let projectRoot {
            fresh.frontmatter = FrontmatterConventions(
                collections: FrontmatterSchemaReader.read(siteDirectory: projectRoot)
            )
        } else if let previous = conventionsBySite[siteID] {
            // No projectRoot on this call (a `removeFile` with no disk access) — keep the
            // last-known frontmatter reading rather than blanking it out.
            fresh.frontmatter = previous.frontmatter
        }
        if let previous = conventionsBySite[siteID] {
            fresh = fresh.merging(overriddenFrom: previous)
        }
        conventionsBySite[siteID] = fresh
    }

    // MARK: - Scanning

    private func shouldScan(_ relativePath: String) -> Bool {
        guard !SiteIndexPaths.isSkipped(relativePath: relativePath) else { return false }
        return Self.scannedExtensions.contains(URL(fileURLWithPath: relativePath).pathExtension.lowercased())
    }

    private static let scannedExtensions: Set<String> = ["astro", "md", "mdx", "html"]

    private static func scan(projectRoot: URL) -> [ProjectConventionsExtractor.ScannedFile] {
        walk(projectRoot).compactMap { url -> ProjectConventionsExtractor.ScannedFile? in
            guard let relativePath = SiteIndexPaths.relativePOSIXPath(of: url, under: projectRoot),
                  scannedExtensions.contains(url.pathExtension.lowercased()),
                  let contents = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            return ProjectConventionsExtractor.ScannedFile(path: relativePath, contents: contents)
        }
    }

    private static func walk(_ dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for entry in entries {
            if SiteIndexPaths.skippedDirectoryNames.contains(entry.lastPathComponent) { continue }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                files.append(contentsOf: walk(entry))
            } else {
                files.append(entry)
            }
        }
        return files
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ProjectConventionsEngineTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ProjectConventionsEngine.swift Tests/AnglesiteCoreTests/ProjectConventionsEngineTests.swift
git commit -m "feat: add in-memory ProjectConventionsEngine actor"
```

---

### Task 5: On-device FM enrichment (tone descriptors, brand terms)

**Files:**
- Modify: `Sources/AnglesiteCore/GenerableTypes.swift` (add `GeneratedProjectConventions`)
- Modify: `Sources/AnglesiteCore/ProjectConventionsEngine.swift` (add throttled enrichment)
- Create: `Sources/AnglesiteCore/ProjectConventionsEnricherFactory.swift`
- Test: `Tests/AnglesiteCoreTests/ProjectConventionsEngineTests.swift` (add enrichment cases)

**Interfaces:**
- Consumes: `ProjectConventionsEngine` (Task 4), `AssistantContext` (existing, `Sources/AnglesiteCore/ContentAssistant.swift`), `FoundationModelAssistant` (existing, gated `#if compiler(>=6.4)`).
- Produces: `ProjectConventionsEngine.ConventionsEnricher` typealias, `ProjectConventionsEngine.init(enrich:enrichmentInterval:now:)`, `ProjectConventionsEnricherFactory.makeDefault() -> ProjectConventionsEngine.ConventionsEnricher?` — consumed by Task 7 (`AppDelegate` constructs the production engine with the default enricher).

- [ ] **Step 1: Write the failing tests (append to `ProjectConventionsEngineTests.swift`)**

```swift
    @Test("rebuild(forceEnrichment: true) calls the enricher and fills tone/brand fields")
    func forcedEnrichmentFillsFields() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let engine = ProjectConventionsEngine(
            enrich: { _, _ in (toneDescriptors: ["concise", "friendly"], brandTerms: ["Anglesite"]) },
            now: { Date(timeIntervalSince1970: 0) }
        )

        await engine.rebuild(siteID: "site-1", projectRoot: root, forceEnrichment: true)

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.writing.toneDescriptors.value == ["concise", "friendly"])
        #expect(conventions?.writing.brandTerms.value == ["Anglesite"])
    }

    @Test("a second rebuild within the throttle window does not call the enricher again")
    func throttleSkipsSecondCall() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let callCount = CallCounter()
        var currentTime = Date(timeIntervalSince1970: 0)
        let engine = ProjectConventionsEngine(
            enrich: { _, _ in
                await callCount.increment()
                return (toneDescriptors: ["concise"], brandTerms: [])
            },
            now: { currentTime }
        )

        await engine.rebuild(siteID: "site-1", projectRoot: root, forceEnrichment: true)
        currentTime = currentTime.addingTimeInterval(1) // well inside the default 300s throttle
        await engine.rebuild(siteID: "site-1", projectRoot: root)

        #expect(await callCount.value == 1)
    }

    @Test("an overridden tone/brand field survives enrichment")
    func enrichmentPreservesOverride() async {
        let root = makeSite(["src/pages/about.astro": "# About Us\n"])
        let engine = ProjectConventionsEngine(
            enrich: { _, _ in (toneDescriptors: ["concise"], brandTerms: ["fresh-from-model"]) },
            now: { Date(timeIntervalSince1970: 0) }
        )
        await engine.applyOverride(siteID: "site-1", value: .brandTerms(["MyBrand"]))

        await engine.rebuild(siteID: "site-1", projectRoot: root, forceEnrichment: true)

        let conventions = await engine.conventions(siteID: "site-1")
        #expect(conventions?.writing.brandTerms.value == ["MyBrand"])
    }

    private actor CallCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ProjectConventionsEngineTests`
Expected: FAIL to compile — no `enrich`/`now` init parameters, no `forceEnrichment` parameter yet.

- [ ] **Step 3: Add `GeneratedProjectConventions`**

Append to `Sources/AnglesiteCore/GenerableTypes.swift`, inside the existing `#if compiler(>=6.4)` block (after `GeneratedPageCopySuggestion`, before the closing `#endif`):

```swift
/// On-device guided-generation result for the throttled project-conventions enrichment pass
/// (tone/brand-term fields the deterministic extractor can't compute from text alone).
@Generable
public struct GeneratedProjectConventions: Equatable, Sendable {
    @Guide(description: "Three to five adjectives describing this site's writing tone, e.g. ['concise', 'playful', 'technical'].")
    public var toneDescriptors: [String]

    @Guide(description: "Up to five brand or product terms with their canonical capitalization as used in the text, e.g. ['Anglesite', 'Astro'].")
    public var brandTerms: [String]
}
```

- [ ] **Step 4: Extend `ProjectConventionsEngine` with throttled enrichment**

In `Sources/AnglesiteCore/ProjectConventionsEngine.swift`, replace the `public init() {}` line and add the enrichment machinery:

```swift
    public typealias ConventionsEnricher = @Sendable (
        _ sampleText: String, _ context: AssistantContext
    ) async throws -> (toneDescriptors: [String], brandTerms: [String])

    private let enrich: ConventionsEnricher?
    private let enrichmentInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var lastEnrichedAt: [String: Date] = [:]

    public init(
        enrich: ConventionsEnricher? = nil,
        enrichmentInterval: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.enrich = enrich
        self.enrichmentInterval = enrichmentInterval
        self.now = now
    }
```

Change `rebuild`'s signature and body to trigger enrichment:

```swift
    public func rebuild(siteID: String, projectRoot: URL, forceEnrichment: Bool = false) async {
        let files = await Task.detached(priority: .utility) {
            Self.scan(projectRoot: projectRoot)
        }.value
        filesBySite[siteID] = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.contents) })
        recompute(siteID: siteID, projectRoot: projectRoot)
        await maybeEnrich(siteID: siteID, siteDirectory: projectRoot, force: forceEnrichment)
    }
```

Add the enrichment helpers (near the other private helpers):

```swift
    private func maybeEnrich(siteID: String, siteDirectory: URL, force: Bool) async {
        guard let enrich else { return }
        if !force, let last = lastEnrichedAt[siteID], now().timeIntervalSince(last) < enrichmentInterval {
            return
        }
        guard let sample = sampleText(siteID: siteID) else { return }
        lastEnrichedAt[siteID] = now()
        let context = AssistantContext(siteID: siteID, siteDirectory: siteDirectory)
        guard let result = try? await enrich(sample, context) else { return }
        guard var conventions = conventionsBySite[siteID] else { return }
        if !conventions.writing.toneDescriptors.isOverridden {
            conventions.writing.toneDescriptors = Learned(value: result.toneDescriptors, source: .inferred(confidence: 1))
        }
        if !conventions.writing.brandTerms.isOverridden {
            conventions.writing.brandTerms = Learned(value: result.brandTerms, source: .inferred(confidence: 1))
        }
        conventionsBySite[siteID] = conventions
    }

    private func sampleText(siteID: String) -> String? {
        guard let files = filesBySite[siteID], !files.isEmpty else { return nil }
        return String(files.values.joined(separator: "\n\n").prefix(4_000))
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ProjectConventionsEngineTests`
Expected: PASS (10 tests total).

- [ ] **Step 6: Add the production enricher factory**

```swift
// Sources/AnglesiteCore/ProjectConventionsEnricherFactory.swift
import Foundation

/// Chooses the production `ProjectConventionsEngine.ConventionsEnricher`. `nil` pre-Xcode-27 (no
/// `FoundationModels`), matching `PageCopyGeneratorFactory`'s gating pattern — `AppDelegate`
/// constructs `ProjectConventionsEngine` with whatever this returns, so the engine works
/// identically (just without tone/brand enrichment) on the reduced CI toolchain.
public enum ProjectConventionsEnricherFactory {
    public static func makeDefault() -> ProjectConventionsEngine.ConventionsEnricher? {
        #if compiler(>=6.4)
        return { sampleText, context in
            let result = try await FoundationModelAssistant(tier: .onDevice).generateStructured(
                prompt: """
                Read the following excerpt from a website's content and describe its conventions.
                Excerpt:
                \(sampleText)
                """,
                context: context,
                resultType: GeneratedProjectConventions.self
            )
            return (toneDescriptors: result.toneDescriptors, brandTerms: result.brandTerms)
        }
        #else
        return nil
        #endif
    }
}
```

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/GenerableTypes.swift Sources/AnglesiteCore/ProjectConventionsEngine.swift Sources/AnglesiteCore/ProjectConventionsEnricherFactory.swift Tests/AnglesiteCoreTests/ProjectConventionsEngineTests.swift
git commit -m "feat: add throttled on-device tone/brand-term enrichment"
```

---

### Task 6: Per-site `Config/conventions.json` persistence

**Files:**
- Create: `Sources/AnglesiteCore/ProjectConventionsStore.swift`
- Test: `Tests/AnglesiteCoreTests/ProjectConventionsStoreTests.swift`

**Interfaces:**
- Consumes: `ProjectConventions` (Task 1).
- Produces: `ProjectConventionsStore` actor with `init(configDirectory:)`, `load() -> ProjectConventions?`, `save(_:)` — consumed by Task 9's `ProjectConventionsModel`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ProjectConventionsStore")
struct ProjectConventionsStoreTests {
    private func makeConfigDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("conventions-store-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("load returns nil when no file exists yet")
    func loadReturnsNilWhenMissing() async {
        let store = ProjectConventionsStore(configDirectory: makeConfigDirectory())
        #expect(await store.load() == nil)
    }

    @Test("save then load round-trips a value, including overrides")
    func saveThenLoadRoundTrips() async {
        let store = ProjectConventionsStore(configDirectory: makeConfigDirectory())
        var conventions = ProjectConventions.empty
        conventions.apply(.brandTerms(["Anglesite"]))

        await store.save(conventions)
        let loaded = await store.load()

        #expect(loaded?.writing.brandTerms.value == ["Anglesite"])
        #expect(loaded?.writing.brandTerms.isOverridden == true)
    }

    @Test("save creates the config directory if it doesn't exist yet")
    func saveCreatesConfigDirectory() async {
        let configDirectory = makeConfigDirectory()
        let store = ProjectConventionsStore(configDirectory: configDirectory)

        await store.save(.empty)

        #expect(FileManager.default.fileExists(atPath: configDirectory.appendingPathComponent("conventions.json").path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ProjectConventionsStoreTests`
Expected: FAIL to compile — `ProjectConventionsStore` doesn't exist yet.

- [ ] **Step 3: Write the store**

```swift
// Sources/AnglesiteCore/ProjectConventionsStore.swift
import Foundation

/// Per-site persistence for `ProjectConventions`, at `<configDirectory>/conventions.json`.
/// Follows `ChatHistoryStore`'s precedent: `Config/` is app-owned and not git-tracked. Unlike
/// `ChatHistoryStore` (append-only JSONL), this is a single whole-value JSON file — there's one
/// current `ProjectConventions`, not a history of them.
public actor ProjectConventionsStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(configDirectory: URL, fileManager: FileManager = .default) {
        self.fileURL = configDirectory.appendingPathComponent("conventions.json")
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func load() -> ProjectConventions? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(ProjectConventions.self, from: data)
    }

    public func save(_ conventions: ProjectConventions) {
        guard let data = try? encoder.encode(conventions) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ProjectConventionsStoreTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ProjectConventionsStore.swift Tests/AnglesiteCoreTests/ProjectConventionsStoreTests.swift
git commit -m "feat: add per-site Config/conventions.json persistence"
```

---

### Task 7: Wire the engine into the container runtime + app-level construction

**Files:**
- Modify: `Sources/AnglesiteCore/LocalContainerSiteRuntime.swift`
- Modify: `Sources/AnglesiteApp/SiteRuntimeFactory.swift`
- Modify: `Sources/AnglesiteApp/PreviewModel.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`
- Modify: `Sources/AnglesiteApp/AnglesiteApp.swift`
- Test: `Tests/AnglesiteCoreTests/LocalContainerSiteRuntimeReindexTests.swift` (add a case)

**Interfaces:**
- Consumes: `ProjectConventionsEngine` (Task 4/5), `ProjectConventionsEnricherFactory.makeDefault()` (Task 5).
- Produces: `LocalContainerSiteRuntime.init(..., conventionsEngine:)`, `SiteRuntimeFactory.makeRuntime(contentGraph:knowledgeIndex:semanticRanker:conventionsEngine:)`, `PreviewModel.init(..., conventionsEngine:)`, `SiteWindowModel.init(..., conventionsEngine:)`, `SiteWindow.init(..., conventionsEngine:)`, `AppDelegate.conventionsEngine` — consumed by Task 8 (alt-text) and Task 10 (Style Guide view).

- [ ] **Step 1: Write the failing test (append to `LocalContainerSiteRuntimeReindexTests.swift`)**

```swift
    @Test("container runtime rebuilds and re-scans project conventions the same way it does the knowledge index")
    func routesBatchToConventionsEngine() async {
        let root = makeSite(["src/pages/index.astro": "# Home\n"])
        let index = SiteKnowledgeIndex()
        let conventions = ProjectConventionsEngine()
        let watcher = ControllableWatcher()
        let fake = FakeLocalContainerControl(startResult: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let runtime = LocalContainerSiteRuntime(
            ref: "HEAD",
            control: fake,
            mcpClient: mcp,
            knowledgeIndex: index,
            conventionsEngine: conventions,
            connect: { _, _ in },
            makeFileWatcher: { watcher })

        await runtime.start(siteID: "s1", siteDirectory: root)
        #expect(await conventions.conventions(siteID: "s1")?.writing.headingCapitalization.sampleSize == 1)

        let added = root.appendingPathComponent("src/pages/about.astro")
        try! Data("# About\n".utf8).write(to: added)
        watcher.deliver(FileChangeBatch(paths: [added], needsFullRescan: false))
        _ = await poll(1.0) {
            await conventions.conventions(siteID: "s1")?.writing.headingCapitalization.sampleSize == 2
        }
        #expect(await conventions.conventions(siteID: "s1")?.writing.headingCapitalization.sampleSize == 2)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter LocalContainerSiteRuntimeReindexTests`
Expected: FAIL to compile — `LocalContainerSiteRuntime.init` has no `conventionsEngine` parameter yet.

- [ ] **Step 3: Add `conventionsEngine` to `LocalContainerSiteRuntime`**

In `Sources/AnglesiteCore/LocalContainerSiteRuntime.swift`, add a stored property next to `knowledgeIndex`/`semanticRanker` (around line 11):

```swift
    private let conventionsEngine: ProjectConventionsEngine?
```

Add the parameter to `init` (around line 30), storing it alongside `semanticRanker`:

```swift
    public init(
        ref: String,
        control: any LocalContainerControl,
        mcpClient: MCPClient,
        knowledgeIndex: SiteKnowledgeIndex? = nil,
        semanticRanker: SemanticRanker? = nil,
        conventionsEngine: ProjectConventionsEngine? = nil,
        logCenter: LogCenter = .shared,
        connect: @escaping @Sendable (MCPClient, URL) async throws -> Void = { c, u in try await c.connect(httpEndpoint: u) },
        makeFileWatcher: @escaping @Sendable () -> any SiteFileWatching = { FSEventsFileWatcher() }
    ) {
        self.ref = ref
        self.control = control
        self.mcpClient = mcpClient
        self.knowledgeIndex = knowledgeIndex
        self.semanticRanker = semanticRanker
        self.conventionsEngine = conventionsEngine
        self.logCenter = logCenter
        self.connect = connect
        self.makeFileWatcher = makeFileWatcher
    }
```

In `start(...)`, right after the existing `await knowledgeIndex?.rebuild(siteID: siteID, projectRoot: siteDirectory)` line (around line 115), add:

```swift
            await conventionsEngine?.rebuild(siteID: siteID, projectRoot: siteDirectory)
```

In `applyFileChanges(...)` (around line 208), extend the guard and add the parallel call:

```swift
    private func applyFileChanges(_ batch: FileChangeBatch, siteID: String, projectRoot: URL, generation gen: Int) async {
        guard gen == generation else { return }
        if let knowledgeIndex {
            await KnowledgeReindex.apply(batch, to: knowledgeIndex, ranker: semanticRanker, siteID: siteID, projectRoot: projectRoot)
        }
        if let conventionsEngine {
            await Self.applyToConventions(batch, engine: conventionsEngine, siteID: siteID, projectRoot: projectRoot)
        }
        guard gen == generation else {
            await knowledgeIndex?.unload(siteID: siteID)
            await semanticRanker?.unload(siteID: siteID)
            return
        }
    }

    /// Mirrors `KnowledgeReindex.apply`'s batch-translation logic for `ProjectConventionsEngine`.
    /// Kept as a small static helper (not a shared type with `KnowledgeReindex`) since the two
    /// indexes have different upsert/remove signatures and no shared ranker to keep in sync.
    private static func applyToConventions(
        _ batch: FileChangeBatch, engine: ProjectConventionsEngine, siteID: String, projectRoot: URL
    ) async {
        if batch.needsFullRescan {
            await engine.rebuild(siteID: siteID, projectRoot: projectRoot)
            return
        }
        var seen = Set<String>()
        for url in batch.paths {
            guard let relativePath = SiteIndexPaths.relativePOSIXPath(of: url, under: projectRoot),
                  !SiteIndexPaths.isSkipped(relativePath: relativePath),
                  seen.insert(relativePath).inserted
            else { continue }
            if FileManager.default.fileExists(atPath: url.path) {
                await engine.upsertFile(siteID: siteID, projectRoot: projectRoot, relativePath: relativePath)
            } else {
                await engine.removeFile(siteID: siteID, relativePath: relativePath)
            }
        }
    }
```

Also add `await conventionsEngine?.unload(siteID: siteID)` wherever `knowledgeIndex?.unload(siteID: siteID)` is already called during teardown/generation checks (the boot-path guard right after `rebuild`, and the two `unload` calls inside `applyFileChanges`'s stale-generation guard above already show the pattern — add the matching `conventionsEngine?.unload` line next to each existing `knowledgeIndex?.unload` call in the file).

- [ ] **Step 4: Thread `conventionsEngine` through `SiteRuntimeFactory`**

In `Sources/AnglesiteApp/SiteRuntimeFactory.swift`, add the parameter to the protocol and both call sites:

```swift
protocol SiteRuntimeFactory: Sendable {
    func makeRuntime(
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex?,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine?
    ) -> any SiteRuntime
}
```

```swift
    func makeRuntime(
        contentGraph: SiteContentGraph?,
        knowledgeIndex: SiteKnowledgeIndex?,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine?
    ) -> any SiteRuntime {
        let support = LocalContainerSupport.availability(
            hasVirtualizationEntitlement: VirtualizationEntitlement.isPresent
        )
        let provisioning = BundledImage.provisioningReport
        if support.isAvailable && provisioning.isProvisioned {
            logRuntimeSelection("selected LocalContainerSiteRuntime")
            return LocalContainerSiteRuntime(
                ref: "HEAD",
                control: ContainerizationControl(),
                mcpClient: MCPClient(supervisor: .shared),
                knowledgeIndex: knowledgeIndex,
                semanticRanker: semanticRanker,
                conventionsEngine: conventionsEngine
            )
        }
        logRuntimeSelection(Self.fallbackReason(support: support, provisioning: provisioning))
        return UnavailableSiteRuntime(reason: Self.unavailableMessage(support: support, provisioning: provisioning))
    }
```

- [ ] **Step 5: Thread `conventionsEngine` through `PreviewModel`**

In `Sources/AnglesiteApp/PreviewModel.swift`, update the convenience init (around line 46):

```swift
    convenience init(
        contentGraph: SiteContentGraph? = nil,
        knowledgeIndex: SiteKnowledgeIndex? = nil,
        semanticRanker: SemanticRanker? = nil,
        conventionsEngine: ProjectConventionsEngine? = nil,
        runtimeFactory: any SiteRuntimeFactory
    ) {
        self.init(runtime: runtimeFactory.makeRuntime(
            contentGraph: contentGraph,
            knowledgeIndex: knowledgeIndex,
            semanticRanker: semanticRanker,
            conventionsEngine: conventionsEngine
        ))
    }
```

- [ ] **Step 6: Thread `conventionsEngine` through `SiteWindowModel` and `SiteWindow`**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, add a stored property (near `knowledgeIndex`, line 34):

```swift
    private let conventionsEngine: ProjectConventionsEngine
```

Update `init` (around line 98):

```swift
    init(
        contentGraph: SiteContentGraph,
        knowledgeIndex: SiteKnowledgeIndex,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine,
        runtimeFactory: any SiteRuntimeFactory,
        contentIndexerStore: ContentIndexerStore
    ) {
        self.contentGraph = contentGraph
        self.knowledgeIndex = knowledgeIndex
        self.semanticRanker = semanticRanker
        self.conventionsEngine = conventionsEngine
        self.contentIndexerStore = contentIndexerStore
        self.preview = PreviewModel(
            contentGraph: contentGraph,
            knowledgeIndex: knowledgeIndex,
            semanticRanker: semanticRanker,
            conventionsEngine: conventionsEngine,
            runtimeFactory: runtimeFactory
        )
        self.contentCreation = ContentCreationWorkflow.native(
            contentGraph: contentGraph,
            knowledgeIndex: knowledgeIndex,
            siteDirectory: { id in await SiteStore.shared.find(id: id)?.sourceDirectory }
        )
        self.graphExplorer = SiteGraphExplorerModel(graph: contentGraph)
        self.relatedPages = RelatedPagesModel(index: knowledgeIndex, ranker: semanticRanker)
    }
```

In `Sources/AnglesiteApp/SiteWindow.swift`, update `init` (around line 31):

```swift
    init(
        siteID: String?,
        contentGraph: SiteContentGraph,
        knowledgeIndex: SiteKnowledgeIndex,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine,
        runtimeFactory: any SiteRuntimeFactory,
        contentIndexerStore: ContentIndexerStore
    ) {
        self.siteID = siteID
        _model = State(initialValue: SiteWindowModel(
            contentGraph: contentGraph,
            knowledgeIndex: knowledgeIndex,
            semanticRanker: semanticRanker,
            conventionsEngine: conventionsEngine,
            runtimeFactory: runtimeFactory,
            contentIndexerStore: contentIndexerStore
        ))
    }
```

- [ ] **Step 7: Construct the shared engine in `AppDelegate` and pass it to `SiteWindow`**

In `Sources/AnglesiteApp/AnglesiteApp.swift`, add a property next to `knowledgeIndex` (around line 25):

```swift
    /// Shared project-conventions index, learned from each open site's content and consumed by
    /// on-device generation (starting with alt text, #313). Mirrors `knowledgeIndex`'s lifecycle.
    let conventionsEngine = ProjectConventionsEngine(enrich: ProjectConventionsEnricherFactory.makeDefault())
```

Update the `SiteWindow(...)` construction inside `WindowGroup(for: String.self)` (around line 214):

```swift
            SiteWindow(
                siteID: siteID,
                contentGraph: appDelegate.contentGraph,
                knowledgeIndex: appDelegate.knowledgeIndex,
                semanticRanker: appDelegate.semanticRanker,
                conventionsEngine: appDelegate.conventionsEngine,
                runtimeFactory: LiveSiteRuntimeFactory(),
                contentIndexerStore: appDelegate.contentIndexerStore
            )
                .frame(minWidth: 960, minHeight: 600)
```

- [ ] **Step 8: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter LocalContainerSiteRuntimeReindexTests`
Expected: PASS.

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: PASS — full `AnglesiteCoreTests` suite still green (confirms the signature changes didn't break other callers).

- [ ] **Step 9: Regenerate the Xcode project and build the app target**

Run: `xcodegen generate && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED (confirms `AnglesiteApp` compiles against the new signatures — `swift test` alone doesn't build the app target).

- [ ] **Step 10: Commit**

```bash
git add Sources/AnglesiteCore/LocalContainerSiteRuntime.swift Sources/AnglesiteApp/SiteRuntimeFactory.swift Sources/AnglesiteApp/PreviewModel.swift Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/AnglesiteApp.swift Tests/AnglesiteCoreTests/LocalContainerSiteRuntimeReindexTests.swift
git commit -m "feat: wire ProjectConventionsEngine into the container runtime lifecycle"
```

---

### Task 8: Consume conventions in `AltTextGenerator`'s prompt

**Files:**
- Create: `Sources/AnglesiteCore/AltTextPromptBuilder.swift`
- Modify: `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift`
- Test: `Tests/AnglesiteCoreTests/AltTextPromptBuilderTests.swift`

**Interfaces:**
- Consumes: `ProjectConventions` (Task 1).
- Produces: `AltTextPromptBuilder.build(basePrompt:conventions:) -> String` — consumed by `SiteAssistantSessionFactory.Dependencies.live`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AnglesiteCore

@Suite("AltTextPromptBuilder")
struct AltTextPromptBuilderTests {
    @Test("returns the base prompt unchanged when there are no learned conventions")
    func returnsBasePromptWhenNoConventions() {
        let prompt = AltTextPromptBuilder.build(basePrompt: "Generate alt text.", conventions: nil)
        #expect(prompt == "Generate alt text.")
    }

    @Test("returns the base prompt unchanged when conventions have no signal yet")
    func returnsBasePromptWhenEmpty() {
        let prompt = AltTextPromptBuilder.build(basePrompt: "Generate alt text.", conventions: .empty)
        #expect(prompt == "Generate alt text.")
    }

    @Test("appends a guidance preamble drawn from images and brand-term conventions")
    func appendsGuidancePreamble() {
        var conventions = ProjectConventions.empty
        conventions.images.altTextAverageLength = Learned(value: 60, source: .inferred(confidence: 1), sampleSize: 10)
        conventions.images.altTextEndsWithPunctuation = Learned(value: true, source: .inferred(confidence: 1), sampleSize: 10)
        conventions.writing.brandTerms = Learned(value: ["Anglesite", "Astro"], source: .inferred(confidence: 1), sampleSize: 10)

        let prompt = AltTextPromptBuilder.build(basePrompt: "Generate alt text.", conventions: conventions)

        #expect(prompt.contains("Generate alt text."))
        #expect(prompt.contains("60 characters"))
        #expect(prompt.contains("ending with punctuation"))
        #expect(prompt.contains("Anglesite"))
        #expect(prompt.contains("Astro"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AltTextPromptBuilderTests`
Expected: FAIL to compile — `AltTextPromptBuilder` doesn't exist yet.

- [ ] **Step 3: Write the prompt builder**

```swift
// Sources/AnglesiteCore/AltTextPromptBuilder.swift
import Foundation

/// Builds the alt-text generation prompt, optionally prefixed with a short guidance preamble
/// drawn from the site's learned `ProjectConventions` (#313). A pure function — kept separate
/// from `AltTextGenerator` and `SiteAssistantSessionFactory` so it's directly unit-testable
/// without constructing either.
public enum AltTextPromptBuilder {
    public static func build(basePrompt: String, conventions: ProjectConventions?) -> String {
        guard let conventions, let preamble = guidance(from: conventions) else { return basePrompt }
        return "\(preamble)\n\n\(basePrompt)"
    }

    private static func guidance(from conventions: ProjectConventions) -> String? {
        var lines: [String] = []
        if conventions.images.altTextAverageLength.sampleSize.map({ $0 > 0 }) == true {
            lines.append("Aim for around \(conventions.images.altTextAverageLength.value) characters, matching this site's existing alt text.")
        }
        if conventions.images.altTextEndsWithPunctuation.sampleSize.map({ $0 > 0 }) == true,
           conventions.images.altTextEndsWithPunctuation.value {
            lines.append("This site's existing alt text tends toward full sentences ending with punctuation.")
        }
        if !conventions.writing.brandTerms.value.isEmpty {
            let terms = conventions.writing.brandTerms.value.joined(separator: ", ")
            lines.append("Use this site's own capitalization for brand/product terms when they appear: \(terms).")
        }
        guard !lines.isEmpty else { return nil }
        return (["This site has learned conventions to match:"] + lines).joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter AltTextPromptBuilderTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Wire it into `SiteAssistantSessionFactory`**

In `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift`, add `conventionsEngine` to `Dependencies.altTextGenerator`'s signature (around line 32) and to `makeSession`'s parameter list, then use it in the `produce` closure.

Change:

```swift
        var altTextGenerator: @Sendable (
            _ siteID: String,
            _ sourceDirectory: URL,
            _ mcpClient: @escaping MCPClientProvider
        ) -> AltTextGenerator
```

to:

```swift
        var altTextGenerator: @Sendable (
            _ siteID: String,
            _ sourceDirectory: URL,
            _ mcpClient: @escaping MCPClientProvider,
            _ conventionsEngine: ProjectConventionsEngine?
        ) -> AltTextGenerator
```

Change the `Dependencies.live` closure body (around line 70) from:

```swift
                altTextGenerator: { siteID, sourceDirectory, mcpClient in
                    AltTextGenerator(
                        siteID: siteID,
                        siteDirectory: sourceDirectory,
                        isEnabled: { AppSettings.shared.autoGenerateAltText },
                        produce: { imageURL, context in
                            try await FoundationModelAssistant(tier: .onDevice).generateStructured(
                                prompt: "Generate concise, descriptive alt text for this image as it would appear on a website. If the image is purely decorative, mark it decorative and use empty alt text.",
                                imageURL: imageURL,
                                context: context,
                                resultType: GeneratedAltText.self
                            )
                        },
```

to:

```swift
                altTextGenerator: { siteID, sourceDirectory, mcpClient, conventionsEngine in
                    AltTextGenerator(
                        siteID: siteID,
                        siteDirectory: sourceDirectory,
                        isEnabled: { AppSettings.shared.autoGenerateAltText },
                        produce: { imageURL, context in
                            let conventions = await conventionsEngine?.conventions(siteID: siteID)
                            let prompt = AltTextPromptBuilder.build(
                                basePrompt: "Generate concise, descriptive alt text for this image as it would appear on a website. If the image is purely decorative, mark it decorative and use empty alt text.",
                                conventions: conventions
                            )
                            return try await FoundationModelAssistant(tier: .onDevice).generateStructured(
                                prompt: prompt,
                                imageURL: imageURL,
                                context: context,
                                resultType: GeneratedAltText.self
                            )
                        },
```

Update `makeSession`'s parameter list (around line 102) to accept `conventionsEngine: ProjectConventionsEngine?` and pass it through to the call at line 132:

```swift
    static func makeSession(
        siteID: String,
        sourceDirectory: URL,
        configDirectory: URL,
        mcpClient: @escaping MCPClientProvider,
        contentGraph: SiteContentGraph,
        knowledgeIndex: SiteKnowledgeIndex,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine?,
        integrationService: any IntegrationOperationsService,
        dependencies: Dependencies = .live
    ) -> SiteAssistantSession {
```

```swift
        let altTextGenerator = dependencies.altTextGenerator(siteID, sourceDirectory, mcpClient, conventionsEngine)
```

- [ ] **Step 6: Update the `makeSession` call site in `SiteWindowModel.swift`**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, the `SiteAssistantSessionFactory.makeSession(...)` call (around line 562) gains one argument:

```swift
        let assistantSession = SiteAssistantSessionFactory.makeSession(
            siteID: resolved.id,
            sourceDirectory: resolved.sourceDirectory,
            configDirectory: resolved.configDirectory,
            mcpClient: mcpClient,
            contentGraph: contentGraph,
            knowledgeIndex: knowledgeIndex,
            semanticRanker: semanticRanker,
            conventionsEngine: conventionsEngine,
            integrationService: integrationOps
        )
```

- [ ] **Step 7: Build the app target to verify the wiring compiles**

Run: `xcodegen generate && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/AltTextPromptBuilder.swift Sources/AnglesiteApp/SiteAssistantSessionFactory.swift Sources/AnglesiteApp/SiteWindowModel.swift Tests/AnglesiteCoreTests/AltTextPromptBuilderTests.swift
git commit -m "feat: prime alt-text generation with learned project conventions"
```

---

### Task 9: `ProjectConventionsModel` (per-site, owns persistence)

**Files:**
- Create: `Sources/AnglesiteApp/ProjectConventionsModel.swift`

**Interfaces:**
- Consumes: `ProjectConventionsEngine` (Task 4), `ProjectConventionsStore` (Task 6), `ProjectConventions`/`OverridableField`/`OverrideValue` (Task 1).
- Produces: `ProjectConventionsModel` with `conventions: ProjectConventions?`, `isLearning: Bool`, `sheetPresented: Bool`, `presentSheet(siteID:siteDirectory:)`, `rescan(siteID:siteDirectory:)`, `setOverride(siteID:_:)`, `clearOverride(siteID:_:)` — consumed by Task 10's `ProjectStyleGuideView` and `SiteWindowModel`.

This is a plain Swift model (no FoundationModels dependency), so no TDD test file is added here —
its logic is a thin `@MainActor` wrapper around the already-tested `ProjectConventionsEngine` and
`ProjectConventionsStore`; it's exercised through the app build (Step 3) and manual verification
(Task 10's UI smoke test covers its behavior end-to-end).

- [ ] **Step 1: Write the model**

```swift
// Sources/AnglesiteApp/ProjectConventionsModel.swift
import Foundation
import AnglesiteCore

/// Per-site, UI-facing wrapper around the shared `ProjectConventionsEngine`. Owns the
/// `Config/conventions.json` round trip (via `ProjectConventionsStore`) so persistence only
/// happens on explicit user-driven actions (rescan, override, clear-override) — background
/// re-learns triggered by the file watcher update the in-memory engine value (which
/// `AltTextGenerator` reads immediately) but are not separately persisted to disk until the next
/// explicit action here.
@MainActor
@Observable
final class ProjectConventionsModel {
    private let engine: ProjectConventionsEngine
    private let store: ProjectConventionsStore
    private let siteID: String
    private let siteDirectory: URL

    private(set) var conventions: ProjectConventions?
    private(set) var isLearning = false
    var sheetPresented = false

    init(engine: ProjectConventionsEngine, siteID: String, siteDirectory: URL, configDirectory: URL) {
        self.engine = engine
        self.siteID = siteID
        self.siteDirectory = siteDirectory
        self.store = ProjectConventionsStore(configDirectory: configDirectory)
    }

    /// Seeds the shared engine from disk (once per site-open, so overrides survive an app
    /// restart) and opens the sheet. Safe to call more than once — `seed` on the engine is
    /// itself a no-op once a value is present.
    func presentSheet() async {
        if let persisted = await store.load() {
            await engine.seed(siteID: siteID, with: persisted)
        }
        conventions = await engine.conventions(siteID: siteID)
        sheetPresented = true
    }

    func rescan() async {
        isLearning = true
        await engine.rebuild(siteID: siteID, projectRoot: siteDirectory, forceEnrichment: true)
        conventions = await engine.conventions(siteID: siteID)
        if let conventions {
            await store.save(conventions)
        }
        isLearning = false
    }

    func setOverride(_ value: OverrideValue) async {
        await engine.applyOverride(siteID: siteID, value: value)
        conventions = await engine.conventions(siteID: siteID)
        if let conventions {
            await store.save(conventions)
        }
    }

    func clearOverride(_ field: OverridableField) async {
        await engine.clearOverride(siteID: siteID, field: field)
        conventions = await engine.conventions(siteID: siteID)
        if let conventions {
            await store.save(conventions)
        }
    }
}
```

- [ ] **Step 2: Build the app target to verify it compiles**

Run: `xcodegen generate && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED. (`ProjectConventionsModel` isn't referenced by anything yet — Task 10 wires it in — so this step just confirms the new file itself is well-formed.)

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/ProjectConventionsModel.swift
git commit -m "feat: add per-site ProjectConventionsModel"
```

---

### Task 10: Project Style Guide inspector view

**Files:**
- Create: `Sources/AnglesiteApp/ProjectStyleGuideView.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`

**Interfaces:**
- Consumes: `ProjectConventionsModel` (Task 9), `ProjectConventions`/`OverridableField`/`OverrideValue`/`HeadingCapitalization`/`SlugStyle` (Task 1).
- Produces: `ProjectStyleGuideView`, `SiteWindowModel.styleGuide: ProjectConventionsModel?`, `SiteWindowModel.openStyleGuide()` — the terminal UI surface for this plan; nothing downstream consumes it.

- [ ] **Step 1: Add `styleGuide` to `SiteWindowModel`**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, add a property near `chat` (around line 65):

```swift
    /// Created once the site resolves in `loadAndStart` (needs `siteDirectory`/`configDirectory`),
    /// same lifecycle as `chat`. Its own `sheetPresented` drives the `.sheet(isPresented:)` in
    /// `SiteWindow`, following `AuditModel`'s pattern rather than the item-based sheets.
    var styleGuide: ProjectConventionsModel?
```

In `loadAndStart` (the same method that sets `chat = assistantSession.chat`, around line 572), add right after that line:

```swift
        styleGuide = ProjectConventionsModel(
            engine: conventionsEngine,
            siteID: resolved.id,
            siteDirectory: resolved.sourceDirectory,
            configDirectory: resolved.configDirectory
        )
```

Add an opener method near `openIntegrationWizard()` (around line 163):

```swift
    func openStyleGuide() {
        guard let styleGuide else { return }
        Task { await styleGuide.presentSheet() }
    }
```

- [ ] **Step 2: Write the view**

```swift
// Sources/AnglesiteApp/ProjectStyleGuideView.swift
import SwiftUI
import AnglesiteCore

/// Sheet showing the site's learned `ProjectConventions`, sectioned by category, with an
/// edit/override affordance per learnable field. Frontmatter is read-only (ground truth from
/// `content.config.ts`, not inference — see `FrontmatterSchemaReader`).
struct ProjectStyleGuideView: View {
    let model: ProjectConventionsModel
    let siteName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let conventions = model.conventions {
                    List {
                        writingSection(conventions)
                        imagesSection(conventions)
                        componentsSection(conventions)
                        namingSection(conventions)
                        seoSection(conventions)
                        frontmatterSection(conventions)
                    }
                } else {
                    ProgressView("Learning \(siteName)’s conventions…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Project Style Guide")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Rescan Now") {
                        Task { await model.rescan() }
                    }
                    .disabled(model.isLearning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    // MARK: Sections

    @ViewBuilder
    private func writingSection(_ conventions: ProjectConventions) -> some View {
        Section("Writing") {
            learnedRow(
                "Heading style",
                display: conventions.writing.headingCapitalization.value.rawValue,
                learned: conventions.writing.headingCapitalization,
                onClear: { Task { await model.clearOverride(.headingCapitalization) } }
            )
            learnedRow(
                "Tone",
                display: conventions.writing.toneDescriptors.value.isEmpty
                    ? "Not learned yet" : conventions.writing.toneDescriptors.value.joined(separator: ", "),
                learned: conventions.writing.toneDescriptors,
                onClear: { Task { await model.clearOverride(.toneDescriptors) } }
            )
            learnedRow(
                "Brand terms",
                display: conventions.writing.brandTerms.value.isEmpty
                    ? "Not learned yet" : conventions.writing.brandTerms.value.joined(separator: ", "),
                learned: conventions.writing.brandTerms,
                onClear: { Task { await model.clearOverride(.brandTerms) } }
            )
        }
    }

    @ViewBuilder
    private func imagesSection(_ conventions: ProjectConventions) -> some View {
        Section("Images") {
            learnedRow(
                "Average alt text length",
                display: "\(conventions.images.altTextAverageLength.value) characters",
                learned: conventions.images.altTextAverageLength,
                onClear: { Task { await model.clearOverride(.altTextAverageLength) } }
            )
            learnedRow(
                "Ends with punctuation",
                display: conventions.images.altTextEndsWithPunctuation.value ? "Yes" : "No",
                learned: conventions.images.altTextEndsWithPunctuation,
                onClear: { Task { await model.clearOverride(.altTextEndsWithPunctuation) } }
            )
        }
    }

    @ViewBuilder
    private func componentsSection(_ conventions: ProjectConventions) -> some View {
        Section("Components") {
            if conventions.components.usageCounts.value.isEmpty {
                Text("No component usage learned yet.").foregroundStyle(.secondary)
            } else {
                ForEach(conventions.components.usageCounts.value.sorted(by: { $0.value > $1.value }), id: \.key) { name, count in
                    LabeledContent(name) { Text("\(count)") }
                }
            }
        }
    }

    @ViewBuilder
    private func namingSection(_ conventions: ProjectConventions) -> some View {
        Section("Naming") {
            learnedRow(
                "Slug style",
                display: conventions.naming.slugStyle.value.rawValue,
                learned: conventions.naming.slugStyle,
                onClear: { Task { await model.clearOverride(.slugStyle) } }
            )
        }
    }

    @ViewBuilder
    private func seoSection(_ conventions: ProjectConventions) -> some View {
        Section("SEO") {
            learnedRow(
                "Average meta description length",
                display: "\(conventions.seo.metaDescriptionAverageLength.value) characters",
                learned: conventions.seo.metaDescriptionAverageLength,
                onClear: { Task { await model.clearOverride(.metaDescriptionAverageLength) } }
            )
        }
    }

    @ViewBuilder
    private func frontmatterSection(_ conventions: ProjectConventions) -> some View {
        Section("Frontmatter (read from content.config.ts)") {
            if conventions.frontmatter.collections.isEmpty {
                Text("No content collections found.").foregroundStyle(.secondary)
            } else {
                ForEach(conventions.frontmatter.collections.keys.sorted(), id: \.self) { name in
                    LabeledContent(name) {
                        Text((conventions.frontmatter.collections[name] ?? []).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Row helper

    @ViewBuilder
    private func learnedRow<Value>(
        _ label: String, display: String, learned: Learned<Value>, onClear: @escaping () -> Void
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(display)
                if learned.isOverridden {
                    Text("edited").font(.caption2).foregroundStyle(.secondary)
                    Button("Revert", action: onClear).font(.caption2)
                } else if let sampleSize = learned.sampleSize, sampleSize > 0, sampleSize < 3 {
                    Text("low confidence").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Wire the sheet and a toolbar button into `SiteWindow`**

In `Sources/AnglesiteApp/SiteWindow.swift`, add a toolbar button near the "Add Integration…" button (around line 332-340):

```swift
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.openStyleGuide()
                } label: {
                    Label("Style Guide", systemImage: "textformat.abc")
                }
                .help("See and edit this site's learned writing, image, and naming conventions")
            }
            .visibilityPriority(ToolbarItemVisibilityPriority(lowerThan: .low))
```

Add the sheet near the other `.sheet(isPresented:)` modifiers (around line 372-377):

```swift
        .sheet(isPresented: Binding(
            get: { bindableModel.styleGuide?.sheetPresented ?? false },
            set: { bindableModel.styleGuide?.sheetPresented = $0 }
        )) {
            if let styleGuide = model.styleGuide {
                ProjectStyleGuideView(model: styleGuide, siteName: site.name)
            }
        }
```

- [ ] **Step 4: Build and manually verify**

Run: `xcodegen generate && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

Manual smoke test (per the project's `verify` skill — this is a UI feature, so a build alone
doesn't confirm the feature works):
1. Launch the built app, open an existing site with some Markdown/Astro content.
2. Click the new "Style Guide" toolbar button. Confirm the sheet opens and, after a moment,
   shows populated Writing/Images/Components/Naming/SEO/Frontmatter sections (not stuck on
   "Learning…" — if a section shows zero-confidence defaults, that's expected for a very small
   fixture site).
3. Click "Rescan Now" — confirm the button disables briefly and the values refresh.
4. Quit and relaunch the app, reopen the same site, open Style Guide again — confirm values are
   still populated (not reset to empty), proving the seed-from-`Config/conventions.json` path
   works.
5. Drop an image into the preview (existing image-drop flow) with Settings' auto-alt-text on;
   confirm alt text generation still succeeds (no regression from Task 8's prompt change).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/ProjectStyleGuideView.swift Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat: add Project Style Guide inspector view"
```

---

## Self-Review Notes

- **Spec coverage:** Taxonomy (§1) → Tasks 1–3; data model (§2) → Task 1; learning engine (§3) →
  Tasks 2/4/5; storage (§4/§5, revised) → Task 6; consumption pattern + first consumer (§6) →
  Task 8; Inspector (§7, promoted to in-scope) → Tasks 9–10. Non-goals (design/CSS conventions,
  chat/new-page-copy/deploy-summary consumption, cross-site sharing, git-tracked storage) are
  intentionally not tasked.
- **Type consistency check:** `OverrideValue`/`OverridableField` cases (Task 1) match exactly
  across `ProjectConventionsModel.setOverride`/`clearOverride` (Task 9) and
  `ProjectStyleGuideView`'s `onClear` closures (Task 10). `ProjectConventionsEngine`'s public
  method names (`rebuild`, `upsertFile`, `removeFile`, `unload`, `conventions`, `seed`,
  `applyOverride`, `clearOverride`) are used identically in Tasks 6, 7, 8, and 9 — no renames
  slipped in along the way.
- **Deviation flagged inline:** Task 3 replaces the design doc's Node-script-over-container-exec
  sketch with a pure-Swift scan, explained in both the plan header and Task 3 itself.

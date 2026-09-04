# Slice 6: Content Help on Foundation Models — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement copy-edit, social-media, and repurpose on FoundationModels (chunk-first, tier-ready), each reachable from chat, Siri, and GUI, per the approved spec [`docs/superpowers/specs/2026-07-10-slice6-content-help-fm-design.md`](../specs/2026-07-10-slice6-content-help-fm-design.md) (issue #465).

**Architecture:** A shared kernel in `AnglesiteCore` — brand-voice preamble from `ProjectConventions`, a filesystem-scanning `SiteContentChunker` with hard caps, and a `ContentAssistantFactory` tier seam (shared with #464) — then three capabilities, each a deterministic gatherer + a `Factory.makeDefault()` gated structured generator + three front-doors (FM `Tool`, App Intent, GUI). All FM-touching code sits behind `#if compiler(>=6.4)` with pure helpers above the gate.

**Tech Stack:** Swift 6.4 / Xcode 27, FoundationModels (`@Generable`/`@Guide` guided generation), Swift Testing, SwiftUI, AppIntents.

## Global Constraints

- **Toolchain gate:** every file that imports `FoundationModels` wraps that code in `#if compiler(>=6.4)`; pure parse/prompt/aggregation helpers live ABOVE the gate so CI (Xcode 26.3) compiles and tests them. Pattern: `Sources/AnglesiteCore/SetupIntegrationTool.swift`.
- **Factories are non-gated:** `SomethingFactory.makeDefault()` returns `(any Protocol)?` — `nil` below Swift 6.4 (pattern: `SiteGraphExplainerFactory`).
- **Tier seam (#464/#465):** capabilities obtain assistants ONLY via `ContentAssistantFactory.make(tier:)` (Task 6) — never construct `FoundationModelAssistant` directly.
- **No network I/O anywhere in this slice.** Nothing posts externally.
- **FM unavailable** (`AssistantError.unavailable`) → GUI disabled-with-explanation, tools return a graceful string, intents return an error dialog. Never a cloud fallback.
- **Tests:** new tests use Swift Testing (`import Testing`, `@Test`, `#expect`) in `Tests/AnglesiteCoreTests/`. Run with:
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .` (the default CommandLineTools swift is too old). If it hangs with no output, check `pgrep -fl swift-test` for a stale process holding the `.build` lock.
- **Worktree:** all work happens in this worktree (`.claude/worktrees/focused-shaw-9f716a`) on branch `claude/issue-465-solutions-db49b6`. App-target builds need `xcodegen generate` + `scripts/copy-plugin.sh` first, but `swift test` does not.
- **Commits:** conventional commits, one per task, ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `AssistantContext(siteID:siteDirectory:)` — `siteDirectory` is always the site's `Source/` directory.
- Char caps use character counts as a token proxy (no on-device tokenizer): `SiteContentChunker.maxChunkCharacters = 2_000`, matching `FoundationModelAssistant.maxPageContentCharacters`.

---

## Phase A — Shared kernel

### Task 1: Extend `WritingConventions` with `audience` + `avoidPhrases`

**Files:**
- Modify: `Sources/AnglesiteCore/ProjectConventions.swift`
- Test: `Tests/AnglesiteCoreTests/ProjectConventionsVoiceFieldsTests.swift`

**Interfaces:**
- Consumes: existing `Learned<V>`, `ConventionSource`, `OverridableField`, `OverrideValue`.
- Produces: `WritingConventions.audience: Learned<String>` ("" = unset), `WritingConventions.avoidPhrases: Learned<[String]>`; `OverridableField.audience/.avoidPhrases`; `OverrideValue.audience(String)/.avoidPhrases([String])`; backward-compatible decoding of old `conventions.json`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/ProjectConventionsVoiceFieldsTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ProjectConventionsVoiceFieldsTests {
    @Test func emptyHasUnsetVoiceFields() {
        let c = ProjectConventions.empty
        #expect(c.writing.audience.value == "")
        #expect(c.writing.avoidPhrases.value == [])
        #expect(!c.writing.audience.isOverridden)
    }

    @Test func applyOverridesVoiceFields() {
        var c = ProjectConventions.empty
        c.apply(.audience("busy parents in Oakland"))
        c.apply(.avoidPhrases(["synergy", "world-class"]))
        #expect(c.writing.audience.value == "busy parents in Oakland")
        #expect(c.writing.audience.isOverridden)
        #expect(c.writing.avoidPhrases.value == ["synergy", "world-class"])
    }

    @Test func mergingPreservesVoiceOverrides() {
        var previous = ProjectConventions.empty
        previous.apply(.audience("locals"))
        let fresh = ProjectConventions.empty
        let merged = fresh.merging(overriddenFrom: previous)
        #expect(merged.writing.audience.value == "locals")
        #expect(merged.writing.audience.isOverridden)
    }

    @Test func clearOverrideRevertsSource() {
        var c = ProjectConventions.empty
        c.apply(.audience("locals"))
        c.clearOverride(.audience)
        #expect(!c.writing.audience.isOverridden)
    }

    /// Old conventions.json files predate the two voice fields — they must decode with defaults.
    @Test func decodesLegacyJSONWithoutVoiceFields() throws {
        let legacy = """
        {"headingCapitalization":{"value":"mixed","source":{"inferred":{"confidence":0}},"sampleSize":0},
         "toneDescriptors":{"value":[],"source":{"inferred":{"confidence":0}},"sampleSize":0},
         "brandTerms":{"value":[],"source":{"inferred":{"confidence":0}},"sampleSize":0}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WritingConventions.self, from: legacy)
        #expect(decoded.audience.value == "")
        #expect(decoded.avoidPhrases.value == [])
    }
}
```

Note: before finalizing the legacy-JSON fixture, encode `ProjectConventions.empty.writing` with `JSONEncoder` in the test and print it once to confirm the synthesized `ConventionSource` encoding shape; adjust the fixture string to match actual output, then remove the print.

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ProjectConventionsVoiceFieldsTests`
Expected: FAIL — `WritingConventions` has no member `audience`.

- [ ] **Step 3: Implement**

In `Sources/AnglesiteCore/ProjectConventions.swift`:

Replace the `WritingConventions` struct with:

```swift
public struct WritingConventions: Sendable, Codable, Equatable {
    public var headingCapitalization: Learned<HeadingCapitalization>
    public var toneDescriptors: Learned<[String]>
    public var brandTerms: Learned<[String]>
    /// Who the site speaks to, in the owner's words. `""` = unset. Set by the brand-voice
    /// interview (#465); never inferred by the extractor.
    public var audience: Learned<String>
    /// Words/phrases generation must avoid. `[]` = unset. Set by the brand-voice interview.
    public var avoidPhrases: Learned<[String]>

    public init(
        headingCapitalization: Learned<HeadingCapitalization>,
        toneDescriptors: Learned<[String]>,
        brandTerms: Learned<[String]>,
        audience: Learned<String> = Learned(value: "", source: .inferred(confidence: 0), sampleSize: 0),
        avoidPhrases: Learned<[String]> = Learned(value: [], source: .inferred(confidence: 0), sampleSize: 0)
    ) {
        self.headingCapitalization = headingCapitalization
        self.toneDescriptors = toneDescriptors
        self.brandTerms = brandTerms
        self.audience = audience
        self.avoidPhrases = avoidPhrases
    }

    private enum CodingKeys: String, CodingKey {
        case headingCapitalization, toneDescriptors, brandTerms, audience, avoidPhrases
    }

    // Pre-#465 conventions.json has no voice fields; default them instead of failing the decode
    // (a decode failure would silently drop the user's whole learned state).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headingCapitalization = try c.decode(Learned<HeadingCapitalization>.self, forKey: .headingCapitalization)
        toneDescriptors = try c.decode(Learned<[String]>.self, forKey: .toneDescriptors)
        brandTerms = try c.decode(Learned<[String]>.self, forKey: .brandTerms)
        audience = try c.decodeIfPresent(Learned<String>.self, forKey: .audience)
            ?? Learned(value: "", source: .inferred(confidence: 0), sampleSize: 0)
        avoidPhrases = try c.decodeIfPresent(Learned<[String]>.self, forKey: .avoidPhrases)
            ?? Learned(value: [], source: .inferred(confidence: 0), sampleSize: 0)
    }
}
```

Add cases to `OverridableField`: `case audience`, `case avoidPhrases`.
Add cases to `OverrideValue`: `case audience(String)`, `case avoidPhrases([String])`.
In `apply(_:)` add:

```swift
        case .audience(let v):
            writing.audience = Learned(value: v, source: .userOverride)
        case .avoidPhrases(let v):
            writing.avoidPhrases = Learned(value: v, source: .userOverride)
```

In `clearOverride(_:)` add:

```swift
        case .audience:
            writing.audience.source = .inferred(confidence: 0)
        case .avoidPhrases:
            writing.avoidPhrases.source = .inferred(confidence: 0)
```

In `merging(overriddenFrom:)` add:

```swift
        if previous.writing.audience.isOverridden {
            merged.writing.audience = previous.writing.audience
        }
        if previous.writing.avoidPhrases.isOverridden {
            merged.writing.avoidPhrases = previous.writing.avoidPhrases
        }
```

`.empty` needs no change (the new init parameters default). Check `ProjectStyleGuideView.swift` and `ProjectConventionsExtractor.swift` still compile: the memberwise-init defaults keep existing call sites source-compatible. If `ProjectStyleGuideView`'s override UI switches exhaustively over `OverridableField`, add the two new cases there as simple `TokenListConventionRow`/text rows or (minimal) exclude them from that view's field list — the interview (Task 4) is their primary editor.

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ProjectConventionsVoiceFieldsTests`
Expected: PASS (5 tests). Then run the full `AnglesiteCoreTests` filter for `ProjectConventions` to catch regressions: `--filter ProjectConventions` → all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ProjectConventions.swift Tests/AnglesiteCoreTests/ProjectConventionsVoiceFieldsTests.swift Sources/AnglesiteApp/ProjectStyleGuideView.swift
git commit -m "feat(core): add audience + avoidPhrases voice fields to WritingConventions (#465)"
```

---

### Task 2: `BrandVoiceGuidance` preamble + `SiteBusinessType`

**Files:**
- Create: `Sources/AnglesiteCore/BrandVoiceGuidance.swift`
- Test: `Tests/AnglesiteCoreTests/BrandVoiceGuidanceTests.swift`

**Interfaces:**
- Consumes: `ProjectConventions` (incl. Task 1 fields), `Learned`, `SiteConfigFile.value(forKey:in:)`.
- Produces: `BrandVoiceGuidance.preamble(conventions: ProjectConventions?, businessType: String?) -> String?`; `SiteBusinessType.read(sourceDirectory: URL) -> String?`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/BrandVoiceGuidanceTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct BrandVoiceGuidanceTests {
    @Test func emptyConventionsYieldNil() {
        #expect(BrandVoiceGuidance.preamble(conventions: .empty, businessType: nil) == nil)
        #expect(BrandVoiceGuidance.preamble(conventions: nil, businessType: nil) == nil)
    }

    @Test func businessTypeAloneYieldsPreamble() {
        let p = BrandVoiceGuidance.preamble(conventions: nil, businessType: "bakery")
        #expect(p?.contains("bakery") == true)
    }

    @Test func learnedFieldsAppearInPreamble() {
        var c = ProjectConventions.empty
        c.writing.toneDescriptors = Learned(value: ["warm", "expert"], source: .inferred(confidence: 0.8), sampleSize: 12)
        c.writing.brandTerms = Learned(value: ["SourdoughLab"], source: .inferred(confidence: 0.9), sampleSize: 12)
        c.apply(.audience("home bakers"))
        c.apply(.avoidPhrases(["artisanal"]))
        let p = BrandVoiceGuidance.preamble(conventions: c, businessType: nil)
        #expect(p?.contains("warm, expert") == true)
        #expect(p?.contains("SourdoughLab") == true)
        #expect(p?.contains("home bakers") == true)
        #expect(p?.contains("artisanal") == true)
    }

    /// Zero-sample inferred values are noise, not signal — they must not leak into prompts.
    @Test func zeroSampleUnoverriddenFieldsAreSkipped() {
        var c = ProjectConventions.empty
        c.writing.toneDescriptors = Learned(value: ["stale"], source: .inferred(confidence: 0), sampleSize: 0)
        #expect(BrandVoiceGuidance.preamble(conventions: c, businessType: nil) == nil)
    }

    @Test func readsBusinessTypeFromSiteConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bvg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "BUSINESS_TYPE=bakery\nSITE_NAME=SourdoughLab\n"
            .write(to: dir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        #expect(SiteBusinessType.read(sourceDirectory: dir) == "bakery")
        #expect(SiteBusinessType.read(sourceDirectory: dir.appendingPathComponent("missing")) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter BrandVoiceGuidanceTests`
Expected: FAIL — cannot find `BrandVoiceGuidance` in scope.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/BrandVoiceGuidance.swift
import Foundation

/// Natural-language brand-voice preamble for content-help prompts (#465) — the general form of
/// `AltTextPromptBuilder`'s guidance, built from the site's learned/overridden `ProjectConventions`.
/// Pure and non-gated so it's unit-testable on CI.
public enum BrandVoiceGuidance {
    /// Returns `nil` when there is no voice signal at all — callers then omit the preamble
    /// entirely rather than prompt with boilerplate.
    public static func preamble(conventions: ProjectConventions?, businessType: String?) -> String? {
        var lines: [String] = []
        if let w = conventions?.writing {
            if hasSignal(w.toneDescriptors), !w.toneDescriptors.value.isEmpty {
                lines.append("Write in a \(w.toneDescriptors.value.joined(separator: ", ")) tone.")
            }
            if hasSignal(w.audience), !w.audience.value.isEmpty {
                lines.append("The audience is \(w.audience.value).")
            }
            if !w.brandTerms.value.isEmpty {
                lines.append("Use this site's own capitalization for brand/product terms when they appear: \(w.brandTerms.value.joined(separator: ", ")).")
            }
            if hasSignal(w.avoidPhrases), !w.avoidPhrases.value.isEmpty {
                lines.append("Never use these words or phrases: \(w.avoidPhrases.value.joined(separator: ", ")).")
            }
        }
        if let businessType, !businessType.isEmpty {
            lines.append("This is the website of a \(businessType).")
        }
        guard !lines.isEmpty else { return nil }
        return (["Match this site's voice:"] + lines).joined(separator: "\n")
    }

    /// A `Learned` value counts only if the user set it or it was inferred from real samples.
    static func hasSignal<V>(_ learned: Learned<V>) -> Bool {
        learned.isOverridden || learned.sampleSize.map { $0 > 0 } == true
    }
}

/// Reads `BUSINESS_TYPE` from the site's `Source/.site-config`, the same key the markdown
/// skills used. `nil` when the file or key is absent.
public enum SiteBusinessType {
    public static func read(sourceDirectory: URL) -> String? {
        let url = sourceDirectory.appendingPathComponent(".site-config")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return SiteConfigFile.value(forKey: "BUSINESS_TYPE", in: contents)
    }
}
```

Note: `brandTerms` intentionally skips the `hasSignal` check beyond non-emptiness, matching `AltTextPromptBuilder`'s existing behavior (a non-empty term list is signal regardless of sample size).

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter BrandVoiceGuidanceTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/BrandVoiceGuidance.swift Tests/AnglesiteCoreTests/BrandVoiceGuidanceTests.swift
git commit -m "feat(core): BrandVoiceGuidance preamble + SiteBusinessType reader (#465)"
```

---

### Task 3: `BrandVoiceInterview` answers→overrides mapping

**Files:**
- Create: `Sources/AnglesiteCore/BrandVoiceInterview.swift`
- Test: `Tests/AnglesiteCoreTests/BrandVoiceInterviewTests.swift`

**Interfaces:**
- Consumes: `ProjectConventions`, `OverrideValue` (Task 1).
- Produces: `BrandVoiceAnswers { audience: String, toneWords: [String], brandTerms: [String], avoidPhrases: [String] }`; `BrandVoiceInterview.apply(_ answers: BrandVoiceAnswers, to: ProjectConventions) -> ProjectConventions`; `BrandVoiceInterview.list(_ raw: String?) -> [String]` (comma-split helper reused by the chat tool and GUI).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/BrandVoiceInterviewTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct BrandVoiceInterviewTests {
    @Test func appliesNonEmptyAnswersAsOverrides() {
        let answers = BrandVoiceAnswers(
            audience: "home bakers",
            toneWords: ["warm", "expert", "playful"],
            brandTerms: ["SourdoughLab"],
            avoidPhrases: ["artisanal"]
        )
        let c = BrandVoiceInterview.apply(answers, to: .empty)
        #expect(c.writing.audience.value == "home bakers")
        #expect(c.writing.audience.isOverridden)
        #expect(c.writing.toneDescriptors.value == ["warm", "expert", "playful"])
        #expect(c.writing.brandTerms.value == ["SourdoughLab"])
        #expect(c.writing.avoidPhrases.value == ["artisanal"])
    }

    /// Empty answers must not clobber existing (possibly inferred) values with empty overrides.
    @Test func emptyAnswersLeaveFieldsUntouched() {
        var existing = ProjectConventions.empty
        existing.writing.toneDescriptors = Learned(value: ["calm"], source: .inferred(confidence: 0.7), sampleSize: 9)
        let answers = BrandVoiceAnswers(audience: "", toneWords: [], brandTerms: [], avoidPhrases: [])
        let c = BrandVoiceInterview.apply(answers, to: existing)
        #expect(c.writing.toneDescriptors.value == ["calm"])
        #expect(!c.writing.toneDescriptors.isOverridden)
        #expect(c.writing.audience.value == "")
    }

    @Test func listSplitsAndTrims() {
        #expect(BrandVoiceInterview.list(" warm, expert ,playful ") == ["warm", "expert", "playful"])
        #expect(BrandVoiceInterview.list(nil) == [])
        #expect(BrandVoiceInterview.list("  ") == [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter BrandVoiceInterviewTests`
Expected: FAIL — cannot find `BrandVoiceAnswers` in scope.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/BrandVoiceInterview.swift
import Foundation

/// Answers to the 5-question brand-voice interview (ported from the copy-edit skill):
/// audience, three-ish personality words, brand terms, phrases to avoid. Formality is
/// captured as tone words rather than a separate axis.
public struct BrandVoiceAnswers: Sendable, Equatable {
    public var audience: String
    public var toneWords: [String]
    public var brandTerms: [String]
    public var avoidPhrases: [String]

    public init(audience: String, toneWords: [String], brandTerms: [String], avoidPhrases: [String]) {
        self.audience = audience
        self.toneWords = toneWords
        self.brandTerms = brandTerms
        self.avoidPhrases = avoidPhrases
    }
}

/// Pure mapping from interview answers to `.userOverride` convention writes. Only non-empty
/// answers are applied, so a partial interview never erases inferred signal.
public enum BrandVoiceInterview {
    public static func apply(_ answers: BrandVoiceAnswers, to conventions: ProjectConventions) -> ProjectConventions {
        var out = conventions
        let audience = answers.audience.trimmingCharacters(in: .whitespacesAndNewlines)
        if !audience.isEmpty { out.apply(.audience(audience)) }
        if !answers.toneWords.isEmpty { out.apply(.toneDescriptors(answers.toneWords)) }
        if !answers.brandTerms.isEmpty { out.apply(.brandTerms(answers.brandTerms)) }
        if !answers.avoidPhrases.isEmpty { out.apply(.avoidPhrases(answers.avoidPhrases)) }
        return out
    }

    /// Comma-separated string → trimmed, non-empty items. Shared by the chat tool and GUI form.
    public static func list(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter BrandVoiceInterviewTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/BrandVoiceInterview.swift Tests/AnglesiteCoreTests/BrandVoiceInterviewTests.swift
git commit -m "feat(core): BrandVoiceInterview answers-to-overrides mapping (#465)"
```

---

### Task 4: Voice front-doors — `SaveBrandVoiceTool` (chat) + interview sheet (GUI)

**Files:**
- Create: `Sources/AnglesiteCore/SaveBrandVoiceTool.swift`
- Create: `Sources/AnglesiteApp/BrandVoiceInterviewView.swift`
- Modify: `Sources/AnglesiteCore/FoundationModelAssistant.swift` (add `conventionsStore` dependency)
- Modify: `Sources/AnglesiteApp/ProjectStyleGuideView.swift` (launch button + sheet)
- Modify: `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift` (thread the store into the assistant)
- Test: `Tests/AnglesiteCoreTests/SaveBrandVoiceToolTests.swift`

**Interfaces:**
- Consumes: `BrandVoiceAnswers`, `BrandVoiceInterview.apply/list` (Task 3), `ProjectConventionsStore` (existing: `actor`, `init(configDirectory:)`, `func load() -> ProjectConventions?`, `func save(_:)`).
- Produces: `SaveBrandVoiceTool` FM tool (`toolName = "saveBrandVoice"`); `FoundationModelAssistant.init` gains `conventionsStore: ProjectConventionsStore? = nil`; pure helper `SaveBrandVoiceReply.confirmation(for: BrandVoiceAnswers) -> String`.

- [ ] **Step 1: Write the failing test (pure helpers only — the Tool itself is gated)**

```swift
// Tests/AnglesiteCoreTests/SaveBrandVoiceToolTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct SaveBrandVoiceToolTests {
    @Test func confirmationNamesWhatWasSaved() {
        let answers = BrandVoiceAnswers(
            audience: "home bakers", toneWords: ["warm"], brandTerms: [], avoidPhrases: ["cheap"])
        let reply = SaveBrandVoiceReply.confirmation(for: answers)
        #expect(reply.contains("audience"))
        #expect(reply.contains("tone"))
        #expect(reply.contains("phrases to avoid"))
        #expect(!reply.contains("brand terms"))
    }

    @Test func emptyAnswersYieldNothingSavedReply() {
        let answers = BrandVoiceAnswers(audience: "", toneWords: [], brandTerms: [], avoidPhrases: [])
        #expect(SaveBrandVoiceReply.confirmation(for: answers).contains("didn't save"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SaveBrandVoiceToolTests`
Expected: FAIL — cannot find `SaveBrandVoiceReply`.

- [ ] **Step 3: Implement the tool**

```swift
// Sources/AnglesiteCore/SaveBrandVoiceTool.swift
import Foundation

/// Pure reply strings for the brand-voice tool, non-gated for CI tests.
public enum SaveBrandVoiceReply {
    public static func confirmation(for answers: BrandVoiceAnswers) -> String {
        var saved: [String] = []
        if !answers.audience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { saved.append("audience") }
        if !answers.toneWords.isEmpty { saved.append("tone") }
        if !answers.brandTerms.isEmpty { saved.append("brand terms") }
        if !answers.avoidPhrases.isEmpty { saved.append("phrases to avoid") }
        guard !saved.isEmpty else {
            return "I didn't save anything — I need at least one answer (audience, tone words, brand terms, or phrases to avoid)."
        }
        return "Saved this site's brand voice (\(saved.joined(separator: ", "))). Future copy suggestions will match it."
    }
}

#if compiler(>=6.4)
import FoundationModels

/// Chat front-door for the brand-voice interview (#465): the model interviews the owner in
/// conversation, then calls this once with the collected answers. Writes `.userOverride`
/// entries via `ProjectConventionsStore` — the same store the Style Guide inspector edits.
public struct SaveBrandVoiceTool: Tool, Sendable {
    public static let toolName = "saveBrandVoice"
    public let name = SaveBrandVoiceTool.toolName
    public let description = "Save the site's brand voice after interviewing the owner. Before calling, ask the owner (one question at a time): who the site speaks to, three personality words for the tone, brand/product terms with exact capitalization, and words or phrases to avoid."

    @Generable
    public struct Arguments {
        @Guide(description: "Who the site speaks to, in the owner's words.")
        public var audience: String?
        @Guide(description: "About three personality words, comma-separated (e.g. 'warm, expert, playful').")
        public var toneWords: String?
        @Guide(description: "Brand/product terms with their exact capitalization, comma-separated.")
        public var brandTerms: String?
        @Guide(description: "Words or phrases the owner never wants used, comma-separated.")
        public var avoidPhrases: String?
    }

    private let store: ProjectConventionsStore
    public init(store: ProjectConventionsStore) { self.store = store }

    public func call(arguments: Arguments) async throws -> String {
        let answers = BrandVoiceAnswers(
            audience: arguments.audience ?? "",
            toneWords: BrandVoiceInterview.list(arguments.toneWords),
            brandTerms: BrandVoiceInterview.list(arguments.brandTerms),
            avoidPhrases: BrandVoiceInterview.list(arguments.avoidPhrases)
        )
        let reply = SaveBrandVoiceReply.confirmation(for: answers)
        guard reply.contains("Saved") else { return reply }
        let current = await store.load() ?? .empty
        await store.save(BrandVoiceInterview.apply(answers, to: current))
        return reply
    }
}
#endif
```

- [ ] **Step 4: Wire into `FoundationModelAssistant`**

In `Sources/AnglesiteCore/FoundationModelAssistant.swift`:
- Add stored property and init parameter (after `integrationService`, before `maxRetainedTurns`): `conventionsStore: ProjectConventionsStore? = nil`, assigned `self.conventionsStore = conventionsStore`.
- In `conversationTools(for:includeSpotlight:)`, after the `integrationService` block:

```swift
        if let conventionsStore {
            tools.append(SaveBrandVoiceTool(store: conventionsStore))
        }
```

- In `attachedToolNames`, after the `integrationService` block:

```swift
        if conventionsStore != nil {
            names.append(SaveBrandVoiceTool.toolName)
        }
```

In `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift`, extend the `AssistantBuilder` closure/signature to accept and pass the site's existing `ProjectConventionsStore` (the same instance `SiteWindowModel` creates for the Style Guide, constructed with the site's `configDirectory`) into `FoundationModelAssistant(conventionsStore:)`. Follow how `integrationService` is threaded through the builder today — same shape, one more parameter.

- [ ] **Step 5: GUI interview sheet**

```swift
// Sources/AnglesiteApp/BrandVoiceInterviewView.swift
import SwiftUI
import AnglesiteCore

/// The 5-question brand-voice interview as a form (#465). Writes `.userOverride` entries via
/// the same `ProjectConventionsStore` the Style Guide inspector uses.
struct BrandVoiceInterviewView: View {
    let store: ProjectConventionsStore
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var audience = ""
    @State private var toneWords = ""
    @State private var brandTerms = ""
    @State private var avoidPhrases = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Brand Voice").font(.title2.bold())
            Text("A few questions so copy suggestions sound like you. Leave anything blank to skip it.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Who does this site speak to?", text: $audience, prompt: Text("e.g. busy parents in Oakland"))
                TextField("Three personality words", text: $toneWords, prompt: Text("e.g. warm, expert, playful"))
                TextField("Brand terms (exact capitalization)", text: $brandTerms, prompt: Text("e.g. SourdoughLab"))
                TextField("Words or phrases to avoid", text: $avoidPhrases, prompt: Text("e.g. artisanal, world-class"))
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Voice") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(answers.audience.isEmpty && answers.toneWords.isEmpty
                              && answers.brandTerms.isEmpty && answers.avoidPhrases.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 360)
    }

    private var answers: BrandVoiceAnswers {
        BrandVoiceAnswers(
            audience: audience.trimmingCharacters(in: .whitespacesAndNewlines),
            toneWords: BrandVoiceInterview.list(toneWords),
            brandTerms: BrandVoiceInterview.list(brandTerms),
            avoidPhrases: BrandVoiceInterview.list(avoidPhrases)
        )
    }

    private func save() async {
        let current = await store.load() ?? .empty
        await store.save(BrandVoiceInterview.apply(answers, to: current))
        onSaved()
        dismiss()
    }
}
```

In `Sources/AnglesiteApp/ProjectStyleGuideView.swift`: add a "Set Up Brand Voice…" button (toolbar or header row of the existing view) that toggles `@State private var interviewPresented = false`, plus `.sheet(isPresented: $interviewPresented) { BrandVoiceInterviewView(store: <the view's model's store>, onSaved: { <trigger the model's existing reload, e.g. seedFromDisk()> }) }`. `ProjectConventionsModel` already owns the store the view edits through — expose it (or add a `presentInterview` hook on the model) rather than constructing a second store.

- [ ] **Step 6: Run tests + build**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SaveBrandVoiceToolTests`
Expected: PASS (2 tests). Then run the full suite (`swift test --package-path .`) — all PASS (the assistant init change is source-compatible; fix any test constructing `FoundationModelAssistant` positionally if one exists).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/SaveBrandVoiceTool.swift Sources/AnglesiteCore/FoundationModelAssistant.swift Sources/AnglesiteApp/BrandVoiceInterviewView.swift Sources/AnglesiteApp/ProjectStyleGuideView.swift Sources/AnglesiteApp/SiteAssistantSessionFactory.swift Tests/AnglesiteCoreTests/SaveBrandVoiceToolTests.swift
git commit -m "feat: brand-voice interview front-doors — saveBrandVoice chat tool + style-guide sheet (#465)"
```

---

### Task 5: `Frontmatter` parser + `SiteContentChunker`

> **AMENDMENT (execution, 2026-07-10):** `Sources/AnglesiteCore/Frontmatter.swift` already exists (PR #401, #275/#346) with `Frontmatter.parse(_:) -> [String: FrontmatterValue]`, 9 production consumers and 14 tests. Do NOT create a new type or change `parse`. Instead: (1) add `public static func body(_ source: String) -> String` to the existing `Frontmatter` enum — everything after the closing `---` fence; the whole input when unfenced or unterminated; (2) the chunker gets fields from the existing `Frontmatter.parse` (title via the `.string` case of `FrontmatterValue`) and the body via the new accessor; (3) the plan's `FrontmatterTests.swift` new-file steps are replaced by body-accessor tests appended to the existing `Tests/AnglesiteCoreTests/FrontmatterTests.swift`. Task 14 amended accordingly.

**Files:**
- Modify: `Sources/AnglesiteCore/Frontmatter.swift` (add `body(_:)` accessor only)
- Create: `Sources/AnglesiteCore/SiteContentChunker.swift`
- Test: `Tests/AnglesiteCoreTests/FrontmatterTests.swift` (append body tests)
- Test: `Tests/AnglesiteCoreTests/SiteContentChunkerTests.swift`

**Interfaces:**
- Consumes: existing `Frontmatter.parse(_:) -> [String: FrontmatterValue]`.
- Produces:
  - `Frontmatter.body(_ source: String) -> String` — everything after the closing fence (whole input when unfenced/unterminated).
  - `ContentChunk { route: String, title: String?, filePath: String /* project-relative */, text: String, truncated: Bool }`, `Identifiable` via `id == filePath`.
  - `SiteContentChunker.maxChunkCharacters = 2_000`
  - `SiteContentChunker.chunks(sourceDirectory: URL, fileManager: FileManager = .default) -> [ContentChunk]` — scans `src/content/**/*.{md,mdoc}` + `src/pages/**/*.{astro,md,mdoc}`, sorted by `route`, empty-text files skipped.
  - Pure helpers: `SiteContentChunker.plainText(markdown: String) -> String`, `plainText(astro: String) -> String`, `route(forRelativePath: String) -> String`, `capped(_ text: String) -> (text: String, truncated: Bool)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/FrontmatterTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct FrontmatterTests {
    @Test func parsesFieldsAndBody() {
        let src = "---\ntitle: Our Story\ndescription: How we started\n---\n\n# Hello\nBody text."
        let (fields, body) = Frontmatter.parse(src)
        #expect(fields["title"] == "Our Story")
        #expect(fields["description"] == "How we started")
        #expect(body.contains("Body text."))
        #expect(!body.contains("title:"))
    }

    @Test func unfencedInputIsAllBody() {
        let (fields, body) = Frontmatter.parse("just text")
        #expect(fields.isEmpty)
        #expect(body == "just text")
    }

    @Test func stripsQuotesFromValues() {
        let (fields, _) = Frontmatter.parse("---\ntitle: \"Quoted Title\"\n---\nx")
        #expect(fields["title"] == "Quoted Title")
    }
}
```

```swift
// Tests/AnglesiteCoreTests/SiteContentChunkerTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct SiteContentChunkerTests {
    @Test func markdownPlainTextStripsSyntax() {
        let text = SiteContentChunker.plainText(
            markdown: "# Heading\n\nSome **bold** and a [link](https://x.test) here.\n- item")
        #expect(!text.contains("#"))
        #expect(!text.contains("**"))
        #expect(text.contains("link"))
        #expect(!text.contains("https://x.test"))
        #expect(text.contains("Heading"))
    }

    @Test func astroPlainTextStripsFenceTagsAndExpressions() {
        let src = "---\nimport Card from '../components/Card.astro'\n---\n<h1>Welcome</h1>\n<Card title=\"x\" />\n<p>We bake {daily.count} loaves.</p>\n<style>h1 { color: red }</style>\n<script>console.log(1)</script>"
        let text = SiteContentChunker.plainText(astro: src)
        #expect(text.contains("Welcome"))
        #expect(text.contains("We bake"))
        #expect(!text.contains("import Card"))
        #expect(!text.contains("<h1>"))
        #expect(!text.contains("color: red"))
        #expect(!text.contains("console.log"))
        #expect(!text.contains("{daily.count}"))
    }

    @Test func routesDeriveFromRelativePaths() {
        #expect(SiteContentChunker.route(forRelativePath: "src/pages/index.astro") == "/")
        #expect(SiteContentChunker.route(forRelativePath: "src/pages/about.astro") == "/about")
        #expect(SiteContentChunker.route(forRelativePath: "src/pages/services/menu.md") == "/services/menu")
        #expect(SiteContentChunker.route(forRelativePath: "src/content/posts/my-trip.mdoc") == "/posts/my-trip")
    }

    @Test func cappingMarksTruncation() {
        let long = String(repeating: "a", count: SiteContentChunker.maxChunkCharacters + 50)
        let (text, truncated) = SiteContentChunker.capped(long)
        #expect(truncated)
        #expect(text.count <= SiteContentChunker.maxChunkCharacters + 1) // +1 for the ellipsis
        let (short, shortTruncated) = SiteContentChunker.capped("hello")
        #expect(short == "hello")
        #expect(!shortTruncated)
    }

    @Test func scansSourceTreeAndSkipsEmpty() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("chunker-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("src/pages"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("src/content/posts"), withIntermediateDirectories: true)
        try "---\ntitle: About\n---\nWe are a bakery."
            .write(to: dir.appendingPathComponent("src/pages/about.md"), atomically: true, encoding: .utf8)
        try "---\ntitle: Trip\n---\nWent to the coast."
            .write(to: dir.appendingPathComponent("src/content/posts/trip.mdoc"), atomically: true, encoding: .utf8)
        try "---\ntitle: Empty\n---\n"
            .write(to: dir.appendingPathComponent("src/pages/empty.md"), atomically: true, encoding: .utf8)
        let chunks = SiteContentChunker.chunks(sourceDirectory: dir)
        #expect(chunks.count == 2)
        #expect(chunks.map(\.route) == ["/about", "/posts/trip"]) // sorted by route
        #expect(chunks[0].title == "About")
        #expect(chunks[0].filePath == "src/pages/about.md")
        #expect(chunks[0].text.contains("bakery"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter "FrontmatterTests|SiteContentChunkerTests"`
Expected: FAIL — cannot find `Frontmatter` / `SiteContentChunker`.

- [ ] **Step 3: Implement `Frontmatter`**

```swift
// Sources/AnglesiteCore/Frontmatter.swift
import Foundation

/// Minimal frontmatter reader for `.md`/`.mdoc`/`.astro` sources: top-level `key: value` pairs
/// between `---` fences. Not a YAML parser — nested structures are ignored, which is all the
/// content-help features need (title/description/tags). Values keep their raw string form minus
/// surrounding quotes.
public enum Frontmatter {
    public static func parse(_ contents: String) -> (fields: [String: String], body: String) {
        let lines = contents.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], contents)
        }
        var fields: [String: String] = [:]
        var index = 1
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                let body = lines[(index + 1)...].joined(separator: "\n")
                return (fields, body)
            }
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                if !key.isEmpty { fields[key] = value }
            }
            index += 1
        }
        // Unterminated fence: treat the whole input as body (malformed file, don't eat content).
        return ([:], contents)
    }
}
```

- [ ] **Step 4: Implement `SiteContentChunker`**

```swift
// Sources/AnglesiteCore/SiteContentChunker.swift
import Foundation

/// One page/post of a site reduced to capped plain text for a single FM call (#465). `filePath`
/// is project-relative (e.g. `src/pages/about.astro`) so findings can be applied back to disk.
public struct ContentChunk: Sendable, Equatable, Identifiable {
    public var id: String { filePath }
    public let route: String
    public let title: String?
    public let filePath: String
    public let text: String
    public let truncated: Bool

    public init(route: String, title: String?, filePath: String, text: String, truncated: Bool) {
        self.route = route
        self.title = title
        self.filePath = filePath
        self.text = text
        self.truncated = truncated
    }
}

/// Deterministic whole-site enumeration for the content-help capabilities: scans the `Source/`
/// tree directly (the same filesystem truth `SiteContentGraph` is populated from), extracts
/// plain text per file, and hard-caps each chunk so every FM call fits the ~4K on-device window
/// (the spec's chunk-first strategy). Pure string helpers are separated for CI unit tests.
public enum SiteContentChunker {
    /// Matches `FoundationModelAssistant.maxPageContentCharacters` — a char-based token proxy.
    public static let maxChunkCharacters = 2_000

    static let contentExtensions: Set<String> = ["md", "mdoc"]
    static let pageExtensions: Set<String> = ["astro", "md", "mdoc"]

    public static func chunks(sourceDirectory: URL, fileManager: FileManager = .default) -> [ContentChunk] {
        var chunks: [ContentChunk] = []
        for (subdir, extensions) in [("src/content", contentExtensions), ("src/pages", pageExtensions)] {
            let root = sourceDirectory.appendingPathComponent(subdir)
            guard let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                guard extensions.contains(url.pathExtension.lowercased()),
                      let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let relative = subdir + "/" + relativePath(of: url, under: root)
                let (fields, body) = Frontmatter.parse(contents)
                let raw = url.pathExtension.lowercased() == "astro"
                    ? plainText(astro: contents) : plainText(markdown: body)
                guard !raw.isEmpty else { continue }
                let (text, truncated) = capped(raw)
                chunks.append(ContentChunk(
                    route: route(forRelativePath: relative),
                    title: fields["title"],
                    filePath: relative,
                    text: text,
                    truncated: truncated
                ))
            }
        }
        return chunks.sorted { $0.route < $1.route }
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
    }

    /// `src/pages/about.astro` → `/about`; `src/pages/index.astro` → `/`;
    /// `src/content/posts/my-trip.mdoc` → `/posts/my-trip`.
    public static func route(forRelativePath relative: String) -> String {
        var path = relative
        for prefix in ["src/pages/", "src/content/"] where path.hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
        }
        path = (path as NSString).deletingPathExtension
        if path == "index" || path.isEmpty { return "/" }
        if path.hasSuffix("/index") { path = String(path.dropLast("/index".count)) }
        return "/" + path
    }

    /// Frontmatter-stripped markdown → readable text: link labels kept (URLs dropped), heading
    /// markers / emphasis / list bullets / code fences removed. Enough for a copy audit; not a
    /// markdown renderer.
    public static func plainText(markdown body: String) -> String {
        var text = body
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^```.*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
        return collapsed(text)
    }

    /// `.astro` source → inline human text: frontmatter fence, `<script>`/`<style>` blocks,
    /// tags, and `{…}` expressions removed. A tag-strip extractor, not an HTML parser — the
    /// spec's v1 answer to the "no HTML→text in Core" gap.
    public static func plainText(astro source: String) -> String {
        var text = source
        text = text.replacingOccurrences(
            of: #"\A---[\s\S]*?^---\s*$"#, with: "",
            options: [.regularExpression], range: nil)
        for block in ["script", "style"] {
            text = text.replacingOccurrences(
                of: "<\(block)[\\s\\S]*?</\(block)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: " ", options: .regularExpression)
        return collapsed(text)
    }

    public static func capped(_ text: String) -> (text: String, truncated: Bool) {
        guard text.count > maxChunkCharacters else { return (text, false) }
        return (String(text.prefix(maxChunkCharacters)) + "…", true)
    }

    private static func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

Note: if the multiline-anchored frontmatter regex in `plainText(astro:)` misbehaves, replace it with a line-based strip using the same fence-walk as `Frontmatter.parse` — behavior, not mechanism, is what the tests pin.

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter "FrontmatterTests|SiteContentChunkerTests"`
Expected: PASS (8 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/Frontmatter.swift Sources/AnglesiteCore/SiteContentChunker.swift Tests/AnglesiteCoreTests/FrontmatterTests.swift Tests/AnglesiteCoreTests/SiteContentChunkerTests.swift
git commit -m "feat(core): Frontmatter parser + SiteContentChunker whole-site enumeration (#465)"
```

---

### Task 6: `ContentAssistantFactory` — the tier seam

**Files:**
- Create: `Sources/AnglesiteCore/ContentAssistantFactory.swift`
- Test: `Tests/AnglesiteCoreTests/ContentAssistantFactoryTests.swift`

**Interfaces:**
- Consumes: `FoundationModelTier`, `FoundationModelAssistant`, `ContentAssistant`.
- Produces: `ContentAssistantFactory.make(tier: FoundationModelTier) -> (any ContentAssistant)?` — THE shared seam with #464. Every later task's generator calls this; none construct `FoundationModelAssistant` directly.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/ContentAssistantFactoryTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct ContentAssistantFactoryTests {
    @Test func makeReturnsBackendMatchingToolchain() {
        let assistant = ContentAssistantFactory.make(tier: .privateCloudCompute)
        #if compiler(>=6.4)
        #expect(assistant != nil)
        #expect(assistant?.capabilities.providerName == "Private Cloud Compute")
        #else
        #expect(assistant == nil)
        #endif
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ContentAssistantFactoryTests`
Expected: FAIL — cannot find `ContentAssistantFactory`.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/ContentAssistantFactory.swift
import Foundation

/// The shared model-tier seam for content-help capabilities (#464/#465). Every heavy generation
/// path obtains its backend HERE with a requested `FoundationModelTier` — today `.privateCloudCompute`
/// is stubbed onto the on-device session inside `FoundationModelAssistant`; when real PCC (or
/// slice 5's escalation) lands, this factory is the one place that changes. `nil` below the
/// Xcode-27 toolchain (no FoundationModels — see #128), matching `SiteGraphExplainerFactory`.
public enum ContentAssistantFactory {
    public static func make(tier: FoundationModelTier) -> (any ContentAssistant)? {
        #if compiler(>=6.4)
        return FoundationModelAssistant(tier: tier)
        #else
        return nil
        #endif
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ContentAssistantFactoryTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ContentAssistantFactory.swift Tests/AnglesiteCoreTests/ContentAssistantFactoryTests.swift
git commit -m "feat(core): ContentAssistantFactory tier seam shared with #464 (#465)"
```

---

## Phase B — Copy-edit

### Task 7: Copy-edit pure core — prompt, report aggregation, rewrite applier

**Files:**
- Create: `Sources/AnglesiteCore/CopyEditReport.swift`
- Create: `Sources/AnglesiteCore/CopyEditPrompt.swift`
- Create: `Sources/AnglesiteCore/CopyRewriteApplier.swift`
- Test: `Tests/AnglesiteCoreTests/CopyEditCoreTests.swift`

**Interfaces:**
- Consumes: `ContentChunk` (Task 5).
- Produces:
  - `CopyFindingSeverity: Int` (`high=0, medium=1, low=2`, `Comparable`, `init(label: String)` defaulting unknown → `.low`)
  - `CopyFindingDraft { category, severity, excerpt, issue, suggestedRewrite: String }` — the non-gated twin of the `@Generable` output (Task 8 maps Generated→Draft above/below the gate boundary).
  - `CopyFinding { id, route, title: String?, filePath, category, severity: CopyFindingSeverity, excerpt, issue, suggestedRewrite }`, `Identifiable`, `id = "\(filePath)#\(index)"`.
  - `CopyEditReport { findings: [CopyFinding], auditedCount: Int, skippedRoutes: [String] }`
  - `CopyEditReportBuilder.report(results: [(chunk: ContentChunk, drafts: [CopyFindingDraft]?)]) -> CopyEditReport` — `nil` drafts = chunk skipped (FM failure); findings sorted severity-then-route.
  - `CopyEditPrompt.build(chunk: ContentChunk, preamble: String?) -> String` — the 10-point checklist prompt.
  - `CopyRewriteApplier.apply(excerpt: String, rewrite: String, contents: String) -> String?` — first exact occurrence replaced; `nil` when the excerpt isn't found verbatim (Apply then disabled per spec §5.1).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/CopyEditCoreTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct CopyEditCoreTests {
    private func chunk(route: String, filePath: String) -> ContentChunk {
        ContentChunk(route: route, title: nil, filePath: filePath, text: "Welcome to our site.", truncated: false)
    }

    @Test func severityParsesLabelsAndDefaultsLow() {
        #expect(CopyFindingSeverity(label: "high") == .high)
        #expect(CopyFindingSeverity(label: "MEDIUM") == .medium)
        #expect(CopyFindingSeverity(label: "whatever") == .low)
        #expect(CopyFindingSeverity.high < CopyFindingSeverity.low)
    }

    @Test func reportSortsBySeverityThenRouteAndTracksSkips() {
        let a = chunk(route: "/a", filePath: "src/pages/a.md")
        let b = chunk(route: "/b", filePath: "src/pages/b.md")
        let c = chunk(route: "/c", filePath: "src/pages/c.md")
        let low = CopyFindingDraft(category: "clarity", severity: "low", excerpt: "x", issue: "i", suggestedRewrite: "r")
        let high = CopyFindingDraft(category: "cta", severity: "high", excerpt: "y", issue: "j", suggestedRewrite: "s")
        let report = CopyEditReportBuilder.report(results: [(a, [low]), (b, [high]), (c, nil)])
        #expect(report.auditedCount == 2)
        #expect(report.skippedRoutes == ["/c"])
        #expect(report.findings.map(\.route) == ["/b", "/a"]) // high first
        #expect(report.findings[0].id == "src/pages/b.md#0")
        #expect(report.findings[0].severity == .high)
    }

    @Test func promptContainsChecklistVoiceAndText() {
        let p = CopyEditPrompt.build(
            chunk: ContentChunk(route: "/about", title: "About", filePath: "src/pages/about.md",
                                text: "We provide synergistic solutions.", truncated: false),
            preamble: "Match this site's voice:\nWrite in a warm tone.")
        #expect(p.contains("call to action"))
        #expect(p.contains("warm tone"))
        #expect(p.contains("synergistic solutions"))
        #expect(p.contains("/about"))
        #expect(p.contains("verbatim")) // excerpt-quoting instruction
    }

    @Test func rewriteApplierReplacesFirstExactMatchOnly() {
        let contents = "Hello world. Hello world."
        let out = CopyRewriteApplier.apply(excerpt: "Hello world.", rewrite: "Hi there.", contents: contents)
        #expect(out == "Hi there. Hello world.")
        #expect(CopyRewriteApplier.apply(excerpt: "not present", rewrite: "x", contents: contents) == nil)
        #expect(CopyRewriteApplier.apply(excerpt: "", rewrite: "x", contents: contents) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter CopyEditCoreTests`
Expected: FAIL — cannot find `CopyFindingSeverity`.

- [ ] **Step 3: Implement report types + builder**

```swift
// Sources/AnglesiteCore/CopyEditReport.swift
import Foundation

public enum CopyFindingSeverity: Int, Sendable, Equatable, Comparable, CaseIterable {
    case high = 0, medium = 1, low = 2

    /// Model output is a free string under `@Guide` — parse defensively, unknown → `.low`.
    public init(label: String) {
        switch label.lowercased() {
        case "high": self = .high
        case "medium": self = .medium
        default: self = .low
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Non-gated twin of `GeneratedCopyFinding` so aggregation is CI-testable (the `@Generable`
/// type only exists on the Xcode-27 toolchain).
public struct CopyFindingDraft: Sendable, Equatable {
    public let category: String
    public let severity: String
    public let excerpt: String
    public let issue: String
    public let suggestedRewrite: String

    public init(category: String, severity: String, excerpt: String, issue: String, suggestedRewrite: String) {
        self.category = category
        self.severity = severity
        self.excerpt = excerpt
        self.issue = issue
        self.suggestedRewrite = suggestedRewrite
    }
}

public struct CopyFinding: Sendable, Equatable, Identifiable {
    public let id: String
    public let route: String
    public let title: String?
    public let filePath: String
    public let category: String
    public let severity: CopyFindingSeverity
    public let excerpt: String
    public let issue: String
    public let suggestedRewrite: String

    public init(id: String, route: String, title: String?, filePath: String, category: String,
                severity: CopyFindingSeverity, excerpt: String, issue: String, suggestedRewrite: String) {
        self.id = id
        self.route = route
        self.title = title
        self.filePath = filePath
        self.category = category
        self.severity = severity
        self.excerpt = excerpt
        self.issue = issue
        self.suggestedRewrite = suggestedRewrite
    }
}

/// Whole-site audit result. Per spec §5.1 a failed chunk degrades to `skippedRoutes` — the
/// report never aborts and never hides a gap.
public struct CopyEditReport: Sendable, Equatable {
    public let findings: [CopyFinding]
    public let auditedCount: Int
    public let skippedRoutes: [String]

    public init(findings: [CopyFinding], auditedCount: Int, skippedRoutes: [String]) {
        self.findings = findings
        self.auditedCount = auditedCount
        self.skippedRoutes = skippedRoutes
    }
}

public enum CopyEditReportBuilder {
    public static func report(results: [(chunk: ContentChunk, drafts: [CopyFindingDraft]?)]) -> CopyEditReport {
        var findings: [CopyFinding] = []
        var skipped: [String] = []
        var audited = 0
        for (chunk, drafts) in results {
            guard let drafts else {
                skipped.append(chunk.route)
                continue
            }
            audited += 1
            for (index, d) in drafts.enumerated() {
                findings.append(CopyFinding(
                    id: "\(chunk.filePath)#\(index)",
                    route: chunk.route,
                    title: chunk.title,
                    filePath: chunk.filePath,
                    category: d.category,
                    severity: CopyFindingSeverity(label: d.severity),
                    excerpt: d.excerpt,
                    issue: d.issue,
                    suggestedRewrite: d.suggestedRewrite
                ))
            }
        }
        findings.sort { ($0.severity, $0.route) < ($1.severity, $1.route) }
        return CopyEditReport(findings: findings, auditedCount: audited, skippedRoutes: skipped)
    }
}
```

(Tuple comparison on `(Severity, String)` requires `Comparable` conformance already declared. If the tuple form doesn't compile, use `findings.sort { $0.severity == $1.severity ? $0.route < $1.route : $0.severity < $1.severity }`.)

- [ ] **Step 4: Implement prompt + applier**

```swift
// Sources/AnglesiteCore/CopyEditPrompt.swift
import Foundation

/// The copy-edit skill's 10-point checklist as a guided-generation prompt (#465). Pure and
/// non-gated. Facts-only framing follows `SiteGraphExplainPrompt`: the model reviews ONLY the
/// provided page text and must quote excerpts verbatim so `CopyRewriteApplier` can find them.
public enum CopyEditPrompt {
    public static let checklist = """
    1. Clarity — would a first-time visitor instantly understand what this page offers?
    2. Benefits over features — does the copy say what the visitor gets, not just what the business does?
    3. Voice consistency — does the tone match the site's voice throughout?
    4. Calls to action — is there a clear next step, and is it compelling?
    5. Scannability — short paragraphs, meaningful headings, front-loaded sentences?
    6. Reader focus — more "you" than "we"?
    7. Jargon — any insider terms a customer wouldn't use?
    8. Social proof — are claims backed by specifics where possible?
    9. Missing information — anything a customer always needs (hours, location, pricing signals)?
    10. Mobile readability — any walls of text?
    """

    public static func build(chunk: ContentChunk, preamble: String?) -> String {
        var sections: [String] = []
        if let preamble { sections.append(preamble) }
        sections.append("""
        You are a copy editor reviewing one page of a small business's website against this checklist:
        \(checklist)

        Report up to 5 highest-impact findings for this page — if the copy is strong, report none. \
        For each finding: the checklist category, a severity (high, medium, or low), a short excerpt \
        quoted verbatim from the page text (copy it exactly, character for character), a one-sentence \
        plain-language issue, and a suggested rewrite in the site's voice. Base findings only on the \
        page text below; do not invent facts about the business.

        Page route: \(chunk.route)\(chunk.truncated ? "\n(Note: page text was truncated.)" : "")

        Page text:
        \(chunk.text)
        """)
        return sections.joined(separator: "\n\n")
    }
}
```

```swift
// Sources/AnglesiteCore/CopyRewriteApplier.swift
import Foundation

/// Deterministic apply for an accepted copy rewrite (spec §5.1, amended): replace the FIRST
/// exact occurrence of the model's quoted excerpt. `nil` (Apply disabled, rewrite offered
/// copy-to-clipboard) when the excerpt doesn't appear verbatim — never fuzzy-match, never
/// batch-rewrite.
public enum CopyRewriteApplier {
    public static func apply(excerpt: String, rewrite: String, contents: String) -> String? {
        guard !excerpt.isEmpty, let range = contents.range(of: excerpt) else { return nil }
        return contents.replacingCharacters(in: range, with: rewrite)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter CopyEditCoreTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/CopyEditReport.swift Sources/AnglesiteCore/CopyEditPrompt.swift Sources/AnglesiteCore/CopyRewriteApplier.swift Tests/AnglesiteCoreTests/CopyEditCoreTests.swift
git commit -m "feat(core): copy-edit pure core — checklist prompt, report builder, rewrite applier (#465)"
```

---

### Task 8: `@Generable` findings + gated `FoundationModelCopyEditAuditor`

**Files:**
- Modify: `Sources/AnglesiteCore/GenerableTypes.swift`
- Create: `Sources/AnglesiteCore/CopyEditAuditor.swift`
- Test: `Tests/AnglesiteCoreTests/CopyEditAuditorTests.swift`

**Interfaces:**
- Consumes: `ContentChunk`, `CopyEditPrompt`, `CopyEditReportBuilder`, `CopyFindingDraft` (Tasks 5/7), `ContentAssistantFactory` (Task 6).
- Produces:
  - `GeneratedCopyFinding` / `GeneratedPageCopyFindings` (gated, in `GenerableTypes.swift`).
  - `protocol CopyEditAuditing: Sendable { func audit(chunks: [ContentChunk], preamble: String?, siteID: String, siteDirectory: URL) async -> CopyEditReport }`
  - `CopyEditAuditorFactory.makeDefault() -> (any CopyEditAuditing)?` (non-gated; `nil` below 6.4).
  - `FoundationModelCopyEditAuditor` (gated): per-chunk `generateStructured` via `ContentAssistantFactory.make(tier: .privateCloudCompute)`; a thrown error marks that chunk skipped, never aborts the loop.

- [ ] **Step 1: Write the failing test (protocol + factory shape; FM path untestable on CI)**

```swift
// Tests/AnglesiteCoreTests/CopyEditAuditorTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct CopyEditAuditorTests {
    @Test func factoryMatchesToolchain() {
        let auditor = CopyEditAuditorFactory.makeDefault()
        #if compiler(>=6.4)
        #expect(auditor != nil)
        #else
        #expect(auditor == nil)
        #endif
    }

    /// The protocol is the app-side seam — a fake must be able to stand in for the FM auditor.
    @Test func fakeAuditorSatisfiesProtocol() async {
        struct FakeAuditor: CopyEditAuditing {
            func audit(chunks: [ContentChunk], preamble: String?, siteID: String, siteDirectory: URL) async -> CopyEditReport {
                CopyEditReportBuilder.report(results: chunks.map { ($0, []) })
            }
        }
        let chunk = ContentChunk(route: "/a", title: nil, filePath: "src/pages/a.md", text: "x", truncated: false)
        let report = await FakeAuditor().audit(
            chunks: [chunk], preamble: nil, siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(report.auditedCount == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter CopyEditAuditorTests`
Expected: FAIL — cannot find `CopyEditAuditorFactory`.

- [ ] **Step 3: Add the Generable types**

In `Sources/AnglesiteCore/GenerableTypes.swift`, alongside the existing gated types (match the file's existing gating — the `@Generable` structs live under `#if compiler(>=6.4)`):

```swift
@Generable
public struct GeneratedCopyFinding: Equatable, Sendable {
    @Guide(description: "Checklist category: clarity, benefits, voice, cta, scannability, reader-focus, jargon, social-proof, missing-info, or mobile.")
    public var category: String
    @Guide(description: "Severity: high, medium, or low.")
    public var severity: String
    @Guide(description: "Short excerpt of the problematic copy, quoted verbatim from the page text — exact characters, no paraphrase.")
    public var excerpt: String
    @Guide(description: "One-sentence plain-language description of the issue.")
    public var issue: String
    @Guide(description: "Suggested replacement copy in the site's voice.")
    public var suggestedRewrite: String
}

@Generable
public struct GeneratedPageCopyFindings: Equatable, Sendable {
    @Guide(description: "Up to 5 highest-impact findings for this page. Empty when the copy is strong.")
    public var findings: [GeneratedCopyFinding]
}
```

- [ ] **Step 4: Implement the auditor**

```swift
// Sources/AnglesiteCore/CopyEditAuditor.swift
import Foundation

/// Whole-site copy audit seam (#465). The FM implementation iterates chunks one guided-generation
/// call at a time (chunk-first — every call fits the on-device window); GUI/intents/tools depend
/// only on this protocol so tests can inject fakes.
public protocol CopyEditAuditing: Sendable {
    func audit(chunks: [ContentChunk], preamble: String?, siteID: String, siteDirectory: URL) async -> CopyEditReport
}

/// `nil` below the Xcode-27 toolchain — callers hide/disable the feature (pattern:
/// `SiteGraphExplainerFactory`).
public enum CopyEditAuditorFactory {
    public static func makeDefault() -> (any CopyEditAuditing)? {
        #if compiler(>=6.4)
        return FoundationModelCopyEditAuditor()
        #else
        return nil
        #endif
    }
}

#if compiler(>=6.4)
import FoundationModels

public struct FoundationModelCopyEditAuditor: CopyEditAuditing {
    public init() {}

    public func audit(chunks: [ContentChunk], preamble: String?, siteID: String, siteDirectory: URL) async -> CopyEditReport {
        // Heavy generation requests the PCC tier through the shared seam (#464); today that is
        // backed on-device, and chunking keeps each call correct at 4K regardless.
        guard let assistant = ContentAssistantFactory.make(tier: .privateCloudCompute) else {
            return CopyEditReportBuilder.report(results: chunks.map { ($0, nil) })
        }
        var results: [(chunk: ContentChunk, drafts: [CopyFindingDraft]?)] = []
        for chunk in chunks {
            do {
                let generated = try await assistant.generateStructured(
                    prompt: CopyEditPrompt.build(chunk: chunk, preamble: preamble),
                    context: AssistantContext(siteID: siteID, siteDirectory: siteDirectory),
                    resultType: GeneratedPageCopyFindings.self
                )
                results.append((chunk, generated.findings.map {
                    CopyFindingDraft(category: $0.category, severity: $0.severity,
                                     excerpt: $0.excerpt, issue: $0.issue,
                                     suggestedRewrite: $0.suggestedRewrite)
                }))
            } catch {
                // Partial results over aborts (spec §6): one failed page becomes a named skip.
                results.append((chunk, nil))
            }
        }
        return CopyEditReportBuilder.report(results: results)
    }
}
#endif
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter CopyEditAuditorTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/GenerableTypes.swift Sources/AnglesiteCore/CopyEditAuditor.swift Tests/AnglesiteCoreTests/CopyEditAuditorTests.swift
git commit -m "feat(core): FoundationModelCopyEditAuditor with Generable findings (#465)"
```

---

### Task 9: `ReviewCopyTool` + assistant wiring

**Files:**
- Create: `Sources/AnglesiteCore/ReviewCopyTool.swift`
- Modify: `Sources/AnglesiteCore/FoundationModelAssistant.swift` (add `copyEditAuditor` dependency)
- Modify: `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift` (pass `CopyEditAuditorFactory.makeDefault()`)
- Test: `Tests/AnglesiteCoreTests/ReviewCopyToolTests.swift`

**Interfaces:**
- Consumes: `CopyEditAuditing`, `CopyEditReport` (Task 8/7), `SiteContentChunker` (Task 5), `BrandVoiceGuidance`/`SiteBusinessType` (Task 2), `ProjectConventionsStore` (wired in Task 4).
- Produces: `ReviewCopyTool` (`toolName = "reviewCopy"`, `Arguments { route: String? }`); pure `ReviewCopyReply.text(for: CopyEditReport, capped: Int?) -> String`; `ReviewCopyTool.maxSiteChunks = 8`; `FoundationModelAssistant.init` gains `copyEditAuditor: (any CopyEditAuditing)? = nil`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/ReviewCopyToolTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct ReviewCopyToolTests {
    @Test func replySummarizesFindingsBySeverity() {
        let finding = CopyFinding(
            id: "src/pages/a.md#0", route: "/a", title: "A", filePath: "src/pages/a.md",
            category: "cta", severity: .high, excerpt: "Click here",
            issue: "Vague call to action.", suggestedRewrite: "Book your table today")
        let report = CopyEditReport(findings: [finding], auditedCount: 3, skippedRoutes: ["/b"])
        let text = ReviewCopyReply.text(for: report, capped: nil)
        #expect(text.contains("/a"))
        #expect(text.contains("Vague call to action."))
        #expect(text.contains("Book your table today"))
        #expect(text.contains("/b")) // skipped pages are named, not hidden
    }

    @Test func cleanReportSaysSo() {
        let report = CopyEditReport(findings: [], auditedCount: 2, skippedRoutes: [])
        #expect(ReviewCopyReply.text(for: report, capped: nil).contains("no copy issues"))
    }

    @Test func cappedAuditIsDisclosed() {
        let report = CopyEditReport(findings: [], auditedCount: 8, skippedRoutes: [])
        let text = ReviewCopyReply.text(for: report, capped: 8)
        #expect(text.contains("first 8"))
        #expect(text.contains("Review Copy")) // points at the GUI for the full audit
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ReviewCopyToolTests`
Expected: FAIL — cannot find `ReviewCopyReply`.

- [ ] **Step 3: Implement**

```swift
// Sources/AnglesiteCore/ReviewCopyTool.swift
import Foundation

/// Pure chat rendering of a `CopyEditReport`, non-gated for CI tests. `capped` is non-nil when
/// a site-wide audit was truncated to the tool's chunk budget (no silent caps — spec §6).
public enum ReviewCopyReply {
    public static func text(for report: CopyEditReport, capped: Int?) -> String {
        var lines: [String] = []
        if report.findings.isEmpty {
            lines.append("I found no copy issues across \(report.auditedCount) page\(report.auditedCount == 1 ? "" : "s") — the copy reads well.")
        } else {
            lines.append("Copy review (\(report.auditedCount) page\(report.auditedCount == 1 ? "" : "s") audited):")
            for f in report.findings {
                lines.append("• [\(severityLabel(f.severity))] \(f.route) — \(f.issue) Suggestion: \(f.suggestedRewrite)")
            }
        }
        if !report.skippedRoutes.isEmpty {
            lines.append("Skipped (couldn't review): \(report.skippedRoutes.joined(separator: ", ")).")
        }
        if let capped {
            lines.append("I reviewed the first \(capped) pages only — use Review Copy in the app for the full site.")
        }
        return lines.joined(separator: "\n")
    }

    static func severityLabel(_ s: CopyFindingSeverity) -> String {
        switch s {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        }
    }
}

#if compiler(>=6.4)
import FoundationModels

/// Chat front-door for the copy audit (#465). Page-scoped when `route` is given; otherwise a
/// site-wide pass capped at `maxSiteChunks` chunks (a chat turn shouldn't run for minutes — the
/// GUI report is the uncapped surface, and the cap is always disclosed in the reply).
public struct ReviewCopyTool: Tool, Sendable {
    public static let toolName = "reviewCopy"
    public static let maxSiteChunks = 8
    public let name = ReviewCopyTool.toolName
    public let description = "Review the site's written copy for clarity, tone, calls to action, and jargon. Pass a route (like '/about') for one page, or omit it to review the site."

    @Generable
    public struct Arguments {
        @Guide(description: "Page route to review (e.g. '/about'). Omit to review the whole site.")
        public var route: String?
    }

    private let auditor: any CopyEditAuditing
    private let conventionsStore: ProjectConventionsStore?
    private let siteID: String
    private let siteDirectory: URL

    public init(auditor: any CopyEditAuditing, conventionsStore: ProjectConventionsStore?,
                siteID: String, siteDirectory: URL) {
        self.auditor = auditor
        self.conventionsStore = conventionsStore
        self.siteID = siteID
        self.siteDirectory = siteDirectory
    }

    public func call(arguments: Arguments) async throws -> String {
        var chunks = SiteContentChunker.chunks(sourceDirectory: siteDirectory)
        var capped: Int? = nil
        if let route = arguments.route, !route.isEmpty {
            chunks = chunks.filter { $0.route == route }
            guard !chunks.isEmpty else { return "I couldn't find a page at \(route)." }
        } else if chunks.count > Self.maxSiteChunks {
            chunks = Array(chunks.prefix(Self.maxSiteChunks))
            capped = Self.maxSiteChunks
        }
        guard !chunks.isEmpty else { return "I couldn't find any pages or posts to review." }
        let conventions = await conventionsStore?.load()
        let preamble = BrandVoiceGuidance.preamble(
            conventions: conventions, businessType: SiteBusinessType.read(sourceDirectory: siteDirectory))
        let report = await auditor.audit(
            chunks: chunks, preamble: preamble, siteID: siteID, siteDirectory: siteDirectory)
        return ReviewCopyReply.text(for: report, capped: capped)
    }
}
#endif
```

- [ ] **Step 4: Wire into the assistant**

In `Sources/AnglesiteCore/FoundationModelAssistant.swift`: add `copyEditAuditor: (any CopyEditAuditing)? = nil` init parameter + stored property (next to `conventionsStore` from Task 4). In `conversationTools(for:includeSpotlight:)`:

```swift
        if let copyEditAuditor {
            tools.append(ReviewCopyTool(
                auditor: copyEditAuditor, conventionsStore: conventionsStore,
                siteID: context.siteID, siteDirectory: context.siteDirectory))
        }
```

In `attachedToolNames`: `if copyEditAuditor != nil { names.append(ReviewCopyTool.toolName) }`.

In `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift`: pass `copyEditAuditor: CopyEditAuditorFactory.makeDefault()` where the production `FoundationModelAssistant` is built.

- [ ] **Step 5: Run tests + full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ReviewCopyToolTests`
Expected: PASS (3 tests). Then the full suite — all PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/ReviewCopyTool.swift Sources/AnglesiteCore/FoundationModelAssistant.swift Sources/AnglesiteApp/SiteAssistantSessionFactory.swift Tests/AnglesiteCoreTests/ReviewCopyToolTests.swift
git commit -m "feat: reviewCopy chat tool wired into FoundationModelAssistant (#465)"
```

---

### Task 10: Copy-edit GUI (report view) + `ReviewCopyIntent`

**Files:**
- Create: `Sources/AnglesiteApp/CopyEditReportModel.swift`
- Create: `Sources/AnglesiteApp/CopyEditReportView.swift`
- Create: `Sources/AnglesiteIntents/ContentHelpIntents.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift` (present hook), `Sources/AnglesiteApp/SiteWindow.swift` (sheet), the commands file that hosts "Project Style Guide…" (menu item — find it with `grep -rn "Style Guide" Sources/AnglesiteApp`)
- Test: `Tests/AnglesiteCoreTests/ContentHelpDialogsTests.swift` (pure dialog strings live in Core so CI covers them; `AnglesiteIntentsTests` needs Xcode 27)

**Interfaces:**
- Consumes: `CopyEditAuditing`/`CopyEditAuditorFactory`, `CopyEditReport`/`CopyFinding`, `CopyRewriteApplier`, `SiteContentChunker`, `BrandVoiceGuidance`, `SiteBusinessType`, `ProjectConventionsStore`, `AnnotationStore.add(in:path:selector:text:sourceFile:)`, `SiteEntity` (has `.id`, `.displayName`, `.directory: URL?` = source dir).
- Produces: `CopyEditReportModel` (`@Observable @MainActor`, `Identifiable`), `CopyEditReportView`, `ReviewCopyIntent`, pure `ContentHelpDialogs` in a new Core file `Sources/AnglesiteCore/ContentHelpDialogs.swift`.

- [ ] **Step 1: Write the failing test for the dialogs**

```swift
// Tests/AnglesiteCoreTests/ContentHelpDialogsTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct ContentHelpDialogsTests {
    @Test func copyReviewDialogCountsAndSkips() {
        let d = ContentHelpDialogs.copyReview(findingCount: 3, pageCount: 5, skippedCount: 1, siteName: "SourdoughLab")
        #expect(d.contains("3"))
        #expect(d.contains("5"))
        #expect(d.contains("SourdoughLab"))
        #expect(d.contains("1"))
        let clean = ContentHelpDialogs.copyReview(findingCount: 0, pageCount: 4, skippedCount: 0, siteName: "S")
        #expect(clean.contains("no copy issues"))
    }

    @Test func unavailableDialogExplains() {
        #expect(ContentHelpDialogs.assistantUnavailable(feature: "Copy review").contains("Apple Intelligence"))
    }
}
```

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter ContentHelpDialogsTests` → FAIL (`ContentHelpDialogs` not found).

- [ ] **Step 2: Implement the dialogs (Core, pure)**

```swift
// Sources/AnglesiteCore/ContentHelpDialogs.swift
import Foundation

/// Pure dialog/summary strings shared by the content-help App Intents and GUI (#465), kept in
/// Core (pattern: `IntegrationDialogs`) so CI unit-tests them without the AppIntents runtime.
public enum ContentHelpDialogs {
    public static func copyReview(findingCount: Int, pageCount: Int, skippedCount: Int, siteName: String) -> String {
        var d: String
        if findingCount == 0 {
            d = "I found no copy issues across \(pageCount) page\(pageCount == 1 ? "" : "s") on \(siteName)."
        } else {
            d = "I found \(findingCount) copy suggestion\(findingCount == 1 ? "" : "s") across \(pageCount) page\(pageCount == 1 ? "" : "s") on \(siteName). Open Review Copy in Anglesite to apply them."
        }
        if skippedCount > 0 { d += " \(skippedCount) page\(skippedCount == 1 ? "" : "s") couldn't be reviewed." }
        return d
    }

    public static func assistantUnavailable(feature: String) -> String {
        "\(feature) needs Apple Intelligence, which isn't available on this Mac right now."
    }

    public static func socialPlanSaved(weeks: Int, siteName: String) -> String {
        "Saved a \(weeks)-week social media plan for \(siteName) to docs/social-calendar.md."
    }

    public static func repurposeSummary(postTitle: String, platformCount: Int, failedCount: Int) -> String {
        var d = "Drafted \(platformCount) platform post\(platformCount == 1 ? "" : "s") for \"\(postTitle)\"."
        if failedCount > 0 { d += " \(failedCount) platform\(failedCount == 1 ? "" : "s") couldn't fit their length limit." }
        return d
    }
}
```

Run the filter again → PASS (2 tests).

- [ ] **Step 3: Implement the model**

```swift
// Sources/AnglesiteApp/CopyEditReportModel.swift
import Foundation
import Observation
import AnglesiteCore

/// Drives the Review Copy sheet (#465): runs the chunked audit, tracks per-finding apply state,
/// and performs the deterministic excerpt-replacement apply. Depends only on `CopyEditAuditing`
/// so tests inject fakes; `auditor == nil` (pre-6.4 toolchain or Apple Intelligence off) renders
/// the disabled-with-explanation state per the LLM policy.
@Observable @MainActor
final class CopyEditReportModel: Identifiable {
    let siteID: String
    let sourceDirectory: URL
    private let auditor: (any CopyEditAuditing)?
    private let conventionsStore: ProjectConventionsStore

    var report: CopyEditReport?
    var running = false
    var appliedFindingIDs: Set<String> = []
    var annotatedFindingIDs: Set<String> = []
    var errorMessage: String?

    var unavailable: Bool { auditor == nil }

    init(siteID: String, sourceDirectory: URL, conventionsStore: ProjectConventionsStore,
         auditor: (any CopyEditAuditing)? = CopyEditAuditorFactory.makeDefault()) {
        self.siteID = siteID
        self.sourceDirectory = sourceDirectory
        self.conventionsStore = conventionsStore
        self.auditor = auditor
    }

    func run() async {
        guard let auditor, !running else { return }
        running = true
        defer { running = false }
        let chunks = SiteContentChunker.chunks(sourceDirectory: sourceDirectory)
        let conventions = await conventionsStore.load()
        let preamble = BrandVoiceGuidance.preamble(
            conventions: conventions,
            businessType: SiteBusinessType.read(sourceDirectory: sourceDirectory))
        report = await auditor.audit(chunks: chunks, preamble: preamble,
                                     siteID: siteID, siteDirectory: sourceDirectory)
    }

    /// Whether Apply can work: the excerpt must appear verbatim in the file right now.
    func canApply(_ finding: CopyFinding) -> Bool {
        guard !appliedFindingIDs.contains(finding.id),
              let contents = try? String(contentsOf: fileURL(finding), encoding: .utf8) else { return false }
        return CopyRewriteApplier.apply(excerpt: finding.excerpt, rewrite: finding.suggestedRewrite,
                                        contents: contents) != nil
    }

    func apply(_ finding: CopyFinding) {
        do {
            let url = fileURL(finding)
            let contents = try String(contentsOf: url, encoding: .utf8)
            guard let updated = CopyRewriteApplier.apply(
                excerpt: finding.excerpt, rewrite: finding.suggestedRewrite, contents: contents) else {
                errorMessage = "The page text changed since the review — this excerpt no longer matches."
                return
            }
            try updated.write(to: url, atomically: true, encoding: .utf8)
            appliedFindingIDs.insert(finding.id)
        } catch {
            errorMessage = "Couldn't apply the rewrite: \(error.localizedDescription)"
        }
    }

    func saveAsAnnotation(_ finding: CopyFinding) {
        do {
            try AnnotationStore.add(
                in: sourceDirectory,
                path: finding.route,
                selector: "",
                text: "Copy review [\(finding.category)]: \(finding.issue) Suggestion: \(finding.suggestedRewrite)",
                sourceFile: finding.filePath)
            annotatedFindingIDs.insert(finding.id)
        } catch {
            errorMessage = "Couldn't save the annotation: \(error.localizedDescription)"
        }
    }

    private func fileURL(_ finding: CopyFinding) -> URL {
        sourceDirectory.appendingPathComponent(finding.filePath)
    }
}
```

- [ ] **Step 4: Implement the view**

```swift
// Sources/AnglesiteApp/CopyEditReportView.swift
import SwiftUI
import AnglesiteCore

/// The Review Copy sheet (#465): findings grouped by page, severity-badged, each with
/// diff-confirmed Apply / Save as Annotation / Copy Rewrite. Never batch-applies.
struct CopyEditReportView: View {
    @Bindable var model: CopyEditReportModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirming: CopyFinding?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Review Copy").font(.title2.bold())
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 480)
        .task { if model.report == nil { await model.run() } }
        .alert("Copy Review", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog(
            "Apply this rewrite?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { finding in
            Button("Replace") { model.apply(finding); confirming = nil }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { finding in
            Text("“\(finding.excerpt)”\n\nbecomes\n\n“\(finding.suggestedRewrite)”")
        }
    }

    @ViewBuilder private var content: some View {
        if model.unavailable {
            ContentUnavailableView(
                "Apple Intelligence Required",
                systemImage: "sparkles",
                description: Text(ContentHelpDialogs.assistantUnavailable(feature: "Copy review")))
        } else if model.running && model.report == nil {
            VStack(spacing: 8) {
                ProgressView()
                Text("Reviewing your site's copy, page by page…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report = model.report {
            reportList(report)
        }
    }

    private func reportList(_ report: CopyEditReport) -> some View {
        List {
            if report.findings.isEmpty {
                Text("No copy issues found across \(report.auditedCount) pages — nice work.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groupedRoutes(report), id: \.self) { route in
                Section(route) {
                    ForEach(report.findings.filter { $0.route == route }) { finding in
                        findingRow(finding)
                    }
                }
            }
            if !report.skippedRoutes.isEmpty {
                Section("Not reviewed") {
                    Text(report.skippedRoutes.joined(separator: ", ")).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func findingRow(_ finding: CopyFinding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                severityBadge(finding.severity)
                Text(finding.category).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.appliedFindingIDs.contains(finding.id) {
                    Label("Applied", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
            }
            Text(finding.issue)
            Text("“\(finding.excerpt)” → “\(finding.suggestedRewrite)”")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Apply…") { confirming = finding }
                    .disabled(!model.canApply(finding))
                Button("Save as Annotation") { model.saveAsAnnotation(finding) }
                    .disabled(model.annotatedFindingIDs.contains(finding.id))
                Button("Copy Rewrite") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(finding.suggestedRewrite, forType: .string)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func severityBadge(_ severity: CopyFindingSeverity) -> some View {
        let (label, color): (String, Color) = switch severity {
        case .high: ("High", .red)
        case .medium: ("Medium", .orange)
        case .low: ("Low", .gray)
        }
        return Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func groupedRoutes(_ report: CopyEditReport) -> [String] {
        var seen = Set<String>()
        return report.findings.map(\.route).filter { seen.insert($0).inserted }
    }
}
```

- [ ] **Step 5: Wire presentation**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, next to the `styleGuide` property (line ~82): add `var copyEditModel: CopyEditReportModel?`, and near `presentStyleGuide` (line ~236) add:

```swift
    func presentCopyEdit() {
        guard let conventionsStore = <the store instance created for styleGuide at ~line 1068> else { return }
        copyEditModel = CopyEditReportModel(
            siteID: site.id, sourceDirectory: site.sourceDirectory, conventionsStore: conventionsStore)
    }
```

(Adapt to how `SiteWindowModel` actually holds the site + store — reuse the exact expressions the `styleGuide` wiring uses at lines ~1068–1078; if the store isn't retained as a property, retain it when first built.)

In `Sources/AnglesiteApp/SiteWindow.swift`, in the sheet block (~line 472ff), add:

```swift
        .sheet(item: $bindableModel.copyEditModel) { reportModel in
            CopyEditReportView(model: reportModel)
        }
```

Menu item: `grep -rn "Style Guide" Sources/AnglesiteApp` to find the CommandGroup hosting "Project Style Guide…", and add a sibling "Review Copy…" item that calls `presentCopyEdit()` through the same focused-scene-value plumbing (memory: menu enablement uses `focusedSceneValue` — mirror the Style Guide item's exact mechanism).

- [ ] **Step 6: Implement `ReviewCopyIntent`**

```swift
// Sources/AnglesiteIntents/ContentHelpIntents.swift
import AppIntents
import AnglesiteCore
import Foundation

/// Siri/Shortcuts front-door for the copy audit (#465). Reuses the same chunker/auditor as the
/// GUI and chat; the intent summarizes and points at the app for applying rewrites.
public struct ReviewCopyIntent: AppIntent {
    public static let title: LocalizedStringResource = "Review Site Copy"
    public static let description = IntentDescription(
        "Review a site's written copy for clarity, tone, and calls to action.")

    @Parameter(title: "Site") public var site: SiteEntity

    public init() {}
    public init(site: SiteEntity) {
        self.init()
        self.site = site
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Review copy on \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let sourceDirectory = site.directory else {
            return .result(dialog: "\(IntegrationDialogs.failed(reason: "site folder unavailable", siteName: site.displayName))")
        }
        guard let auditor = CopyEditAuditorFactory.makeDefault() else {
            return .result(dialog: "\(ContentHelpDialogs.assistantUnavailable(feature: "Copy review"))")
        }
        let chunks = SiteContentChunker.chunks(sourceDirectory: sourceDirectory)
        let preamble = BrandVoiceGuidance.preamble(
            conventions: nil, businessType: SiteBusinessType.read(sourceDirectory: sourceDirectory))
        let report = await auditor.audit(
            chunks: chunks, preamble: preamble, siteID: site.id, siteDirectory: sourceDirectory)
        return .result(dialog: "\(ContentHelpDialogs.copyReview(findingCount: report.findings.count, pageCount: report.auditedCount, skippedCount: report.skippedRoutes.count, siteName: site.displayName))")
    }
}
```

Register the intent wherever the module lists its intents (if an `AppShortcutsProvider`/intent registry file exists in `Sources/AnglesiteIntents/`, add `ReviewCopyIntent` following how `AddBookingIntent` is registered; if registration is automatic, nothing to do). Note: the intent passes `conventions: nil` — the conventions store lives per-window in the app; a follow-up can thread it through. `SiteEntity.directory` must be the `Source/` dir — verify against `SiteEntityQuery`'s construction (it builds entities from `SiteStore.Site`; use `sourceDirectory` there if it currently passes something else).

- [ ] **Step 7: Build + test**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: all PASS (including `ContentHelpDialogsTests` and, on Xcode 27, `AnglesiteIntentsTests`).

- [ ] **Step 8: Commit**

```bash
git add Sources/AnglesiteCore/ContentHelpDialogs.swift Sources/AnglesiteApp/CopyEditReportModel.swift Sources/AnglesiteApp/CopyEditReportView.swift Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteIntents/ContentHelpIntents.swift Tests/AnglesiteCoreTests/ContentHelpDialogsTests.swift
git add -A Sources/AnglesiteApp  # the commands file edited for the menu item
git commit -m "feat: Review Copy GUI report + ReviewCopyIntent (#465)"
```

---

## Phase C — Social media

### Task 11: Social pure core — platform catalog + calendar markdown

**Files:**
- Create: `Sources/AnglesiteCore/SocialPlatformCatalog.swift`
- Create: `Sources/AnglesiteCore/SocialMediaPlan.swift`
- Create: `Sources/AnglesiteCore/SocialCalendarMarkdown.swift`
- Test: `Tests/AnglesiteCoreTests/SocialCoreTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `SocialPlatformProfile { platform: String, bioCharLimit: Int, postsPerWeek: Int, note: String }`
  - `SocialPlatformCatalog.recommended(businessType: String?) -> [SocialPlatformProfile]`
  - `SocialPillar { name: String, detail: String }`
  - `SocialCalendarEntry { day: String, platform: String, pillar: String, idea: String }`
  - `SocialCalendarWeek { startDate: Date, entries: [SocialCalendarEntry] }`
  - `SocialMediaPlan { businessType: String?, platforms: [SocialPlatformProfile], bios: [String: String], pillars: [SocialPillar], weeks: [SocialCalendarWeek] }`
  - `SocialCalendarMarkdown.render(plan: SocialMediaPlan, siteName: String) -> String`
  - `SocialCalendarMarkdown.write(markdown: String, sourceDirectory: URL) throws -> URL` (writes `docs/social-calendar.md`, creating `docs/`)

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/SocialCoreTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct SocialCoreTests {
    @Test func catalogRecommendsByBusinessTypeWithDefault() {
        let bakery = SocialPlatformCatalog.recommended(businessType: "bakery")
        #expect(bakery.contains { $0.platform == "Instagram" })
        let trades = SocialPlatformCatalog.recommended(businessType: "trades")
        #expect(trades.contains { $0.platform == "Nextdoor" })
        let unknown = SocialPlatformCatalog.recommended(businessType: nil)
        #expect(!unknown.isEmpty) // sensible default set
        #expect(unknown.allSatisfy { $0.postsPerWeek > 0 && $0.bioCharLimit > 0 })
    }

    @Test func markdownRendersAllSections() {
        let plan = SocialMediaPlan(
            businessType: "bakery",
            platforms: [SocialPlatformProfile(platform: "Instagram", bioCharLimit: 150, postsPerWeek: 4, note: "visual-first")],
            bios: ["Instagram": "Fresh sourdough daily in Oakland."],
            pillars: [SocialPillar(name: "Behind the oven", detail: "Process shots and baking stories")],
            weeks: [SocialCalendarWeek(
                startDate: Date(timeIntervalSince1970: 1_752_105_600), // 2025-07-10 UTC
                entries: [SocialCalendarEntry(day: "Monday", platform: "Instagram",
                                              pillar: "Behind the oven", idea: "Time-lapse of the morning bake")])]
        )
        let md = SocialCalendarMarkdown.render(plan: plan, siteName: "SourdoughLab")
        #expect(md.contains("# Social media plan for SourdoughLab"))
        #expect(md.contains("Fresh sourdough daily"))
        #expect(md.contains("Behind the oven"))
        #expect(md.contains("| Monday | Instagram |"))
        #expect(md.contains("## Week of 2025-07-10"))
        #expect(md.contains("never posts on your behalf") || md.contains("copy-paste"))
    }

    @Test func writeCreatesDocsFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("social-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = try SocialCalendarMarkdown.write(markdown: "# Plan", sourceDirectory: dir)
        #expect(url.lastPathComponent == "social-calendar.md")
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Plan")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SocialCoreTests`
Expected: FAIL — cannot find `SocialPlatformCatalog`.

- [ ] **Step 3: Implement catalog + plan types**

```swift
// Sources/AnglesiteCore/SocialPlatformCatalog.swift
import Foundation

/// Deterministic platform recommendation by business type — ported from the social-media
/// skill's business-type→platform table (v1: a representative subset; enriching from the SMB
/// guides is a tracked follow-up). Cadence is posts per week.
public struct SocialPlatformProfile: Sendable, Equatable {
    public let platform: String
    public let bioCharLimit: Int
    public let postsPerWeek: Int
    public let note: String

    public init(platform: String, bioCharLimit: Int, postsPerWeek: Int, note: String) {
        self.platform = platform
        self.bioCharLimit = bioCharLimit
        self.postsPerWeek = postsPerWeek
        self.note = note
    }
}

public enum SocialPlatformCatalog {
    static let instagram = SocialPlatformProfile(platform: "Instagram", bioCharLimit: 150, postsPerWeek: 4, note: "visual-first; photos and reels")
    static let facebook = SocialPlatformProfile(platform: "Facebook", bioCharLimit: 255, postsPerWeek: 3, note: "community updates and events")
    static let googleBusiness = SocialPlatformProfile(platform: "Google Business", bioCharLimit: 750, postsPerWeek: 2, note: "posts show in local search")
    static let nextdoor = SocialPlatformProfile(platform: "Nextdoor", bioCharLimit: 500, postsPerWeek: 1, note: "neighborhood word of mouth")
    static let bluesky = SocialPlatformProfile(platform: "Bluesky", bioCharLimit: 256, postsPerWeek: 3, note: "conversational, link-friendly")

    public static func recommended(businessType: String?) -> [SocialPlatformProfile] {
        switch businessType?.lowercased() {
        case "restaurant", "cafe", "bakery", "food-truck":
            return [instagram, facebook, googleBusiness]
        case "trades", "landscaping", "cleaning", "handyman", "plumber", "electrician":
            return [facebook, nextdoor, googleBusiness]
        case "web-artist", "photographer", "designer", "artist", "studio":
            return [instagram, bluesky]
        case "retail", "boutique", "shop":
            return [instagram, facebook, googleBusiness]
        case "salon", "barber", "spa", "wellness":
            return [instagram, googleBusiness, facebook]
        default:
            return [facebook, instagram, googleBusiness]
        }
    }
}
```

```swift
// Sources/AnglesiteCore/SocialMediaPlan.swift
import Foundation

public struct SocialPillar: Sendable, Equatable {
    public let name: String
    public let detail: String
    public init(name: String, detail: String) {
        self.name = name
        self.detail = detail
    }
}

public struct SocialCalendarEntry: Sendable, Equatable {
    public let day: String
    public let platform: String
    public let pillar: String
    public let idea: String
    public init(day: String, platform: String, pillar: String, idea: String) {
        self.day = day
        self.platform = platform
        self.pillar = pillar
        self.idea = idea
    }
}

public struct SocialCalendarWeek: Sendable, Equatable {
    public let startDate: Date
    public let entries: [SocialCalendarEntry]
    public init(startDate: Date, entries: [SocialCalendarEntry]) {
        self.startDate = startDate
        self.entries = entries
    }
}

/// A generated social plan: FM writes the content, deterministic Swift owns the structure and
/// the file format (spec §5.2). `bios` is keyed by platform name; a missing key means that
/// bio couldn't be generated within its limit.
public struct SocialMediaPlan: Sendable, Equatable {
    public let businessType: String?
    public let platforms: [SocialPlatformProfile]
    public let bios: [String: String]
    public let pillars: [SocialPillar]
    public let weeks: [SocialCalendarWeek]

    public init(businessType: String?, platforms: [SocialPlatformProfile], bios: [String: String],
                pillars: [SocialPillar], weeks: [SocialCalendarWeek]) {
        self.businessType = businessType
        self.platforms = platforms
        self.bios = bios
        self.pillars = pillars
        self.weeks = weeks
    }
}
```

- [ ] **Step 4: Implement the renderer**

```swift
// Sources/AnglesiteCore/SocialCalendarMarkdown.swift
import Foundation

/// Deterministic markdown rendering of a `SocialMediaPlan` into the site repo's
/// `docs/social-calendar.md` — the same git-visible contract the markdown skill kept, so the
/// plan is portable and survives editing outside the app. Anglesite never posts on the
/// owner's behalf; the calendar is a copy-paste companion.
public enum SocialCalendarMarkdown {
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    public static func render(plan: SocialMediaPlan, siteName: String) -> String {
        var out: [String] = []
        out.append("# Social media plan for \(siteName)")
        out.append("")
        out.append("> Generated by Anglesite. Anglesite never posts on your behalf — copy-paste what you like, edit what you don't.")
        out.append("")
        out.append("## Platforms")
        out.append("")
        out.append("| Platform | Posts/week | Why |")
        out.append("|---|---|---|")
        for p in plan.platforms {
            out.append("| \(p.platform) | \(p.postsPerWeek) | \(p.note) |")
        }
        out.append("")
        out.append("## Profile bios")
        out.append("")
        for p in plan.platforms {
            out.append("**\(p.platform)** (max \(p.bioCharLimit) chars): \(plan.bios[p.platform] ?? "_(no bio generated)_")")
            out.append("")
        }
        out.append("## Content pillars")
        out.append("")
        for pillar in plan.pillars {
            out.append("- **\(pillar.name)** — \(pillar.detail)")
        }
        out.append("")
        for week in plan.weeks {
            out.append("## Week of \(dateFormatter.string(from: week.startDate))")
            out.append("")
            out.append("| Day | Platform | Pillar | Idea |")
            out.append("|---|---|---|---|")
            for e in week.entries {
                out.append("| \(e.day) | \(e.platform) | \(e.pillar) | \(e.idea) |")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// Writes (or replaces) `docs/social-calendar.md` under the site's `Source/` tree.
    @discardableResult
    public static func write(markdown: String, sourceDirectory: URL,
                             fileManager: FileManager = .default) throws -> URL {
        let docs = sourceDirectory.appendingPathComponent("docs")
        try fileManager.createDirectory(at: docs, withIntermediateDirectories: true)
        let url = docs.appendingPathComponent("social-calendar.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SocialCoreTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/SocialPlatformCatalog.swift Sources/AnglesiteCore/SocialMediaPlan.swift Sources/AnglesiteCore/SocialCalendarMarkdown.swift Tests/AnglesiteCoreTests/SocialCoreTests.swift
git commit -m "feat(core): social platform catalog + calendar markdown renderer (#465)"
```

---

### Task 12: Gated `FoundationModelSocialMediaPlanner`

**Files:**
- Modify: `Sources/AnglesiteCore/GenerableTypes.swift`
- Create: `Sources/AnglesiteCore/SocialPlanPrompt.swift`
- Create: `Sources/AnglesiteCore/SocialMediaPlanner.swift`
- Test: `Tests/AnglesiteCoreTests/SocialPlannerTests.swift`

**Interfaces:**
- Consumes: `SocialPlatformCatalog`/`SocialMediaPlan` types (Task 11), `ContentAssistantFactory` (Task 6), `BrandVoiceGuidance` (Task 2).
- Produces:
  - Generables (gated): `GeneratedSocialBio { bio }`, `GeneratedSocialPillar { name, detail }`, `GeneratedSocialPillars { pillars: [GeneratedSocialPillar] }`, `GeneratedSocialWeekEntry { day, platform, pillar, idea }`, `GeneratedSocialWeek { entries: [GeneratedSocialWeekEntry] }`
  - `SocialPlanPrompt.bio(platform: SocialPlatformProfile, siteName: String, businessType: String?, preamble: String?) -> String`; `.pillars(siteName:businessType:preamble:)`; `.week(index: Int, platforms: [SocialPlatformProfile], pillars: [SocialPillar], businessType: String?, preamble: String?) -> String` (all pure).
  - `protocol SocialMediaPlanning: Sendable { func plan(siteName: String, businessType: String?, preamble: String?, weeks: Int, startDate: Date, siteID: String, siteDirectory: URL) async -> SocialMediaPlan? }`
  - `SocialMediaPlannerFactory.makeDefault() -> (any SocialMediaPlanning)?`
  - `SocialWeekDates.startDates(from: Date, count: Int) -> [Date]` (pure, 7-day steps, gregorian/UTC).
  - Planner semantics: pillars failing → return `nil` (pillars are the backbone); a bio over its limit after one retry → omitted from `bios`; a failed week → omitted from `weeks`.

- [ ] **Step 1: Write the failing tests (pure parts)**

```swift
// Tests/AnglesiteCoreTests/SocialPlannerTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct SocialPlannerTests {
    @Test func factoryMatchesToolchain() {
        let planner = SocialMediaPlannerFactory.makeDefault()
        #if compiler(>=6.4)
        #expect(planner != nil)
        #else
        #expect(planner == nil)
        #endif
    }

    @Test func weekStartDatesStepBySevenDays() {
        let start = Date(timeIntervalSince1970: 1_752_105_600)
        let dates = SocialWeekDates.startDates(from: start, count: 3)
        #expect(dates.count == 3)
        #expect(dates[0] == start)
        #expect(dates[1].timeIntervalSince(dates[0]) == 7 * 86_400)
    }

    @Test func promptsCarryLimitsCadenceAndVoice() {
        let insta = SocialPlatformCatalog.recommended(businessType: "bakery")[0]
        let bio = SocialPlanPrompt.bio(platform: insta, siteName: "SourdoughLab",
                                       businessType: "bakery", preamble: "Match this site's voice:\nwarm.")
        #expect(bio.contains("150"))
        #expect(bio.contains("SourdoughLab"))
        #expect(bio.contains("warm"))
        let week = SocialPlanPrompt.week(
            index: 0, platforms: [insta],
            pillars: [SocialPillar(name: "Behind the oven", detail: "process")],
            businessType: "bakery", preamble: nil)
        #expect(week.contains("Instagram"))
        #expect(week.contains("4"))            // cadence
        #expect(week.contains("Behind the oven"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SocialPlannerTests`
Expected: FAIL — cannot find `SocialMediaPlannerFactory`.

- [ ] **Step 3: Add Generables (in `GenerableTypes.swift`, gated section)**

```swift
@Generable
public struct GeneratedSocialBio: Equatable, Sendable {
    @Guide(description: "The profile bio text, within the stated character limit. No hashtags unless the platform calls for them.")
    public var bio: String
}

@Generable
public struct GeneratedSocialPillar: Equatable, Sendable {
    @Guide(description: "Short pillar name, e.g. 'Behind the scenes'.")
    public var name: String
    @Guide(description: "One sentence on what this pillar covers and why followers care.")
    public var detail: String
}

@Generable
public struct GeneratedSocialPillars: Equatable, Sendable {
    @Guide(description: "3 to 5 content pillars. Roughly 80% value/story content, 20% promotional.")
    public var pillars: [GeneratedSocialPillar]
}

@Generable
public struct GeneratedSocialWeekEntry: Equatable, Sendable {
    @Guide(description: "Day of week, e.g. 'Monday'.")
    public var day: String
    @Guide(description: "Platform name, exactly as given in the prompt.")
    public var platform: String
    @Guide(description: "Pillar name, exactly as given in the prompt.")
    public var pillar: String
    @Guide(description: "One concrete post idea the owner could shoot/write that day.")
    public var idea: String
}

@Generable
public struct GeneratedSocialWeek: Equatable, Sendable {
    @Guide(description: "The week's post schedule, respecting each platform's posts-per-week cadence.")
    public var entries: [GeneratedSocialWeekEntry]
}
```

- [ ] **Step 4: Implement prompts + planner**

```swift
// Sources/AnglesiteCore/SocialPlanPrompt.swift
import Foundation

/// Pure prompt builders for the social planner (#465) — non-gated for CI tests. Week generation
/// is one call per week (chunk-first): each call carries only the platform cadence and pillar
/// facts, comfortably inside the on-device window.
public enum SocialPlanPrompt {
    public static func bio(platform: SocialPlatformProfile, siteName: String,
                           businessType: String?, preamble: String?) -> String {
        joined(preamble, """
        Write a profile bio for \(siteName)\(businessDescription(businessType)) on \(platform.platform). \
        Hard limit: \(platform.bioCharLimit) characters — shorter is better. Platform note: \(platform.note). \
        Plain text only, no surrounding quotes.
        """)
    }

    public static func pillars(siteName: String, businessType: String?, preamble: String?) -> String {
        joined(preamble, """
        Propose 3 to 5 social media content pillars for \(siteName)\(businessDescription(businessType)). \
        Follow the 80/20 rule: mostly value, story, and behind-the-scenes content; at most one \
        promotional pillar.
        """)
    }

    public static func week(index: Int, platforms: [SocialPlatformProfile], pillars: [SocialPillar],
                            businessType: String?, preamble: String?) -> String {
        let platformFacts = platforms
            .map { "- \($0.platform): \($0.postsPerWeek) posts this week (\($0.note))" }
            .joined(separator: "\n")
        let pillarFacts = pillars.map { "- \($0.name): \($0.detail)" }.joined(separator: "\n")
        return joined(preamble, """
        Plan week \(index + 1) of a social media calendar\(businessDescription(businessType)). \
        Create one entry per post, spread across the week, rotating through the pillars so no \
        pillar repeats on consecutive days on the same platform.

        Platforms and cadence:
        \(platformFacts)

        Content pillars (use these names exactly):
        \(pillarFacts)
        """)
    }

    static func businessDescription(_ businessType: String?) -> String {
        guard let businessType, !businessType.isEmpty else { return "" }
        return ", a \(businessType),"
    }

    static func joined(_ preamble: String?, _ body: String) -> String {
        [preamble, body].compactMap { $0 }.joined(separator: "\n\n")
    }
}

/// Pure 7-day week-start math, gregorian/UTC — deterministic regardless of the user's calendar.
public enum SocialWeekDates {
    public static func startDates(from start: Date, count: Int) -> [Date] {
        (0..<max(0, count)).map { start.addingTimeInterval(TimeInterval($0) * 7 * 86_400) }
    }
}
```

```swift
// Sources/AnglesiteCore/SocialMediaPlanner.swift
import Foundation

/// Social plan generation seam (#465). Pillars are the backbone: if they fail, the whole plan
/// is `nil` (callers show unavailable/retry). Bios and weeks degrade individually — a bio that
/// can't fit its platform limit after one retry is omitted (the renderer marks it), a failed
/// week is dropped.
public protocol SocialMediaPlanning: Sendable {
    func plan(siteName: String, businessType: String?, preamble: String?, weeks: Int,
              startDate: Date, siteID: String, siteDirectory: URL) async -> SocialMediaPlan?
}

public enum SocialMediaPlannerFactory {
    public static func makeDefault() -> (any SocialMediaPlanning)? {
        #if compiler(>=6.4)
        return FoundationModelSocialMediaPlanner()
        #else
        return nil
        #endif
    }
}

#if compiler(>=6.4)
import FoundationModels

public struct FoundationModelSocialMediaPlanner: SocialMediaPlanning {
    public init() {}

    public func plan(siteName: String, businessType: String?, preamble: String?, weeks: Int,
                     startDate: Date, siteID: String, siteDirectory: URL) async -> SocialMediaPlan? {
        guard let assistant = ContentAssistantFactory.make(tier: .privateCloudCompute) else { return nil }
        let context = AssistantContext(siteID: siteID, siteDirectory: siteDirectory)
        let platforms = SocialPlatformCatalog.recommended(businessType: businessType)

        guard let generatedPillars = try? await assistant.generateStructured(
            prompt: SocialPlanPrompt.pillars(siteName: siteName, businessType: businessType, preamble: preamble),
            context: context, resultType: GeneratedSocialPillars.self
        ), !generatedPillars.pillars.isEmpty else { return nil }
        let pillars = generatedPillars.pillars.map { SocialPillar(name: $0.name, detail: $0.detail) }

        var bios: [String: String] = [:]
        for platform in platforms {
            if let bio = await generateBio(platform: platform, siteName: siteName,
                                           businessType: businessType, preamble: preamble,
                                           assistant: assistant, context: context) {
                bios[platform.platform] = bio
            }
        }

        var calendarWeeks: [SocialCalendarWeek] = []
        for (index, weekStart) in SocialWeekDates.startDates(from: startDate, count: weeks).enumerated() {
            guard let week = try? await assistant.generateStructured(
                prompt: SocialPlanPrompt.week(index: index, platforms: platforms, pillars: pillars,
                                              businessType: businessType, preamble: preamble),
                context: context, resultType: GeneratedSocialWeek.self
            ) else { continue }
            calendarWeeks.append(SocialCalendarWeek(
                startDate: weekStart,
                entries: week.entries.map {
                    SocialCalendarEntry(day: $0.day, platform: $0.platform, pillar: $0.pillar, idea: $0.idea)
                }))
        }

        return SocialMediaPlan(businessType: businessType, platforms: platforms,
                               bios: bios, pillars: pillars, weeks: calendarWeeks)
    }

    /// One retry with an explicit "too long" correction, then give up — the renderer marks the
    /// gap; never silently truncate generated copy (spec §5.3 policy, applied to bios too).
    private func generateBio(platform: SocialPlatformProfile, siteName: String, businessType: String?,
                             preamble: String?, assistant: any ContentAssistant,
                             context: AssistantContext) async -> String? {
        let prompt = SocialPlanPrompt.bio(platform: platform, siteName: siteName,
                                          businessType: businessType, preamble: preamble)
        guard let first = try? await assistant.generateStructured(
            prompt: prompt, context: context, resultType: GeneratedSocialBio.self) else { return nil }
        if first.bio.count <= platform.bioCharLimit { return first.bio }
        let retryPrompt = prompt + "\n\nYour previous attempt was \(first.bio.count) characters — too long. It must be under \(platform.bioCharLimit) characters."
        guard let second = try? await assistant.generateStructured(
            prompt: retryPrompt, context: context, resultType: GeneratedSocialBio.self),
              second.bio.count <= platform.bioCharLimit else { return nil }
        return second.bio
    }
}
#endif
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter SocialPlannerTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/GenerableTypes.swift Sources/AnglesiteCore/SocialPlanPrompt.swift Sources/AnglesiteCore/SocialMediaPlanner.swift Tests/AnglesiteCoreTests/SocialPlannerTests.swift
git commit -m "feat(core): FoundationModelSocialMediaPlanner with week-by-week generation (#465)"
```

---

### Task 13: Social front-doors — `PlanSocialMediaTool` + GUI + Intent

**Files:**
- Create: `Sources/AnglesiteCore/PlanSocialMediaTool.swift`
- Create: `Sources/AnglesiteApp/SocialPlanModel.swift`
- Create: `Sources/AnglesiteApp/SocialPlanView.swift`
- Modify: `Sources/AnglesiteCore/FoundationModelAssistant.swift` (add `socialMediaPlanner` dependency)
- Modify: `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift`, `Sources/AnglesiteApp/SiteWindowModel.swift`, `Sources/AnglesiteApp/SiteWindow.swift`, the same commands file as Task 10 (menu item "Social Media Plan…")
- Modify: `Sources/AnglesiteIntents/ContentHelpIntents.swift` (add `PlanSocialMediaIntent`)
- Test: `Tests/AnglesiteCoreTests/PlanSocialMediaToolTests.swift`

**Interfaces:**
- Consumes: `SocialMediaPlanning`/`SocialMediaPlannerFactory` (Task 12), `SocialCalendarMarkdown` (Task 11), `BrandVoiceGuidance`/`SiteBusinessType` (Task 2), `ContentHelpDialogs` (Task 10).
- Produces: `PlanSocialMediaTool` (`toolName = "planSocialMedia"`, `Arguments { weeks: Int?, apply: Bool? }` — confirm-before-write like `SetupIntegrationTool`); pure `PlanSocialMediaReply.preview(plan: SocialMediaPlan) -> String` and `.saved(weeks: Int) -> String`; `FoundationModelAssistant.init` gains `socialMediaPlanner: (any SocialMediaPlanning)? = nil`; `SocialPlanModel`/`SocialPlanView`; `PlanSocialMediaIntent`.
- Site name for prompts: `SiteConfigFile.value(forKey: "SITE_NAME", in:)` via a `SiteBusinessType`-style helper — add `SiteConfigValues.siteName(sourceDirectory: URL) -> String?` to `Sources/AnglesiteCore/BrandVoiceGuidance.swift`'s file (alongside `SiteBusinessType`), falling back to the directory name.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AnglesiteCoreTests/PlanSocialMediaToolTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct PlanSocialMediaToolTests {
    private var plan: SocialMediaPlan {
        SocialMediaPlan(
            businessType: "bakery",
            platforms: [SocialPlatformProfile(platform: "Instagram", bioCharLimit: 150, postsPerWeek: 4, note: "n")],
            bios: ["Instagram": "Fresh daily."],
            pillars: [SocialPillar(name: "Behind the oven", detail: "d")],
            weeks: [SocialCalendarWeek(startDate: Date(timeIntervalSince1970: 0), entries: [])])
    }

    @Test func previewSummarizesAndAsksToConfirm() {
        let text = PlanSocialMediaReply.preview(plan: plan)
        #expect(text.contains("Instagram"))
        #expect(text.contains("Behind the oven"))
        #expect(text.contains("apply: true")) // confirm-before-write hint, SetupIntegrationTool pattern
    }

    @Test func savedNamesTheFile() {
        #expect(PlanSocialMediaReply.saved(weeks: 4).contains("docs/social-calendar.md"))
    }

    @Test func siteNameFallsBackToDirectoryName() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MySite-\(UUID().uuidString)")
        #expect(SiteConfigValues.siteName(sourceDirectory: dir)?.hasPrefix("MySite-") == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter PlanSocialMediaToolTests`
Expected: FAIL — cannot find `PlanSocialMediaReply`.

- [ ] **Step 3: Implement the tool (+ `SiteConfigValues.siteName`)**

Add to the `SiteBusinessType` file (`Sources/AnglesiteCore/BrandVoiceGuidance.swift`):

```swift
/// Reads display values from `Source/.site-config`, falling back sensibly.
public enum SiteConfigValues {
    public static func siteName(sourceDirectory: URL) -> String? {
        let url = sourceDirectory.appendingPathComponent(".site-config")
        if let contents = try? String(contentsOf: url, encoding: .utf8),
           let name = SiteConfigFile.value(forKey: "SITE_NAME", in: contents), !name.isEmpty {
            return name
        }
        let dirName = sourceDirectory.lastPathComponent
        return dirName.isEmpty ? nil : dirName
    }
}
```

```swift
// Sources/AnglesiteCore/PlanSocialMediaTool.swift
import Foundation

/// Pure chat replies for the social planner tool, non-gated for CI tests.
public enum PlanSocialMediaReply {
    public static func preview(plan: SocialMediaPlan) -> String {
        var lines: [String] = ["Here's the social media plan I'd save:"]
        lines.append("Platforms: " + plan.platforms.map { "\($0.platform) (\($0.postsPerWeek)×/week)" }.joined(separator: ", "))
        lines.append("Pillars: " + plan.pillars.map(\.name).joined(separator: ", "))
        lines.append("\(plan.weeks.count) week\(plan.weeks.count == 1 ? "" : "s") of calendar entries.")
        lines.append("Confirm to save it to docs/social-calendar.md, or tell me what to change. When the user confirms, call this tool again with apply: true.")
        return lines.joined(separator: "\n")
    }

    public static func saved(weeks: Int) -> String {
        "Saved the \(weeks)-week plan to docs/social-calendar.md. Anglesite never posts for you — copy entries out as you go."
    }
}

#if compiler(>=6.4)
import FoundationModels

/// Chat front-door for the social plan (#465). Confirm-before-write: the first call previews;
/// `apply: true` regenerates and writes `docs/social-calendar.md` (the file is app-generated,
/// so a regenerate-on-apply keeps the tool stateless across turns).
public struct PlanSocialMediaTool: Tool, Sendable {
    public static let toolName = "planSocialMedia"
    public let name = PlanSocialMediaTool.toolName
    public let description = "Create a social media plan: recommended platforms, profile bios, content pillars, and a weekly content calendar saved to docs/social-calendar.md. Returns a preview to confirm before saving."

    @Generable
    public struct Arguments {
        @Guide(description: "How many weeks of calendar to plan (default 4, max 8).")
        public var weeks: Int?
        @Guide(description: "Set to true ONLY after the user has confirmed they want the plan saved.")
        public var apply: Bool?
    }

    private let planner: any SocialMediaPlanning
    private let conventionsStore: ProjectConventionsStore?
    private let siteID: String
    private let siteDirectory: URL
    /// Injected clock so the calendar's start is testable/deterministic where needed.
    private let now: @Sendable () -> Date

    public init(planner: any SocialMediaPlanning, conventionsStore: ProjectConventionsStore?,
                siteID: String, siteDirectory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.planner = planner
        self.conventionsStore = conventionsStore
        self.siteID = siteID
        self.siteDirectory = siteDirectory
        self.now = now
    }

    public func call(arguments: Arguments) async throws -> String {
        let weeks = min(max(arguments.weeks ?? 4, 1), 8)
        let conventions = await conventionsStore?.load()
        let businessType = SiteBusinessType.read(sourceDirectory: siteDirectory)
        let preamble = BrandVoiceGuidance.preamble(conventions: conventions, businessType: businessType)
        let siteName = SiteConfigValues.siteName(sourceDirectory: siteDirectory) ?? "this site"
        guard let plan = await planner.plan(
            siteName: siteName, businessType: businessType, preamble: preamble,
            weeks: weeks, startDate: now(), siteID: siteID, siteDirectory: siteDirectory) else {
            return ContentHelpDialogs.assistantUnavailable(feature: "Social planning")
        }
        if arguments.apply == true {
            let markdown = SocialCalendarMarkdown.render(plan: plan, siteName: siteName)
            do {
                try SocialCalendarMarkdown.write(markdown: markdown, sourceDirectory: siteDirectory)
                return PlanSocialMediaReply.saved(weeks: plan.weeks.count)
            } catch {
                return "I generated the plan but couldn't save it: \(error.localizedDescription)"
            }
        }
        return PlanSocialMediaReply.preview(plan: plan)
    }
}
#endif
```

- [ ] **Step 4: Wire into the assistant**

`FoundationModelAssistant.swift`: add `socialMediaPlanner: (any SocialMediaPlanning)? = nil` init param + property. `conversationTools`:

```swift
        if let socialMediaPlanner {
            tools.append(PlanSocialMediaTool(
                planner: socialMediaPlanner, conventionsStore: conventionsStore,
                siteID: context.siteID, siteDirectory: context.siteDirectory))
        }
```

`attachedToolNames`: `if socialMediaPlanner != nil { names.append(PlanSocialMediaTool.toolName) }`.
`SiteAssistantSessionFactory.swift`: pass `socialMediaPlanner: SocialMediaPlannerFactory.makeDefault()`.

- [ ] **Step 5: GUI model + view**

```swift
// Sources/AnglesiteApp/SocialPlanModel.swift
import Foundation
import Observation
import AnglesiteCore

/// Drives the Social Media Plan sheet (#465): generate → preview markdown → explicit Save.
/// FM generates content; deterministic code renders and writes the file (spec §5.2).
@Observable @MainActor
final class SocialPlanModel: Identifiable {
    let siteID: String
    let sourceDirectory: URL
    private let conventionsStore: ProjectConventionsStore
    private let planner: (any SocialMediaPlanning)?

    var weeks = 4
    var markdown: String?
    var running = false
    var saved = false
    var errorMessage: String?
    var unavailable: Bool { planner == nil }

    init(siteID: String, sourceDirectory: URL, conventionsStore: ProjectConventionsStore,
         planner: (any SocialMediaPlanning)? = SocialMediaPlannerFactory.makeDefault()) {
        self.siteID = siteID
        self.sourceDirectory = sourceDirectory
        self.conventionsStore = conventionsStore
        self.planner = planner
    }

    func generate() async {
        guard let planner, !running else { return }
        running = true
        saved = false
        defer { running = false }
        let conventions = await conventionsStore.load()
        let businessType = SiteBusinessType.read(sourceDirectory: sourceDirectory)
        let siteName = SiteConfigValues.siteName(sourceDirectory: sourceDirectory) ?? "this site"
        let preamble = BrandVoiceGuidance.preamble(conventions: conventions, businessType: businessType)
        guard let plan = await planner.plan(
            siteName: siteName, businessType: businessType, preamble: preamble,
            weeks: weeks, startDate: Date(), siteID: siteID, siteDirectory: sourceDirectory) else {
            errorMessage = ContentHelpDialogs.assistantUnavailable(feature: "Social planning")
            return
        }
        markdown = SocialCalendarMarkdown.render(plan: plan, siteName: siteName)
    }

    func save() {
        guard let markdown else { return }
        do {
            try SocialCalendarMarkdown.write(markdown: markdown, sourceDirectory: sourceDirectory)
            saved = true
        } catch {
            errorMessage = "Couldn't save the plan: \(error.localizedDescription)"
        }
    }
}
```

```swift
// Sources/AnglesiteApp/SocialPlanView.swift
import SwiftUI
import AnglesiteCore

struct SocialPlanView: View {
    @Bindable var model: SocialPlanModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Social Media Plan").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if model.unavailable {
                ContentUnavailableView(
                    "Apple Intelligence Required", systemImage: "sparkles",
                    description: Text(ContentHelpDialogs.assistantUnavailable(feature: "Social planning")))
            } else {
                HStack {
                    Stepper("Weeks: \(model.weeks)", value: $model.weeks, in: 1...8)
                    Spacer()
                    Button(model.markdown == nil ? "Generate Plan" : "Regenerate") {
                        Task { await model.generate() }
                    }
                    .disabled(model.running)
                    if model.running { ProgressView().controlSize(.small) }
                }
                if let markdown = model.markdown {
                    ScrollView {
                        Text(markdown)
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Spacer()
                        if model.saved { Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        Button("Save to docs/social-calendar.md") { model.save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.saved)
                    }
                } else if !model.running {
                    Text("Generates recommended platforms, bios, content pillars, and a weekly calendar — saved into your site repo, never posted for you.")
                        .foregroundStyle(.secondary)
                }
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
    }
}
```

Wire `SiteWindowModel.socialPlanModel: SocialPlanModel?` + `presentSocialPlan()` + `.sheet(item:)` in `SiteWindow.swift` + a "Social Media Plan…" menu item — all exactly parallel to Task 10's copy-edit wiring.

- [ ] **Step 6: Add `PlanSocialMediaIntent`**

Append to `Sources/AnglesiteIntents/ContentHelpIntents.swift`:

```swift
public struct PlanSocialMediaIntent: AppIntent {
    public static let title: LocalizedStringResource = "Plan Social Media"
    public static let description = IntentDescription(
        "Generate a social media plan and content calendar for a site.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Weeks", default: 4) public var weeks: Int

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Plan social media for \(\.$site)") {
            \.$weeks
        }
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let sourceDirectory = site.directory else {
            return .result(dialog: "\(IntegrationDialogs.failed(reason: "site folder unavailable", siteName: site.displayName))")
        }
        guard let planner = SocialMediaPlannerFactory.makeDefault() else {
            return .result(dialog: "\(ContentHelpDialogs.assistantUnavailable(feature: "Social planning"))")
        }
        let businessType = SiteBusinessType.read(sourceDirectory: sourceDirectory)
        let siteName = SiteConfigValues.siteName(sourceDirectory: sourceDirectory) ?? site.displayName
        let clamped = min(max(weeks, 1), 8)
        guard let plan = await planner.plan(
            siteName: siteName, businessType: businessType,
            preamble: BrandVoiceGuidance.preamble(conventions: nil, businessType: businessType),
            weeks: clamped, startDate: Date(), siteID: site.id, siteDirectory: sourceDirectory) else {
            return .result(dialog: "\(ContentHelpDialogs.assistantUnavailable(feature: "Social planning"))")
        }
        // Writing a docs file into the site repo: confirm like AddBookingIntent confirms writes.
        try await requestConfirmation(dialog: "Save a \(plan.weeks.count)-week social plan to \(site.displayName)'s docs/social-calendar.md?")
        let markdown = SocialCalendarMarkdown.render(plan: plan, siteName: siteName)
        try SocialCalendarMarkdown.write(markdown: markdown, sourceDirectory: sourceDirectory)
        return .result(dialog: "\(ContentHelpDialogs.socialPlanSaved(weeks: plan.weeks.count, siteName: site.displayName))")
    }
}
```

- [ ] **Step 7: Run the full suite + commit**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: all PASS (new: `PlanSocialMediaToolTests`, 3 tests).

```bash
git add Sources/AnglesiteCore/PlanSocialMediaTool.swift Sources/AnglesiteCore/BrandVoiceGuidance.swift Sources/AnglesiteCore/FoundationModelAssistant.swift Sources/AnglesiteApp/SocialPlanModel.swift Sources/AnglesiteApp/SocialPlanView.swift Sources/AnglesiteApp/SiteAssistantSessionFactory.swift Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteIntents/ContentHelpIntents.swift Tests/AnglesiteCoreTests/PlanSocialMediaToolTests.swift
git add -A Sources/AnglesiteApp  # commands file
git commit -m "feat: social media plan front-doors — planSocialMedia tool, GUI sheet, intent (#465)"
```

---

## Phase D — Repurpose

### Task 14: Repurpose pure core — post loading, platform specs, syndication write-back

**Files:**
- Create: `Sources/AnglesiteCore/RepurposePlatformSpecs.swift`
- Create: `Sources/AnglesiteCore/PostSource.swift`
- Create: `Sources/AnglesiteCore/SyndicationFrontmatter.swift`
- Test: `Tests/AnglesiteCoreTests/RepurposeCoreTests.swift`

> **AMENDMENT (execution, 2026-07-10):** per Task 5's amendment, `PostSource.load` uses the EXISTING `Frontmatter.parse(_:) -> [String: FrontmatterValue]` (title/description via the `.string` case, tags via the `.array` case — drop the plan's ad-hoc bracket-stripping tags parser) plus the new `Frontmatter.body(_:)` accessor for the raw body. `SyndicationFrontmatter` is unaffected (it does its own line-based fence walk).

**Interfaces:**
- Consumes: existing `Frontmatter.parse` + `Frontmatter.body(_:)` (Task 5), `SiteContentChunker.plainText(markdown:)` (Task 5), `SiteConfigFile`.
- Produces:
  - `PlatformPostSpec { platform: String, charLimit: Int, includesURL: Bool, allowsHashtags: Bool, styleHint: String }`
  - `RepurposePlatformSpecs.all: [PlatformPostSpec]` (Instagram 2200 / Facebook 500 / Google Business 1500 / Nextdoor 800 / X 280 / Bluesky 300) and `.fits(_ text: String, spec:) -> Bool`
  - `PostSource { collection: String, slug: String, title: String, description: String?, tags: [String], body: String, filePath: String }`
  - `PostSource.load(slug: String, sourceDirectory: URL) -> PostSource?` — finds `src/content/<collection>/<slug>.{md,mdoc}`.
  - `PostSource.postURL(domain: String, collection: String, slug: String) -> String` — `https://<domain>/<collection>/<slug>/`, scheme-stripping the domain if present.
  - `SyndicationFrontmatter.adding(urls: [String], to contents: String) -> String` — creates/extends the `syndication:` YAML list, deduplicating.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AnglesiteCoreTests/RepurposeCoreTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct RepurposeCoreTests {
    @Test func specsTableCarriesTheSkillsLimits() {
        let byName = Dictionary(uniqueKeysWithValues: RepurposePlatformSpecs.all.map { ($0.platform, $0) })
        #expect(byName["X"]?.charLimit == 280)
        #expect(byName["Bluesky"]?.charLimit == 300)
        #expect(byName["Instagram"]?.charLimit == 2200)
        #expect(byName["Instagram"]?.includesURL == false) // Instagram strips links
        #expect(byName["Facebook"]?.charLimit == 500)
        #expect(RepurposePlatformSpecs.fits("ok", spec: byName["X"]!))
        #expect(!RepurposePlatformSpecs.fits(String(repeating: "a", count: 281), spec: byName["X"]!))
    }

    @Test func loadsPostBySlugAcrossCollections() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("repurpose-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("src/content/posts"), withIntermediateDirectories: true)
        try """
        ---
        title: Coast Trip
        description: A weekend on the coast
        ---
        We drove out early and the fog lifted by ten.
        """.write(to: dir.appendingPathComponent("src/content/posts/coast-trip.mdoc"), atomically: true, encoding: .utf8)
        let post = PostSource.load(slug: "coast-trip", sourceDirectory: dir)
        #expect(post?.title == "Coast Trip")
        #expect(post?.collection == "posts")
        #expect(post?.body.contains("fog lifted") == true)
        #expect(post?.filePath == "src/content/posts/coast-trip.mdoc")
        #expect(PostSource.load(slug: "missing", sourceDirectory: dir) == nil)
    }

    @Test func postURLNormalizesDomain() {
        #expect(PostSource.postURL(domain: "example.com", collection: "posts", slug: "a") == "https://example.com/posts/a/")
        #expect(PostSource.postURL(domain: "https://example.com/", collection: "posts", slug: "a") == "https://example.com/posts/a/")
    }

    @Test func syndicationAddsBlockAndDeduplicates() {
        let original = """
        ---
        title: Coast Trip
        ---
        Body.
        """
        let once = SyndicationFrontmatter.adding(urls: ["https://bsky.app/x/1"], to: original)
        #expect(once.contains("syndication:"))
        #expect(once.contains("  - https://bsky.app/x/1"))
        #expect(once.contains("Body."))
        let twice = SyndicationFrontmatter.adding(urls: ["https://bsky.app/x/1", "https://x.com/y/2"], to: once)
        #expect(twice.components(separatedBy: "https://bsky.app/x/1").count == 2) // still once
        #expect(twice.contains("https://x.com/y/2"))
    }

    @Test func syndicationOnUnfencedFileCreatesFrontmatter() {
        let out = SyndicationFrontmatter.adding(urls: ["https://a.test/1"], to: "Just body.")
        #expect(out.hasPrefix("---\n"))
        #expect(out.contains("syndication:"))
        #expect(out.contains("Just body."))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter RepurposeCoreTests`
Expected: FAIL — cannot find `RepurposePlatformSpecs`.

- [ ] **Step 3: Implement specs + post source**

```swift
// Sources/AnglesiteCore/RepurposePlatformSpecs.swift
import Foundation

/// Per-platform constraints for repurposed posts — the repurpose skill's table as Swift data.
/// Char limits are enforced in Swift (spec §5.3), never trusted to the model.
public struct PlatformPostSpec: Sendable, Equatable {
    public let platform: String
    public let charLimit: Int
    /// Whether the post should end with the canonical post URL (Instagram strips links).
    public let includesURL: Bool
    public let allowsHashtags: Bool
    public let styleHint: String

    public init(platform: String, charLimit: Int, includesURL: Bool, allowsHashtags: Bool, styleHint: String) {
        self.platform = platform
        self.charLimit = charLimit
        self.includesURL = includesURL
        self.allowsHashtags = allowsHashtags
        self.styleHint = styleHint
    }
}

public enum RepurposePlatformSpecs {
    public static let all: [PlatformPostSpec] = [
        PlatformPostSpec(platform: "Instagram", charLimit: 2200, includesURL: false, allowsHashtags: true,
                         styleHint: "engaging caption; mention 'link in bio'; end with a handful of relevant hashtags"),
        PlatformPostSpec(platform: "Facebook", charLimit: 500, includesURL: true, allowsHashtags: false,
                         styleHint: "conversational, one short paragraph"),
        PlatformPostSpec(platform: "Google Business", charLimit: 1500, includesURL: true, allowsHashtags: false,
                         styleHint: "informative and action-oriented for local searchers"),
        PlatformPostSpec(platform: "Nextdoor", charLimit: 800, includesURL: true, allowsHashtags: false,
                         styleHint: "neighborly, local framing"),
        PlatformPostSpec(platform: "X", charLimit: 280, includesURL: true, allowsHashtags: true,
                         styleHint: "punchy single post"),
        PlatformPostSpec(platform: "Bluesky", charLimit: 300, includesURL: true, allowsHashtags: true,
                         styleHint: "punchy single post"),
    ]

    public static func fits(_ text: String, spec: PlatformPostSpec) -> Bool {
        text.count <= spec.charLimit
    }
}
```

```swift
// Sources/AnglesiteCore/PostSource.swift
import Foundation

/// One blog post loaded for repurposing (#465): frontmatter + plain-text body + where it lives.
public struct PostSource: Sendable, Equatable {
    public let collection: String
    public let slug: String
    public let title: String
    public let description: String?
    public let tags: [String]
    public let body: String
    public let filePath: String

    public init(collection: String, slug: String, title: String, description: String?,
                tags: [String], body: String, filePath: String) {
        self.collection = collection
        self.slug = slug
        self.title = title
        self.description = description
        self.tags = tags
        self.body = body
        self.filePath = filePath
    }

    /// Finds `src/content/<collection>/<slug>.{md,mdoc}` across all collections.
    public static func load(slug: String, sourceDirectory: URL,
                            fileManager: FileManager = .default) -> PostSource? {
        let contentRoot = sourceDirectory.appendingPathComponent("src/content")
        guard let collections = try? fileManager.contentsOfDirectory(
            at: contentRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for collectionURL in collections where (try? collectionURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for ext in ["mdoc", "md"] {
                let url = collectionURL.appendingPathComponent("\(slug).\(ext)")
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let (fields, rawBody) = Frontmatter.parse(contents)
                let collection = collectionURL.lastPathComponent
                let tags = (fields["tags"] ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
                    .filter { !$0.isEmpty }
                return PostSource(
                    collection: collection,
                    slug: slug,
                    title: fields["title"] ?? slug,
                    description: fields["description"],
                    tags: tags,
                    body: SiteContentChunker.plainText(markdown: rawBody),
                    filePath: "src/content/\(collection)/\(slug).\(ext)")
            }
        }
        return nil
    }

    /// Canonical published URL for a post: `https://<domain>/<collection>/<slug>/`.
    public static func postURL(domain: String, collection: String, slug: String) -> String {
        var host = domain
        for prefix in ["https://", "http://"] where host.hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        host = host.hasSuffix("/") ? String(host.dropLast()) : host
        return "https://\(host)/\(collection)/\(slug)/"
    }
}
```

- [ ] **Step 4: Implement syndication write-back**

```swift
// Sources/AnglesiteCore/SyndicationFrontmatter.swift
import Foundation

/// Deterministic POSSE trail (#465): records published-copy URLs in the post's `syndication:`
/// frontmatter list (the u-syndication source the mf2 layer projects). Pure string → string.
public enum SyndicationFrontmatter {
    public static func adding(urls: [String], to contents: String) -> String {
        let newURLs = urls.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !newURLs.isEmpty else { return contents }
        var lines = contents.components(separatedBy: "\n")

        // No frontmatter at all: synthesize a fence around the syndication block.
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else {
            let block = ["---", "syndication:"] + newURLs.map { "  - \($0)" } + ["---"]
            return (block + [contents]).joined(separator: "\n")
        }

        let existing = Set(lines[..<closing]
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
            .map { $0.trimmingCharacters(in: .whitespaces).dropFirst(2).trimmingCharacters(in: .whitespaces) })
        let toAdd = newURLs.filter { !existing.contains($0) }
        guard !toAdd.isEmpty else { return contents }

        if let keyIndex = lines[..<closing].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "syndication:" || $0.hasPrefix("syndication:")
        }) {
            // Append after the last item of the existing list.
            var insertAt = keyIndex + 1
            while insertAt < closing, lines[insertAt].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                insertAt += 1
            }
            lines.insert(contentsOf: toAdd.map { "  - \($0)" }, at: insertAt)
        } else {
            lines.insert(contentsOf: ["syndication:"] + toAdd.map { "  - \($0)" }, at: closing)
        }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter RepurposeCoreTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/RepurposePlatformSpecs.swift Sources/AnglesiteCore/PostSource.swift Sources/AnglesiteCore/SyndicationFrontmatter.swift Tests/AnglesiteCoreTests/RepurposeCoreTests.swift
git commit -m "feat(core): repurpose pure core — post loader, platform specs, syndication write-back (#465)"
```

---

### Task 15: Gated `FoundationModelPostRepurposer` + `RepurposePostTool`

**Files:**
- Modify: `Sources/AnglesiteCore/GenerableTypes.swift` (add `GeneratedPlatformPost`)
- Create: `Sources/AnglesiteCore/PostRepurposer.swift`
- Create: `Sources/AnglesiteCore/RepurposePostTool.swift`
- Modify: `Sources/AnglesiteCore/FoundationModelAssistant.swift` (add `postRepurposer` dependency), `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift`
- Test: `Tests/AnglesiteCoreTests/PostRepurposerTests.swift`

**Interfaces:**
- Consumes: `PostSource`/`PlatformPostSpec`/`RepurposePlatformSpecs`/`SyndicationFrontmatter` (Task 14), `ContentAssistantFactory` (Task 6), `BrandVoiceGuidance`, `ContentHelpDialogs`.
- Produces:
  - `GeneratedPlatformPost { text }` (gated Generable).
  - `PlatformPostVariant { platform: String, text: String?, failure: String? }`
  - `RepurposePrompt.build(post: PostSource, postURL: String, spec: PlatformPostSpec, preamble: String?) -> String` (pure)
  - `protocol PostRepurposing: Sendable { func variants(post: PostSource, postURL: String, specs: [PlatformPostSpec], preamble: String?, siteID: String, siteDirectory: URL) async -> [PlatformPostVariant] }`
  - `PostRepurposerFactory.makeDefault() -> (any PostRepurposing)?`
  - `RepurposeReply.text(postTitle: String, variants: [PlatformPostVariant]) -> String` (pure)
  - `RepurposePostTool` (`toolName = "repurposePost"`, `Arguments { slug: String }`) and `SaveSyndicationTool` (`toolName = "saveSyndication"`, `Arguments { slug: String, urls: String }`, deterministic write-back).
  - Char-limit policy (spec §5.3): validate → one retry with explicit length correction → variant fails with a message. Never silent truncation.

- [ ] **Step 1: Write the failing tests (pure parts)**

```swift
// Tests/AnglesiteCoreTests/PostRepurposerTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct PostRepurposerTests {
    private var post: PostSource {
        PostSource(collection: "posts", slug: "coast-trip", title: "Coast Trip",
                   description: "A weekend on the coast", tags: ["travel"],
                   body: "We drove out early and the fog lifted by ten.",
                   filePath: "src/content/posts/coast-trip.mdoc")
    }

    @Test func factoryMatchesToolchain() {
        let repurposer = PostRepurposerFactory.makeDefault()
        #if compiler(>=6.4)
        #expect(repurposer != nil)
        #else
        #expect(repurposer == nil)
        #endif
    }

    @Test func promptCarriesLimitURLPolicyAndBody() {
        let spec = RepurposePlatformSpecs.all.first { $0.platform == "X" }!
        let p = RepurposePrompt.build(post: post, postURL: "https://e.com/posts/coast-trip/",
                                      spec: spec, preamble: "Match this site's voice:\nwarm.")
        #expect(p.contains("280"))
        #expect(p.contains("https://e.com/posts/coast-trip/"))
        #expect(p.contains("fog lifted"))
        #expect(p.contains("warm"))
        let insta = RepurposePlatformSpecs.all.first { $0.platform == "Instagram" }!
        let ip = RepurposePrompt.build(post: post, postURL: "https://e.com/posts/coast-trip/",
                                       spec: insta, preamble: nil)
        #expect(ip.contains("Do not include any URL"))
    }

    @Test func replyRendersVariantsAndFailures() {
        let variants = [
            PlatformPostVariant(platform: "X", text: "Fog lifted by ten. https://e.com/p/", failure: nil),
            PlatformPostVariant(platform: "Bluesky", text: nil, failure: "Couldn't fit Bluesky's 300-character limit."),
        ]
        let text = RepurposeReply.text(postTitle: "Coast Trip", variants: variants)
        #expect(text.contains("Coast Trip"))
        #expect(text.contains("X:"))
        #expect(text.contains("Fog lifted"))
        #expect(text.contains("300-character"))
        #expect(text.contains("saveSyndication")) // instructs the follow-up write-back
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter PostRepurposerTests`
Expected: FAIL — cannot find `PostRepurposerFactory`.

- [ ] **Step 3: Add the Generable + implement the repurposer**

In `GenerableTypes.swift` (gated section):

```swift
@Generable
public struct GeneratedPlatformPost: Equatable, Sendable {
    @Guide(description: "The complete post text for the platform, within the stated character limit, ready to copy-paste.")
    public var text: String
}
```

```swift
// Sources/AnglesiteCore/PostRepurposer.swift
import Foundation

/// One platform's repurposed post: `text` on success, `failure` (user-facing) when the model
/// couldn't satisfy the platform's hard limit after a retry — never silently truncated.
public struct PlatformPostVariant: Sendable, Equatable {
    public let platform: String
    public let text: String?
    public let failure: String?

    public init(platform: String, text: String?, failure: String?) {
        self.platform = platform
        self.text = text
        self.failure = failure
    }
}

/// Pure prompt builder for one platform variant — non-gated for CI tests.
public enum RepurposePrompt {
    public static func build(post: PostSource, postURL: String, spec: PlatformPostSpec,
                             preamble: String?) -> String {
        var rules: [String] = []
        rules.append("Hard limit: \(spec.charLimit) characters total — shorter is better.")
        rules.append(spec.includesURL
            ? "End with the post's link: \(postURL)"
            : "Do not include any URL (\(spec.platform) strips links); say 'link in bio' instead.")
        rules.append(spec.allowsHashtags
            ? "A few relevant hashtags are welcome."
            : "No hashtags.")
        rules.append("Style: \(spec.styleHint).")
        let sections = [
            preamble,
            """
            Write a \(spec.platform) post that shares this blog post with the owner's followers.
            \(rules.joined(separator: "\n"))

            Blog post title: \(post.title)
            \(post.description.map { "Summary: \($0)" } ?? "")
            Blog post text:
            \(post.body)
            """,
        ]
        return sections.compactMap { $0 }.joined(separator: "\n\n")
    }
}

public protocol PostRepurposing: Sendable {
    func variants(post: PostSource, postURL: String, specs: [PlatformPostSpec], preamble: String?,
                  siteID: String, siteDirectory: URL) async -> [PlatformPostVariant]
}

public enum PostRepurposerFactory {
    public static func makeDefault() -> (any PostRepurposing)? {
        #if compiler(>=6.4)
        return FoundationModelPostRepurposer()
        #else
        return nil
        #endif
    }
}

#if compiler(>=6.4)
import FoundationModels

public struct FoundationModelPostRepurposer: PostRepurposing {
    public init() {}

    public func variants(post: PostSource, postURL: String, specs: [PlatformPostSpec], preamble: String?,
                         siteID: String, siteDirectory: URL) async -> [PlatformPostVariant] {
        guard let assistant = ContentAssistantFactory.make(tier: .privateCloudCompute) else {
            return specs.map { PlatformPostVariant(
                platform: $0.platform, text: nil,
                failure: ContentHelpDialogs.assistantUnavailable(feature: "Repurposing")) }
        }
        let context = AssistantContext(siteID: siteID, siteDirectory: siteDirectory)
        var out: [PlatformPostVariant] = []
        for spec in specs {
            out.append(await variant(for: spec, post: post, postURL: postURL, preamble: preamble,
                                     assistant: assistant, context: context))
        }
        return out
    }

    /// Spec §5.3: validate in Swift → one retry with the measured overshoot → fail with a message.
    private func variant(for spec: PlatformPostSpec, post: PostSource, postURL: String,
                         preamble: String?, assistant: any ContentAssistant,
                         context: AssistantContext) async -> PlatformPostVariant {
        let prompt = RepurposePrompt.build(post: post, postURL: postURL, spec: spec, preamble: preamble)
        guard let first = try? await assistant.generateStructured(
            prompt: prompt, context: context, resultType: GeneratedPlatformPost.self) else {
            return PlatformPostVariant(platform: spec.platform, text: nil,
                                       failure: "Couldn't generate a \(spec.platform) post.")
        }
        if RepurposePlatformSpecs.fits(first.text, spec: spec) {
            return PlatformPostVariant(platform: spec.platform, text: first.text, failure: nil)
        }
        let retryPrompt = prompt + "\n\nYour previous attempt was \(first.text.count) characters — over the \(spec.charLimit)-character limit. Rewrite it well under \(spec.charLimit) characters."
        if let second = try? await assistant.generateStructured(
            prompt: retryPrompt, context: context, resultType: GeneratedPlatformPost.self),
           RepurposePlatformSpecs.fits(second.text, spec: spec) {
            return PlatformPostVariant(platform: spec.platform, text: second.text, failure: nil)
        }
        return PlatformPostVariant(platform: spec.platform, text: nil,
                                   failure: "Couldn't fit \(spec.platform)'s \(spec.charLimit)-character limit.")
    }
}
#endif
```

- [ ] **Step 4: Implement the chat tools**

```swift
// Sources/AnglesiteCore/RepurposePostTool.swift
import Foundation

/// Pure chat rendering of repurposed variants, non-gated for CI tests.
public enum RepurposeReply {
    public static func text(postTitle: String, variants: [PlatformPostVariant]) -> String {
        var lines = ["Platform posts for \"\(postTitle)\" — copy-paste what you like (Anglesite never posts for you):", ""]
        for v in variants {
            if let text = v.text {
                lines.append("\(v.platform):")
                lines.append(text)
            } else {
                lines.append("\(v.platform): \(v.failure ?? "unavailable")")
            }
            lines.append("")
        }
        lines.append("After you publish, tell me the published URLs and I'll record them on the post with saveSyndication.")
        return lines.joined(separator: "\n")
    }
}

#if compiler(>=6.4)
import FoundationModels

/// Chat front-door for repurposing one post into per-platform variants (#465).
public struct RepurposePostTool: Tool, Sendable {
    public static let toolName = "repurposePost"
    public let name = RepurposePostTool.toolName
    public let description = "Turn one published blog post into ready-to-paste social posts for each platform (Instagram, Facebook, Google Business, Nextdoor, X, Bluesky), respecting each platform's length rules."

    @Generable
    public struct Arguments {
        @Guide(description: "The post's slug, e.g. 'coast-trip' for src/content/posts/coast-trip.mdoc.")
        public var slug: String
    }

    private let repurposer: any PostRepurposing
    private let conventionsStore: ProjectConventionsStore?
    private let siteID: String
    private let siteDirectory: URL

    public init(repurposer: any PostRepurposing, conventionsStore: ProjectConventionsStore?,
                siteID: String, siteDirectory: URL) {
        self.repurposer = repurposer
        self.conventionsStore = conventionsStore
        self.siteID = siteID
        self.siteDirectory = siteDirectory
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let post = PostSource.load(slug: arguments.slug, sourceDirectory: siteDirectory) else {
            return "I couldn't find a post with the slug \"\(arguments.slug)\"."
        }
        let configURL = siteDirectory.appendingPathComponent(".site-config")
        let domain = (try? String(contentsOf: configURL, encoding: .utf8))
            .flatMap { SiteConfigFile.value(forKey: "SITE_DOMAIN", in: $0) } ?? "example.com"
        let postURL = PostSource.postURL(domain: domain, collection: post.collection, slug: post.slug)
        let conventions = await conventionsStore?.load()
        let preamble = BrandVoiceGuidance.preamble(
            conventions: conventions, businessType: SiteBusinessType.read(sourceDirectory: siteDirectory))
        let variants = await repurposer.variants(
            post: post, postURL: postURL, specs: RepurposePlatformSpecs.all,
            preamble: preamble, siteID: siteID, siteDirectory: siteDirectory)
        return RepurposeReply.text(postTitle: post.title, variants: variants)
    }
}

/// Deterministic POSSE write-back (#465): records published-copy URLs into the post's
/// `syndication:` frontmatter. No FM involved.
public struct SaveSyndicationTool: Tool, Sendable {
    public static let toolName = "saveSyndication"
    public let name = SaveSyndicationTool.toolName
    public let description = "Record the published social-post URLs on a blog post's syndication list (POSSE trail). Call after the owner has posted and shared the URLs."

    @Generable
    public struct Arguments {
        @Guide(description: "The post's slug.")
        public var slug: String
        @Guide(description: "The published URLs, comma-separated.")
        public var urls: String
    }

    private let siteDirectory: URL
    public init(siteDirectory: URL) { self.siteDirectory = siteDirectory }

    public func call(arguments: Arguments) async throws -> String {
        guard let post = PostSource.load(slug: arguments.slug, sourceDirectory: siteDirectory) else {
            return "I couldn't find a post with the slug \"\(arguments.slug)\"."
        }
        let urls = BrandVoiceInterview.list(arguments.urls)
        guard !urls.isEmpty else { return "I need at least one published URL." }
        let fileURL = siteDirectory.appendingPathComponent(post.filePath)
        do {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            try SyndicationFrontmatter.adding(urls: urls, to: contents)
                .write(to: fileURL, atomically: true, encoding: .utf8)
            return "Recorded \(urls.count) syndication URL\(urls.count == 1 ? "" : "s") on \"\(post.title)\"."
        } catch {
            return "Couldn't update the post: \(error.localizedDescription)"
        }
    }
}
#endif
```

- [ ] **Step 5: Wire into the assistant**

`FoundationModelAssistant.swift`: add `postRepurposer: (any PostRepurposing)? = nil` init param + property. `conversationTools`:

```swift
        if let postRepurposer {
            tools.append(RepurposePostTool(
                repurposer: postRepurposer, conventionsStore: conventionsStore,
                siteID: context.siteID, siteDirectory: context.siteDirectory))
            tools.append(SaveSyndicationTool(siteDirectory: context.siteDirectory))
        }
```

`attachedToolNames`: `if postRepurposer != nil { names.append(RepurposePostTool.toolName); names.append(SaveSyndicationTool.toolName) }`.
`SiteAssistantSessionFactory.swift`: pass `postRepurposer: PostRepurposerFactory.makeDefault()`.

- [ ] **Step 6: Run tests + full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path . --filter PostRepurposerTests`
Expected: PASS (3 tests). Full suite: all PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteCore/GenerableTypes.swift Sources/AnglesiteCore/PostRepurposer.swift Sources/AnglesiteCore/RepurposePostTool.swift Sources/AnglesiteCore/FoundationModelAssistant.swift Sources/AnglesiteApp/SiteAssistantSessionFactory.swift Tests/AnglesiteCoreTests/PostRepurposerTests.swift
git commit -m "feat: post repurposer with Swift-enforced limits + chat tools (#465)"
```

---

### Task 16: Repurpose GUI (variants sheet + navigator entry) + `RepurposePostIntent`

**Files:**
- Create: `Sources/AnglesiteApp/RepurposeModel.swift`
- Create: `Sources/AnglesiteApp/RepurposeView.swift`
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift`, `Sources/AnglesiteApp/SiteWindow.swift`, the navigator's post context-menu (find with `grep -rn "contextMenu" Sources/AnglesiteApp/SiteNavigator*.swift` — add "Repurpose Post…" beside the existing post commands from the #518/#586 sweep)
- Modify: `Sources/AnglesiteIntents/ContentHelpIntents.swift` (add `RepurposePostIntent`)

**Interfaces:**
- Consumes: `PostRepurposing`/`PostRepurposerFactory`, `PostSource`, `RepurposePlatformSpecs`, `PlatformPostVariant`, `SyndicationFrontmatter`, `BrandVoiceGuidance`, `SiteConfigValues`, `ContentHelpDialogs` (all prior tasks).
- Produces: `RepurposeModel` (`@Observable @MainActor`, `Identifiable`), `RepurposeView` (per-platform copy buttons + `ShareLink` + published-URL fields + deterministic Save), `RepurposePostIntent`, `SiteWindowModel.presentRepurpose(slug: String)`.

- [ ] **Step 1: Implement the model**

```swift
// Sources/AnglesiteApp/RepurposeModel.swift
import Foundation
import Observation
import AnglesiteCore

/// Drives the Repurpose sheet (#465): generate per-platform variants for one post, offer
/// copy/share, then deterministically record published URLs as the post's syndication trail.
@Observable @MainActor
final class RepurposeModel: Identifiable {
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
    var unavailable: Bool { repurposer == nil }

    init(siteID: String, sourceDirectory: URL, slug: String, conventionsStore: ProjectConventionsStore,
         repurposer: (any PostRepurposing)? = PostRepurposerFactory.makeDefault()) {
        self.siteID = siteID
        self.sourceDirectory = sourceDirectory
        self.slug = slug
        self.conventionsStore = conventionsStore
        self.repurposer = repurposer
    }

    func generate() async {
        guard let repurposer, !running else { return }
        running = true
        defer { running = false }
        guard let post = PostSource.load(slug: slug, sourceDirectory: sourceDirectory) else {
            errorMessage = "Couldn't load the post \"\(slug)\"."
            return
        }
        self.post = post
        let configURL = sourceDirectory.appendingPathComponent(".site-config")
        let domain = (try? String(contentsOf: configURL, encoding: .utf8))
            .flatMap { SiteConfigFile.value(forKey: "SITE_DOMAIN", in: $0) } ?? "example.com"
        let conventions = await conventionsStore.load()
        let preamble = BrandVoiceGuidance.preamble(
            conventions: conventions, businessType: SiteBusinessType.read(sourceDirectory: sourceDirectory))
        variants = await repurposer.variants(
            post: post,
            postURL: PostSource.postURL(domain: domain, collection: post.collection, slug: post.slug),
            specs: RepurposePlatformSpecs.all,
            preamble: preamble, siteID: siteID, siteDirectory: sourceDirectory)
    }

    func saveSyndication() {
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
            errorMessage = "Couldn't record the syndication URLs: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: Implement the view**

```swift
// Sources/AnglesiteApp/RepurposeView.swift
import SwiftUI
import AnglesiteCore

struct RepurposeView: View {
    @Bindable var model: RepurposeModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Repurpose “\(model.post?.title ?? model.slug)”").font(.title2.bold())
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if model.unavailable {
                ContentUnavailableView(
                    "Apple Intelligence Required", systemImage: "sparkles",
                    description: Text(ContentHelpDialogs.assistantUnavailable(feature: "Repurposing")))
            } else if model.variants.isEmpty && !model.running {
                Text("Drafts platform-sized posts for this article. Anglesite never posts for you — copy each one out, then record the published URLs below.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.variants, id: \.platform) { variant in
                            variantCard(variant)
                        }
                    }
                }
                HStack {
                    Spacer()
                    if model.syndicationSaved {
                        Label("Syndication recorded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Button("Record Published URLs") { model.saveSyndication() }
                        .disabled(model.publishedURLs.values.allSatisfy(\.isEmpty) || model.syndicationSaved)
                }
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
        .task { if model.variants.isEmpty { await model.generate() } }
    }

    private func variantCard(_ variant: PlatformPostVariant) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(variant.platform).font(.headline)
                Spacer()
                if let text = variant.text {
                    Text("\(text.count) chars").font(.caption).foregroundStyle(.secondary)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                }
            }
            if let text = variant.text {
                Text(text)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                TextField("Published URL (paste after posting)", text: Binding(
                    get: { model.publishedURLs[variant.platform] ?? "" },
                    set: { model.publishedURLs[variant.platform] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            } else {
                Text(variant.failure ?? "Unavailable").foregroundStyle(.secondary).italic()
            }
        }
    }
}
```

- [ ] **Step 3: Wire presentation + navigator entry**

`SiteWindowModel.swift`: `var repurposeModel: RepurposeModel?` and

```swift
    func presentRepurpose(slug: String) {
        repurposeModel = RepurposeModel(
            siteID: site.id, sourceDirectory: site.sourceDirectory, slug: slug,
            conventionsStore: <same store expression as Tasks 10/13>)
    }
```

`SiteWindow.swift`: `.sheet(item: $bindableModel.repurposeModel) { RepurposeView(model: $0) }`.

Navigator: find the post row context menu (`grep -rn "contextMenu" Sources/AnglesiteApp/SiteNavigator*.swift`) and add, beside the existing post commands (Duplicate/Rename etc. from the #518 sweep):

```swift
        Button("Repurpose Post…") { windowModel.presentRepurpose(slug: <the row's post slug>) }
```

(Adapt the accessor to however the navigator row exposes its `SiteContentGraph.Post` — the slug is `post.slug`. Memory note: content posts are `.route` targets in the navigator; the context-menu item goes on post rows regardless of their open-target kind.)

- [ ] **Step 4: Add `RepurposePostIntent`**

Append to `Sources/AnglesiteIntents/ContentHelpIntents.swift`:

```swift
public struct RepurposePostIntent: AppIntent {
    public static let title: LocalizedStringResource = "Repurpose Post"
    public static let description = IntentDescription(
        "Draft platform-sized social posts from one of a site's blog posts.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Post Slug", description: "The post's slug, e.g. 'coast-trip'.")
    public var slug: String

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Repurpose \(\.$slug) from \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let sourceDirectory = site.directory else {
            return .result(value: "", dialog: "\(IntegrationDialogs.failed(reason: "site folder unavailable", siteName: site.displayName))")
        }
        guard let repurposer = PostRepurposerFactory.makeDefault() else {
            return .result(value: "", dialog: "\(ContentHelpDialogs.assistantUnavailable(feature: "Repurposing"))")
        }
        guard let post = PostSource.load(slug: slug, sourceDirectory: sourceDirectory) else {
            return .result(value: "", dialog: "\(IntegrationDialogs.failed(reason: "no post named \(slug)", siteName: site.displayName))")
        }
        let configURL = sourceDirectory.appendingPathComponent(".site-config")
        let domain = (try? String(contentsOf: configURL, encoding: .utf8))
            .flatMap { SiteConfigFile.value(forKey: "SITE_DOMAIN", in: $0) } ?? "example.com"
        let businessType = SiteBusinessType.read(sourceDirectory: sourceDirectory)
        let variants = await repurposer.variants(
            post: post,
            postURL: PostSource.postURL(domain: domain, collection: post.collection, slug: post.slug),
            specs: RepurposePlatformSpecs.all,
            preamble: BrandVoiceGuidance.preamble(conventions: nil, businessType: businessType),
            siteID: site.id, siteDirectory: sourceDirectory)
        let failed = variants.filter { $0.text == nil }.count
        let block = RepurposeReply.text(postTitle: post.title, variants: variants)
        return .result(
            value: block,
            dialog: "\(ContentHelpDialogs.repurposeSummary(postTitle: post.title, platformCount: variants.count - failed, failedCount: failed))")
    }
}
```

- [ ] **Step 5: Full suite + app build**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: all PASS.
Then verify the app target still builds: `xcodegen generate && ANGLESITE_PLUGIN_SRC=/Users/dwk/Developer/github.com/Anglesite/anglesite scripts/copy-plugin.sh && xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` → BUILD SUCCEEDED. (Memory: if the build fails with "Too many levels of symbolic links", remove the self-pointing `Resources/plugin` symlink and re-run copy-plugin.sh.)

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/RepurposeModel.swift Sources/AnglesiteApp/RepurposeView.swift Sources/AnglesiteApp/SiteWindowModel.swift Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteIntents/ContentHelpIntents.swift
git add -A Sources/AnglesiteApp  # navigator context-menu file
git commit -m "feat: repurpose GUI sheet, navigator entry + RepurposePostIntent (#465)"
```

---

## Phase E — Wrap-up

### Task 17: Full verification, docs, PR

**Files:**
- Modify: `CLAUDE.md` (status line for #465 under "Other active tracks" / removal-epic paragraph)
- No new code.

- [ ] **Step 1: Full test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .`
Expected: all PASS, zero skips beyond the known gated e2e suites. Fix anything red before proceeding.

- [ ] **Step 2: App build + manual smoke**

`xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build` → BUILD SUCCEEDED.
Manual GUI smoke (needs a machine with Apple Intelligence): open a site → Review Copy… runs and renders findings; Social Media Plan… generates and saves `docs/social-calendar.md`; a post's context menu shows Repurpose Post… and variants respect char limits; chat lists the new tools in its attached-tools line. Record results in the PR description (or file a follow-up GUI-smoke issue like #491 if no Apple Intelligence machine is at hand — say so explicitly, don't claim it smoke-tested).

- [ ] **Step 3: Update CLAUDE.md**

In the **Claude Code removal epic (#459)** paragraph, update the slice status sentence to record that Slice 6 (#465) has landed (copy-edit / social-media / repurpose on FM via the content-help kernel; slices 5 and 7 remain as they then stand — check `gh issue view 464 466` and reflect reality at merge time).

- [ ] **Step 4: Push and open the PR**

```bash
git push -u origin claude/issue-465-solutions-db49b6
gh pr create \
  --title "feat: Slice 6 — content help on Foundation Models (copy-edit, social-media, repurpose) (#465)" \
  --body "$(cat <<'EOF'
Implements #465 per docs/superpowers/specs/2026-07-10-slice6-content-help-fm-design.md.

- Shared kernel: BrandVoiceGuidance (ProjectConventions preamble + audience/avoidPhrases fields + interview), SiteContentChunker (whole-site enumeration, 2k-char caps), ContentAssistantFactory (tier seam shared with #464).
- Copy-edit: chunked 10-point audit → CopyEditReport; findings → annotations; deterministic diff-confirmed excerpt rewrite. Front-doors: reviewCopy tool, Review Copy… sheet, ReviewCopyIntent.
- Social: platform catalog by business type + FM bios/pillars/week-by-week calendar → docs/social-calendar.md. Front-doors: planSocialMedia tool (confirm-before-write), Social Media Plan… sheet, PlanSocialMediaIntent.
- Repurpose: per-platform variants with Swift-enforced char limits (retry-then-fail, never truncate) + deterministic syndication write-back. Front-doors: repurposePost/saveSyndication tools, Repurpose sheet + navigator entry, RepurposePostIntent.

All FM code gated #if compiler(>=6.4); pure prompt/aggregation/validation helpers unit-tested on CI. No network I/O; nothing posts externally.

Closes #465.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh issue edit 465 --remove-label status:in-progress
```

- [ ] **Step 5: Post-PR follow-ups (file as issues, one each)**

- Remaining Bucket-5 capabilities on this kernel: `reputation`, `animate`, `i18n` translation, `convert`/`import` cleanup, commerce copy (reference spec §1).
- Deploy-time copy-quality report hook (`reports/copy-edit-report.md` parity).
- Thread per-window `ProjectConventionsStore` into the App Intents (they currently pass `conventions: nil`).
- Enrich `SocialPlatformCatalog` from the SMB guides + seasonal-calendar data.

## Plan self-review notes

- **Spec coverage:** kernel §4.1–4.5 → Tasks 1–6; copy-edit §5.1 → Tasks 7–10; social §5.2 → Tasks 11–13; repurpose §5.3 → Tasks 14–16; errors/privacy §6 → unavailable states + partial reports + no-network throughout; testing §7 → pure-above-gate tests per task; rollout §8 → Task 17.
- **Known approximations an executor must resolve on the ground (marked inline):** the exact `SiteWindowModel` store/site expressions (Tasks 10/13/16), the commands file hosting the Style Guide menu item, the navigator post context-menu location, intent registration mechanics, and the legacy-JSON fixture encoding shape (Task 1). Each has a grep anchor and a stated pattern to mirror.
- **Type consistency verified:** `ContentChunk`/`CopyFindingDraft`/`CopyEditReport`/`SocialMediaPlan`/`PlatformPostVariant` signatures match across producing and consuming tasks; all factories follow `makeDefault() -> (any P)?`; all four assistant dependencies (`conventionsStore`, `copyEditAuditor`, `socialMediaPlanner`, `postRepurposer`) are optional-with-default so intermediate tasks keep the build green.







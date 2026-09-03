# AI-Interpretation Table Expansion Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `LicenseCatalog`'s boolean `permitsAIUse` classification with a three-state `AIInterpretation` (permits / unclear / prohibits), add one new catalog entry (Public Domain Mark 1.0), and give "All rights reserved" and "Custom…" their own explicit interpretation in the first-publish license gate's comparison table — closing part of #999 ("expand the AI-interpretation column beyond CC0/CC BY/CC BY-SA").

**Architecture:** Pure model change in `AnglesiteCore/LicenseCatalog.swift` (one enum replaces one bool, plus one new entry), consumed by three existing call sites (`prefilled`, `coherenceWarning`, `LicenseGateSheetView`'s "AI systems" column). No new files, no new UI surfaces — this only changes what a table cell says and which licenses have a row.

**Tech Stack:** Swift 6.4, Swift Testing (`@Suite`/`@Test`/`#expect`), SwiftUI.

## Global Constraints

- Never reclassify a license the model can't defend. Per `docs/superpowers/specs/2026-07-26-really-simple-licensing-spike.md` §Q3 and the existing doc comment on `LicenseCatalog`: whether AI training is a "derivative work" or "commercial use" is a live legal question, so CC BY-NC/BY-ND/BY-NC-SA/BY-NC-ND stay `.unclear` — this plan does not touch their classification, only the *type* it's expressed in.
- No third-party dependencies; Apple frameworks / stdlib only (unchanged from current file).
- Owner review gate: per issue #999's comment thread (2026-08-15), the expanded table "goes through owner review in the PR" — this plan implements the draft; it does not claim final legal sign-off.
- Conventional commits, subject ≤72 chars, reference `#999`.

---

### Task 1: `AIInterpretation` enum + catalog migration

**Files:**
- Modify: `Sources/AnglesiteCore/LicenseCatalog.swift`
- Test: `Tests/AnglesiteCoreTests/LicenseCatalogTests.swift`

**Interfaces:**
- Produces: `public enum AIInterpretation: String, Sendable, Equatable, CaseIterable { case permits, unclear, prohibits }`; `LicenseCatalog.Entry.aiInterpretation: AIInterpretation` (replaces `permitsAIUse: Bool`); `LicenseCatalog.allRightsReservedInterpretation: AIInterpretation` (static constant, `.prohibits`).

- [ ] **Step 1: Write the failing test for the richer classification**

Replace the existing `classification` test in `Tests/AnglesiteCoreTests/LicenseCatalogTests.swift` (lines 20-24) with:

```swift
    @Test("only CC0, CC BY, CC BY-SA, and Public Domain Mark are classified as permitting AI use")
    func classification() {
        let permitting = Set(LicenseCatalog.entries.filter { $0.aiInterpretation == .permits }.map(\.id))
        #expect(permitting == ["cc0-1.0", "cc-by-4.0", "cc-by-sa-4.0", "pdm-1.0"])
        let unclear = Set(LicenseCatalog.entries.filter { $0.aiInterpretation == .unclear }.map(\.id))
        #expect(unclear == ["cc-by-nc-4.0", "cc-by-nd-4.0", "cc-by-nc-sa-4.0", "cc-by-nc-nd-4.0"])
    }

    @Test("all-rights-reserved is classified as prohibiting AI use — it grants no permission at all")
    func allRightsReservedInterpretation() {
        #expect(LicenseCatalog.allRightsReservedInterpretation == .prohibits)
    }
```

Also update `entriesWellFormed` (line 11-18) — the count changes from 7 to 8:

```swift
    @Test("every catalog entry has a safe URL and a unique id")
    func entriesWellFormed() {
        #expect(LicenseCatalog.entries.count == 8)
        #expect(Set(LicenseCatalog.entries.map(\.id)).count == LicenseCatalog.entries.count)
        for entry in LicenseCatalog.entries {
            #expect(LicenseRef.isSafeLicenseURL(entry.url), "\(entry.id) has an unsafe URL")
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter LicenseCatalogTests`
Expected: FAIL — `entriesWellFormed` fails on count (7 != 8), `classification`/`allRightsReservedInterpretation` fail to compile (`aiInterpretation`/`allRightsReservedInterpretation` don't exist yet).

- [ ] **Step 3: Replace `permitsAIUse` with `aiInterpretation` and add the Public Domain Mark entry**

In `Sources/AnglesiteCore/LicenseCatalog.swift`, replace the whole file's top doc comment, `Entry` struct, `entries` array, and add the new enum, so the file reads:

```swift
import Foundation

/// The licenses the Content Licensing facet offers, and how each relates to the site's AI usage
/// permissions (#991) and to the first-publish license gate's "AI systems" comparison column
/// (#999).
///
/// The classification is deliberately narrow. Whether model training is a "derivative work" or a
/// "commercial use" is a live legal question, so only licenses whose grant unambiguously covers
/// any use are marked `.permits`; NC and ND variants, custom URLs, and all-rights-reserved get
/// `.unclear` unless a specific, defensible case exists to mark them otherwise (as
/// `allRightsReservedInterpretation` below does — an unlicensed work grants no permission by
/// construction, which is not the same live question NC/ND raise about an *existing* grant's
/// scope). That follows the spike's rule that Anglesite never asserts on the user's behalf — see
/// docs/superpowers/specs/2026-07-26-really-simple-licensing-spike.md §Q3.
public enum LicenseCatalog {
    /// How Anglesite reads a license's grant with respect to AI training/use. Three states, not
    /// two, so "we don't know" and "this affirmatively grants nothing" stay distinguishable —
    /// collapsing them back into a bool is what the #999 expansion was asked to stop doing.
    public enum AIInterpretation: String, Sendable, Equatable, CaseIterable {
        /// The license's grant unambiguously covers AI training and AI answers.
        case permits
        /// Not classified — the grant's scope with respect to AI use is a live legal question
        /// Anglesite declines to resolve on the user's behalf.
        case unclear
        /// No permission is granted at all (the all-rights-reserved default) — distinct from
        /// `.unclear`, which is about the *scope* of a grant that does exist.
        case prohibits
    }

    /// One offered license: stable picker identity, display strings, and the app-side AI-use
    /// classification (which is deliberately *not* part of what gets stored — see `ref`).
    public struct Entry: Sendable, Equatable, Hashable, Identifiable {
        /// Stable across releases — it is the SwiftUI picker tag, not display text.
        public let id: String
        /// Display name shown in the picker, e.g. "CC BY 4.0".
        public let name: String
        /// Canonical deed URL — the identity `entry(for:)` matches stored licenses on.
        public let url: String
        /// How this license's grant reads with respect to AI training and AI answers.
        public let aiInterpretation: AIInterpretation

        /// The `LicenseRef` this entry stores and publishes — URL + name only. The
        /// `aiInterpretation` classification stays app-side, because it is Anglesite's reading of
        /// the license, not something to assert on the user's behalf (see the type doc).
        public var ref: LicenseRef { LicenseRef(url: url, name: name) }
    }

    /// The offered licenses in picker order: CC0 and Public Domain Mark first, then the CC 4.0
    /// suite from most to least permissive. Extending this list requires the same "unambiguous
    /// grant" test the type doc describes before marking an entry `.permits`.
    public static let entries: [Entry] = [
        Entry(id: "cc0-1.0", name: "CC0 1.0",
              url: "https://creativecommons.org/publicdomain/zero/1.0/", aiInterpretation: .permits),
        Entry(id: "pdm-1.0", name: "Public Domain Mark 1.0",
              url: "https://creativecommons.org/publicdomain/mark/1.0/", aiInterpretation: .permits),
        Entry(id: "cc-by-4.0", name: "CC BY 4.0",
              url: "https://creativecommons.org/licenses/by/4.0/", aiInterpretation: .permits),
        Entry(id: "cc-by-sa-4.0", name: "CC BY-SA 4.0",
              url: "https://creativecommons.org/licenses/by-sa/4.0/", aiInterpretation: .permits),
        Entry(id: "cc-by-nc-4.0", name: "CC BY-NC 4.0",
              url: "https://creativecommons.org/licenses/by-nc/4.0/", aiInterpretation: .unclear),
        Entry(id: "cc-by-nd-4.0", name: "CC BY-ND 4.0",
              url: "https://creativecommons.org/licenses/by-nd/4.0/", aiInterpretation: .unclear),
        Entry(id: "cc-by-nc-sa-4.0", name: "CC BY-NC-SA 4.0",
              url: "https://creativecommons.org/licenses/by-nc-sa/4.0/", aiInterpretation: .unclear),
        Entry(id: "cc-by-nc-nd-4.0", name: "CC BY-NC-ND 4.0",
              url: "https://creativecommons.org/licenses/by-nc-nd/4.0/", aiInterpretation: .unclear),
    ]

    /// "All rights reserved" — the untouched-scaffold default — is not a catalog entry (it has no
    /// URL), but the first-publish gate's comparison table asks the same interpretation question
    /// about it. An unlicensed work grants no permission under copyright law absent a stated TDM
    /// exception, so this is `.prohibits` rather than `.unclear`: unlike NC/ND (a live question
    /// about how far an *existing* grant reaches), there is no grant here to be uncertain about.
    public static let allRightsReservedInterpretation: AIInterpretation = .prohibits

    /// The catalog entry a stored license refers to, matched on URL — a hand-edited `name` should
    /// not stop the picker recognizing a standard license. nil means custom or none.
    public static func entry(for license: LicenseRef?) -> Entry? {
        guard let license else { return nil }
        return entries.first { $0.url == license.url }
    }

    /// Suggests AI permissions consistent with a newly-chosen license, filling **only** purposes
    /// the user has not stated. Overwriting a stated purpose would silently discard a deliberate
    /// choice, so this never does; an unclassified license suggests nothing at all.
    public static func prefilled(_ usage: AIUsage, for license: LicenseRef?) -> AIUsage {
        guard entry(for: license)?.aiInterpretation == .permits else { return usage }
        var filled = usage
        if filled.search == .unset { filled.search = .yes }
        if filled.aiInput == .unset { filled.aiInput = .yes }
        if filled.aiTrain == .unset { filled.aiTrain = .yes }
        return filled
    }

    /// Why the facet should show an inline note, or nil when there is nothing to say. The typed
    /// case (rather than a `String`) keeps user-facing copy in the app module where Xcode's string
    /// extraction can reach it.
    public enum CoherenceWarning: Sendable, Equatable {
        /// The site default license already grants an AI use the policy asks crawlers not to make.
        case licensePermitsDeniedUse(licenseName: String)
    }

    /// Fires only for a classified license against a denied AI purpose — the one contradiction
    /// detectable without interpreting license text. Permitting *more* than a restrictive license
    /// requires is never flagged: it is the user's own content, and they may grant what they like.
    /// `search` is not an AI purpose and never triggers this.
    public static func coherenceWarning(for license: LicenseRef?, usage: AIUsage) -> CoherenceWarning? {
        guard let entry = entry(for: license), entry.aiInterpretation == .permits else { return nil }
        guard usage.aiInput == .no || usage.aiTrain == .no else { return nil }
        return .licensePermitsDeniedUse(licenseName: entry.name)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter LicenseCatalogTests`
Expected: PASS — all `LicenseCatalogTests` cases green.

- [ ] **Step 5: Run the full `AnglesiteCoreTests` suite to catch any other `permitsAIUse` reference**

Run: `swift test --package-path . --filter AnglesiteCoreTests`
Expected: PASS. If anything else references `permitsAIUse`, this fails with a compile error naming the file — fix it using the same `aiInterpretation` rename before moving on (Task 2 below already covers the one other known call site, `LicenseGateSheetView.swift`, which is `AnglesiteApp`, not `AnglesiteCoreTests` — a hit here would mean an undiscovered third call site).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/LicenseCatalog.swift Tests/AnglesiteCoreTests/LicenseCatalogTests.swift
git commit -m "feat(#999): expand license AI-interpretation to a 3-state model"
```

---

### Task 2: Update `LicenseGateSheetView`'s "AI systems" column

**Files:**
- Modify: `Sources/AnglesiteApp/LicenseGateSheetView.swift`
- Test: `Tests/AnglesiteAppTests/LicenseGateSelectionTests.swift`

**Interfaces:**
- Consumes: `LicenseCatalog.AIInterpretation` (Task 1), `LicenseCatalog.allRightsReservedInterpretation` (Task 1), `LicenseCatalog.Entry.aiInterpretation` (Task 1).
- Produces: `LicenseGateSheetView.aiInterpretationLabel(_:) -> LocalizedStringKey` (private, but the table row values it drives are covered by Step 1's test via `permitsSummary`-style verification — see Step 1).

- [ ] **Step 1: Write the failing test**

`LicenseGateSelectionTests.swift` currently tests `LicenseGateSheetView.Selection` in isolation (it doesn't render the view). Since `aiInterpretationLabel` is a private view method, test it indirectly through the public classification it's driven by — add this to `Tests/AnglesiteAppTests/LicenseGateSelectionTests.swift` (inside the existing `@Suite` struct, wherever the other `@Test`s live):

```swift
    @Test("every catalog entry's AI interpretation has a defined row label")
    func everyInterpretationIsCovered() {
        // LicenseGateSheetView.aiInterpretationLabel is private and unrenderable in a unit
        // test, so this pins the *input* it must handle: every case of AIInterpretation, so a
        // future case added to the enum without a matching row label fails loudly instead of
        // silently falling through to a default.
        #expect(LicenseCatalog.AIInterpretation.allCases == [.permits, .unclear, .prohibits])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter LicenseGateSelectionTests`
Expected: FAIL to compile — `AnglesiteAppTests` doesn't yet import/see `LicenseCatalog.AIInterpretation` as a 3-case enum (it does via Task 1's `AnglesiteCore` change already merged, so this specific test should actually PASS once Task 1 lands — if it fails, it's confirming the enum shape, which is the point: run it now to confirm the baseline before editing the view).

- [ ] **Step 3: Update the view**

In `Sources/AnglesiteApp/LicenseGateSheetView.swift`:

Change the `row(...)` signature (lines 169-172) — `aiNote` is no longer optional:

```swift
    private func row(
        title: LocalizedStringKey, permits: LocalizedStringKey, aiNote: LocalizedStringKey,
        choice: Selection.Choice
    ) -> some View {
```

Update the body of `row(...)` (line 182) to drop the `?? "—"` fallback:

```swift
                Text(aiNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: Self.aiColumnWidth, alignment: .leading)
```

Update the three call sites in `body` (lines 99-113):

```swift
                row(title: "All rights reserved", permits: "Nothing without asking",
                    aiNote: aiInterpretationLabel(LicenseCatalog.allRightsReservedInterpretation),
                    choice: .allRightsReserved)

                ForEach(LicenseCatalog.entries) { entry in
                    row(
                        // A license's own name ("CC BY 4.0") is catalog data, not UI copy, so
                        // it is deliberately not a literal key for extraction — the runtime
                        // lookup just falls back to the name itself.
                        title: LocalizedStringKey(entry.name),
                        permits: permitsSummary(for: entry),
                        aiNote: aiInterpretationLabel(entry.aiInterpretation),
                        choice: .catalog(entry.id))
                }

                row(title: "Custom…", permits: "Your own terms",
                    aiNote: aiInterpretationLabel(.unclear), choice: .custom)
```

Add the new label helper right after `permitsSummary(for:)` (after line 221, before the closing `}` of the view struct):

```swift

    /// Row copy for the "AI systems" column, keyed by the 3-state classification (#999) rather
    /// than a bare bool — see `LicenseCatalog.AIInterpretation`.
    private func aiInterpretationLabel(_ interpretation: LicenseCatalog.AIInterpretation) -> LocalizedStringKey {
        switch interpretation {
        case .permits: return "✅ Permits"
        case .unclear: return "❔ Unclear"
        case .prohibits: return "🚫 Prohibits"
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter LicenseGateSelectionTests`
Expected: PASS.

- [ ] **Step 5: Build the app target to catch any SwiftUI compile error the test suite can't**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED. (`swift test` doesn't compile the app target's every file the same way a full app build does — run this because `LicenseGateSheetView.swift` is SwiftUI view code with no unit-test render pass.)

- [ ] **Step 6: Run the full AnglesiteAppTests suite**

Run: `swift test --package-path . --filter AnglesiteAppTests`
Expected: PASS — confirms nothing else in `AnglesiteApp` broke from the `permitsAIUse` → `aiInterpretation` rename.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/LicenseGateSheetView.swift Tests/AnglesiteAppTests/LicenseGateSelectionTests.swift
git commit -m "feat(#999): show 3-state AI interpretation in the license gate table"
```

---

## Self-Review Notes

- **Spec coverage:** Issue #999's fourth scope item — "expand the table beyond CC0/BY/BY-SA... anything not explicitly classified must remain explicitly unresolved" — is covered: NC/ND variants are untouched (still `.unclear`), one new entry (Public Domain Mark) is added with a defensible `.permits` classification, and "All rights reserved"/"Custom…" get explicit (not silently blank) interpretations for the first time.
- **Scope not covered here:** this plan only touches the picker/gate surface. `ContentLicensingTab.swift` (Settings ▸ Licensing) does not currently render an AI-interpretation column at all — confirmed by grep, no `permitsAIUse`/`aiNote` references there — so it needs no change.
- **Owner review:** flag in the PR description that the Public Domain Mark addition and the "All rights reserved → prohibits" classification are the two *new* judgment calls in this table and should get explicit sign-off, per the issue's own requirement that this goes through owner review.

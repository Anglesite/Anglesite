# WYSIWYG slice 6 — on-device AI services — design

Tracking: [#1227](https://github.com/Anglesite/Anglesite/issues/1227), part of epic
[#1221](https://github.com/Anglesite/Anglesite/issues/1221). Implements spec §6 of
[`2026-08-03-modern-wysiwyg-editor-design.md`](2026-08-03-modern-wysiwyg-editor-design.md)
(the "AI — assistive, never authoritative" bullets; quality gates, the other
half of spec §6, is a separate already-closed slice, [#1226](https://github.com/Anglesite/Anglesite/issues/1226)).

## 1. Summary

Three on-device AI services for the WYSIWYG canvas — alt-text proposals on
image insert, writing help (rewrite/tighten/tone) on text selections, and
block-type suggestions ("this looks like a testimonial") — each landing as
ordinary `Op` values through the existing ops pipeline (undo, version
checking, invertibility all come for free). All three are FoundationModels-only,
gated behind the established `Factory.makeDefault() -> (any Protocol)?`
convention so a Mac without Apple Intelligence simply doesn't render the
affordances. This ships as **three sequential PRs against one spec**:
alt-text proposals, writing help, block-type suggestions — in that order,
lowest-risk (an existing near-complete template) first.

## 2. Shared architecture

### Chips generalize, they don't fork

Slice 5 built `QualityGateRunner -> Finding{id, blockId, category, severity,
message, fix: Op?} -> _handleQualityFindings -> QualityGateChips` — a
deterministic-only pipeline. Alt-text and block-suggestion chips need the same
anchored, keyed-diff chip UI but with AI provenance and (for block
suggestions) a per-block dismiss action quality gates don't have.

`Finding` gains one new field: `origin: FindingOrigin` (`.qualityGate` |
`.aiSuggestion`, defaulting to `.qualityGate` so the wire format stays
backward compatible with `JS/wysiwyg-engine/src/quality-gates.ts`). A second
host-to-engine bridge call, `_handleAISuggestions`, feeds the same
`QualityGateChips` keyed-diff renderer on a separate channel so quality
findings and AI suggestions never collide on diff keys. One JS chip
component, two Swift-side producers, no bespoke UI convention per
capability.

### New shared Core pieces

- **`WYSIWYGDismissalStore`** — actor, persists per-site under
  `Config/wysiwyg-dismissals.json` (app-owned state, never committed to the
  site's git repo, per the existing `Config/` convention). Keyed by block ID
  + suggestion kind. Used by block-type suggestions (§5); alt-text and
  writing help don't need it (neither produces a repeatable nagging chip).
- **`ContentHelpDialogs.assistantUnavailable(feature:)`** (existing) covers
  the one place this slice needs an explicit unavailable message: the
  `rewriteBlock` chat tool (§4).

### Tier / FM substrate reuse

All three capabilities obtain their backend through the existing
`ContentAssistant` protocol and `Factory.makeDefault()` idiom — none
construct `FoundationModelAssistant` directly. `BrandVoiceGuidance` and
`ProjectConventions` (already shipped, from the unrelated but now-closed
#465) provide voice/tone grounding for alt-text and writing-help prompts for
free.

## 3. Alt-text proposals (PR 1)

Re-plumbs the legacy `AltTextGenerator.swift` (today used by
`MCPApplyEditRouter`'s post-processor, emitting `EditMessage`s for the
overlay-based editor) for the WYSIWYG image-drop path, without touching the
legacy overlay's own usage of it.

**Flow:** `SiteWindow.swift`'s image-drop handler (~1748-1796) already runs
sniff → license check (`WYSIWYGDropLicenseResolver`) → `WYSIWYGImageAssetIngestor.ingest`
→ `canvas.insertBlockAndSelect(...)`. A new step, `WYSIWYGAltTextProposer.propose(imageData:context:) async -> GeneratedAltText?`,
runs between ingest and `insertBlockAndSelect`, reusing
`FoundationModelAssistant.generateStructured(...resultType: GeneratedAltText.self)`
and the existing `AltTextPromptBuilder` (which already folds in
`ProjectConventions` guidance). The result seeds `props["alt"]` (and the
existing decorative-image / `role="presentation"` handling) on the
`insertBlock` op *before* it is submitted — one op, one undo entry. The
owner sees the proposed alt text live in the inspector's alt-text field
immediately after drop and can edit it or Undo the whole insert like any
other op; there is no separate accept/dismiss step.

**Availability / failure:** if FM is unavailable or the call fails or times
out, the insert proceeds with empty alt text exactly as it does today — a
silent degrade, not a blocking gate. Neither the pre-deploy accessibility
check nor the in-app quality gate flags an empty `alt` — both treat it as
intentionally decorative, matching how a manually-added decorative image is
already handled. A degraded proposal is therefore indistinguishable from a
deliberately decorative image; closing that gap (e.g. a quality-gate finding
for `alt=""` with no `role="presentation"`) is a reasonable follow-up for
PR 3's chip work, not this PR's job.

**Front-doors:** GUI only (the drop gesture itself). No chat tool or App
Intent — there is no meaningful voice/chat trigger for "the image I just
dropped."

## 4. Writing help — rewrite / tighten / tone (PR 2)

**Trigger:** a floating selection toolbar in the canvas engine
(`JS/wysiwyg-engine/`) appears on a non-empty text selection inside a
text-bearing block, offering **Rewrite**, **Tighten**, and **Tone ▾** (a
small preset menu — Friendlier, More Formal, More Confident; free-form tone
input is a fast-follow, not v1). Selecting an action posts
`{blockId, selectionRange, action, instruction?}` to the host over the
existing native-host-transport bridge.

**Host side:** `WritingHelpAssistant.rewrite(text:action:preamble:) async throws -> String`
(new Core type, `Factory.makeDefault()`-gated) makes one
`ContentAssistant.generate` call per invocation — selections are short, so
streaming isn't needed — with `BrandVoiceGuidance.preamble` folded in so
rewrites match the site's learned voice.

**Preview, not immediate apply.** The result comes back to the canvas as a
before/after preview in the selection toolbar with **Accept**/**Discard** —
unlike alt-text, there is no separate live field already showing the
proposed change, so the preview *is* the review step. Accept emits one
`editText` op replacing the selected run's text (via the same `RichTextRun`
diffing typing already uses); Discard emits nothing.

**Chat-tool front door:** `rewriteBlock(blockId, instruction)`, an FM `Tool`
operating on a whole block's plain text (not a live canvas selection),
callable from the site chat panel. Same preview-then-apply semantics; the
implementation plan will confirm the concrete chat-transcript affordance for
inline Accept against whatever action mechanism the chat UI already
supports. `ContentHelpDialogs.assistantUnavailable(feature:)` covers the
"not available on this Mac" case here, since it's plausible to ask for by
name in chat even when the canvas toolbar is simply absent.

**No App Intent** — neither Siri nor Shortcuts has a durable "current
selection" or "current block" concept to bind to.

## 5. Block-type suggestions — testimonial, FAQ, CTA (PR 3)

### Deterministic pre-filter

`BlockSuggestionHeuristic` (pure, Core, unit-tested) runs on block-edit
*settle* (the same debounce point `editText` op coalescing already uses for
undo, not on every keystroke), restricted to paragraph-ish text blocks
(headings/buttons/nav/etc. are skipped by block kind):

- **Testimonial-shaped:** a quoted span (curly or straight quotes) plus a
  short trailing attribution-like line (`— Name`, `- Name, Title`, or a
  final short line ≤ ~40 characters distinct from the quoted span).
- **FAQ-shaped:** a line ending in `?` followed by answer-like text, within
  one block or across two adjacent blocks.
- **CTA-shaped:** a short block (≤ ~25 words) opening with an imperative
  verb from a small fixed list ("Get", "Book", "Start", "Try", "Sign up", …)
  — this list is hand-maintained Swift data, not FM-derived.

Each heuristic only fires when the **active theme's block manifest**
declares a matching block type, checked against the same palette
`WYSIWYGCanvasController.blockPalette` already exposes — there's no point
proposing a block the theme can't offer.

### FM confirms and maps

One structured call per surviving candidate:
`@Generable GeneratedBlockSuggestion{matches: Bool, confidence, mappedProps: [String: String]}`.
The model both gates the remaining false-positive risk (it can say no) and
maps the block's own text into the target block's typed props — quote/author
for testimonial, question/answer for FAQ, label for CTA. CTA's `href` can't
be invented from text alone; it's left empty and flagged in the inspector
for the owner to fill in after applying.

### Chip and apply

Surfaces via the shared `_handleAISuggestions` bridge (§2): "This looks like
a testimonial — Use Testimonial block?" with **Apply**/**Dismiss**. Apply
composes `deleteBlock` (old) + `insertBlock` (new type, mapped props, same
parent/slot/index) as one submission — the implementation plan confirms
whether the undo coordinator already coalesces a multi-op submission into
one undo entry or needs a small addition to do so. Dismiss writes to
`WYSIWYGDismissalStore` keyed by block ID + suggestion kind and clears the
chip; a dismissed block is never re-suggested for that same suggestion kind.

## 6. Error handling & availability

- **FM unavailable** (`Factory.makeDefault()` → `nil`, per
  `SystemLanguageModel.availability`): all three capabilities hide their
  affordance outright — no AI buttons in the selection toolbar, no alt-text
  proposal (silent, per §3), no suggestion chips ever computed. No
  disabled-with-tooltip state is needed for the in-canvas surfaces since they
  simply don't render; the `rewriteBlock` chat tool is the one exception,
  returning `ContentHelpDialogs.assistantUnavailable(feature:)`'s message
  since it can be invoked by name.
- **FM call fails or times out mid-flow:** the writing-help preview shows an
  inline error in place of the diff ("Couldn't generate a rewrite — try
  again"); no partial op is ever submitted. Block-suggestion candidates that
  error are silently skipped — no chip, no retry — since this is a
  best-effort background suggestion, not a report the owner is waiting on.
- **No network I/O anywhere in this slice**, matching the on-device-only
  constraint already established for the app's other content-help features.
- **Stale versions:** every AI-emitted op still carries `targetVersion` like
  any op. If the model changed underneath a pending suggestion or preview
  (the owner kept typing), the existing rejection/replay path in
  `WYSIWYGCanvasController` handles it; a suggestion or preview computed
  against a stale version is discarded, never force-applied.

## 7. Testing

- Pure logic — heuristics, prompt builders, `Finding`/op composition,
  dismissal-store key logic, prop-mapping validation — as Swift Testing in
  `AnglesiteCoreTests`, unconditionally on CI (no FM/toolchain gate).
- FM-touching generators exercised through `ContentAssistant` fakes, the same
  pattern `CopyEditAuditor` and friends already use.
- JS chip-rendering changes (the `QualityGateChips` `origin` field, the
  selection toolbar) — existing `JS/wysiwyg-engine` vitest suite, extended
  for the `.aiSuggestion` origin and the new toolbar component.
- No live on-device model calls in CI, consistent with how every other FM
  feature in this app is tested (mocked `ContentAssistant`, never the real
  `FoundationModelAssistant`).

## 8. Out of scope (YAGNI)

- Free-form tone instructions for writing help (preset menu only, v1).
- Block-type suggestions beyond testimonial/FAQ/CTA — a generic prop-mapping
  system is real design work that isn't justified until a fourth use case
  exists.
- `rewriteBlock` App Intent / Siri front-door (no durable selection/block
  context to bind to outside the canvas or an active chat turn).
- Any change to the quality-gates hard backstop (`pre-deploy-check.ts`) —
  unaffected by this slice.

## 9. Rollout

Three PRs against this one spec, in order:

1. **Alt-text proposals** — smallest surface, an existing near-complete
   template (`AltTextGenerator.swift`) to re-plumb; proves the "AI output
   lands as a reviewable-via-undo op" pattern end to end.
2. **Writing help** — new in-canvas selection toolbar + chat tool, reusing
   the same op-emission pattern established by PR 1.
3. **Block-type suggestions** — the new shared chip-generalization work
   (`Finding.origin`, `_handleAISuggestions`, `WYSIWYGDismissalStore`) lands
   here since it's the first capability that actually needs it; the
   heuristic + FM-confirm pattern carries the most false-positive risk of
   the three, so it ships last with the most groundwork already proven.

Only the PR that lands last should close #1227 with a closing keyword; PRs 1
and 2 reference #1227 without closing it, per `CONTRIBUTING.md`'s multi-PR
tracking-issue guidance.

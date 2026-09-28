# System One decision seam + received-interaction spam screen — design

**Date:** 2026-09-28
**Status:** current
**Issue:** #2058 (seam + gate, this design); #2059 (Core ML provider + model weights, owner decision)
**Related:** [`../../specs/2026-06-29-c3-received-interaction-canonicality.md`](../../specs/2026-06-29-c3-received-interaction-canonicality.md) (what a received interaction is and how it reaches git);
[`2026-08-10-hosted-community-provisioning-moderation-design.md`](2026-08-10-hosted-community-provisioning-moderation-design.md) §5 (the moderation pane the held queue lands in);
[`2026-08-16-external-llm-backend-design.md`](2026-08-16-external-llm-backend-design.md) (the LLM policy that rules out a hosted decision API on the Mac);
[`../../architecture.md`](../../architecture.md) ("one capability, one implementation"; the on-device boundary)

---

## 1. Problem

Every verified webmention, ActivityPub reply and Micropub submission the Worker accepts is
snapshotted into `Source/data/interactions/` and rendered on the site
(`ReceivedInteractionSync` → `ReceivedInteractionCommitter`). Verification proves the source
*links to* the target; it says nothing about whether the content is a genuine response or a
casino ad. Today the owner's only defence is deleting the file after it has already rendered —
a git operation on a surface CLAUDE.md says never shows git.

The same shape recurs elsewhere (join-request approval for hosted communities, intake triage in
the software factory, edit-kind classification before guided generation): a narrow semantic
judgement over text, where **code** should own the thresholds and side effects and the model
should supply only a calibrated probability. That is the "System One" pattern TypeSafe's Jev
popularised — typed questions (yes/no, pick-one, rubric score) answered as probability
distributions over a caller-fixed option set, never free text — and the open reproductions that
followed (Kev-0.5B, jevmlx, open-jev, open-alternative-jev, Bespoke Nimble) established that the
mechanism is model-agnostic: one prefill, logits read at the option positions, a softmax
restricted to the allowed options, temperature-scaled for calibration.

## 2. Decisions

| # | Question | Decision |
|---|---|---|
| S1 | Where does the judgement run? | **On device, via a Core ML readout model** (follow-up #2059). The Mac app's LLM policy allows off-device calls only as an explicit Settings opt-in; a moderation gate that silently ships every comment to a hosted API would violate it. The seam is model-agnostic so an opt-in hosted backend can be added later without touching the gate. |
| S2 | What does the model return? | **Probabilities over a fixed option set, plus a margin-based confidence.** No generated text anywhere in the gate. A type-invalid answer is unrepresentable. |
| S3 | Who owns thresholds and side effects? | **Application code** (`InteractionScreeningPolicy`). The model never decides what happens next. |
| S4 | What happens when the model is missing or fails? | **Fail open to today's behavior** (publish), logged once per batch to the debug pane. A gate that can hide comments when an asset download fails would be worse than no gate. |
| S5 | Can the gate delete anything? | **No.** A held interaction stays in the Worker's D1 inbox; the gate only decides whether it is snapshotted into git. `drop` exists in the verdict enum but is disabled by default (`dropThreshold: nil`) until a site's own calibration report justifies it. |
| S6 | What about sites that already show comments? | **Grandfathered.** An interaction whose snapshot already exists in `data/interactions/` is published without asking, so enabling the screen never un-publishes anything. |
| S7 | Where do decisions and owner rulings live? | **`Config/interaction-screening.json`** (app-owned, never in git — decision D6). It is both the moderation queue and the labelled set for calibration. |
| S8 | How is calibration handled? | **One temperature per provider, fitted on the owner's own Accept/Reject rulings** (`TemperatureCalibration.fit`). Below 20 labels it stays at identity: an overfitted temperature makes the confidence gate worse than none. ECE is reported, never gated on. |

## 3. Components

All in `AnglesiteCore`, pure Foundation, tested in `AnglesiteCorePortableTests` so the Linux
lane runs them.

### 3.1 `DecisionProvider` (`Sources/AnglesiteCore/AI/DecisionProvider.swift`)

- `DecisionQuestion` — `.noul(proposition)` (yes/no), `.choice(prompt:options:)` (2…255),
  `.score(prompt:levels:)` (2…10, ordered). `validate()` rejects blank, duplicate or wrong-count
  option sets before any model call.
- `DecisionAnswer` — `probabilities` in option order, `winnerIndex`, `confidence` = margin
  between the top two options (for a noul, `|2p − 1|`), `probabilityTrue` for nouls.
- `DecisionProvider` — `decide(state:questions:) -> [DecisionAnswer]`. Questions in one call are
  evaluated independently against the same state; answers never become context for each other.
- `OptionScorer` — the narrow backend surface: `score(state:question:) -> [Double]` raw logits.
  This is what the Core ML model implements (#2059) and what test fakes implement.
- `ScoringDecisionProvider` — validate → score → `DecisionScoring.softmax(logits / T)`. The one
  place calibration is applied, so every backend gets it for free.
- `DecisionScoring` — numerically stable restricted softmax; non-finite input degrades to uniform
  (zero confidence, which any gate holds for review).

### 3.2 `TemperatureCalibration` (`Sources/AnglesiteCore/AI/TemperatureCalibration.swift`)

Single-parameter temperature scaling. `fit(samples:)` minimises NLL by golden-section search over
`log T ∈ [−4, 4]`; deterministic, no dependencies. `expectedCalibrationError(samples:bins:)`
reports ECE for the calibration report. `Codable`, so a fitted temperature can sit beside the
model asset.

### 3.3 `InteractionScreener` (`Sources/AnglesiteCore/Social/InteractionScreening.swift`)

The gate. Per interaction, in order:

1. **Owner ruling** (`OwnerRuling` in the ledger) → publish or hold. Always wins.
2. **Already published** (snapshot exists) → publish (S6).
3. **Verified Vouch** → publish. The IndieWeb already defines this trust signal; no model needed.
4. **No content** (like, repost, bare mention) → publish. Text-only screening has nothing to judge.
5. **Model**: one `noul` — *"This interaction is spam, unsolicited advertising, or abuse, rather
   than a genuine response to the page it targets."* — over a compact labelled state
   (protocol, kind, source, author, target, vouch, content truncated to
   `maxContentCharacters`). Then `InteractionScreeningPolicy`:
   - `p ≥ dropThreshold` and confident → `drop` (disabled by default);
   - `p ≥ holdThreshold` (0.5) → `hold`;
   - `confidence < minimumConfidence` (0.3) → `hold` (the escalation gate: uncertain → person);
   - otherwise → `publish`.
6. **Model error** → publish, rule `modelUnavailable`, one log line per batch (S4).

Every input gets a `ScreeningDecision` (verdict, rule, `p(spam)`, confidence, log-probabilities,
timestamp). Log-probabilities are stored rather than the backend's raw logits because a softmax
is shift-invariant: they are an equivalent logit vector for fitting a temperature, and they don't
leak backend-specific scale into the ledger.

### 3.4 `InteractionScreeningLedger`

`Config/interaction-screening.json`: latest decision per id, owner rulings per id.
`held()` is the moderation queue (unruled holds, oldest first); `rule(_:approved:)` records the
owner's verdict; `calibrationSamples()` pairs model decisions with rulings (Reject ⇒ "yes" was
correct, Accept ⇒ "no") for `TemperatureCalibration.fit`. Corrupt or missing → empty; the next
sync re-screens, which is safe under S6.

### 3.5 Wiring

`ReceivedInteractionSync.pullAndCommit(client:siteDirectory:screener:ledger:)` and
`pullAndCommitIfConfigured(…, screener:)` take an optional screener. `nil` (the default, and the
app's call in `PreviewModel` today) is byte-for-byte the pre-screening path. With a screener,
only the `published` partition reaches `ReceivedInteractionCommitter.commit`, and every decision
is recorded. The reconcile's stale-file deletion is unaffected: a held interaction that was never
published has no file to delete, and a published one is grandfathered.

## 4. What this PR does not do (follow-ups)

- **#2059 — the Core ML `OptionScorer` and its weights.** The seam ships inert. The provider needs
  an owner decision on the base model and licence: Kev-0.5B (Qwen2.5-0.5B LoRA + readout head,
  MIT), jevmlx's zero-shot recipe (MIT), or a Nimble-style contrastive fine-tune (Apache-2.0)
  convert to Core ML and satisfy "Apple frameworks only"; `system-one-gemma`'s weights are
  CC-BY-NC and do not. Size (0.3–1 GB) argues for an on-demand asset with the same
  missing-asset fallback `NLContextualEmbeddingProvider` uses, not an App Store bundle resource.
  Zero-shot small models score ~64–68% on TypeSafe's public eval; the value is in the domain
  fine-tune, which is why the ledger keeps labels from day one.
- **Moderation-pane wiring.** `ModerationModel` lists `ledger.held()` beside pending followers
  and calls `ledger.rule(_:approved:)` on Accept/Reject. App target; needs Xcode 27 to verify.
- **ActivityPub and Bluesky paths.** `BlueskyBackfeedSync` and the AP inbox reuse the same
  screener once the webmention path has a calibration report.
- **Second question.** A parallel `noul` for harassment (independent of spam) once the first
  has a site's worth of labels; the seam already supports asking both in one call.
- **Other decision shapes** from the analysis that prompted this (edit-kind `choice` before
  guided generation, intake-triage routing, import-item classification) — each is a separate
  gate over the same `DecisionProvider`.

## 5. Testing

- `DecisionProviderTests` — softmax stability, temperature direction, validation, provider
  composition, error propagation.
- `TemperatureCalibrationTests` — recovers a known temperature from synthetic labels
  (deterministic LCG), lowers ECE, refuses to fit on < 20 labels, `Codable` round-trip.
- `InteractionScreeningTests` — rule order, thresholds incl. the low-confidence hold and
  drop opt-in, state rendering and truncation, fail-open with a single log line, owner override,
  ledger round-trip, queue ordering, calibration samples, corrupt-file tolerance.
- `ReceivedInteractionSyncTests` (macOS, real `git`) — held mentions stay out of git and in the
  ledger; an owner Accept publishes on the next sync; existing snapshots are grandfathered.

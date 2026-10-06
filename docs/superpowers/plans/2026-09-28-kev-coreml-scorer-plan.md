# Kev-0.5B on-device scorer — implementation plan

**Date:** 2026-09-28
**Status:** current
**Issue:** #2059 (parent #2058)
**Design:** [`../specs/2026-09-28-system-one-decision-seam-design.md`](../specs/2026-09-28-system-one-decision-seam-design.md) §4
**Decision:** Kev-0.5B (owner, 2026-09-28) — Qwen2.5-0.5B + LoRA r=16 + 896→256 pointer head, Apache-2.0

---

## Why Kev-0.5B and not the current Kev line

Kev's active checkpoints (0.8B/4B/9B/27B) moved to Qwen3.5/3.8 bases whose Gated DeltaNet
layers coremltools cannot convert today. Kev-0.5B is the attention-only prototype: a plain
Qwen2 transformer with a merged LoRA, which Core ML exports as-is. Its model card reports
0.799 accuracy and ECE 0.031 after temperature scaling (T = 1.47) on held-out public sets, with
7% argmax flips under option reordering — adequate for a *hold-for-review* gate that never
deletes, and the screening ledger accumulates the site-specific labels a later fine-tune needs.

## Slices

| # | Slice | Runs where | Status |
|---|---|---|---|
| 1 | `BytePairEncoder` — Qwen2 byte-level BPE in Foundation; golden fixture cross-checked against HF `tokenizers`; env-gated run over the full 151k tables | Linux + macOS | done |
| 2 | `KevSequencePacker` / `KevEncoding` / `KevDelimiters` / `KevQuestionRendering` — port of `encode()` + `branch_mask_batch()`; golden row + mask; noul order map | Linux + macOS | done |
| 3 | `KevPointerHead` — head math in Swift; `head.bin`/`head.json` loader; env-gated load of the real 896×256 head | Linux + macOS | done |
| 4 | `KevOptionScorer` + `KevBackbone` seam + `KevModelAssets` — assembly, escaping, option reordering, fail-open on backbone errors; fake-backbone tests | Linux + macOS | done |
| 5 | `CoreMLKevBackbone` — `MLModel` over `Kev.mlmodelc` with the 4-D additive mask | macOS (compiles on the macOS lane; runs only with the asset) | done (#2062); runtime verification is slice 8 |
| 6 | `KevModelLocator` + `InteractionScreenerFactory` — Application Support lookup, env override, `nil` when absent; `PreviewModel` passes the screener | macOS app | done (#2062) |
| 7 | `scripts/kev/` — `extract-kev-head.py` (run, stdlib only), `gen-*-golden.py` (run), `convert-kev-coreml.py` (needs a Mac with torch + coremltools) | owner's Mac | done (#2099) — `--verify` max \|Δ\| = 0.031 |
| 8 | Owner runs the export with `--verify`, installs to `Models/kev-0.5b/`, opens a site with a provisioned inbox, confirms a held mention appears in the ledger and the Debug pane shows no load errors | owner's Mac | done (#2099) — first real run clean |
| 9 | Moderation pane: `ModerationModel` lists `ledger.held()` beside pending followers; Accept/Reject → `ledger.rule(_:approved:)` | macOS app | done (#2070) |
| 10 | Calibration: fit `TemperatureCalibration` from `ledger.calibrationSamples()` at ≥ 20 rulings; ECE to the Debug pane | Core + app | done (#2083) |
| 11 | Asset delivery: download-on-demand with integrity check against `MANIFEST.json`; until then the asset is installed by the recipe in `scripts/kev/README.md` | app | done (#2086); the download stays unoffered until #2100 publishes the assets and pins the manifest |

## Verification gates

- Linux lane: the four Kev suites (26 tests) plus the seam suites from #2058.
- macOS lane: same, plus `CoreMLKevBackbone` and `InteractionScreenerFactory` compile.
- Owner's Mac (slice 8): `--verify` max |Δ| < 5e-2; env-gated suites green against the exported
  directory; one real site-open with the model installed.

## Licensing

`KevSequencePacker.swift`, `KevPointerHead.swift` and `scripts/kev/` derive from Kev
(Apache-2.0, Jared Palmer); the fixtures embed a 616-token excerpt of the Qwen2 tokenizer
(Apache-2.0, Alibaba Cloud). Both are annotated in `REUSE.toml` with `LICENSES/Apache-2.0.txt`.
The model asset itself is never committed.

# Kev-0.5B decision model — asset pipeline (#2059)

The on-device spam screen (`InteractionScreener`, #2058) scores comments with
[Kev-0.5B](https://github.com/jaredpalmer/kev/blob/main/docs/model-cards/kev-0.5b.md): Qwen2.5-0.5B
plus a rank-16 LoRA adapter and a 896→256 pointer head, trained to answer typed questions with
calibrated probabilities (owner decision, 2026-09-28). The app links no PyTorch and no third-party
tokenizer, so the checkpoint is turned into a plain asset directory that `KevModelAssets`
(`Sources/AnglesiteCore/AI/Kev/`) reads:

| File | Produced by | Read by |
|---|---|---|
| `Kev.mlmodelc` | `convert-kev-coreml.py` (Core ML export of base + merged adapter) | `CoreMLKevBackbone` |
| `vocab.json`, `merges.txt`, `added_tokens.json` | copied from the checkpoint | `BytePairEncoder`, `KevDelimiters` |
| `head.bin`, `head.json` | `extract-kev-head.py` (no torch needed) | `KevPointerHead` |
| `MANIFEST.json` | `convert-kev-coreml.py` | `KevModelDownloader` (every file, recursively, with sha256 + size) |

Install location: `~/Library/Application Support/Anglesite/Models/kev-0.5b/`
(`KevModelLocator.defaultDirectory`), or `ANGLESITE_KEV_ASSETS=<dir>` for development. With
nothing installed `InteractionScreenerFactory.makeDefault()` returns `nil` and the sync is the
unscreened path.

## Build the assets (macOS, Apple Silicon)

```sh
# 1. The checkpoint (adapter + head + tokenizer, 38 MB, Apache-2.0):
curl -LO https://github.com/jaredpalmer/kev/releases/download/v0.1.0/kev-0.5b.tar.gz
tar -xzf kev-0.5b.tar.gz            # → kev-0.5b/

# 2. Export. Downloads Qwen/Qwen2.5-0.5B (Apache-2.0) from Hugging Face on first run.
python3 -m venv .venv && .venv/bin/pip install "torch>=2.4" "transformers>=4.45" "peft>=0.13" "coremltools>=8.0" safetensors
.venv/bin/python scripts/kev/convert-kev-coreml.py --checkpoint kev-0.5b \
  --out ~/Library/Application\ Support/Anglesite/Models/kev-0.5b --verify

# 3. Prove the Swift side against the real tables (the env-gated Kev suites):
ANGLESITE_KEV_ASSETS=~/Library/Application\ Support/Anglesite/Models/kev-0.5b \
  swift test --filter 'BytePairEncoderTests|KevSequencePackerTests|KevPointerHeadTests|KevOptionScorerTests'
```

`--verify` runs one packed row through PyTorch and the compiled Core ML model and prints the
max abs difference at the readout positions (expect < 5e-2 in float16).

## Publish the assets for download-on-demand (#2068)

The app never bundles the model: `KevModelDownloader` fetches it from the Anglesite-operated host
pinned in `scripts/kev/kev-assets.lock.json` (generated into `KevModelAssetPin.swift`), verifies
`MANIFEST.json` against the pinned SHA-256 and every file against the manifest, and only then
moves the set into `KevModelLocator.defaultDirectory`. Until a digest is pinned the app never
offers the download.

```sh
# 1. Upload <asset-dir> recursively to a NEW versioned prefix (never reuse one the pin has
#    pointed at — installed apps verify against the digest they shipped with), e.g.
#    https://anglesite.dwk.io/models/kev-0.5b/2026-09-29/
# 2. Pin it. Prints the file list the manifest covers; review, then commit both files.
scripts/kev/bump-kev-assets.sh ~/Library/Application\ Support/Anglesite/Models/kev-0.5b \
  https://anglesite.dwk.io/models/kev-0.5b/2026-09-29/
```

`scripts/kev/bump-kev-assets.sh --check` runs in CI so the lock and the generated Swift constant
can't drift.

## Regenerate the test fixtures

The golden fixtures under `Tests/AnglesiteCorePortableTests/Fixtures/Kev/` pin the Swift
tokenizer and packer to the reference implementation. Regenerate only when the checkpoint or
the sample set changes:

```sh
.venv/bin/pip install tokenizers regex
.venv/bin/python scripts/kev/gen-tokenizer-golden.py kev-0.5b Tests/AnglesiteCorePortableTests/Fixtures/Kev/tokenizer-golden.json
.venv/bin/python scripts/kev/gen-packer-golden.py   kev-0.5b Tests/AnglesiteCorePortableTests/Fixtures/Kev/packer-golden.json
```

`gen-tokenizer-golden.py` cross-checks its own BPE against Hugging Face `tokenizers` on every
sample before writing, and emits *reduced* tables (the 256 byte symbols, every token produced,
every merge applied at its original rank) so the fixture stays ~14 KB while reproducing the full
tokenizer exactly on those samples. `gen-packer-golden.py` is a line-for-line port of
`kev/model.py`'s `encode()` and `branch_mask_batch()`.

## Contract notes

- Delimiters are Qwen's reserved `<|fim_prefix|>` (state), `<|fim_middle|>` (question),
  `<|box_start|>`/`<|box_end|>` (option), `<|fim_suffix|>` (decide); ids come from
  `added_tokens.json`, never hardcoded.
- Caller text is escaped (`<|name|>` → `<¦name¦>`) before tokenising, as Kev's `user_tokens()`
  does, so no comment can forge a delimiter.
- A `noul` is rendered as Kev's `[no, yes]`; `KevQuestionRendering.optionOrder` maps the logits
  back to `DecisionQuestion.noulOptions` (`[yes, no]`).
- The head divides by the checkpoint's calibration temperature (1.47), so
  `ScoringDecisionProvider(scorer:)` with `.identity` reproduces Kev's served probabilities; a
  site-fitted `TemperatureCalibration` from the screening ledger composes on top.
- kev-0.5b was trained without option isolation; the packer supports it but the scorer defaults
  to `false` to match.

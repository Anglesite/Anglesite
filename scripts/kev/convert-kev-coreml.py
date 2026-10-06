#!/usr/bin/env python3
"""Export the Kev-0.5B backbone to Core ML and assemble the app's model asset directory (#2059).

Produces `<out>/` with exactly what `KevModelAssets` (Sources/AnglesiteCore/AI/Kev/) expects:

    Kev.mlmodelc        compiled Core ML backbone: Qwen2.5-0.5B + the kev-0.5b LoRA adapter merged
    vocab.json          }
    merges.txt          } the checkpoint's tokenizer, copied verbatim
    added_tokens.json   }
    head.bin, head.json the pointer head, via extract-kev-head.py
    MANIFEST.json       sha256 + size per file (recursive, incl. Kev.mlmodelc/*), base model id, adapter sha256, coremltools version

The Core ML model's interface is the contract `CoreMLKevBackbone` codes against — change both
together:
    inputs   input_ids      int32   [1, L]
             position_ids   int32   [1, L]
             attention_mask float16 [1, 1, L, L]   additive: 0 = attend, -1e4 = blocked
    output   hidden_states  float16 [1, L, 896]    final-layer hidden states after the last RMSNorm

`L` is a flexible range 8…2048 (Kev's MAX_PACKED). The mask is passed straight through to every
attention layer as the 4-D additive mask, which is what lets one row carry a block-causal
question-isolated layout (see KevEncoding.attentionAllowMatrix) rather than a plain causal one.

Requirements (macOS, Apple Silicon, Python 3.11+):
    pip install "torch>=2.4" "transformers>=4.45" "peft>=0.13" "coremltools>=8.0" safetensors
    Base weights come from Hugging Face (`Qwen/Qwen2.5-0.5B`, Apache-2.0); the adapter + head from
    the kev v0.1.0 GitHub release (Apache-2.0): https://github.com/jaredpalmer/kev/releases/tag/v0.1.0

    scripts/kev/convert-kev-coreml.py --checkpoint path/to/kev-0.5b --out ~/Library/Application\\ Support/Anglesite/Models/kev-0.5b

Validation: `--verify` runs one packed row through both PyTorch and the Core ML model and
reports the max abs difference of the hidden states at the readout positions (expect < 5e-2 in
float16). The Swift side is validated separately by the AnglesiteCorePortableTests Kev suites
with ANGLESITE_KEV_ASSETS pointing at `<out>`.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

MASKED = -1e4
MAX_PACKED = 2048
MIN_LEN = 8


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build_merged_model(checkpoint: Path, base: str):
    import torch
    from peft import PeftModel
    from transformers import AutoModel

    model = AutoModel.from_pretrained(base, torch_dtype=torch.float32, attn_implementation="eager")
    model = PeftModel.from_pretrained(model, str(checkpoint))
    model = model.merge_and_unload()
    model.eval()
    return model


class Backbone:
    """Traceable wrapper: (input_ids, position_ids, attention_mask) -> last_hidden_state."""

    def __init__(self, model):
        import torch

        class Wrapped(torch.nn.Module):
            def __init__(self, inner):
                super().__init__()
                self.inner = inner

            def forward(self, input_ids, position_ids, attention_mask):
                out = self.inner(input_ids=input_ids, position_ids=position_ids, attention_mask=attention_mask,
                                 use_cache=False, return_dict=True)
                return out.last_hidden_state

        self.module = Wrapped(model)


def export(checkpoint: Path, out: Path, base: str, verify: bool) -> int:
    import torch
    import coremltools as ct

    out.mkdir(parents=True, exist_ok=True)
    model = build_merged_model(checkpoint, base)
    hidden = model.config.hidden_size
    wrapped = Backbone(model).module

    L = 64
    example = (
        torch.zeros(1, L, dtype=torch.int32),
        torch.arange(L, dtype=torch.int32).unsqueeze(0),
        torch.zeros(1, 1, L, L, dtype=torch.float32),
    )
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)

    length = ct.RangeDim(lower_bound=MIN_LEN, upper_bound=MAX_PACKED, default=L)
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, length), dtype=ct.converters.mil.mil.types.int32),
            ct.TensorType(name="position_ids", shape=(1, length), dtype=ct.converters.mil.mil.types.int32),
            ct.TensorType(name="attention_mask", shape=(1, 1, length, length), dtype=ct.converters.mil.mil.types.fp16),
        ],
        outputs=[ct.TensorType(name="hidden_states", dtype=ct.converters.mil.mil.types.fp16)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )
    mlmodel.short_description = f"Kev-0.5B backbone ({base} + kev-0.5b LoRA merged); pointer head applied in Swift"
    package = out / "Kev.mlpackage"
    if package.exists():
        shutil.rmtree(package)
    mlmodel.save(str(package))

    compiled = out / "Kev.mlmodelc"
    if compiled.exists():
        shutil.rmtree(compiled)
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(out)], check=True)
    shutil.rmtree(package)

    for name in ("vocab.json", "merges.txt", "added_tokens.json"):
        shutil.copyfile(checkpoint / name, out / name)
    subprocess.run([sys.executable, str(Path(__file__).with_name("extract-kev-head.py")), str(checkpoint), str(out)], check=True)

    if verify:
        max_diff = verify_row(wrapped, compiled, checkpoint, out)
        print(f"verify: max |Δ hidden| at readout positions = {max_diff:.4g}")

    manifest = {
        "checkpoint": "kev-0.5b", "base": base, "hiddenSize": hidden,
        "adapter_sha256": sha256(checkpoint / "adapter_model.safetensors"),
        "coremltools": ct.__version__, "torch": torch.__version__,
        # Every file, recursively, keyed by its path relative to `out` (so `Kev.mlmodelc/…` is
        # covered too): this is the download list `KevModelDownloader` verifies against (#2068).
        "files": {p.relative_to(out).as_posix(): {"sha256": sha256(p), "bytes": p.stat().st_size}
                  for p in sorted(out.rglob("*")) if p.is_file() and p.name != "MANIFEST.json"},
    }
    (out / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {out}")
    return 0


def verify_row(wrapped, compiled: Path, checkpoint: Path, out: Path) -> float:
    """One packed row through PyTorch and Core ML; returns the max abs diff at the readout positions."""
    import numpy as np
    import torch
    import coremltools as ct
    from transformers import AutoTokenizer

    tok = AutoTokenizer.from_pretrained(str(checkpoint))
    added = json.loads((checkpoint / "added_tokens.json").read_text())
    specials = ["<|fim_prefix|>", "<|fim_middle|>", "<|box_start|>", "<|box_end|>", "<|fim_suffix|>"]
    s_id, q_id, o_id, c_id, d_id = (added[t] for t in specials)
    state = tok("Protocol: webmention\nContent:\nBUY NOW cheap pills", add_special_tokens=False).input_ids
    instr = tok("This interaction is spam.", add_special_tokens=False).input_ids
    spans = [[o_id] + tok(o, add_special_tokens=False).input_ids + [c_id] for o in ("no", "yes")]
    S = [s_id] + state
    branch = [q_id] + instr + [t for sp in spans for t in sp] + [d_id]
    ids = S + branch
    seg = [0] * len(S) + [1] * len(branch)
    pos = list(range(len(S))) + list(range(len(S), len(S) + len(branch)))
    L = len(ids)
    allow = [[(j <= i and (seg[j] == 0 or seg[j] == seg[i])) or i == j for j in range(L)] for i in range(L)]
    mask = np.where(np.array(allow), 0.0, MASKED).astype(np.float32)[None, None]
    readout = [L - 1] + [len(S) + len(instr) + 1 + sum(len(sp) for sp in spans[:k]) + len(spans[k]) - 1 for k in range(2)]

    with torch.no_grad():
        ref = wrapped(torch.tensor([ids], dtype=torch.int32), torch.tensor([pos], dtype=torch.int32),
                      torch.tensor(mask)).numpy()[0]
    ml = ct.models.CompiledMLModel(str(compiled))
    got = ml.predict({"input_ids": np.array([ids], dtype=np.int32), "position_ids": np.array([pos], dtype=np.int32),
                      "attention_mask": mask.astype(np.float16)})["hidden_states"][0]
    return float(max(np.abs(ref[i] - got[i]).max() for i in readout))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--checkpoint", type=Path, required=True, help="unpacked kev-0.5b release directory")
    ap.add_argument("--out", type=Path, required=True, help="asset directory to write (KevModelLocator.defaultDirectory)")
    ap.add_argument("--base", default="Qwen/Qwen2.5-0.5B")
    ap.add_argument("--verify", action="store_true", help="compare PyTorch vs Core ML on one packed row")
    args = ap.parse_args()
    if sys.platform != "darwin":
        print("Core ML export needs macOS (coremlcompiler); run this on a Mac.", file=sys.stderr)
        return 2
    return export(args.checkpoint, args.out, args.base, args.verify)


if __name__ == "__main__":
    sys.exit(main())

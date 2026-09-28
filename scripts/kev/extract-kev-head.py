#!/usr/bin/env python3
"""Extract Kev's pointer head from `head.pt` into the flat binary + JSON the app loads (#2059).

`head.pt` is a PyTorch zip checkpoint holding four float32 tensors (q.weight [dp, d], q.bias [dp],
k.weight [dp, d], k.bias [dp]) plus metadata. The app never links PyTorch, so this writes:

  head.bin   — the four tensors concatenated row-major in that order, little-endian float32
  head.json  — {"d": 896, "dp": 256, "temperature": T, "base": "...", "lora": 16,
                "layout": ["q.weight", "q.bias", "k.weight", "k.bias"]}

Stdlib only (zipfile + a stub unpickler), so it runs without torch — the storage keys in the
pickle name the raw `head/data/<n>` entries, which are already little-endian float32 on disk.

    scripts/kev/extract-kev-head.py <kev-0.5b dir> <out dir> [--temperature 1.47]
"""
from __future__ import annotations

import argparse
import collections
import io
import json
import pickle
import struct
import sys
import zipfile
from pathlib import Path

ORDER = ["q.weight", "q.bias", "k.weight", "k.bias"]


class _Stub:
    def __init__(self, *args):
        self.args = args


class _Unpickler(pickle.Unpickler):
    """Loads torch's data.pkl without torch: tensors become stubs carrying (storage key, shape)."""

    def find_class(self, module, name):
        if module == "collections" and name == "OrderedDict":
            return collections.OrderedDict
        if name == "_rebuild_tensor_v2":
            return lambda storage, offset, size, stride, *rest: ("tensor", storage, offset, tuple(size))
        return type(name, (_Stub,), {"__module__": module})

    def persistent_load(self, pid):
        # ('storage', <class FloatStorage>, key, location, numel)
        return ("storage", pid[1].__name__, pid[2], pid[4])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("checkpoint_dir", type=Path)
    ap.add_argument("out_dir", type=Path)
    ap.add_argument("--temperature", type=float, default=1.47,
                    help="post-hoc calibration temperature from the model card (kev-0.5b: 1.47)")
    args = ap.parse_args()

    z = zipfile.ZipFile(args.checkpoint_dir / "head.pt")
    pkl = next(n for n in z.namelist() if n.endswith("data.pkl"))
    prefix = pkl[: -len("data.pkl")]
    byteorder = z.read(prefix + "byteorder").decode().strip() if (prefix + "byteorder") in z.namelist() else "little"
    if byteorder != "little":
        print(f"unsupported byte order {byteorder!r}", file=sys.stderr)
        return 1
    obj = _Unpickler(io.BytesIO(z.read(pkl))).load()
    head = obj["head"]

    d = dp = None
    blobs = []
    for name in ORDER:
        kind, storage, offset, shape = head[name]
        assert kind == "tensor" and storage[0] == "storage" and storage[1] == "FloatStorage", (name, storage)
        raw = z.read(prefix + f"data/{storage[2]}")
        numel = 1
        for s in shape:
            numel *= s
        blob = raw[offset * 4 : (offset + numel) * 4]
        if len(blob) != numel * 4:
            print(f"{name}: expected {numel * 4} bytes, got {len(blob)}", file=sys.stderr)
            return 1
        if name.endswith(".weight"):
            dp, d = shape
        blobs.append(blob)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / "head.bin").write_bytes(b"".join(blobs))
    meta = {
        "d": d, "dp": dp, "temperature": args.temperature,
        "base": obj.get("base"), "lora": obj.get("lora"), "layout": ORDER, "dtype": "float32-le",
    }
    (args.out_dir / "head.json").write_text(json.dumps(meta, indent=2) + "\n")
    # Sanity: the first weight row should be finite, not garbage.
    first = struct.unpack("<4f", blobs[0][:16])
    print(f"wrote head.bin ({sum(map(len, blobs))} bytes) and head.json; d={d} dp={dp} q.weight[0][:4]={first}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""DIAGNOSTIC (#1990): dump async function pointer records (fn offset, context size) and
resolved disassembly for the default-argument thunks and their callees, from the linked
AnglesitePackageTests bundle."""
import re, struct, subprocess, sys

binary = sys.argv[1]
PATTERNS = [
    "ExistingSiteMigrationCommitter.commit(", "ExistingSiteMigrationCommitter.retryPendingCommit(",
    "Issue1990Diag.", "InboxSubmissionCommitter.isTracked", "InboxSubmissionCommitter.processGitCommitBatch",
    "x2_isTrackedViaClosureValueNonRepo",
] + sys.argv[2:]

nm = subprocess.run(["nm", "-n", binary], capture_output=True, text=True).stdout.splitlines()
rows = []
for l in nm:
    parts = l.split()
    if len(parts) != 3: continue
    rows.append((int(parts[0], 16), parts[1], parts[2]))
names = "\n".join(r[2] for r in rows)
dem = subprocess.run(["swift", "demangle", "-compact"], input=names, capture_output=True, text=True).stdout.splitlines()
sel = []
for (addr, typ, mangled), d in zip(rows, dem):
    if any(p in d for p in PATTERNS):
        sel.append((addr, typ, mangled, d))
print("=== selected symbols ===")
for addr, typ, mangled, d in sel:
    print(f"{addr:016x} {typ} {d}")

# Function addresses (so AFP relative offsets can be resolved back to a name).
by_addr = {addr: d for addr, typ, mangled, d in sel}

_sections = None
def sections():
    """[(addr, size, fileoff)] from otool -l (LC_SEGMENT_64 sections)."""
    global _sections
    if _sections is None:
        out = subprocess.run(["otool", "-l", binary], capture_output=True, text=True).stdout.splitlines()
        _sections = []
        cur = {}
        for l in out:
            l = l.strip()
            if l.startswith("Section"):
                cur = {}
            for key in ("addr", "size", "offset"):
                if l.startswith(key + " "):
                    cur[key] = int(l.split()[1], 0)
                    if len(cur) == 3:
                        _sections.append((cur["addr"], cur["size"], cur["offset"])); cur = {}
    return _sections

def read_bytes(start, length):
    for addr, size, off in sections():
        if addr <= start < addr + size:
            with open(binary, "rb") as fh:
                fh.seek(off + (start - addr))
                return fh.read(length)
    return b""

print("\n=== async function pointer records (relative fn offset -> resolved target, context size) ===")
for addr, typ, mangled, d in sel:
    if not d.startswith("async function pointer to "):
        continue
    raw = read_bytes(addr, 8)
    if len(raw) < 8:
        print(f"{d}: could not read bytes at {addr:#x} ({raw.hex()})"); continue
    rel, size = struct.unpack("<iI", raw)
    target = addr + rel
    print(f"size={size:#6x} ({size:4d})  fn={target:#x} {by_addr.get(target, '?')}\n    for: {d}")

print("\n=== resolved disassembly of thunks and callees ===")
want = [mangled for addr, typ, mangled, d in sel
        if typ in "tT" and ("closure" in d and "default argument" in d and "Issue1990Diag" in d)]
if want:
    out = subprocess.run(["objdump", "-d", "--no-show-raw-insn", "--disassemble-symbols=" + ",".join(want), binary],
                         capture_output=True, text=True).stdout
    out = subprocess.run(["swift", "demangle", "-compact"], input=out, capture_output=True, text=True).stdout
    print(out[:40000])

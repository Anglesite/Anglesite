#!/usr/bin/env python3
"""Generate Tests/AnglesiteCorePortableTests/Fixtures/Kev/tokenizer-golden.json (#2059).

Encodes a fixed sample set with a from-scratch byte-level BPE over the checkpoint's vocab.json +
merges.txt, asserts every result equals Hugging Face `tokenizers` on tokenizer.json, then writes
the samples plus *reduced* tables: the 256 byte symbols, every token produced, and every merge
applied at its original rank — enough to reproduce the full tokenizer exactly on these samples.

    gen-tokenizer-golden.py <kev-0.5b checkpoint dir> <out.json>     (pip install tokenizers regex)
"""
import json, re, sys, unicodedata
from tokenizers import Tokenizer
src = sys.argv[1]; out = sys.argv[2]
tok = Tokenizer.from_file(src + "/tokenizer.json")
vocab = json.load(open(src + "/vocab.json"))
merges = [l.rstrip("\n") for l in open(src + "/merges.txt", encoding="utf-8") if not l.startswith("#") and l.strip()]
rank = {tuple(m.split(" ")): i for i, m in enumerate(merges)}
import regex  # `re` has no \p{L}; `regex` matches HF tokenizers' Rust engine on this pattern
PAT = regex.compile(r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+")
def bytes_to_unicode():
    bs = list(range(ord("!"), ord("~")+1)) + list(range(ord("¡"), ord("¬")+1)) + list(range(ord("®"), ord("ÿ")+1))
    cs = bs[:]; n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b); cs.append(256+n); n += 1
    return dict(zip(bs, [chr(c) for c in cs]))
B2U = bytes_to_unicode()
applied = {}
def bpe(word):
    syms = list(word)
    while len(syms) > 1:
        pairs = [(syms[i], syms[i+1]) for i in range(len(syms)-1)]
        best = min((rank.get(p, 1<<60), p) for p in pairs)
        if best[0] == 1<<60: break
        a, b = best[1]; applied[(a,b)] = best[0]
        merged = []; i = 0
        while i < len(syms):
            if i < len(syms)-1 and syms[i] == a and syms[i+1] == b:
                merged.append(a+b); i += 2
            else:
                merged.append(syms[i]); i += 1
        syms = merged
    return syms
def encode(text):
    text = unicodedata.normalize("NFC", text)
    ids = []
    for piece in PAT.findall(text):
        chars = "".join(B2U[b] for b in piece.encode("utf-8"))
        ids += [vocab[s] for s in bpe(chars)]
    return ids
samples = [
    "Hello, world!", "hello world", "  leading and trailing  ", "Tabs\tand\nnewlines\r\n\r\ndone",
    "I'm sure they'll've done it, isn't it? They'd", "Numbers 1234567890 and 3.14159 and 1,000,000",
    "email me@dwk.io or visit https://anglesite.dwk.io/blog/hi?x=1&y=2", "Café naïve résumé Straße ärger",
    "日本語のテキストと中文和한국어", "emoji 🎉🚀 and combining é (e + ́)", "Protocol: webmention\nKind: reply\nFrom: https://alice.example/post",
    "BUY NOW!!! cheap pills $$$ >>> click here <<<", "<¦im_start¦> escaped delimiter and <|not_a_token|> plain text",
    "Mixed   spaces    then word", "trailing newline\n", "\n\nleading newlines", "ALLCAPS WORDS and CamelCase and snake_case",
    "punctuation...!!!???;;;", "unicode punctuation — “quotes” ‘single’ …", "x" * 40, "a", "", " ", "\n",
    "Great post! Thanks for writing this up, it helped me fix my webmention endpoint.",
]
golden = []
for s in samples:
    ref = tok.encode(s, add_special_tokens=False).ids
    mine = encode(s)
    assert ref == mine, (s, ref[:10], mine[:10])
    golden.append({"text": s, "ids": ref})
# Reduced tables: 256 byte-alphabet tokens + every final token, and every merge applied, in rank order.
final_tokens = set(B2U.values())
inv = {v: k for k, v in vocab.items()}
for g in golden:
    for i in g["ids"]: final_tokens.add(inv[i])
# intermediate symbols produced by applied merges must also be in the vocab for the loader's sanity, include them
for (a, b) in applied: final_tokens.add(a); final_tokens.add(b); final_tokens.add(a+b)
reduced_vocab = {t: vocab[t] for t in sorted(final_tokens, key=lambda t: vocab[t]) if t in vocab}
reduced_merges = [f"{a} {b}" for (a, b), r in sorted(applied.items(), key=lambda kv: kv[1])]
json.dump({"pattern": PAT.pattern, "vocab": reduced_vocab, "merges": reduced_merges, "samples": golden},
          open(out, "w"), ensure_ascii=False, indent=0, sort_keys=True)
print("samples", len(golden), "reduced vocab", len(reduced_vocab), "reduced merges", len(reduced_merges), "bytes", len(open(out,'rb').read()))

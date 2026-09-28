#!/usr/bin/env python3
"""Generate Tests/AnglesiteCorePortableTests/Fixtures/Kev/packer-golden.json (#2059).

A line-for-line port of kev/model.py's encode() and branch_mask_batch() (Apache-2.0, Jared
Palmer) run over one two-question record with the real tokenizer, with and without option
isolation. The Swift KevSequencePacker must reproduce ids/seg/pos/opt/decide_idx/opt_idx and the
allow matrix exactly.

    gen-packer-golden.py <kev-0.5b checkpoint dir> <out.json>     (pip install tokenizers)
"""
import json, re, sys
from tokenizers import Tokenizer
src, out = sys.argv[1], sys.argv[2]
tok = Tokenizer.from_file(src + "/tokenizer.json")
added = json.load(open(src + "/added_tokens.json"))
SPECIAL = ["<|fim_prefix|>", "<|fim_middle|>", "<|box_start|>", "<|box_end|>", "<|fim_suffix|>"]
_SPECIAL_RE = re.compile(r"<\|([A-Za-z0-9_]+)\|>")
OPT_NONE, OPT_DECIDE = -1, -2
def user_tokens(text): return tok.encode(_SPECIAL_RE.sub(r"<¦\1¦>", text), add_special_tokens=False).ids
def encode(rec, max_state=384, max_branch=1024, option_isolation=False):
    state_tokens = user_tokens(rec["state"])
    S = [added[SPECIAL[0]]] + state_tokens[: max_state - 1]
    ids, seg, pos, opt = list(S), [0] * len(S), list(range(len(S))), [OPT_NONE] * len(S)
    q_id, o_id, c_id, d_id = (added[t] for t in SPECIAL[1:])
    decide_idx, opt_idx = [], []
    for k, q in enumerate(rec["questions"], start=1):
        instr = [q_id] + user_tokens(q["instr"])
        spans = [[o_id] + user_tokens(o) + [c_id] for o in q["options"]]
        br = instr + [t for sp in spans for t in sp] + [d_id]
        assert len(br) <= max_branch - len(S)
        base = len(ids); p0 = len(S)
        br_opt = [OPT_NONE] * len(instr) + [j for j, sp in enumerate(spans) for _ in sp] + [OPT_DECIDE]
        if option_isolation:
            longest = max(len(sp) for sp in spans)
            br_pos = list(range(p0, p0 + len(instr))) + [p0 + len(instr) + i for sp in spans for i in range(len(sp))] + [p0 + len(instr) + longest]
        else:
            br_pos = list(range(p0, p0 + len(br)))
        ends, cursor = [], len(instr)
        for sp in spans:
            cursor += len(sp); ends.append(cursor - 1)
        ids += br; seg += [k] * len(br); pos += br_pos; opt += br_opt
        decide_idx.append(base + len(br) - 1); opt_idx.append([base + e for e in ends])
    return {"ids": ids, "seg": seg, "pos": pos, "opt": opt, "decide_idx": decide_idx, "opt_idx": opt_idx, "option_isolation": option_isolation}
def allow_mask(enc):
    seg, opt = enc["seg"], enc["opt"]; L = len(seg); rows = []
    for i in range(L):
        row = []
        for j in range(L):
            a = j <= i and (seg[j] == 0 or seg[j] == seg[i])
            if enc["option_isolation"]:
                key_is_option = opt[j] >= 0; query_is_decide = opt[i] == OPT_DECIDE; same_option = opt[j] == opt[i]
                a = a and ((not key_is_option) or query_is_decide or same_option)
            a = a or i == j
            row.append("1" if a else "0")
        rows.append("".join(row))
    return rows
rec = {"state": "Protocol: webmention\nKind: reply\nFrom: https://casino.example/win\nContent:\nBUY NOW <|fim_suffix|> cheap",
       "questions": [
           {"label": "spam", "instr": "This interaction is spam.", "options": ["no", "yes"]},
           {"label": "kind", "instr": "What kind of message is this?", "options": ["ad: an advertisement", "reply", "other: None of the above"]}]}
golden = {"delimiters": {"state": added[SPECIAL[0]], "question": added[SPECIAL[1]], "optionOpen": added[SPECIAL[2]], "optionClose": added[SPECIAL[3]], "decide": added[SPECIAL[4]]},
          "record": rec, "encodings": {}}
for iso in (False, True):
    enc = encode(rec, option_isolation=iso); enc["allow"] = allow_mask(enc)
    golden["encodings"]["isolated" if iso else "shared"] = enc
# token ids of the escaped state / instr / options so the Swift test can run the packer without the full vocab
golden["tokens"] = {"state": user_tokens(rec["state"]), "questions": [{"instr": user_tokens(q["instr"]), "options": [user_tokens(o) for o in q["options"]]} for q in rec["questions"]]}
json.dump(golden, open(out, "w"), ensure_ascii=False)
e = golden["encodings"]["shared"]; print("L", len(e["ids"]), "decide", e["decide_idx"], "opt_idx", e["opt_idx"], "bytes", len(open(out,'rb').read()))

#!/usr/bin/env python3
"""gen_program.py - turn manifest.json into the accelerator's program.

Build plan #6. The top sequencer of docs/controller_design.md executes one
instruction per op, so this is the compiler: it replays the network, allocates
every feature map a place in the on-chip activation pool, and emits the
instruction stream plus a human-readable listing.

Three things it produces, in order of how much they matter:

  1. THE ALLOCATION, and its peak. Every tensor gets a static address, computed
     from real lifetimes, and the script proves no two live tensors overlap. The
     peak it reports is the actual size the pool has to be - the number
     controller_design.md section 4 estimates.
  2. The listing, which is what you read when the hardware disagrees with the
     C model.
  3. The instruction hex for $readmemh into the sequencer's program memory.

Two semantic points that fall out of reading the C reference model:

  * `save` MOVES NO DATA. run_inference() keeps every layer's output alive and
    residual_add reads the producing layer's buffer directly, so in hardware a
    save is purely a lifetime annotation: it tells the allocator "this tensor
    must survive until the matching res_add". It costs zero cycles and emits no
    instruction.
  * The stem's input is NOT in the pool. 224x224x3 stored as 32-channel entries
    would waste 91% of 1.53 MB; the image lives in its own 147 KB region that
    the PS fills, and only the stem reads it.

Usage:
    python scripts/gen_program.py                 # listing + allocation report
    python scripts/gen_program.py --emit          # also write the hex + listing
    python scripts/gen_program.py --pool 65536    # check against a pool size
"""
import argparse
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "software", "export", "manifest.json")
OUT_DIR = os.path.join(ROOT, "software", "export")

# --- datapath constants (keep in sync with the RTL parameters) ---------------
TM = 32          # pointwise lanes / channels per pool entry
TN = 16          # pointwise taps per cycle
TC = 16          # depthwise channels in parallel
POOL_TM = 32     # channels per activation-pool entry
ENTRY_BYTES = POOL_TM

# --- opcodes (mirror the sequencer's localparams) ----------------------------
OP_STEM   = 0x1
OP_PW     = 0x2
OP_DW     = 0x3
OP_RES    = 0x4
OP_GAP    = 0x5
OP_LINEAR = 0x6

OPNAME = {OP_STEM: "STEM", OP_PW: "PW", OP_DW: "DW",
          OP_RES: "RES_ADD", OP_GAP: "GAP", OP_LINEAR: "LINEAR"}


def entries(h, w, c):
    """Pool entries a HxWxC tensor occupies (POOL_TM channels per entry)."""
    return h * w * math.ceil(c / POOL_TM)


def build_ops(manifest):
    """Replay the manifest into a list of instruction dicts plus tensor info.

    Returns (ops, tensors) where each op records which tensor it reads and
    which it defines, and `save` is folded into the lifetime of the tensor it
    marks rather than becoming an op of its own.
    """
    ops = []
    tensors = {}          # id -> dict(h, w, c, entries, def_op, last_use)
    h = w = 224
    c = 3
    cur = None            # id of the tensor holding the running activation
    saved = None          # id of the tensor the pending res_add will read
    next_id = 0

    def new_tensor(th, tw, tc, def_op):
        nonlocal next_id
        tid = next_id
        next_id += 1
        tensors[tid] = dict(h=th, w=tw, c=tc, entries=entries(th, tw, tc),
                            def_op=def_op, last_use=def_op, addr=None)
        return tid

    for op in manifest["ops"]:
        kind = op["kind"]

        if kind == "save":
            # no data movement: just keep `cur` alive until the res_add
            saved = cur
            continue

        idx = len(ops)

        if kind == "conv":
            oc, ic_g, kh, kw = op["weight_shape"]
            s = op["stride"][0]
            p = op["padding"][0]
            oh = (h + 2 * p - kh) // s + 1
            ow = (w + 2 * p - kw) // s + 1

            if op["groups"] > 1:
                opcode = OP_DW
            elif kh == 1:
                opcode = OP_PW
            else:
                opcode = OP_STEM

            inp = cur                      # None for the stem: image region
            out = new_tensor(oh, ow, oc, idx)
            wbytes = oc * ic_g * kh * kw

            ops.append(dict(
                idx=idx, opcode=opcode, name=op["name"],
                img_h=h, img_w=w, out_h=oh, out_w=ow, in_c=c, out_c=oc,
                stride2=(s == 2), act=1 if op["relu6"] else 0,
                qmax=op.get("relu6_qmax", 0) or 0,
                n_pix=oh * ow,
                n_oc=math.ceil(oc / TM), n_ic=math.ceil(c / TN),
                n_grp=math.ceil(oc / TC),
                n_ent_in=math.ceil(c / POOL_TM),
                n_ent_out=math.ceil(oc / POOL_TM),
                t_in=inp, t_saved=None, t_out=out,
                wbytes=wbytes, pchan=oc))
            if inp is not None:
                tensors[inp]["last_use"] = idx
            cur = out
            h, w, c = oh, ow, oc

        elif kind == "res_add":
            out = new_tensor(h, w, c, idx)
            ops.append(dict(
                idx=idx, opcode=OP_RES, name=op["name"],
                img_h=h, img_w=w, out_h=h, out_w=w, in_c=c, out_c=c,
                stride2=False, act=0, qmax=0,
                n_pix=h * w, n_oc=math.ceil(c / TM), n_ic=math.ceil(c / TN),
                n_grp=math.ceil(c / TC),
                n_ent_in=math.ceil(c / POOL_TM),
                n_ent_out=math.ceil(c / POOL_TM),
                t_in=cur, t_saved=saved, t_out=out,
                wbytes=0, pchan=0,
                m0=op["m0"], shift=op["shift"]))
            tensors[cur]["last_use"] = idx
            if saved is not None:
                tensors[saved]["last_use"] = idx
            saved = None
            cur = out

        elif kind == "gap":
            out = new_tensor(1, 1, c, idx)
            ops.append(dict(
                idx=idx, opcode=OP_GAP, name="avgpool",
                img_h=h, img_w=w, out_h=1, out_w=1, in_c=c, out_c=c,
                stride2=False, act=0, qmax=0,
                n_pix=1, n_oc=math.ceil(c / TM), n_ic=math.ceil(c / TN),
                n_grp=math.ceil(c / TC),
                n_ent_in=math.ceil(c / POOL_TM),
                n_ent_out=math.ceil(c / POOL_TM),
                t_in=cur, t_saved=None, t_out=out,
                wbytes=0, pchan=0))
            tensors[cur]["last_use"] = idx
            cur = out
            h = w = 1

        elif kind == "linear":
            oc, ic = op["weight_shape"][:2]
            out = new_tensor(1, 1, oc, idx)
            ops.append(dict(
                idx=idx, opcode=OP_LINEAR, name=op["name"],
                img_h=1, img_w=1, out_h=1, out_w=1, in_c=ic, out_c=oc,
                stride2=False, act=0, qmax=0,
                n_pix=1, n_oc=math.ceil(oc / TM), n_ic=math.ceil(ic / TN),
                n_grp=math.ceil(oc / TC),
                n_ent_in=math.ceil(ic / POOL_TM),
                n_ent_out=math.ceil(oc / POOL_TM),
                t_in=cur, t_saved=None, t_out=out,
                wbytes=oc * ic, pchan=oc))
            tensors[cur]["last_use"] = idx
            cur = out
            c = oc

    return ops, tensors


def allocate(ops, tensors):
    """Static first-fit allocation over the activation pool, in entries.

    A tensor is live from the op that defines it through its last use, so the
    inputs of the current op are still live when its output is placed - which is
    what stops an output overwriting an input it is still reading.
    """
    free = [(0, None)]        # list of (start, end) with None = unbounded
    live = []                 # list of tensor ids

    def intervals():
        return sorted((tensors[t]["addr"], tensors[t]["addr"] + tensors[t]["entries"])
                      for t in live)

    peak = 0
    for op in ops:
        # retire everything whose last use is behind us
        live[:] = [t for t in live if tensors[t]["last_use"] >= op["idx"]]

        out = op["t_out"]
        need = tensors[out]["entries"]

        # first fit in the gaps between live tensors
        addr = 0
        for lo, hi in intervals():
            if addr + need <= lo:
                break
            addr = max(addr, hi)
        tensors[out]["addr"] = addr
        live.append(out)
        peak = max(peak, addr + need)

    return peak


def verify(ops, tensors):
    """Every pair of tensors live at the same time must not overlap."""
    errs = []
    for op in ops:
        at = [t for t, v in tensors.items()
              if v["def_op"] <= op["idx"] <= v["last_use"]]
        for i, a in enumerate(at):
            for b in at[i + 1:]:
                a0, a1 = tensors[a]["addr"], tensors[a]["addr"] + tensors[a]["entries"]
                b0, b1 = tensors[b]["addr"], tensors[b]["addr"] + tensors[b]["entries"]
                if a0 < b1 and b0 < a1:
                    errs.append(f"op {op['idx']} ({op['name']}): tensors {a} and {b} overlap "
                                f"[{a0},{a1}) vs [{b0},{b1})")
        # an op must never write where it reads
        for src in (op["t_in"], op["t_saved"]):
            if src is None or src == op["t_out"]:
                continue
            s0, s1 = tensors[src]["addr"], tensors[src]["addr"] + tensors[src]["entries"]
            d0, d1 = tensors[op["t_out"]]["addr"], tensors[op["t_out"]]["addr"] + tensors[op["t_out"]]["entries"]
            if s0 < d1 and d0 < s1:
                errs.append(f"op {op['idx']} ({op['name']}): output overlaps its own input")
    return errs


# --- the instruction word ----------------------------------------------------
#  8 x 32-bit words. Density is irrelevant here - 74 ops is 2.4 KB either way -
#  so the layout is chosen to be readable in a hex dump and trivial to slice in
#  the RTL. Keep this table and the sequencer's field extraction in step.
#
#   w0  [3:0] opcode  [11:4] img_w  [19:12] img_h  [20] stride2  [21] act
#       [31:24] relu6_qmax
#   w1  [15:0] n_pix  [23:16] n_oc  [31:24] n_ic
#   w2  [7:0]  n_grp  [15:8] n_ent_in  [23:16] n_ent_out
#   w3  [15:0] base_in   [31:16] base_out
#   w4  [15:0] base_saved
#   w5  [23:0] wgt_off      (byte offset into the weight blob)
#   w6  [19:0] wgt_bytes
#   w7  [15:0] pchan        (channels of per-channel parameters to load)
def encode(op, tensors):
    def addr(t):
        return 0 if t is None else tensors[t]["addr"]
    w = [0] * 8
    w[0] = ((op["opcode"] & 0xF)
            | ((op["img_w"] & 0xFF) << 4)
            | ((op["img_h"] & 0xFF) << 12)
            | ((1 if op["stride2"] else 0) << 20)
            | ((op["act"] & 1) << 21)
            | ((op["qmax"] & 0xFF) << 24))
    w[1] = ((op["n_pix"] & 0xFFFF)
            | ((op["n_oc"] & 0xFF) << 16)
            | ((op["n_ic"] & 0xFF) << 24))
    w[2] = ((op["n_grp"] & 0xFF)
            | ((op["n_ent_in"] & 0xFF) << 8)
            | ((op["n_ent_out"] & 0xFF) << 16))
    w[3] = (addr(op["t_in"]) & 0xFFFF) | ((addr(op["t_out"]) & 0xFFFF) << 16)
    w[4] = addr(op["t_saved"]) & 0xFFFF
    w[5] = op.get("wgt_off", 0) & 0xFFFFFF
    w[6] = op["wbytes"] & 0xFFFFF
    w[7] = op["pchan"] & 0xFFFF
    return w


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emit", action="store_true", help="write program.hex and program.txt")
    ap.add_argument("--pool", type=int, default=None, help="pool size in entries to check against")
    args = ap.parse_args()

    if not os.path.exists(MANIFEST):
        sys.exit(f"manifest not found: {MANIFEST}")
    with open(MANIFEST, encoding="utf-8") as fh:
        manifest = json.load(fh)

    ops, tensors = build_ops(manifest)

    # weight blob offsets, in manifest order
    off = 0
    for op in ops:
        op["wgt_off"] = off
        off += op["wbytes"]
    wgt_total = off

    peak = allocate(ops, tensors)
    errs = verify(ops, tensors)

    # ---- listing ----------------------------------------------------------
    lines = []
    lines.append(f"{'#':>3} {'op':<8} {'name':<24} {'out':>14} "
                 f"{'in@':>7} {'out@':>7} {'sv@':>7} {'ent':>7}")
    lines.append("-" * 96)
    for op in ops:
        t = tensors[op["t_out"]]
        ia = "-" if op["t_in"] is None else str(tensors[op["t_in"]]["addr"])
        sa = "-" if op["t_saved"] is None else str(tensors[op["t_saved"]]["addr"])
        lines.append(f"{op['idx']:>3} {OPNAME[op['opcode']]:<8} {op['name']:<24} "
                     f"{f'{op['out_h']}x{op['out_w']}x{op['out_c']}':>14} "
                     f"{ia:>7} {t['addr']:>7} {sa:>7} {t['entries']:>7}")
    listing = "\n".join(lines)

    print(listing)
    print()
    print(f"instructions        : {len(ops)}  "
          f"({sum(1 for o in ops if o['opcode']==OP_PW)} PW, "
          f"{sum(1 for o in ops if o['opcode']==OP_DW)} DW, "
          f"{sum(1 for o in ops if o['opcode']==OP_STEM)} STEM, "
          f"{sum(1 for o in ops if o['opcode']==OP_RES)} RES, "
          f"{sum(1 for o in ops if o['opcode']==OP_GAP)} GAP, "
          f"{sum(1 for o in ops if o['opcode']==OP_LINEAR)} LINEAR)")
    print(f"save ops folded away: {sum(1 for o in manifest['ops'] if o['kind']=='save')}"
          "  (lifetime only, no data movement, no instruction)")
    print(f"weight blob         : {wgt_total:,} B ({wgt_total/1e6:.2f} MB)")
    print(f"program memory      : {len(ops)*32:,} B")
    print()
    print(f"ACTIVATION POOL PEAK: {peak:,} entries x {ENTRY_BYTES} B "
          f"= {peak*ENTRY_BYTES/1024/1024:.2f} MB")
    print(f"  largest single tensor: "
          f"{max(t['entries'] for t in tensors.values()):,} entries "
          f"= {max(t['entries'] for t in tensors.values())*ENTRY_BYTES/1024/1024:.2f} MB")
    print(f"  stem input (separate): {224*224*3:,} B = {224*224*3/1024:.0f} KB")

    if args.pool:
        ok = "OK" if peak <= args.pool else "TOO SMALL"
        print(f"  against --pool {args.pool:,} entries: {ok}")

    print()
    if errs:
        print(f"ALLOCATION INVALID - {len(errs)} problems:")
        for e in errs[:10]:
            print("  " + e)
        sys.exit(1)
    print(f"allocation verified: no two simultaneously live tensors overlap, "
          f"and no op writes where it reads ({len(tensors)} tensors)")

    if args.emit:
        hexpath = os.path.join(OUT_DIR, "program.hex")
        txtpath = os.path.join(OUT_DIR, "program.txt")
        with open(hexpath, "w", encoding="utf-8") as fh:
            for op in ops:
                for word in encode(op, tensors):
                    fh.write(f"{word:08x}\n")
        with open(txtpath, "w", encoding="utf-8") as fh:
            fh.write(listing + "\n")
        print(f"wrote {hexpath} ({len(ops)*8} words)")
        print(f"wrote {txtpath}")


if __name__ == "__main__":
    main()

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
DEFAULT_GOLDEN_DIR = os.path.join(ROOT, "software", "golden", "image_1")
TB_INCLUDE = os.path.join(ROOT, "hardware", "tb", "program_ops.svh")

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
                wbytes=wbytes, pchan=oc,
                files=op["files"], pconst=None))
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
                # pchan is the channel count, NOT zero. The rescale of the skip
                # branch runs on the shared out_stage, which reads (bias, m0,
                # shift) out of the parameter banks like any other op - it just
                # happens to want the same triple in every channel. Leaving
                # pchan at 0 made top_seq take its `no_load` path and never ask
                # the DMA for them, so the banks still held the PREVIOUS layer's
                # scales.
                wbytes=0, pchan=c,
                files=None, pconst=(0, op["m0"], op["shift"])))
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
                # n_pix is how many spatial positions the FEEDER walks, which
                # for every other op is the output pixel count. Global pooling
                # is the one op that consumes more positions than it produces:
                # gap_feeder accumulates over h*w inputs to emit one. Emitting
                # the output count here (1) made it average a single pixel.
                n_pix=h * w, n_oc=math.ceil(c / TM), n_ic=math.ceil(c / TN),
                n_grp=math.ceil(c / TC),
                n_ent_in=math.ceil(c / POOL_TM),
                n_ent_out=math.ceil(c / POOL_TM),
                t_in=cur, t_saved=None, t_out=out,
                wbytes=0, pchan=c,
                files=None, pconst=(0, op["m0"], op["shift"])))
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
                wbytes=oc * ic, pchan=oc,
                files=op["files"], pconst=None))
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
#           n_pix = spatial positions the feeder WALKS: the output pixel
#           count for every op except GAP, which walks its input.
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


# --- the two blobs the DMA reads --------------------------------------------
#  The sequencer hands the DMA (wgt_off, wgt_bytes, pchan) per op, so:
#
#    weights.hex   RANDOM access. wgt_off is a byte offset into this file and
#                  wgt_bytes is the length, both already in the instruction.
#    params_*.hex  SEQUENTIAL. There is no parameter offset in the instruction
#                  and there does not need to be: ops execute in program order,
#                  so the DMA keeps a running index and advances it by
#                  ceil(pchan/TM)*TM triples per op. Reset it on `start`.
#
#  The padding to a multiple of TM is IN the blob rather than left to the DMA.
#  A parameter entry covers TM consecutive channels and the banks are read a
#  whole tile at a time, so channels past pchan would otherwise be read as X -
#  and X survives being multiplied by the next layer's zero weights, which is
#  what the tail contract relies on being harmless. Zeros there make it so.
def read_lines(name):
    with open(os.path.join(OUT_DIR, name), encoding="utf-8") as fh:
        return [ln.strip() for ln in fh if ln.strip()]


def emit_blobs(ops):
    wbytes_seen = 0
    wlines = []
    b_lines, m0_lines, sh_lines = [], [], []
    problems = []

    for op in ops:
        # ---- weights -------------------------------------------------
        if op["wbytes"]:
            w = read_lines(op["files"]["w"])
            if len(w) != op["wbytes"]:
                problems.append(
                    f"op {op['idx']} ({op['name']}): {op['files']['w']} has "
                    f"{len(w)} bytes, instruction says {op['wbytes']}")
            if op["wgt_off"] != wbytes_seen:
                problems.append(
                    f"op {op['idx']} ({op['name']}): wgt_off {op['wgt_off']} "
                    f"but blob is at {wbytes_seen}")
            wlines.extend(w)
            wbytes_seen += len(w)

        # ---- parameters, padded to a whole tile ----------------------
        npad = math.ceil(op["pchan"] / TM) * TM if op["pchan"] else 0
        if npad == 0:
            continue
        if op["pconst"] is not None:
            bias, m0, sh = op["pconst"]
            b_lines .extend([f"{bias & 0xFFFFFFFF:08x}"] * npad)
            m0_lines.extend([f"{m0 & 0xFFFFFFFF:08x}"]   * npad)
            sh_lines.extend([f"{sh & 0xFF:02x}"]         * npad)
        else:
            bb = read_lines(op["files"]["b"])
            mm = read_lines(op["files"]["m0"])
            ss = read_lines(op["files"]["shift"])
            if not (len(bb) == len(mm) == len(ss) == op["pchan"]):
                problems.append(
                    f"op {op['idx']} ({op['name']}): parameter files are "
                    f"{len(bb)}/{len(mm)}/{len(ss)} long, pchan is {op['pchan']}")
            for ch in range(npad):
                inside = ch < len(bb)
                b_lines .append(bb[ch] if inside else "00000000")
                m0_lines.append(mm[ch] if inside else "00000000")
                sh_lines.append(ss[ch] if inside else "00")

    return wlines, b_lines, m0_lines, sh_lines, problems


# --- the testbench's view of the program ------------------------------------
#  accel_tb walks all 64 ops and compares each against its golden vector. It
#  needs two things per op that the instruction word does not carry: the exact
#  output geometry in ELEMENTS (the instruction has tile counts) and which
#  golden file to compare against. Both are generated here rather than typed
#  into the testbench, because a hand-written table is a second source of truth
#  that silently stops matching the first one.
#
#  The golden file comes from golden_manifest.json, matched BY NAME, and the
#  shape it declares is cross-checked against the shape this compiler derived
#  independently by replaying the network. If those two ever disagree the build
#  stops - that disagreement would mean the RTL is being compared against the
#  wrong tensor, which is the one failure mode a bit-exact check cannot see.
def emit_tb_include(ops, golden_dir, manifest):
    with open(os.path.join(golden_dir, "golden_manifest.json"), encoding="utf-8") as fh:
        gm = json.load(fh)
    by_name = {f["name"]: f for f in gm["files"]}

    # The golden set and the weights must come from the SAME checkpoint. They
    # did not once: the model was retrained five weeks after software/export/
    # was committed, and regenerating the export alone moved the weights to the
    # new checkpoint while the goldens stayed on the old one. That showed up as
    # 4.4 million mismatches starting at op 0 - a diagnosis that cost an
    # afternoon, and which this one comparison would have made instant.
    ck_gold = gm.get("ckpt_sha256")
    ck_wgt  = manifest.get("ckpt_sha256")
    if ck_gold and ck_wgt and ck_gold != ck_wgt:
        sys.exit(
            f"CHECKPOINT MISMATCH - the golden set and the weights are from "
            f"different models:\n"
            f"  {os.path.relpath(golden_dir, ROOT)}: {ck_gold[:16]}...\n"
            f"  software/export/manifest.json:      {ck_wgt[:16]}...\n"
            f"Re-run export.py with --image to regenerate this golden set.")
    if not (ck_gold and ck_wgt):
        print("  note: no ckpt_sha256 in one of the manifests - "
              "cannot verify the golden set and the weights share a checkpoint")

    # the whole-tensor goldens the testbench loads directly, not per op
    g_input = by_name.get("input")
    if g_input is None:
        sys.exit(f"golden set {golden_dir} has no 'input' entry")
    g_logits = None

    rows, problems = [], []
    for op in ops:
        g = by_name.get(op["name"])
        split = False
        if g is None:
            # the classifier's golden is split into int32 accumulators and the
            # int16 logits; the logits are what the hardware emits
            g = by_name.get(op["name"] + ".logits_int16")
            split = True
            if g is not None:
                g_logits = g
        if g is None:
            problems.append(f"op {op['idx']} ({op['name']}): no golden vector")
            continue
        if not split and g["seq"] != op["idx"] + 1:
            problems.append(
                f"op {op['idx']} ({op['name']}): golden seq {g['seq']}, "
                f"expected {op['idx'] + 1}")
        if not split:
            shape = g["shape"]           # [1, C, H, W] or [1, C]
            gc = shape[1]
            gh = shape[2] if len(shape) > 2 else 1
            gw = shape[3] if len(shape) > 3 else 1
            if (gc, gh, gw) != (op["out_c"], op["out_h"], op["out_w"]):
                problems.append(
                    f"op {op['idx']} ({op['name']}): golden is "
                    f"{gc}x{gh}x{gw}, compiler says "
                    f"{op['out_c']}x{op['out_h']}x{op['out_w']}")
        rows.append((op, g["file"]))

    if problems:
        print()
        print(f"GOLDEN TABLE INVALID - {len(problems)} problems:")
        for e in problems[:10]:
            print("  " + e)
        sys.exit(1)

    # the testbench runs from sim/xsim_<module>/, two levels below the root
    grel = os.path.relpath(golden_dir, ROOT).replace(os.sep, "/")
    gpath = f"../../{grel}"

    L = []
    L.append("// GENERATED by scripts/gen_program.py --emit -- DO NOT EDIT")
    L.append("// Per-op geometry and golden vectors for accel_tb.")
    L.append("//")
    L.append(f"// golden set : {grel}")
    L.append(f"// image      : {os.path.basename(gm.get('image', '?'))}")
    L.append(f"// predicted  : {gm.get('predicted_class', '?')}  "
             f"logits {gm.get('logits_int16', '?')}")
    L.append(f"// checkpoint : {ck_gold or 'unknown'}")
    L.append("//")
    L.append("// Include this INSIDE the module, after gold_mem is declared:")
    L.append("//     `include \"program_ops.svh\"")
    L.append("// then call load_op_table once before using the arrays.")
    L.append("")
    L.append(f"localparam integer N_PROG_OPS = {len(rows)};")
    L.append("")
    # The expected answer, from the golden set rather than typed into the
    # testbench - a hardcoded "class 1 = esca" survived a change of image and
    # reported the WRONG class as the failure.
    logits = gm.get("logits_int16") or []
    argmax = max(range(len(logits)), key=lambda i: logits[i]) if logits else 0
    L.append(f"localparam integer GOLDEN_ARGMAX = {argmax};")
    L.append(f'localparam string  GOLDEN_CLASS  = "{gm.get("predicted_class", "?")}";')
    L.append("")
    for nm in ("OP_OPCODE", "OP_OC", "OP_IC", "OP_OH", "OP_OW"):
        L.append(f"integer {nm} [0:N_PROG_OPS-1];")
    L.append("")
    L.append("task automatic load_op_table;")
    L.append("    begin")
    for op, _ in rows:
        L.append(f"        OP_OPCODE[{op['idx']}]={op['opcode']}; "
                 f"OP_OC[{op['idx']}]={op['out_c']}; "
                 f"OP_IC[{op['idx']}]={op['in_c']}; "
                 f"OP_OH[{op['idx']}]={op['out_h']}; "
                 f"OP_OW[{op['idx']}]={op['out_w']};"
                 f"  // {OPNAME[op['opcode']]} {op['name']}")
    L.append("    end")
    L.append("endtask")
    L.append("")
    L.append("// $readmemh needs a literal, so this is a case rather than a string array.")
    L.append("task automatic load_golden(input integer k);")
    L.append("    begin")
    L.append("        case (k)")
    for op, fname in rows:
        L.append(f'        {op["idx"]}: $readmemh("{gpath}/{fname}", gold_mem);')
    L.append("        default: $display(\"  [ERR] no golden vector for op %0d\", k);")
    L.append("        endcase")
    L.append("    end")
    L.append("endtask")
    L.append("")
    # The input image and the final logits belong to the same golden set as the
    # per-op vectors, so they are emitted here too rather than typed into the
    # testbench. Tasks, not string parameters, because $readmemh wants a literal.
    L.append("// The input image and the expected logits, from the same golden set.")
    L.append("task automatic load_input;")
    L.append(f'    $readmemh("{gpath}/{g_input["file"]}", img_mem);')
    L.append("endtask")
    L.append("")
    L.append("task automatic load_gold_logits;")
    if g_logits is None:
        L.append('    $display("  [ERR] golden set has no int16 logits");')
    else:
        L.append(f'    $readmemh("{gpath}/{g_logits["file"]}", gold_log);')
    L.append("endtask")
    L.append("")

    with open(TB_INCLUDE, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(L))
    print(f"wrote {TB_INCLUDE} ({len(rows)} ops)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emit", action="store_true", help="write program.hex and program.txt")
    ap.add_argument("--pool", type=int, default=None, help="pool size in entries to check against")
    ap.add_argument("--golden-dir", default=DEFAULT_GOLDEN_DIR,
                    help="golden set the testbench compares against "
                         "(default: software/golden/image_1)")
    args = ap.parse_args()

    if not os.path.isdir(args.golden_dir):
        sys.exit(f"golden dir not found: {args.golden_dir}")

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

        wlines, b_lines, m0_lines, sh_lines, problems = emit_blobs(ops)
        if problems:
            print()
            print(f"BLOBS INVALID - {len(problems)} problems:")
            for e in problems[:10]:
                print("  " + e)
            sys.exit(1)
        for name, lines in (("weights.hex",      wlines),
                            ("params_b.hex",     b_lines),
                            ("params_m0.hex",    m0_lines),
                            ("params_shift.hex", sh_lines)):
            path = os.path.join(OUT_DIR, name)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("\n".join(lines) + "\n")
            print(f"wrote {path} ({len(lines):,} lines)")

        emit_tb_include(ops, args.golden_dir, manifest)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""analyze_workload.py - recompute every architectural number from the manifest.

The roofline inputs, the Tm/Tn choice and the depthwise finding in
docs/controller_design.md all come from here. Nothing is hard-coded: shapes are
replayed from software/export/manifest.json, so if the network is retrained or
re-exported the numbers follow automatically.

Usage:
    python scripts/analyze_workload.py            # all sections
    python scripts/analyze_workload.py roofline   # one section
    python scripts/analyze_workload.py sweep depthwise

Sections: roofline | sweep | tail | depthwise
"""
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "software", "export", "manifest.json")

# --- design constants (keep in sync with docs/controller_design.md) ----------
CLK = 250e6          # Hz, design target
DSP_TOTAL = 1728     # DSP48E2 on the XCZU7EV
P = 512              # MAC/cycle of the pointwise array
TM, TN = 32, 16      # DD-013
TC = 16              # DD-014, depthwise channels per cycle
INPUT_BYTES = 3 * 224 * 224


def load_ops():
    """Replay the network and return (pointwise, depthwise, stem, totals).

    Spatial dims are not in the manifest, so they are derived by walking the ops
    in order from the 224x224x3 input - exactly what the controller will do.
    """
    with open(MANIFEST, encoding="utf-8") as fh:
        manifest = json.load(fh)

    h = w = 224
    c = 3
    pw, dw, stem = [], [], None
    macs = {"pointwise": 0, "depthwise": 0, "stem": 0, "other": 0}
    wbytes = {"pointwise": 0, "depthwise": 0, "stem": 0, "other": 0}
    bias_bytes = 0

    for op in manifest["ops"]:
        kind = op["kind"]
        if kind == "conv":
            oc, ic_g, kh, kw = op["weight_shape"]
            s = op["stride"][0]
            p = op["padding"][0]
            oh = (h + 2 * p - kh) // s + 1
            ow = (w + 2 * p - kw) // s + 1
            n_mac = oh * ow * oc * ic_g * kh * kw
            n_w = oc * ic_g * kh * kw

            if op["groups"] > 1:
                key = "depthwise"
                dw.append((op["name"], oh, ow, oc))
            elif kh == 1:
                key = "pointwise"
                pw.append((op["name"], oh, ow, c, oc))
            else:
                key = "stem"
                stem = (op["name"], oh, ow, c, oc)

            macs[key] += n_mac
            wbytes[key] += n_w
            bias_bytes += oc * 4
            h, w, c = oh, ow, oc

        elif kind == "gap":
            macs["other"] += c * h * w
            h = w = 1

        elif kind == "linear":
            oc, ic = op["weight_shape"][:2]
            macs["other"] += oc * ic
            wbytes["other"] += oc * ic
            bias_bytes += oc * 4
            # the classifier is a 1x1x1280 -> 4 dot product: it runs on the array too
            pw.append((op["name"], 1, 1, ic, oc))
            c = oc

    return manifest, pw, dw, stem, macs, wbytes, bias_bytes


def pw_cycles(oh, ow, ic, oc, tm, tn):
    """Cycle model of the output-stationary pointwise array (section 5)."""
    return oh * ow * math.ceil(oc / tm) * math.ceil(ic / tn)


# --- sections ---------------------------------------------------------------
def sec_roofline(macs, wbytes, bias_bytes):
    total_mac = sum(macs.values())
    total_w = sum(wbytes.values())
    print("== roofline inputs (section 3) ==")
    print(f"  workload        : {total_mac:,} MACs ({total_mac/1e6:.1f} M)")
    print(f"  weights         : {total_w:,} B int8 ({total_w/1e6:.2f} MB)")
    print(f"  bias            : {bias_bytes:,} B int32 ({bias_bytes/1e6:.2f} MB)")
    print(f"  peak, 1 MAC/DSP : {DSP_TOTAL*CLK/1e9:.0f} GMAC/s")
    print(f"  peak, int8 pack : {2*DSP_TOTAL*CLK/1e9:.0f} GMAC/s")

    print("\n  workload split:")
    for key in ("pointwise", "depthwise", "stem", "other"):
        share = 100 * macs[key] / total_mac
        wshare = 100 * wbytes[key] / total_w
        print(f"    {key:<10} {macs[key]:>13,} MACs  {share:5.1f}%   "
              f"{wbytes[key]:>9,} B  {wshare:5.1f}%")

    traffic = total_w + bias_bytes + INPUT_BYTES
    intensity = total_mac / traffic
    print(f"\n  DRAM traffic    : {traffic/1e6:.2f} MB (weights + bias + input)")
    print(f"  intensity       : {intensity:.0f} MAC/byte")
    for bw in (12e9, 19e9):
        ridge = 2 * DSP_TOTAL * CLK / bw
        verdict = "compute-bound" if intensity > ridge else "MEMORY-BOUND"
        print(f"  ridge @{bw/1e9:5.0f} GB/s: {ridge:5.0f} MAC/byte  -> {verdict}")


def sec_sweep(pw):
    print("== Tm/Tn sweep at constant P=512 (section 5, DD-013) ==")
    useful = sum(oh * ow * ic * oc for _, oh, ow, ic, oc in pw)
    configs = [(8, 64), (16, 32), (32, 16), (64, 8)]
    print(f"  {'Tm x Tn':>10} {'util':>8} {'cycles':>10} {'ms@250MHz':>11}")
    for tm, tn in configs:
        cyc = sum(pw_cycles(oh, ow, ic, oc, tm, tn) for _, oh, ow, ic, oc in pw)
        mark = "  <-- DD-013" if (tm, tn) == (TM, TN) else ""
        print(f"  {f'{tm} x {tn}':>10} {100*useful/(P*cyc):7.1f}% {cyc:>10,} "
              f"{1e3*cyc/CLK:>11.2f}{mark}")


def sec_tail(pw):
    print(f"== where the tail-padding goes at Tm={TM}, Tn={TN} (section 5) ==")
    rows = []
    for name, oh, ow, ic, oc in pw:
        cyc = pw_cycles(oh, ow, ic, oc, TM, TN)
        rows.append((name, cyc, cyc - oh * ow * ic * oc / P, oc, ic))
    total = sum(r[1] for r in rows)
    waste = sum(r[2] for r in rows)
    print(f"  {total:,} cycles, {waste:,.0f} wasted ({100*waste/total:.1f}%)\n")
    print(f"  {'layer':<24}{'cycles':>10}{'wasted':>10}{'share':>8}  cause")
    for name, cyc, w, oc, ic in sorted(rows, key=lambda r: -r[2])[:6]:
        why = []
        if oc % TM:
            why.append(f"OC={oc}->{math.ceil(oc/TM)*TM}")
        if ic % TN:
            why.append(f"IC={ic}->{math.ceil(ic/TN)*TN}")
        print(f"  {name:<24}{cyc:>10,}{w:>10,.0f}{100*w/waste:>7.1f}%  "
              f"{', '.join(why) or '-'}")


def sec_depthwise(pw, dw, stem):
    print("== depthwise bottleneck (section 6, DD-014) ==")
    pw_c = sum(pw_cycles(oh, ow, ic, oc, TM, TN) for _, oh, ow, ic, oc in pw)
    stem_c = stem[1] * stem[2] * stem[4]          # 1 element/cycle, 27 taps parallel
    print(f"  {'Tc':>4} {'DSPs':>6} {'dw ms':>8} {'total ms':>10} {'fps':>7}")
    for tc in (1, 8, 16, 32):
        dw_c = sum(math.ceil(oc / tc) * oh * ow for _, oh, ow, oc in dw)
        total = pw_c + dw_c + stem_c
        mark = "  <-- DD-014" if tc == TC else ""
        print(f"  {tc:>4} {math.ceil(tc*9/2):>6} {1e3*dw_c/CLK:>8.2f} "
              f"{1e3*total/CLK:>10.2f} {CLK/total:>7.0f}{mark}")
    print(f"\n  pointwise array: {pw_c:,} cycles = {1e3*pw_c/CLK:.2f} ms")
    print(f"  stem @1/cycle  : {stem_c:,} cycles = {1e3*stem_c/CLK:.2f} ms")


SECTIONS = {
    "roofline": lambda ctx: sec_roofline(ctx["macs"], ctx["wbytes"], ctx["bias"]),
    "sweep": lambda ctx: sec_sweep(ctx["pw"]),
    "tail": lambda ctx: sec_tail(ctx["pw"]),
    "depthwise": lambda ctx: sec_depthwise(ctx["pw"], ctx["dw"], ctx["stem"]),
}


def main():
    if not os.path.exists(MANIFEST):
        sys.exit(f"manifest not found: {MANIFEST}\nRun software/train/export.py first.")

    _, pw, dw, stem, macs, wbytes, bias = load_ops()
    ctx = {"pw": pw, "dw": dw, "stem": stem,
           "macs": macs, "wbytes": wbytes, "bias": bias}

    wanted = sys.argv[1:] or list(SECTIONS)
    for name in wanted:
        if name not in SECTIONS:
            sys.exit(f"unknown section '{name}'. choose from: {', '.join(SECTIONS)}")
    for i, name in enumerate(wanted):
        if i:
            print()
        SECTIONS[name](ctx)


if __name__ == "__main__":
    main()

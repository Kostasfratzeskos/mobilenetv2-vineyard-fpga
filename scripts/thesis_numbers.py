#!/usr/bin/env python3
"""Emit thesis/generated/numbers.tex from the repository's own artefacts.

Every number the manuscript quotes about the network or about an implementation
run is defined here as a LaTeX macro, recomputed from `software/export/manifest.json`,
from the Vivado reports under `build/`, and from the test-set report that
`evaluate.py --report` writes (DD-034). Nothing is typed into the text.

The reason is DD-019 in prose form: a number that was measured once and then
copied by hand is true only until the thing it measured changes. `analyze_workload.py`
already refuses to hard-code the architectural numbers; this does the same for the
manuscript.

What this file cannot derive - cycle counts from simulation logs - lives in
`thesis/manual_numbers.tex`, where each macro has to carry a comment saying where
it came from. If a number is not in one of those two files, it does not belong in
the text.

Usage:
    python scripts/thesis_numbers.py            # write thesis/generated/numbers.tex
    python scripts/thesis_numbers.py --stdout   # print instead, for inspection
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from analyze_workload import load_ops  # noqa: E402  - one source of truth for the network

OUT = os.path.join(ROOT, "thesis", "generated", "numbers.tex")
MANIFEST = os.path.join(ROOT, "software", "export", "manifest.json")
# evaluate.py --split test --report: the held-out test set, scored once (DD-034)
ACCURACY = os.path.join(ROOT, "software", "runs", "mobilenetv2_grape_leafsplit_test.json")

# Device totals for the XCZU7EV-ffvc1156-2-e, so utilisation percentages are
# derived here rather than trusted from whichever report happened to be open.
DEVICE = {
    "LUT": 230400,
    "FF": 460800,
    "BRAM": 312,
    "URAM": 96,
    "DSP": 1728,
}

# build/ directory -> macro suffix. Letters only: LaTeX macro names cannot carry
# digits or underscores. A directory that is missing is skipped with a note, so
# the file always regenerates on a fresh clone.
RUNS = [
    # the timing progression of the RTL review, chapter "Timing Closure"
    ("impl_base_4p000", "Base", "baseline, before the review"),
    ("impl_phase1_4p000", "PhaseOne", "observability only, no datapath change"),
    ("impl_dd020_4p000", "SyncReset", "DD-020, synchronous reset"),
    ("impl_p2a_4p000", "PhaseTwoA", "mac_lane and pe_array pipelined"),
    ("impl_p2b_4p000", "PhaseTwoB", "dwconv3x3 pipelined"),
    ("impl_p2c_4p000", "PhaseTwoC", "conv3x3_std pipelined"),
    ("impl_p2d_4p000", "PhaseTwoD", "requantize pipelined"),
    ("impl_p3_4p000", "PhaseThree", "A-1, act_buffer address register"),
    ("impl_p4a_4p000", "PhaseFour", "correctness pass"),
    # the three tops, out of context, after the image path landed
    ("impl_accel_top_img_4p000", "AccelTop", "accelerator alone, OOC"),
    ("impl_accel_sys_img_4p000", "AccelSys", "+ weight DMA, OOC"),
    ("impl_accel_axi_img_4p000", "AccelAxi", "+ AXI-Lite CSR, OOC"),
    # in context, on the ZCU104 block design
    ("bd_187p5_explore", "Board", "ZCU104 block design, in context"),
]


def git_commit():
    try:
        out = subprocess.run(
            ["git", "-C", ROOT, "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unknown"


def parse_period(run_dir):
    """Constrained clock period in ns, from the XDC that drove the run."""
    for name in sorted(os.listdir(run_dir)):
        if not name.endswith(".xdc"):
            continue
        with open(os.path.join(run_dir, name), encoding="utf-8", errors="replace") as fh:
            m = re.search(r"create_clock\s+-period\s+([0-9.]+)", fh.read())
            if m:
                return float(m.group(1))
    # block-design runs have no OOC XDC; the timing report states the period
    rpt = os.path.join(run_dir, "timing_summary.rpt")
    if os.path.exists(rpt):
        with open(rpt, encoding="utf-8", errors="replace") as fh:
            m = re.search(r"^Period\(ns\):\s+([0-9.]+)", fh.read(), re.M)
            if m:
                return float(m.group(1))
    return None


def parse_wns(run_dir):
    """Worst negative slack in ns, from the Design Timing Summary table."""
    rpt = os.path.join(run_dir, "timing_summary.rpt")
    if not os.path.exists(rpt):
        return None
    with open(rpt, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    m = re.search(r"Design Timing Summary.*?WNS\(ns\).*?\n\s*-+.*?\n\s*(-?[0-9.]+)",
                  text, re.S)
    return float(m.group(1)) if m else None


def parse_utilisation(run_dir):
    """LUT / FF / BRAM / URAM / DSP from the post-route utilisation report."""
    rpt = os.path.join(run_dir, "utilization.rpt")
    if not os.path.exists(rpt):
        return {}
    with open(rpt, encoding="utf-8", errors="replace") as fh:
        text = fh.read()

    def cell(label):
        # "| CLB LUTs  | 37349 | 0 | 0 | 230400 | 16.21 |" - first column only.
        # Block RAM comes out fractional (165.5) when RAMB18s are counted as halves.
        m = re.search(r"^\|\s*" + label + r"\s*\|\s*([0-9.]+)\s*\|", text, re.M)
        return float(m.group(1)) if m else None

    return {
        "LUT": cell(r"CLB LUTs"),
        "FF": cell(r"CLB Registers"),
        "BRAM": cell(r"Block RAM Tile"),
        "URAM": cell(r"URAM"),
        "DSP": cell(r"DSPs"),
    }


def emit(lines, macro, value, comment=None):
    tail = "  % " + comment if comment else ""
    lines.append(r"\newcommand{\th%s}{%s}%s" % (macro, value, tail))


def network_macros(lines):
    manifest, pw, dw, stem, macs, wbytes, bias_bytes = load_ops()
    total_macs = sum(macs.values())
    total_w = sum(wbytes.values())

    lines.append("% --- the network, replayed from software/export/manifest.json ---")
    emit(lines, "Classes", len(manifest["classes"]))
    emit(lines, "ClassList", ", ".join(manifest["classes"]))
    emit(lines, "ImgSize", manifest["img_size"])
    emit(lines, "CkptSha", manifest["ckpt_sha256"][:12],
         "first 12 hex digits; the manifest carries the full hash")
    emit(lines, "ManifestOps", len(manifest["ops"]))
    # Two totals, because "MACs per inference" is ambiguous and the repository's
    # documents have quoted both: the global-average-pool accumulations are
    # additions with no multiply, and counting them moves the figure by ~62.7k.
    # Pick one in the text and say which.
    conv_macs = macs["pointwise"] + macs["depthwise"] + macs["stem"]
    emit(lines, "Macs", "{:,}".format(total_macs).replace(",", r"\,"),
         "convolution + classifier + GAP accumulations")
    emit(lines, "MacsConv", "{:,}".format(conv_macs).replace(",", r"\,"),
         "convolution layers only")
    emit(lines, "MacsM", "{:.1f}".format(total_macs / 1e6))
    emit(lines, "WeightMB", "{:.2f}".format(total_w / 1e6))
    emit(lines, "BiasMB", "{:.2f}".format(bias_bytes / 1e6))
    emit(lines, "PwLayers", len(pw))
    emit(lines, "DwLayers", len(dw))
    for key, macro in (("pointwise", "PwMacPct"), ("depthwise", "DwMacPct"),
                       ("stem", "StemMacPct"), ("other", "OtherMacPct")):
        emit(lines, macro, "{:.1f}".format(100.0 * macs[key] / total_macs))
    lines.append("")


RTL_TOP = os.path.join(ROOT, "hardware", "rtl", "control", "accel_top.v")
EXPORT_DIR = os.path.dirname(MANIFEST)


def _hex_values(path, bits):
    """One two's-complement value per line, as export.py writes them."""
    out = []
    with open(path, encoding="utf-8") as fh:
        for tok in fh.read().split():
            v = int(tok, 16)
            out.append(v - (1 << bits) if v >= 1 << (bits - 1) else v)
    return out


def accumulator_macros(lines):
    """The accumulator bound (DD-019), replayed from the export on every run.

    These figures used to be copied by hand into manual_numbers.tex, and a retrain
    (DD-034) made every one of them wrong at once - DD-019's failure, in prose. The
    walk is export.py's acc_bound(): a_max starts at 128 (the int8 image), is a
    ReLU6 layer's relu6_qmax after it and 128 otherwise, and per output channel

        |acc + bias| <= (sum over taps of |w|) * a_max + |bias|

    It is repeated here rather than imported because export.py needs torch, and
    `make numbers` should not. Checked on 2026-10-22: replayed on the previous
    export it gives the hand-copied figures exactly (5,094,750 / 24 bits /
    classifier.1 / 14 layers over 21 bits / largest shift 48).
    """
    with open(MANIFEST, encoding="utf-8") as fh:
        manifest = json.load(fh)
    a_max = 128
    worst = (0, "?", -1, 0)               # bound, layer, channel, that channel's bias
    geo = (0, "?")                        # taps * 128 * 128, the format-only bound
    shift = (0, "?")
    peaks = []
    for op in manifest["ops"]:
        if op["kind"] in ("conv", "linear"):
            files = op["files"]
            w = _hex_values(os.path.join(EXPORT_DIR, files["w"]), 8)
            b = _hex_values(os.path.join(EXPORT_DIR, files["b"]), 32)
            sh = _hex_values(os.path.join(EXPORT_DIR, files["shift"]), 8)
            oc = op["weight_shape"][0]
            taps = len(w) // oc
            peak = 0
            for c in range(oc):
                bound = sum(abs(x) for x in w[c * taps:(c + 1) * taps]) * a_max + abs(b[c])
                peak = max(peak, bound)
                if bound > worst[0]:
                    worst = (bound, op["name"], c, b[c])
            peaks.append(peak)
            if taps * 128 * 128 > geo[0]:
                geo = (taps * 128 * 128, op["name"])
            top = max(v & 0xFF for v in sh)
            if top > shift[0]:
                shift = (top, op["name"])
        if op["kind"] == "save":
            continue
        a_max = max(int(op["relu6_qmax"]), 1) if op["kind"] == "conv" and op.get("relu6") else 128

    with open(RTL_TOP, encoding="utf-8") as fh:
        m = re.search(r"parameter\s+ACC_W\s*=\s*(\d+)", fh.read())
    acc_w = int(m.group(1)) if m else None
    bits = (worst[0]).bit_length() + 1   # signed bits that hold +-worst
    thin = lambda n: "{:,}".format(n).replace(",", r"\,")   # noqa: E731

    lines.append("% --- the accumulator bound (DD-019), replayed from software/export ---")
    emit(lines, "AccBound", thin(worst[0]), "the provable worst |acc + bias|, any input")
    emit(lines, "AccBoundBits", bits, "signed bits it needs")
    emit(lines, "AccBoundLayer", worst[1])
    emit(lines, "AccBoundChannel", worst[2])
    emit(lines, "AccBoundBias", thin(abs(worst[3])), "that channel's folded bias, alone")
    if acc_w:
        emit(lines, "AccRange", thin(1 << (acc_w - 1)), "2^(ACC_W-1), ACC_W = %d read from the RTL" % acc_w)
        emit(lines, "AccMargin", "{:.1f}".format((1 << (acc_w - 1)) / worst[0]), "at ACC_W = %d" % acc_w)
    else:
        lines.append("% ACC_W not found in %s - AccRange/AccMargin not defined"
                     % os.path.relpath(RTL_TOP, ROOT))
    emit(lines, "AccMarginNarrow", "{:.1f}".format((1 << (bits - 1)) / worst[0]),
         "at the narrowest safe width, ACC_W = AccBoundBits")
    emit(lines, "AccGeom", thin(geo[0]), "taps * 128 * 128, maximised over the network: %s" % geo[1])
    emit(lines, "AccUnsafeLayers", sum(1 for p in peaks if p >= 1 << 20),
         "layers whose bound does not fit the original 21-bit accumulator")
    emit(lines, "MaxShift", shift[0], "the largest requantization shift exported")
    emit(lines, "MaxShiftLayer", shift[1])
    lines.append("")


def accuracy_macros(lines):
    """Float and int8 accuracy on the held-out test split, from evaluate.py's report.

    The int8 figures are the integer pipeline's - the arithmetic the accelerator
    reproduces bit for bit - so they are the accelerator's accuracy, provided the
    report's checkpoint is the one software/export/ was built from. When it is
    not, that is said in the output, not left for a reader to discover.
    """
    rel = os.path.relpath(ACCURACY, ROOT).replace(os.sep, "/")
    if not os.path.exists(ACCURACY):
        lines.append("%% %s missing - accuracy macros not defined" % rel)
        lines.append("")
        return
    with open(ACCURACY, encoding="utf-8") as fh:
        rep = json.load(fh)
    if rep["split"] != "test":
        sys.exit("%s scores the %r split - only the test split is a result" % (rel, rep["split"]))

    def pct(x):
        return "{:.2f}".format(100.0 * x)

    def name(s):   # LaTeX macro names take letters only
        return re.sub(r"[^A-Za-z]", "", s)

    lines.append("% --- accuracy on the held-out test split, from " + rel + " ---")
    with open(MANIFEST, encoding="utf-8") as fh:
        deployed = json.load(fh)["ckpt_sha256"]
    if rep["ckpt_sha256"] != deployed:
        note = ("WARNING: accuracy measured on checkpoint %s, but software/export/ is built "
                "from %s - these are not the deployed model's numbers"
                % (rep["ckpt_sha256"][:12], deployed[:12]))
        lines.append("% " + note)
        print(note, file=sys.stderr)
    emit(lines, "AccCkptSha", rep["ckpt_sha256"][:12], "the checkpoint these were measured on")
    emit(lines, "AccTestImages", rep["images"])
    emit(lines, "AccTestLeaves", rep["groups"],
         "independent leaves (healthy: runs of 4 frames, an approximation)")
    emit(lines, "AccBestEpoch", rep["ckpt_best_epoch"], "chosen on val/, never on test/")
    emit(lines, "AccValSelect", pct(rep["ckpt_best_val_acc"]),
         "val accuracy at that epoch - a selection score, not a result")
    for key, tag in (("float", "Float"), ("int8", "Int")):
        m = rep[key]
        emit(lines, "Acc" + tag, pct(m["accuracy"]),
             "percent, %d/%d correct" % (m["correct"], m["images"]))
        emit(lines, "Acc%sErrors" % tag, m["images"] - m["correct"])
        lo, hi = m["ci95_per_image"]
        emit(lines, "Acc%sCiImageLo" % tag, pct(lo), "95% Wilson, photos as independent")
        emit(lines, "Acc%sCiImageHi" % tag, pct(hi))
        lo, hi = m["ci95_per_leaf"]
        emit(lines, "Acc%sCiLeafLo" % tag, pct(lo), "95% Wilson, one observation per leaf")
        emit(lines, "Acc%sCiLeafHi" % tag, pct(hi))
        emit(lines, "Acc%sMacroF" % tag, "{:.4f}".format(m["macro_f1"]), "macro-averaged F1")
        for cls, r in m["per_class"].items():
            for metric, short in (("precision", "Prec"), ("recall", "Rec"), ("f1", "F")):
                emit(lines, "Acc%s%s%s" % (tag, short, name(cls)), "{:.4f}".format(r[metric]))
        for t, row in zip(rep["classes"], m["confusion"]):
            for p, v in zip(rep["classes"], row):
                emit(lines, "Acc%sConf%s%s" % (tag, name(t), name(p)), v,
                     "true %s, predicted %s" % (t, p))
    for cls, r in rep["float"]["per_class"].items():
        emit(lines, "AccTestImages" + name(cls), r["support"])
        emit(lines, "AccTestLeaves" + name(cls), r["groups"])
    emit(lines, "AccDrop", "{:.2f}".format(100.0 * (rep["float"]["accuracy"]
                                                    - rep["int8"]["accuracy"])),
         "points, float minus int8")
    emit(lines, "AccDisagree", len(rep["int8_float_disagree"]),
         "test images where int8 and float predict differently")
    lines.append("")


def run_macros(lines):
    lines.append("% --- implementation runs, parsed from build/*/ Vivado reports ---")
    for dirname, suffix, note in RUNS:
        run_dir = os.path.join(ROOT, "build", dirname)
        if not os.path.isdir(run_dir):
            lines.append("%% build/%s missing - macros \\th*%s not defined" % (dirname, suffix))
            continue

        period = parse_period(run_dir)
        wns = parse_wns(run_dir)
        util = parse_utilisation(run_dir)

        lines.append("%% build/%s - %s" % (dirname, note))
        if period is not None:
            emit(lines, "Clk" + suffix, "{:.1f}".format(1000.0 / period),
                 "MHz, the clock the run was CONSTRAINED at")
        if period is not None and wns is not None:
            emit(lines, "Wns" + suffix, "{:.3f}".format(wns))
            # For a failing run this is the frequency the design reaches. For a
            # met constraint it is a capability, not an operating point: the run
            # is signed off at its constrained clock, and on the PL clock grid
            # the achievable figure is usually not even selectable.
            emit(lines, "Fmax" + suffix, "{:.1f}".format(1000.0 / (period - wns)),
                 "MHz, = 1000/(%.3f - WNS)%s" % (
                     period, "; constraint MET, so quote ThClk instead" if wns >= 0 else ""))
        for key, value in util.items():
            if value is None:
                continue
            shown = "{:,}".format(int(value)) if float(value).is_integer() else "{:.1f}".format(value)
            emit(lines, key.title() + suffix, shown.replace(",", r"\,"))
            emit(lines, key.title() + "Pct" + suffix,
                 "{:.2f}".format(100.0 * value / DEVICE[key]))
        lines.append("")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stdout", action="store_true", help="print instead of writing")
    args = ap.parse_args()

    lines = [
        "% Generated by scripts/thesis_numbers.py - DO NOT EDIT.",
        "% Regenerate with: make -C thesis numbers",
        "%% Repository commit: %s" % git_commit(),
        "%% Generated: %s" % datetime.date.today().isoformat(),
        "",
    ]
    network_macros(lines)
    accumulator_macros(lines)
    accuracy_macros(lines)
    run_macros(lines)

    text = "\n".join(lines) + "\n"
    if args.stdout:
        sys.stdout.write(text)
        return

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    n = sum(1 for line in lines if line.startswith(r"\newcommand"))
    print("wrote %s (%d macros)" % (os.path.relpath(OUT, ROOT), n))


if __name__ == "__main__":
    main()

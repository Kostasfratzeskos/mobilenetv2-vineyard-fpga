#!/usr/bin/env python3
"""Emit thesis/generated/numbers.tex from the repository's own artefacts.

Every number the manuscript quotes about the network or about an implementation
run is defined here as a LaTeX macro, recomputed from `software/export/manifest.json`
and from the Vivado reports under `build/`. Nothing is typed into the text.

The reason is DD-019 in prose form: a number that was measured once and then
copied by hand is true only until the thing it measured changes. `analyze_workload.py`
already refuses to hard-code the architectural numbers; this does the same for the
manuscript.

What this file cannot derive - cycle counts from simulation logs, accuracy from an
evaluation run - lives in `thesis/manual_numbers.tex`, where each macro has to carry
a comment saying where it came from. If a number is not in one of those two files,
it does not belong in the text.

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

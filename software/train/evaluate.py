"""Evaluate a checkpoint on one split - the float model AND the integer pipeline.

The protocol (DD-034): train on train/, choose the checkpoint on val/, calibrate
the int8 scales (quantize.py), and only then run this ONCE with --split test.
--split val is fine for a look; a val number is a selection score, not a result.

Two models are scored on the same images:
  float  the checkpoint as trained;
  int8   the integer pipeline export.py defines - the arithmetic the
         accelerator reproduces bit for bit (DD-006) - not the fake-quant
         approximation quantize.py prints (DD-009 says how they differ).
For each: accuracy, per-class precision / recall / F1, macro-F1, the confusion
matrix and every misclassified file; and the images on which the two disagree,
which is the cost of the quantisation itself.

Accuracy carries two 95% Wilson intervals, because the test images are not
independent - PlantVillage photographed every leaf four times. "per image"
treats each photo as its own observation, which is too narrow; "per leaf"
counts each group of the dataset's split.csv once, which is conservative. The
truth lies between them, so quote both.

--report writes all of it as JSON, which scripts/thesis_numbers.py reads.

Run from inside software/:
    python train/evaluate.py --data ../data/grape_leafsplit --split test \\
        --ckpt runs/mobilenetv2_grape_leafsplit.pth \\
        --scales runs/quant_scales_grape_leafsplit.json \\
        --report runs/mobilenetv2_grape_leafsplit_test.json
"""
from __future__ import annotations

import argparse
import csv
import datetime
import hashlib
import json
import math
import os
import subprocess
import sys
import time

import numpy as np
import torch

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from model.mobilenetv2 import load_checkpoint  # noqa: E402
from dataset import make_eval_loader  # noqa: E402
from quantize import fuse_conv_bn  # noqa: E402
from export import (IntExecutor, acc_bound, build_int_plan,  # noqa: E402
                    calibrate_logit_scale, quantize_input, rtl_acc_w, sha256_file)

Z95 = 1.959964


def wilson(p, n, z=Z95):
    """95% Wilson score interval for a proportion p seen over n observations.
    Unlike p +/- 1.96 sigma it stays inside [0,1] and is not zero-width at p = 1."""
    if n == 0:
        return [float("nan"), float("nan")]
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return [max(0.0, c - h), min(1.0, c + h)]


def load_groups(data_dir, samples, classes):
    """Leaf group of every sample, from <data>/split.csv (resplit_dataset.py).
    Without it each image is its own group, and the per-leaf interval says nothing."""
    path = os.path.join(data_dir, "split.csv")
    names = [(classes[y], os.path.basename(p)) for p, y in samples]
    if not os.path.exists(path):
        print(f"WARNING: no {path} - every image is its own group")
        return [f"{c}/{f}" for c, f in names]
    with open(path, newline="") as fh:
        g = {(r["class"], r["file"]): f"{r['class']}/{r['group']}" for r in csv.DictReader(fh)}
    missing = [n for n in names if n not in g]
    assert not missing, f"{len(missing)} images not in {path}, e.g. {missing[:2]}"
    return [g[n] for n in names]


def metrics(y_true, y_pred, classes, names, groups):
    n = len(classes)
    cm = np.zeros((n, n), dtype=np.int64)
    for t, p in zip(y_true, y_pred):
        cm[t, p] += 1
    total, correct = int(cm.sum()), int(np.trace(cm))
    acc = correct / total
    per, f1s = {}, []
    for c in range(n):
        tp, support, predicted = int(cm[c, c]), int(cm[c].sum()), int(cm[:, c].sum())
        prec = tp / predicted if predicted else 0.0
        rec = tp / support if support else 0.0
        f1 = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
        f1s.append(f1)
        per[classes[c]] = {"precision": prec, "recall": rec, "f1": f1, "support": support,
                           "groups": len({g for g, t in zip(groups, y_true) if t == c})}
    return {
        "accuracy": acc, "correct": correct, "images": total,
        "ci95_per_image": wilson(acc, total),
        "ci95_per_leaf": wilson(acc, len(set(groups))),
        "macro_f1": float(np.mean(f1s)),
        "per_class": per,
        "confusion": cm.tolist(),   # rows = true class, columns = predicted
        "errors": [{"file": names[i], "true": classes[t], "pred": classes[p]}
                   for i, (t, p) in enumerate(zip(y_true, y_pred)) if t != p],
    }


def show(title, m, classes):
    lo, hi = m["ci95_per_image"]
    llo, lhi = m["ci95_per_leaf"]
    print(f"\n{title}")
    print(f"  accuracy {100 * m['accuracy']:.2f}%  ({m['correct']}/{m['images']})   "
          f"95% CI per image [{100 * lo:.2f}, {100 * hi:.2f}]  per leaf [{100 * llo:.2f}, {100 * lhi:.2f}]")
    print(f"  macro-F1 {m['macro_f1']:.4f}")
    print(f"  {'class':<14s}{'precision':>10s}{'recall':>8s}{'F1':>8s}{'images':>8s}{'leaves':>8s}")
    for c in classes:
        r = m["per_class"][c]
        print(f"  {c:<14s}{r['precision']:>10.4f}{r['recall']:>8.4f}{r['f1']:>8.4f}"
              f"{r['support']:>8d}{r['groups']:>8d}")
    w = max(len(c) for c in classes)
    print(f"  confusion (rows true, columns predicted):")
    print("  " + " " * w + "".join(f"{c[:11]:>12s}" for c in classes))
    for c, row in zip(classes, m["confusion"]):
        print(f"  {c:<{w}s}" + "".join(f"{v:>12d}" for v in row))
    for e in m["errors"]:
        print(f"  ERROR  {e['file']}  true {e['true']}  predicted {e['pred']}")


def git_commit():
    """HEAD, marked -dirty when the code under software/ is not what HEAD holds -
    a report must name the code that produced it, not merely the one before."""
    software = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    try:
        def git(*a):
            return subprocess.run(["git", *a], check=True, capture_output=True,
                                  text=True, cwd=software).stdout.strip()
        dirty = git("status", "--porcelain", "--untracked-files=no", "--", ".")
        return git("rev-parse", "--short", "HEAD") + ("-dirty" if dirty else "")
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unknown"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--data", required=True)
    p.add_argument("--split", required=True, choices=("val", "test"),
                   help="which split to score - test only once, at the end")
    p.add_argument("--ckpt", required=True)
    p.add_argument("--scales", help="activation scales from quantize.py; "
                                    "without them the int8 pipeline is skipped")
    p.add_argument("--report", help="write the results here as JSON")
    p.add_argument("--batch-size", type=int, default=32)
    p.add_argument("--num-workers", type=int, default=4)
    args = p.parse_args()

    # CPU throughout: the integer reference is defined on CPU (export.py), and
    # the float model should see exactly the same tensors
    device = "cpu"
    model, ckpt = load_checkpoint(args.ckpt, map_location=device)
    model.to(device).eval()
    classes = ckpt["classes"]
    img_size = ckpt.get("img_size", 224)

    loader, ds_classes = make_eval_loader(args.data, args.batch_size, img_size,
                                          args.num_workers, split=args.split)
    assert list(ds_classes) == list(classes), \
        f"dataset classes {ds_classes} differ from the checkpoint's {classes}"
    samples = loader.dataset.samples
    names = [f"{classes[y]}/{os.path.basename(path)}" for path, y in samples]
    groups = load_groups(args.data, samples, classes)
    print(f"{args.split}: {len(samples)} images, {len(set(groups))} leaf groups")

    t0 = time.time()
    y_true, y_float = [], []
    with torch.no_grad():
        for x, y in loader:
            y_float += model(x.to(device)).argmax(1).tolist()
            y_true += y.tolist()
    m_float = metrics(y_true, y_float, classes, names, groups)
    show(f"FLOAT  ({time.time() - t0:.0f}s)", m_float, classes)

    report = {
        "split": args.split,
        "data": os.path.basename(os.path.normpath(args.data)),
        "file_list_sha256": hashlib.sha256("\n".join(sorted(names)).encode()).hexdigest(),
        "images": len(samples), "groups": len(set(groups)),
        "classes": classes,
        "ckpt": args.ckpt.replace(os.sep, "/"), "ckpt_sha256": sha256_file(args.ckpt),
        "ckpt_best_val_acc": ckpt.get("best_acc"), "ckpt_best_epoch": ckpt.get("best_epoch"),
        "ckpt_trained_on": ckpt.get("data"),
        "float": m_float,
        "generated": datetime.date.today().isoformat(), "commit": git_commit(),
    }

    if args.scales:
        with open(args.scales) as fh:
            scales = json.load(fh)
        act = {n: float(d["act_scale"]) for n, d in scales["layers"].items()}
        fused = fuse_conv_bn(model).to(device).eval()
        # S_logit exactly as export.py would set it for this dataset: from val/
        cal_loader, _ = make_eval_loader(args.data, 32, img_size, num_workers=0, split="val")
        _, s_logit = calibrate_logit_scale(fused, cal_loader, device)
        plan = build_int_plan(fused, act, s_logit, args.scales)
        executor = IntExecutor(plan)
        s_first = act["features.0.0"]

        # the integer pipeline is the hardware's only if it fits the hardware
        worst, worst_name, need, _ = acc_bound(plan)
        acc_w = rtl_acc_w()
        fits = acc_w is not None and worst < (1 << (acc_w - 1))
        print(f"\naccumulator bound {worst:,} in {worst_name} -> {need} bits; "
              f"RTL ACC_W = {acc_w}: {'fits' if fits else 'DOES NOT FIT'}")
        if not fits:
            print("WARNING: this checkpoint would overflow the accelerator's accumulator - "
                  "the int8 numbers below are NOT the hardware's")

        t0, y_int = time.time(), []
        for x, _ in loader:
            for i in range(x.shape[0]):
                y_int.append(executor.run(quantize_input(x[i:i + 1], s_first))[2])
            print(f"\r  int8: {len(y_int)}/{len(samples)} images ({time.time() - t0:.0f}s)",
                  end="", flush=True)
        print()
        m_int = metrics(y_true, y_int, classes, names, groups)
        show(f"INT8 integer pipeline  ({time.time() - t0:.0f}s)", m_int, classes)

        disagree = [names[i] for i in range(len(names)) if y_int[i] != y_float[i]]
        drop = 100 * (m_float["accuracy"] - m_int["accuracy"])
        print(f"\nint8 vs float: {len(disagree)}/{len(names)} predictions differ; "
              f"accuracy drop {drop:+.2f} points")
        for n in disagree:
            print(f"  DIFFERS  {n}")
        report.update({
            "scales": args.scales.replace(os.sep, "/"), "scales_sha256": sha256_file(args.scales),
            "s_logit": s_logit,
            "acc_bound": worst, "acc_bound_bits": need, "rtl_acc_w": acc_w,
            "acc_bound_fits": fits, "max_abs_acc_seen": executor.max_abs_acc,
            "int8": m_int,
            "int8_float_disagree": disagree,
        })

    if args.report:
        with open(args.report, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(report, fh, indent=2)
            fh.write("\n")
        print(f"\nwrote {args.report}")


if __name__ == "__main__":
    main()

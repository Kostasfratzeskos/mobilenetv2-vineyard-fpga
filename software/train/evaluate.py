"""Evaluate a trained checkpoint: overall + per-class accuracy.

Run from inside software/:
    python train/evaluate.py --data ../data/grape --ckpt runs/mobilenetv2_grape.pth
"""
from __future__ import annotations

import argparse
import os
import sys

import torch

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from model.mobilenetv2 import load_checkpoint  # noqa: E402
from dataset import make_eval_loader  # noqa: E402


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--data", required=True)
    p.add_argument("--ckpt", required=True)
    p.add_argument("--batch-size", type=int, default=32)
    p.add_argument("--num-workers", type=int, default=4)
    args = p.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    model, ckpt = load_checkpoint(args.ckpt, map_location=device)
    model.to(device).eval()
    classes = ckpt["classes"]

    loader, ds_classes = make_eval_loader(
        args.data, args.batch_size, ckpt.get("img_size", 224), args.num_workers)
    if list(ds_classes) != list(classes):
        print("WARNING: dataset class order differs from checkpoint")
        print("  checkpoint:", classes)
        print("  dataset:   ", ds_classes)

    n = len(classes)
    correct = torch.zeros(n)
    total = torch.zeros(n)
    overall_c = overall_n = 0
    with torch.no_grad():
        for x, y in loader:
            x, y = x.to(device), y.to(device)
            pred = model(x).argmax(1)
            for c in range(n):
                m = (y == c)
                total[c] += m.sum().item()
                correct[c] += (pred[m] == c).sum().item()
            overall_c += (pred == y).sum().item()
            overall_n += y.numel()

    print(f"Overall accuracy: {overall_c / max(overall_n, 1):.4f} ({overall_c}/{overall_n})")
    print("Per-class accuracy:")
    for c in range(n):
        acc = (correct[c] / total[c]).item() if total[c] > 0 else float("nan")
        print(f"  {classes[c]:<20s} {acc:.4f}  (n={int(total[c])})")


if __name__ == "__main__":
    main()
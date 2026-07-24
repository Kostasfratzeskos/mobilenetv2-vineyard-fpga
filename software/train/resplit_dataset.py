"""Rebuild a leakage-free train/val split for the grape dataset.

The source folders (data/grape/{train,val}) were split *per file*, but the dataset
contains augmented duplicates of the same physical leaf: one true original plus
rotated/flipped copies (`_flipLR`, `_90deg`, `_180deg`, `_270deg`, `_new30degFlipLR`),
all sharing the same `<uuid>___` prefix. Splitting per file put copies of the same
leaf in both train and val -> data leakage -> inflated (near-100%) accuracy.

This script:
  1. Pools train+val and keeps only the ONE true original per leaf (the file whose
     name has no augmentation suffix, i.e. its stem ends in the image number).
     Verified: every leaf has exactly one such original.
  2. Splits per class 80/20 by leaf (no leaf can land in both sets).
  3. Copies the originals into a fresh, leakage-free layout.
  4. Asserts zero leaf-id overlap between the new train and val.

Augmentation is NOT baked into the files: the training DataLoader already applies
RandomHorizontalFlip on the fly (see dataset.py:_train_tf), so dropping the static
rotated/flipped copies loses no real information.

Run from software/:
    python train/resplit_dataset.py --src ../data/grape --dst ../data/grape_clean
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
from collections import defaultdict


def stem(fn: str) -> str:
    return os.path.splitext(fn)[0]


def leaf_id(fn: str) -> str:
    """UUID prefix that identifies one physical leaf (before '___')."""
    return fn.split("___", 1)[0]


def is_original(fn: str) -> bool:
    """True original has no augmentation suffix: its stem ends in the image number.

    Augmented copies append a suffix after that number (_flipLR, _90deg, _180deg,
    _270deg, _new30degFlipLR, ...), so their stem does NOT end in a digit.
    """
    return bool(re.search(r"\d$", stem(fn)))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--src", required=True, help="source root with train/ and val/")
    p.add_argument("--dst", required=True, help="output root (created fresh)")
    p.add_argument("--val-split", type=float, default=0.2)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--dry-run", action="store_true", help="report only, copy nothing")
    args = p.parse_args()

    import random
    rng = random.Random(args.seed)

    src_subs = [s for s in ("train", "val") if os.path.isdir(os.path.join(args.src, s))]
    if not src_subs:
        src_subs = [""]  # single-folder ImageFolder layout

    # class -> {filename: full source path} for ORIGINAL (non-flip) files only
    classes = set()
    for sub in src_subs:
        base = os.path.join(args.src, sub)
        for cls in os.listdir(base):
            if os.path.isdir(os.path.join(base, cls)):
                classes.add(cls)
    classes = sorted(classes)

    if os.path.exists(args.dst) and not args.dry_run:
        raise SystemExit(f"refusing to overwrite existing {args.dst!r} - remove it first")

    grand_tr = grand_va = grand_dropped = 0
    for cls in classes:
        files = {}  # filename -> src path (true originals only)
        dropped = 0
        for sub in src_subs:
            d = os.path.join(args.src, sub, cls)
            if not os.path.isdir(d):
                continue
            for f in os.listdir(d):
                if not is_original(f):
                    dropped += 1
                    continue
                files[f] = os.path.join(d, f)

        # exactly one original per leaf (verified beforehand); group defensively
        by_leaf = defaultdict(list)
        for f in files:
            by_leaf[leaf_id(f)].append(f)
        for lf, fs in by_leaf.items():
            assert len(fs) == 1, f"leaf {lf} in {cls} has {len(fs)} originals: {fs}"

        leaves = sorted(by_leaf)
        rng.shuffle(leaves)
        n_val = max(1, round(len(leaves) * args.val_split))
        val_leaves = set(leaves[:n_val])

        tr = [f for lf in leaves if lf not in val_leaves for f in by_leaf[lf]]
        va = [f for lf in val_leaves for f in by_leaf[lf]]
        grand_tr += len(tr); grand_va += len(va); grand_dropped += dropped

        print(f"{cls:12s} leaves={len(leaves):4d}  train={len(tr):4d}  val={len(va):4d}  "
              f"(dropped {dropped} augmented copies)")

        if args.dry_run:
            continue
        for split, names in (("train", tr), ("val", va)):
            out = os.path.join(args.dst, split, cls)
            os.makedirs(out, exist_ok=True)
            for f in names:
                shutil.copy2(files[f], os.path.join(out, f))

    print(f"\nTOTAL  train={grand_tr}  val={grand_va}  dropped_augmented={grand_dropped}")

    if not args.dry_run:
        # hard verification: no leaf id may appear in both new train and val
        for cls in classes:
            tr_ids = {leaf_id(f) for f in os.listdir(os.path.join(args.dst, "train", cls))}
            va_ids = {leaf_id(f) for f in os.listdir(os.path.join(args.dst, "val", cls))}
            overlap = tr_ids & va_ids
            assert not overlap, f"LEAK in {cls}: {len(overlap)} shared leaves"
        print("VERIFIED: zero leaf overlap between train and val.")
        print(f"New dataset: {args.dst}")


if __name__ == "__main__":
    main()

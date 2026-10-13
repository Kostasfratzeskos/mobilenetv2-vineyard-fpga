"""Build the leakage-free train/val/test split of the grape dataset - by LEAF.

Two splits came before this one, and both leaked (DD-034):

  data/grape        split per FILE, with rotated/flipped copies of each image
                    (`_flipLR`, `_90deg`, ...) on both sides -> 100.00%.
  data/grape_clean  the first version of this script: one original per `<uuid>`,
                    split by uuid. That removed the copies but not the real leak.
                    PlantVillage photographed every leaf FOUR times, each photo
                    with its own uuid: its own leaf maps put the 3,639 diseased
                    images on 910 leaves, and grape_clean has 532 of those 910
                    leaves on both sides of its split.

So the unit of splitting is the physical leaf, and nothing is left to a uuid:

  Black Rot, ESCA, Leaf Blight
      grouped by PlantVillage's own leaf maps (leaf_grouping/leaf_maps in
      spMohanty/PlantVillage-Dataset), which cover every one of our images.
      Leaves are shuffled and split 70/15/15 within each class.

  Healthy
      has no leaf map upstream. Every mapped leaf occupies one unbroken stretch
      of the frame sequence - no two of the 910 interleave - and healthy was
      shot the same way, so it is split into contiguous frame RANGES. A leaf
      can only cross a split at a cut, and every cut sits where the leaf
      visibly changes - margin and lobing, which no rotation or exposure
      explains. Both photo sessions (6020-6212 and 8903-9132) contribute to
      every split.

The leaf maps are not committed (the upstream repository declares no licence);
they live beside the images and are pinned by sha256. Fetch them into
data/plantvillage_leaf_maps/ from LEAF_MAPS_URL below, e.g.

    curl -o "Grape_Black Rot Fungus.csv" "<LEAF_MAPS_URL>Grape_Black%20Rot%20Fungus.csv"

and the same for the other two files named in LEAF_MAPS.

Only the true original of each image is kept; the training DataLoader applies
flips and crops on the fly (see dataset.py:_train_tf), so the static
rotated/flipped copies add nothing.

Besides the image folders, writes `<dst>/split.csv` (split, class, file, group):
the record of which photos belong together. evaluate.py resamples by `group`
when it puts a confidence interval on accuracy, because four photos of one leaf
are not four independent tests.

Run from software/:
    python train/resplit_dataset.py --src ../data/grape \\
        --leaf-maps ../data/plantvillage_leaf_maps --dst ../data/grape_leafsplit
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import os
import random
import re
import shutil
from collections import defaultdict

SPLITS = ("train", "val", "test")

# PlantVillage's per-class leaf maps, as of upstream commit 40789680 (2016-08-04).
LEAF_MAPS_URL = ("https://raw.githubusercontent.com/spMohanty/PlantVillage-Dataset/"
                 "40789680ba2e6382608dba47b397688fcbd0d04a/leaf_grouping/leaf_maps/")
LEAF_MAPS = {   # our class folder -> (upstream file, sha256)
    "Black Rot": ("Grape_Black Rot Fungus.csv",
                  "3f81f13657f170e5887aac0bd372cefcfdceac4f247285345c9bf3a605ad5d40"),
    "ESCA": ("Grape_Black Measles Fungus.csv",
             "f404cd950d32c8f3c721dab67865527dd51287b2f438b22431d9c897568d4553"),
    "Leaf Blight": ("Grape_Leaf Blight Fungus.csv",
                    "e8cad3b46c25a709b74502bab1c2cc6cfd15744ac3098234a7af23997ec5f347"),
}

# Healthy: inclusive frame ranges, one per split per session. The cuts, each
# checked by eye on the frames either side:
#   6150|6151  smooth three-lobed leaf  -> deeply serrated leaf
#   6181|6182  deeply lobed, serrated   -> smooth heart-shaped
#   9062|9063  round, entire margin     -> lobed, serrated
#   9090|9091  serrated, lobed          -> smooth heart-shaped
# Not at the nominal 15% marks, because there consecutive frames look alike
# (6151-6158 could be one leaf or two) and a cut has to be unambiguous.
HEALTHY_CLASS = "Healthy"
HEALTHY_RANGES = {
    "train": ((6020, 6150), (8903, 9062)),
    "val": ((6151, 6181), (9063, 9090)),
    "test": ((6182, 6212), (9091, 9132)),
}
# For the confidence interval only (never for the split): healthy frames are
# grouped in runs of 4 from the start of each range, the way every mapped leaf
# was photographed. An approximation, and named as one in split.csv.
HEALTHY_RUN = 4


def stem(fn: str) -> str:
    return os.path.splitext(fn)[0]


def is_original(fn: str) -> bool:
    """True original has no augmentation suffix: its stem ends in the image number.

    Augmented copies append a suffix after that number (_flipLR, _90deg, _180deg,
    _270deg, _new30degFlipLR, ...), so their stem does NOT end in a digit.
    """
    return bool(re.search(r"\d$", stem(fn)))


def pv_name(fn: str) -> str:
    """PlantVillage's own image name, the part after '<uuid>___': 'FAM_B.Rot 0323'."""
    return stem(fn.split("___", 1)[1])


def frame(fn: str) -> int:
    return int(re.search(r"(\d+)$", pv_name(fn)).group(1))


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        h.update(fh.read())
    return h.hexdigest()


def load_leaf_map(leaf_maps_dir: str, cls: str) -> dict:
    """{pv_name lowercased: leaf number} for one class, after checking the file."""
    name, want = LEAF_MAPS[cls]
    path = os.path.join(leaf_maps_dir, name)
    if not os.path.exists(path):
        raise SystemExit(f"missing leaf map {path!r} - fetch it from {LEAF_MAPS_URL}")
    got = sha256_file(path)
    if got != want:
        raise SystemExit(f"{path!r} is not the pinned leaf map (sha256 {got[:12]}...)")
    with open(path, newline="") as fh:
        rows = list(csv.DictReader(fh))
    return {stem(r["File Name"]).lower(): int(float(r["Leaf #"])) for r in rows}


def healthy_split(n: int) -> str:
    hits = [s for s in SPLITS for lo, hi in HEALTHY_RANGES[s] if lo <= n <= hi]
    assert len(hits) == 1, f"healthy frame {n} is in {len(hits)} ranges"
    return hits[0]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--src", required=True, help="source root with train/ and val/")
    p.add_argument("--leaf-maps", required=True,
                   help="folder holding PlantVillage's three grape leaf-map CSVs")
    p.add_argument("--dst", required=True, help="output root (created fresh)")
    p.add_argument("--val-split", type=float, default=0.15)
    p.add_argument("--test-split", type=float, default=0.15)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--dry-run", action="store_true", help="report only, copy nothing")
    args = p.parse_args()

    rng = random.Random(args.seed)

    src_subs = [s for s in ("train", "val") if os.path.isdir(os.path.join(args.src, s))]
    if not src_subs:
        src_subs = [""]  # single-folder ImageFolder layout

    classes = sorted({cls for sub in src_subs
                      for cls in os.listdir(os.path.join(args.src, sub))
                      if os.path.isdir(os.path.join(args.src, sub, cls))})
    unknown = [c for c in classes if c != HEALTHY_CLASS and c not in LEAF_MAPS]
    assert not unknown, f"no leaf grouping for classes {unknown}"

    if os.path.exists(args.dst) and not args.dry_run:
        raise SystemExit(f"refusing to overwrite existing {args.dst!r} - remove it first")

    rows = []  # (split, class, filename, group, source path)
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
        names = defaultdict(list)
        for f in files:
            names[pv_name(f).lower()].append(f)
        twice = {n: fs for n, fs in names.items() if len(fs) > 1}
        assert not twice, f"{cls}: one PlantVillage image under two uuids: {twice}"

        if cls == HEALTHY_CLASS:
            leaves = None
            for f in files:
                s = healthy_split(frame(f))   # every frame in exactly one range
                lo = next(lo for lo, hi in HEALTHY_RANGES[s] if lo <= frame(f) <= hi)
                run = lo + (frame(f) - lo) // HEALTHY_RUN * HEALTHY_RUN
                rows.append((s, cls, f, f"run {run}", files[f]))
        else:
            leaf_of = load_leaf_map(args.leaf_maps, cls)
            missing = [f for f in files if pv_name(f).lower() not in leaf_of]
            assert not missing, f"{cls}: {len(missing)} images not in the leaf map, e.g. {missing[:3]}"
            by_leaf = defaultdict(list)
            for f in files:
                by_leaf[leaf_of[pv_name(f).lower()]].append(f)
            leaves = sorted(by_leaf)
            rng.shuffle(leaves)
            n_test = round(len(leaves) * args.test_split)
            n_val = round(len(leaves) * args.val_split)
            assign = {lf: ("test" if i < n_test else "val" if i < n_test + n_val else "train")
                      for i, lf in enumerate(leaves)}
            for lf, fs in by_leaf.items():
                for f in fs:
                    rows.append((assign[lf], cls, f, f"leaf {lf}", files[f]))

        mine = [r for r in rows if r[1] == cls]
        assert len(mine) == len(files), f"{cls}: {len(files)} originals, {len(mine)} assigned"
        n = {s: sum(1 for r in mine if r[0] == s) for s in SPLITS}
        unit = f"leaves={len(leaves):4d}" if leaves is not None else "frame ranges"
        print(f"{cls:12s} {unit:14s} train={n['train']:4d}  val={n['val']:4d}  "
              f"test={n['test']:4d}  (dropped {dropped} augmented copies)")

    tot = {s: sum(1 for r in rows if r[0] == s) for s in SPLITS}
    print(f"\nTOTAL  train={tot['train']}  val={tot['val']}  test={tot['test']}  "
          f"({len(rows)} originals)")

    # no group may sit in two splits (for healthy that checks the runs; the
    # ranges themselves were checked by healthy_split above)
    split_of = {}
    for s, cls, _, g, _ in rows:
        assert split_of.setdefault((cls, g), s) == s, f"LEAK: {cls} {g} in two splits"

    if args.dry_run:
        return
    for s, cls, f, _, path in rows:
        out = os.path.join(args.dst, s, cls)
        os.makedirs(out, exist_ok=True)
        shutil.copy2(path, os.path.join(out, f))
    with open(os.path.join(args.dst, "split.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["split", "class", "file", "group"])
        for s, cls, f, g, _ in sorted(rows):
            w.writerow([s, cls, f, g])

    # hard verification, from what actually landed on disk
    for cls in classes:
        leaf_of = None if cls == HEALTHY_CLASS else load_leaf_map(args.leaf_maps, cls)
        where = {}
        for s in SPLITS:
            for f in os.listdir(os.path.join(args.dst, s, cls)):
                if leaf_of is None:
                    assert healthy_split(frame(f)) == s, f"healthy {f} outside its range"
                    continue
                lf = leaf_of[pv_name(f).lower()]
                assert where.setdefault(lf, s) == s, f"LEAK in {cls}: leaf {lf} in {where[lf]} and {s}"
    print("VERIFIED: no leaf in two splits; every healthy frame inside its range.")
    print(f"New dataset: {args.dst}  (+ split.csv)")


if __name__ == "__main__":
    main()
